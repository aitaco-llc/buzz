//! The call-end post: one line in the parent channel saying how the call
//! ended, with the transcript under it, and — when anything was said — the
//! seat's own wake-up to turn that transcript into recorded work.
//!
//! This is the artifact someone reads after a call, and the only place the
//! huddle's speech reaches durable storage: the huddle channel expires. So it
//! is posted whether the call ended cleanly or failed, retried when the relay
//! refuses it, and posted again on the next start by `recovery.rs` when the
//! bridge died before it could.

use anyhow::Result;
use nostr::{Event, EventBuilder};
use serde_json::{json, Value};
use std::time::Duration;
use uuid::Uuid;

use crate::config::Names;
use crate::jsonl::JsonlLog;
use crate::relay_io::{Provenance, Publisher};

/// The label a call-end post carries when it holds what was said.
///
/// A reader of the channel treats a tagged post as the humans' own words,
/// spoken rather than typed — the only place huddle speech reaches the relay.
/// An untagged call-end post is the bridge's own stats line and nothing more,
/// so the tag goes on only when there is a transcript under it: a call nobody
/// spoke in must not offer an empty transcript as if it were input.
pub const HUDDLE_TRANSCRIPT_TAG: &str = "huddle-transcript";

/// The post is capped well under the relay's 64 KiB content limit. Bytes,
/// because that is what the SDK checks: a transcript full of curly quotes
/// and ellipses is three bytes a character, and a post refused for size is a
/// transcript that never reaches the channel.
const BODY_BYTE_CAP: usize = 60 * 1024;
/// What replaces the transcript lines that did not fit.
const OMITTED_MARKER: &str = "… (earlier lines omitted; the call log has all of them)";

/// Publish attempts before giving up on this process; `recovery.rs` picks up
/// the rest on the next start. The relay's own timeout is 15 s per attempt.
const PUBLISH_ATTEMPTS: u32 = 3;

/// Everything the post says, gathered by the call loop or read back from a
/// call log.
#[derive(Debug, Clone)]
pub struct CallOutcome {
    pub parent: Uuid,
    pub ephemeral: Uuid,
    pub end_reason: String,
    pub duration: Duration,
    /// "Lloyd, 2c4a588a" — who else was on the line, or "none".
    pub peers: String,
    pub asks: u64,
    pub answers: u64,
    pub timeouts: u64,
    pub ask_failures: u64,
    pub reconnects: u64,
    pub errors: u64,
    pub log_path: String,
    /// The whole call, `[HH:MM:SS] name: text` per line, or empty.
    pub transcript: String,
    pub names: Names,
    /// True when this post is written from a log after the bridge restarted,
    /// so the reader knows why it is late and may be incomplete.
    pub recovered: bool,
}

impl CallOutcome {
    pub fn has_transcript(&self) -> bool {
        !self.transcript.trim().is_empty()
    }

    /// The seat is woken to record the call only when there is a call to
    /// record. A silent call is a stats line and wakes nobody.
    pub fn wakes_seat(&self) -> bool {
        self.has_transcript()
    }

    pub fn body(&self) -> String {
        let Names {
            agent,
            human,
            voice,
        } = &self.names;
        let recovered = if self.recovered {
            " (posted after the bridge restarted; the call log is the full record)"
        } else {
            ""
        };
        let mut body = format!(
            "Voice call `{}` ended: {}{recovered}. {} · peers: {} · asks {} asked / {} answered / {} timed out / {} failed · {} · {} · log `{}`",
            &self.ephemeral.to_string()[..8],
            self.end_reason,
            human_duration(self.duration),
            self.peers,
            self.asks,
            self.answers,
            self.timeouts,
            self.ask_failures,
            plural(self.reconnects, "Gemini reconnect"),
            plural(self.errors, "error"),
            self.log_path,
        );
        if self.has_transcript() {
            body.push_str(&format!(
                "\n\n{agent}: this call is over and the huddle channel expires, so this post is the record of it. \
                 Do this now, as yourself, on the transcript below:\n\
                 1. Record every action item, commitment and decision durably. Tasks you own go to `buzz issues create` on the right project \
                 (or your own plan if there is no project); things worth remembering go to `buzz mem set`; anything a teammate owns gets \
                 handed to them in their channel.\n\
                 2. Reply in this thread with a short written recap for {human}: what was decided, each action item with its owner, and \
                 anything you promised. If there were no action items, say so in one line. No greeting, no filler.\n\n\
                 Transcript, {human} and {voice}. Written by the voice bridge; lines labelled {voice} are you, speaking on the call.\n\n"
            ));
            body.push_str(&fit_transcript(
                &self.transcript,
                BODY_BYTE_CAP.saturating_sub(body.len()),
            ));
        }
        body
    }

