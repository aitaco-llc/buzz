//! `buzz relay members` — NIP-43 relay membership: add, remove, list.
//!
//! `add`/`remove` are signed command events (kinds 9030/9031) submitted via
//! `POST /events`. The relay authorizes and executes them directly against
//! `relay_members` and never stores them (`buzz-relay/src/handlers/relay_admin.rs`):
//! the sender must be an admin or owner, and only an owner may grant `admin`.
//! Re-adding an existing member is a silent success at the relay, so `add` is
//! idempotent. Role changes (kind 9032) are owner-only and deliberately not
//! exposed here.
//!
//! `list` reads the relay-signed kind:13534 membership snapshot — the
//! authoritative roster (see `buzz-admin/src/main.rs`) — and verifies that the
//! relay itself signed it before trusting any `member` tag.

use buzz_core::kind::KIND_NIP43_MEMBERSHIP_LIST;
use nostr::PublicKey;
use serde_json::json;

use crate::client::BuzzClient;
use crate::commands::parse_write_response;
use crate::error::CliError;
use crate::{RelayCmd, RelayMembersCmd};

/// Accept a hex or npub pubkey and return lowercase hex.
fn parse_pubkey(input: &str) -> Result<String, CliError> {
    PublicKey::parse(input.trim())
        .map(|pk| pk.to_hex())
        .map_err(|e| {
            CliError::Usage(format!(
                "--pubkey must be a 64-char hex pubkey or npub: {e}"
            ))
        })
}

/// The relay reports a role refusal as HTTP 400 `invalid: actor not
/// authorized: ...`. Surface it as an auth error (exit 3) so callers can tell
/// "this key may not do that" from a malformed request or a relay fault.
fn map_admin_refusal(error: CliError) -> CliError {
    match error {
        CliError::Relay { status: 400, body }
            if body
                .strip_prefix("invalid: ")
                .unwrap_or(&body)
                .starts_with("actor not authorized") =>
        {
            CliError::Auth(body)
        }
        other => other,
    }
}

async fn submit_admin_command(
    client: &BuzzClient,
    builder: nostr::EventBuilder,
) -> Result<String, CliError> {
    let event = client.sign_event(builder)?;
    let raw = client
        .submit_event(event)
        .await
        .map_err(map_admin_refusal)?;
    // Relay-admin commands are never stored, so "duplicate" cannot occur;
    // this call exists to turn `accepted: false` into a non-zero exit.
    parse_write_response(&raw, "relay reported a duplicate membership command")
}

async fn cmd_add(client: &BuzzClient, pubkey: &str, role: &str) -> Result<(), CliError> {
    let pubkey = parse_pubkey(pubkey)?;
    let builder = buzz_sdk::build_relay_admin_add(&pubkey, role)
        .map_err(|e| CliError::Usage(format!("invalid relay member add: {e}")))?;
    println!("{}", submit_admin_command(client, builder).await?);
    Ok(())
}

async fn cmd_remove(client: &BuzzClient, pubkey: &str) -> Result<(), CliError> {
    let pubkey = parse_pubkey(pubkey)?;
    let builder = buzz_sdk::build_relay_admin_remove(&pubkey)
        .map_err(|e| CliError::Usage(format!("invalid relay member remove: {e}")))?;
    println!("{}", submit_admin_command(client, builder).await?);
    Ok(())
}

