//! One call: the huddle's audio room on one side, a Gemini Live session on the
//! other, and the seat reachable through `ask_rock`.
//!
//! ```text
//! room (Opus 20 ms) ──decode 16 kHz──▶ Gemini realtimeInput
//! room ◀──encode 24 kHz Opus, paced 20 ms── Gemini audio
//! Gemini transcription ──▶ speaker-labelled lines in the huddle channel
//! Gemini ask_rock ──▶ voice-bridge=ask event in the parent (wakes the seat)
//! seat's reply in that thread ──▶ Gemini user turn "rock answered …"
//! ```

use anyhow::{anyhow, Context, Result};
use buzz_ws_client::{NostrWsConnection, RelayMessage, WsClientError};
use futures_util::{SinkExt, StreamExt};
use nostr::{Event, EventId, Keys};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet, VecDeque};
use std::io::Write;
use std::path::PathBuf;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};
use uuid::Uuid;

use crate::gemini::{self, GeminiStream, ServerEvent, SessionConfig};
use crate::relay_io::{is_bridge_event, Provenance, Publisher};
use crate::room::{self, parse_control, RoomEvent};
use crate::transcript::{Line, Transcript};
use crate::wire::{self, FrameHeader};

/// 20 ms at Gemini's output rate: one Opus frame.
const OUT_FRAME: usize = (gemini::OUTPUT_RATE / 50) as usize;
/// 20 ms at Gemini's input rate.
const IN_FRAME: usize = (gemini::INPUT_RATE / 50) as usize;
/// Feed Gemini silence once the human's audio has stopped for this long, so
/// its voice-activity detection can hear the end of a turn even when the
/// client sends nothing during silence (DTX).
const SILENCE_AFTER: Duration = Duration::from_millis(100);
/// Consecutive Gemini reconnects before the call gives up.
const MAX_GEMINI_RECONNECTS: u32 = 3;

pub struct CallParams {
    pub relay_url: String,
    pub ephemeral: Uuid,
    pub parent: Uuid,
    pub starters: HashSet<String>,
    pub publisher: Publisher,
    pub gemini_url: String,
    pub gemini_key: String,
    pub session: SessionConfig,
    pub human_label: String,
    pub voice_label: String,
    pub log_path: PathBuf,
    pub ask_timeout: Duration,
}

/// Append-only JSONL record of one call: every transcript line, ask, answer,
/// reconnect and usage report. Audio is never written.
struct CallLog {
    file: Option<std::fs::File>,
}

impl CallLog {
    fn open(path: &PathBuf) -> Self {
        let file = path
            .parent()
            .map(std::fs::create_dir_all)
            .transpose()
            .and_then(|_| {
                std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(path)
            });
        match file {
            Ok(file) => Self { file: Some(file) },
            Err(error) => {
                warn!(path = %path.display(), %error, "call log unavailable");
                Self { file: None }
            }
        }
    }

    fn record(&mut self, event: &str, data: Value) {
        let Some(file) = self.file.as_mut() else {
            return;
        };
        let line = json!({ "t": chrono::Utc::now().to_rfc3339(), "event": event, "data": data });
        if let Err(error) = writeln!(file, "{line}") {
            warn!(%error, "call log write failed");
        }
    }
}

/// Answers from the seat, and ask bookkeeping, sent back to the call loop.
enum AskUpdate {
    /// The ask event is published; answer Gemini's tool call.
    Asked { call_id: String, event_id: EventId },
    /// Publishing the ask failed; tell Gemini so it can say so.
    Failed { call_id: String, error: String },
    /// The seat replied in the ask thread.
    Answer { request: String, text: String },
    /// No reply within the ask timeout.
    TimedOut { request: String },
}

struct AskRequest {
    call_id: String,
    request: String,
}

