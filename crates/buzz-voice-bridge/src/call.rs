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

/// The seat's typing indicator (`buzz_core::kind::KIND_TYPING_INDICATOR`).
/// Ephemeral by Nostr's range rule, so relays forward it and store nothing.
const TYPING_INDICATOR_KIND: u16 = 20002;

/// buzz-acp's tag naming the event a turn is answering (`relay::TYPING_TRIGGER_TAG`).
/// Not an `e` tag on purpose: an extra `e` would move a channel-keyed
/// indicator into a thread panel that does not exist yet.
const TYPING_TRIGGER_TAG: &str = "trigger";
/// Consecutive Gemini reconnects before the call gives up.
const MAX_GEMINI_RECONNECTS: u32 = 3;
/// How often the running audio counters are written to the call log.
const STATS_EVERY: Duration = Duration::from_secs(5);
/// A fault on the audio path repeats at 50 frames/s. Report it at most this
/// often, with the count of what was swallowed.
const FAULT_WINDOW: Duration = Duration::from_secs(5);
/// One frame of room audio, as a step of the pacing deadline.
///
/// Nothing acts on the deadline yet. It exists so `pacer.debt_ms` can say how
/// far behind real time the room track ran, which is the difference between a
/// loop that could not emit and a queue that had nothing to emit — and those
/// two produce the same five-second averages. See the note on
/// `MissedTickBehavior` in [`run_call`].
const FRAME_INTERVAL: Duration = Duration::from_millis(20);
/// Below this an inbound frame is the room's noise floor rather than someone
/// talking. Used only to anchor latency on the end of speech.
const SPEECH_FLOOR_DBOV: i8 = -50;

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
    /// How often, while the seat is working, its voice says so and for how
    /// long. The elapsed number it speaks is counted here.
    pub progress_every: Duration,
    /// Which loop plays under the room track during a wait.
    pub working_sound: crate::bed::WorkingSound,
    /// Level of that loop, as a fraction of the file's own level.
    pub working_sound_gain: f32,
    /// How long after an ask the loop starts, so a fast answer never triggers it.
    pub working_sound_delay: Duration,
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
    /// Working-sound frames, counted apart from speech: they are audio the
    /// room heard that Gemini never sent, and folding them into `samples_out`
    /// would make the queue look emptier than it is.
    bed_frames_out: u64,
    /// Samples thrown away by a barge-in, which the human had not heard yet.
    discarded_by_interrupt: u64,
    /// How many times a barge-in did that.
    interrupts: u64,
    /// Queue depth in samples when the last frame of this window was emitted.
    queued_at_emit: usize,
    /// Pacing ticks that fired, and the worst gap between two of them. One
    /// frame goes out per 20 ms of wall clock, so a tick that arrives late is
    /// audio the room does not get.
    ticks: u64,
    worst_tick_gap_ms: u128,
    /// Ticks that found a whole frame waiting. A window with few of these and
    /// a low emit rate is a queue that was short, not a loop that was blocked;
    /// five-second averages cannot tell those apart, and they call for
    /// opposite fixes.
    ticks_owed: u64,
    /// Worst gap between a frame's real-time deadline and the tick that
    /// emitted it. What a catch-up drain would have had to repay.
    worst_debt_ms: u128,
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
                "bed_frames": self.bed_frames_out,
            },
            "queue": {
                "queued_samples_at_emit": self.queued_at_emit,
                "queued_ms_at_emit": self.queued_at_emit as u64 * 1000 / gemini::OUTPUT_RATE as u64,
                "discarded_by_interrupt": self.discarded_by_interrupt,
                "interrupts": self.interrupts,
            },
            "pacer": {
                "ticks": self.ticks,
                "ticks_owed": self.ticks_owed,
                "worst_tick_gap_ms": self.worst_tick_gap_ms,
                "worst_debt_ms": self.worst_debt_ms,
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
    /// The wait is still on. Carries the elapsed time the voice is allowed to
    /// speak, counted here so it is not one the model invented, and what the
    /// bridge actually knows about the seat — which decides what may be said.
    Waiting { elapsed_secs: u64, state: WaitState },
}

