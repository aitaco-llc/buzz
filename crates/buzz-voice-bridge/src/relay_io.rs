//! Relay I/O: the signing key, event publication and provenance tags.
//!
//! Every event the bridge signs carries `["voice-bridge", <what>]`, so the
//! signed log shows which events Gemini's side produced even though they are
//! signed with the seat's key. Only `ask` wakes the seat, and only when the
//! seat runs with `BUZZ_ACP_SELF_WAKE_TAG=voice-bridge=ask`.

use anyhow::{anyhow, bail, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use nostr::{Event, EventBuilder, JsonUtil, Keys, Kind, Tag};
use sha2::{Digest, Sha256};
use std::path::Path;
use std::time::Duration;

pub const PROVENANCE: &str = "voice-bridge";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Provenance {
    /// A request for the seat. The only kind that wakes it.
    Ask,
    /// A transcript line or the full transcript.
    Transcript,
}

impl Provenance {
    pub fn value(self) -> &'static str {
        match self {
            Self::Ask => "ask",
            Self::Transcript => "transcript",
        }
    }

    pub fn tag(self) -> Tag {
        Tag::parse([PROVENANCE, self.value()]).expect("static tag")
    }
}

/// True when `event` was signed by the bridge (any provenance value).
pub fn is_bridge_event(event: &Event) -> bool {
    event
        .tags
        .iter()
        .any(|tag| tag.as_slice().first().map(String::as_str) == Some(PROVENANCE))
}

/// Read `BUZZ_PRIVATE_KEY` from an env file, the same file the seat reads.
/// The key is never copied anywhere else.
pub fn load_key_file(path: &Path) -> Result<Keys> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("read key file {}", path.display()))?;
    parse_key_env(&text).with_context(|| format!("key file {}", path.display()))
}

fn parse_key_env(text: &str) -> Result<Keys> {
    let value = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.starts_with('#'))
        .filter_map(|line| line.strip_prefix("export ").unwrap_or(line).split_once('='))
        .filter(|(name, _)| name.trim() == "BUZZ_PRIVATE_KEY")
        .map(|(_, value)| value.trim().trim_matches('"').trim_matches('\''))
        .next_back()
        .ok_or_else(|| anyhow!("no BUZZ_PRIVATE_KEY line"))?;
    if value.is_empty() {
        bail!("BUZZ_PRIVATE_KEY is empty");
    }
    Keys::parse(value).map_err(|e| anyhow!("BUZZ_PRIVATE_KEY does not parse: {e}"))
}

/// `wss://host` → `https://host`, `ws://host` → `http://host`.
pub fn http_base(relay_url: &str) -> String {
    let url = relay_url.trim_end_matches('/');
    if let Some(rest) = url.strip_prefix("wss://") {
        format!("https://{rest}")
    } else if let Some(rest) = url.strip_prefix("ws://") {
        format!("http://{rest}")
    } else {
        url.to_owned()
    }
}

#[derive(Clone)]
pub struct Publisher {
    http: reqwest::Client,
    keys: Keys,
    events_url: String,
}

impl Publisher {
    pub fn new(relay_url: &str, keys: Keys) -> Result<Self> {
        Ok(Self {
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(15))
                .redirect(reqwest::redirect::Policy::none())
                .build()?,
            keys,
            events_url: format!("{}/events", http_base(relay_url)),
        })
    }

    pub fn keys(&self) -> &Keys {
        &self.keys
    }

    /// Sign `builder` with the provenance tag and POST it to `/events`.
    pub async fn publish(&self, builder: EventBuilder, provenance: Provenance) -> Result<Event> {
        let event = builder.tag(provenance.tag()).sign_with_keys(&self.keys)?;
        self.publish_event(event).await
    }

    /// POST an already-signed event to `/events`, authenticating as this
    /// publisher's key.
    pub async fn publish_event(&self, event: Event) -> Result<Event> {
        let body = event.as_json().into_bytes();
        let auth = self.nip98(&body)?;
        let response = self
            .http
            .post(&self.events_url)
            .header("Authorization", auth)
            .header("Content-Type", "application/json")
            .body(body)
            .send()
            .await
            .context("POST /events")?;
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        let value: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();
        if !status.is_success() || value["accepted"] != true {
            bail!("relay refused event {}: {status} {text}", event.id.to_hex());
        }
        Ok(event)
    }

    fn nip98(&self, body: &[u8]) -> Result<String> {
        let event = EventBuilder::new(Kind::HttpAuth, "")
            .tags([
                Tag::parse(["u", self.events_url.as_str()])?,
                Tag::parse(["method", "POST"])?,
                Tag::parse(["nonce", uuid::Uuid::new_v4().to_string().as_str()])?,
                Tag::parse(["payload", hex::encode(Sha256::digest(body)).as_str()])?,
            ])
            .sign_with_keys(&self.keys)?;
        Ok(format!("Nostr {}", STANDARD.encode(event.as_json())))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_env_takes_the_last_uncommented_assignment() {
        let keys = Keys::generate();
        let hex = keys.secret_key().to_secret_hex();
        let text = format!(
            "# BUZZ_PRIVATE_KEY=nope\nBUZZ_RELAY_URL=wss://x\nBUZZ_PRIVATE_KEY=\"{hex}\"\n"
        );
        assert_eq!(
            parse_key_env(&text).expect("parse").public_key(),
            keys.public_key()
        );
        assert!(parse_key_env("BUZZ_RELAY_URL=wss://x\n").is_err());
        assert!(parse_key_env("BUZZ_PRIVATE_KEY=\n").is_err());
    }

    #[test]
    fn http_base_maps_ws_schemes() {
        assert_eq!(http_base("wss://buzz.aitaco.co/"), "https://buzz.aitaco.co");
        assert_eq!(http_base("ws://localhost:3968"), "http://localhost:3968");
    }

    #[test]
    fn provenance_tags_mark_bridge_events() {
        let keys = Keys::generate();
        let tagged = EventBuilder::new(Kind::Custom(9), "x")
            .tag(Provenance::Transcript.tag())
            .sign_with_keys(&keys)
            .expect("sign");
        let plain = EventBuilder::new(Kind::Custom(9), "x")
            .sign_with_keys(&keys)
            .expect("sign");
        assert!(is_bridge_event(&tagged));
        assert!(!is_bridge_event(&plain));
        assert_eq!(
            Provenance::Ask.tag().as_slice(),
            &["voice-bridge".to_string(), "ask".to_string()]
        );
    }
}
