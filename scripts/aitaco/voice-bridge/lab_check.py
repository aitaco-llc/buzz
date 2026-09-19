#!/usr/bin/env python3
"""Score one voice-bridge lab run. Every check must hold for a pass."""
import argparse
import json
from pathlib import Path
import sys

p = argparse.ArgumentParser()
p.add_argument("--run-dir", type=Path, required=True)
p.add_argument("--seat", required=True)
p.add_argument("--caller", required=True)
p.add_argument("--results", type=Path, required=True)
p.add_argument("--fault", default="none",
               choices=["none", "room_join", "gemini_connect", "mid_call", "relay_gone"])
a = p.parse_args()


def text(name):
    path = a.run_dir / name
    return path.read_text().strip() if path.exists() else ""


def jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []


def rows(name):
    raw = text(name)
    if not raw:
        return []
    data = json.loads(raw)
    return data if isinstance(data, list) else data.get("messages", [])


def tag(row, name):
    return next((t[1] for t in row.get("tags", []) if t and t[0] == name and len(t) > 1), None)


nonce = text("nonce")
gemini = jsonl(a.run_dir / "gemini.jsonl")
prompts = jsonl(a.run_dir / "seat-prompts.jsonl")
calls = sorted(p for p in (a.run_dir / "bridge-calls").glob("*.jsonl") if p.name != "bridge.jsonl")
call_log = jsonl(calls[0]) if calls else []
call_events = [e["event"] for e in call_log]
bridge_log = jsonl(a.run_dir / "bridge-calls" / "bridge.jsonl")
bridge_events = [e["event"] for e in bridge_log]


def first(log, event):
    return next((e["data"] for e in log if e["event"] == event), None)


def last(log, event):
    return next((e["data"] for e in reversed(log) if e["event"] == event), None)
t_start = int(text("t_start") or 0)
eph = rows("ephemeral-messages.json")
dm = [r for r in rows("dm-messages.json") if r.get("created_at", 0) >= t_start]
caller = json.loads(text("caller.json") or "{}")

setups = [g for g in gemini if g["event"] == "setup"]
client_texts = [g["text"] for g in gemini if g["event"] == "client_text"]
asks = [r for r in dm if r.get("pubkey") == a.seat and tag(r, "voice-bridge") == "ask"]
answers = [r for r in dm if r.get("pubkey") == a.seat and tag(r, "voice-bridge") is None
           and f"ANSWER-{nonce}" in r.get("content", "")]
dm_transcripts = [r for r in dm if tag(r, "voice-bridge") == "transcript"]
lines = [r.get("content", "") for r in eph if r.get("pubkey") == a.seat]
seat_audio = [r for r in caller.get("received", []) if r["pubkey"] == a.seat]

real = text("gemini_mode") == "real"
lines_logged = [e["data"]["text"] for e in call_log if e["event"] == "transcript_line"]

# ── instrumentation: true of every run, however it ended ─────────────────────
start = first(call_log, "call_start") or {}
audio = last(call_log, "audio_stats") or {}
inbound = audio.get("in") or [{}]
ending = first(call_log, "call_end") or first(call_log, "call_failed") or {}
outcome_posts = [r for r in dm if tag(r, "voice-bridge") == "transcript"
                 and r.get("content", "").startswith("Voice call `")]

instrumented = {
    "call_start_names_the_build_and_the_config":
        bool(start.get("build_sha")) and start["build_sha"] != "unknown"
        and bool(start.get("pid")) and bool((start.get("config") or {}).get("relay_url")),
    "every_call_writes_an_ending":
        ("call_end" in call_events) != ("call_failed" in call_events)
        and bool(ending.get("reason") or ending.get("error"))
        and ending.get("duration_ms") is not None and bool(ending.get("phase")),
    "the_watcher_logs_its_own_run":
        all(e in bridge_events for e in ["up", "identity", "subscribed", "heartbeat"])
        and bool((first(bridge_log, "up") or {}).get("build_sha")),
    "the_heartbeat_proves_the_subscription":
        any(e["event"] == "heartbeat" and e["data"].get("rtt_ms") is not None for e in bridge_log),
    "the_bridge_log_survives_a_restart":
        bridge_events.count("up") >= 2 and "down" in bridge_events,
    # One relay connection per start, and no subscription churn. The relay
    # answers a client CLOSE with a CLOSED, and reading that as the huddle
    # subscription dying reconnects the watcher every few seconds.
    "the_watcher_holds_one_subscription":
        bridge_events.count("relay_connected") == bridge_events.count("up")
        and "subscription_closed" not in bridge_events,
    "an_outcome_reaches_the_parent": len(outcome_posts) == 1
        and "log `" in outcome_posts[0]["content"],
}

if a.fault != "none":
    # A forced failure: the call must name what stopped it, in the log and in
    # the parent. Nothing else about the call is expected to have worked.
    want = {
        "room_join": ("call_failed", "phase", "room_join"),
        "gemini_connect": ("call_failed", "phase", "gemini_connect"),
        "mid_call": ("call_end", "reason", "Gemini session lost"),
        "relay_gone": (None, None, ""),
    }[a.fault]
    record, field, expected = want
    cause = str(ending.get("error") or ending.get("reason") or "")
    checks = dict(instrumented)
    if a.fault == "relay_gone":
        # Either socket can notice first; both endings name their cause.
        del checks["an_outcome_reaches_the_parent"]  # the relay is gone
        del checks["the_bridge_log_survives_a_restart"]
        del checks["the_watcher_holds_one_subscription"]
        checks["the_call_ended_with_a_cause"] = bool(cause)
    else:
        checks["the_expected_record_was_written"] = record in call_events
        checks["it_names_the_stage_that_failed"] = expected in str(ending.get(field, ""))
        checks["it_names_the_cause"] = len(cause) > 20
    result_mode = a.fault
