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
//!
//! Every call writes one JSONL log, and every call writes an ending: either
//! `call_end` with a reason or `call_failed` with the error chain that stopped
//! it. Audio is counted, never written.

use anyhow::{anyhow, Context, Result};
use buzz_ws_client::{NostrWsConnection, RelayMessage, WsClientError};
use futures_util::{SinkExt, StreamExt};
use nostr::{Event, EventId, Keys};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_util::sync::CancellationToken;
use tracing::{error, info, warn};
use uuid::Uuid;

use crate::gemini::{self, GeminiStream, ServerEvent, SessionConfig};
use crate::jsonl::{JsonlLog, RateLimit};
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
/// How often the running audio counters are written to the call log.
const STATS_EVERY: Duration = Duration::from_secs(5);
/// A fault on the audio path repeats at 50 frames/s. Report it at most this
/// often, with the count of what was swallowed.
const FAULT_WINDOW: Duration = Duration::from_secs(5);

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
    /// The watcher's resolved configuration, recorded on `call_start` so the
    /// call log explains itself.
    pub config: Value,
    /// Write every Gemini server message to a sidecar, audio elided.
    pub trace_frames: bool,
}

/// Append-only JSONL record of one call: every transcript line, ask, answer,
/// reconnect, usage report and audio count. Audio is never written.
type CallLog = JsonlLog;

/// What the call did, for `call_end` and for the outcome posted to the parent.
#[derive(Debug, Default)]
struct Outcome {
    /// Where the call had got to, so a failure names the stage that failed.
    phase: &'static str,
    peers: BTreeSet<String>,
    asks: u32,
    answers: u32,
    timeouts: u32,
    ask_failures: u32,
    /// Gemini reconnects over the whole call, unlike the consecutive counter
    /// that the reconnect limit uses.
    reconnects: u32,
    errors: u32,
}

impl Outcome {
    fn counts(&self) -> Value {
        json!({
            "phase": self.phase,
            "peers": self.peers,
            "asks": self.asks,
            "answers": self.answers,
            "timeouts": self.timeouts,
            "ask_failures": self.ask_failures,
            "reconnects": self.reconnects,
            "errors": self.errors,
        })
    }
}

/// What one peer sent us, and what became of it.
#[derive(Debug, Default)]
struct PeerAudio {
    pubkey: String,
    opus_frames: u64,
    decode_errors: u64,
    /// PCM samples decoded and handed to Gemini at 16 kHz.
    pcm_samples: u64,
}

/// Running counts on both audio directions. Cumulative since `call_start`:
/// differencing two records gives the rate, the last one gives the totals.
#[derive(Debug, Default)]
struct AudioStats {
    inbound: BTreeMap<u8, PeerAudio>,
    to_gemini_errors: u64,
    gemini_audio_frames: u64,
    gemini_samples: u64,
    opus_frames_out: u64,
    dtx_frames_out: u64,
    samples_out: u64,
    silence_injections: u64,
    silence_errors: u64,
}

impl AudioStats {
    fn peer(&mut self, index: u8, pubkey: &str) -> &mut PeerAudio {
        let entry = self.inbound.entry(index).or_default();
        if entry.pubkey != pubkey {
            entry.pubkey = pubkey.to_owned();
        }
        entry
    }

    fn snapshot(&self, elapsed: Duration) -> Value {
        json!({
            "elapsed_ms": elapsed.as_millis(),
            "in": self.inbound.iter().map(|(index, peer)| json!({
                "peer_index": index,
                "pubkey": peer.pubkey,
                "opus_frames": peer.opus_frames,
                "decode_errors": peer.decode_errors,
                "pcm_samples_to_gemini": peer.pcm_samples,
            })).collect::<Vec<_>>(),
            "to_gemini_errors": self.to_gemini_errors,
            "from_gemini": {
                "audio_frames": self.gemini_audio_frames,
                "samples": self.gemini_samples,
            },
            "out": {
                "opus_frames": self.opus_frames_out,
                "dtx_frames": self.dtx_frames_out,
                "samples": self.samples_out,
                "silence_injections": self.silence_injections,
                "silence_errors": self.silence_errors,
            },
        })
    }
}

