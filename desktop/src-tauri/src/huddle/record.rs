//! The record of a huddle, posted when it ends.
//!
//! A huddle's transcript lives in its ephemeral channel, which is archived the
//! moment the huddle ends: nothing an agent heard on the call is ever turned
//! into work unless someone asks. So when the last human leaves, Desktop posts
//! one message in the parent channel, addressed to every agent that was in the
//! huddle, carrying the transcript and asking them to record the action items
//! and reply with a recap. The phone path gets the same from the voice bridge
//! (`crates/buzz-voice-bridge/src/outcome.rs`); this is Desktop's half.
//!
//! Posted by the human who ended the huddle, so it passes every agent's author
//! gate as their owner's own words, and tagged `t=huddle-transcript` like the
//! bridge's, so either kind of call can be found the same way.

use std::collections::{BTreeSet, HashMap};

use nostr::{Event, Tag};

use crate::{app_state::AppState, events, relay::submit_event};

use super::relay_api::{fetch_channel_members, parse_channel_uuid};

/// The label a record post carries.
pub(crate) const HUDDLE_TRANSCRIPT_TAG: &str = "huddle-transcript";
/// Under the relay's 64 KiB content limit, in bytes: the transcript is cut
/// from the front, because the end of a call is where its decisions are.
const BODY_BYTE_CAP: usize = 60 * 1024;
const OMITTED: &str = "… (earlier lines omitted; the archived huddle channel has all of them)";
/// Publish attempts before giving up; the transcript stays in the archive.
const ATTEMPTS: u32 = 3;

/// The record post's text, or `None` when there is nobody to hand it to or
/// nothing was said. `agents` are display names, in mention order.
pub(crate) fn record_body(agents: &[String], lines: &[String]) -> Option<String> {
    if agents.is_empty() || lines.iter().all(|l| l.trim().is_empty()) {
        return None;
    }
    let mentions = agents
        .iter()
        .map(|name| format!("@{name}"))
        .collect::<Vec<_>>()
        .join(" ");
    let who = if agents.len() == 1 {
        "Do this now, as yourself:".to_owned()
    } else {
        format!(
            "Each of you records what you own; @{} writes the recap. Do this now:",
            agents[0]
        )
    };
    let mut body = format!(
        "{mentions} this huddle is over and its channel is archived, so this post is the record \
         of it. {who}\n\
         1. Record every action item, commitment and decision durably: tasks with `buzz issues \
         create` on the right project, things to remember with `buzz mem set`, and anything a \
         teammate owns handed to them in their channel.\n\
         2. Reply in this thread with a short written recap: what was decided, each action item \
         with its owner, and anything promised. If there were no action items, say so in one \
         line. No greeting.\n\nTranscript:\n\n"
    );
    body.push_str(&fit(lines, BODY_BYTE_CAP.saturating_sub(body.len())));
    Some(body)
}

/// The lines within `budget` bytes, oldest dropped first, with a marker.
fn fit(lines: &[String], budget: usize) -> String {
    let whole = lines.join("\n");
    if whole.len() <= budget {
        return whole;
    }
    let mut start = 0;
    let mut size = OMITTED.len() + 1 + whole.len();
    while start < lines.len() && size > budget {
        size -= lines[start].len() + 1;
        start += 1;
    }
    let mut out = OMITTED.to_owned();
    for line in &lines[start..] {
        out.push('\n');
        out.push_str(line);
    }
    out
}

/// `[HH:MM:SS] name: text` for each spoken or written message, oldest first.
/// System notices are not speech and are left out.
pub(crate) fn transcript_lines(events: &[Event], names: &HashMap<String, String>) -> Vec<String> {
    let mut sorted: Vec<&Event> = events
        .iter()
        .filter(|e| e.kind.as_u16() == 9)
        .filter(|e| {
            let text = e.content.trim();
            !text.is_empty() && !text.starts_with("[System]")
        })
        .collect();
    sorted.sort_by_key(|e| (e.created_at, e.id));
    sorted
        .into_iter()
        .map(|e| {
            let pubkey = e.pubkey.to_hex();
            let name = names
                .get(&pubkey)
                .cloned()
                .unwrap_or_else(|| pubkey.chars().take(8).collect());
            let at = chrono::DateTime::<chrono::Utc>::from_timestamp(
                i64::try_from(e.created_at.as_secs()).unwrap_or_default(),
                0,
            )
            .map(|t| t.format("%H:%M:%S").to_string())
            .unwrap_or_default();
            let text = e.content.split_whitespace().collect::<Vec<_>>().join(" ");
            format!("[{at}] {name}: {text}")
        })
        .collect()
}

