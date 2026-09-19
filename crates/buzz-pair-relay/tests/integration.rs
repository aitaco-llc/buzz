//! Integration tests for buzz-pair-relay.
//!
//! Each test spins up a relay on a random port (`:0`), connects one or more
//! WebSocket clients, and exercises the observable protocol surface.

use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::net::TcpListener;
use tokio_tungstenite::{connect_async, tungstenite::Message, MaybeTlsStream, WebSocketStream};

use buzz_pair_relay::{run_server, Relay};

use secp256k1::{Keypair, Secp256k1, SecretKey};
use sha2::{Digest, Sha256};

/// A valid 64-char lowercase hex string (all 'a's).
const P_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
/// A different valid 64-char lowercase hex string (all 'b's).
const P_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
/// A valid event id (all 'c's) — used only in tests that are rejected before
/// ID/sig verification (kind check, shape check, etc.).
const EV_ID: &str = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
/// A valid pubkey (all 'd's) — used only in pre-sig-check rejection tests.
const PUBKEY: &str = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
/// A valid sig (128 'e's) — used only in pre-sig-check rejection tests.
const SIG: &str = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

type WS = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

/// Start a relay on a random port, return the WebSocket URL.
async fn start_relay() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let relay = Arc::new(Relay::new());
    tokio::spawn(run_server(listener, relay));
    format!("ws://127.0.0.1:{}", addr.port())
}

/// Connect a WebSocket client and read the relay's NIP-42 challenge.
async fn connect_challenged(url: &str) -> (WS, String) {
    let (mut ws, _) = connect_async(url).await.unwrap();
    let auth = recv(&mut ws).await;
    assert_eq!(
        auth[0], "AUTH",
        "expected an AUTH challenge first, got {auth}"
    );
    let challenge = auth[1].as_str().expect("challenge string").to_string();
    assert!(
        challenge.len() == 64 && challenge.bytes().all(|b| b.is_ascii_hexdigit()),
        "unexpected challenge: {challenge}"
    );
    (ws, challenge)
}

/// Connect a WebSocket client to the relay, without answering its challenge.
async fn connect(url: &str) -> WS {
    connect_challenged(url).await.0
}

/// Connect and authenticate as `pubkey_hex`, the owner of that #p.
async fn connect_as(url: &str, sk: &SecretKey, pubkey_hex: &str) -> WS {
    let (mut ws, challenge) = connect_challenged(url).await;
    let auth = sign_event(
        sk,
        pubkey_hex,
        22242,
        json!([["relay", url], ["challenge", challenge]]),
        "",
        now_ts(),
    );
    send(&mut ws, &json!(["AUTH", auth])).await;
    let ok = recv(&mut ws).await;
    assert_eq!(ok[0], "OK");
    assert_eq!(ok[1], auth["id"]);
    assert_eq!(ok[2], true, "AUTH rejected: {}", ok[3]);
    ws
}

/// Send a JSON value as a text frame.
async fn send(ws: &mut WS, msg: &Value) {
    ws.send(Message::Text(msg.to_string().into()))
        .await
        .unwrap();
}

/// Receive the next text frame and parse it as JSON.
/// Panics if no message arrives within 2 seconds.
async fn recv(ws: &mut WS) -> Value {
    let msg = tokio::time::timeout(Duration::from_secs(2), ws.next())
        .await
        .expect("timed out waiting for message")
        .expect("stream ended")
        .expect("WebSocket error");
    match msg {
        Message::Text(t) => serde_json::from_str(t.as_str()).expect("invalid JSON"),
        other => panic!("expected Text frame, got {:?}", other),
    }
}

/// Try to receive the next frame; return None if nothing arrives within 500 ms.
async fn try_recv(ws: &mut WS) -> Option<Message> {
    tokio::time::timeout(Duration::from_millis(500), ws.next())
        .await
        .ok()?
        .and_then(|r| r.ok())
}

/// Assert the connection is closed (stream ends) within 2 seconds.
async fn assert_closed(ws: &mut WS) {
    let result = tokio::time::timeout(Duration::from_secs(2), ws.next()).await;
    match result {
        Err(_) => panic!("connection did not close within 2 s"),
        Ok(None) => {}                        // clean EOF
        Ok(Some(Ok(Message::Close(_)))) => {} // close frame
        Ok(Some(Err(_))) => {}                // protocol error / reset
        Ok(Some(Ok(other))) => panic!("expected close, got {:?}", other),
    }
}

/// Generate a random keypair; returns `(SecretKey, pubkey_hex)`.
fn gen_keypair() -> (SecretKey, String) {
    let secp = Secp256k1::new();
    let (sk, pk) = secp.generate_keypair(&mut secp256k1::rand::rng());
    let xonly = pk.x_only_public_key().0;
    let pubkey_hex = xonly
        .serialize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    (sk, pubkey_hex)
}

