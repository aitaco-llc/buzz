//! Huddle audio-room client: the relay's `/huddle/{channel}/audio` socket.
//!
//! Handshake (see `desktop/src-tauri/src/huddle/relay_api.rs` and
//! `crates/buzz-relay/src/audio/handler.rs`):
//! relay sends `{"type":"challenge"}`, client answers `{"type":"auth"}` with a
//! kind:22242 event, `parent_channel_id` and `protocol_version: 2`, relay
//! answers `{"type":"joined"}` with this peer's index and the roster. Later
//! `joined` / `left` messages keep the peer-index → pubkey map current.
//!
//! A key that belongs to the parent channel is auto-added to a private
//! ephemeral huddle channel on join (`audio/handler.rs:1326-1348`), so the
//! bridge needs no kind:9000 enrollment.

use anyhow::{anyhow, bail, Context, Result};
use futures_util::{SinkExt, StreamExt};
use nostr::{EventBuilder, JsonUtil, Keys, Kind, Tag};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::time::Duration;
use tokio_tungstenite::{connect_async, tungstenite::Message, MaybeTlsStream, WebSocketStream};
use uuid::Uuid;

use crate::wire::PROTOCOL_VERSION;

pub type RoomStream = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);

pub struct Room {
    pub ws: RoomStream,
    pub self_index: u8,
    /// peer index → pubkey hex, this peer included.
    pub peers: HashMap<u8, String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RoomEvent {
    Joined { peer_index: u8, pubkey: String },
    Left { peer_index: u8, pubkey: String },
    Error(String),
    Other,
}

/// Parse a control message from the room.
pub fn parse_control(value: &Value) -> RoomEvent {
    let peer = || {
        Some((
            u8::try_from(value["peer_index"].as_u64()?).ok()?,
            value["pubkey"].as_str()?.to_ascii_lowercase(),
        ))
    };
    match value["type"].as_str() {
        Some("joined") => match peer() {
            Some((peer_index, pubkey)) => RoomEvent::Joined { peer_index, pubkey },
            None => RoomEvent::Other,
        },
        Some("left") => match peer() {
            Some((peer_index, pubkey)) => RoomEvent::Left { peer_index, pubkey },
            None => RoomEvent::Other,
        },
        Some("error") => RoomEvent::Error(value.to_string()),
        _ => RoomEvent::Other,
    }
}

/// The relay's WebSocket origin for NIP-42: `ws(s)://host`, no path.
pub fn relay_origin(relay_url: &str) -> String {
    relay_url.trim_end_matches('/').to_owned()
}

pub async fn join(relay_url: &str, channel: Uuid, parent: Uuid, keys: &Keys) -> Result<Room> {
    let origin = relay_origin(relay_url);
    let url = format!("{origin}/huddle/{channel}/audio");
    let (mut ws, _) = tokio::time::timeout(Duration::from_secs(10), connect_async(url.as_str()))
        .await
        .map_err(|_| anyhow!("audio connect timed out"))?
        .with_context(|| format!("audio connect {url}"))?;

    let challenge = tokio::time::timeout(HANDSHAKE_TIMEOUT, async {
        while let Some(message) = ws.next().await {
            if let Message::Text(text) = message.context("audio receive")? {
                let value: Value = serde_json::from_str(&text).context("challenge JSON")?;
                if value["type"] == "challenge" {
                    return value["challenge"]
                        .as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| anyhow!("challenge without a string"));
                }
            }
        }
        bail!("audio socket closed before the challenge")
    })
    .await
    .map_err(|_| anyhow!("no audio challenge within 5 s"))??;

    let auth = EventBuilder::new(Kind::Custom(22242), "")
        .tags([
            Tag::parse(["relay", origin.as_str()])?,
            Tag::parse(["challenge", challenge.as_str()])?,
        ])
        .sign_with_keys(keys)?;
    let auth_message = json!({
        "type": "auth",
        "event": serde_json::from_str::<Value>(&auth.as_json())?,
        "parent_channel_id": parent.to_string(),
        "protocol_version": PROTOCOL_VERSION,
    });
    ws.send(Message::Text(auth_message.to_string().into()))
        .await
        .context("send audio auth")?;

    let me = keys.public_key().to_hex();
    let (self_index, peers) = tokio::time::timeout(HANDSHAKE_TIMEOUT, async {
        while let Some(message) = ws.next().await {
            let Message::Text(text) = message.context("audio receive")? else {
                continue;
            };
            let value: Value = serde_json::from_str(&text).unwrap_or_default();
            match value["type"].as_str() {
                Some("joined") if value["pubkey"].as_str() == Some(me.as_str()) => {
                    let self_index = value["peer_index"]
                        .as_u64()
                        .and_then(|i| u8::try_from(i).ok())
                        .ok_or_else(|| anyhow!("joined without a peer index"))?;
                    let mut peers = HashMap::new();
                    for peer in value["peers"].as_array().into_iter().flatten() {
                        if let (Some(index), Some(pubkey)) =
                            (peer["peer_index"].as_u64(), peer["pubkey"].as_str())
                        {
                            if let Ok(index) = u8::try_from(index) {
                                peers.insert(index, pubkey.to_ascii_lowercase());
                            }
                        }
                    }
                    peers.insert(self_index, me.clone());
                    return Ok((self_index, peers));
                }
                Some("error") => bail!("audio room refused the join: {value}"),
                _ => {}
            }
        }
        bail!("audio socket closed before joined")
    })
    .await
    .map_err(|_| anyhow!("no joined within 5 s"))??;

    Ok(Room {
        ws,
        self_index,
        peers,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_messages_update_the_roster() {
        assert_eq!(
            parse_control(
                &json!({"type":"joined","pubkey":"AB","peer_index":4,"epoch":1,"peers":[]})
            ),
            RoomEvent::Joined {
                peer_index: 4,
                pubkey: "ab".into()
            }
        );
        assert_eq!(
            parse_control(&json!({"type":"left","pubkey":"ab","peer_index":4})),
            RoomEvent::Left {
                peer_index: 4,
                pubkey: "ab".into()
            }
        );
        assert!(matches!(
            parse_control(&json!({"type":"error","code":"room_ended"})),
            RoomEvent::Error(_)
        ));
        assert_eq!(parse_control(&json!({"type":"speakers"})), RoomEvent::Other);
        assert_eq!(
            parse_control(&json!({"type":"joined","peer_index":999,"pubkey":"ab"})),
            RoomEvent::Other
        );
    }

    #[test]
    fn origin_has_no_trailing_slash() {
        assert_eq!(
            relay_origin("wss://buzz.aitaco.co/"),
            "wss://buzz.aitaco.co"
        );
    }
}
