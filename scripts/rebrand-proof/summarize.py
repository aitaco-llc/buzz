#!/usr/bin/env python3
"""Turn one proof run directory into one results line.

Recorded per run (null when a field does not apply to the mode):

  pass                 reply posted, carries the nonce, threaded under the mention,
                       and the turn ended "ok"
  reply_found, reply_threaded, turn_outcome
  mention_to_reply_s   relay created_at of the reply minus that of the mention
  mention_to_turn_start_s, turn_s
                       from the harness turn log (startedAt / completedAt)
  llm_calls, llm_s_total, llm_s_first, llm_s_max
                       from the recording proxy, one entry per chat completion
  prompt_tokens_first, prompt_tokens_max, completion_tokens_total
                       from each response's `usage`, as the backend reports them
  prompt_chars_first, request_bytes_max, tool_calls, finish_reasons
  http_errors, unknown_fields
                       non-200 responses; request fields Rebrand would reject
  serve_ready_s        rebrand only: `rebrand serve` start to /health ok
  vram_baseline_mib, vram_peak_mib
                       amdgpu sysfs, sampled once a second (not in stub mode)
  seat_cwd, hint_agents_md, hint_bytes, hint_skill_files
                       the seat's own working directory, and the AGENTS.md files
                       (path, bytes) and SKILL.md count its hint loader reads
  mode, model_id, model_path, model_bytes, backend_version, max_seq_len,
  max_output_tokens, binaries, repo_commit, run_id
"""

import argparse
import glob
import json
import os
import sys


def read(run_dir, name):
    path = os.path.join(run_dir, name)
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as handle:
        return handle.read().strip() or None


def jsonl(pattern):
    rows = []
    for path in sorted(glob.glob(pattern)):
        with open(path, encoding="utf-8") as handle:
            rows.extend(json.loads(line) for line in handle if line.strip())
    return rows


