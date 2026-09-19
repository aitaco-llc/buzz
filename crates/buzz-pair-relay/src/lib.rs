//! Ephemeral sidecar relay for NIP-AB device pairing handshakes.
//!
//! Accepts WebSocket connections, matches incoming kind:24134 events against
//! live `#p`-filtered subscriptions, and forwards matches to the subscriber.
//! No persistence. No auth. History only for the hold window (see below).
//!
//! # Deployment
//!
//! This binary binds **loopback only** and MUST run behind a reverse proxy
//! (nginx, caddy, etc.) that:
//! - Routes only `/pair` to this sidecar
//! - Enforces HTTP read timeouts (mitigates slowloris at the TCP layer)
//! - Terminates TLS
//!
//! The relay does not enforce path restrictions or pre-upgrade connection
//! limits — those are the reverse proxy's responsibility.
//!
//! # Security Model
//!
//! - **Signature verification** — Schnorr signatures are verified against the
//!   NIP-01 event ID hash. Events with invalid signatures are rejected.
//! - **No persistence** — events live only in memory, and for at most
//!   [`HOLD_TTL`] (see Hold).
//! - **Bounded resources** — 128 max WS connections, 4 KiB max frame, 120s TTL.
//! - **Session cap** — at most 6 accepted EVENTs per connection.
//! - **Freshness** — `created_at` must be within ±120 s of relay wall-clock.
//! - **Deduplication** — duplicate event IDs are rejected; dedup entries expire after 300 s.
//!
//! # Hold
//!
//! A phone that pairs with another app on the same phone spends part of the
//! handshake in the background, where its socket can be suspended or torn down.
//! So every accepted event is also held for [`HOLD_TTL`], at most
//! [`HOLD_PER_P`] per `#p` and [`HOLD_TOTAL`] in all:
//! - With no live subscriber for its `#p`, the event is held (`OK` true,
//!   `"held: no live subscriber"`). If the hold is full, it is rejected as before.
//! - A new subscription for a `#p` gets `EOSE`, then every held event for that
//!   `#p` in arrival order, including ones already written to an earlier
//!   subscription. The relay can't tell a suspended socket from a live one, so
//!   an event it "delivered" may never have been read. NIP-AB requires clients
//!   to discard duplicates.
//! - A new subscription for a `#p` replaces a subscription for the same `#p` on
//!   another connection, which gets `CLOSED`. That is how a client that
//!   reconnects gets past its own dead socket. Anyone who knows the `#p` could
//!   already take the held events while the owner was away, and events are
//!   NIP-44 encrypted to the owner's ephemeral key, so this adds no exposure.
//! - A timer drops each held event at [`HOLD_TTL`], whether or not it was
//!   delivered.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Weak};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use http_body_util::Full;
use hyper::body::{Bytes, Incoming};
use hyper::header::{
    HeaderValue, CONNECTION, SEC_WEBSOCKET_ACCEPT, SEC_WEBSOCKET_KEY, SEC_WEBSOCKET_VERSION,
    UPGRADE,
};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::upgrade::Upgraded;
use hyper::{Method, Request, Response, StatusCode, Version};
use hyper_util::rt::TokioIo;
use parking_lot::Mutex;
use secp256k1::schnorr::Signature as SchnorrSig;
use secp256k1::XOnlyPublicKey;
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::handshake::derive_accept_key;
use tokio_tungstenite::tungstenite::protocol::{Message, Role, WebSocketConfig};
use tokio_tungstenite::WebSocketStream;
use tokio_util::sync::CancellationToken;

/// Hard per-connection lifetime. `pub(crate)` for test access.
pub(crate) const CONN_TIMEOUT: Duration = Duration::from_secs(120);

const MAX_CONNS: u32 = 128;
/// Writer queue per connection. Room for `EOSE` plus a full replay of the hold
/// for one `#p` ([`HOLD_PER_P`]).
const CHANNEL_CAP: usize = 8;
const KIND_PAIR: u64 = 24134;
/// Max WebSocket frame/message size. NIP-AB handshake payloads are small
/// (ephemeral pubkeys + encrypted session data), well under 4 KiB.
const MAX_FRAME: usize = 4096;
const RATE_WINDOW: Duration = Duration::from_secs(10);
const RATE_MSG_MAX: u32 = 20;
const RATE_EVENT_MAX: u32 = 10;
const SUB_ID_MAX: usize = 64;

/// Hard session cap: at most this many attempted EVENTs (post-sig-check) per connection.
const MAX_EVENTS_PER_CONN: u32 = 6;

/// Per-#p delivery budget: enough for one full pairing from each direction.
const MAX_DELIVERED_PER_P: u32 = 12;

/// Dedup vec rejects new events when still at capacity after TTL eviction (fail closed).
const DEDUP_CAP: usize = 1024;

/// Delivered map rejects new #p keys when still at capacity after TTL eviction (fail closed).
const DELIVERED_MAP_CAP: usize = 4096;

/// TTL for entries in `seen_ids` and `delivered`. Entries older than this are
/// evicted on the next access, keeping both structures bounded over time.
const ENTRY_TTL: Duration = Duration::from_secs(300);

/// Freshness window in seconds (±).
const FRESHNESS_SECS: i64 = 120;

/// How long an accepted event is held for a later subscription. Matches the
/// NIP-AB session timeout.
pub const HOLD_TTL: Duration = Duration::from_secs(120);

/// Held events per `#p`: one sender's full session cap. A NIP-AB session sends
/// at most three events to either side.
pub const HOLD_PER_P: usize = MAX_EVENTS_PER_CONN as usize;

/// Held events across all `#p` values. At 4 KiB per event this is 1 MiB.
pub const HOLD_TOTAL: usize = 256;

