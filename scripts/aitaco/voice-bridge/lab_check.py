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
# A call-end post that carries the transcript is signed `ask` so it wakes the
# seat, and labelled `t=huddle-transcript`; the asks proper carry no label.
asks = [r for r in dm if r.get("pubkey") == a.seat and tag(r, "voice-bridge") == "ask"
        and tag(r, "t") != "huddle-transcript"]
answers = [r for r in dm if r.get("pubkey") == a.seat and tag(r, "voice-bridge") is None
           and f"ANSWER-{nonce}" in r.get("content", "")]
recaps = [r for r in dm if r.get("pubkey") == a.seat and tag(r, "voice-bridge") is None
          and f"RECAP-{nonce}" in r.get("content", "")]
dm_transcripts = [r for r in dm if tag(r, "t") == "huddle-transcript"]
ask_prompts = [p for p in prompts if not p.get("wrap_up")]
wrap_up_prompts = [p for p in prompts if p.get("wrap_up")]
lines = [r.get("content", "") for r in eph if r.get("pubkey") == a.seat]
seat_audio = [r for r in caller.get("received", []) if r["pubkey"] == a.seat]

real = text("gemini_mode") == "real"
lines_logged = [e["data"]["text"] for e in call_log if e["event"] == "transcript_line"]

# ── instrumentation: true of every run, however it ended ─────────────────────
start = first(call_log, "call_start") or {}
audio = last(call_log, "audio_stats") or {}
inbound = audio.get("in") or [{}]
ending = first(call_log, "call_end") or first(call_log, "call_failed") or {}
outcome_posts = [r for r in dm if tag(r, "voice-bridge") in ("transcript", "ask")
                 and r.get("content", "").startswith("Voice call `")]

dm_id = text("dm")
discovered = [e["data"] for e in bridge_log if e["event"] == "dms_discovered"]

instrumented = {
    # No channel is configured: the bridge found the caller's DM with the seat
    # on the relay (kind:41001), which is what lets it serve any agent.
    "the_dm_was_discovered_not_configured":
        bool(discovered)
        and any(dm_id in (d.get("dms") or []) for d in discovered),
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

if text("desktop") == "1":
    # Desktop voices a huddle it started with the agent in it. The bridge saw
    # the huddle, recognised it, and did not join: no call, no Gemini session.
    skips = [e["data"] for e in bridge_log if e["event"] == "skipped"]
    checks = {
        "the_dm_was_discovered_not_configured": instrumented["the_dm_was_discovered_not_configured"],
        "the_bridge_saw_the_huddle": "huddle_seen" in bridge_events,
        "it_left_a_desktop_voiced_huddle_to_desktop":
            any(s.get("reason") == "desktop is voicing this huddle" for s in skips),
        "no_call_was_spawned": "call_spawned" not in bridge_events and not calls,
        "gemini_was_never_opened": not setups,
    }
    result = {"pass": all(checks.values()), "mode": "desktop", "checks": checks, "run_dir": str(a.run_dir),
              "bridge_events": bridge_events}
    with a.results.open("a") as out:
        out.write(json.dumps(result) + "\n")
    print(json.dumps(result, indent=2))
    sys.exit(0 if result["pass"] else 1)

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
        "gemini_spoke_transcribed": any(l.startswith("rock (voice): ") for l in lines_logged),
        "work_called_and_posted": "work" in call_events and "ask_posted" in call_events,
        "seat_woke_once_on_the_ask": len(ask_prompts) == 1 and len(asks) == 1 and ask_prompts[0]["event"] == asks[0]["id"],
        "seat_answer_reached_gemini": "seat_answer" in call_events,
        "bridge_spoke_into_room": bool(seat_audio) and seat_audio[0]["frames"] > 100,
        "transcript_lines_tagged": bool(lines) and all(
            tag(r, "voice-bridge") == "transcript" for r in eph if r.get("pubkey") == a.seat),
        "full_transcript_in_parent": len(dm_transcripts) == 1,
    }
