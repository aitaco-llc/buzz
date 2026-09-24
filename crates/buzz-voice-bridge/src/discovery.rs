//! Which huddles this seat's voice answers, found rather than configured.
//!
//! A person huddles with an agent by opening the agent's DM and starting a
//! huddle there, from the phone or anywhere else. So the bridge for a seat
//! watches every 1:1 DM between that seat and a configured starter, and finds
//! them on the relay instead of from a hand-kept channel list. A DM is an
//! ordinary channel there, and its NIP-29 metadata (kind:39000) carries
//! `["t","dm"]` and one `p` tag per participant
//! (`crates/buzz-relay/src/handlers/side_effects.rs`, group discovery). A DM
//! opened tomorrow is watched tomorrow, with no config change.
//!
//! Group DMs and ordinary channels are not discovered: with several agents in
//! the room, every one of their bridges would answer at once. A channel can
//! still be listed explicitly with `--parent-channels`.
//!
//! One exception is decided per huddle, not per channel: a huddle started on
//! Desktop is already voiced — Desktop invites the DM's agent, posts kind:48106
//! voice guidelines into the huddle's channel, and speaks the agent's replies
//! with its own TTS. A second voice from this bridge would talk over it, so a
//! huddle whose channel carries those guidelines is left to Desktop.

use std::collections::{BTreeSet, HashSet};
use std::time::Duration;

use anyhow::Result;
use nostr::Event;
use serde_json::json;
use uuid::Uuid;

use crate::relay_io::Publisher;

/// NIP-29 group metadata, which for a DM names its participants.
pub const KIND_GROUP_METADATA: u16 = 39000;
/// Desktop's voice-mode guidelines for agents, posted into a huddle's channel.
pub const KIND_HUDDLE_GUIDELINES: u16 = 48106;
/// How long the Desktop check may take before the bridge answers anyway. A
/// huddle that is not answered is worse than one answered twice.
pub const VOICED_CHECK_TIMEOUT: Duration = Duration::from_secs(4);

/// The live 1:1 DMs between `me` and any of `starters`, from DM metadata.
pub fn dms_with_starters(events: &[Event], me: &str, starters: &HashSet<String>) -> BTreeSet<Uuid> {
    events
        .iter()
        .filter(|event| event.kind.as_u16() == KIND_GROUP_METADATA)
        .filter_map(|event| {
            let mut dm: Option<Uuid> = None;
            let mut others: BTreeSet<String> = BTreeSet::new();
            let mut includes_me = false;
            let mut is_dm = false;
            let mut archived = false;
            for tag in event.tags.iter().map(|t| t.as_slice()) {
                match (tag.first().map(String::as_str), tag.get(1)) {
                    (Some("t"), Some(kind)) if kind == "dm" => is_dm = true,
                    (Some("archived"), Some(flag)) if flag == "true" => archived = true,
                    (Some("d"), Some(id)) => dm = id.parse().ok(),
                    (Some("p"), Some(pubkey)) => {
                        let pubkey = pubkey.to_ascii_lowercase();
                        if pubkey == me {
                            includes_me = true;
                        } else {
                            others.insert(pubkey);
                        }
                    }
                    _ => {}
                }
            }
            let one_starter = others.len() == 1 && others.iter().all(|o| starters.contains(o));
            (is_dm && !archived && includes_me && one_starter)
                .then_some(dm)
                .flatten()
        })
        .collect()
}

/// Ask the relay for this seat's DMs with the starters.
pub async fn discover_dms(
    publisher: &Publisher,
    me: &str,
    starters: &HashSet<String>,
) -> Result<BTreeSet<Uuid>> {
    let events = publisher
        .query(&[json!({ "kinds": [KIND_GROUP_METADATA], "#p": [me], "limit": 500 })])
        .await?;
    Ok(dms_with_starters(&events, me, starters))
}

/// Whether Desktop is voicing this huddle already. A seat Desktop invited is a
/// member of the huddle's channel and can read the guidelines; a phone huddle
/// has none, and the read fails or comes back empty — both mean "not voiced".
pub async fn desktop_voiced(publisher: &Publisher, ephemeral: Uuid) -> Result<bool> {
    let events = publisher
        .query(&[json!({
            "kinds": [KIND_HUDDLE_GUIDELINES],
            "#h": [ephemeral.to_string()],
            "limit": 1,
        })])
        .await?;
    Ok(!events.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{EventBuilder, Keys, Kind, Tag};

    fn dm(keys: &Keys, id: &str, participants: &[&str]) -> Event {
        channel(keys, id, "dm", participants, false)
    }

    fn channel(keys: &Keys, id: &str, kind: &str, participants: &[&str], archived: bool) -> Event {
        let mut builder = EventBuilder::new(Kind::Custom(KIND_GROUP_METADATA), "")
            .tag(Tag::parse(["d", id]).expect("d"))
            .tag(Tag::parse(["t", kind]).expect("t"));
        if archived {
            builder = builder.tag(Tag::parse(["archived", "true"]).expect("archived"));
        }
        for p in participants {
            builder = builder.tag(Tag::parse(["p", p]).expect("p"));
        }
        builder.sign_with_keys(keys).expect("sign")
    }

    #[test]
    fn only_one_to_one_dms_with_a_starter_are_watched() {
        let relay = Keys::generate();
        let me = "aa".repeat(32);
        let lloyd = "bb".repeat(32);
        let stranger = "cc".repeat(32);
        let starters: HashSet<String> = [lloyd.clone()].into();
        let ours = "11111111-1111-4111-8111-111111111111";
        let group = "22222222-2222-4222-8222-222222222222";
        let foreign = "33333333-3333-4333-8333-333333333333";
        let not_mine = "44444444-4444-4444-8444-444444444444";
        let events = vec![
            dm(&relay, ours, &[&me, &lloyd.to_ascii_uppercase()]),
            dm(&relay, group, &[&me, &lloyd, &stranger]),
            dm(&relay, foreign, &[&me, &stranger]),
            dm(&relay, not_mine, &[&lloyd, &stranger]),
            dm(&relay, "not-a-uuid", &[&me, &lloyd]),
            channel(
                &relay,
                "55555555-5555-4555-8555-555555555555",
                "stream",
                &[&me, &lloyd],
                false,
            ),
            channel(
                &relay,
                "66666666-6666-4666-8666-666666666666",
                "dm",
                &[&me, &lloyd],
                true,
            ),
        ];
        let found = dms_with_starters(&events, &me, &starters);
        assert_eq!(found, [ours.parse::<Uuid>().unwrap()].into());
    }
}