/// What the bridge has observed about the seat while an ask is outstanding.
///
/// The wait line may only claim work the bridge has evidence of. The evidence
/// is the seat's own typing indicator (kind:20002), published when buzz-acp
/// dispatches the turn and refreshed every 3 s until the turn returns
/// (`crates/buzz-acp/src/lib.rs`: `begin_typing` on dispatch, the 3 s
/// `typing_refresh` tick, and `typing_channels.remove(scope)` on the result).
/// So its arrival means a turn began, and its silence means one ended.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum WaitState {
    /// No typing seen yet: the ask is published but no turn has begun. A seat
    /// that cannot run — rate-limited, down, unauthorised — never leaves this
    /// state, and saying "still working" about it is the fabrication we are
    /// here to stop.
    NotPickedUp,
    /// Typing seen within [`TYPING_STALE_AFTER`]: a turn is in flight now.
    Working,
    /// Typing was seen and then stopped, with no answer. buzz-acp clears the
    /// indicator when the turn returns, so this is a turn that ended without
    /// answering — the shape of a seat that died on its first failure.
    Stalled,
}

impl WaitState {
    fn as_str(self) -> &'static str {
        match self {
            Self::NotPickedUp => "not_picked_up",
            Self::Working => "working",
            Self::Stalled => "stalled",
        }
    }
}

/// How long the seat's typing indicator may go unrefreshed before the bridge
/// stops calling it work. buzz-acp republishes every 3 s, so this is three
/// missed refreshes: long enough to ride out a dropped ephemeral event or a
/// reconnect, short enough that a dead turn is not described as a live one for
/// more than one progress line.
const TYPING_STALE_AFTER: Duration = Duration::from_secs(10);

/// When an update may reach Gemini.
///
/// Cutting the voice off mid-word is the harshest thing the bridge can do, so
/// only a tool response Gemini is blocked on goes in regardless.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Delivery {
    /// Gemini is waiting on this; send it now whatever else is happening.
    Now,
    /// Send when the voice is quiet, and hold it until then.
    WhenQuiet,
    /// Send only if the voice is already quiet, and drop it otherwise. A
    /// progress line carries a number that is true at the moment it is
    /// counted; held until the voice stops, it would arrive stale, and a
    /// stale number spoken as fact is the defect this exists to close.
    IfQuiet,
}

/// An ask that has been published and not yet answered.
struct Pending {
    request: String,
    /// When the ask was published — the anchor every elapsed count uses.
    asked_at: Instant,
    /// When its last progress line went out.
    last_progress: Instant,
    /// Whether the seat has been seen typing since this ask was published.
    picked_up: bool,
    /// The ask's own event id, to match a `trigger`-tagged indicator to it.
    event_id: Option<EventId>,
}

impl Pending {
    /// Count a typing indicator against this ask, if it can belong to it.
    ///
    /// Two ways to decide, in order of how much they prove:
    ///
    /// * the indicator names the event it is answering (buzz-acp's `trigger`
    ///   tag). Then it is exact: ours, or somebody else's, with no guessing.
    /// * it does not. Then all the bridge knows is that this seat is typing in
    ///   this channel, so the best it can do is require the indicator to
    ///   postdate the ask — an indicator that predates it is the seat
    ///   finishing something else, and counting it would call the ask picked
    ///   up before anything had looked at it.
    ///
    /// The fallback stays because a seat on an older buzz-acp sends no trigger
    /// tag, and the Mac seats trail every roll.
    fn note_typing(&mut self, seen: Instant, trigger: Option<&EventId>) {
        match (trigger, self.event_id.as_ref()) {
            (Some(trigger), Some(mine)) => {
                if trigger == mine {
                    self.picked_up = true;
                }
            }
            _ => {
                if seen >= self.asked_at {
                    self.picked_up = true;
                }
            }
        }
    }
}