pub async fn run_call(params: CallParams, cancel: CancellationToken) -> Result<()> {
    let mut log = CallLog::open(&params.log_path);
    log.record(
        "call_start",
        json!({ "ephemeral": params.ephemeral, "parent": params.parent, "model": params.session.model }),
    );
    info!(ephemeral = %params.ephemeral, parent = %params.parent, "joining huddle");

    let keys = params.publisher.keys().clone();
    let me = keys.public_key().to_hex();
    let mut room = join_room_with_retry(&params, &keys, &cancel).await?;
    log.record(
        "room_joined",
        json!({ "peer_index": room.self_index, "peers": room.peers }),
    );

    let setup = gemini::setup_message(&params.session, None);
    let mut gemini = gemini::connect(&params.gemini_url, &params.gemini_key, &setup)
        .await
        .context("open the Gemini Live session")?;
    log.record("gemini_connected", json!({ "resumed": false }));
    // Greet once the caller is actually in the room: the bridge usually joins
    // first, on the huddle-start event, before the caller's audio connects.
    let greeting = gemini::user_turn(&format!(
        "{} just joined the call. Greet him in one short sentence.",
        params.human_label
    ));
    let mut greeted = false;
    if room.peers.values().any(|p| params.starters.contains(p)) {
        gemini
            .send(Message::Text(greeting.to_string().into()))
            .await?;
        greeted = true;
    }

    // Ordered transcript posting, off the audio path.
    let (post_tx, post_rx) = mpsc::unbounded_channel::<String>();
    let poster = tokio::spawn(post_lines(
        params.publisher.clone(),
        params.ephemeral,
        post_rx,
    ));

    // Asks: one task owns the thread root and the reply watcher.
    let (ask_tx, ask_rx) = mpsc::unbounded_channel::<AskRequest>();
    let (update_tx, mut update_rx) = mpsc::unbounded_channel::<AskUpdate>();
    let asker = tokio::spawn(run_asks(
        params.publisher.clone(),
        params.relay_url.clone(),
        params.parent,
        params.ephemeral,
        me.clone(),
        params.ask_timeout,
        ask_rx,
        update_tx,
        cancel.child_token(),
    ));

    let mut transcript = Transcript::new(&params.human_label, &params.voice_label);
    let mut decoders: HashMap<u8, (String, opus::Decoder)> = HashMap::new();
    let mut encoder = opus::Encoder::new(
        gemini::OUTPUT_RATE,
        opus::Channels::Mono,
        opus::Application::Voip,
    )?;
    encoder.set_bitrate(opus::Bitrate::Bits(32_000))?;
    let mut out_pcm: VecDeque<i16> = VecDeque::new();
    let mut encoded = vec![0u8; 4000];
    let mut pcm_in = vec![0i16; 5760];
    let mut seq: u16 = 0;
    let mut ts_48k: u32 = 0;
    let mut last_input = Instant::now();
    let mut resume_handle: Option<String> = None;
    let mut reconnects = 0u32;
    // rock's answers wait for Gemini to finish its current sentence instead of
    // cutting it off; tool responses never wait, because Gemini blocks on them.
    let mut speaking = false;
    let mut held: VecDeque<Value> = VecDeque::new();
    let mut tick = tokio::time::interval(Duration::from_millis(20));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    let end_reason: String = loop {
        tokio::select! {
            _ = cancel.cancelled() => break "huddle ended".into(),

            _ = tick.tick() => {
                if out_pcm.len() >= OUT_FRAME {
                    let frame: Vec<i16> = out_pcm.drain(..OUT_FRAME).collect();
                    let len = encoder.encode(&frame, &mut encoded)?;
                    if len > 0 {
                        let header = FrameHeader {
                            seq,
                            ts_48k,
                            level_dbov: wire::level_dbov(&frame),
                            flags: if len <= 2 { wire::FLAG_DTX } else { 0 },
                        };
                        room.ws
                            .send(Message::Binary(wire::client_frame(header, &encoded[..len]).into()))
                            .await
                            .context("send audio to the room")?;
                        seq = seq.wrapping_add(1);
                        ts_48k = ts_48k.wrapping_add(wire::TS_PER_FRAME);
                    }
                }
                if last_input.elapsed() >= SILENCE_AFTER {
                    gemini
                        .send(Message::Text(gemini::audio_input(&[0; IN_FRAME]).to_string().into()))
                        .await
                        .ok();
                }
            }

            message = room.ws.next() => {
                let message = match message {
                    Some(Ok(message)) => message,
                    Some(Err(error)) => break format!("audio socket error: {error}"),
                    None => break "audio socket closed".into(),
                };
                match message {
                    Message::Binary(bytes) => {
                        let Some((index, _header, opus_payload)) = wire::parse_relay_frame(&bytes) else {
                            continue;
                        };
                        let Some(pubkey) = room.peers.get(&index) else { continue };
                        if !params.starters.contains(pubkey) {
                            continue;
                        }
                        let entry = decoders.entry(index);
                        let (owner, decoder) = entry.or_insert_with(|| {
                            (pubkey.clone(), opus::Decoder::new(gemini::INPUT_RATE, opus::Channels::Mono).expect("opus decoder"))
                        });
                        if *owner != *pubkey {
                            *owner = pubkey.clone();
                            *decoder = opus::Decoder::new(gemini::INPUT_RATE, opus::Channels::Mono)?;
                        }
                        match decoder.decode(opus_payload, &mut pcm_in, false) {
                            Ok(n) if n > 0 => {
                                last_input = Instant::now();
                                if let Err(error) = gemini
                                    .send(Message::Text(gemini::audio_input(&pcm_in[..n]).to_string().into()))
                                    .await
                                {
                                    warn!(%error, "audio to Gemini failed; the session will reconnect");
                                }
                            }
                            Ok(_) => {}
                            Err(error) => warn!(%error, "undecodable Opus frame"),
                        }
                    }
                    Message::Text(text) => {
                        let value: Value = serde_json::from_str(&text).unwrap_or_default();
                        match parse_control(&value) {
                            RoomEvent::Joined { peer_index, pubkey } => {
                                log.record("peer_joined", json!({ "peer_index": peer_index, "pubkey": pubkey }));
                                if !greeted && params.starters.contains(&pubkey) {
                                    greeted = true;
                                    gemini.send(Message::Text(greeting.to_string().into())).await.ok();
                                }
                                decoders.remove(&peer_index);
                                room.peers.insert(peer_index, pubkey);
                            }
                            RoomEvent::Left { peer_index, pubkey } => {
                                log.record("peer_left", json!({ "peer_index": peer_index, "pubkey": pubkey }));
                                decoders.remove(&peer_index);
                                room.peers.remove(&peer_index);
                                if params.starters.contains(&pubkey)
                                    && !room.peers.values().any(|p| params.starters.contains(p))
                                {
                                    break "the caller left".into();
                                }
                            }
                            RoomEvent::Error(error) => {
                                log.record("room_error", json!({ "message": error }));
                                break format!("room error: {error}");
                            }
                            RoomEvent::Other => {}
                        }
                    }
                    Message::Ping(data) => {
                        room.ws.send(Message::Pong(data)).await.ok();
                    }
                    Message::Close(_) => break "the relay closed the audio socket".into(),
                    _ => {}
                }
            }

            message = gemini.next() => {
                let parsed = match message {
                    Some(Ok(message)) => gemini::message_json(message),
                    Some(Err(error)) => Err(anyhow::Error::from(error)),
                    None => Err(anyhow!("Gemini closed the socket")),
                };
                let events = match parsed {
                    Ok(Some(value)) => gemini::parse_server_message(&value),
                    Ok(None) => continue,
                    Err(error) => {
                        let error = error.to_string();
                        match reconnect_gemini(&params, resume_handle.as_deref(), &mut reconnects, &mut log, &error).await {
                            Ok(fresh) => { gemini = fresh; continue; }
                            Err(error) => break format!("Gemini session lost: {error}"),
                        }
                    }
                };
                reconnects = 0;
                let mut go_away = false;
                for event in events {
                    match event {
                        ServerEvent::Audio(samples) => {
                            speaking = true;
                            out_pcm.extend(samples);
                        }
                        ServerEvent::InputText(text) => transcript.human(&text),
                        ServerEvent::OutputText(text) => {
                            let lines = transcript.voice(&text);
                            emit(&transcript, lines, &post_tx, &mut log);
                        }
                        ServerEvent::Interrupted => {
                            speaking = false;
                            out_pcm.clear();
                            let lines = transcript.interrupted();
                            emit(&transcript, lines, &post_tx, &mut log);
                        }
                        ServerEvent::TurnComplete => {
                            speaking = false;
                            // Let the tail of the answer play out.
                            let pad = (OUT_FRAME - out_pcm.len() % OUT_FRAME) % OUT_FRAME;
                            out_pcm.extend(std::iter::repeat_n(0, pad));
                            let lines = transcript.turn_complete();
                            emit(&transcript, lines, &post_tx, &mut log);
                        }
                        ServerEvent::ToolCall(calls) => {
                            for call in calls {
                                if call.name == gemini::ASK_ROCK {
                                    let request = call.args["request"].as_str().unwrap_or_default().trim().to_owned();
                                    log.record("ask_rock", json!({ "call_id": call.id, "request": request }));
                                    ask_tx.send(AskRequest { call_id: call.id, request }).ok();
                                } else {
                                    log.record("unknown_tool", json!({ "name": call.name }));
                                    gemini.send(Message::Text(gemini::tool_response(
                                        &call.id, &call.name, json!({ "error": "no such tool" }),
                                    ).to_string().into())).await.ok();
                                }
                            }
                        }
                        ServerEvent::ToolCallCancellation(ids) => {
                            log.record("tool_call_cancelled", json!({ "ids": ids }));
                        }
                        ServerEvent::ResumptionHandle(handle) => resume_handle = Some(handle),
                        ServerEvent::GoAway(time_left) => {
                            log.record("gemini_go_away", json!({ "time_left": time_left }));
                            go_away = true;
                        }
                        ServerEvent::Usage(usage) => log.record("gemini_usage", usage),
                        ServerEvent::Error(error) => {
                            warn!(%error, "Gemini reported an error");
                            log.record("gemini_error", json!({ "message": error }));
                        }
                        ServerEvent::SetupComplete => {}
                    }
                }
                if !speaking {
                    while let Some(message) = held.pop_front() {
                        gemini.send(Message::Text(message.to_string().into())).await.ok();
                    }
                }
                if go_away {
                    match reconnect_gemini(&params, resume_handle.as_deref(), &mut reconnects, &mut log, "goAway").await {
                        Ok(fresh) => gemini = fresh,
                        Err(error) => break format!("Gemini session lost after goAway: {error}"),
                    }
                }
            }

            update = update_rx.recv() => {
                let Some(update) = update else { continue };
                let (message, is_answer) = match update {
                    AskUpdate::Asked { call_id, event_id } => {
                        log.record("ask_posted", json!({ "call_id": call_id, "event_id": event_id.to_hex() }));
                        (gemini::tool_response(&call_id, gemini::ASK_ROCK, json!({
                            "status": "asked",
                            "note": format!("rock has the request. Tell {} briefly that you are checking with rock. The answer will arrive later as a message that starts with \"rock answered\".", params.human_label),
                        })), false)
                    }
                    AskUpdate::Failed { call_id, error } => {
                        log.record("ask_failed", json!({ "call_id": call_id, "error": error }));
                        (gemini::tool_response(&call_id, gemini::ASK_ROCK, json!({
                            "status": "failed",
                            "note": "The request did not reach rock. Say so plainly.",
                        })), false)
                    }
                    AskUpdate::Answer { request, text } => {
                        log.record("rock_answer", json!({ "request": request, "text": text }));
                        (gemini::user_turn(&format!(
                            "rock answered {}'s request \"{request}\": {text}\n\nTell {} this now, briefly and faithfully. Add nothing rock did not say.",
                            params.human_label, params.human_label
                        )), true)
                    }
                    AskUpdate::TimedOut { request } => {
                        log.record("ask_timed_out", json!({ "request": request }));
                        (gemini::user_turn(&format!(
                            "rock answered {}'s request \"{request}\": no answer yet after {} minutes. Tell him the request is waiting in his DM with rock.",
                            params.human_label,
                            params.ask_timeout.as_secs() / 60
                        )), true)
                    }
                };
                if is_answer && speaking {
                    held.push_back(message);
                } else if let Err(error) = gemini.send(Message::Text(message.to_string().into())).await {
                    warn!(%error, "could not deliver an ask update to Gemini");
                }
            }
        }
    };

    info!(ephemeral = %params.ephemeral, reason = %end_reason, "call ending");
    log.record("call_end", json!({ "reason": end_reason }));
    let lines = transcript.finish();
    emit(&transcript, lines, &post_tx, &mut log);
    drop(post_tx);
    drop(ask_tx);
    let _ = room.ws.send(Message::Close(None)).await;
    let _ = gemini.send(Message::Close(None)).await;
    let _ = tokio::time::timeout(Duration::from_secs(10), poster).await;
    asker.abort();

    if !transcript.is_empty() {
        let body = format!(
            "Voice call transcript (huddle `{}`), {} and {}. Written by the voice bridge; lines labelled {} are Gemini speaking with this key.\n\n{}",
            &params.ephemeral.to_string()[..8],
            params.human_label,
            params.voice_label,
            params.voice_label,
            transcript.full_text()
        );
        let body: String = body.chars().take(60 * 1024).collect();
        match buzz_sdk::build_message(params.parent, &body, None, &[], false, &[], &[]) {
            Ok(builder) => match params
                .publisher
                .publish(builder, Provenance::Transcript)
                .await
            {
                Ok(event) => log.record(
                    "transcript_posted",
                    json!({ "event_id": event.id.to_hex() }),
                ),
                Err(error) => log.record(
                    "transcript_post_failed",
                    json!({ "error": error.to_string() }),
                ),
            },
            Err(error) => log.record(
                "transcript_post_failed",
                json!({ "error": error.to_string() }),
            ),
        }
    }
    Ok(())
}

