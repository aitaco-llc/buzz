#!/usr/bin/env python3
"""Exercise the actual ACP worker and Rebrand loop against controlled wire failures."""
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

BIN = os.environ['PROOF_NATIVE_BIN']
CHANNEL = '00000000-0000-4000-8000-000000000001'
ROOT, SOURCE, TRIGGER = 'a' * 64, 'b' * 64, 'c' * 64
QUESTION = 'Find incident fixture and report the recovery code.'

class ProtocolTests(unittest.TestCase):
    def run_case(self, mode):
        queries, publications, requests = [], [], []
        started = threading.Event()
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_POST(self):
                value = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                if self.path == '/query':
                    f = value[0]
                    queries.append(f)
                    event_id = SOURCE if '#e' in f else TRIGGER if f.get('ids') == [TRIGGER] else ROOT
                    channel = 'forbidden' if mode == 'wrong-channel' and 'search' in f else CHANNEL
                    result = [{'id': event_id, 'content': 'Recovery code SOLVED-fixture.', 'tags': [['h', channel]]}]
                elif self.path == '/events':
                    publications.append(value)
                    result = {'accepted': True, 'event_id': value['id']}
                else:
                    requests.append(value)
                    started.set()
                    if mode == 'cancel':
                        time.sleep(1)
                    i = len(requests)
                    if i == 1:
                        name, args = 'search_messages', {'query': 'incident fixture'}
                    elif i == 2:
                        name, args = 'read_thread', {'event_id': ROOT}
                    else:
                        name, args = 'finish_answer', {'answer': 'SOLVED-fixture', 'source_ids': ['d' * 64 if mode == 'invented-citation' else SOURCE]}
                    chunk = {'choices':[{'index':0,'delta':{'tool_calls':[{'index':0,'id':f'call{i}','type':'function','function':{'name':name,'arguments':json.dumps(args)}}]},'finish_reason': 'error' if mode == 'model-error' else 'tool_calls'}]}
                    if i >= 3:
                        content = '' if mode == 'empty-answer' or (mode == 'recover-stall' and i == 3) else json.dumps(args)
                        chunk = {'choices':[{'index':0,'delta':{'content':content},'finish_reason':'stop'}]}
                    body = ('data: ' + json.dumps(chunk) + '\n\ndata: [DONE]\n\n').encode()
                    self.send_response(200)
                    self.send_header('Content-Type','text/event-stream')
                    self.send_header('Content-Length',str(len(body)))
                    self.end_headers()
                    try:
                        self.wfile.write(body)
                    except BrokenPipeError:
                        pass
                    return
                body = json.dumps(result).encode()
                self.send_response(200)
                self.send_header('Content-Length',str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        with tempfile.TemporaryDirectory() as directory:
            d = Path(directory)
            (d/'trigger').write_text(TRIGGER)
            endpoint = f'http://127.0.0.1:{server.server_port}'
            env = dict(os.environ, BUZZ_RELAY_URL=endpoint, BUZZ_PRIVATE_KEY='0'*63+'1',
                       REBRAND_ENDPOINT=endpoint, REBRAND_MODEL_ID='fixture',
                       PROOF_CHANNEL=CHANNEL, PROOF_QUESTION=QUESTION,
                       PROOF_TRIGGER_FILE=str(d/'trigger'), PROOF_NATIVE_RESULT=str(d/'result'))
            with (d/'stderr').open('w+') as stderr:
                proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, env=env)
                def send(value):
                    proc.stdin.write((json.dumps(value)+'\n').encode())
                    proc.stdin.flush()
                def reply():
                    selector = selectors.DefaultSelector()
                    selector.register(proc.stdout, selectors.EVENT_READ)
                    try:
                        self.assertTrue(selector.select(10), 'ACP response timed out')
                        line = proc.stdout.readline()
                        return json.loads(line) if line else None
                    finally:
                        selector.close()
                try:
                    send({'id':1,'method':'initialize','params':{'protocolVersion':1}})
                    self.assertEqual(reply()['result']['protocolVersion'], 1)
                    send({'id':2,'method':'session/new','params':{'cwd':directory,'mcpServers':[]}})
                    self.assertEqual(reply()['result']['sessionId'], 'retrieval-proof')
                    send({'id':3,'method':'session/prompt','params':{'sessionId':'retrieval-proof','prompt':[{'type':'text','text':QUESTION}]}})
                    if mode == 'cancel':
                        self.assertTrue(started.wait(5))
                        send({'method':'session/cancel','params':{'sessionId':'retrieval-proof'}})
                        self.assertEqual(reply()['result']['stopReason'],'cancelled')
                        self.assertEqual(proc.wait(timeout=5),0)
                    elif mode in ('ok', 'recover-stall'):
                        self.assertEqual(reply()['method'],'session/update')
                        # stdout's buffered reader may already contain the next line.
                        response = json.loads(proc.stdout.readline())
                        self.assertEqual(response['result']['stopReason'],'end_turn')
                        self.assertTrue((d/'result').exists())
                        self.assertEqual(len(publications),1)
                        self.assertIn(f'&id={SOURCE}', publications[0]['content'])
                        proc.stdin.close()
                        self.assertEqual(proc.wait(timeout=5),0)
                    else:
                        proc.wait(timeout=10)
                        self.assertNotEqual(proc.returncode,0)
                    self.assertTrue(all(q['#h'] == [CHANNEL] and q['kinds'] == [9,40002] for q in queries))
                    if mode not in ('ok', 'recover-stall'):
                        self.assertEqual(publications, [], 'failed/cancelled run published a reply')
                finally:
                    if proc.poll() is None:
                        proc.kill()
                    proc.wait(timeout=5)
                    proc.stdout.close()
                    if not proc.stdin.closed:
                        proc.stdin.close()
                    stderr.seek(0)
                    if proc.returncode not in (0,1):
                        print(stderr.read())
        server.shutdown()
        server.server_close()

    def test_success(self): self.run_case('ok')
    def test_recovers_one_empty_turn(self): self.run_case('recover-stall')
    def test_repeated_empty_answer_is_failure(self): self.run_case('empty-answer')
    def test_cancellation(self): self.run_case('cancel')
    def test_forged_citation(self): self.run_case('invented-citation')
    def test_wrong_channel(self): self.run_case('wrong-channel')
    def test_model_error(self): self.run_case('model-error')

if __name__ == '__main__': unittest.main()
