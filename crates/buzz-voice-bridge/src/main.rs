//! buzz-voice-bridge: a seat's voice in a Buzz huddle.
//!
//! Watches the configured parent channels for a huddle start (kind:48100) by a
//! configured starter, joins that huddle's audio room with the seat's key, and
//! runs the call against Gemini Live until the huddle ends (kind:48103) or the
//! caller leaves. One call at a time.
//!
//! The watcher keeps its own log, `bridge.jsonl`, next to the per-call logs:
//! what it started with, every relay connection and subscription, a heartbeat
//! that proves the subscription is live rather than merely connected, every
//! huddle event it saw and every one it skipped and why, and each call it
//! spawned. A call that never happens is a fact, and this is where it is
//! written down.

use anyhow::{Context, Result};
use buzz_voice_bridge::jsonl::{self, JsonlLog, RateLimit};
use buzz_voice_bridge::{call, config, gemini, relay_io, BUILD_SHA, VERSION};
use buzz_ws_client::{NostrWsConnection, RelayMessage, WsClientError};
use clap::Parser;
use nostr::Event;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::time::{Duration, Instant};
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;
use tracing::{error, info, warn, Instrument};
use uuid::Uuid;

/// The one subscription that matters. Heartbeat probes use `hb-<n>`, and the
/// relay echoes a CLOSED for each of those when we close them.
const HUDDLE_SUB: &str = "huddles";
const KIND_HUDDLE_STARTED: u16 = 48100;
const KIND_HUDDLE_ENDED: u16 = 48103;
/// A heartbeat REQ that has not reached EOSE by now means the subscription is
/// gone even though the socket is not. Reconnect rather than wait for a huddle
/// that will never arrive.
const HEARTBEAT_DEADLINE: Duration = Duration::from_secs(20);
/// How long the watcher blocks for a relay message before looking at its own
/// clock again. It bounds how late a heartbeat or a deadline can be noticed.
const POLL: Duration = Duration::from_secs(5);
/// Expire old call logs this often while the bridge is up.
const SWEEP_EVERY: Duration = Duration::from_secs(24 * 60 * 60);
/// At most one skip record per reason per window, with a suppressed count.
const SKIP_WINDOW: Duration = Duration::from_secs(60);

struct ActiveCall {
    ephemeral: Uuid,
    cancel: CancellationToken,
    task: JoinHandle<()>,
    started: Instant,
    log_path: PathBuf,
}

/// The watcher's log, and the rate limiters that keep a repeating fault from
/// drowning it.
struct Watcher {
    log: JsonlLog,
    skips: HashMap<&'static str, RateLimit>,
}

impl Watcher {
    /// A huddle event the bridge saw and did not act on. Without this, "why
    /// didn't it join" has no evidence at all.
    fn skipped(&mut self, reason: &'static str, event: &Event) {
        let limit = self
            .skips
            .entry(reason)
            .or_insert_with(|| RateLimit::new(SKIP_WINDOW));
        let Some(suppressed) = limit.allow() else {
            return;
        };
        warn!(reason, kind = event.kind.as_u16(), "huddle event skipped");
        self.log.record(
            "skipped",
            json!({
                "reason": reason,
                "kind": event.kind.as_u16(),
                "author": event.pubkey.to_hex(),
                "event_id": event.id.to_hex(),
                "suppressed_since_last": suppressed,
            }),
        );
    }
}