async fn cmd_list(client: &BuzzClient) -> Result<(), CliError> {
    let nip11_raw = client
        .get_public("/")
        .await
        .map_err(|e| CliError::Other(format!("failed to fetch relay info document: {e}")))?;
    let nip11: serde_json::Value = serde_json::from_str(&nip11_raw)
        .map_err(|e| CliError::Other(format!("relay info document is not valid JSON: {e}")))?;
    let self_hex = nip11
        .get("self")
        .and_then(|v| v.as_str())
        .ok_or_else(|| CliError::Other("relay info document missing 'self' field".into()))?;
    let self_hex = parse_relay_self(self_hex)?;

    let filter = json!({"kinds": [KIND_NIP43_MEMBERSHIP_LIST], "authors": [self_hex], "limit": 1});
    let raw = client.query(&filter).await?;
    let events: Vec<nostr::Event> = serde_json::from_str(&raw)
        .map_err(|e| CliError::Other(format!("invalid query response: {e}")))?;
    let event = events.into_iter().next().ok_or_else(|| {
        CliError::NotFound(
            "relay returned no membership snapshot (kind 13534); membership may not be enabled"
                .into(),
        )
    })?;

    let members = verify_membership_event(&event, &self_hex)?;
    println!(
        "{}",
        json!({
            "members": members
                .iter()
                .map(|(pubkey, role)| json!({"pubkey": pubkey, "role": role}))
                .collect::<Vec<_>>(),
            "count": members.len(),
            "snapshot_created_at": event.created_at.as_secs(),
        })
    );
    Ok(())
}

/// Validate the NIP-11 `self` field as a 64-hex pubkey, lowercased so the
/// query filter and the author comparison agree.
fn parse_relay_self(self_hex: &str) -> Result<String, CliError> {
    if self_hex.len() != 64 || !self_hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(CliError::Other(format!(
            "relay 'self' field is not a valid 64-hex pubkey: {self_hex}"
        )));
    }
    Ok(self_hex.to_ascii_lowercase())
}

/// Verify a kind:13534 snapshot was signed by the relay and extract its
/// `["member", <pubkey>, <role>?]` tags. A missing role reads as `member`,
/// matching the desktop's `relay_members_from_event`.
fn verify_membership_event(
    event: &nostr::Event,
    relay_self_hex: &str,
) -> Result<Vec<(String, String)>, CliError> {
    if event.kind != nostr::Kind::Custom(KIND_NIP43_MEMBERSHIP_LIST as u16) {
        return Err(CliError::Other(format!(
            "membership snapshot has wrong kind: {}",
            event.kind.as_u16()
        )));
    }
    if event.pubkey.to_hex() != relay_self_hex {
        return Err(CliError::Other(format!(
            "membership snapshot author {} does not match relay self {relay_self_hex}",
            event.pubkey.to_hex()
        )));
    }
    event.verify().map_err(|e| {
        CliError::Other(format!(
            "membership snapshot failed cryptographic verification: {e}"
        ))
    })?;

    let mut members: Vec<(String, String)> = Vec::new();
    for tag in event.tags.iter() {
        let parts = tag.as_slice();
        if parts.first().map(String::as_str) != Some("member") {
            continue;
        }
        let Some(pubkey) = parts.get(1) else {
            continue;
        };
        if pubkey.len() != 64 || !pubkey.chars().all(|c| c.is_ascii_hexdigit()) {
            continue;
        }
        let pubkey = pubkey.to_ascii_lowercase();
        if members.iter().any(|(existing, _)| *existing == pubkey) {
            continue;
        }
        let role = parts
            .get(2)
            .filter(|r| !r.is_empty())
            .cloned()
            .unwrap_or_else(|| "member".to_string());
        members.push((pubkey, role));
    }
    Ok(members)
}

