//! Calls whose transcript never reached the channel: a bridge killed mid-call,
//! or one whose call-end post the relay refused every time. Their call logs
//! hold every transcript line, so on start the bridge reads them back and
//! posts the outcome it could not post then.
//!
//! The rule is the one the call log already keeps: a log with a `call_start`
//! and no `outcome_posted` is a call the channel never heard the end of. The
//! recovery post is appended to that same log, so the next start leaves it
//! alone, and a log that still cannot be posted is tried again next time
//! until retention expires it.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};
use uuid::Uuid;

use crate::config::Names;
use crate::jsonl::JsonlLog;
use crate::outcome::CallOutcome;
use crate::relay_io::Publisher;

/// A log written more recently than this is left alone: it may still be
/// being written by a predecessor on its way out. Short on purpose: under
/// systemd the old unit is dead before the new one starts (`TimeoutStopSec`),
/// and the restart is 5 s away, so a crashed call's log has to be old enough
/// by the time the scan runs or it would wait for a restart that may never
/// come. Two bridges for one seat at once is not a supported shape.
const SETTLE: Duration = Duration::from_secs(5);

/// What a call log says about a call that needs its ending posted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Unposted {
    pub path: PathBuf,
    /// The key that wrote the log, from `call_start`. Absent in logs written
    /// before it was recorded; those are taken as this seat's.
    pub pubkey: Option<String>,
    pub parent: Uuid,
    pub ephemeral: Uuid,
    /// From `call_end`/`call_failed` when the call wrote one; otherwise the
    /// bridge stopped before the call did.
    pub end_reason: String,
    pub duration: Duration,
    pub counts: Value,
    /// `[HH:MM:SS] label: text` per line, from the `transcript_line` records.
    pub transcript: String,
}

/// Read one call log. `None` when it is not a call log, has no `call_start`,
/// or already carries an `outcome_posted`.
pub fn unposted_call(path: &Path, text: &str) -> Option<Unposted> {
    let records: Vec<Value> = text
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect();
    let find = |name: &str| records.iter().find(|r| r["event"] == name);
    let start = find("call_start")?;
    if find("outcome_posted").is_some() {
        return None;
    }
    let parent = start["data"]["parent"].as_str()?.parse().ok()?;
    let ephemeral = start["data"]["ephemeral"].as_str()?.parse().ok()?;
    let pubkey = start["data"]["pubkey"].as_str().map(str::to_owned);
    let ending = find("call_end").or_else(|| find("call_failed"));
    let (end_reason, duration, counts) = match ending {
        Some(record) => {
            let data = &record["data"];
            let reason = data["reason"]
                .as_str()
                .map(str::to_owned)
                .or_else(|| {
                    data["error"].as_str().map(|e| {
                        format!(
                            "failed during {}: {e}",
                            data["phase"].as_str().unwrap_or("?")
                        )
                    })
                })
                .unwrap_or_else(|| "ended".to_owned());
            (
                reason,
                Duration::from_millis(data["duration_ms"].as_u64().unwrap_or_default()),
                data.clone(),
            )
        }
        None => {
            let started = start["t"].as_str().and_then(parse_time);
            let last = records
                .last()
                .and_then(|r| r["t"].as_str())
                .and_then(parse_time);
            let duration = match (started, last) {
                (Some(a), Some(b)) => (b - a).to_std().unwrap_or_default(),
                _ => Duration::ZERO,
            };
            (
                "the bridge stopped before the call ended".to_owned(),
                duration,
                json!({}),
            )
        }
    };
    let transcript = records
        .iter()
        .filter(|r| r["event"] == "transcript_line")
        .filter_map(|r| {
            let text = r["data"]["text"].as_str()?;
            let at = r["t"]
                .as_str()
                .and_then(parse_time)
                .map(|t| t.format("%H:%M:%S").to_string())
                .unwrap_or_else(|| "??:??:??".to_owned());
            Some(format!("[{at}] {text}"))
        })
        .collect::<Vec<_>>()
        .join("\n");
    Some(Unposted {
        path: path.to_path_buf(),
        pubkey,
        parent,
        ephemeral,
        end_reason,
        duration,
        counts,
        transcript,
    })
}

fn parse_time(text: &str) -> Option<chrono::DateTime<chrono::Utc>> {
    chrono::DateTime::parse_from_rfc3339(text)
        .ok()
        .map(|t| t.with_timezone(&chrono::Utc))
}