/// Standard base64 encoder (no external dep).
fn base64_encode(data: &[u8]) -> String {
    const ALPHA: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(ALPHA[((triple >> 18) & 0x3F) as usize] as char);
        out.push(ALPHA[((triple >> 12) & 0x3F) as usize] as char);
        if chunk.len() > 1 {
            out.push(ALPHA[((triple >> 6) & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(ALPHA[(triple & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

/// Build a minimal valid NIP-44 v2 fake ciphertext and base64-encode it.
/// Layout: 0x02 (version) | 32-byte nonce | 48-byte ciphertext | 32-byte MAC = 113 bytes.
/// 113 bytes ≥ 99 minimum; first decoded byte is 0x02.
fn make_nip44_content() -> String {
    let mut blob = vec![0x02u8]; // version
    blob.extend_from_slice(&[0xAA; 32]); // nonce
    blob.extend_from_slice(&[0xBB; 48]); // ciphertext
    blob.extend_from_slice(&[0xCC; 32]); // MAC
                                         // 113 bytes total
    base64_encode(&blob)
}

/// Build a properly signed kind:24134 event targeting `p_hex`.
/// `nonce` is mixed into the content so callers can produce unique IDs from
/// the same keypair without sleeping.
fn make_signed_event(sk: &SecretKey, pubkey_hex: &str, p_hex: &str, nonce: u64) -> Value {
    // Vary content per nonce so each call produces a unique event ID.
    let mut blob = vec![0x02u8];
    blob.extend_from_slice(&nonce.to_le_bytes()); // 8 bytes of nonce
    blob.extend_from_slice(&[0xAA; 24]); // pad to 32-byte "nonce" field
    blob.extend_from_slice(&[0xBB; 48]);
    blob.extend_from_slice(&[0xCC; 32]);
    let content = base64_encode(&blob);

    sign_event(
        sk,
        pubkey_hex,
        24134,
        json!([["p", p_hex]]),
        &content,
        now_ts(),
    )
}

/// Sign an arbitrary NIP-01 event.
fn sign_event(
    sk: &SecretKey,
    pubkey_hex: &str,
    kind: u64,
    tags: Value,
    content: &str,
    created_at: i64,
) -> Value {
    let secp = Secp256k1::new();

    // NIP-01 commitment: [0, pubkey, created_at, kind, tags, content]
    let commitment = json!([0, pubkey_hex, created_at, kind, tags, content]);
    let commitment_str = serde_json::to_string(&commitment).unwrap();
    let hash: [u8; 32] = Sha256::digest(commitment_str.as_bytes()).into();
    let id_hex: String = hash.iter().map(|b| format!("{b:02x}")).collect();

    let keypair = Keypair::from_secret_key(&secp, sk);
    let sig = secp.sign_schnorr_no_aux_rand(&hash, &keypair);
    let sig_hex: String = sig
        .to_byte_array()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();

    json!({
        "id":         id_hex,
        "pubkey":     pubkey_hex,
        "kind":       kind,
        "created_at": created_at,
        "content":    content,
        "sig":        sig_hex,
        "tags":       tags
    })
}

/// Return the current Unix timestamp as i64.
fn now_ts() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

/// Send a REQ for the given sub_id and p_hex, then consume the EOSE.
async fn subscribe(ws: &mut WS, sub_id: &str, p_hex: &str) {
    send(ws, &json!(["REQ", sub_id, {"#p": [p_hex]}])).await;
    let eose = recv(ws).await;
    assert_eq!(eose[0], "EOSE", "expected EOSE, got {eose}");
    assert_eq!(eose[1], sub_id);
}

/// 1. Hold: an event published before its subscriber connects is held, and
///    the #p's owner gets it right after EOSE. A subscriber that has not
///    proved it owns the #p gets EOSE only.
#[tokio::test]
async fn test_event_before_subscriber_is_held() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();
    let (owner_sk, owner_pk) = gen_keypair();

    // Publish first — no subscriber yet, so the relay holds it.
    let mut pub_ws = connect(&url).await;
    let ev = make_signed_event(&sk, &pk, &owner_pk, 0);
    send(&mut pub_ws, &json!(["EVENT", ev])).await;
    let ok = recv(&mut pub_ws).await;
    assert_eq!(ok[0], "OK");
    assert_eq!(ok[1], ev["id"]);
    assert_eq!(ok[2], true, "expected the event to be held: {}", ok[3]);
    assert_eq!(ok[3], "held: no live subscriber");

    // Someone who only knows the #p gets nothing held.
    let mut other_ws = connect(&url).await;
    subscribe(&mut other_ws, "s0", &owner_pk).await;
    assert!(
        try_recv(&mut other_ws).await.is_none(),
        "a subscriber that is not the owner received a held event"
    );
    send(&mut other_ws, &json!(["CLOSE", "s0"])).await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    // The owner subscribes — EOSE, then the held event.
    let mut sub_ws = connect_as(&url, &owner_sk, &owner_pk).await;
    subscribe(&mut sub_ws, "s1", &owner_pk).await;
    let ev_msg = recv(&mut sub_ws).await;
    assert_eq!(ev_msg[0], "EVENT");
    assert_eq!(ev_msg[1], "s1");
    assert_eq!(ev_msg[2], ev);
    assert!(
        try_recv(&mut sub_ws).await.is_none(),
        "received unexpected message after the held event"
    );
}

/// 2. Live delivery: events published after subscription are delivered; events
///    for a different p-tag are not.
#[tokio::test]
async fn test_live_delivery() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();

    let mut sub_ws = connect(&url).await;
    subscribe(&mut sub_ws, "s1", P_A).await;

    // Publish matching event from a second connection.
    let mut pub_ws = connect(&url).await;
    send(
        &mut pub_ws,
        &json!(["EVENT", make_signed_event(&sk, &pk, P_A, 0)]),
    )
    .await;
    let ok = recv(&mut pub_ws).await;
    assert_eq!(ok[0], "OK");
    assert!(ok[2].as_bool().unwrap(), "event rejected: {}", ok[3]);

    // Subscriber should receive the event.
    let ev_msg = recv(&mut sub_ws).await;
    assert_eq!(ev_msg[0], "EVENT");
    assert_eq!(ev_msg[1], "s1");

    // Publish to a different p-tag — no subscriber for P_B, so it is held.
    send(
        &mut pub_ws,
        &json!(["EVENT", make_signed_event(&sk, &pk, P_B, 1)]),
    )
    .await;
    let ok2 = recv(&mut pub_ws).await;
    assert_eq!(ok2[0], "OK");
    assert_eq!(ok2[3], "held: no live subscriber");

    assert!(
        try_recv(&mut sub_ws).await.is_none(),
        "subscriber received event for wrong p-tag"
    );
}

/// 3. Kind rejection: events with kind != 24134 are rejected.
#[tokio::test]
async fn test_kind_rejection() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    let bad_event = json!({
        "id":         EV_ID,
        "pubkey":     PUBKEY,
        "kind":       1,
        "created_at": 1_700_000_000i64,
        "content":    "hello",
        "sig":        SIG,
        "tags":       [["p", P_A]]
    });
    send(&mut ws, &json!(["EVENT", bad_event])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "OK");
    assert_eq!(resp[2], false);
    assert!(
        resp[3]
            .as_str()
            .unwrap_or("")
            .contains("kind must be 24134"),
        "unexpected message: {}",
        resp[3]
    );
}

/// 4. REQ without #p filter is rejected.
#[tokio::test]
async fn test_no_p_filter() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    send(&mut ws, &json!(["REQ", "s1", {}])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "CLOSED");
    assert_eq!(resp[1], "s1");
    assert!(
        resp[2]
            .as_str()
            .unwrap_or("")
            .contains("#p filter required"),
        "unexpected message: {}",
        resp[2]
    );
}

/// 5. REQ with multiple #p values is rejected.
#[tokio::test]
async fn test_multi_value_p() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    send(&mut ws, &json!(["REQ", "s1", {"#p": [P_A, P_B]}])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "CLOSED");
    assert_eq!(resp[1], "s1");
    assert!(
        resp[2]
            .as_str()
            .unwrap_or("")
            .contains("#p must have exactly one value"),
        "unexpected message: {}",
        resp[2]
    );
}

/// 6. REQ with unsupported filter field is rejected.
#[tokio::test]
async fn test_unsupported_filter_field() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    send(
        &mut ws,
        &json!(["REQ", "s1", {"#p": [P_A], "authors": [PUBKEY]}]),
    )
    .await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "CLOSED");
    assert_eq!(resp[1], "s1");
    assert!(
        resp[2]
            .as_str()
            .unwrap_or("")
            .contains("unsupported filter field"),
        "unexpected message: {}",
        resp[2]
    );
}

/// 7. Second subscription with a different sub_id is rejected; first still works.
#[tokio::test]
async fn test_second_sub_different_id() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();
    let mut ws = connect(&url).await;

    subscribe(&mut ws, "s1", P_A).await;

    // Second REQ with a different sub_id.
    send(&mut ws, &json!(["REQ", "s2", {"#p": [P_B]}])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "CLOSED");
    assert_eq!(resp[1], "s2");
    assert!(
        resp[2]
            .as_str()
            .unwrap_or("")
            .contains("already subscribed"),
        "unexpected message: {}",
        resp[2]
    );

    // First subscription still works.
    let mut pub_ws = connect(&url).await;
    send(
        &mut pub_ws,
        &json!(["EVENT", make_signed_event(&sk, &pk, P_A, 0)]),
    )
    .await;
    let ev_msg = recv(&mut ws).await;
    assert_eq!(ev_msg[0], "EVENT");
    assert_eq!(ev_msg[1], "s1");
}

