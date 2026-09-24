//! What the voice knows when the call starts: the recent written conversation
//! in the channel the huddle was started from, rendered as a transcript the
//! model can read as its own memory.
//!
//! The seat's own written turns are in here, the human's, and the seat's
//! written recap of the last call, so "what did we decide last time" has an
//! answer without a round trip to the seat. The bridge's own posts — asks and
//! call-end posts — are left out: they are instructions to the seat, and fed
//! back to the voice as things it said they become things it tries to do.

use anyhow::Result;
use nostr::Event;
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::time::Duration;
use uuid::Uuid;

use crate::relay_io::Publisher;

/// The whole history section, in characters. Older lines are dropped first.
pub const HISTORY_CHAR_CAP: usize = 12 * 1024;
/// One message, in characters. A call-end post carries a whole transcript;
/// the voice needs its gist, not its entirety.
pub const MESSAGE_CHAR_CAP: usize = 600;
/// How long the fetch may take before the call goes on without it. A history
/// is context, not a precondition; the room join runs in parallel and the
/// human is already on the line.
pub const FETCH_TIMEOUT: Duration = Duration::from_secs(4);

/// Recent kind:9 messages in `parent`, newest last, as `[HH:MM] name: text`
/// lines, or `None` when the relay had nothing or the fetch failed.
///
/// `labels` maps pubkeys the caller already knows the names of (the seat, the
/// starters); every other author is looked up by profile, and one that has no
/// profile is shown by the first eight characters of its key.
pub async fn recent_history(
    publisher: &Publisher,
    parent: Uuid,
    limit: usize,
    days: u64,
    labels: &HashMap<String, String>,
) -> Result<Option<String>> {
    if limit == 0 {
        return Ok(None);
    }
    let since = nostr::Timestamp::now()
        .as_secs()
        .saturating_sub(days.saturating_mul(24 * 60 * 60));
    let filter = json!({
        "kinds": [9],
        "#h": [parent.to_string()],
        "since": since,
        "limit": limit,
    });
    let mut events = publisher.query(&[filter]).await?;
    events.retain(|event| !crate::relay_io::is_bridge_event(event));
    if events.is_empty() {
        return Ok(None);
    }
    events.sort_by_key(|event| (event.created_at, event.id));
    let unknown: Vec<String> = events
        .iter()
        .map(|event| event.pubkey.to_hex())
        .filter(|pubkey| !labels.contains_key(pubkey))
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    let mut names = labels.clone();
    if !unknown.is_empty() {
        match publisher.profile_names(&unknown).await {
            Ok(found) => names.extend(found),
            Err(error) => tracing::warn!(%error, "profile names unavailable; keys shown instead"),
        }
    }
    Ok(Some(render(&events, &names)))
}

/// Render `events` (oldest first) as transcript lines within the caps.
pub fn render(events: &[Event], names: &HashMap<String, String>) -> String {
    let lines: Vec<String> = events
        .iter()
        .filter(|event| !event.content.trim().is_empty())
        .map(|event| {
            let pubkey = event.pubkey.to_hex();
            let name = names
                .get(&pubkey)
                .cloned()
                .unwrap_or_else(|| pubkey.chars().take(8).collect());
            let when = chrono::DateTime::<chrono::Utc>::from_timestamp(
                i64::try_from(event.created_at.as_secs()).unwrap_or_default(),
                0,
            )
            .map(|t| t.format("%b %-d %H:%M").to_string())
            .unwrap_or_default();
            let text = clip(&event.content, MESSAGE_CHAR_CAP);
            format!("[{when}] {name}: {text}")
        })
        .collect();
    // Newest lines matter most: drop from the front until the whole fits.
    let mut start = 0;
    let mut total: usize = lines.iter().map(|line| line.chars().count() + 1).sum();
    while start < lines.len() && total > HISTORY_CHAR_CAP {
        total -= lines[start].chars().count() + 1;
        start += 1;
    }
    lines[start..].join("\n")
}

/// Whitespace collapsed, cut at `cap` characters with a marker.
fn clip(text: &str, cap: usize) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() <= cap {
        return collapsed;
    }
    let mut cut: String = collapsed.chars().take(cap).collect();
    cut.push('…');
    cut
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
    fn lines_carry_a_name_a_time_and_the_text_oldest_first() {
        let lloyd = Keys::generate();
        let rock = Keys::generate();
        let names: HashMap<String, String> = [
            (lloyd.public_key().to_hex(), "Lloyd".to_owned()),
            (rock.public_key().to_hex(), "rock".to_owned()),
        ]
        .into_iter()
        .collect();
        let events = vec![
            message(&lloyd, 1_800_000_000, "what's the\nbuild   status"),
            message(&rock, 1_800_000_060, "green as of an hour ago"),
        ];
        let text = render(&events, &names);
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 2);
        assert!(
            lines[0].ends_with("] Lloyd: what's the build status"),
            "{}",
            lines[0]
        );
        assert!(
            lines[1].ends_with("] rock: green as of an hour ago"),
            "{}",
            lines[1]
        );
        assert!(lines[0].starts_with('['));
    }

    #[test]
    fn the_bridges_own_posts_are_not_history() {
        // `recent_history` drops them before rendering; the filter it uses is
        // the provenance tag every bridge event carries.
        let keys = Keys::generate();
        let ask = EventBuilder::new(Kind::Custom(9), "Lloyd is on a voice call with you")
            .tag(crate::relay_io::Provenance::Ask.tag())
            .sign_with_keys(&keys)
            .expect("sign");
        let mut events = vec![message(&keys, 1, "the build is green"), ask];
        events.retain(|event| !crate::relay_io::is_bridge_event(event));
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].content, "the build is green");
    }

    #[test]
    fn an_unnamed_author_is_shown_by_a_key_prefix_and_empty_messages_are_skipped() {
        let who = Keys::generate();
        let events = vec![message(&who, 1, "   "), message(&who, 2, "hello")];
        let text = render(&events, &HashMap::new());
        let prefix: String = who.public_key().to_hex().chars().take(8).collect();
        assert_eq!(text.lines().count(), 1);
        assert!(text.contains(&format!("] {prefix}: hello")), "{text}");
    }

    #[test]
    fn long_messages_are_clipped_and_the_oldest_lines_go_first_under_the_cap() {
        let who = Keys::generate();
        let long = "x".repeat(MESSAGE_CHAR_CAP + 50);
        let clipped = render(&[message(&who, 1, &long)], &HashMap::new());
        assert!(clipped.ends_with('…'));
        assert!(clipped.chars().count() < MESSAGE_CHAR_CAP + 40);

        let many: Vec<Event> = (0..200)
            .map(|i| message(&who, 1_000 + i, &format!("m{i} {}", "y".repeat(90))))
            .collect();
        let text = render(&many, &HashMap::new());
        assert!(text.chars().count() <= HISTORY_CHAR_CAP);
        assert!(text.contains("m199 "), "the newest line survives");
        assert!(
            !text.contains("] m0 ") && !text.contains(": m0 "),
            "the oldest line went first"
        );
    }
}