/// Every call log in `dir` that still owes the channel its ending, oldest
/// first, skipping the watcher's own log, anything written in the last few
/// seconds, and any log another key wrote: two seats sharing a log directory
/// must not post, sign and be woken for each other's calls.
pub fn scan(dir: &Path, keep: &Path, me: &str) -> Vec<Unposted> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut found: Vec<Unposted> = entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            if path == keep || path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                return None;
            }
            // The rotated watcher log and frame traces are not call logs; the
            // `call_start` check below excludes them anyway, but cheaply.
            let name = path.file_name()?.to_str()?;
            if name.starts_with("bridge.jsonl") || name.ends_with(".frames.jsonl") {
                return None;
            }
            let settled = entry
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|m| SystemTime::now().duration_since(m).ok())
                .is_some_and(|age| age >= SETTLE);
            if !settled {
                return None;
            }
            let text = std::fs::read_to_string(&path).ok()?;
            let call = unposted_call(&path, &text)?;
            if call.pubkey.as_deref().is_some_and(|key| key != me) {
                return None;
            }
            Some(call)
        })
        .collect();
    found.sort_by(|a, b| a.path.cmp(&b.path));
    found
}

/// Post every unposted call's ending. Returns how many were posted.
pub async fn post_unposted(
    dir: &Path,
    keep: &Path,
    publisher: &Publisher,
    names: &Names,
    watcher: &mut JsonlLog,
) -> usize {
    let me = publisher.keys().public_key().to_hex();
    let mut posted = 0;
    for call in scan(dir, keep, &me) {
        let outcome = CallOutcome {
            parent: call.parent,
            ephemeral: call.ephemeral,
            end_reason: call.end_reason.clone(),
            duration: call.duration,
            peers: "see the log".to_owned(),
            asks: call.counts["asks"].as_u64().unwrap_or_default(),
            answers: call.counts["answers"].as_u64().unwrap_or_default(),
            timeouts: call.counts["timeouts"].as_u64().unwrap_or_default(),
            ask_failures: call.counts["ask_failures"].as_u64().unwrap_or_default(),
            reconnects: call.counts["reconnects"].as_u64().unwrap_or_default(),
            errors: call.counts["errors"].as_u64().unwrap_or_default(),
            log_path: call.path.display().to_string(),
            transcript: call.transcript.clone(),
            names: names.clone(),
            recovered: true,
        };
        let mut log = JsonlLog::open(&call.path);
        log.record(
            "recovery_attempt",
            json!({ "transcript_lines": call.transcript.lines().count(), "reason": call.end_reason }),
        );
        let result = outcome.post(publisher, &mut log).await;
        watcher.record(
            "recovered_call",
            json!({
                "log": call.path.display().to_string(),
                "ephemeral": call.ephemeral,
                "parent": call.parent,
                "posted": result.is_some(),
                "event_id": result.as_ref().map(|e| e.id.to_hex()),
                "transcript_lines": call.transcript.lines().count(),
            }),
        );
        if result.is_some() {
            posted += 1;
        }
    }
    posted
}

#[cfg(test)]
mod tests {
    use super::*;

    const PARENT: &str = "daa0371a-17fc-41a8-bb70-272b7c7e8be0";
    const EPH: &str = "0f1e2d3c-0000-4000-8000-000000000001";

    fn line(t: &str, event: &str, data: Value) -> String {
        json!({ "t": t, "event": event, "data": data }).to_string()
    }

    const ME: &str = "3b61e4e79e8eba0c142b2a07a6f968f4c8016c463bb3c0930933ea4da97998e0";

    fn start() -> String {
        line(
            "2026-09-21T10:00:00Z",
            "call_start",
            json!({ "parent": PARENT, "ephemeral": EPH, "pubkey": ME }),
        )
    }

    #[test]
    fn a_log_that_stops_mid_call_owes_its_transcript_and_says_the_bridge_stopped() {
        let text = [
            start(),
            line(
                "2026-09-21T10:00:05Z",
                "transcript_line",
                json!({ "text": "Lloyd: ship it" }),
            ),
            line(
                "2026-09-21T10:00:09Z",
                "transcript_line",
                json!({ "text": "rock (voice): one sec" }),
            ),
            line("2026-09-21T10:00:10Z", "audio_stats", json!({})),
        ]
        .join("\n");
        let call = unposted_call(Path::new("/x/a.jsonl"), &text).expect("unposted");
        assert_eq!(call.parent.to_string(), PARENT);
        assert_eq!(call.ephemeral.to_string(), EPH);
        assert_eq!(call.end_reason, "the bridge stopped before the call ended");
        assert_eq!(call.duration, Duration::from_secs(10));
        assert_eq!(
            call.transcript,
            "[10:00:05] Lloyd: ship it\n[10:00:09] rock (voice): one sec"
        );
    }