else:
  checks = {
      # Gemini side
      "gemini_setup_key_model_tool": bool(setups) and setups[0]["key_ok"]
          and setups[0]["model"] == "models/gemini-3.8-live" and setups[0]["tools"] == ["work"]
          and setups[0]["transcription"] and setups[0]["handle"] is None,
      "caller_audio_reached_gemini": any(g["event"] == "heard_caller" for g in gemini),
      # The tool is answered at once and quietly, so "one sec" never waits on
      # the relay round trip.
      "tool_answered_started_and_silent": any(
          g["event"] == "tool_response" and g["response"]["response"].get("status") == "started"
          and g["response"]["response"].get("scheduling") == "SILENT" for g in gemini),
      "seat_answer_reached_gemini": any(t.startswith("Your work came back") and f"ANSWER-{nonce}" in t for t in client_texts),
      "resumed_with_handle_after_go_away": any(s["session"] == 2 and s["handle"] == "handle-1" for s in setups),
      # The voice is the seat: nothing handed to Gemini speaks of it in the
      # third person.
      "nothing_reaches_the_voice_in_the_third_person": bool(client_texts) and not any(
          "rock answered" in t or "checking with rock" in t or "rock is still working" in t for t in client_texts),
      # Seat side: the ask woke it, with the call so far in hand
      "ask_tagged_and_mentions_seat": len(asks) == 1 and tag(asks[0], "p") == a.seat,
      "the_ask_carries_the_call_so_far": bool(asks)
          and asks[0]["content"].startswith("Lloyd is on a voice call with you")
          and "rock (voice): Hi Lloyd" in asks[0]["content"]
          and "> what is the build status" in asks[0]["content"],
      "seat_woke_once_on_the_ask": len(ask_prompts) == 1 and bool(asks) and ask_prompts[0]["event"] == asks[0]["id"],
      "seat_answered_in_thread": len(answers) == 1 and bool(asks) and any(
          t[0] == "e" and t[1] == asks[0]["id"] for t in answers[0].get("tags", [])),
      # Transcript: every line tagged and labelled with the profile names
      "transcript_lines_tagged": bool(lines) and all(
          tag(r, "voice-bridge") == "transcript" for r in eph if r.get("pubkey") == a.seat),
      "transcript_names_speakers": any(l.startswith("Lloyd: what is the build status") for l in lines)
          and any(l.startswith("rock (voice): Hi Lloyd") for l in lines)
          and any(l.startswith("rock (voice): The build is green") for l in lines),
      "full_transcript_in_parent": len(dm_transcripts) == 1 and "Lloyd: what is the build status" in dm_transcripts[0]["content"],
      # The call is recorded: the transcript post wakes the seat, which
      # replies in that thread with the recap.
      "the_call_end_woke_the_seat_to_record_it": len(dm_transcripts) == 1
          and tag(dm_transcripts[0], "voice-bridge") == "ask" and tag(dm_transcripts[0], "p") == a.seat
          and "buzz issues create" in dm_transcripts[0]["content"]
          and len(wrap_up_prompts) == 1 and wrap_up_prompts[0]["event"] == dm_transcripts[0]["id"],
      "the_seat_recapped_in_the_transcript_thread": len(recaps) == 1 and bool(dm_transcripts) and any(
          t[0] == "e" and t[1] == dm_transcripts[0]["id"] for t in recaps[0].get("tags", [])),
      # The voice was given the channel's recent conversation before it spoke.
      "the_history_was_fetched_before_the_call": (first(call_log, "history") or {}).get("lines") is not None
          and "history_failed" not in call_events,
      # Room side
      "bridge_spoke_into_room": bool(seat_audio) and seat_audio[0]["frames"] > 50 and seat_audio[0]["peak_dbov"] > -40,
      "call_log_complete": all(e in call_events for e in
                               ["call_start", "room_joined", "ask_posted", "seat_answer", "gemini_go_away", "call_end"])
          and any(e["event"] == "gemini_connected" and e["data"].get("resumed") for e in call_log),
  }