/// Answers from the seat, and ask bookkeeping, sent back to the call loop.
enum AskUpdate {
    /// The ask event is published; answer Gemini's tool call.
    Asked { call_id: String, event_id: EventId },
    /// Publishing the ask failed; tell Gemini so it can say so.
    Failed { call_id: String, error: String },
    /// The seat replied in the ask thread.
    Answer {
        request: String,
        text: String,
        waited_ms: u128,
    },
    /// No reply within the ask timeout.
    TimedOut { request: String, waited_ms: u128 },
}

struct AskRequest {
    call_id: String,
    request: String,
}

pub async fn run_call(params: CallParams, cancel: CancellationToken) -> Result<()> {
    let started = Instant::now();
    let mut log = CallLog::open(&params.log_path);
    log.record(
        "call_start",
        json!({
            "ephemeral": params.ephemeral,
            "parent": params.parent,
            "model": params.session.model,
            "build_sha": crate::BUILD_SHA,
            "version": crate::VERSION,
            "pid": std::process::id(),
            "config": params.config,
        }),
    );
    info!(ephemeral = %params.ephemeral, parent = %params.parent, build_sha = crate::BUILD_SHA, "joining huddle");

    let mut transcript = Transcript::new(&params.human_label, &params.voice_label);
    let mut outcome = Outcome {
        phase: "room_join",
        ..Outcome::default()
    };
    let result = run_call_inner(
        &params,
        &cancel,
        &mut log,
        &mut transcript,
        &mut outcome,
        started,
    )
    .await;

    let duration = started.elapsed();
    let end_reason = match &result {
        Ok(reason) => {
            info!(ephemeral = %params.ephemeral, reason = %reason, "call ending");
            let mut data = outcome.counts();
            data["reason"] = json!(reason);
            data["duration_ms"] = json!(duration.as_millis());
            log.record("call_end", data);
            reason.clone()
        }
        Err(error) => {
            // The only place a failed call leaves a mark. Without it the JSONL
            // simply stops and the journal holds one line that rotates away.
            let chain = format!("{error:#}");
            error!(ephemeral = %params.ephemeral, phase = outcome.phase, error = %chain, "call failed");
            let mut data = outcome.counts();
            data["error"] = json!(chain);
            data["duration_ms"] = json!(duration.as_millis());
            log.record("call_failed", data);
            // Anything the human said before the failure is still theirs.
            for line in transcript.finish() {
                let text = transcript.render(&line);
                log.record("transcript_line", json!({ "text": text }));
            }
            format!("failed during {}: {chain}", outcome.phase)
        }
    };

    post_outcome(&params, &mut log, &transcript, &outcome, &end_reason, duration).await;
    result.map(|_| ())
}