/// Record a startup failure before it takes the process down. The unit
/// restarts on failure, so without this the only trace of a crash loop is a
/// journal that rotates.
fn or_record<T>(result: Result<T>, step: &str, watcher: &mut Watcher) -> Result<T> {
    if let Err(error) = &result {
        let error = format!("{error:#}");
        error!(step, %error, "voice bridge could not start");
        watcher
            .log
            .record("start_failed", json!({ "step": step, "error": error }));
    }
    result
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
                // The transport crates are in the default too: a tungstenite
                // or buzz-ws-client error is exactly what explains a call that
                // never happened, and `buzz_voice_bridge=info` discards it.
                "buzz_voice_bridge=info,buzz_ws_client=info,tokio_tungstenite=info,tungstenite=info"
                    .into()
            }),
        )
        .with_writer(std::io::stderr)
        .init();

    let mut args = config::Args::parse();
    args.validate()?;

    let log_dir = args.log_dir();
    let bridge_path = log_dir.join("bridge.jsonl");
    jsonl::rotate_if_over(&bridge_path, jsonl::ROTATE_AT_BYTES);
    let mut watcher = Watcher {
        log: JsonlLog::open(&bridge_path),
        skips: HashMap::new(),
    };
    watcher.log.record(
        "up",
        json!({
            "build_sha": BUILD_SHA,
            "version": VERSION,
            "pid": std::process::id(),
            "config": args.resolved(),
        }),
    );

    let keys = or_record(
        relay_io::load_key_file(&args.key_file),
        "key_file",
        &mut watcher,
    )?;
    let gemini_key = or_record(
        args.gemini_api_key().context("Gemini API key"),
        "gemini_key",
        &mut watcher,
    )?;
    let publisher = or_record(
        relay_io::Publisher::new(&args.relay_url, keys.clone()),
        "publisher",
        &mut watcher,
    )?;
    let starters: HashSet<String> = args.starters.iter().cloned().collect();
    let parents: HashSet<Uuid> = args.parent_channels.iter().copied().collect();
    let parent_ids: Vec<String> = parents.iter().map(Uuid::to_string).collect();
    info!(
        pubkey = %keys.public_key().to_hex(),
        relay = %args.relay_url,
        parents = ?parents,
        model = %args.model,
        build_sha = BUILD_SHA,
        "voice bridge up"
    );
    watcher.log.record(
        "identity",
        json!({ "pubkey": keys.public_key().to_hex(), "log_dir": log_dir.display().to_string() }),
    );
    let mut last_sweep = sweep(&mut watcher, &log_dir, args.retention_days, &bridge_path);

    let shutdown = CancellationToken::new();
    {
        let shutdown = shutdown.clone();
        tokio::spawn(async move {
            shutdown_signal().await;
            shutdown.cancel();
        });
    }

    let heartbeat_every = Duration::from_secs(args.heartbeat_secs.max(5));
    let mut active: Option<ActiveCall> = None;
    let mut probe_seq: u64 = 0;
    while !shutdown.is_cancelled() {
        if last_sweep.elapsed() >= SWEEP_EVERY {
            last_sweep = sweep(&mut watcher, &log_dir, args.retention_days, &bridge_path);
        }
        let mut conn =
            match NostrWsConnection::connect_authenticated(&args.relay_url, &keys, None).await {
                Ok(conn) => {
                    watcher.log.record("relay_connected", json!({}));
                    conn
                }
                Err(error) => {
                    warn!(%error, "relay connect failed; retrying");
                    watcher.log.record(
                        "relay_connect_failed",
                        json!({ "error": error.to_string() }),
                    );
                    tokio::time::sleep(Duration::from_secs(3)).await;
                    continue;
                }
            };
        let filter = json!({
            "kinds": [KIND_HUDDLE_STARTED, KIND_HUDDLE_ENDED],
            "#h": parent_ids,
            "authors": starters.iter().collect::<Vec<_>>(),
            "since": nostr::Timestamp::now().as_secs().saturating_sub(30),
        });
        if let Err(error) = conn.send_raw(&json!(["REQ", HUDDLE_SUB, filter])).await {
            warn!(%error, "subscribe failed; reconnecting");
            watcher
                .log
                .record("subscribe_failed", json!({ "error": error.to_string() }));
            tokio::time::sleep(Duration::from_secs(3)).await;
            continue;
        }
        info!("watching for huddles");
        watcher.log.record(
            "subscribed",
            json!({
                "kinds": [KIND_HUDDLE_STARTED, KIND_HUDDLE_ENDED],
                "parents": parent_ids,
                "starters": starters.len(),
            }),
        );

        // One outstanding heartbeat at a time: a REQ whose EOSE proves the
        // relay is still serving this socket's subscriptions.
        let mut probe: Option<(String, Instant)> = None;
        let mut last_beat: Option<Instant> = None;
        let mut heartbeats = true;
        loop {
            if let Some(call) = active.as_ref().filter(|call| call.task.is_finished()) {
                watcher.log.record(
                    "call_ended",
                    json!({
                        "ephemeral": call.ephemeral,
                        "duration_ms": call.started.elapsed().as_millis(),
                        "log": call.log_path.display().to_string(),
                    }),
                );
                active = None;
            }
            if heartbeats
                && probe.is_none()
                && last_beat.is_none_or(|at| at.elapsed() >= heartbeat_every)
            {
                probe_seq += 1;
                let id = format!("hb-{probe_seq}");
                // `limit: 0` is NIP-01 for "no results from this filter"
                // (`handlers/req.rs:634`), so the probe costs the relay a
                // registration and an EOSE, and nothing else.
                let probe_filter = json!({
                    "kinds": [KIND_HUDDLE_STARTED],
                    "#h": parent_ids,
                    "limit": 0,
                });
                if let Err(error) = conn.send_raw(&json!(["REQ", id, probe_filter])).await {
                    warn!(%error, "heartbeat could not be sent; reconnecting");
                    watcher
                        .log
                        .record("heartbeat_failed", json!({ "error": error.to_string() }));
                    break;
                }
                probe = Some((id, Instant::now()));
                last_beat = Some(Instant::now());
            }
            if let Some((id, at)) = probe
                .as_ref()
                .filter(|(_, at)| at.elapsed() >= HEARTBEAT_DEADLINE)
            {
                warn!(
                    subscription = %id,
                    after_ms = at.elapsed().as_millis() as u64,
                    "the huddle subscription did not answer a heartbeat; reconnecting"
                );
                watcher.log.record(
                    "heartbeat_missed",
                    json!({ "subscription": id, "after_ms": at.elapsed().as_millis() }),
                );
                break;
            }

            let message = tokio::select! {
                _ = shutdown.cancelled() => break,
                message = conn.next_event(POLL) => message,
            };
            match message {
                Ok(RelayMessage::Event { event, .. }) => {
                    handle_event(
                        &event,
                        &args,
                        &parents,
                        &starters,
                        &publisher,
                        &gemini_key,
                        &mut active,
                        &mut watcher,
                    );
                }
                Ok(RelayMessage::Eose { subscription_id }) => {
                    if probe.as_ref().is_some_and(|(id, _)| *id == subscription_id) {
                        let (id, at) = probe.take().expect("probe matched above");
                        watcher.log.record(
                            "heartbeat",
                            json!({ "rtt_ms": at.elapsed().as_millis(), "in_call": active.is_some() }),
                        );
                        conn.send_raw(&json!(["CLOSE", id])).await.ok();
                    }
                }
                Ok(RelayMessage::Closed {
                    subscription_id,
                    message,
                }) => {
                    // The relay answers our own CLOSE of a finished heartbeat
                    // with a CLOSED for that id. Only the huddle subscription
                    // dying is worth a reconnect; reading the echo as a death
                    // reconnects the watcher every few seconds.
                    if subscription_id != HUDDLE_SUB {
                        if probe.as_ref().is_some_and(|(id, _)| *id == subscription_id) {
                            // Refused before it reached EOSE. That says nothing
                            // about the huddle subscription, so stop probing on
                            // this connection instead of reconnecting in a loop.
                            warn!(%message, "the relay refused the heartbeat subscription");
                            watcher
                                .log
                                .record("heartbeat_rejected", json!({ "message": message }));
                            probe = None;
                            heartbeats = false;
                        }
                        continue;
                    }
                    warn!(%message, "the relay closed the huddle subscription; reconnecting");
                    watcher
                        .log
                        .record("subscription_closed", json!({ "message": message }));
                    tokio::time::sleep(Duration::from_secs(3)).await;
                    break;
                }
                Ok(_) | Err(WsClientError::Timeout) => {}
                Err(error) => {
                    warn!(%error, "relay connection lost; reconnecting");
                    watcher
                        .log
                        .record("relay_lost", json!({ "error": error.to_string() }));
                    break;
                }
            }
        }
    }

    if let Some(call) = active.take() {
        call.cancel.cancel();
        let _ = tokio::time::timeout(Duration::from_secs(15), call.task).await;
        watcher.log.record(
            "call_ended",
            json!({
                "ephemeral": call.ephemeral,
                "duration_ms": call.started.elapsed().as_millis(),
                "log": call.log_path.display().to_string(),
                "on_shutdown": true,
            }),
        );
    }
    info!("voice bridge stopped");
    watcher
        .log
        .record("down", json!({ "pid": std::process::id() }));
    Ok(())
}

