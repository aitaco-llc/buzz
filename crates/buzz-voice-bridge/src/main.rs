//! buzz-voice-bridge: a seat's voice in a Buzz huddle.
//!
//! Watches the configured parent channels for a huddle start (kind:48100) by a
//! configured starter, joins that huddle's audio room with the seat's key, and
//! runs the call against Gemini Live until the huddle ends (kind:48103) or the
//! caller leaves. One call at a time.

use anyhow::{Context, Result};
use buzz_voice_bridge::{call, config, gemini, relay_io};
use buzz_ws_client::{NostrWsConnection, RelayMessage, WsClientError};
use clap::Parser;
use nostr::Event;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::time::Duration;
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};
use uuid::Uuid;

const KIND_HUDDLE_STARTED: u16 = 48100;
const KIND_HUDDLE_ENDED: u16 = 48103;

struct ActiveCall {
    ephemeral: Uuid,
    cancel: CancellationToken,
    task: JoinHandle<()>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "buzz_voice_bridge=info".into()),
        )
        .with_writer(std::io::stderr)
        .init();

    let mut args = config::Args::parse();
    args.validate()?;
    let keys = relay_io::load_key_file(&args.key_file)?;
    let gemini_key = args.gemini_api_key().context("Gemini API key")?;
    let publisher = relay_io::Publisher::new(&args.relay_url, keys.clone())?;
    let starters: HashSet<String> = args.starters.iter().cloned().collect();
    let parents: HashSet<Uuid> = args.parent_channels.iter().copied().collect();
    info!(
        pubkey = %keys.public_key().to_hex(),
        relay = %args.relay_url,
        parents = ?parents,
        model = %args.model,
        "voice bridge up"
    );

    let shutdown = CancellationToken::new();
    {
        let shutdown = shutdown.clone();
        tokio::spawn(async move {
            shutdown_signal().await;
            shutdown.cancel();
        });
    }

    let mut active: Option<ActiveCall> = None;
    while !shutdown.is_cancelled() {
        let mut conn =
            match NostrWsConnection::connect_authenticated(&args.relay_url, &keys, None).await {
                Ok(conn) => conn,
                Err(error) => {
                    warn!(%error, "relay connect failed; retrying");
                    tokio::time::sleep(Duration::from_secs(3)).await;
                    continue;
                }
            };
        let filter = json!({
            "kinds": [KIND_HUDDLE_STARTED, KIND_HUDDLE_ENDED],
            "#h": parents.iter().map(Uuid::to_string).collect::<Vec<_>>(),
            "authors": starters.iter().collect::<Vec<_>>(),
            "since": nostr::Timestamp::now().as_secs().saturating_sub(30),
        });
        if let Err(error) = conn.send_raw(&json!(["REQ", "huddles", filter])).await {
            warn!(%error, "subscribe failed; reconnecting");
            continue;
        }
        info!("watching for huddles");
        loop {
            if active.as_ref().is_some_and(|call| call.task.is_finished()) {
                active = None;
            }
            let message = tokio::select! {
                _ = shutdown.cancelled() => break,
                message = conn.next_event(Duration::from_secs(30)) => message,
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
                    );
                }
                Ok(RelayMessage::Closed { message, .. }) => {
                    warn!(%message, "the relay closed the huddle subscription; reconnecting");
                    tokio::time::sleep(Duration::from_secs(3)).await;
                    break;
                }
                Ok(_) | Err(WsClientError::Timeout) => {}
                Err(error) => {
                    warn!(%error, "relay connection lost; reconnecting");
                    break;
                }
            }
        }
    }

    if let Some(call) = active.take() {
        call.cancel.cancel();
        let _ = tokio::time::timeout(Duration::from_secs(15), call.task).await;
    }
    info!("voice bridge stopped");
    Ok(())
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

fn handle_event(
    event: &Event,
    args: &config::Args,
    parents: &HashSet<Uuid>,
    starters: &HashSet<String>,
    publisher: &relay_io::Publisher,
    gemini_key: &str,
    active: &mut Option<ActiveCall>,
) {
    let Some(ephemeral) = ephemeral_of(event) else {
        return;
    };
    let Some(parent) = parent_of(event).filter(|p| parents.contains(p)) else {
        return;
    };
    if !starters.contains(&event.pubkey.to_hex()) {
        return;
    }
    match event.kind.as_u16() {
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
                log_path,
                ask_timeout: Duration::from_secs(args.ask_timeout_secs),
            };
            info!(%ephemeral, %parent, "huddle started; joining");
            let token = cancel.clone();
            let task = tokio::spawn(async move {
                if let Err(error) = call::run_call(params, token).await {
                    warn!(%ephemeral, error = %format!("{error:#}"), "call failed");
                }
            });
            *active = Some(ActiveCall {
                ephemeral,
                cancel,
                task,
            });
        }
        _ => {}
    }
}