#[allow(clippy::too_many_lines)]
async fn run_call_inner(
    params: &CallParams,
    cancel: &CancellationToken,
    log: &mut CallLog,
    transcript: &mut Transcript,
    outcome: &mut Outcome,
    call_started: Instant,
) -> Result<String> {
    let keys = params.publisher.keys().clone();
    let me = keys.public_key().to_hex();

    let joining = Instant::now();
    let mut room = join_room_with_retry(params, &keys, cancel, log).await?;
    for pubkey in room.peers.values() {
        if *pubkey != me {
            outcome.peers.insert(pubkey.clone());
        }
    }
    log.record(
        "room_joined",
        json!({
            "peer_index": room.self_index,
            "peers": room.peers,
            "join_ms": joining.elapsed().as_millis(),
        }),
    );

    outcome.phase = "gemini_connect";
    let setup = gemini::setup_message(&params.session, None);
    let connecting = Instant::now();
    let mut gemini = gemini::connect(&params.gemini_url, &params.gemini_key, &setup)
        .await
        .context("open the Gemini Live session")?;
    log.record(
        "gemini_connected",
        json!({ "resumed": false, "connect_ms": connecting.elapsed().as_millis() }),
    );
    outcome.phase = "in_call";

    // Gemini's server messages, audio elided, when VOICE_BRIDGE_TRACE_FRAMES
    // is on. A debugging tool: off by default, and never an artifact.
    let mut frames = params.trace_frames.then(|| {
        let path = params.log_path.with_extension("frames.jsonl");
        log.record(
            "frame_trace_on",
            json!({ "path": path.display().to_string() }),
        );
        CallLog::open(path)
    });

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

    let mut audio = AudioStats::default();
    let mut stats_at = Instant::now();
    let mut decode_fault = RateLimit::new(FAULT_WINDOW);
    let mut gemini_send_fault = RateLimit::new(FAULT_WINDOW);
    let mut silence_fault = RateLimit::new(FAULT_WINDOW);
    let mut unknown_message = RateLimit::new(FAULT_WINDOW);
    // How long the human waited to hear anything back. `awaiting` is refreshed
    // on every frame the human sends, so it holds the end of their speech; the
    // next Gemini audio frame answers it, and the next Opus frame out is when
    // they could actually hear it.
    let mut awaiting: Option<Instant> = None;
    let mut pending_room: Option<(Instant, u128)> = None;

    let end_reason: String = loop {
        tokio::select! {
            _ = cancel.cancelled() => break "huddle ended".into(),

            _ = tick.tick() => {
                if out_pcm.len() >= OUT_FRAME {
                    let frame: Vec<i16> = out_pcm.drain(..OUT_FRAME).collect();
                    let len = encoder.encode(&frame, &mut encoded)?;
                    if len > 0 {
                        let dtx = len <= 2;
                        let header = FrameHeader {
                            seq,
                            ts_48k,
                            level_dbov: wire::level_dbov(&frame),
                            flags: if dtx { wire::FLAG_DTX } else { 0 },
                        };
                        room.ws
                            .send(Message::Binary(wire::client_frame(header, &encoded[..len]).into()))
                            .await
                            .context("send audio to the room")?;
                        seq = seq.wrapping_add(1);
                        ts_48k = ts_48k.wrapping_add(wire::TS_PER_FRAME);
                        audio.opus_frames_out += 1;
                        audio.samples_out += OUT_FRAME as u64;
                        if dtx {
                            audio.dtx_frames_out += 1;
                        }
                        if let Some((since, gemini_ms)) = pending_room.take() {
                            log.record("response_latency", json!({
                                "from": "the human's last audio frame",
                                "gemini_first_audio_ms": gemini_ms,
                                "room_first_audio_ms": since.elapsed().as_millis(),
                            }));
                        }
                    }
                }
                if last_input.elapsed() >= SILENCE_AFTER {
                    audio.silence_injections += 1;
                    if let Err(error) = gemini
                        .send(Message::Text(gemini::audio_input(&[0; IN_FRAME]).to_string().into()))
                        .await
                    {
                        audio.silence_errors += 1;
                        if let Some(suppressed) = silence_fault.allow() {
                            warn!(%error, suppressed, "silence to Gemini failed");
                        }
                    }
                }
                if stats_at.elapsed() >= STATS_EVERY {
                    stats_at = Instant::now();
                    log.record("audio_stats", audio.snapshot(call_started.elapsed()));
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
                        let decoded = decoder.decode(opus_payload, &mut pcm_in, false);
                        audio.peer(index, pubkey).opus_frames += 1;
                        match decoded {
                            Ok(n) if n > 0 => {
                                audio.peer(index, pubkey).pcm_samples += n as u64;
                                last_input = Instant::now();
                                awaiting = Some(last_input);
                                if let Err(error) = gemini
                                    .send(Message::Text(gemini::audio_input(&pcm_in[..n]).to_string().into()))
                                    .await
                                {
                                    audio.to_gemini_errors += 1;
                                    if let Some(suppressed) = gemini_send_fault.allow() {
                                        warn!(%error, suppressed, "audio to Gemini failed; the session will reconnect");
                                    }
                                }
                            }
                            Ok(_) => {}
                            Err(error) => {
                                audio.peer(index, pubkey).decode_errors += 1;
                                if let Some(suppressed) = decode_fault.allow() {
                                    warn!(%error, suppressed, peer_index = index, "undecodable Opus frame");
                                }
                            }
                        }
                    }
                    Message::Text(text) => {
                        let value: Value = serde_json::from_str(&text).unwrap_or_default();
                        match parse_control(&value) {
                            RoomEvent::Joined { peer_index, pubkey } => {
                                log.record("peer_joined", json!({ "peer_index": peer_index, "pubkey": pubkey }));
                                if pubkey != me {
                                    outcome.peers.insert(pubkey.clone());
                                }
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
                                outcome.errors += 1;
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
                let value = match parsed {
                    Ok(Some(value)) => value,
                    Ok(None) => continue,
                    Err(error) => {
                        outcome.errors += 1;
                        let error = error.to_string();
                        match reconnect_gemini(params, resume_handle.as_deref(), &mut reconnects, log, &error, outcome).await {
                            Ok(fresh) => { gemini = fresh; continue; }
                            Err(error) => break format!("Gemini session lost: {error}"),
                        }
                    }
                };
                if let Some(frames) = frames.as_mut() {
                    frames.record("server_message", elide_audio(&value));
                }
                let events = gemini::parse_server_message(&value);
                if events.is_empty() {
                    // Silently dropping a message the model sent is how a
                    // protocol change becomes a mystery. Name its keys.
                    if let Some(suppressed) = unknown_message.allow() {
                        log.record("unknown_server_message", json!({
                            "keys": top_level_keys(&value),
                            "suppressed_since_last": suppressed,
                        }));
                    }
                }
                reconnects = 0;
                let mut go_away = false;
                for event in events {
                    match event {
                        ServerEvent::Audio(samples) => {
                            speaking = true;
                            audio.gemini_audio_frames += 1;
                            audio.gemini_samples += samples.len() as u64;
                            if let Some(since) = awaiting.take() {
                                pending_room = Some((since, since.elapsed().as_millis()));
                            }
                            out_pcm.extend(samples);
                        }
                        ServerEvent::InputText(text) => transcript.human(&text),
                        ServerEvent::OutputText(text) => {
                            let lines = transcript.voice(&text);
                            emit(transcript, lines, &post_tx, log);
                        }
                        ServerEvent::Interrupted => {
                            speaking = false;
                            out_pcm.clear();
                            let lines = transcript.interrupted();
                            emit(transcript, lines, &post_tx, log);
                        }
                        ServerEvent::TurnComplete => {
                            speaking = false;
                            // Let the tail of the answer play out.
                            let pad = (OUT_FRAME - out_pcm.len() % OUT_FRAME) % OUT_FRAME;
                            out_pcm.extend(std::iter::repeat_n(0, pad));
                            let lines = transcript.turn_complete();
                            emit(transcript, lines, &post_tx, log);
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
                            outcome.errors += 1;
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
                    match reconnect_gemini(params, resume_handle.as_deref(), &mut reconnects, log, "goAway", outcome).await {
                        Ok(fresh) => gemini = fresh,
                        Err(error) => break format!("Gemini session lost after goAway: {error}"),
                    }
                }
            }

            update = update_rx.recv() => {
                let Some(update) = update else { continue };
                let (message, is_answer) = match update {
                    AskUpdate::Asked { call_id, event_id } => {
                        outcome.asks += 1;
                        log.record("ask_posted", json!({ "call_id": call_id, "event_id": event_id.to_hex() }));
                        (gemini::tool_response(&call_id, gemini::ASK_ROCK, json!({
                            "status": "asked",
                            "note": format!("rock has the request. Tell {} briefly that you are checking with rock. The answer will arrive later as a message that starts with \"rock answered\".", params.human_label),
                        })), false)
                    }
                    AskUpdate::Failed { call_id, error } => {
                        outcome.ask_failures += 1;
                        outcome.errors += 1;
                        log.record("ask_failed", json!({ "call_id": call_id, "error": error }));
                        (gemini::tool_response(&call_id, gemini::ASK_ROCK, json!({
                            "status": "failed",
                            "note": "The request did not reach rock. Say so plainly.",
                        })), false)
                    }
                    AskUpdate::Answer { request, text, waited_ms } => {
                        outcome.answers += 1;
                        log.record("rock_answer", json!({ "request": request, "text": text, "waited_ms": waited_ms }));
                        (gemini::user_turn(&format!(
                            "rock answered {}'s request \"{request}\": {text}\n\nTell {} this now, briefly and faithfully. Add nothing rock did not say.",
                            params.human_label, params.human_label
                        )), true)
                    }
                    AskUpdate::TimedOut { request, waited_ms } => {
                        outcome.timeouts += 1;
                        log.record("ask_timed_out", json!({ "request": request, "waited_ms": waited_ms }));
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
                    outcome.errors += 1;
                    warn!(%error, "could not deliver an ask update to Gemini");
                }
            }
        }
    };

    outcome.phase = "ending";
    log.record("audio_stats", audio.snapshot(call_started.elapsed()));
    let lines = transcript.finish();
    emit(transcript, lines, &post_tx, log);
    drop(post_tx);
    drop(ask_tx);
    let _ = room.ws.send(Message::Close(None)).await;
    let _ = gemini.send(Message::Close(None)).await;
    let _ = tokio::time::timeout(Duration::from_secs(10), poster).await;
    asker.abort();
    Ok(end_reason)
}

/// The keys of a server message the parser found nothing in.
fn top_level_keys(value: &Value) -> Vec<String> {
    value
        .as_object()
        .map(|object| object.keys().cloned().collect())
        .unwrap_or_default()
}

/// A copy of a Gemini message with every `data` payload replaced by its size.
/// The trace is for protocol shapes; audio never goes to disk.
fn elide_audio(value: &Value) -> Value {
    match value {
        Value::Object(object) => Value::Object(
            object
                .iter()
                .map(|(key, child)| {
                    let child = match (key.as_str(), child) {
                        ("data", Value::String(text)) => {
                            json!({ "elided_chars": text.chars().count() })
                        }
                        _ => elide_audio(child),
                    };
                    (key.clone(), child)
                })
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.iter().map(elide_audio).collect()),
        other => other.clone(),
    }
}

/// One human-readable line about the call, with the transcript under it, in the
/// parent channel. This is the artifact someone reads after a bad call, so it
/// is posted whether the call ended cleanly or failed, and it names the log.
async fn post_outcome(
    params: &CallParams,
    log: &mut CallLog,
    transcript: &Transcript,
    outcome: &Outcome,
    end_reason: &str,
    duration: Duration,
) {
    let peers = if outcome.peers.is_empty() {
        "none".to_owned()
    } else {
        outcome
            .peers
            .iter()
            .map(|pubkey| {
                if params.starters.contains(pubkey) {
                    params.human_label.clone()
                } else {
                    pubkey.chars().take(8).collect()
                }
            })
            .collect::<Vec<_>>()
            .join(", ")
    };
    let mut body = format!(
        "Voice call `{}` ended: {end_reason}. {} · peers: {peers} · asks {} asked / {} answered / {} timed out / {} failed · {} Gemini reconnects · {} errors · log `{}`",
        &params.ephemeral.to_string()[..8],
        human_duration(duration),
        outcome.asks,
        outcome.answers,
        outcome.timeouts,
        outcome.ask_failures,
        outcome.reconnects,
        outcome.errors,
        params.log_path.display(),
    );
    if !transcript.is_empty() {
        body.push_str(&format!(
            "\n\nTranscript, {} and {}. Written by the voice bridge; lines labelled {} are Gemini speaking with this key.\n\n{}",
            params.human_label,
            params.voice_label,
            params.voice_label,
            transcript.full_text()
        ));
    }
    let body: String = body.chars().take(60 * 1024).collect();
    match buzz_sdk::build_message(params.parent, &body, None, &[], false, &[], &[]) {
        Ok(builder) => match params
            .publisher
            .publish(builder, Provenance::Transcript)
            .await
        {
            Ok(event) => log.record(
                "outcome_posted",
                json!({ "event_id": event.id.to_hex(), "with_transcript": !transcript.is_empty() }),
            ),
            Err(error) => log.record("outcome_post_failed", json!({ "error": error.to_string() })),
        },
        Err(error) => log.record("outcome_post_failed", json!({ "error": error.to_string() })),
    }
}

fn human_duration(duration: Duration) -> String {
    let seconds = duration.as_secs();
    if seconds >= 60 {
        format!("{}m{:02}s", seconds / 60, seconds % 60)
    } else {
        format!("{}.{:01}s", seconds, duration.subsec_millis() / 100)
    }
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
    log: &mut CallLog,
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
                log.record(
                    "room_join_failed",
                    json!({ "attempt": attempt, "error": format!("{error:#}") }),
                );
                last_error = Some(error);
                tokio::time::sleep(Duration::from_secs(1 << attempt.min(3))).await;
            }
        }
    }
    Err(last_error.unwrap_or_else(|| anyhow!("cancelled before joining")))
        .context("join the huddle audio room")
}

async fn reconnect_gemini(
    params: &CallParams,
    handle: Option<&str>,
    reconnects: &mut u32,
    log: &mut CallLog,
    reason: &str,
    outcome: &mut Outcome,
) -> Result<GeminiStream> {
    loop {
        *reconnects += 1;
        outcome.reconnects += 1;
        if *reconnects > MAX_GEMINI_RECONNECTS {
            return Err(anyhow!(
                "{MAX_GEMINI_RECONNECTS} reconnects failed; last cause: {reason}"
            ));
        }
        let setup = gemini::setup_message(&params.session, handle);
        let connecting = Instant::now();
        match gemini::connect(&params.gemini_url, &params.gemini_key, &setup).await {
            Ok(stream) => {
                log.record(
                    "gemini_connected",
                    json!({
                        "resumed": handle.is_some(),
                        "reason": reason,
                        "attempt": *reconnects,
                        "connect_ms": connecting.elapsed().as_millis(),
                    }),
                );
                return Ok(stream);
            }
            Err(error) => {
                outcome.errors += 1;
                warn!(%error, attempt = *reconnects, "Gemini reconnect failed");
                log.record(
                    "gemini_reconnect_failed",
                    json!({ "error": format!("{error:#}"), "attempt": *reconnects }),
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
                        update_tx.send(AskUpdate::Failed { call_id: ask.call_id, error: format!("{error:#}") }).ok();
                    }
                }
            }
            reply = reply_rx.recv() => {
                let Some(reply) = reply else { continue };
                let (request, asked_at) = pending
                    .pop_front()
                    .unwrap_or_else(|| ("earlier request".into(), Instant::now()));
                update_tx.send(AskUpdate::Answer {
                    request,
                    text: reply.content.clone(),
                    waited_ms: asked_at.elapsed().as_millis(),
                }).ok();
            }
            _ = check.tick() => {
                while pending.front().is_some_and(|(_, at)| at.elapsed() >= ask_timeout) {
                    if let Some((request, at)) = pending.pop_front() {
                        update_tx.send(AskUpdate::TimedOut {
                            request,
                            waited_ms: at.elapsed().as_millis(),
                        }).ok();
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audio_stats_count_both_directions_and_each_peer() {
        let mut audio = AudioStats::default();
        let peer = audio.peer(3, "ab");
        peer.opus_frames += 2;
        peer.pcm_samples += 640;
        audio.peer(3, "ab").decode_errors += 1;
        audio.peer(7, "cd").opus_frames += 1;
        audio.gemini_audio_frames += 4;
        audio.gemini_samples += 9600;
        audio.opus_frames_out += 5;
        audio.dtx_frames_out += 1;
        audio.silence_injections += 50;

        let snapshot = audio.snapshot(Duration::from_millis(5000));
        assert_eq!(snapshot["elapsed_ms"], 5000);
        let inbound = snapshot["in"].as_array().expect("in");
        assert_eq!(inbound.len(), 2);
        assert_eq!(inbound[0]["peer_index"], 3);
        assert_eq!(inbound[0]["pubkey"], "ab");
        assert_eq!(inbound[0]["opus_frames"], 2);
        assert_eq!(inbound[0]["decode_errors"], 1);
        assert_eq!(inbound[0]["pcm_samples_to_gemini"], 640);
        assert_eq!(inbound[1]["peer_index"], 7);
        assert_eq!(snapshot["from_gemini"]["audio_frames"], 4);
        assert_eq!(snapshot["from_gemini"]["samples"], 9600);
        assert_eq!(snapshot["out"]["opus_frames"], 5);
        assert_eq!(snapshot["out"]["dtx_frames"], 1);
        assert_eq!(snapshot["out"]["silence_injections"], 50);
    }

    #[test]
    fn a_peer_index_reused_by_another_key_is_relabelled() {
        let mut audio = AudioStats::default();
        audio.peer(1, "ab").opus_frames += 1;
        audio.peer(1, "cd").opus_frames += 1;
        let snapshot = audio.snapshot(Duration::ZERO);
        assert_eq!(snapshot["in"][0]["pubkey"], "cd");
        assert_eq!(snapshot["in"][0]["opus_frames"], 2);
    }

    #[test]
    fn the_frame_trace_keeps_the_shape_and_drops_the_audio() {
        let message = json!({
            "serverContent": { "modelTurn": { "parts": [
                { "inlineData": { "mimeType": "audio/pcm;rate=24000", "data": "AAAA" } },
                { "text": "kept" }
            ] } },
            "usageMetadata": { "totalTokenCount": 7 }
        });
        let elided = elide_audio(&message);
        let part = &elided["serverContent"]["modelTurn"]["parts"][0]["inlineData"];
        assert_eq!(part["mimeType"], "audio/pcm;rate=24000");
        assert_eq!(part["data"]["elided_chars"], 4);
        assert_eq!(elided["serverContent"]["modelTurn"]["parts"][1]["text"], "kept");
        assert_eq!(elided["usageMetadata"]["totalTokenCount"], 7);
    }

    #[test]
    fn an_unparsed_message_is_named_by_its_keys() {
        let message = json!({ "somethingNew": { "a": 1 }, "goAwayLater": true });
        assert!(gemini::parse_server_message(&message).is_empty());
        assert_eq!(top_level_keys(&message), vec!["goAwayLater", "somethingNew"]);
        assert!(top_level_keys(&json!([1, 2])).is_empty());
    }

    #[test]
    fn durations_read_as_a_human_would_say_them() {
        assert_eq!(human_duration(Duration::from_millis(3400)), "3.4s");
        assert_eq!(human_duration(Duration::from_secs(72)), "1m12s");
        assert_eq!(human_duration(Duration::from_secs(3600)), "60m00s");
    }

    #[test]
    fn the_outcome_counts_carry_the_phase_and_every_tally() {
        let outcome = Outcome {
            phase: "gemini_connect",
            peers: ["ab".to_owned()].into_iter().collect(),
            asks: 2,
            answers: 1,
            timeouts: 1,
            ask_failures: 0,
            reconnects: 3,
            errors: 4,
        };
        let counts = outcome.counts();
        assert_eq!(counts["phase"], "gemini_connect");
        assert_eq!(counts["peers"][0], "ab");
        assert_eq!(counts["asks"], 2);
        assert_eq!(counts["answers"], 1);
        assert_eq!(counts["timeouts"], 1);
        assert_eq!(counts["reconnects"], 3);
        assert_eq!(counts["errors"], 4);
    }
}