fn emit(
    transcript: &Transcript,
    lines: Vec<Line>,
    post_tx: &mpsc::UnboundedSender<String>,
    log: &mut CallLog,
) {
    for line in lines {
        let text = transcript.render(&line);
        log.record("transcript_line", json!({ "text": text }));
        post_tx.send(text).ok();
    }
}

async fn post_lines(publisher: Publisher, channel: Uuid, mut rx: mpsc::UnboundedReceiver<String>) {
    while let Some(text) = rx.recv().await {
        let builder = match buzz_sdk::build_message(channel, &text, None, &[], false, &[], &[]) {
            Ok(builder) => builder,
            Err(error) => {
                warn!(%error, "transcript line not built");
                continue;
            }
        };
        if let Err(error) = publisher.publish(builder, Provenance::Transcript).await {
            warn!(%error, "transcript line not posted");
        }
    }
}

async fn join_room_with_retry(
    params: &CallParams,
    keys: &Keys,
    cancel: &CancellationToken,
) -> Result<room::Room> {
    let mut last_error = None;
    for attempt in 0..5 {
        if cancel.is_cancelled() {
            break;
        }
        match room::join(&params.relay_url, params.ephemeral, params.parent, keys).await {
            Ok(room) => return Ok(room),
            Err(error) => {
                warn!(attempt, %error, "audio room join failed");
                last_error = Some(error);
                tokio::time::sleep(Duration::from_secs(1 << attempt.min(3))).await;
            }
        }
    }
    Err(last_error.unwrap_or_else(|| anyhow!("cancelled before joining")))
}