    /// The signed shape: a plain channel message; tagged `t=huddle-transcript`
    /// and addressed to the seat when it carries the transcript.
    pub fn message(&self, seat_pubkey_hex: &str) -> Result<EventBuilder> {
        let body = self.body();
        let mentions: &[&str] = if self.wakes_seat() {
            &[seat_pubkey_hex]
        } else {
            &[]
        };
        let builder = buzz_sdk::build_message(self.parent, &body, None, mentions, false, &[], &[])?;
        if self.has_transcript() {
            Ok(builder.tag(nostr::Tag::parse(["t", HUDDLE_TRANSCRIPT_TAG])?))
        } else {
            Ok(builder)
        }
    }

    /// The provenance the post is signed with. `ask` is the value that wakes
    /// the seat (`BUZZ_ACP_SELF_WAKE_TAG=voice-bridge=ask`); a stats-only post
    /// is `transcript`, which wakes nothing.
    pub fn provenance(&self) -> Provenance {
        if self.wakes_seat() {
            Provenance::Ask
        } else {
            Provenance::Transcript
        }
    }

    /// Publish with bounded retries, recording the result in `log` either way.
    /// `outcome_posted` is the record `recovery.rs` looks for; a log without it
    /// is a call whose transcript never reached the channel.
    pub async fn post(&self, publisher: &Publisher, log: &mut JsonlLog) -> Option<Event> {
        let seat = publisher.keys().public_key().to_hex();
        let mut last_error = String::new();
        for attempt in 1..=PUBLISH_ATTEMPTS {
            let result = match self.message(&seat) {
                Ok(builder) => publisher.publish(builder, self.provenance()).await,
                Err(error) => {
                    // A body the SDK refuses will not be fixed by retrying.
                    log.record(
                        "outcome_post_failed",
                        json!({ "error": error.to_string(), "attempt": attempt, "final": true }),
                    );
                    return None;
                }
            };
            match result {
                Ok(event) => {
                    log.record(
                        "outcome_posted",
                        json!({
                            "event_id": event.id.to_hex(),
                            "with_transcript": self.has_transcript(),
                            "wakes_seat": self.wakes_seat(),
                            "recovered": self.recovered,
                            "attempt": attempt,
                        }),
                    );
                    return Some(event);
                }
                Err(error) => {
                    last_error = error.to_string();
                    tracing::warn!(attempt, error = %last_error, "call-end post refused");
                    if attempt < PUBLISH_ATTEMPTS {
                        tokio::time::sleep(Duration::from_secs(2 * u64::from(attempt))).await;
                    }
                }
            }
        }
        log.record(
            "outcome_post_failed",
            json!({ "error": last_error, "attempts": PUBLISH_ATTEMPTS, "final": false }),
        );
        None
    }

    pub fn counts(&self) -> Value {
        json!({
            "asks": self.asks,
            "answers": self.answers,
            "timeouts": self.timeouts,
            "ask_failures": self.ask_failures,
            "reconnects": self.reconnects,
            "errors": self.errors,
        })
    }
}

/// The transcript within `budget` bytes, dropping the oldest lines first: the
/// end of a call is where its decisions are, and the instructions above it
/// must survive whole. A marker says what went.
fn fit_transcript(transcript: &str, budget: usize) -> String {
    if transcript.len() <= budget {
        return transcript.to_owned();
    }
    let lines: Vec<&str> = transcript.lines().collect();
    let mut start = 0;
    let mut size: usize =
        OMITTED_MARKER.len() + 1 + lines.iter().map(|l| l.len() + 1).sum::<usize>();
    while start < lines.len() && size > budget {
        size -= lines[start].len() + 1;
        start += 1;
    }
    let mut out = OMITTED_MARKER.to_owned();
    for line in &lines[start..] {
        out.push('\n');
        out.push_str(line);
    }
    out
}

/// "1 error", "2 errors". The outcome line is read by a person.
pub fn plural(count: u64, noun: &str) -> String {
    match count {
        1 => format!("1 {noun}"),
        other => format!("{other} {noun}s"),
    }
}