pub async fn dispatch(cmd: RelayCmd, client: &BuzzClient) -> Result<(), CliError> {
    match cmd {
        RelayCmd::Members(sub) => match sub {
            RelayMembersCmd::Add { pubkey, role } => cmd_add(client, &pubkey, role.as_str()).await,
            RelayMembersCmd::Remove { pubkey } => cmd_remove(client, &pubkey).await,
            RelayMembersCmd::List => cmd_list(client).await,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{EventBuilder, Keys, Kind, Tag};

    fn snapshot(keys: &Keys, tags: Vec<Vec<&str>>) -> nostr::Event {
        let tags: Vec<Tag> = tags
            .into_iter()
            .map(|t| Tag::parse(t).expect("tag"))
            .collect();
        EventBuilder::new(Kind::Custom(KIND_NIP43_MEMBERSHIP_LIST as u16), "")
            .tags(tags)
            .sign_with_keys(keys)
            .expect("sign")
    }

    #[test]
    fn parse_pubkey_accepts_hex_and_npub() {
        let keys = Keys::generate();
        let hex = keys.public_key().to_hex();
        let npub = nostr::ToBech32::to_bech32(&keys.public_key()).expect("npub");
        assert_eq!(parse_pubkey(&hex).unwrap(), hex);
        assert_eq!(parse_pubkey(&hex.to_ascii_uppercase()).unwrap(), hex);
        assert_eq!(parse_pubkey(&npub).unwrap(), hex);
    }

    #[test]
    fn parse_pubkey_rejects_garbage_as_usage() {
        for bad in ["", "abc", "npub1notreal", &"g".repeat(64)] {
            assert!(
                matches!(parse_pubkey(bad), Err(CliError::Usage(_))),
                "input {bad:?}"
            );
        }
    }

    #[test]
    fn role_refusal_maps_to_auth_exit_code() {
        for body in [
            "invalid: actor not authorized: must be admin or owner",
            "invalid: actor not authorized: only owner can grant admin role",
            "invalid: actor not authorized: admins can only remove members",
        ] {
            let mapped = map_admin_refusal(CliError::Relay {
                status: 400,
                body: body.to_string(),
            });
            assert!(matches!(mapped, CliError::Auth(_)), "body {body:?}");
            assert_eq!(crate::error::exit_code(&mapped), 3);
        }
    }

    #[test]
    fn other_relay_refusals_keep_their_error() {
        for body in [
            "invalid: member not found: abc",
            "invalid: cannot remove yourself",
            "invalid: invalid role: owner",
        ] {
            let mapped = map_admin_refusal(CliError::Relay {
                status: 400,
                body: body.to_string(),
            });
            assert!(
                matches!(mapped, CliError::Relay { status: 400, .. }),
                "body {body:?}"
            );
        }
        // A 403 is already an auth error; leave it alone.
        let mapped = map_admin_refusal(CliError::Relay {
            status: 403,
            body: "relay_membership_required".into(),
        });
        assert!(matches!(mapped, CliError::Relay { status: 403, .. }));
    }

    #[test]
    fn verify_extracts_members_and_roles() {
        let relay = Keys::generate();
        let a = "a".repeat(64);
        let b = "B".repeat(64);
        let c = "c".repeat(64);
        let ev = snapshot(
            &relay,
            vec![
                vec!["-"],
                vec!["member", &a, "owner"],
                vec!["member", &b, "admin"],
                vec!["member", &c],
                vec!["member", &a, "member"],
                vec!["member", "not-a-pubkey", "member"],
                vec!["p", &"d".repeat(64)],
            ],
        );
        let members = verify_membership_event(&ev, &relay.public_key().to_hex()).unwrap();
        assert_eq!(
            members,
            vec![
                (a.clone(), "owner".to_string()),
                ("b".repeat(64), "admin".to_string()),
                (c, "member".to_string()),
            ]
        );
    }

    #[test]
    fn verify_rejects_snapshot_not_signed_by_relay() {
        let relay = Keys::generate();
        let impostor = Keys::generate();
        let ev = snapshot(&impostor, vec![vec!["member", &"a".repeat(64), "admin"]]);
        let err = verify_membership_event(&ev, &relay.public_key().to_hex()).unwrap_err();
        assert!(matches!(err, CliError::Other(_)));
    }

    #[test]
    fn verify_rejects_wrong_kind() {
        let relay = Keys::generate();
        let ev = EventBuilder::new(Kind::Custom(13535), "")
            .sign_with_keys(&relay)
            .expect("sign");
        assert!(verify_membership_event(&ev, &relay.public_key().to_hex()).is_err());
    }

    #[test]
    fn relay_self_must_be_hex64() {
        assert!(parse_relay_self("abc").is_err());
        assert_eq!(parse_relay_self(&"A".repeat(64)).unwrap(), "a".repeat(64));
    }
}
