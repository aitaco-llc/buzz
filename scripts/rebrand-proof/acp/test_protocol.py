#!/usr/bin/env python3
"""Drive the proof host and the real rebrand-acp binary against a scripted model and relay.

One local HTTP server plays both `rebrand serve` (/v1/models, /v1/chat/completions)
and the relay (/query, /events). The host speaks ACP to the test, ACP to
rebrand-acp, and serves the read tools to rebrand-acp over HTTP MCP.
"""
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIN = os.environ['PROOF_HOST_BIN']
ACP_BIN = os.environ['PROOF_REBRAND_ACP_BIN']
CHANNEL = '00000000-0000-4000-8000-000000000001'
ROOT, SOURCE, TRIGGER = 'a' * 64, 'b' * 64, 'c' * 64
QUESTION = 'Find incident fixture and report the recovery code.'


def children(endpoint):
    """rebrand-acp processes started for this endpoint."""
    found = []
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit():
            continue
        try:
            argv0 = (proc / 'cmdline').read_bytes().split(b'\0')[0].decode()
            environ = (proc / 'environ').read_bytes().split(b'\0')
        except OSError:
            continue
        if argv0 == ACP_BIN and f'REBRAND_ACP_ENDPOINT={endpoint}'.encode() in environ:
            found.append(int(proc.name))
    return found