enum OutMsg {
    Text(String),
    Pong(Vec<u8>),
    Close,
}

struct Sub {
    conn_id: u64,
    sub_id: String,
    p_value: [u8; 32],
    writer_tx: mpsc::Sender<OutMsg>,
}

struct HeldEvent {
    id: [u8; 32],
    event: Value,
}

#[derive(Default)]
struct Hold {
    by_p: HashMap<[u8; 32], Vec<HeldEvent>>,
    total: usize,
}

impl Hold {
    fn has_room(&self, p_value: &[u8; 32]) -> bool {
        self.total < HOLD_TOTAL && self.by_p.get(p_value).map_or(0, Vec::len) < HOLD_PER_P
    }

    fn remove(&mut self, p_value: &[u8; 32], id: &[u8; 32]) {
        let Some(events) = self.by_p.get_mut(p_value) else {
            return;
        };
        if let Some(pos) = events.iter().position(|h| &h.id == id) {
            events.remove(pos);
            self.total -= 1;
        }
        if events.is_empty() {
            self.by_p.remove(p_value);
        }
    }
}

/// Where an accepted event went.
#[derive(Debug, PartialEq, Eq)]
enum Accepted {
    /// Written to the live subscriber for its `#p`.
    Delivered,
    /// No live subscriber; held for the next one.
    Held,
}

fn event_msg(sub_id: &str, event: &Value) -> Option<String> {
    serde_json::to_string(&Value::Array(vec![
        Value::String("EVENT".into()),
        Value::String(sub_id.into()),
        event.clone(),
    ]))
    .ok()
}

pub struct Relay {
    subs: Mutex<Vec<Sub>>,
    conn_count: AtomicU32,
    next_conn_id: AtomicU64,
    /// Global dedup vec — entries expire after ENTRY_TTL; rejects at DEDUP_CAP after eviction.
    seen_ids: Mutex<Vec<([u8; 32], tokio::time::Instant)>>,
    /// Per-#p delivery counter — entries expire after ENTRY_TTL; rejects at DELIVERED_MAP_CAP after eviction.
    delivered: Mutex<HashMap<[u8; 32], (u32, tokio::time::Instant)>>,
    /// Accepted events, kept for HOLD_TTL. Lock order: subs, then delivered, then hold.
    hold: Mutex<Hold>,
}

impl Default for Relay {
    fn default() -> Self {
        Self::new()
    }
}

impl Relay {
    pub fn new() -> Self {
        Self {
            subs: Mutex::new(Vec::new()),
            conn_count: AtomicU32::new(0),
            next_conn_id: AtomicU64::new(0),
            seen_ids: Mutex::new(Vec::new()),
            delivered: Mutex::new(HashMap::new()),
            hold: Mutex::new(Hold::default()),
        }
    }

    /// Atomically check-and-reserve an event ID. Evicts expired entries first.
    /// Returns `Ok(true)` if duplicate (already seen), `Ok(false)` if new
    /// (reserved — caller MUST call `unreserve_id` if delivery fails),
    /// `Err(())` if at capacity after eviction (fail closed).
    fn reserve_id(&self, id: &[u8; 32]) -> Result<bool, ()> {
        let mut vec = self.seen_ids.lock();
        vec.retain(|(_, ts)| ts.elapsed() < ENTRY_TTL);
        if vec.iter().any(|(eid, _)| eid == id) {
            return Ok(true); // duplicate
        }
        if vec.len() >= DEDUP_CAP {
            return Err(()); // at capacity after eviction — fail closed
        }
        // Optimistically reserve the slot.
        vec.push((*id, tokio::time::Instant::now()));
        Ok(false)
    }

    /// Remove a previously reserved ID (called when delivery fails).
    fn unreserve_id(&self, id: &[u8; 32]) {
        let mut vec = self.seen_ids.lock();
        if let Some(pos) = vec.iter().position(|(eid, _)| eid == id) {
            vec.swap_remove(pos);
        }
    }

    /// Check that the per-#p delivery budget has room for one more delivery.
    /// [`Relay::count_delivery`] spends it.
    fn check_budget(
        delivered: &mut HashMap<[u8; 32], (u32, tokio::time::Instant)>,
        p_value: &[u8; 32],
    ) -> Result<(), &'static str> {
        // Evict entries older than ENTRY_TTL before checking capacity.
        delivered.retain(|_, (_, ts)| ts.elapsed() < ENTRY_TTL);