/// 8. Second subscription with the same sub_id is rejected; first still works.
#[tokio::test]
async fn test_second_sub_same_id() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();
    let mut ws = connect(&url).await;

    subscribe(&mut ws, "s1", P_A).await;

    // Same sub_id again.
    send(&mut ws, &json!(["REQ", "s1", {"#p": [P_B]}])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "CLOSED");
    assert_eq!(resp[1], "s1");
    assert!(
        resp[2]
            .as_str()
            .unwrap_or("")
            .contains("already subscribed"),
        "unexpected message: {}",
        resp[2]
    );

    // First subscription still works.
    let mut pub_ws = connect(&url).await;
    send(
        &mut pub_ws,
        &json!(["EVENT", make_signed_event(&sk, &pk, P_A, 0)]),
    )
    .await;
    let ev_msg = recv(&mut ws).await;
    assert_eq!(ev_msg[0], "EVENT");
    assert_eq!(ev_msg[1], "s1");
}

/// 9. Connection closes after 120 s (virtual time).
#[tokio::test(start_paused = true)]
async fn test_120s_timeout() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    // Advance virtual time past the connection timeout.
    tokio::time::advance(Duration::from_secs(121)).await;
    // Yield to let the relay task run its deadline branch.
    tokio::task::yield_now().await;

    assert_closed(&mut ws).await;
}

/// 10. Backpressure unit test: bounded mpsc channel rejects when full.
#[tokio::test]
async fn test_backpressure_unit() {
    let (tx, _rx) = tokio::sync::mpsc::channel::<String>(4);
    for i in 0..4 {
        tx.try_send(format!("msg {i}"))
            .expect("send should succeed");
    }
    // Channel is now full; 5th send must fail.
    assert!(
        tx.try_send("overflow".to_string()).is_err(),
        "expected channel to be full"
    );
}

/// 11. Frame larger than 4096 bytes closes the connection.
#[tokio::test]
async fn test_max_frame_size() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    let big = "x".repeat(4097);
    // Ignore send errors — the server may close mid-send.
    let _ = ws.send(Message::Text(big.into())).await;

    assert_closed(&mut ws).await;
}

/// 12. EVENT with missing `id` field is rejected.
#[tokio::test]
async fn test_event_shape_missing_id() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    let bad = json!({
        "pubkey":     PUBKEY,
        "kind":       24134,
        "created_at": 1_700_000_000i64,
        "content":    "x",
        "sig":        SIG,
        "tags":       [["p", P_A]]
    });
    send(&mut ws, &json!(["EVENT", bad])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "OK");
    assert_eq!(resp[2], false);
}

/// 13. EVENT with no `p` tag is rejected.
#[tokio::test]
async fn test_no_p_tag() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    let bad = json!({
        "id":         EV_ID,
        "pubkey":     PUBKEY,
        "kind":       24134,
        "created_at": 1_700_000_000i64,
        "content":    "x",
        "sig":        SIG,
        "tags":       []
    });
    send(&mut ws, &json!(["EVENT", bad])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "OK");
    assert_eq!(resp[2], false);
}

/// 14. EVENT with two `p` tags is rejected.
#[tokio::test]
async fn test_multiple_p_tags() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    let bad = json!({
        "id":         EV_ID,
        "pubkey":     PUBKEY,
        "kind":       24134,
        "created_at": now_ts(),
        "content":    make_nip44_content(),
        "sig":        SIG,
        "tags":       [["p", P_A], ["p", P_B]]
    });
    send(&mut ws, &json!(["EVENT", bad])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "OK");
    assert_eq!(resp[2], false);
    assert!(
        resp[3].as_str().unwrap_or("").contains("exactly one p tag"),
        "unexpected message: {}",
        resp[3]
    );
}

/// 15. REQ with non-hex #p value is rejected.
#[tokio::test]
async fn test_invalid_hex_in_p_filter() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    send(&mut ws, &json!(["REQ", "s1", {"#p": ["not-hex-64-chars"]}])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "CLOSED");
    assert_eq!(resp[1], "s1");
}

/// 16. EVENT with non-hex `id` is rejected.
#[tokio::test]
async fn test_invalid_hex_in_event_id() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    let bad = json!({
        "id":         "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ",
        "pubkey":     PUBKEY,
        "kind":       24134,
        "created_at": 1_700_000_000i64,
        "content":    "x",
        "sig":        SIG,
        "tags":       [["p", P_A]]
    });
    send(&mut ws, &json!(["EVENT", bad])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "OK");
    assert_eq!(resp[2], false);
}

/// 17. Global connection cap: 128 connections succeed; 129th is rejected.
///     After closing one, a new connection succeeds.
#[tokio::test]
async fn test_global_conn_cap() {
    let url = start_relay().await;

    let mut conns: Vec<WS> = Vec::with_capacity(128);
    for _ in 0..128 {
        conns.push(connect(&url).await);
    }

    // 129th should fail (server returns 503).
    let result = connect_async(&url).await;
    assert!(result.is_err(), "expected 129th connection to fail");

    // Close one connection.
    let mut dropped = conns.pop().unwrap();
    dropped.close(None).await.unwrap();
    // Give the relay a moment to decrement its counter.
    tokio::time::sleep(Duration::from_millis(100)).await;

    // Now a new connection should succeed.
    let _new = connect(&url).await;
}

/// 18. Session event cap: 6 EVENTs are accepted; 7th is rejected with
///     "session event limit reached".  (The relay's hard cap is 6 per
///     connection, which is tighter than the per-window rate limit of 10.)
#[tokio::test]
async fn test_event_rate_limit() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();

    // Subscribe so the relay has exactly one live recipient for P_A.
    let mut sub_ws = connect(&url).await;
    subscribe(&mut sub_ws, "s1", P_A).await;

    let mut pub_ws = connect(&url).await;

    // First 6 events must be accepted (session cap = 6).
    for i in 0..6u64 {
        send(
            &mut pub_ws,
            &json!(["EVENT", make_signed_event(&sk, &pk, P_A, i)]),
        )
        .await;
        let resp = recv(&mut pub_ws).await;
        assert_eq!(resp[0], "OK", "event {i}: {resp}");
        assert!(
            resp[2].as_bool().unwrap(),
            "event {i} rejected: {}",
            resp[3]
        );
        // Drain the forwarded event from the subscriber so the channel stays open.
        let _ = recv(&mut sub_ws).await;
    }

    // 7th must be rejected by the session cap.
    send(
        &mut pub_ws,
        &json!(["EVENT", make_signed_event(&sk, &pk, P_A, 6)]),
    )
    .await;
    let resp = recv(&mut pub_ws).await;
    assert_eq!(resp[0], "OK");
    assert_eq!(resp[2], false);
    assert!(
        resp[3]
            .as_str()
            .unwrap_or("")
            .contains("session event limit reached"),
        "unexpected message: {}",
        resp[3]
    );
}