    #[test]
    fn a_log_whose_post_failed_keeps_the_ending_it_wrote() {
        let text = [
            start(),
            line("2026-09-21T10:00:05Z", "transcript_line", json!({ "text": "Lloyd: hi" })),
            line(
                "2026-09-21T10:01:00Z",
                "call_end",
                json!({ "reason": "the caller left", "duration_ms": 60000, "asks": 2, "answers": 1 }),
            ),
            line("2026-09-21T10:01:01Z", "outcome_post_failed", json!({ "error": "503" })),
        ]
        .join("\n");
        let call = unposted_call(Path::new("/x/b.jsonl"), &text).expect("unposted");
        assert_eq!(call.end_reason, "the caller left");
        assert_eq!(call.duration, Duration::from_secs(60));
        assert_eq!(call.counts["asks"], 2);
        assert_eq!(call.counts["answers"], 1);
    }

    #[test]
    fn a_failed_call_names_its_phase() {
        let text = [
            start(),
            line(
                "2026-09-21T10:01:00Z",
                "call_failed",
                json!({ "error": "boom", "phase": "gemini_connect", "duration_ms": 1200 }),
            ),
        ]
        .join("\n");
        let call = unposted_call(Path::new("/x/c.jsonl"), &text).expect("unposted");
        assert_eq!(call.end_reason, "failed during gemini_connect: boom");
        assert!(call.transcript.is_empty());
    }

    #[test]
    fn a_posted_log_a_foreign_log_and_garbage_are_left_alone() {
        let posted = [
            start(),
            line("2026-09-21T10:01:00Z", "outcome_posted", json!({})),
        ]
        .join("\n");
        assert!(unposted_call(Path::new("/x/d.jsonl"), &posted).is_none());
        let watcher = line("2026-09-21T10:00:00Z", "up", json!({}));
        assert!(unposted_call(Path::new("/x/bridge.jsonl"), &watcher).is_none());
        assert!(unposted_call(Path::new("/x/e.jsonl"), "not json\n{}\n").is_none());
    }

    #[test]
    fn scan_skips_fresh_logs_the_watcher_log_and_frame_traces() {
        let dir =
            std::env::temp_dir().join(format!("voice-bridge-recovery-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let old = filetime_old();
        let write = |name: &str, text: &str, backdate: bool| {
            let path = dir.join(name);
            std::fs::write(&path, text).expect("write");
            if backdate {
                let file = std::fs::File::open(&path).expect("open");
                file.set_modified(old).expect("mtime");
            }
            path
        };
        let owed = write("20260921T100000Z-aaaa.jsonl", &start(), true);
        write("20260921T110000Z-bbbb.jsonl", &start(), false); // still fresh
        let other_seat = line(
            "2026-09-21T10:00:00Z",
            "call_start",
            json!({ "parent": PARENT, "ephemeral": EPH, "pubkey": "ab".repeat(32) }),
        );
        write("20260921T090000Z-cccc.jsonl", &other_seat, true); // another key's call
        write("bridge.jsonl", &line("t", "up", json!({})), true);
        write("bridge.jsonl.1", &line("t", "up", json!({})), true);
        write("20260921T100000Z-aaaa.frames.jsonl", &start(), true);
        let found = scan(&dir, &dir.join("bridge.jsonl"), ME);
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].path, owed);
        assert_eq!(found[0].pubkey.as_deref(), Some(ME));
        // A log from before the key was recorded is this seat's.
        let legacy = line(
            "2026-09-21T10:00:00Z",
            "call_start",
            json!({ "parent": PARENT, "ephemeral": EPH }),
        );
        write("20260921T080000Z-dddd.jsonl", &legacy, true);
        assert_eq!(scan(&dir, &dir.join("bridge.jsonl"), ME).len(), 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn filetime_old() -> SystemTime {
        SystemTime::now() - Duration::from_secs(600)
    }
}