        let count = delivered.get(p_value).map(|(c, _)| *c).unwrap_or(0);
        if count >= MAX_DELIVERED_PER_P {
            return Err("recipient session budget exhausted");
        }
        // Fail closed if still at capacity after eviction and key is new.
        if delivered.len() >= DELIVERED_MAP_CAP && !delivered.contains_key(p_value) {
            return Err("relay at capacity");
        }
        Ok(())
    }

    fn count_delivery(
        delivered: &mut HashMap<[u8; 32], (u32, tokio::time::Instant)>,
        p_value: &[u8; 32],
    ) {
        // Refresh the timestamp along with the count.
        let entry = delivered
            .entry(*p_value)
            .or_insert((0, tokio::time::Instant::now()));
        entry.0 += 1;
        entry.1 = tokio::time::Instant::now();
    }

    /// Deliver an accepted event to the live subscriber for its `#p`, and hold
    /// it for HOLD_TTL when the hold has room. With no live subscriber the
    /// event is only held, and is rejected if the hold is full.
    ///
    /// `Err(reason)` means the event went nowhere; the caller unreserves its ID.
    fn accept_event(
        self: &Arc<Self>,
        p_value: [u8; 32],
        id: [u8; 32],
        event: &Value,
    ) -> Result<Accepted, &'static str> {
        let subs = self.subs.lock();

        let matching: Vec<&Sub> = subs.iter().filter(|s| s.p_value == p_value).collect();
        if matching.len() > 1 {
            return Err("ambiguous recipient");
        }

        let mut delivered = self.delivered.lock();
        let mut hold = self.hold.lock();
        let hold_it = hold.has_room(&p_value);

        let accepted = match matching.first() {
            None if hold_it => Accepted::Held,
            None => return Err("no live subscriber, hold full"),
            Some(sub) => {
                Self::check_budget(&mut delivered, &p_value)?;
                let text = event_msg(&sub.sub_id, event).ok_or("delivery failed")?;
                if sub.writer_tx.try_send(OutMsg::Text(text)).is_err() {
                    return Err("delivery failed");
                }
                Self::count_delivery(&mut delivered, &p_value);
                Accepted::Delivered
            }
        };

        if hold_it {
            hold.by_p.entry(p_value).or_default().push(HeldEvent {
                id,
                event: event.clone(),
            });
            hold.total += 1;
            let relay: Weak<Relay> = Arc::downgrade(self);
            tokio::spawn(async move {
                tokio::time::sleep(HOLD_TTL).await;
                if let Some(relay) = relay.upgrade() {
                    relay.hold.lock().remove(&p_value, &id);
                }
            });
        }
        Ok(accepted)
    }

    /// Register `conn_id`'s subscription for `p_value`: send `EOSE`, replace any
    /// subscription for the same `#p` on another connection, then replay the
    /// hold for `p_value`. All under the subs lock, so no live event can land
    /// between `EOSE` and the replay.
    ///
    /// `Err(Some(reason))` is a refusal for the client; `Err(None)` means the
    /// connection's writer is full and the caller closes the connection.
    fn subscribe(
        &self,
        conn_id: u64,
        sub_id: &str,
        p_value: [u8; 32],
        writer_tx: &mpsc::Sender<OutMsg>,
    ) -> Result<(), Option<&'static str>> {
        let mut subs = self.subs.lock();
        if subs.iter().any(|s| s.conn_id == conn_id) {
            return Err(Some("error: already subscribed, send CLOSE first"));
        }
        // EOSE before registering, so the caller can back out with nothing changed.
        if writer_tx.try_send(OutMsg::Text(make_eose(sub_id))).is_err() {
            return Err(None);
        }
        if let Some(pos) = subs.iter().position(|s| s.p_value == p_value) {
            let old = subs.swap_remove(pos);
            let _ = old.writer_tx.try_send(OutMsg::Text(make_closed(
                &old.sub_id,
                "error: replaced by a newer subscription for this #p",
            )));
            eprintln!("sub replaced conn_id={} by conn_id={conn_id}", old.conn_id);
        }
        subs.push(Sub {
            conn_id,
            sub_id: sub_id.to_string(),
            p_value,
            writer_tx: writer_tx.clone(),
        });

        let mut delivered = self.delivered.lock();
        let hold = self.hold.lock();
        let Some(held) = hold.by_p.get(&p_value) else {
            return Ok(());
        };
        let mut replayed = 0usize;
        for h in held {
            if Self::check_budget(&mut delivered, &p_value).is_err() {
                break;
            }
            let Some(text) = event_msg(sub_id, &h.event) else {
                continue;
            };
            // A full writer stops the replay; the events stay held for the next REQ.
            if writer_tx.try_send(OutMsg::Text(text)).is_err() {
                break;
            }
            Self::count_delivery(&mut delivered, &p_value);
            replayed += 1;
        }
        eprintln!("sub replayed conn_id={conn_id} events={replayed}");
        Ok(())
    }

    fn remove_sub(&self, conn_id: u64) {
        self.subs.lock().retain(|s| s.conn_id != conn_id);
    }
}

struct ConnGuard {
    relay: Arc<Relay>,
    conn_id: u64,
}

impl Drop for ConnGuard {
    fn drop(&mut self) {
        self.relay.remove_sub(self.conn_id);
        self.relay.conn_count.fetch_sub(1, Ordering::Relaxed);
        eprintln!(
            "conn closed conn_id={} active={}",
            self.conn_id,
            self.relay.conn_count.load(Ordering::Relaxed)
        );
    }
}

struct RateWindow {
    count: u32,
    window_start: tokio::time::Instant,
}

impl RateWindow {
    fn new() -> Self {
        Self {
            count: 0,
            window_start: tokio::time::Instant::now(),
        }
    }

    fn tick(&mut self) -> u32 {
        if self.window_start.elapsed() >= RATE_WINDOW {
            self.count = 0;
            self.window_start = tokio::time::Instant::now();
        }
        self.count += 1;
        self.count
    }
}

fn jarr(v: Vec<Value>) -> String {
    Value::Array(v).to_string()
}

fn make_ok(id: &str, ok: bool, msg: &str) -> String {
    jarr(vec![
        Value::String("OK".into()),
        Value::String(id.into()),
        Value::Bool(ok),
        Value::String(msg.into()),
    ])
}

fn make_closed(sub_id: &str, msg: &str) -> String {
    jarr(vec![
        Value::String("CLOSED".into()),
        Value::String(sub_id.into()),
        Value::String(msg.into()),
    ])
}

fn make_eose(sub_id: &str) -> String {
    jarr(vec![
        Value::String("EOSE".into()),
        Value::String(sub_id.into()),
    ])
}

fn make_notice(msg: &str) -> String {
    jarr(vec![
        Value::String("NOTICE".into()),
        Value::String(msg.into()),
    ])
}