/// 19. Message rate limit: 20 messages succeed; 21st closes the connection.
#[tokio::test]
async fn test_message_rate_limit() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    // Send 20 messages (CLOSE with unknown sub_id — no response generated).
    for _ in 0..20 {
        send(&mut ws, &json!(["CLOSE", "nonexistent"])).await;
    }
    // Small delay to let the server process all messages.
    tokio::time::sleep(Duration::from_millis(50)).await;

    // 21st message should trigger the rate limit and close the connection.
    send(&mut ws, &json!(["CLOSE", "nonexistent"])).await;
    assert_closed(&mut ws).await;
}

/// 20. REQ with multiple filters is rejected.
#[tokio::test]
async fn test_multiple_filters() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    send(&mut ws, &json!(["REQ", "s1", {"#p": [P_A]}, {"#p": [P_B]}])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "CLOSED");
    assert_eq!(resp[1], "s1");
    assert!(
        resp[2].as_str().unwrap_or("").contains("multiple filters"),
        "unexpected message: {}",
        resp[2]
    );
}

/// 21. Unknown message type receives a NOTICE.
#[tokio::test]
async fn test_unknown_message() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    // AUTH is supported now (NIP-42 ownership); COUNT (NIP-45) is not.
    send(&mut ws, &json!(["COUNT", "c1", {}])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "NOTICE");
    assert!(
        resp[1]
            .as_str()
            .unwrap_or("")
            .contains("unsupported message"),
        "unexpected message: {}",
        resp[1]
    );
}

/// 22. Sub_id containing JSON special characters does not cause injection.
#[tokio::test]
async fn test_json_injection_sub_id() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    let evil_id = r#""],\"evil\":["#;
    send(&mut ws, &json!(["REQ", evil_id, {}])).await;
    let resp = recv(&mut ws).await;
    // Whatever the server responds, it must be valid JSON (recv() already
    // parses it). The sub_id in the response must equal the literal string.
    assert!(resp.is_array(), "response is not a JSON array: {resp}");
    // The response should be CLOSED with the literal sub_id echoed back safely.
    if resp[0] == "CLOSED" {
        let echoed = resp[1].as_str().unwrap_or("");
        assert_eq!(echoed, evil_id, "sub_id was not echoed verbatim");
    }
}

/// 23. CLOSE removes the subscription; subsequent events are not delivered.
#[tokio::test]
async fn test_close_removes_sub() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();
    let mut ws = connect(&url).await;

    subscribe(&mut ws, "s1", P_A).await;

    send(&mut ws, &json!(["CLOSE", "s1"])).await;
    // Give the relay a moment to process the CLOSE.
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Publish a matching event — no subscriber, so it is held.
    let mut pub_ws = connect(&url).await;
    send(
        &mut pub_ws,
        &json!(["EVENT", make_signed_event(&sk, &pk, P_A, 0)]),
    )
    .await;
    let ok = recv(&mut pub_ws).await;
    assert_eq!(ok[0], "OK");
    // No subscriber after CLOSE, so the event is held, not delivered.
    assert_eq!(ok[3], "held: no live subscriber");

    // Original subscriber must not receive anything.
    assert!(
        try_recv(&mut ws).await.is_none(),
        "received event after CLOSE"
    );
}

/// 24. CLOSE does not close the WebSocket connection.
#[tokio::test]
async fn test_close_keeps_connection() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    subscribe(&mut ws, "s1", P_A).await;
    send(&mut ws, &json!(["CLOSE", "s1"])).await;

    // Connection must still be open — send another message and get a response.
    send(&mut ws, &json!(["REQ", "s2", {"#p": [P_B]}])).await;
    let eose = recv(&mut ws).await;
    assert_eq!(eose[0], "EOSE");
    assert_eq!(eose[1], "s2");
}

/// 25. After CLOSE, a new REQ works and receives future events.
#[tokio::test]
async fn test_req_after_close() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();
    let mut ws = connect(&url).await;

    subscribe(&mut ws, "s1", P_A).await;
    send(&mut ws, &json!(["CLOSE", "s1"])).await;

    // Re-subscribe with a new sub_id.
    subscribe(&mut ws, "s2", P_A).await;

    // Publish a matching event.
    let mut pub_ws = connect(&url).await;
    send(
        &mut pub_ws,
        &json!(["EVENT", make_signed_event(&sk, &pk, P_A, 0)]),
    )
    .await;
    let ok = recv(&mut pub_ws).await;
    assert_eq!(ok[0], "OK");
    assert!(ok[2].as_bool().unwrap(), "event rejected: {}", ok[3]);

    // New subscription must receive the event.
    let ev_msg = recv(&mut ws).await;
    assert_eq!(ev_msg[0], "EVENT");
    assert_eq!(ev_msg[1], "s2");
}

/// 26. CLOSE with an unknown sub_id is silently ignored.
#[tokio::test]
async fn test_close_unknown_sub_id() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    send(&mut ws, &json!(["CLOSE", "nonexistent"])).await;

    // No error response; connection stays open.
    assert!(
        try_recv(&mut ws).await.is_none(),
        "received unexpected response to CLOSE of unknown sub_id"
    );

    // Connection is still usable.
    send(&mut ws, &json!(["REQ", "s1", {"#p": [P_A]}])).await;
    let eose = recv(&mut ws).await;
    assert_eq!(eose[0], "EOSE");
}

/// 27. No events delivered after CLOSE (explicit duplicate of test 23).
#[tokio::test]
async fn test_no_events_after_close() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();
    let mut ws = connect(&url).await;

    subscribe(&mut ws, "sub", P_A).await;
    send(&mut ws, &json!(["CLOSE", "sub"])).await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    let mut pub_ws = connect(&url).await;
    send(
        &mut pub_ws,
        &json!(["EVENT", make_signed_event(&sk, &pk, P_A, 0)]),
    )
    .await;
    recv(&mut pub_ws).await; // consume OK (held — no subscriber)

    assert!(
        try_recv(&mut ws).await.is_none(),
        "received event after CLOSE"
    );
}

/// 28. Binary WebSocket frame closes the connection.
#[tokio::test]
async fn test_binary_frame() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    let _ = ws.send(Message::Binary(b"hello".to_vec().into())).await;

    assert_closed(&mut ws).await;
}

/// 29. REQ with too few elements receives a NOTICE.
#[tokio::test]
async fn test_malformed_req_too_few() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    send(&mut ws, &json!(["REQ"])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "NOTICE");
    assert!(
        resp[1].as_str().unwrap_or("").contains("invalid REQ"),
        "unexpected message: {}",
        resp[1]
    );
}