/// Display names from kind:0 profiles: `display_name`, else `name`.
fn profile_names(events: &[Event]) -> HashMap<String, String> {
    let mut newest: HashMap<String, &Event> = HashMap::new();
    for event in events.iter().filter(|e| e.kind.as_u16() == 0) {
        let key = event.pubkey.to_hex();
        if newest
            .get(&key)
            .is_none_or(|current| event.created_at > current.created_at)
        {
            newest.insert(key, event);
        }
    }
    newest
        .into_iter()
        .filter_map(|(pubkey, event)| {
            let profile: serde_json::Value = serde_json::from_str(&event.content).ok()?;
            let name = ["display_name", "name"]
                .iter()
                .filter_map(|field| profile[field].as_str())
                .map(str::trim)
                .find(|s| !s.is_empty())?;
            Some((pubkey, name.to_owned()))
        })
        .collect()
}

/// Post the huddle's record to its parent channel. Best-effort by design —
/// the huddle is ending either way — but retried, and every outcome logged:
/// the transcript also remains in the archived huddle channel.
pub(crate) async fn post_huddle_record(parent: &str, ephemeral: &str, state: &AppState) {
    if parent.is_empty() || ephemeral.is_empty() {
        return;
    }
    let Ok(parent_uuid) = parse_channel_uuid(parent) else {
        return;
    };
    let agents = match fetch_channel_members(ephemeral, Some("bot"), state).await {
        Ok(agents) if !agents.is_empty() => agents,
        Ok(_) => return, // no agent on the call: nobody to hand the record to
        Err(e) => {
            eprintln!("buzz-desktop: huddle record: agent list unavailable: {e}");
            return;
        }
    };
    let messages = match crate::relay::query_relay(
        state,
        &[serde_json::json!({ "kinds": [9], "#h": [ephemeral], "limit": 500 })],
    )
    .await
    {
        Ok(events) => events,
        Err(e) => {
            eprintln!("buzz-desktop: huddle record: transcript unavailable: {e}");
            return;
        }
    };
    let authors: BTreeSet<String> = messages
        .iter()
        .map(|e| e.pubkey.to_hex())
        .chain(agents.iter().cloned())
        .collect();
    let names = crate::relay::query_relay(
        state,
        &[serde_json::json!({ "kinds": [0], "authors": authors })],
    )
    .await
    .map(|events| profile_names(&events))
    .unwrap_or_default();
    let agent_names: Vec<String> = agents
        .iter()
        .map(|pk| {
            names
                .get(pk)
                .cloned()
                .unwrap_or_else(|| pk.chars().take(8).collect())
        })
        .collect();
    let Some(body) = record_body(&agent_names, &transcript_lines(&messages, &names)) else {
        return;
    };
    let mentions: Vec<&str> = agents.iter().map(String::as_str).collect();
    for attempt in 1..=ATTEMPTS {
        let built = events::build_message(
            parent_uuid,
            &body,
            None,
            &mentions,
            &[],
            &[],
            &[],
            &[],
            None,
            &crate::relay::relay_api_base_url(),
        )
        .and_then(|builder| {
            Tag::parse(["t", HUDDLE_TRANSCRIPT_TAG])
                .map(|tag| builder.tag(tag))
                .map_err(|e| e.to_string())
        });
        let builder = match built {
            Ok(builder) => builder,
            Err(e) => {
                eprintln!("buzz-desktop: huddle record: not built: {e}");
                return;
            }
        };
        match submit_event(builder, state).await {
            Ok(_) => return,
            Err(e) => {
                eprintln!("buzz-desktop: huddle record: attempt {attempt} failed: {e}");
                if attempt < ATTEMPTS {
                    tokio::time::sleep(std::time::Duration::from_secs(2 * u64::from(attempt)))
                        .await;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{EventBuilder, Keys, Kind};

    fn message(keys: &Keys, at: u64, text: &str) -> Event {
        EventBuilder::new(Kind::Custom(9), text)
            .custom_created_at(nostr::Timestamp::from(at))
            .sign_with_keys(keys)
            .expect("sign")
    }

    #[test]
    fn a_huddle_with_an_agent_and_words_gets_a_record_addressed_to_it() {
        let body = record_body(
            &["woody".to_owned()],
            &["[10:00:00] Lloyd: ship the build friday".to_owned()],
        )
        .expect("a record");
        assert!(body.starts_with("@woody this huddle is over"));
        assert!(body.contains("Do this now, as yourself:"));
        assert!(body.contains("buzz issues create"));
        assert!(body.contains("Reply in this thread"));
        assert!(body.ends_with("Lloyd: ship the build friday"));
    }

    #[test]
    fn several_agents_split_the_work_and_one_writes_the_recap() {
        let body = record_body(
            &["woody".to_owned(), "jessie".to_owned()],
            &["[10:00:00] Lloyd: hi".to_owned()],
        )
        .expect("a record");
        assert!(body.starts_with("@woody @jessie this huddle is over"));
        assert!(body.contains("@woody writes the recap"));
    }

    #[test]
    fn no_agent_or_no_words_means_no_record() {
        assert!(record_body(&[], &["[10:00:00] Lloyd: hi".to_owned()]).is_none());
        assert!(record_body(&["woody".to_owned()], &[]).is_none());
        assert!(record_body(&["woody".to_owned()], &["  ".to_owned()]).is_none());
    }

    #[test]
    fn a_long_call_keeps_its_end_within_the_byte_cap() {
        let lines: Vec<String> = (0..5_000)
            .map(|i| format!("[10:00:00] Lloyd: “line {i}” …"))
            .collect();
        let body = record_body(&["woody".to_owned()], &lines).expect("a record");
        assert!(body.len() <= BODY_BYTE_CAP, "{} bytes", body.len());
        assert!(body.contains(OMITTED));
        assert!(body.ends_with("“line 4999” …"));
        assert!(
            body.contains("buzz issues create"),
            "the instructions survive whole"
        );
    }

    #[test]
    fn the_transcript_is_named_ordered_and_leaves_out_system_notices() {
        let lloyd = Keys::generate();
        let woody = Keys::generate();
        let names: HashMap<String, String> = [
            (lloyd.public_key().to_hex(), "Lloyd".to_owned()),
            (woody.public_key().to_hex(), "woody".to_owned()),
        ]
        .into_iter()
        .collect();
        let events = vec![
            message(&woody, 1_800_000_010, "one sec,\n  checking"),
            message(&lloyd, 1_800_000_000, "what's left for release?"),
            message(&woody, 1_800_000_020, "[System] agent joined"),
            message(&lloyd, 1_800_000_030, "   "),
        ];
        let lines = transcript_lines(&events, &names);
        assert_eq!(lines.len(), 2);
        assert!(
            lines[0].ends_with("] Lloyd: what's left for release?"),
            "{}",
            lines[0]
        );
        assert!(
            lines[1].ends_with("] woody: one sec, checking"),
            "{}",
            lines[1]
        );
    }

    #[test]
    fn profile_names_prefer_display_name_from_the_newest_profile() {
        let keys = Keys::generate();
        let old = EventBuilder::new(Kind::Metadata, r#"{"name":"old"}"#)
            .custom_created_at(nostr::Timestamp::from(1))
            .sign_with_keys(&keys)
            .expect("sign");
        let new = EventBuilder::new(Kind::Metadata, r#"{"name":"w","display_name":"woody"}"#)
            .custom_created_at(nostr::Timestamp::from(2))
            .sign_with_keys(&keys)
            .expect("sign");
        let names = profile_names(&[old, new]);
        assert_eq!(
            names.get(&keys.public_key().to_hex()).map(String::as_str),
            Some("woody")
        );
    }
}
