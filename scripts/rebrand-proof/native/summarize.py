#!/usr/bin/env python3
"""Require actual retrieval, source citation, relay publication and successful ACP turn."""
import argparse
import json
from pathlib import Path
import sys

p = argparse.ArgumentParser()
p.add_argument('--run-dir', type=Path, required=True)
p.add_argument('--seat', required=True)
p.add_argument('--results', type=Path, required=True)
a = p.parse_args()
def text(name):
    path = a.run_dir / name
    return path.read_text().strip() if path.exists() else ''
def data(name):
    raw = text(name)
    return json.loads(raw) if raw else {}

reply, native = data('reply.json'), data('native.json')
trigger, source, nonce = text('trigger_id'), text('source_id'), text('nonce')
turns = [json.loads(line) for path in (a.run_dir / 'turnlog/index').glob('*.jsonl')
         for line in path.read_text().splitlines() if line.strip()]
turn = next((t for t in turns if trigger in t.get('triggeringEventIds', [])), {})
checks = {
    'correct_author': reply.get('pubkey') == a.seat,
    'retrieved_secret': bool(nonce) and f'SOLVED-{nonce}' in reply.get('content', ''),
    'cited_source': bool(source) and f'&id={source}' in reply.get('content', ''),
    'threaded': any(len(t) >= 4 and t[0] == 'e' and t[1] == trigger and t[3] == 'reply'
                    for t in reply.get('tags', [])),
    'source_read_from_thread': bool(source) and source in native.get('run', {}).get('thread_source_ids', []),
    'actual_rebrand_loop': native.get('run', {}).get('loop') == 'rebrand-of-agent',
    'both_read_tools': {'search_messages','read_thread'} <= set(native.get('run', {}).get('reads', [])),
    'accepted': native.get('publication', {}).get('accepted') is True,
    'turn_completed': turn.get('outcome') == 'ok',
}
result = {'pass': all(checks.values()), 'checks': checks, 'run_dir': str(a.run_dir),
          'model': text('model_id'), 'model_sha256': text('model_sha256'),
          'backend_version': text('backend_version'), 'backend_sha256': text('backend_sha256'),
          'max_seq_len': text('max_seq_len'),
          'native_binary': text('native_binary'), 'run': native.get('run'), 'reply': reply.get('content')}
with a.results.open('a') as out:
    out.write(json.dumps(result) + '\n')
print(json.dumps(result, indent=2))
sys.exit(0 if result['pass'] else 1)