elif real:
    # The real model is not scripted: check the path, not the words.
    checks = {
        "gemini_session_opened": "gemini_connected" in call_events,
        "caller_speech_transcribed": any(l.startswith("Lloyd: ") for l in lines_logged),
        "gemini_spoke_transcribed": any(l.startswith("rock (voice, Gemini): ") for l in lines_logged),
        "ask_rock_called_and_posted": "ask_rock" in call_events and "ask_posted" in call_events,
        "seat_woke_once_on_the_ask": len(prompts) == 1 and len(asks) == 1 and prompts[0]["event"] == asks[0]["id"],
        "seat_answer_reached_gemini": "rock_answer" in call_events,
        "bridge_spoke_into_room": bool(seat_audio) and seat_audio[0]["frames"] > 100,
        "transcript_lines_tagged": bool(lines) and all(
            tag(r, "voice-bridge") == "transcript" for r in eph if r.get("pubkey") == a.seat),
        "full_transcript_in_parent": len(dm_transcripts) == 1,
    }
else:
  checks = {
      # Gemini side
      "gemini_setup_key_model_tool": bool(setups) and setups[0]["key_ok"]
          and setups[0]["model"] == "models/gemini-3.8-live" and setups[0]["tools"] == ["ask_rock"]
          and setups[0]["transcription"] and setups[0]["handle"] is None,
      "caller_audio_reached_gemini": any(g["event"] == "heard_caller" for g in gemini),
      "tool_answered_asked": any(g["event"] == "tool_response" and g["response"]["response"].get("status") == "asked"
                                 for g in gemini),
      "seat_answer_reached_gemini": any(t.startswith("rock answered") and f"ANSWER-{nonce}" in t for t in client_texts),
      "resumed_with_handle_after_go_away": any(s["session"] == 2 and s["handle"] == "handle-1" for s in setups),
      # Seat side: only the ask woke it
      "ask_tagged_and_mentions_seat": len(asks) == 1 and tag(asks[0], "p") == a.seat,
      "seat_woke_once_on_the_ask": len(prompts) == 1 and bool(asks) and prompts[0]["event"] == asks[0]["id"],
      "seat_answered_in_thread": len(answers) == 1 and bool(asks) and any(
          t[0] == "e" and t[1] == asks[0]["id"] for t in answers[0].get("tags", [])),
      # Transcript: every line tagged and labelled
      "transcript_lines_tagged": bool(lines) and all(
          tag(r, "voice-bridge") == "transcript" for r in eph if r.get("pubkey") == a.seat),
      "transcript_names_speakers": any(l.startswith("Lloyd: what is the build status") for l in lines)
          and any(l.startswith("rock (voice, Gemini): Hi Lloyd") for l in lines)
          and any(l.startswith("rock (voice, Gemini): rock says the build is green") for l in lines),
      "full_transcript_in_parent": len(dm_transcripts) == 1 and "Lloyd: what is the build status" in dm_transcripts[0]["content"],
      # Room side
      "bridge_spoke_into_room": bool(seat_audio) and seat_audio[0]["frames"] > 50 and seat_audio[0]["peak_dbov"] > -40,
      "call_log_complete": all(e in call_events for e in
                               ["call_start", "room_joined", "ask_posted", "rock_answer", "gemini_go_away", "call_end"])
          and any(e["event"] == "gemini_connected" and e["data"].get("resumed") for e in call_log),
  }

if a.fault == "none":
    checks.update(instrumented)
    checks.update({
        "audio_counted_in_both_directions":
            inbound[0].get("opus_frames", 0) > 50
            and inbound[0].get("pcm_samples_to_gemini", 0) > 0
            and (audio.get("from_gemini") or {}).get("audio_frames", 0) > 0
            and (audio.get("out") or {}).get("opus_frames", 0) > 50
            and (audio.get("out") or {}).get("silence_injections", 0) > 0,
        "timings_on_join_connect_answer_and_end":
            (first(call_log, "room_joined") or {}).get("join_ms") is not None
            and (first(call_log, "gemini_connected") or {}).get("connect_ms") is not None
            and (first(call_log, "rock_answer") or {}).get("waited_ms") is not None
            and ending.get("duration_ms") is not None,
        "the_answer_latency_is_measured":
            any(e["event"] == "response_latency"
                and e["data"].get("gemini_first_audio_ms") is not None for e in call_log),
        "the_watcher_saw_the_huddle_and_spawned_the_call":
            all(e in bridge_events for e in ["huddle_seen", "call_spawned", "call_ended"]),
    })
    result_mode = "real" if real else "fake"

result = {"pass": all(checks.values()), "mode": result_mode, "checks": checks, "run_dir": str(a.run_dir),
          "binaries": text("binaries"), "repo_commit": text("repo_commit"),
          "caller": caller, "transcript_lines": lines, "call_log_lines": lines_logged,
          "fault": a.fault, "audio_stats": audio, "bridge_events": bridge_events,
          "end_reason": ending.get("reason") or ending.get("error")}
with a.results.open("a") as out:
    out.write(json.dumps(result) + "\n")
print(json.dumps(result, indent=2))
sys.exit(0 if result["pass"] else 1)