def as_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def iso_to_epoch(value):
    if not value:
        return None
    from datetime import datetime

    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--seat", required=True)
    parser.add_argument("--results", required=True)
    args = parser.parse_args()
    run_dir = args.run_dir

    trigger = read(run_dir, "trigger_id")
    nonce = read(run_dir, "nonce")
    t_mention = as_float(read(run_dir, "t_mention"))

    reply = None
    reply_raw = read(run_dir, "reply.json")
    if reply_raw:
        reply = json.loads(reply_raw)
    reply_threaded = None
    if reply:
        e_tags = [t for t in reply.get("tags", []) if t and t[0] == "e"]
        reply_threaded = any(len(t) > 1 and t[1] == trigger for t in e_tags)

    turns = [row for row in jsonl(os.path.join(run_dir, "turnlog", "index", "*.jsonl"))
             if trigger in (row.get("triggeringEventIds") or [])]
    turn = turns[0] if turns else {}
    started = iso_to_epoch(turn.get("startedAt"))
    completed = iso_to_epoch(turn.get("completedAt"))

    calls = [c for c in jsonl(os.path.join(run_dir, "llm_calls.jsonl")) if c.get("path", "").endswith("/chat/completions")]
    latencies = [c["latency_s"] for c in calls if c.get("latency_s") is not None]
    usages = [c.get("usage") or {} for c in calls]
    prompt_tokens = [u.get("prompt_tokens") for u in usages if u.get("prompt_tokens") is not None]

    vram = []
    vram_path = os.path.join(run_dir, "vram.tsv")
    if os.path.exists(vram_path):
        with open(vram_path, encoding="utf-8") as handle:
            for line in handle:
                parts = line.split()
                if len(parts) == 2 and parts[1].isdigit():
                    vram.append(int(parts[1]) / (1024 * 1024))

    mention_created = None
    if reply and trigger:
        # The mention's own created_at is not fetched; the observed send time
        # (t_mention) is the reference, to the second.
        mention_created = int(t_mention) if t_mention else None

    binaries = {}
    for line in (read(run_dir, "binaries") or "").splitlines():
        name, _, digest = line.partition(" ")
        binaries[name] = digest

    hints = json.loads(read(run_dir, "hint_files.json") or "{}")
    hint_files = hints.get("agents_md") or []

    result = {
        "run_id": os.path.basename(run_dir.rstrip("/")),
        "mode": read(run_dir, "mode"),
        "model_id": read(run_dir, "model_id"),
        "model_path": read(run_dir, "model_path"),
        "model_bytes": int(read(run_dir, "model_bytes")) if read(run_dir, "model_bytes") else None,
        "backend_version": read(run_dir, "backend_version"),
        "max_seq_len": int(read(run_dir, "max_seq_len") or 0) or None,
        "max_output_tokens": int(read(run_dir, "max_output_tokens") or 0) or None,
        "serve_ready_s": as_float(read(run_dir, "serve_ready_s")),
        "trigger_id": trigger,
        "reply_found": reply is not None,
        "reply_threaded": reply_threaded,
        "reply_text": (reply or {}).get("content"),
        "turn_outcome": turn.get("outcome"),
        "mention_to_reply_s": (reply["created_at"] - mention_created) if reply and mention_created else None,
        "mention_to_reply_observed_s": (
            round(as_float(read(run_dir, "t_reply_observed")) - t_mention, 2)
            if read(run_dir, "t_reply_observed") and t_mention else None
        ),
        "mention_to_turn_start_s": round(started - t_mention, 2) if started and t_mention else None,
        "turn_s": round(completed - started, 2) if started and completed else None,
        "llm_calls": len(calls),
        "llm_s_total": round(sum(latencies), 2) if latencies else None,
        "llm_s_first": latencies[0] if latencies else None,
        "llm_s_max": max(latencies) if latencies else None,
        "prompt_tokens_first": prompt_tokens[0] if prompt_tokens else None,
        "prompt_tokens_max": max(prompt_tokens) if prompt_tokens else None,
        "completion_tokens_total": sum(u.get("completion_tokens") or 0 for u in usages) if usages else None,
        "prompt_chars_first": calls[0].get("prompt_chars") if calls else None,
        "request_bytes_max": max((c.get("request_bytes") or 0) for c in calls) if calls else None,
        "tool_calls": sum(c.get("tool_calls") or 0 for c in calls),
        "finish_reasons": [c.get("finish_reason") for c in calls],
        "http_errors": [{"status": c["status"], "error": c.get("error")} for c in calls if c.get("status") != 200],
        "unknown_fields": sorted({f for c in calls for f in (c.get("unknown_fields") or [])}),
        "vram_baseline_mib": round(vram[0]) if vram else None,
        "vram_peak_mib": round(max(vram)) if vram else None,
        "seat_cwd": read(run_dir, "seat_cwd"),
        "hint_agents_md": hint_files,
        "hint_bytes": sum(f.get("bytes") or 0 for f in hint_files),
        "hint_skill_files": hints.get("skill_md_files"),
        "binaries": binaries,
        "repo_commit": read(run_dir, "repo_commit"),
    }
    result["pass"] = bool(
        result["reply_found"]
        and result["reply_threaded"]
        and nonce
        and f"PONG-{nonce}" in (result["reply_text"] or "")
        and result["turn_outcome"] == "ok"
    )

    with open(args.results, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(result) + "\n")
    with open(os.path.join(run_dir, "result.json"), "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2)

    keys = ["pass", "mode", "model_id", "reply_threaded", "turn_outcome", "mention_to_reply_s",
            "turn_s", "llm_calls", "llm_s_first", "llm_s_total", "prompt_tokens_first",
            "prompt_tokens_max", "prompt_chars_first", "hint_bytes", "tool_calls",
            "http_errors", "unknown_fields",
            "serve_ready_s", "vram_peak_mib"]
    for key in keys:
        print(f"{key:>24}: {result[key]}")
    print(f"{'result line':>24}: {args.results}")
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