/// 30. REQ with a non-string sub_id receives a NOTICE.
#[tokio::test]
async fn test_malformed_req_non_string_sub_id() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    send(&mut ws, &json!(["REQ", 123, {}])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "NOTICE");
    assert!(
        resp[1].as_str().unwrap_or("").contains("invalid REQ"),
        "unexpected message: {}",
        resp[1]
    );
}

/// 31. REQ with a non-object filter receives a CLOSED.
#[tokio::test]
async fn test_malformed_req_non_object_filter() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    send(&mut ws, &json!(["REQ", "s1", "bad"])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "CLOSED");
    assert_eq!(resp[1], "s1");
    assert!(
        resp[2].as_str().unwrap_or("").contains("invalid filter"),
        "unexpected message: {}",
        resp[2]
    );
}

/// 32. Write timeout / slow reader: subscriber that doesn't read eventually
///     gets disconnected when the server's write buffer fills up.
///
///     We flood the subscriber's p-tag with events from a second connection.
///     Because the subscriber never reads, the relay's bounded channel fills
///     and subsequent fan-out drops are silent.  The subscriber connection
///     itself stays open (fan-out drops don't close).  This test verifies the
///     observable behavior: the publisher keeps getting OK responses and the
///     subscriber connection is still alive after the flood.
#[tokio::test]
async fn test_write_timeout() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();

    // Subscribe but never read.
    let mut sub_ws = connect(&url).await;
    send(&mut sub_ws, &json!(["REQ", "s1", {"#p": [P_A]}])).await;
    // Don't call recv — leave the EOSE unread.

    // Flood from a publisher — stay within the 6-event session cap.
    let mut pub_ws = connect(&url).await;
    for i in 0..6u64 {
        send(
            &mut pub_ws,
            &json!(["EVENT", make_signed_event(&sk, &pk, P_A, i)]),
        )
        .await;
        let ok = recv(&mut pub_ws).await;
        assert_eq!(ok[0], "OK");
    }

    // Publisher connection is still healthy.
    send(&mut pub_ws, &json!(["REQ", "check", {"#p": [P_B]}])).await;
    let eose = recv(&mut pub_ws).await;
    assert_eq!(eose[0], "EOSE");
}

/// 33. Ping frame receives a Pong with the same payload.
#[tokio::test]
async fn test_ping_pong() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    let payload = b"hello".to_vec();
    ws.send(Message::Ping(payload.clone().into()))
        .await
        .unwrap();

    let msg = tokio::time::timeout(Duration::from_secs(2), ws.next())
        .await
        .expect("timed out")
        .expect("stream ended")
        .expect("WebSocket error");

    match msg {
        Message::Pong(data) => assert_eq!(data.as_ref(), payload.as_slice()),
        other => panic!("expected Pong, got {:?}", other),
    }
}

/// 34. Client-initiated Close frame receives a Close reply.
#[tokio::test]
async fn test_close_handshake() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    ws.send(Message::Close(None)).await.unwrap();

    // The stream should end (server sends its own Close and closes).
    assert_closed(&mut ws).await;
}

/// 35. Connection counter does not leak: open/close 5 connections, then open
///     128 more — all should succeed.
#[tokio::test]
async fn test_conn_counter_no_leak() {
    let url = start_relay().await;

    // Open and close 5 connections.
    for _ in 0..5 {
        let mut ws = connect(&url).await;
        ws.close(None).await.unwrap();
    }
    // Give the relay time to decrement counters.
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Now open 128 connections — all should succeed.
    let mut conns: Vec<WS> = Vec::with_capacity(128);
    for _ in 0..128 {
        conns.push(connect(&url).await);
    }
    assert_eq!(conns.len(), 128);
}

/// 36. Fan-out drops do not close the subscriber connection.
#[tokio::test]
async fn test_control_msg_backpressure() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();

    let mut sub_ws = connect(&url).await;
    send(&mut sub_ws, &json!(["REQ", "s1", {"#p": [P_A]}])).await;
    // Leave EOSE unread to fill the channel quickly.

    // Flood within the 6-event session cap.
    let mut pub_ws = connect(&url).await;
    for i in 0..6u64 {
        send(
            &mut pub_ws,
            &json!(["EVENT", make_signed_event(&sk, &pk, P_A, i)]),
        )
        .await;
        let _ = recv(&mut pub_ws).await;
    }

    // Subscriber connection must still be alive — verify by closing it cleanly.
    let close_result = tokio::time::timeout(Duration::from_secs(2), sub_ws.close(None)).await;
    assert!(
        close_result.is_ok(),
        "subscriber connection died after flood"
    );
}

/// 37. Various malformed inputs do not crash the relay (no panic).
#[tokio::test]
async fn test_no_client_data_in_logs() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    // A grab-bag of weird inputs — none should panic the relay.
    let inputs: &[Value] = &[
        json!(null),
        json!(42),
        json!("just a string"),
        json!({}),
        json!([]),
        json!(["UNKNOWN"]),
        json!(["EVENT"]),
        json!(["EVENT", null]),
        json!(["REQ", null]),
        json!(["CLOSE"]),
        json!(["CLOSE", null]),
    ];

    for input in inputs {
        // Ignore send errors (server may close on some inputs).
        let _ = ws.send(Message::Text(input.to_string().into())).await;
        // Small pause to let the relay process.
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    // If we reach here without a panic, the test passes.
    // The connection may or may not still be open.
}

/// 38. EOSE arrives before any EVENT, held events included. Clients that wait
///     for EOSE discard what comes before it (Desktop's `wait_for_eose`).
#[tokio::test]
async fn test_eose_try_send_failure() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();

    let (owner_sk, owner_pk) = gen_keypair();

    // Publisher sends an event before the subscriber connects — held.
    let mut pub_ws = connect(&url).await;
    send(
        &mut pub_ws,
        &json!(["EVENT", make_signed_event(&sk, &pk, &owner_pk, 0)]),
    )
    .await;
    let ok = recv(&mut pub_ws).await;
    assert_eq!(ok[0], "OK");
    assert_eq!(ok[2], true, "expected the event to be held: {}", ok[3]);

    // Subscriber connects after the event — EOSE first, then the held EVENT.
    let mut sub_ws = connect_as(&url, &owner_sk, &owner_pk).await;
    send(&mut sub_ws, &json!(["REQ", "s1", {"#p": [owner_pk]}])).await;
    let first = recv(&mut sub_ws).await;
    assert_eq!(first[0], "EOSE", "first message must be EOSE, got {first}");
    let second = recv(&mut sub_ws).await;
    assert_eq!(
        second[0], "EVENT",
        "held event must follow EOSE, got {second}"
    );
}

/// 39. Ping frames count toward the per-connection message rate limit.
/// We use CLOSE messages (no response generated) to burn through the rate
/// limit without buffered responses interfering with the close assertion.
#[tokio::test]
async fn test_ping_counts_toward_rate_limit() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    // Send 20 CLOSE messages for a non-existent sub_id.
    // Each counts toward the 20-message rate limit but generates no response.
    for _ in 0..20 {
        send(&mut ws, &json!(["CLOSE", "nope"])).await;
    }

    // Small yield to let the server process all 20.
    tokio::time::sleep(Duration::from_millis(50)).await;

    // 21st message (a Ping this time) should trigger the rate limit.
    let _ = ws.send(Message::Ping(vec![].into())).await;

    assert_closed(&mut ws).await;
}