/// Expire call logs past the retention window and say how many went.
fn sweep(
    watcher: &mut Watcher,
    dir: &std::path::Path,
    days: u64,
    keep: &std::path::Path,
) -> Instant {
    let removed = jsonl::sweep_older_than(dir, days, keep);
    watcher.log.record(
        "retention_sweep",
        json!({ "removed": removed, "older_than_days": days }),
    );
    Instant::now()
}

/// SIGINT, or SIGTERM where there is one (systemd stops the unit with it).
async fn shutdown_signal() {
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = term.recv() => {}
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

/// The ephemeral channel named in a huddle lifecycle event's content.
fn ephemeral_of(event: &Event) -> Option<Uuid> {
    let content: Value = serde_json::from_str(&event.content).ok()?;
    content["ephemeral_channel_id"].as_str()?.parse().ok()
}

fn parent_of(event: &Event) -> Option<Uuid> {
    event.tags.iter().find_map(|tag| {
        let parts = tag.as_slice();
        (parts.first().map(String::as_str) == Some("h"))
            .then(|| parts.get(1)?.parse().ok())
            .flatten()
    })
}

#[allow(clippy::too_many_arguments)]
fn handle_event(
    event: &Event,
    args: &config::Args,
    parents: &HashSet<Uuid>,
    starters: &HashSet<String>,
    publisher: &relay_io::Publisher,
    gemini_key: &str,
    active: &mut Option<ActiveCall>,
    watcher: &mut Watcher,
) {
    let kind = event.kind.as_u16();
    if kind != KIND_HUDDLE_STARTED && kind != KIND_HUDDLE_ENDED {
        watcher.skipped("not a huddle lifecycle kind", event);
        return;
    }
    let Some(ephemeral) = ephemeral_of(event) else {
        // The one branch a client can reach on its own, by tagging the huddle
        // differently: the content carries no `ephemeral_channel_id`.
        watcher.skipped("no ephemeral_channel_id in content", event);
        return;
    };
    // The subscription filter already restricts `#h` and `authors`, so these
    // two mean the relay sent something the filter should have excluded.
    let Some(parent) = parent_of(event) else {
        watcher.skipped("no h tag", event);
        return;
    };
    if !parents.contains(&parent) {
        watcher.skipped("parent not watched", event);
        return;
    }
    if !starters.contains(&event.pubkey.to_hex()) {
        watcher.skipped("author is not a starter", event);
        return;
    }
    watcher.log.record(
        "huddle_seen",
        json!({
            "kind": kind,
            "ephemeral": ephemeral,
            "parent": parent,
            "author": event.pubkey.to_hex(),
            "event_id": event.id.to_hex(),
        }),
    );
    match kind {
        KIND_HUDDLE_ENDED => {
            if let Some(call) = active.as_ref().filter(|c| c.ephemeral == ephemeral) {
                info!(%ephemeral, "huddle ended");
                call.cancel.cancel();
            }
        }
        KIND_HUDDLE_STARTED => {
            if let Some(call) = active.as_ref() {
                if call.ephemeral != ephemeral {
                    warn!(%ephemeral, busy_with = %call.ephemeral, "already in a call; not joining");
                    watcher.log.record(
                        "busy",
                        json!({ "ephemeral": ephemeral, "busy_with": call.ephemeral }),
                    );
                }
                return;
            }
            let cancel = CancellationToken::new();
            let log_path = args.log_dir().join(format!(
                "{}-{}.jsonl",
                chrono::Utc::now().format("%Y%m%dT%H%M%SZ"),
                &ephemeral.to_string()[..8]
            ));
            let params = call::CallParams {
                relay_url: args.relay_url.clone(),
                ephemeral,
                parent,
                starters: starters.clone(),
                publisher: publisher.clone(),
                gemini_url: args.gemini_url.clone(),
                gemini_key: gemini_key.to_owned(),
                session: gemini::SessionConfig {
                    model: args.model.clone(),
                    system_instruction: args.system_instruction(),
                    voice: args.voice.clone(),
                },
                human_label: args.human_label.clone(),
                voice_label: args.voice_label.clone(),
                log_path: log_path.clone(),
                ask_timeout: Duration::from_secs(args.ask_timeout_secs),
                progress_every: Duration::from_secs(args.progress_secs.max(1)),
                working_sound: args.working_sound,
                working_sound_gain: args.working_sound_gain,
                working_sound_delay: Duration::from_millis(args.working_sound_delay_ms),
                config: args.resolved(),
                trace_frames: args.trace_frames,
            };
            info!(%ephemeral, %parent, "huddle started; joining");
            watcher.log.record(
                "call_spawned",
                json!({
                    "ephemeral": ephemeral,
                    "parent": parent,
                    "log": log_path.display().to_string(),
                }),
            );
            let token = cancel.clone();
            // Every journald line the call produces carries the ephemeral, so
            // a JSONL record and a journal line can be put side by side.
            let span = tracing::info_span!("call", ephemeral = %ephemeral);
            let task = tokio::spawn(
                async move {
                    // run_call writes `call_failed` and logs the error chain
                    // itself, inside this span.
                    let _ = call::run_call(params, token).await;
                }
                .instrument(span),
            );
            *active = Some(ActiveCall {
                ephemeral,
                cancel,
                task,
                started: Instant::now(),
                log_path,
            });
        }
        _ => {}
    }
}