async fn reconnect_gemini(
    params: &CallParams,
    handle: Option<&str>,
    reconnects: &mut u32,
    log: &mut CallLog,
    reason: &str,
) -> Result<GeminiStream> {
    loop {
        *reconnects += 1;
        if *reconnects > MAX_GEMINI_RECONNECTS {
            return Err(anyhow!(
                "{MAX_GEMINI_RECONNECTS} reconnects failed; last cause: {reason}"
            ));
        }
        let setup = gemini::setup_message(&params.session, handle);
        match gemini::connect(&params.gemini_url, &params.gemini_key, &setup).await {
            Ok(stream) => {
                log.record(
                    "gemini_connected",
                    json!({ "resumed": handle.is_some(), "reason": reason, "attempt": *reconnects }),
                );
                return Ok(stream);
            }
            Err(error) => {
                warn!(%error, attempt = *reconnects, "Gemini reconnect failed");
                log.record(
                    "gemini_reconnect_failed",
                    json!({ "error": error.to_string() }),
                );
                tokio::time::sleep(Duration::from_millis(500 * u64::from(*reconnects))).await;
            }
        }
    }
}

/// Publish asks in one thread per call and watch that thread for the seat's
/// replies: kind:9 events signed with the same key, in the thread, without the
/// bridge's provenance tag.
#[allow(clippy::too_many_arguments)]
async fn run_asks(
    publisher: Publisher,
    relay_url: String,
    parent: Uuid,
    ephemeral: Uuid,
    me: String,
    ask_timeout: Duration,
    mut ask_rx: mpsc::UnboundedReceiver<AskRequest>,
    update_tx: mpsc::UnboundedSender<AskUpdate>,
    cancel: CancellationToken,
) {
    let mut root: Option<EventId> = None;
    let (reply_tx, mut reply_rx) = mpsc::unbounded_channel::<Event>();
    let mut pending: VecDeque<(String, Instant)> = VecDeque::new();
    let mut check = tokio::time::interval(Duration::from_secs(5));
    loop {
        tokio::select! {
            _ = cancel.cancelled() => return,
            ask = ask_rx.recv() => {
                let Some(ask) = ask else { return };
                let content = format!(
                    "Voice request from Lloyd, relayed by your voice bridge (Gemini) from huddle `{}`:\n\n> {}\n\nReply in this thread. The bridge speaks your reply to Lloyd, so keep it short and speakable.",
                    &ephemeral.to_string()[..8],
                    ask.request.replace('\n', "\n> "),
                );
                let thread = root.map(|root| buzz_sdk::ThreadRef { root_event_id: root, parent_event_id: root });
                let built = buzz_sdk::build_message(parent, &content, thread.as_ref(), &[me.as_str()], false, &[], &[]);
                let result = match built {
                    Ok(builder) => publisher.publish(builder, Provenance::Ask).await,
                    Err(error) => Err(anyhow!("{error}")),
                };
                match result {
                    Ok(event) => {
                        if root.is_none() {
                            root = Some(event.id);
                            tokio::spawn(watch_replies(
                                relay_url.clone(),
                                publisher.keys().clone(),
                                parent,
                                event.id,
                                me.clone(),
                                reply_tx.clone(),
                                cancel.clone(),
                            ));
                        }
                        pending.push_back((ask.request, Instant::now()));
                        update_tx.send(AskUpdate::Asked { call_id: ask.call_id, event_id: event.id }).ok();
                    }
                    Err(error) => {
                        update_tx.send(AskUpdate::Failed { call_id: ask.call_id, error: error.to_string() }).ok();
                    }
                }
            }
            reply = reply_rx.recv() => {
                let Some(reply) = reply else { continue };
                let request = pending.pop_front().map(|(r, _)| r).unwrap_or_else(|| "earlier request".into());
                update_tx.send(AskUpdate::Answer { request, text: reply.content.clone() }).ok();
            }
            _ = check.tick() => {
                while pending.front().is_some_and(|(_, at)| at.elapsed() >= ask_timeout) {
                    if let Some((request, _)) = pending.pop_front() {
                        update_tx.send(AskUpdate::TimedOut { request }).ok();
                    }
                }
            }
        }
    }
}