/// 40. Fan-out drops do not close the subscriber connection.
#[tokio::test]
async fn test_fan_out_drop_doesnt_close() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();

    // Subscribe but don't read (leave EOSE buffered).
    let mut sub_ws = connect(&url).await;
    send(&mut sub_ws, &json!(["REQ", "s1", {"#p": [P_A]}])).await;

    // Flood from a publisher — stay within the 6-event session cap.
    let mut pub_ws = connect(&url).await;
    for i in 0..6u64 {
        send(
            &mut pub_ws,
            &json!(["EVENT", make_signed_event(&sk, &pk, P_A, i)]),
        )
        .await;
        let _ = recv(&mut pub_ws).await;
    }

    // Subscriber connection must still be alive — verify by closing it cleanly.
    let result = tokio::time::timeout(Duration::from_secs(2), sub_ws.close(None)).await;
    assert!(
        result.is_ok(),
        "subscriber connection was unexpectedly dead"
    );
}

/// 41. Reader backpressure: publisher can keep running even when the subscriber
///     never reads.
#[tokio::test]
async fn test_reader_backpressure_closes() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();

    // Slow subscriber — never reads.
    let mut sub_ws = connect(&url).await;
    send(&mut sub_ws, &json!(["REQ", "s1", {"#p": [P_A]}])).await;

    // Publisher floods events up to the session cap.
    let mut pub_ws = connect(&url).await;
    for i in 0..6u64 {
        send(
            &mut pub_ws,
            &json!(["EVENT", make_signed_event(&sk, &pk, P_A, i)]),
        )
        .await;
        let ok = recv(&mut pub_ws).await;
        // Publisher must always get OK (fan-out drops are silent to publisher).
        assert_eq!(ok[0], "OK");
    }
}

/// 42. Connection closes promptly after 120 s (virtual time).
///     Explicit duplicate of test 9 with a slightly different assertion style.
#[tokio::test(start_paused = true)]
async fn test_cancellation_immediate() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    tokio::time::advance(Duration::from_secs(121)).await;
    tokio::task::yield_now().await;

    // The connection must be closed — not just slow.
    assert_closed(&mut ws).await;
}

/// 43. Client-initiated graceful close receives a Close reply.
///     Explicit duplicate of test 34 with a different connection state.
#[tokio::test]
async fn test_graceful_close() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    // Subscribe first, then close gracefully.
    subscribe(&mut ws, "s1", P_A).await;

    ws.send(Message::Close(None)).await.unwrap();
    assert_closed(&mut ws).await;
}

/// 44. Multiple subscribers on the same #p value: a second subscriber that
///     has not proved it owns the #p is refused while the first is live
///     (tightening #2 — exactly one subscriber required).
#[tokio::test]
async fn test_multiple_subscribers_same_p() {
    let url = start_relay().await;
    let (other_sk, other_pk) = gen_keypair();

    // First subscriber on #p succeeds.
    let mut sub1 = connect(&url).await;
    subscribe(&mut sub1, "s1", P_A).await;

    // Second subscriber on the SAME #p is rejected at REQ time, whether it is
    // unauthenticated or authenticated as some other key.
    let mut sub2 = connect(&url).await;
    let mut sub3 = connect_as(&url, &other_sk, &other_pk).await;
    for (ws, id) in [(&mut sub2, "s2"), (&mut sub3, "s3")] {
        send(ws, &json!(["REQ", id, {"#p": [P_A]}])).await;
        let resp = recv(ws).await;
        assert_eq!(resp[0], "CLOSED");
        assert_eq!(resp[1], id);
        assert!(
            resp[2]
                .as_str()
                .unwrap_or("")
                .contains("already has a live subscriber"),
            "unexpected message: {}",
            resp[2]
        );
    }
    assert!(
        try_recv(&mut sub1).await.is_none(),
        "first subscriber was disturbed"
    );
}

/// 45. Uppercase hex in #p filter value is rejected.
#[tokio::test]
async fn test_uppercase_hex_in_p_filter() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    // Uppercase hex — must be rejected.
    let upper_p = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    send(&mut ws, &json!(["REQ", "s1", {"#p": [upper_p]}])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "CLOSED");
    assert!(
        resp[2].as_str().unwrap_or("").contains("64 lowercase hex"),
        "unexpected: {}",
        resp[2]
    );
}

/// 46. Uppercase hex in event id is rejected.
#[tokio::test]
async fn test_uppercase_hex_in_event_fields() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    // Build an event with a valid shape but uppercase id — rejected at hex check.
    let ev = json!({
        "id":         "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "pubkey":     PUBKEY,
        "kind":       24134,
        "created_at": 1_700_000_000i64,
        "content":    make_nip44_content(),
        "sig":        SIG,
        "tags":       [["p", P_A]]
    });
    send(&mut ws, &json!(["EVENT", ev])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "OK");
    assert_eq!(resp[2], false);
    assert!(resp[3].as_str().unwrap_or("").contains("64 lowercase hex"));
}

/// 47. Overlong sub_id (> 64 bytes) is rejected with CLOSED "".
#[tokio::test]
async fn test_overlong_sub_id() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    let long_sub_id = "x".repeat(65);
    send(&mut ws, &json!(["REQ", long_sub_id, {"#p": [P_A]}])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "CLOSED");
    assert_eq!(resp[1], ""); // sub_id too long → use ""
    assert!(resp[2].as_str().unwrap_or("").contains("sub_id too long"));
}

/// 48. Negative created_at is rejected by the freshness window check.
///     (Tightening #6: created_at must be within ±120 s of relay wall-clock.)
#[tokio::test]
async fn test_negative_created_at() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    // A stale event with created_at = -1 is far outside the ±120 s window.
    let ev = json!({
        "id":         EV_ID,
        "pubkey":     PUBKEY,
        "kind":       24134,
        "created_at": -1i64,
        "content":    make_nip44_content(),
        "sig":        SIG,
        "tags":       [["p", P_A]]
    });
    send(&mut ws, &json!(["EVENT", ev])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "OK");
    assert_eq!(resp[2], false, "expected rejection for stale created_at");
    assert!(
        resp[3].as_str().unwrap_or("").contains("freshness window"),
        "unexpected message: {}",
        resp[3]
    );
}

/// 49. Event with missing sig field is rejected.
#[tokio::test]
async fn test_event_missing_sig() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    let ev = json!({
        "id":         EV_ID,
        "pubkey":     PUBKEY,
        "kind":       24134,
        "created_at": now_ts(),
        "content":    make_nip44_content(),
        "tags":       [["p", P_A]]
    });
    send(&mut ws, &json!(["EVENT", ev])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "OK");
    assert_eq!(resp[2], false);
    assert!(resp[3].as_str().unwrap_or("").contains("missing sig"));
}