fn is_lower_hex(s: &str, len: usize) -> bool {
    s.len() == len && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn decode_hex32(s: &str) -> Option<[u8; 32]> {
    if !is_lower_hex(s, 64) {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, chunk) in s.as_bytes().chunks(2).enumerate() {
        let hi = (chunk[0] as char).to_digit(16)?;
        let lo = (chunk[1] as char).to_digit(16)?;
        out[i] = (hi * 16 + lo) as u8;
    }
    Some(out)
}

/// Validate a REQ filter. Returns `Ok(p_value)` or `Err(reason)`.
fn validate_filter(filter: &Value) -> Result<[u8; 32], &'static str> {
    let obj = filter.as_object().ok_or("filter must be an object")?;
    for key in obj.keys() {
        match key.as_str() {
            "kinds" | "#p" => {}
            _ => return Err("unsupported filter field"),
        }
    }
    if let Some(kinds) = obj.get("kinds") {
        let arr = kinds.as_array().ok_or("kinds must be an array")?;
        if arr.len() != 1 || arr[0].as_u64() != Some(KIND_PAIR) {
            return Err("kinds must be [24134]");
        }
    }
    let p_arr = obj
        .get("#p")
        .and_then(|v| v.as_array())
        .ok_or("#p filter required")?;
    if p_arr.len() != 1 {
        return Err("#p must have exactly one value");
    }
    let p_str = p_arr[0].as_str().ok_or("#p value must be a string")?;
    decode_hex32(p_str).ok_or("#p value must be 64 lowercase hex chars")
}

/// Validate NIP-44 content structure (no external crate — manual base64 check).
///
/// Checks:
/// - Standard base64 alphabet only (A-Z, a-z, 0-9, +, /, =)
/// - Decoded length ≥ 99 bytes (1 version + 32 nonce + 32 min ciphertext + 32 MAC + 2 padding)
/// - First decoded byte is 0x02 (NIP-44 version 2)
fn validate_nip44_content(content: &str) -> Result<(), &'static str> {
    if content.is_empty() {
        return Err("content must not be empty");
    }

    // Validate base64 alphabet and compute decoded length.
    let bytes = content.as_bytes();
    let len = bytes.len();

    // base64 strings must have length that is a multiple of 4 (with padding).
    if !len.is_multiple_of(4) {
        return Err("content is not valid base64");
    }

    // Check alphabet and count padding.
    let mut pad_count = 0usize;
    for (i, &b) in bytes.iter().enumerate() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'+' | b'/' => {
                if pad_count > 0 {
                    // Non-pad after pad is invalid.
                    return Err("content is not valid base64");
                }
            }
            b'=' => {
                // Padding only allowed in last two positions.
                if i < len - 2 {
                    return Err("content is not valid base64");
                }
                pad_count += 1;
                if pad_count > 2 {
                    return Err("content is not valid base64");
                }
            }
            _ => return Err("content is not valid base64"),
        }
    }

    // Decoded byte length = (len / 4) * 3 - pad_count.
    let decoded_len = (len / 4) * 3 - pad_count;
    if decoded_len < 99 {
        return Err("content too short for NIP-44 v2");
    }

    // Decode only the first byte to check the version prefix.
    // First base64 char encodes bits 7-2 of byte 0; second encodes bits 1-0 of
    // byte 0 (high) and bits 5-2 of byte 1 (low). We only need byte 0.
    let b64_val = |c: u8| -> Option<u8> {
        match c {
            b'A'..=b'Z' => Some(c - b'A'),
            b'a'..=b'z' => Some(c - b'a' + 26),
            b'0'..=b'9' => Some(c - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    };
    let v0 = b64_val(bytes[0]).ok_or("content is not valid base64")?;
    let v1 = b64_val(bytes[1]).ok_or("content is not valid base64")?;
    let first_byte = (v0 << 2) | (v1 >> 4);

    if first_byte != 0x02 {
        return Err("content is not NIP-44 v2 (expected 0x02 prefix)");
    }

    Ok(())
}

/// Validate an EVENT object. Returns `Ok((event_id_str, event_id_bytes, p_value))` or `Err(reason)`.
///
/// Tightenings applied here:
/// - Exactly 7 top-level keys (tightening #4)
/// - Strict tag shape: exactly `[["p", "<64-hex>"]]` (tightening #3)
/// - NIP-44 content validation (tightening #5)
/// - Freshness window on `created_at` (tightening #6)
fn validate_event(ev: &Value) -> Result<(String, [u8; 32], [u8; 32]), &'static str> {
    let obj = ev.as_object().ok_or("event must be an object")?;

    // Tightening #4: reject extra top-level fields.
    const ALLOWED_KEYS: &[&str] = &[
        "id",
        "pubkey",
        "created_at",
        "kind",
        "tags",
        "content",
        "sig",
    ];
    for key in obj.keys() {
        if !ALLOWED_KEYS.contains(&key.as_str()) {
            return Err("unknown top-level field");
        }
    }

    let id = obj.get("id").and_then(|v| v.as_str()).ok_or("missing id")?;
    if !is_lower_hex(id, 64) {
        return Err("id must be 64 lowercase hex chars");
    }
    let id_bytes = decode_hex32(id).ok_or("id must be 64 lowercase hex chars")?;

    let pubkey = obj
        .get("pubkey")
        .and_then(|v| v.as_str())
        .ok_or("missing pubkey")?;
    if !is_lower_hex(pubkey, 64) {
        return Err("pubkey must be 64 lowercase hex chars");
    }
    if obj.get("kind").and_then(|v| v.as_u64()) != Some(KIND_PAIR) {
        return Err("kind must be 24134");
    }

    // Tightening #6: freshness window.
    let created_at = obj
        .get("created_at")
        .and_then(|v| v.as_i64())
        .ok_or("missing created_at")?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    if (created_at as i128 - now as i128).unsigned_abs() > FRESHNESS_SECS as u128 {
        return Err("created_at outside freshness window");
    }

    let content = obj
        .get("content")
        .and_then(|v| v.as_str())
        .ok_or("missing content")?;

    // Tightening #5: NIP-44 content validation.
    validate_nip44_content(content)?;

    let sig = obj
        .get("sig")
        .and_then(|v| v.as_str())
        .ok_or("missing sig")?;
    if !is_lower_hex(sig, 128) {
        return Err("sig must be 128 lowercase hex chars");
    }

    let tags = obj
        .get("tags")
        .and_then(|v| v.as_array())
        .ok_or("missing tags")?;

    // Tightening #3: exactly one tag, exactly ["p", "<64-hex>"].
    if tags.len() != 1 {
        return Err("event must have exactly one p tag");
    }
    let tag = tags[0].as_array().ok_or("tag must be an array")?;
    if tag.len() != 2 {
        return Err("p tag must have exactly 2 elements");
    }
    if tag[0].as_str() != Some("p") {
        return Err("event must have exactly one p tag");
    }
    let p_str = tag[1].as_str().ok_or("p tag value must be a string")?;
    let p_bytes = decode_hex32(p_str).ok_or("p tag value must be 64 lowercase hex chars")?;

    Ok((id.to_string(), id_bytes, p_bytes))
}