seat_mode_top = text("seat_mode") or "live"
if a.fault == "none" and seat_mode_top == "limited":
    # The seat woke and its provider refused on a usage limit. buzz-acp must
    # hold the trigger rather than retry it to death, and say so exactly once
    # in the ask's own thread — the line the bridge reads aloud.
    held = [r for r in dm
            if r.get("pubkey") == a.seat
            and tag(r, "voice-bridge") is None
            and "Nothing was lost" in r.get("content", "")]
    dead_letters = [r for r in dm if "\u26a0\ufe0f I couldn't process" in r.get("content", "")]
    checks = {
        k: v for k, v in checks.items()
        # The call-end wake is published and delivered, but buzz-acp holds it
        # behind the usage limit without a prompt, so neither the recap nor
        # the wrap-up prompt can be seen in this run.
        if k not in {"seat_answer_reached_gemini", "seat_answered_in_thread",
                     "transcript_names_speakers", "call_log_complete",
                     "resumed_with_handle_after_go_away",
                     "the_call_end_woke_the_seat_to_record_it",
                     "the_seat_recapped_in_the_transcript_thread"}
    }
    checks.update({
        "the_seat_woke_and_could_not_run": len(ask_prompts) >= 1 and not answers,
        "the_held_trigger_was_announced_once": len(held) == 1,
        "the_notice_went_to_the_ask_thread":
            bool(held) and bool(asks)
            and any(t[0] == "e" and t[1] == asks[0]["id"]
                    for t in held[0].get("tags", [])),
        # rock's constraint: a hold is not a dead-letter, and nothing was
        # discarded, so the ⚠️ text must never appear.
        "no_dead_letter_notice_was_posted": not dead_letters,
        # The point of putting the notice in the ask's thread: the bridge reads
        # replies to its ask, so this is what the caller HEARS instead of
        # silence or a false "still working". No progress line ever fires,
        # because the refusal comes back in about a second.
        "the_voice_was_told_the_work_is_held":
            any(t.startswith("Your work came back") and "Nothing was lost" in t
                for t in client_texts),
        "no_progress_line_claimed_work":
            not [e for e in call_log if e["event"] == "waiting_tick"],
        "the_notice_names_the_reset_and_needs_no_resend":
            bool(held)
            and "UTC" in held[0]["content"]
            and "Please re-send" not in held[0]["content"],
        # It is read aloud in the seat's voice, so it quotes the provider and
        # nothing of ours: AcpError's Display frames the message as "Agent
        # reported error (code -32603): …", which Gemini speaks as "agent
        # reported error code minus three two six zero three".
        "the_spoken_line_quoted_the_provider_not_our_wrapper":
            bool(held)
            and "You've hit your session limit" in held[0]["content"]
            and "Agent reported error" not in held[0]["content"]
            and "-32603" not in held[0]["content"],
        # Same bar as the silent run: the call itself still worked, only the
        # answer is missing.
        "audio_counted_in_both_directions_through_the_wait":
            inbound[0].get("opus_frames", 0) > 50
            and inbound[0].get("pcm_samples_to_gemini", 0) > 0
            and (audio.get("from_gemini") or {}).get("audio_frames", 0) > 0
            and (audio.get("out") or {}).get("opus_frames", 0) >= 50
            and (audio.get("out") or {}).get("silence_injections", 0) > 0,
        "timings_on_join_connect_and_end":
            (first(call_log, "room_joined") or {}).get("join_ms") is not None
            and (first(call_log, "gemini_connected") or {}).get("connect_ms") is not None
            and ending.get("duration_ms") is not None,
    })

if a.fault == "none" and seat_mode_top == "silent":
    # The seat ran without the self-wake opt-in, so the ask reached a seat that
    # never picked it up. Everything about the call is expected to have worked
    # except the answer, which must never arrive — that absence is the point.
    # Everything downstream of an answer is dropped, and replaced with the
    # same assertion minus the answer — the bar moves off the reply, not down.
    # `resumed_with_handle_after_go_away` goes because the scripted goAway
    # follows the answer, so no resume is reached in this run.
    checks = {
        k: v for k, v in checks.items()
        if k not in {"seat_answer_reached_gemini", "seat_woke_once_on_the_ask",
                     "seat_answered_in_thread", "transcript_names_speakers",
                     "call_log_complete", "resumed_with_handle_after_go_away",
                     "the_call_end_woke_the_seat_to_record_it",
                     "the_seat_recapped_in_the_transcript_thread"}
    }
    checks.update({
        "the_ask_was_published_and_addressed_to_the_seat":
            len(asks) == 1 and tag(asks[0], "p") == a.seat,
        "nothing_ever_picked_the_ask_up": not prompts and not answers,
        "the_call_still_ran_and_ended_cleanly":
            all(e in call_events for e in ["call_start", "room_joined", "ask_posted", "call_end"])
            and "seat_answer" not in call_events,
        # Both directions still carry audio through a wait that never ends.
        # Outbound is the greeting only — an answer is what makes it grow —
        # so this is `>=` where the live run can demand more.
        "audio_counted_in_both_directions_through_the_wait":
            inbound[0].get("opus_frames", 0) > 50
            and inbound[0].get("pcm_samples_to_gemini", 0) > 0
            and (audio.get("from_gemini") or {}).get("audio_frames", 0) > 0
            and (audio.get("out") or {}).get("opus_frames", 0) >= 50
            and (audio.get("out") or {}).get("silence_injections", 0) > 0,
        "timings_on_join_connect_and_end":
            (first(call_log, "room_joined") or {}).get("join_ms") is not None
            and (first(call_log, "gemini_connected") or {}).get("connect_ms") is not None
            and ending.get("duration_ms") is not None,
    })