class ProtocolTests(unittest.TestCase):
    def run_case(self, mode):
        queries, publications, chats = [], [], []
        started = threading.Event()

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def send_json(self, value):
                body = json.dumps(value).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path == '/v1/models':
                    return self.send_json({'object': 'list', 'data': [{'id': 'fixture', 'object': 'model'}]})
                self.send_response(404)
                self.end_headers()

            def do_POST(self):
                value = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                if self.path == '/query':
                    f = value[0]
                    queries.append(f)
                    event_id = SOURCE if '#e' in f else TRIGGER if f.get('ids') == [TRIGGER] else ROOT
                    channel = 'forbidden' if mode == 'wrong-channel' and 'search' in f else CHANNEL
                    return self.send_json([{'id': event_id, 'content': 'Recovery code SOLVED-fixture7.', 'tags': [['h', channel]]}])
                if self.path == '/events':
                    publications.append(value)
                    return self.send_json({'accepted': True, 'event_id': value['id']})
                chats.append(value)
                started.set()
                if mode == 'cancel':
                    time.sleep(3)
                i = len(chats)
                if i == 1:
                    delta = {'tool_calls': [{'index': 0, 'id': 'call1', 'type': 'function', 'function': {
                        'name': 'search_messages', 'arguments': json.dumps({'query': 'incident fixture'})}}]}
                    finish = 'error' if mode == 'model-error' else 'tool_calls'
                elif i == 2:
                    delta = {'tool_calls': [{'index': 0, 'id': 'call2', 'type': 'function', 'function': {
                        'name': 'read_thread', 'arguments': json.dumps({'event_id': ROOT})}}]}
                    finish = 'tool_calls'
                else:
                    answer = {'answer': 'SOLVED-123456' if mode == 'invented-code' else 'SOLVED-fixture7',
                              'source_ids': ['d' * 64 if mode == 'invented-citation' else SOURCE]}
                    if mode == 'off-schema':
                        answer = {'answer': 'SOLVED-fixture7'}
                    delta, finish = {'content': json.dumps(answer)}, 'stop'
                if mode == 'empty-citations' and i == 2:
                    # Answering while read_thread is still on offer: of-agent
                    # sends that turn with tools and no response_format, so
                    # nothing constrains it. This is what B9/B10 did on hip.
                    delta = {'content': json.dumps({'answer': 'SOLVED-fixture7', 'source_ids': []})}
                    finish = 'stop'
                chunk = {'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]}
                body = ('data: ' + json.dumps(chunk) + '\n\ndata: [DONE]\n\n').encode()
                try:
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        with tempfile.TemporaryDirectory() as directory:
            d = Path(directory)
            (d / 'trigger').write_text(TRIGGER)
            endpoint = f'http://127.0.0.1:{server.server_port}'
            # The host holds a key; rebrand-acp refuses to start if it inherits one.
            env = dict(os.environ, BUZZ_RELAY_URL=endpoint, BUZZ_PRIVATE_KEY='0' * 63 + '1',
                       REBRAND_ENDPOINT=endpoint, REBRAND_MODEL_ID='fixture',
                       PROOF_REBRAND_ACP_BIN=ACP_BIN,
                       PROOF_REBRAND_ACP_ARGS='--max-iterations 6 --max-tool-calls 6 --max-seconds 30',
                       PROOF_CHANNEL=CHANNEL, PROOF_QUESTION=QUESTION,
                       PROOF_TRIGGER_FILE=str(d / 'trigger'), PROOF_NATIVE_RESULT=str(d / 'result'))
            with (d / 'stderr').open('w+') as stderr:
                proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, env=env)

                def send(value):
                    proc.stdin.write((json.dumps(value) + '\n').encode())
                    proc.stdin.flush()

                def reply():
                    selector = selectors.DefaultSelector()
                    selector.register(proc.stdout, selectors.EVENT_READ)
                    try:
                        self.assertTrue(selector.select(20), 'ACP response timed out')
                        line = proc.stdout.readline()
                        return json.loads(line) if line else None
                    finally:
                        selector.close()
                try:
                    send({'id': 1, 'method': 'initialize', 'params': {'protocolVersion': 1}})
                    self.assertEqual(reply()['result']['protocolVersion'], 1)
                    send({'id': 2, 'method': 'session/new', 'params': {'cwd': directory, 'mcpServers': []}})
                    self.assertEqual(reply()['result']['sessionId'], 'retrieval-proof')
                    send({'id': 3, 'method': 'session/prompt', 'params': {'sessionId': 'retrieval-proof', 'prompt': [{'type': 'text', 'text': QUESTION}]}})
                    if mode == 'cancel':
                        self.assertTrue(started.wait(10))
                        self.assertEqual(len(children(endpoint)), 1)
                        send({'method': 'session/cancel', 'params': {'sessionId': 'retrieval-proof'}})
                        self.assertEqual(reply()['result']['stopReason'], 'cancelled')
                        self.assertEqual(proc.wait(timeout=5), 0)
                    elif mode == 'ok':
                        self.assertEqual(reply()['method'], 'session/update')
                        # stdout's buffered reader may already contain the next line.
                        response = json.loads(proc.stdout.readline())
                        self.assertEqual(response['result']['stopReason'], 'end_turn')
                        self.assertEqual(len(publications), 1)
                        self.assertIn(f'&id={SOURCE}', publications[0]['content'])
                        self.assertIn('SOLVED-fixture7', publications[0]['content'])
                        # Tools narrow as the run goes, and the answering turn
                        # is offered none and carries the schema.
                        offered = [[t['function']['name'] for t in c.get('tools') or []] for c in chats]
                        self.assertEqual(offered, [['search_messages'], ['read_thread'], []])
                        self.assertEqual(chats[1]['tools'][0]['function']['parameters']['properties']['event_id']['enum'], [ROOT])
                        self.assertNotIn('response_format', chats[0])
                        self.assertEqual(chats[2]['response_format']['type'], 'json_schema')
                        sent = chats[2]['response_format']['json_schema']['schema']
                        self.assertEqual(sent['required'], ['answer', 'source_ids'])
                        self.assertEqual(sent['properties']['source_ids']['minItems'], 1)
                        self.assertEqual(sent['properties']['source_ids']['maxItems'], 5)
                        report = json.loads((d / 'result').read_text())['run']
                        self.assertEqual(report['loop'], 'rebrand-acp')
                        self.assertEqual(report['agent']['name'], 'rebrand-acp')
                        self.assertEqual(report['reads'], ['search_messages', 'read_thread'])
                        self.assertEqual(json.loads(report['answer_text'])['answer'], 'SOLVED-fixture7')
                        self.assertIn(SOURCE, report['thread_source_ids'])
                        proc.stdin.close()
                        self.assertEqual(proc.wait(timeout=5), 0)
                    else:
                        proc.wait(timeout=20)
                        self.assertNotEqual(proc.returncode, 0)
                        self.assertTrue((d / 'result.run.json').exists() or mode == 'wrong-channel')
                        if mode == 'empty-citations':
                            # The turn that answered had a tool on offer, so it
                            # carried no schema: an empty array cannot come
                            # from a constrained decode.
                            self.assertEqual(len(chats), 2)
                            self.assertEqual([t['function']['name'] for t in chats[1]['tools']], ['read_thread'])
                            self.assertNotIn('response_format', chats[1])
                            self.assertIn('less than 1 item', json.loads((d / 'result.run.json').read_text())['error']['message'])
                        if mode == 'invented-code':
                            self.assertIn('SOLVED-123456', json.loads((d / 'result.run.json').read_text())['answer_text'])
                    self.assertTrue(all(q['#h'] == [CHANNEL] and q['kinds'] == [9, 40002] for q in queries))
                    if mode != 'ok':
                        self.assertEqual(publications, [], 'failed/cancelled run published a reply')
                    for _ in range(30):
                        if not children(endpoint):
                            break
                        time.sleep(0.1)
                    self.assertEqual(children(endpoint), [], 'rebrand-acp outlived the host')
                finally:
                    if proc.poll() is None:
                        proc.kill()
                    proc.wait(timeout=5)
                    proc.stdout.close()
                    if not proc.stdin.closed:
                        proc.stdin.close()
                    stderr.seek(0)
                    log = stderr.read()
                    if os.environ.get('PROOF_TEST_VERBOSE') or proc.returncode not in (0, 1):
                        print(f'--- {mode} stderr\n{log}')
        server.shutdown()
        server.server_close()

    def test_success(self): self.run_case('ok')
    def test_cancellation(self): self.run_case('cancel')
    def test_forged_citation(self): self.run_case('invented-citation')
    def test_invented_code_with_real_citation(self): self.run_case('invented-code')
    def test_answer_off_schema(self): self.run_case('off-schema')
    def test_empty_citation_list_from_an_unconstrained_turn(self): self.run_case('empty-citations')
    def test_wrong_channel(self): self.run_case('wrong-channel')
    def test_model_error(self): self.run_case('model-error')


if __name__ == '__main__':
    unittest.main()