async fn watch_replies(
    relay_url: String,
    keys: Keys,
    parent: Uuid,
    root: EventId,
    me: String,
    reply_tx: mpsc::UnboundedSender<Event>,
    cancel: CancellationToken,
) {
    let mut seen: HashSet<EventId> = HashSet::new();
    let since = nostr::Timestamp::now().as_secs().saturating_sub(5);
    while !cancel.is_cancelled() {
        let mut conn = match NostrWsConnection::connect_authenticated(&relay_url, &keys, None).await
        {
            Ok(conn) => conn,
            Err(error) => {
                warn!(%error, "reply watcher could not connect");
                tokio::time::sleep(Duration::from_secs(2)).await;
                continue;
            }
        };
        // Channel reads need `#h`; without it the relay closes the REQ.
        let filter = json!({
            "kinds": [9],
            "#h": [parent.to_string()],
            "#e": [root.to_hex()],
            "authors": [me],
            "since": since,
        });
        if conn
            .send_raw(&json!(["REQ", "asks", filter]))
            .await
            .is_err()
        {
            continue;
        }
        loop {
            tokio::select! {
                _ = cancel.cancelled() => return,
                message = conn.next_event(Duration::from_secs(60)) => match message {
                    Ok(RelayMessage::Event { event, .. }) => {
                        if event.pubkey.to_hex() == me && !is_bridge_event(&event) && seen.insert(event.id) {
                            reply_tx.send(*event).ok();
                        }
                    }
                    Ok(RelayMessage::Closed { message, .. }) => {
                        warn!(%message, "the relay closed the reply subscription");
                        tokio::time::sleep(Duration::from_secs(2)).await;
                        break;
                    }
                    Ok(_) | Err(WsClientError::Timeout) => {}
                    Err(error) => {
                        warn!(%error, "reply watcher lost its connection");
                        break;
                    }
                }
            }
        }
    }
}