/// What may be said about the seat, from what the bridge has actually seen.
///
/// Split out so the rule is one testable place rather than a condition inside
/// a `select!` arm: never claim work without evidence of a turn, and stop
/// claiming it once that evidence goes stale.
fn wait_state(picked_up: bool, last_typing_at: Option<Instant>) -> WaitState {
    if !picked_up {
        return WaitState::NotPickedUp;
    }
    match last_typing_at {
        Some(at) if at.elapsed() < TYPING_STALE_AFTER => WaitState::Working,
        // Picked up, then the indicator stopped: buzz-acp clears it when the
        // turn returns, so the turn ended and no answer came with it.
        _ => WaitState::Stalled,
    }
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

    post_outcome(
        &params,
        &mut log,
        &transcript,
        &outcome,
        &end_reason,
        duration,
    )
    .await;
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
        params.progress_every,
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
    // `Skip` drops every tick missed while an arm of the `select!` held the
    // loop; tokio's default, `Burst`, fires once per missed tick and would
    // emit the frames behind them. That is catch-up this loop had and gave
    // away, and it is why a stall leaves `out_pcm` permanently behind: the
    // samples stay, the chance to emit them does not. Left as it is until
    // `pacer.ticks` says ticks are being missed at all — a queue that was
    // simply short looks the same in a five-second average and needs the
    // opposite fix.
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    let mut audio = AudioStats::default();
    let mut stats_at = Instant::now();
    let mut decode_fault = RateLimit::new(FAULT_WINDOW);
    let mut gemini_send_fault = RateLimit::new(FAULT_WINDOW);
    let mut silence_fault = RateLimit::new(FAULT_WINDOW);
    let mut unknown_message = RateLimit::new(FAULT_WINDOW);
    // How long the human waited to hear anything back. Refreshed on every
    // inbound frame that carries speech rather than on every inbound frame:
    // his client streams continuously whether or not he is talking, so the
    // original anchor was pinned to the present and 143 records on call
    // `bab4c7e1` read 1-103 ms through a call that ran seconds behind. The
    // next Gemini audio frame answers it, and the next Opus frame out is when
    // he could actually hear it.
    let mut awaiting: Option<Instant> = None;
    let mut pending_room: Option<(Instant, u128)> = None;
    // The answer's own chain, which is the one the human feels: the bridge has
    // it, the hold queue lets it go, Gemini starts speaking, the room hears it.
    let mut answer_at: Option<Instant> = None;
    let mut answer_handed_at: Option<Instant> = None;
    let mut answer_audio: Option<Instant> = None;
    // The working sound, and the ask it belongs to. `working_since` is the
    // moment the ask reached the relay; the bed waits out `working_sound_delay`
    // from there so a fast answer is never dressed up as a wait.
    let mut bed = crate::bed::Bed::new(params.working_sound, params.working_sound_gain);
    let mut working_since: Option<Instant> = None;
    let mut bed_frame = vec![0i16; OUT_FRAME];
    // One frame per tick, and no more — nothing here leaves on a wall-clock
    // deadline yet. `next_frame_at` is the deadline a drain would emit
    // against; today the only thing that reads it is `worst_debt_ms`, which
    // says how far behind real time the frame we are about to send already is.
    // Reset whenever the queue runs dry, so an idle line does not book a debt
    // it never owed and then report it as a stall. Combined with the `Skip`
    // above, that means every tick the loop misses is 20 ms of audio it can
    // never make up: the samples stay in `out_pcm`, the chance to emit them
    // does not.
    let mut next_frame_at = Instant::now();
    let mut last_tick = Instant::now();

    let end_reason: String = loop {
        tokio::select! {
            _ = cancel.cancelled() => break "huddle ended".into(),

            _ = tick.tick() => {
                let now = Instant::now();
                audio.ticks += 1;
                audio.worst_tick_gap_ms = audio.worst_tick_gap_ms.max(now.duration_since(last_tick).as_millis());
                last_tick = now;

                if out_pcm.len() < OUT_FRAME {
                    // Nothing owed: start the next frame's clock from here
                    // rather than carrying an idle line's debt into the next
                    // utterance.
                    next_frame_at = now;
                }
                let mut sent = 0usize;
                if out_pcm.len() >= OUT_FRAME {
                    audio.ticks_owed += 1;
                    audio.worst_debt_ms = audio
                        .worst_debt_ms
                        .max(now.saturating_duration_since(next_frame_at).as_millis());
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
                        audio.queued_at_emit = out_pcm.len();
                        if dtx {
                            audio.dtx_frames_out += 1;
                        }
                        if let Some((since, gemini_ms)) = pending_room.take() {
                            log.record("response_latency", json!({
                                "from": "the end of the human's speech",
                                "gemini_first_audio_ms": gemini_ms,
                                "room_first_audio_ms": since.elapsed().as_millis(),
                            }));
                        }
                        if let (Some(answer), None) = (answer_at, answer_audio) {
                            answer_audio = Some(Instant::now());
                            log.record("answer_audio", json!({
                                "seen_to_room_ms": answer.elapsed().as_millis(),
                                "handed_to_room_ms": answer_handed_at.map(|at| at.elapsed().as_millis()),
                                "queued_samples": out_pcm.len(),
                                "queued_ms": out_pcm.len() as u64 * 1000 / gemini::OUTPUT_RATE as u64,
                            }));
                        }
                    }
                    next_frame_at += FRAME_INTERVAL;
                    sent += 1;
                }
                // The working sound, in the gap where the room hears nothing
                // at all today. Speech always wins: this is the `else`.
                if sent == 0 {
                    let waiting = working_since
                        .is_some_and(|since| since.elapsed() >= params.working_sound_delay);
                    if waiting && !speaking {
                        if let Some(bed) = bed.as_mut() {
                            bed.frame(&mut bed_frame);
                            let len = encoder.encode(&bed_frame, &mut encoded)?;
                            if len > 0 {
                                let header = FrameHeader {
                                    seq,
                                    ts_48k,
                                    level_dbov: wire::level_dbov(&bed_frame),
                                    flags: 0,
                                };
                                room.ws
                                    .send(Message::Binary(wire::client_frame(header, &encoded[..len]).into()))
                                    .await
                                    .context("send the working sound to the room")?;
                                seq = seq.wrapping_add(1);
                                ts_48k = ts_48k.wrapping_add(wire::TS_PER_FRAME);
                                audio.bed_frames_out += 1;
                            }
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
                                if wire::level_dbov(&pcm_in[..n]) > SPEECH_FLOOR_DBOV {
                                    awaiting = Some(last_input);
                                }
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
                            // Everything still queued is speech the human has
                            // not heard. Dropping it is what a barge-in means,
                            // but how much it drops is the measure of how far
                            // behind the room track was running.
                            if !out_pcm.is_empty() {
                                audio.interrupts += 1;
                                audio.discarded_by_interrupt += out_pcm.len() as u64;
                                log.record("interrupted", json!({
                                    "discarded_samples": out_pcm.len(),
                                    "discarded_ms": out_pcm.len() as u64 * 1000 / gemini::OUTPUT_RATE as u64,
                                }));
                            }
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
                        if let (Some(answer), None) = (answer_at, answer_handed_at) {
                            answer_handed_at = Some(Instant::now());
                            log.record("answer_handed", json!({
                                "held_ms": answer.elapsed().as_millis(),
                                "queued_samples": out_pcm.len(),
                                "queued_ms": out_pcm.len() as u64 * 1000 / gemini::OUTPUT_RATE as u64,
                            }));
                        }
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
                let (message, delivery) = match update {
                    AskUpdate::Asked { call_id, event_id } => {
                        outcome.asks += 1;
                        log.record("ask_posted", json!({ "call_id": call_id, "event_id": event_id.to_hex() }));
                        // The wait starts here, not at the tool call: this is
                        // the moment the seat could first have seen it.
                        working_since = Some(Instant::now());
                        if let Some(bed) = bed.as_mut() {
                            bed.rewind();
                        }
                        (gemini::tool_response(&call_id, gemini::ASK_ROCK, json!({
                            "status": "asked",
                            "note": format!("rock has the request. Tell {} briefly that you are checking with rock, then wait. {} can hear a working sound while rock works, so silence is fine. The answer will arrive later as a message that starts with \"rock answered\".", params.human_label, params.human_label),
                        })), Delivery::Now)
                    }
                    AskUpdate::Failed { call_id, error } => {
                        outcome.ask_failures += 1;
                        outcome.errors += 1;
                        log.record("ask_failed", json!({ "call_id": call_id, "error": error }));
                        working_since = None;
                        (gemini::tool_response(&call_id, gemini::ASK_ROCK, json!({
                            "status": "failed",
                            "note": "The request did not reach rock. Say so plainly.",
                        })), Delivery::Now)
                    }
                    AskUpdate::Answer { request, text, waited_ms } => {
                        outcome.answers += 1;
                        log.record("rock_answer", json!({ "request": request, "text": text, "waited_ms": waited_ms }));
                        working_since = None;
                        answer_at = Some(Instant::now());
                        answer_handed_at = None;
                        answer_audio = None;
                        (gemini::user_turn(&format!(
                            "rock answered {}'s request \"{request}\": {text}\n\nTell {} this now, briefly and faithfully. Add nothing rock did not say.",
                            params.human_label, params.human_label
                        )), Delivery::WhenQuiet)
                    }
                    AskUpdate::TimedOut { request, waited_ms } => {
                        outcome.timeouts += 1;
                        log.record("ask_timed_out", json!({ "request": request, "waited_ms": waited_ms }));
                        working_since = None;
                        (gemini::user_turn(&format!(
                            "rock answered {}'s request \"{request}\": no answer yet after {} minutes. Tell him the request is waiting in his DM with rock.",
                            params.human_label,
                            params.ask_timeout.as_secs() / 60
                        )), Delivery::WhenQuiet)
                    }
                    AskUpdate::Waiting { elapsed_secs, state } => {
                        log.record("waiting_tick", json!({
                            "elapsed_secs": elapsed_secs,
                            "state": state.as_str(),
                            "spoken": !speaking,
                        }));
                        // One sentence per state, and each says only what the
                        // bridge has seen. "Still working" is a claim about a
                        // turn that is running, so it is reserved for the one
                        // state that has evidence of one.
                        let line = match state {
                            WaitState::NotPickedUp => format!(
                                "rock has not picked this up yet. It has been {elapsed_secs} seconds. Tell {} \
                                 exactly that: that rock has not picked it up yet and how long it has been. Do \
                                 not say rock is working on it, because it is not. Do not guess why, do not \
                                 guess how much longer, and do not answer his request yourself.",
                                params.human_label
                            ),
                            WaitState::Working => format!(
                                "rock is still working. It has been {elapsed_secs} seconds. Tell {} that rock is \
                                 still working and that it has been {elapsed_secs} seconds. Say only those two \
                                 things. Do not say what rock is doing, do not guess how much longer, and do not \
                                 answer his request yourself.",
                                params.human_label
                            ),
                            // Deliberately not "rock stopped". The indicator is
                            // best-effort — buzz-acp drops it when its publish
                            // queue is full, and this watcher can lose its own
                            // subscription — so its silence is only ever a fact
                            // about what the bridge saw, never a proven death.
                            WaitState::Stalled => format!(
                                "rock picked this up, and the bridge has stopped seeing it work. There is still \
                                 no answer and it has been {elapsed_secs} seconds. Tell {} exactly that. Do not \
                                 say rock is still working, do not say what went wrong or guess why, and do not \
                                 answer his request yourself.",
                                params.human_label
                            ),
                        };
                        (gemini::user_turn(&line), Delivery::IfQuiet)
                    }
                };
                match delivery {
                    Delivery::WhenQuiet if speaking => {
                        held.push_back(message);
                    }
                    Delivery::IfQuiet if speaking => {}
                    _ => {
                        if answer_at.is_some() && answer_handed_at.is_none() && delivery == Delivery::WhenQuiet {
                            answer_handed_at = Some(Instant::now());
                            log.record("answer_handed", json!({
                                "held_ms": 0,
                                "queued_samples": out_pcm.len(),
                                "queued_ms": out_pcm.len() as u64 * 1000 / gemini::OUTPUT_RATE as u64,
                            }));
                        }
                        if let Err(error) = gemini.send(Message::Text(message.to_string().into())).await {
                            outcome.errors += 1;
                            warn!(%error, "could not deliver an ask update to Gemini");
                        }
                    }
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
        "Voice call `{}` ended: {end_reason}. {} · peers: {peers} · asks {} asked / {} answered / {} timed out / {} failed · {} · {} · log `{}`",
        &params.ephemeral.to_string()[..8],
        human_duration(duration),
        outcome.asks,
        outcome.answers,
        outcome.timeouts,
        outcome.ask_failures,
        plural(outcome.reconnects, "Gemini reconnect"),
        plural(outcome.errors, "error"),
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

/// "1 error", "2 errors". The outcome line is read by a person.
fn plural(count: u32, noun: &str) -> String {
    match count {
        1 => format!("1 {noun}"),
        other => format!("{other} {noun}s"),
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
    progress_every: Duration,
    mut ask_rx: mpsc::UnboundedReceiver<AskRequest>,
    update_tx: mpsc::UnboundedSender<AskUpdate>,
    cancel: CancellationToken,
) {
    let mut root: Option<EventId> = None;
    let (reply_tx, mut reply_rx) = mpsc::unbounded_channel::<Event>();
    let (typing_tx, mut typing_rx) = mpsc::unbounded_channel::<(Instant, Option<EventId>)>();
    let mut pending: VecDeque<Pending> = VecDeque::new();
    // The seat's last observed typing indicator, for the whole call rather
    // than per ask: a channel-keyed indicator cannot be attributed to one ask
    // (see `watch_typing`), and the seat answers one ask at a time anyway.
    let mut last_typing_at: Option<Instant> = None;
    let mut check = tokio::time::interval(Duration::from_secs(5));
    // One second so a progress line lands within a second of its due time
    // whatever `progress_every` is; the tick itself costs nothing.
    let mut progress = tokio::time::interval(Duration::from_secs(1));
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
                            tokio::spawn(watch_typing(
                                relay_url.clone(),
                                publisher.keys().clone(),
                                parent,
                                me.clone(),
                                typing_tx.clone(),
                                cancel.clone(),
                            ));
                        }
                        let now = Instant::now();
                        pending.push_back(Pending {
                            request: ask.request,
                            asked_at: now,
                            last_progress: now,
                            picked_up: false,
                            event_id: Some(event.id),
                        });
                        update_tx.send(AskUpdate::Asked { call_id: ask.call_id, event_id: event.id }).ok();
                    }
                    Err(error) => {
                        update_tx.send(AskUpdate::Failed { call_id: ask.call_id, error: format!("{error:#}") }).ok();
                    }
                }
            }
            reply = reply_rx.recv() => {
                let Some(reply) = reply else { continue };
                let done = pending.pop_front().unwrap_or_else(|| Pending {
                    request: "earlier request".into(),
                    asked_at: Instant::now(),
                    last_progress: Instant::now(),
                    picked_up: true,
                    event_id: None,
                });
                update_tx.send(AskUpdate::Answer {
                    request: done.request,
                    text: reply.content.clone(),
                    waited_ms: done.asked_at.elapsed().as_millis(),
                }).ok();
            }
            _ = check.tick() => {
                while pending.front().is_some_and(|p| p.asked_at.elapsed() >= ask_timeout) {
                    if let Some(late) = pending.pop_front() {
                        update_tx.send(AskUpdate::TimedOut {
                            waited_ms: late.asked_at.elapsed().as_millis(),
                            request: late.request,
                        }).ok();
                    }
                }
            }
            seen = typing_rx.recv() => {
                let Some((seen, trigger)) = seen else { continue };
                last_typing_at = Some(seen);
                if let Some(front) = pending.front_mut() {
                    front.note_typing(seen, trigger.as_ref());
                }
            }
            _ = progress.tick() => {
                // The oldest outstanding ask only. Two lines about two waits
                // is noise, and the human asked one question at a time.
                if let Some(front) = pending.front_mut() {
                    if front.last_progress.elapsed() >= progress_every {
                        front.last_progress = Instant::now();
                        update_tx.send(AskUpdate::Waiting {
                            elapsed_secs: front.asked_at.elapsed().as_secs(),
                            state: wait_state(front.picked_up, last_typing_at),
                        }).ok();
                    }
                }
            }
        }
    }
}

/// Watch the seat's typing indicator (kind:20002) in the ask's channel.
///
/// This is the only evidence the bridge has that a turn actually began. It is
/// an ephemeral kind, so the relay forwards it live and stores nothing: a
/// watcher that connects late misses the first one and picks up the next 3 s
/// refresh, which is why staleness is measured in refreshes rather than in a
/// single event.
///
/// The filter cannot be narrowed to this ask. buzz-acp keys a turn's indicator
/// to the *thread root* of its trigger, and a top-level trigger stays
/// channel-keyed with no `e` tag at all (`queue.rs`: `typing_thread_tags`) —
/// and the first ask of every call is top-level. So this matches on the seat's
/// own pubkey in the ask's channel, and the caller only counts what arrives
/// after it published. The residue is that the seat typing in this channel for
/// unrelated work reads as pick-up; that says "working" of a seat that is
/// working, which is the mild direction, and never says it of one that is not
/// running at all — the case this exists to catch.
async fn watch_typing(
    relay_url: String,
    keys: Keys,
    parent: Uuid,
    me: String,
    typing_tx: mpsc::UnboundedSender<(Instant, Option<EventId>)>,
    cancel: CancellationToken,
) {
    while !cancel.is_cancelled() {
        let mut conn = match NostrWsConnection::connect_authenticated(&relay_url, &keys, None).await
        {
            Ok(conn) => conn,
            Err(error) => {
                warn!(%error, "typing watcher could not connect");
                tokio::time::sleep(Duration::from_secs(2)).await;
                continue;
            }
        };
        // Channel reads need `#h`; without it the relay closes the REQ.
        let filter = json!({
            "kinds": [TYPING_INDICATOR_KIND],
            "#h": [parent.to_string()],
            "authors": [me],
        });
        if conn
            .send_raw(&json!(["REQ", "typing", filter]))
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
                        if event.pubkey.to_hex() == me {
                            // buzz-acp names the event its turn is answering.
                            // Absent on a seat running an older harness, and
                            // the caller falls back to timing when it is.
                            let trigger = event
                                .tags
                                .iter()
                                .map(|t| t.as_slice())
                                .find(|t| t.first().map(String::as_str) == Some(TYPING_TRIGGER_TAG))
                                .and_then(|t| t.get(1))
                                .and_then(|id| EventId::from_hex(id).ok());
                            typing_tx.send((Instant::now(), trigger)).ok();
                        }
                    }
                    Ok(RelayMessage::Closed { message, .. }) => {
                        warn!(%message, "the relay closed the typing subscription");
                        tokio::time::sleep(Duration::from_secs(2)).await;
                        break;
                    }
                    Ok(_) | Err(WsClientError::Timeout) => {}
                    Err(error) => {
                        warn!(%error, "typing watcher lost its connection");
                        break;
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

    fn ago(secs: u64) -> Instant {
        Instant::now() - Duration::from_secs(secs)
    }

    fn pending_at(asked_at: Instant) -> Pending {
        Pending {
            request: "what is the status".into(),
            asked_at,
            last_progress: asked_at,
            picked_up: false,
            event_id: None,
        }
    }

    fn id(byte: u8) -> EventId {
        EventId::from_slice(&[byte; 32]).expect("32 bytes")
    }

    #[test]
    fn a_seat_that_never_starts_is_never_called_working() {
        // The 05:13Z shape: the ask is published, the seat cannot run, and no
        // typing ever arrives. Every progress line must stay on the truth.
        assert_eq!(wait_state(false, None), WaitState::NotPickedUp);
    }

    #[test]
    fn typing_alone_does_not_make_an_unpicked_ask_working() {
        // The seat is typing in this channel, but not since this ask went out
        // — so it is someone else's work, and this ask is still untouched.
        assert_eq!(
            wait_state(false, Some(Instant::now())),
            WaitState::NotPickedUp
        );
    }

    #[test]
    fn a_refreshing_indicator_is_the_only_thing_that_earns_still_working() {
        assert_eq!(wait_state(true, Some(Instant::now())), WaitState::Working);
        // buzz-acp republishes every 3 s, so just under the window is healthy.
        assert_eq!(wait_state(true, Some(ago(9))), WaitState::Working);
    }

    #[test]
    fn an_indicator_that_stops_refreshing_ends_the_claim_of_work() {
        // buzz-acp clears the indicator when the turn returns, so three missed
        // refreshes with no answer means the turn ended without one.
        assert_eq!(wait_state(true, Some(ago(11))), WaitState::Stalled);
        assert_eq!(wait_state(true, None), WaitState::Stalled);
    }

    #[test]
    fn only_typing_that_postdates_the_ask_counts_as_picking_it_up() {
        let asked_at = ago(30);
        let mut ask = pending_at(asked_at);

        // The seat was already typing when the ask went out: another turn.
        ask.note_typing(asked_at - Duration::from_secs(1), None);
        assert!(!ask.picked_up);
        assert_eq!(
            wait_state(ask.picked_up, Some(Instant::now())),
            WaitState::NotPickedUp
        );

        // Then it types again, after the ask. That one is ours.
        ask.note_typing(asked_at + Duration::from_secs(1), None);
        assert!(ask.picked_up);
    }

    #[test]
    fn a_picked_up_ask_that_goes_quiet_does_not_fall_back_to_not_picked_up() {
        // Once a turn has begun, the honest report is that it began and went
        // quiet — not that nobody ever looked, which would be a new false
        // statement rather than the absence of one.
        let mut ask = pending_at(ago(60));
        ask.note_typing(ago(59), None);
        assert_eq!(wait_state(ask.picked_up, Some(ago(40))), WaitState::Stalled);
    }

    #[test]
    fn a_named_trigger_decides_exactly_and_ignores_another_turn() {
        // With buzz-acp's `trigger` tag there is no guessing: an indicator for
        // a different event is somebody else's turn, even though it arrives on
        // this seat, in this channel, after our ask. That is the whole point
        // of the tag — in a DM this is the common case, not a corner.
        let mut ask = pending_at(ago(30));
        ask.event_id = Some(id(1));

        ask.note_typing(Instant::now(), Some(&id(2)));
        assert!(
            !ask.picked_up,
            "another turn's indicator is not our pick-up"
        );

        ask.note_typing(Instant::now(), Some(&id(1)));
        assert!(ask.picked_up, "our own trigger is exact");
    }

    #[test]
    fn a_named_trigger_counts_even_when_it_looks_too_early() {
        // Exactness beats the timing heuristic: if the seat names our event,
        // it is ours whatever the clocks say.
        let asked_at = ago(30);
        let mut ask = pending_at(asked_at);
        ask.event_id = Some(id(7));
        ask.note_typing(asked_at - Duration::from_secs(5), Some(&id(7)));
        assert!(ask.picked_up);
    }

    #[test]
    fn without_a_trigger_the_timing_fallback_still_applies() {
        // A seat on an older buzz-acp sends no tag, and the Mac seats trail
        // every roll — so the fallback has to keep working.
        let asked_at = ago(30);
        let mut ask = pending_at(asked_at);
        ask.event_id = Some(id(3));
        ask.note_typing(asked_at - Duration::from_secs(1), None);
        assert!(
            !ask.picked_up,
            "an untagged indicator predating the ask is not ours"
        );
        ask.note_typing(asked_at + Duration::from_secs(1), None);
        assert!(ask.picked_up);
    }

    #[test]
    fn every_wait_state_has_a_distinct_log_name() {
        let names = [
            WaitState::NotPickedUp.as_str(),
            WaitState::Working.as_str(),
            WaitState::Stalled.as_str(),
        ];
        let unique: HashSet<&str> = names.iter().copied().collect();
        assert_eq!(
            unique.len(),
            names.len(),
            "waiting_tick states must be distinguishable in the log"
        );
    }

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
        assert_eq!(
            elided["serverContent"]["modelTurn"]["parts"][1]["text"],
            "kept"
        );
        assert_eq!(elided["usageMetadata"]["totalTokenCount"], 7);
    }

    #[test]
    fn an_unparsed_message_is_named_by_its_keys() {
        let message = json!({ "somethingNew": { "a": 1 }, "goAwayLater": true });
        assert!(gemini::parse_server_message(&message).is_empty());
        assert_eq!(
            top_level_keys(&message),
            vec!["goAwayLater", "somethingNew"]
        );
        assert!(top_level_keys(&json!([1, 2])).is_empty());
    }

    #[test]
    fn counts_read_as_a_human_would_say_them() {
        assert_eq!(plural(0, "error"), "0 errors");
        assert_eq!(plural(1, "Gemini reconnect"), "1 Gemini reconnect");
        assert_eq!(plural(2, "Gemini reconnect"), "2 Gemini reconnects");
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