fn safe_event_id(ev: &Value) -> String {
    ev.get("id")
        .and_then(|v| v.as_str())
        .filter(|s| is_lower_hex(s, 64))
        .unwrap_or("")
        .to_string()
}

/// Verify the Schnorr signature and event ID for a NIP-01 event.
///
/// Steps:
/// 1. Serialize the commitment array `[0, pubkey, created_at, kind, tags, content]`
///    as compact JSON (no spaces).
/// 2. SHA-256 hash the serialization.
/// 3. Verify the hash matches the claimed `id` field.
/// 4. Verify the Schnorr signature over the hash using the `pubkey` field.
fn verify_event_sig(ev: &Value) -> Result<(), &'static str> {
    let obj = ev.as_object().ok_or("event must be an object")?;

    let pubkey_str = obj
        .get("pubkey")
        .and_then(|v| v.as_str())
        .ok_or("missing pubkey")?;
    let created_at = obj
        .get("created_at")
        .and_then(|v| v.as_i64())
        .ok_or("missing created_at")?;
    let kind = obj
        .get("kind")
        .and_then(|v| v.as_u64())
        .ok_or("missing kind")?;
    let tags = obj.get("tags").ok_or("missing tags")?;
    let content = obj
        .get("content")
        .and_then(|v| v.as_str())
        .ok_or("missing content")?;
    let id_str = obj.get("id").and_then(|v| v.as_str()).ok_or("missing id")?;
    let sig_str = obj
        .get("sig")
        .and_then(|v| v.as_str())
        .ok_or("missing sig")?;

    // Step 1: build the NIP-01 commitment and hash it.
    let commitment = Value::Array(vec![
        Value::Number(0.into()),
        Value::String(pubkey_str.to_string()),
        Value::Number(created_at.into()),
        Value::Number(kind.into()),
        tags.clone(),
        Value::String(content.to_string()),
    ]);
    let commitment_json =
        serde_json::to_string(&commitment).map_err(|_| "failed to serialize commitment")?;
    let hash: [u8; 32] = Sha256::digest(commitment_json.as_bytes()).into();

    // Step 2: verify hash matches claimed id.
    let id_bytes = decode_hex32(id_str).ok_or("id must be 64 lowercase hex chars")?;
    if hash != id_bytes {
        return Err("invalid: event id mismatch");
    }

    // Step 3: parse pubkey as x-only.
    let pubkey_bytes = decode_hex32(pubkey_str).ok_or("pubkey must be 64 lowercase hex chars")?;
    let xonly_pk =
        XOnlyPublicKey::from_byte_array(pubkey_bytes).map_err(|_| "invalid: bad pubkey")?;

    // Step 4: parse sig.
    let sig_bytes = decode_hex64(sig_str).ok_or("sig must be 128 lowercase hex chars")?;
    let schnorr_sig = SchnorrSig::from_byte_array(sig_bytes);

    // Step 5: verify.
    let secp = secp256k1::Secp256k1::verification_only();
    secp.verify_schnorr(&schnorr_sig, &hash, &xonly_pk)
        .map_err(|_| "invalid: signature verification failed")
}

/// Decode a 128-char lowercase hex string into 64 bytes.
fn decode_hex64(s: &str) -> Option<[u8; 64]> {
    if !is_lower_hex(s, 128) {
        return None;
    }
    let mut out = [0u8; 64];
    for (i, chunk) in s.as_bytes().chunks(2).enumerate() {
        let hi = (chunk[0] as char).to_digit(16)?;
        let lo = (chunk[1] as char).to_digit(16)?;
        out[i] = (hi * 16 + lo) as u8;
    }
    Some(out)
}

type WsSink = futures_util::stream::SplitSink<WebSocketStream<TokioIo<Upgraded>>, Message>;

async fn writer_task(mut sink: WsSink, mut rx: mpsc::Receiver<OutMsg>, cancel: CancellationToken) {
    loop {
        let msg = tokio::select! {
            _ = cancel.cancelled() => break,
            m = rx.recv() => match m { Some(m) => m, None => break },
        };
        let ws_msg = match msg {
            OutMsg::Text(s) => Message::Text(s.into()),
            OutMsg::Pong(d) => Message::Pong(d.into()),
            OutMsg::Close => Message::Close(None),
        };
        let result = tokio::select! {
            _ = cancel.cancelled() => break,
            r = timeout(Duration::from_secs(5), sink.send(ws_msg)) => r,
        };
        match result {
            Err(_) => break,     // timeout
            Ok(Err(_)) => break, // send error
            Ok(Ok(())) => {}     // success
        }
    }
}