if a.fault == "none":
    checks.update(instrumented)
    if seat_mode_top in ("silent", "limited"):
        # Re-stated above without the answer; adding the originals back here
        # would reintroduce the two that cannot hold in a run with no reply.
        pass
    else:
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
            and (first(call_log, "seat_answer") or {}).get("waited_ms") is not None
            and ending.get("duration_ms") is not None,
        # buzz#63: the receive loop folds every inbound frame into the
        # per-peer arrival block. The fake caller sends one contiguous stream,
        # so the block must exist, have counted continuity, and report no loss.
        # Without this, deleting the `observe` call compiles and fails nothing.
        "inbound_arrival_is_counted_per_peer":
            isinstance(inbound[0].get("arrival"), dict)
            and inbound[0]["arrival"].get("seq_missing") == 0
            and inbound[0]["arrival"].get("seq_regressions") == 0
            and inbound[0]["arrival"].get("gap_worst_ms", 0) > 0,
        "the_answer_latency_is_measured":
            any(e["event"] == "response_latency"
                and e["data"].get("gemini_first_audio_ms") is not None for e in call_log),
        "the_watcher_saw_the_huddle_and_spawned_the_call":
            all(e in bridge_events for e in ["huddle_seen", "call_spawned", "call_ended"]),
    })
    result_mode = "real" if real else "fake"

    # ── the wait: only when the run was set up to have one ───────────────────
    delay = float(text("answer_delay_s") or 0)
    progress_s = float(text("progress_s") or 10)
    seat_mode = text("seat_mode") or "live"
    if delay >= progress_s + 2 and seat_mode != "limited":
        ticks = [e["data"] for e in call_log if e["event"] == "waiting_tick"]
        spoken = [t for t in ticks if t.get("spoken")]
        states = {t.get("state") for t in ticks}
        # The line the voice was actually handed, per state. Asserting on the
        # opening words is asserting the claim that was made about the seat.
        working_said = [g["text"] for g in gemini
                        if g["event"] == "client_text"
                        and g["text"].startswith("You are still working")]
        unpicked_said = [g["text"] for g in gemini
                         if g["event"] == "client_text"
                         and g["text"].startswith("Your work has not started yet")]
        said = working_said if seat_mode == "live" else unpicked_said
        closed = next((g for g in gemini if g["event"] == "closed" and g["session"] == 1), {})
        bed_frames = (audio.get("out") or {}).get("bed_frames", 0)
        # The room track ran for the length of the wait at 50 frames/s; allow
        # the delay before it starts and the answer arriving early.
        expect_bed = (delay - 2) * 50 * 0.5
        checks.update({
            # The number spoken is the bridge's, not the model's: it lands
            # inside the wait, rises, and rises by the configured interval.
            "the_wait_is_counted_by_the_bridge":
                bool(ticks)
                # With no answer coming, the wait runs to the end of the call,
                # so only the live run has `delay` as its ceiling.
                and all(0 < t["elapsed_secs"] <= delay + 2 for t in ticks
                        if seat_mode == "live")
                and [t["elapsed_secs"] for t in ticks] == sorted(t["elapsed_secs"] for t in ticks)
                and all(progress_s - 1 <= b["elapsed_secs"] - a["elapsed_secs"] <= progress_s + 1
                        for a, b in zip(ticks, ticks[1:])),
            "a_progress_line_reached_the_voice": bool(spoken) and len(said) >= 1,
            # The point of the three states: a claim of work needs evidence of
            # a turn. With the seat woken, every tick saw its typing indicator
            # and said so; with the opt-in dropped, nothing ever picked the ask
            # up and no tick may claim otherwise.
            "the_wait_line_claimed_work_only_with_evidence":
                (states == {"working"} and not unpicked_said) if seat_mode == "live"
                else (states == {"not_picked_up"} and not working_said),
            "the_voice_was_given_only_the_elapsed_seconds":
                bool(said) and all(f"been {t['elapsed_secs']} seconds" in " ".join(said)
                                   for t in spoken[:len(said)]),
            "the_working_sound_played_into_the_room": bed_frames >= expect_bed,
            # rock's one hard constraint. Over the span where the caller was
            # not talking, the room heard a keyboard and Gemini's input has to
            # have been silence and nothing else — its voice-activity
            # detection reads that silence as the end of a turn.
            "the_working_sound_never_reached_gemini":
                closed.get("chunks_while_quiet", 0) > 100
                and closed.get("peak_while_quiet", 1) == 0,
        })

result = {"pass": all(checks.values()), "mode": result_mode, "checks": checks, "run_dir": str(a.run_dir),
          "binaries": text("binaries"), "repo_commit": text("repo_commit"),
          "caller": caller, "transcript_lines": lines, "call_log_lines": lines_logged,
          "fault": a.fault, "seat_mode": text("seat_mode") or "live",
          "audio_stats": audio, "bridge_events": bridge_events,
          "waiting_ticks": [e["data"] for e in call_log if e["event"] == "waiting_tick"],
          "end_reason": ending.get("reason") or ending.get("error")}
with a.results.open("a") as out:
    out.write(json.dumps(result) + "\n")
print(json.dumps(result, indent=2))
sys.exit(0 if result["pass"] else 1)