pub fn human_duration(duration: Duration) -> String {
    let seconds = duration.as_secs();
    if seconds >= 60 {
        format!("{}m{:02}s", seconds / 60, seconds % 60)
    } else {
        format!("{}.{:01}s", seconds, duration.subsec_millis() / 100)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::Keys;

    fn outcome(transcript: &str) -> CallOutcome {
        CallOutcome {
            parent: Uuid::new_v4(),
            ephemeral: Uuid::new_v4(),
            end_reason: "the caller left".into(),
            duration: Duration::from_secs(72),
            peers: "Lloyd".into(),
            asks: 1,
            answers: 1,
            timeouts: 0,
            ask_failures: 0,
            reconnects: 0,
            errors: 0,
            log_path: "/tmp/x.jsonl".into(),
            transcript: transcript.into(),
            names: Names {
                agent: "rock".into(),
                human: "Lloyd".into(),
                voice: "rock (voice)".into(),
            },
            recovered: false,
        }
    }

    fn tags(event: &Event) -> Vec<Vec<String>> {
        event.tags.iter().map(|t| t.clone().to_vec()).collect()
    }

    #[test]
    fn a_post_with_words_under_it_is_tagged_addressed_and_wakes_the_seat() {
        let keys = Keys::generate();
        let me = keys.public_key().to_hex();
        let with = outcome("[10:00:00] Lloyd: ship it\n[10:00:03] rock (voice): on it");
        assert!(with.wakes_seat());
        assert_eq!(with.provenance(), Provenance::Ask);
        let event = with
            .message(&me)
            .expect("build")
            .sign_with_keys(&keys)
            .expect("sign");
        let tags = tags(&event);
        assert!(tags.contains(&vec!["t".to_owned(), HUDDLE_TRANSCRIPT_TAG.to_owned()]));
        assert!(
            tags.iter()
                .any(|t| t.first().map(String::as_str) == Some("p") && t.get(1) == Some(&me)),
            "the seat is addressed so the wake has a mention: {tags:?}"
        );
        assert!(event.content.contains("rock: this call is over"));
        assert!(event.content.contains("buzz issues create"));
        assert!(event.content.contains("Reply in this thread"));
        assert!(event.content.ends_with("on it"));
    }

    #[test]
    fn a_stats_only_post_carries_no_label_no_mention_and_wakes_nobody() {
        let keys = Keys::generate();
        let me = keys.public_key().to_hex();
        let without = outcome("  ");
        assert!(!without.wakes_seat());
        assert_eq!(without.provenance(), Provenance::Transcript);
        let event = without
            .message(&me)
            .expect("build")
            .sign_with_keys(&keys)
            .expect("sign");
        let tags = tags(&event);
        assert!(!tags
            .iter()
            .any(|t| t.first().map(String::as_str) == Some("t")));
        assert!(!tags
            .iter()
            .any(|t| t.first().map(String::as_str) == Some("p")));
        assert!(tags
            .iter()
            .any(|t| t.first().map(String::as_str) == Some("h")));
        assert!(!event.content.contains("Transcript"));
        assert!(event.content.starts_with("Voice call `"));
        assert!(event.content.contains("1m12s"));
    }

    #[test]
    fn a_recovered_post_says_so_and_a_long_transcript_keeps_its_end_within_the_byte_cap() {
        // Three-byte characters throughout: a char cap would pass the SDK's
        // byte limit by half again and the post would be refused forever.
        let lines: Vec<String> = (0..6_000)
            .map(|i| format!("[10:00:00] Lloyd: “line {i}” …"))
            .collect();
        let mut long = outcome(&lines.join("\n"));
        long.recovered = true;
        let body = long.body();
        assert!(body.contains("posted after the bridge restarted"));
        assert!(body.len() <= BODY_BYTE_CAP, "{} bytes", body.len());
        assert!(
            body.contains("buzz issues create"),
            "the instructions survive whole"
        );
        assert!(body.contains(OMITTED_MARKER));
        assert!(body.ends_with("“line 5999” …"), "the newest line is kept");
        assert!(!body.contains("“line 0”"), "the oldest line went first");
        assert!(buzz_sdk::build_message(Uuid::new_v4(), &body, None, &[], false, &[], &[]).is_ok());

        let short = outcome("[10:00:00] Lloyd: hi").body();
        assert!(!short.contains(OMITTED_MARKER));
    }

    #[test]
    fn counts_and_durations_read_as_a_human_would_say_them() {
        assert_eq!(plural(0, "error"), "0 errors");
        assert_eq!(plural(1, "Gemini reconnect"), "1 Gemini reconnect");
        assert_eq!(plural(2, "Gemini reconnect"), "2 Gemini reconnects");
        assert_eq!(human_duration(Duration::from_millis(3400)), "3.4s");
        assert_eq!(human_duration(Duration::from_secs(72)), "1m12s");
        assert_eq!(human_duration(Duration::from_secs(3600)), "60m00s");
    }
}