async fn handle_conn(relay: Arc<Relay>, conn_id: u64, stream: WebSocketStream<TokioIo<Upgraded>>) {
    let _guard = ConnGuard {
        relay: Arc::clone(&relay),
        conn_id,
    };
    let (sink, mut source) = stream.split();
    let (tx, rx) = mpsc::channel::<OutMsg>(CHANNEL_CAP);
    let cancel = CancellationToken::new();
    let writer_handle = tokio::spawn(writer_task(sink, rx, cancel.clone()));
    tokio::pin!(writer_handle);

    let mut msg_rate = RateWindow::new();
    let mut event_rate = RateWindow::new();
    let mut sub_id: Option<String> = None;
    // Tightening #1: hard session cap — counts all valid+sig-verified EVENT attempts.
    let mut events_attempted: u32 = 0;
    let deadline = tokio::time::sleep(CONN_TIMEOUT);
    tokio::pin!(deadline);

    'conn: loop {
        let frame = tokio::select! {
            _ = &mut deadline => break 'conn,
            _ = &mut writer_handle => break 'conn,  // writer died → close
            f = source.next() => match f { Some(f) => f, None => break 'conn },
        };

        // All inbound frames count toward the message rate limit.
        if msg_rate.tick() > RATE_MSG_MAX {
            eprintln!("conn_id={} rate-limited (msg)", conn_id);
            break 'conn;
        }

        let frame = match frame {
            Ok(f) => f,
            Err(_) => break 'conn,
        };

        match frame {
            Message::Binary(_) | Message::Frame(_) => break 'conn,

            Message::Ping(data) => {
                if tx.try_send(OutMsg::Pong(data.to_vec())).is_err() {
                    break 'conn;
                }
            }

            Message::Pong(_) => {}

            Message::Close(_) => {
                let _ = tx.try_send(OutMsg::Close);
                break 'conn;
            }

            Message::Text(text) => {
                let arr: Vec<Value> = match serde_json::from_str::<Value>(text.as_str()).ok() {
                    Some(Value::Array(a)) if !a.is_empty() => a,
                    _ => {
                        let _ = tx.try_send(OutMsg::Text(make_notice("error: invalid message")));
                        continue;
                    }
                };

                let verb = match arr[0].as_str() {
                    Some(v) => v.to_string(),
                    None => {
                        let _ = tx.try_send(OutMsg::Text(make_notice("error: invalid message")));
                        continue;
                    }
                };

                match verb.as_str() {
                    "REQ" => {
                        // Structural validation first (before we have a valid sub_id).
                        if arr.len() < 3 || !arr[1].is_string() {
                            let _ = tx.try_send(OutMsg::Text(make_notice("error: invalid REQ")));
                            continue;
                        }
                        // Now we know arr[1] is a string.
                        let client_sub_id = match arr[1].as_str() {
                            Some(s) if s.len() <= SUB_ID_MAX => s.to_string(),
                            Some(_) => {
                                let _ = tx.try_send(OutMsg::Text(make_closed(
                                    "",
                                    "error: sub_id too long",
                                )));
                                continue;
                            }
                            None => {
                                continue;
                            } // arr[1].is_string() checked above
                        };
                        if arr.len() > 3 {
                            let _ = tx.try_send(OutMsg::Text(make_closed(
                                &client_sub_id,
                                "error: multiple filters not supported",
                            )));
                            continue;
                        }
                        if !arr[2].is_object() {
                            let _ = tx.try_send(OutMsg::Text(make_closed(
                                &client_sub_id,
                                "error: invalid filter",
                            )));
                            continue;
                        }
                        let p_value = match validate_filter(&arr[2]) {
                            Ok(p) => p,
                            Err(reason) => {
                                let _ = tx.try_send(OutMsg::Text(make_closed(
                                    &client_sub_id,
                                    &format!("error: {reason}"),
                                )));
                                continue;
                            }
                        };
                        match relay.subscribe(conn_id, &client_sub_id, p_value, &tx) {
                            Ok(()) => {}
                            Err(Some(reason)) => {
                                let _ =
                                    tx.try_send(OutMsg::Text(make_closed(&client_sub_id, reason)));
                                continue;
                            }
                            Err(None) => break 'conn,
                        }
                        sub_id = Some(client_sub_id);
                    }

                    "EVENT" => {
                        if arr.len() != 2 {
                            let _ = tx.try_send(OutMsg::Text(make_notice("error: invalid EVENT")));
                            continue;
                        }
                        // Rate check before validation (rate check takes priority).
                        if event_rate.tick() > RATE_EVENT_MAX {
                            let safe_id = safe_event_id(&arr[1]);
                            let _ =
                                tx.try_send(OutMsg::Text(make_ok(&safe_id, false, "rate-limited")));
                            continue;
                        }
                        // Tightening #1: hard session cap check.
                        if events_attempted >= MAX_EVENTS_PER_CONN {
                            let safe_id = safe_event_id(&arr[1]);
                            let _ = tx.try_send(OutMsg::Text(make_ok(
                                &safe_id,
                                false,
                                "error: session event limit reached",
                            )));
                            continue;
                        }
                        if !arr[1].is_object() {
                            let _ = tx.try_send(OutMsg::Text(make_ok(
                                "",
                                false,
                                "invalid: malformed event",
                            )));
                            continue;
                        }
                        match validate_event(&arr[1]) {
                            Ok((event_id, id_bytes, p_value)) => {
                                // Tightening #8: Schnorr signature verification BEFORE dedup.
                                if let Err(reason) = verify_event_sig(&arr[1]) {
                                    let _ = tx
                                        .try_send(OutMsg::Text(make_ok(&event_id, false, reason)));
                                    continue;
                                }
                                // Count all valid+sig-verified attempts toward the session cap.
                                events_attempted += 1;
                                // Tightening #7: atomic dedup reservation AFTER sig check.
                                match relay.reserve_id(&id_bytes) {
                                    Ok(true) => {
                                        let _ = tx.try_send(OutMsg::Text(make_ok(
                                            &event_id,
                                            false,
                                            "duplicate: already seen",
                                        )));
                                        continue;
                                    }
                                    Err(()) => {
                                        let _ = tx.try_send(OutMsg::Text(make_ok(
                                            &event_id,
                                            false,
                                            "relay at capacity",
                                        )));
                                        continue;
                                    }
                                    Ok(false) => {} // reserved — proceed to delivery
                                }
                                // Tightening #2: atomically check subscriber and deliver,
                                // or hold for a subscriber that has not connected yet.
                                match relay.accept_event(p_value, id_bytes, &arr[1]) {
                                    Ok(Accepted::Delivered) => {
                                        // ID stays reserved (already in dedup vec).
                                        let _ =
                                            tx.try_send(OutMsg::Text(make_ok(&event_id, true, "")));
                                    }
                                    Ok(Accepted::Held) => {
                                        let _ = tx.try_send(OutMsg::Text(make_ok(
                                            &event_id,
                                            true,
                                            "held: no live subscriber",
                                        )));
                                    }
                                    Err(reason) => {
                                        // Rejected — unreserve so ID can be retried.
                                        relay.unreserve_id(&id_bytes);
                                        let _ = tx.try_send(OutMsg::Text(make_ok(
                                            &event_id, false, reason,
                                        )));
                                    }
                                }
                            }
                            Err(reason) => {
                                let safe_id = safe_event_id(&arr[1]);
                                let _ = tx.try_send(OutMsg::Text(make_ok(
                                    &safe_id,
                                    false,
                                    &format!("invalid: {reason}"),
                                )));
                            }
                        }
                    }

                    "CLOSE" => {
                        if arr.len() != 2 {
                            let _ = tx.try_send(OutMsg::Text(make_notice("error: invalid CLOSE")));
                            continue;
                        }
                        match arr[1].as_str() {
                            Some(sid) => {
                                if sub_id.as_deref() == Some(sid) {
                                    relay.remove_sub(conn_id);
                                    sub_id = None;
                                }
                                // Silently ignore unknown sub_id per NIP-01.
                            }
                            None => {
                                let _ =
                                    tx.try_send(OutMsg::Text(make_notice("error: invalid CLOSE")));
                            }
                        }
                    }

                    _ => {
                        let _ =
                            tx.try_send(OutMsg::Text(make_notice("error: unsupported message")));
                    }
                }
            }
        }
    }

    // Remove the subscription first so its cloned writer_tx is dropped.
    // This allows the channel to close when we drop our local tx.
    relay.remove_sub(conn_id);

    let _ = tx.try_send(OutMsg::Close);

    // Drop the sender so the writer can drain any queued messages (including
    // Close frames), then cancel after a brief grace period.
    drop(tx);

    // Only await the writer if it hasn't already completed (avoid double-poll panic).
    if !writer_handle.is_finished() {
        let _ = tokio::time::timeout(Duration::from_millis(100), &mut writer_handle).await;
    }
    cancel.cancel();
}