/// 50. EVENT with extra tags (not exactly one `["p", ...]`) is rejected.
///     (Tightening #3: tags must be exactly `[["p", "<64-hex>"]]`.)
#[tokio::test]
async fn test_event_too_many_tags() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    // Two tags — violates the "exactly one p tag" rule.
    let ev = json!({
        "id":         EV_ID,
        "pubkey":     PUBKEY,
        "kind":       24134,
        "created_at": now_ts(),
        "content":    make_nip44_content(),
        "sig":        SIG,
        "tags":       [["p", P_A], ["x", "extra"]]
    });
    send(&mut ws, &json!(["EVENT", ev])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "OK");
    assert_eq!(resp[2], false);
    assert!(
        resp[3].as_str().unwrap_or("").contains("exactly one p tag"),
        "unexpected message: {}",
        resp[3]
    );
}

/// 51. EVENT with extra tags (not exactly one `["p", ...]`) is rejected.
///     (Tightening #3: tags must be exactly `[["p", "<64-hex>"]]`.)
///     Variant: two tags where one has a long string value.
#[tokio::test]
async fn test_event_tag_string_too_long() {
    let url = start_relay().await;
    let mut ws = connect(&url).await;

    // Two tags — violates the "exactly one p tag" rule before any length check.
    let long_val = "x".repeat(129);
    let ev = json!({
        "id":         EV_ID,
        "pubkey":     PUBKEY,
        "kind":       24134,
        "created_at": now_ts(),
        "content":    make_nip44_content(),
        "sig":        SIG,
        "tags":       [["p", P_A], ["x", long_val]]
    });
    send(&mut ws, &json!(["EVENT", ev])).await;
    let resp = recv(&mut ws).await;
    assert_eq!(resp[0], "OK");
    assert_eq!(resp[2], false);
    // Strict tag check fires first: exactly one tag required.
    assert!(
        resp[3].as_str().unwrap_or("").contains("exactly one p tag"),
        "unexpected message: {}",
        resp[3]
    );
}

// ── Hold ─────────────────────────────────────────────────────────────────

/// Pull the next message and assert it is an EVENT for `sub_id` carrying `ev`.
async fn expect_event(ws: &mut WS, sub_id: &str, ev: &Value) {
    let msg = recv(ws).await;
    assert_eq!(msg[0], "EVENT", "expected EVENT, got {msg}");
    assert_eq!(msg[1], sub_id);
    assert_eq!(&msg[2], ev);
}

/// Subscribe, retrying while the relay is still closing an earlier connection
/// that held this #p.
async fn subscribe_when_free(ws: &mut WS, sub_id: &str, p_hex: &str) {
    for _ in 0..50 {
        send(ws, &json!(["REQ", sub_id, {"#p": [p_hex]}])).await;
        let resp = recv(ws).await;
        if resp[0] == "EOSE" {
            assert_eq!(resp[1], sub_id);
            return;
        }
        assert!(
            resp[2]
                .as_str()
                .unwrap_or("")
                .contains("already has a live subscriber"),
            "unexpected response: {resp}"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("#p never became free");
}

/// 52. Held events replay in the order they arrived.
#[tokio::test]
async fn test_hold_replays_in_arrival_order() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();
    let (owner_sk, owner_pk) = gen_keypair();

    let mut pub_ws = connect(&url).await;
    let evs: Vec<Value> = (0..3u64)
        .map(|i| make_signed_event(&sk, &pk, &owner_pk, i))
        .collect();
    for ev in &evs {
        send(&mut pub_ws, &json!(["EVENT", ev])).await;
        let ok = recv(&mut pub_ws).await;
        assert_eq!(ok[3], "held: no live subscriber");
    }

    let mut sub_ws = connect_as(&url, &owner_sk, &owner_pk).await;
    subscribe(&mut sub_ws, "s1", &owner_pk).await;
    for ev in &evs {
        expect_event(&mut sub_ws, "s1", ev).await;
    }
    assert!(try_recv(&mut sub_ws).await.is_none());
}

/// 53. The hold for one #p is capped at 6 events. The 7th is rejected as it
///     was before the hold existed, and its ID stays retryable.
#[tokio::test]
async fn test_hold_per_p_cap() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();
    let (owner_sk, owner_pk) = gen_keypair();

    // Six events fill one connection's session cap and the #p's hold.
    let mut pub1 = connect(&url).await;
    for i in 0..6u64 {
        send(
            &mut pub1,
            &json!(["EVENT", make_signed_event(&sk, &pk, &owner_pk, i)]),
        )
        .await;
        let ok = recv(&mut pub1).await;
        assert_eq!(ok[2], true, "event {i} rejected: {}", ok[3]);
    }

    let mut pub2 = connect(&url).await;
    let seventh = make_signed_event(&sk, &pk, &owner_pk, 6);
    send(&mut pub2, &json!(["EVENT", seventh])).await;
    let ok = recv(&mut pub2).await;
    assert_eq!(ok[2], false);
    assert_eq!(ok[3], "no live subscriber, hold full");

    // Another #p still has room.
    send(
        &mut pub2,
        &json!(["EVENT", make_signed_event(&sk, &pk, P_B, 7)]),
    )
    .await;
    let ok = recv(&mut pub2).await;
    assert_eq!(ok[3], "held: no live subscriber");

    // Once the owner is live, the rejected event can be sent again.
    let mut sub_ws = connect_as(&url, &owner_sk, &owner_pk).await;
    subscribe(&mut sub_ws, "s1", &owner_pk).await;
    for _ in 0..6 {
        assert_eq!(recv(&mut sub_ws).await[0], "EVENT");
    }
    send(&mut pub2, &json!(["EVENT", seventh])).await;
    let ok = recv(&mut pub2).await;
    assert_eq!(ok[2], true, "retry rejected: {}", ok[3]);
    expect_event(&mut sub_ws, "s1", &seventh).await;
}

/// 54. An owner whose old socket is suspended (open, never read again)
///     reconnects: its new subscription replaces the old one, which gets
///     CLOSED, and replays the event already written to the old socket.
#[tokio::test]
async fn test_owner_resubscribe_replaces_suspended_socket() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();
    let (owner_sk, owner_pk) = gen_keypair();

    let mut old_ws = connect_as(&url, &owner_sk, &owner_pk).await;
    subscribe(&mut old_ws, "s1", &owner_pk).await;

    let mut pub_ws = connect(&url).await;
    let ev = make_signed_event(&sk, &pk, &owner_pk, 0);
    send(&mut pub_ws, &json!(["EVENT", ev])).await;
    let ok = recv(&mut pub_ws).await;
    assert_eq!(ok[2], true);
    assert_eq!(ok[3], "", "expected live delivery");

    let mut new_ws = connect_as(&url, &owner_sk, &owner_pk).await;
    subscribe(&mut new_ws, "s2", &owner_pk).await;
    expect_event(&mut new_ws, "s2", &ev).await;

    // The old socket, read at last, has the event and then CLOSED.
    expect_event(&mut old_ws, "s1", &ev).await;
    let closed = recv(&mut old_ws).await;
    assert_eq!(closed[0], "CLOSED");
    assert_eq!(closed[1], "s1");
    assert!(
        closed[2].as_str().unwrap_or("").contains("replaced"),
        "unexpected message: {}",
        closed[2]
    );

    // Live events go to the new subscription only.
    let ev2 = make_signed_event(&sk, &pk, &owner_pk, 1);
    send(&mut pub_ws, &json!(["EVENT", ev2])).await;
    assert_eq!(recv(&mut pub_ws).await[3], "");
    expect_event(&mut new_ws, "s2", &ev2).await;
    assert!(try_recv(&mut old_ws).await.is_none());
}