async fn http_service(
    relay: Arc<Relay>,
    mut req: Request<Incoming>,
) -> Result<Response<Full<Bytes>>, hyper::Error> {
    let headers = req.headers();
    let key = headers.get(SEC_WEBSOCKET_KEY).cloned();
    let is_ws = req.method() == Method::GET
        && req.version() >= Version::HTTP_11
        && headers
            .get(CONNECTION)
            .and_then(|h| h.to_str().ok())
            .map(|h| {
                h.split([' ', ','])
                    .any(|p| p.eq_ignore_ascii_case("upgrade"))
            })
            .unwrap_or(false)
        && headers
            .get(UPGRADE)
            .and_then(|h| h.to_str().ok())
            .map(|h| h.eq_ignore_ascii_case("websocket"))
            .unwrap_or(false)
        && headers
            .get(SEC_WEBSOCKET_VERSION)
            .map(|h| h == "13")
            .unwrap_or(false)
        && key
            .as_ref()
            .map(|k| k.len() == 24 && k.as_bytes().iter().all(|&b| b.is_ascii()))
            .unwrap_or(false);

    if !is_ws {
        let mut r = Response::new(Full::default());
        *r.status_mut() = StatusCode::BAD_REQUEST;
        return Ok(r);
    }

    // Reserve slot before upgrading.
    if relay.conn_count.fetch_add(1, Ordering::Relaxed) >= MAX_CONNS {
        relay.conn_count.fetch_sub(1, Ordering::Relaxed);
        let mut r = Response::new(Full::default());
        *r.status_mut() = StatusCode::SERVICE_UNAVAILABLE;
        return Ok(r);
    }

    let conn_id = relay.next_conn_id.fetch_add(1, Ordering::Relaxed);
    eprintln!(
        "conn opened conn_id={} active={}",
        conn_id,
        relay.conn_count.load(Ordering::Relaxed)
    );

    let accept = derive_accept_key(key.as_ref().map(|k| k.as_bytes()).unwrap_or(b""));
    let relay_clone = Arc::clone(&relay);

    tokio::spawn(async move {
        match hyper::upgrade::on(&mut req).await {
            Ok(upgraded) => {
                let io = TokioIo::new(upgraded);
                let mut ws_config = WebSocketConfig::default();
                ws_config.max_frame_size = Some(MAX_FRAME);
                ws_config.max_message_size = Some(MAX_FRAME);
                let stream =
                    WebSocketStream::from_raw_socket(io, Role::Server, Some(ws_config)).await;
                handle_conn(relay_clone, conn_id, stream).await;
            }
            Err(e) => {
                eprintln!("upgrade error: {e}");
                relay_clone.conn_count.fetch_sub(1, Ordering::Relaxed);
            }
        }
    });

    let mut resp = Response::new(Full::default());
    *resp.status_mut() = StatusCode::SWITCHING_PROTOCOLS;
    resp.headers_mut()
        .insert(CONNECTION, HeaderValue::from_static("Upgrade"));
    resp.headers_mut()
        .insert(UPGRADE, HeaderValue::from_static("websocket"));
    if let Ok(val) = HeaderValue::from_str(&accept) {
        resp.headers_mut().insert(SEC_WEBSOCKET_ACCEPT, val);
    }
    Ok(resp)
}

/// Run the relay accept loop on the given listener.
/// Public for integration tests that bind to `:0`.
pub async fn run_server(listener: TcpListener, relay: Arc<Relay>) {
    let addr = listener.local_addr().ok();
    if let Some(a) = addr {
        eprintln!("buzz-pair-relay listening on {a}");
    }
    loop {
        let (tcp, _peer) = match listener.accept().await {
            Ok(pair) => pair,
            Err(e) => {
                eprintln!("accept error: {e}");
                continue;
            }
        };
        let relay = Arc::clone(&relay);
        tokio::spawn(async move {
            let io = TokioIo::new(tcp);
            let svc = service_fn(move |req| http_service(Arc::clone(&relay), req));
            if let Err(e) = http1::Builder::new()
                .serve_connection(io, svc)
                .with_upgrades()
                .await
            {
                eprintln!("http error: {e}");
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn key(n: usize) -> [u8; 32] {
        let mut k = [0u8; 32];
        k[..8].copy_from_slice(&(n as u64).to_le_bytes());
        k
    }

    fn is_eose(msg: Result<OutMsg, mpsc::error::TryRecvError>) -> bool {
        matches!(msg, Ok(OutMsg::Text(t)) if t.starts_with("[\"EOSE\""))
    }

    #[tokio::test(start_paused = true)]
    async fn held_event_is_dropped_at_the_window() {
        let relay = Arc::new(Relay::new());
        let (p, id) = (key(1), key(2));
        assert_eq!(
            relay.accept_event(p, id, &json!({"n": 1})),
            Ok(Accepted::Held)
        );

        tokio::time::sleep(HOLD_TTL - Duration::from_millis(1)).await;
        assert_eq!(relay.hold.lock().total, 1, "dropped before the window");

        tokio::time::sleep(Duration::from_millis(2)).await;
        tokio::task::yield_now().await;
        assert_eq!(relay.hold.lock().total, 0, "kept past the window");
        assert!(relay.hold.lock().by_p.is_empty());

        // A subscriber after the window gets EOSE and nothing else.
        let (tx, mut rx) = mpsc::channel(CHANNEL_CAP);
        relay.subscribe(1, "s", p, &tx).unwrap();
        assert!(is_eose(rx.try_recv()));
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn delivered_event_is_also_dropped_at_the_window() {
        let relay = Arc::new(Relay::new());
        let p = key(1);
        let (tx, mut rx) = mpsc::channel(CHANNEL_CAP);
        relay.subscribe(1, "s", p, &tx).unwrap();
        assert!(is_eose(rx.try_recv()));

        assert_eq!(
            relay.accept_event(p, key(2), &json!({"n": 1})),
            Ok(Accepted::Delivered)
        );
        assert_eq!(relay.hold.lock().total, 1);

        tokio::time::sleep(HOLD_TTL + Duration::from_millis(1)).await;
        tokio::task::yield_now().await;
        assert_eq!(relay.hold.lock().total, 0);
    }

    #[tokio::test]
    async fn hold_is_capped_in_total() {
        let relay = Arc::new(Relay::new());
        let ev = json!({});
        for i in 0..HOLD_TOTAL {
            assert_eq!(
                relay.accept_event(key(i), key(100_000 + i), &ev),
                Ok(Accepted::Held)
            );
        }
        let p = key(HOLD_TOTAL);
        assert_eq!(
            relay.accept_event(p, key(200_000), &ev),
            Err("no live subscriber, hold full")
        );

        // A live subscriber still gets events while the hold is full; they
        // just aren't held.
        let (tx, mut rx) = mpsc::channel(CHANNEL_CAP);
        relay.subscribe(1, "s", p, &tx).unwrap();
        assert!(is_eose(rx.try_recv()));
        assert_eq!(
            relay.accept_event(p, key(200_001), &ev),
            Ok(Accepted::Delivered)
        );
        assert!(rx.try_recv().is_ok());
        assert_eq!(relay.hold.lock().total, HOLD_TOTAL);
    }

    #[tokio::test]
    async fn replay_counts_against_the_delivery_budget() {
        let relay = Arc::new(Relay::new());
        let p = key(1);
        for i in 0..3 {
            assert_eq!(
                relay.accept_event(p, key(10 + i), &json!({ "n": i })),
                Ok(Accepted::Held)
            );
        }
        // Four subscriptions replay 3 events each: 12, the per-#p budget.
        for conn in 0..4u64 {
            let (tx, mut rx) = mpsc::channel(CHANNEL_CAP);
            relay.subscribe(conn, "s", p, &tx).unwrap();
            assert!(is_eose(rx.try_recv()));
            for _ in 0..3 {
                assert!(rx.try_recv().is_ok(), "conn {conn} missed a replay");
            }
        }
        // The fifth gets EOSE only.
        let (tx, mut rx) = mpsc::channel(CHANNEL_CAP);
        relay.subscribe(4, "s", p, &tx).unwrap();
        assert!(is_eose(rx.try_recv()));
        assert!(rx.try_recv().is_err());
    }
}