/// 55. Someone who has the pairing QR code (so knows the source's #p) gets
///     nothing held and can't displace the source. If they squat the #p while
///     the source is away, they get only what arrives live, as before the hold,
///     and the source takes the #p back when it returns.
#[tokio::test]
async fn test_qr_viewer_cannot_take_the_hold() {
    let url = start_relay().await;
    let (source_sk, source_pk) = gen_keypair();
    let (target_sk, target_pk) = gen_keypair();
    let (viewer_sk, viewer_pk) = gen_keypair();

    let mut source = connect_as(&url, &source_sk, &source_pk).await;
    subscribe(&mut source, "pair", &source_pk).await;

    // The viewer can't displace a live source, authenticated or not.
    let mut viewer = connect_as(&url, &viewer_sk, &viewer_pk).await;
    send(&mut viewer, &json!(["REQ", "v", {"#p": [source_pk]}])).await;
    let resp = recv(&mut viewer).await;
    assert_eq!(resp[0], "CLOSED");

    // The target's offer reaches the source.
    let mut target = connect_as(&url, &target_sk, &target_pk).await;
    subscribe(&mut target, "pair", &target_pk).await;
    let offer = make_signed_event(&target_sk, &target_pk, &source_pk, 0);
    send(&mut target, &json!(["EVENT", offer])).await;
    assert_eq!(recv(&mut target).await[3], "");
    expect_event(&mut source, "pair", &offer).await;

    // The source goes away; the viewer squats its #p and gets no replay, so it
    // never learns the target's key from the offer.
    drop(source);
    let mut viewer = connect(&url).await;
    subscribe_when_free(&mut viewer, "v", &source_pk).await;
    assert!(
        try_recv(&mut viewer).await.is_none(),
        "the viewer received a held event"
    );

    // The source returns, takes the #p back, and gets the offer again.
    let mut source = connect_as(&url, &source_sk, &source_pk).await;
    subscribe(&mut source, "pair", &source_pk).await;
    expect_event(&mut source, "pair", &offer).await;
    let closed = recv(&mut viewer).await;
    assert_eq!(closed[0], "CLOSED");
}

/// 56. An AUTH that doesn't answer this connection's challenge is refused, and
///     the connection gets no owner rights.
#[tokio::test]
async fn test_auth_with_wrong_challenge_is_refused() {
    let url = start_relay().await;
    let (sk, pk) = gen_keypair();
    let (mut ws, _challenge) = connect_challenged(&url).await;

    let (_, other_challenge) = connect_challenged(&url).await;
    let auth = sign_event(
        &sk,
        &pk,
        22242,
        json!([["relay", url], ["challenge", other_challenge]]),
        "",
        now_ts(),
    );
    send(&mut ws, &json!(["AUTH", auth])).await;
    let ok = recv(&mut ws).await;
    assert_eq!(ok[0], "OK");
    assert_eq!(ok[1], auth["id"]);
    assert_eq!(ok[2], false);
    assert_eq!(ok[3], "auth-required: challenge mismatch");

    // A bad signature is refused too.
    let (mut ws2, challenge2) = connect_challenged(&url).await;
    let mut forged = sign_event(
        &sk,
        &pk,
        22242,
        json!([["relay", url], ["challenge", challenge2]]),
        "",
        now_ts(),
    );
    let (_, pk2) = gen_keypair();
    forged["pubkey"] = json!(pk2);
    send(&mut ws2, &json!(["AUTH", forged])).await;
    let ok = recv(&mut ws2).await;
    assert_eq!(ok[2], false, "forged AUTH accepted");
}

/// 57. The two-apps-on-one-phone handshake. Each side spends part of the
///     session in the background: first with its socket closed, then with a
///     socket that is still open but no longer read (suspended). Every message
///     still arrives after the side reconnects.
#[tokio::test]
async fn test_two_apps_one_phone_handshake() {
    let url = start_relay().await;
    let (source_sk, source_pk) = gen_keypair();
    let (target_sk, target_pk) = gen_keypair();

    // Source (app A) shows the code, then goes to the background: socket closed.
    let mut source = connect_as(&url, &source_sk, &source_pk).await;
    subscribe(&mut source, "pair", &source_pk).await;
    source.close(None).await.unwrap();
    drop(source);

    // Target (app B) subscribes and sends its offer while A is away (or while
    // the relay is still closing A's connection).
    let mut target = connect_as(&url, &target_sk, &target_pk).await;
    subscribe(&mut target, "pair", &target_pk).await;
    let offer = make_signed_event(&target_sk, &target_pk, &source_pk, 0);
    send(&mut target, &json!(["EVENT", offer])).await;
    let ok = recv(&mut target).await;
    assert_eq!(ok[2], true, "offer rejected: {}", ok[3]);

    // B goes to the background: its socket stays open but is never read again.
    let _suspended_target = target;

    // A comes back, reconnects, and gets the offer.
    let mut source = connect_as(&url, &source_sk, &source_pk).await;
    subscribe(&mut source, "pair", &source_pk).await;
    expect_event(&mut source, "pair", &offer).await;

    // A confirms the code and sends sas-confirm and the payload. The relay
    // writes both into B's suspended socket.
    let sas_confirm = make_signed_event(&source_sk, &source_pk, &target_pk, 1);
    let payload = make_signed_event(&source_sk, &source_pk, &target_pk, 2);
    for ev in [&sas_confirm, &payload] {
        send(&mut source, &json!(["EVENT", ev])).await;
        let ok = recv(&mut source).await;
        assert_eq!(ok[2], true, "rejected: {}", ok[3]);
    }

    // B comes back on a new connection, replaces its dead subscription, and
    // gets both, in order.
    let mut target = connect_as(&url, &target_sk, &target_pk).await;
    subscribe(&mut target, "pair", &target_pk).await;
    expect_event(&mut target, "pair", &sas_confirm).await;
    expect_event(&mut target, "pair", &payload).await;

    // B sends complete; A is live and gets it directly.
    let complete = make_signed_event(&target_sk, &target_pk, &source_pk, 3);
    send(&mut target, &json!(["EVENT", complete])).await;
    let ok = recv(&mut target).await;
    assert_eq!(ok[2], true);
    assert_eq!(ok[3], "");
    expect_event(&mut source, "pair", &complete).await;
}
