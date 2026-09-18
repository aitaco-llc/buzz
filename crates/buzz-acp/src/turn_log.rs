//! Durable, local, per-turn record of harness activity.
//!
//! Off by default. When `BUZZ_ACP_TURN_LOG_DIR` is set, the harness keeps a
//! record that answers post-mortem questions the relay cannot ("what did the
//! agent see, what did it do, and why did it not answer?") and that does not
//! depend on agent transcript pruning or journal rotation:
//!
//! - `turns/<YYYY-MM-DD>/<turn_id>.jsonl` — every observer event for one turn,
//!   in emission order: the raw ACP frames (`acp_write` carries the prompt the
//!   agent received, `acp_read` its messages and tool calls), `turn_started`
//!   (with the triggering event ids), `turn_completed`, and the harness's
//!   outcome label.
//! - `index/<YYYY-MM-DD>.jsonl` — one line per finished turn, carrying the
//!   seat pubkey and the triggering event ids, so
//!   `grep <event-id> index/*.jsonl` finds the turn.
//! - `decisions/<YYYY-MM-DD>.jsonl` — one line per inbound channel event the
//!   harness queued or dropped, with the reason: the record for events that
//!   never became a turn.
//! - `harness/<YYYY-MM-DD>.jsonl` — observer events that belong to no turn
//!   (harness start, busy-owner holds, control results) and gaps in this log.
//!
//! Every file is partitioned by UTC day, so retention is deleting old files
//! (for example a `systemd-tmpfiles` age rule); nothing is held open across a
//! day boundary.
//!
//! Turn records come from the same in-process observer bus the relay observer
//! publishes from; decisions and outcomes are sent here directly so they never
//! reach the relay. Writes happen on a dedicated OS thread fed by a bounded
//! channel whose queued bytes are capped: the harness never blocks on disk,
//! and when the cap is reached the record is dropped and counted in the
//! harness log rather than stalling a turn or growing memory.

use std::collections::{HashMap, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, SyncSender, TryRecvError, TrySendError};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tokio::sync::broadcast;

use crate::observer::ObserverEvent;

/// Messages buffered between the harness and the writer thread.
const CHANNEL_CAPACITY: usize = 8_192;
/// Serialized bytes allowed to wait for the writer. A single agent message
/// can be megabytes, so a record count alone does not bound memory.
const MAX_QUEUED_BYTES: usize = 64 * 1024 * 1024;
/// How long a turn waits for its other half (observer `turn_completed` or the
/// harness outcome) before its index line is written without it.
const FINALIZE_GRACE: Duration = Duration::from_secs(60);
/// A turn with no events for this long is indexed and closed even if it never
/// completed (its completion was lost). Longer than any turn's deadline.
const IDLE_CAP: Duration = Duration::from_secs(3 * 60 * 60);
/// How often the writer checks for turns past their grace period.
const SWEEP_INTERVAL: Duration = Duration::from_secs(10);
/// Finished turns remembered so late events and outcomes land in the right file.
const RECENT_FINISHED_CAP: usize = 512;
/// Minimum spacing between repeated write-failure warnings (e.g. disk full).
const WARN_INTERVAL: Duration = Duration::from_secs(60);

/// Why an inbound event did or did not become work.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Queued for a turn.
    Queued,
    /// Refused by the queue: `dedup=drop` and a turn for this scope is in flight.
    DroppedScopeBusy,
    /// Dropped by the inbound author gate (respond-to policy).
    AuthorGate,
    /// Authorized, but no subscription rule matched (includes relevance-gate declines).
    NoRuleMatched,
}

impl Decision {
    fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::DroppedScopeBusy => "dropped_scope_busy",
            Self::AuthorGate => "author_gate",
            Self::NoRuleMatched => "no_rule_matched",
        }
    }
}

/// An observer event, serialized off the writer thread, with the few fields
/// the writer needs to route it.
struct Observed {
    line: String,
    turn_id: Option<String>,
    kind: String,
    timestamp: String,
    started_at: Option<String>,
    channel_id: Option<String>,
    session_id: Option<String>,
    source: Option<String>,
    triggering_event_ids: Vec<String>,
}

enum Msg {
    Observer(Box<Observed>),
    Lagged(u64),
    Decision(String),
    Outcome(Outcome),
    Shutdown(SyncSender<()>),
}

struct Outcome {
    turn_id: String,
    outcome: String,
    scope: Option<String>,
    timestamp: String,
}

impl Msg {
    fn queued_bytes(&self) -> usize {
        match self {
            Self::Observer(observed) => observed.line.len(),
            Self::Decision(line) => line.len(),
            Self::Lagged(_) | Self::Outcome(_) | Self::Shutdown(_) => 0,
        }
    }
}

/// Bounded, non-blocking sender shared by the harness and the observer
/// forwarder. Drops (and counts) rather than blocking or over-buffering.
#[derive(Clone)]
struct Sender {
    tx: SyncSender<Msg>,
    queued_bytes: Arc<AtomicUsize>,
    dropped: Arc<AtomicU64>,
}

impl Sender {
    /// Queue `msg`, or drop and count it. Returns `false` only when the
    /// writer is gone.
    fn send(&self, msg: Msg) -> bool {
        let bytes = msg.queued_bytes();
        if bytes > 0 && self.queued_bytes.load(Ordering::Relaxed) + bytes > MAX_QUEUED_BYTES {
            self.dropped.fetch_add(1, Ordering::Relaxed);
            return true;
        }
        self.queued_bytes.fetch_add(bytes, Ordering::Relaxed);
        match self.tx.try_send(msg) {
            Ok(()) => true,
            Err(TrySendError::Full(_)) => {
                self.queued_bytes.fetch_sub(bytes, Ordering::Relaxed);
                self.dropped.fetch_add(1, Ordering::Relaxed);
                true
            }
            Err(TrySendError::Disconnected(_)) => {
                self.queued_bytes.fetch_sub(bytes, Ordering::Relaxed);
                false
            }
        }
    }
}

/// Handle the harness uses to record decisions and turn outcomes.
#[derive(Clone)]
pub struct TurnLog {
    sender: Sender,
    seat_pubkey: String,
}

impl TurnLog {
    /// Create the log directory, start the writer thread, and forward the
    /// observer bus into it. Subscribe `observer_rx` before emitting anything
    /// that should be logged (e.g. `harness_started`).
    pub fn start(
        dir: PathBuf,
        seat_pubkey: String,
        mut observer_rx: broadcast::Receiver<ObserverEvent>,
    ) -> std::io::Result<Self> {
        create_private_dir(&dir)?;
        let (tx, rx) = mpsc::sync_channel(CHANNEL_CAPACITY);
        let sender = Sender {
            tx,
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            dropped: Arc::new(AtomicU64::new(0)),
        };

        let mut writer = Writer::new(
            dir,
            seat_pubkey.clone(),
            sender.dropped.clone(),
            sender.queued_bytes.clone(),
        );
        std::thread::Builder::new()
            .name("buzz-acp-turn-log".into())
            .spawn(move || writer.run(rx))?;

        let forward = sender.clone();
        let forward_seat = seat_pubkey.clone();
        tokio::spawn(async move {
            loop {
                let msg = match observer_rx.recv().await {
                    Ok(event) => match observed(&event, &forward_seat) {
                        Some(observed) => Msg::Observer(Box::new(observed)),
                        None => continue,
                    },
                    Err(broadcast::error::RecvError::Lagged(count)) => Msg::Lagged(count),
                    Err(broadcast::error::RecvError::Closed) => break,
                };
                if !forward.send(msg) {
                    break;
                }
            }
        });

        Ok(Self {
            sender,
            seat_pubkey,
        })
    }

    /// Record what the harness did with an inbound channel event.
    pub fn decision(
        &self,
        event: &nostr::Event,
        channel_id: uuid::Uuid,
        decision: Decision,
        scope: Option<&str>,
    ) {
        let thread = crate::queue::parse_thread_tags(event);
        let line = json!({
            "ts": chrono::Utc::now().to_rfc3339(),
            "seat": self.seat_pubkey,
            "eventId": event.id.to_hex(),
            "kind": event.kind.as_u16(),
            "author": event.pubkey.to_hex(),
            "channelId": channel_id.to_string(),
            "threadRoot": thread.root_event_id,
            "decision": decision.as_str(),
            "scope": scope,
        });
        self.sender.send(Msg::Decision(line.to_string()));
    }

    /// Record the harness's outcome label for a finished turn.
    pub fn outcome(&self, turn_id: &str, outcome: &str, scope: Option<String>) {
        self.sender.send(Msg::Outcome(Outcome {
            turn_id: turn_id.to_owned(),
            outcome: outcome.to_owned(),
            scope,
            timestamp: chrono::Utc::now().to_rfc3339(),
        }));
    }

    /// Flush queued records, index turns still open as `harness_exit`, and
    /// stop the writer. Blocks for at most `timeout`; call it from a blocking
    /// context at harness exit.
    pub fn close(&self, timeout: Duration) {
        let deadline = Instant::now() + timeout;
        let (ack_tx, ack_rx) = mpsc::sync_channel(1);
        let mut msg = Msg::Shutdown(ack_tx);
        loop {
            match self.sender.tx.try_send(msg) {
                Ok(()) => break,
                Err(TrySendError::Full(returned)) if Instant::now() < deadline => {
                    msg = returned;
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(_) => {
                    tracing::warn!("turn log: writer did not accept shutdown; queued records lost");
                    return;
                }
            }
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if ack_rx.recv_timeout(remaining).is_err() {
            tracing::warn!("turn log: writer did not finish flushing before exit");
        }
    }
}

/// Serialize an observer event for the log. Events with no turn go to the
/// harness log, where each line also names the seat.
fn observed(event: &ObserverEvent, seat_pubkey: &str) -> Option<Observed> {
    let mut value = match serde_json::to_value(event) {
        Ok(value) => value,
        Err(error) => {
            tracing::warn!("turn log: unserializable observer event: {error}");
            return None;
        }
    };
    if event.turn_id.is_none() {
        if let Some(object) = value.as_object_mut() {
            object.insert("seat".into(), Value::String(seat_pubkey.to_owned()));
        }
    }
    let (source, triggering_event_ids) = if event.kind == "turn_started" {
        (
            event
                .payload
                .get("source")
                .and_then(Value::as_str)
                .map(str::to_owned),
            event
                .payload
                .get("triggeringEventIds")
                .and_then(Value::as_array)
                .map(|ids| {
                    ids.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default(),
        )
    } else {
        (None, Vec::new())
    };
    Some(Observed {
        line: value.to_string(),
        turn_id: event.turn_id.clone(),
        kind: event.kind.clone(),
        timestamp: event.timestamp.clone(),
        started_at: event.started_at.clone(),
        channel_id: event.channel_id.clone(),
        session_id: event.session_id.clone(),
        source,
        triggering_event_ids,
    })
}

struct TurnState {
    file: Option<File>,
    rel_path: String,
    events: u64,
    started_at: Option<String>,
    channel_id: Option<String>,
    session_id: Option<String>,
    source: Option<String>,
    triggering_event_ids: Vec<String>,
    completed_at: Option<String>,
    outcome: Option<(String, Option<String>)>,
    waiting_since: Option<Instant>,
    last_event: Instant,
}

struct PendingOutcome {
    outcome: Outcome,
    received: Instant,
}

/// A log file partitioned by UTC day. The handle is reopened when the day
/// changes, so old days can be deleted without a restart.
struct DayFile {
    subdir: &'static str,
    day: String,
    file: Option<File>,
}

impl DayFile {
    fn new(subdir: &'static str) -> Self {
        Self {
            subdir,
            day: String::new(),
            file: None,
        }
    }
}

#[derive(Clone, Copy)]
enum DayLog {
    Index,
    Decisions,
    Harness,
}

struct Writer {
    dir: PathBuf,
    seat_pubkey: String,
    dropped: Arc<AtomicU64>,
    queued_bytes: Arc<AtomicUsize>,
    turns: HashMap<String, TurnState>,
    pending_outcomes: HashMap<String, PendingOutcome>,
    recent_finished: VecDeque<(String, String)>,
    index: DayFile,
    decisions: DayFile,
    harness: DayFile,
    last_warn: Option<Instant>,
}

impl Writer {
    fn new(
        dir: PathBuf,
        seat_pubkey: String,
        dropped: Arc<AtomicU64>,
        queued_bytes: Arc<AtomicUsize>,
    ) -> Self {
        Self {
            dir,
            seat_pubkey,
            dropped,
            queued_bytes,
            turns: HashMap::new(),
            pending_outcomes: HashMap::new(),
            recent_finished: VecDeque::new(),
            index: DayFile::new("index"),
            decisions: DayFile::new("decisions"),
            harness: DayFile::new("harness"),
            last_warn: None,
        }
    }

    fn run(&mut self, rx: mpsc::Receiver<Msg>) {
        let mut last_sweep = Instant::now();
        loop {
            match rx.recv_timeout(SWEEP_INTERVAL) {
                Ok(Msg::Shutdown(ack)) => {
                    self.drain(&rx);
                    self.finalize_all("harness_exit");
                    let _ = ack.send(());
                    return;
                }
                Ok(msg) => self.handle(msg),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    self.finalize_all("harness_exit");
                    return;
                }
            }
            if last_sweep.elapsed() >= SWEEP_INTERVAL {
                self.sweep(Instant::now());
                last_sweep = Instant::now();
            }
        }
    }

    /// Handle everything already queued, without waiting for more.
    fn drain(&mut self, rx: &mpsc::Receiver<Msg>) {
        loop {
            match rx.try_recv() {
                Ok(msg) => self.handle(msg),
                Err(TryRecvError::Empty | TryRecvError::Disconnected) => return,
            }
        }
    }

    fn handle(&mut self, msg: Msg) {
        self.queued_bytes
            .fetch_sub(msg.queued_bytes(), Ordering::Relaxed);
        self.report_dropped();
        match msg {
            Msg::Observer(observed) => self.observer_event(*observed),
            Msg::Lagged(count) => {
                let line = json!({
                    "timestamp": chrono::Utc::now().to_rfc3339(),
                    "kind": "turn_log_lagged",
                    "seat": self.seat_pubkey,
                    "droppedObserverEvents": count,
                });
                self.day_line(DayLog::Harness, &line.to_string());
            }
            Msg::Decision(line) => self.day_line(DayLog::Decisions, &line),
            Msg::Outcome(outcome) => self.outcome(outcome),
            // A second shutdown while draining: acknowledge; the first one
            // finishes the flush.
            Msg::Shutdown(ack) => {
                let _ = ack.send(());
            }
        }
    }

    fn report_dropped(&mut self) {
        let dropped = self.dropped.swap(0, Ordering::Relaxed);
        if dropped > 0 {
            let line = json!({
                "timestamp": chrono::Utc::now().to_rfc3339(),
                "kind": "turn_log_dropped",
                "seat": self.seat_pubkey,
                "droppedRecords": dropped,
            });
            self.day_line(DayLog::Harness, &line.to_string());
        }
    }

    fn day_line(&mut self, which: DayLog, line: &str) {
        let today = chrono::Utc::now().format("%Y-%m-%d").to_string();
        let target = match which {
            DayLog::Index => &mut self.index,
            DayLog::Decisions => &mut self.decisions,
            DayLog::Harness => &mut self.harness,
        };
        if target.day != today {
            target.file = None;
            target.day = today;
        }
        let subdir = self.dir.join(target.subdir);
        let path = subdir.join(format!("{}.jsonl", target.day));
        let result = if target.file.is_none() {
            create_private_dir(&subdir).and_then(|()| append_line(&mut target.file, &path, line))
        } else {
            append_line(&mut target.file, &path, line)
        };
        if let Err(error) = result {
            warn_limited(&mut self.last_warn, &path, &error);
        }
    }

    fn turn_line(&mut self, turn_id: &str, line: &str) {
        let Some(state) = self.turns.get_mut(turn_id) else {
            return;
        };
        let path = self.dir.join(&state.rel_path);
        if let Err(error) = append_line(&mut state.file, &path, line) {
            warn_limited(&mut self.last_warn, &path, &error);
        }
    }

    /// Append to a finished turn's file without reopening its state.
    fn finished_turn_line(&mut self, rel_path: &str, line: &str) {
        let path = self.dir.join(rel_path);
        let mut file = None;
        if let Err(error) = append_line(&mut file, &path, line) {
            warn_limited(&mut self.last_warn, &path, &error);
        }
    }

    fn recent_path(&self, turn_id: &str) -> Option<String> {
        self.recent_finished
            .iter()
            .find(|(id, _)| id == turn_id)
            .map(|(_, rel)| rel.clone())
    }

    fn observer_event(&mut self, observed: Observed) {
        let Some(turn_id) = observed.turn_id.clone() else {
            self.day_line(DayLog::Harness, &observed.line);
            return;
        };
        // Events can trail a finished turn (e.g. `turn_error`, emitted after
        // the outcome). They belong in its file and must not reopen it.
        if !self.turns.contains_key(&turn_id) {
            if let Some(rel_path) = self.recent_path(&turn_id) {
                self.finished_turn_line(&rel_path, &observed.line);
                return;
            }
            let state = new_turn_state(&self.dir, &turn_id, &observed);
            self.turns.insert(turn_id.clone(), state);
        }
        self.turn_line(&turn_id, &observed.line);

        let Some(state) = self.turns.get_mut(&turn_id) else {
            return;
        };
        state.events += 1;
        state.last_event = Instant::now();
        if state.channel_id.is_none() {
            state.channel_id = observed.channel_id;
        }
        if observed.session_id.is_some() {
            state.session_id = observed.session_id;
        }
        match observed.kind.as_str() {
            "turn_started" => {
                state.started_at = observed.started_at.or(Some(observed.timestamp));
                state.source = observed.source;
                state.triggering_event_ids = observed.triggering_event_ids;
            }
            "turn_completed" => {
                state.completed_at = Some(observed.timestamp);
                state.waiting_since.get_or_insert_with(Instant::now);
            }
            _ => {}
        }
        if let Some(pending) = self.pending_outcomes.remove(&turn_id) {
            self.attach_outcome(&turn_id, pending.outcome);
        }
        self.finalize_if_complete(&turn_id);
    }

    fn attach_outcome(&mut self, turn_id: &str, outcome: Outcome) {
        self.turn_line(turn_id, &outcome_line(&outcome).to_string());
        if let Some(state) = self.turns.get_mut(turn_id) {
            state.outcome = Some((outcome.outcome, outcome.scope));
            state.waiting_since.get_or_insert_with(Instant::now);
        }
    }

    fn finalize_if_complete(&mut self, turn_id: &str) {
        let complete = self
            .turns
            .get(turn_id)
            .is_some_and(|state| state.completed_at.is_some() && state.outcome.is_some());
        if complete {
            self.finalize(turn_id, None);
        }
    }

    fn outcome(&mut self, outcome: Outcome) {
        let turn_id = outcome.turn_id.clone();
        if self.turns.contains_key(&turn_id) {
            self.attach_outcome(&turn_id, outcome);
            self.finalize_if_complete(&turn_id);
            return;
        }
        if let Some(rel_path) = self.recent_path(&turn_id) {
            // The turn was indexed after its grace period; record the outcome
            // where the turn lives and note it in the index.
            self.finished_turn_line(&rel_path, &outcome_line(&outcome).to_string());
            let line = json!({
                "seat": self.seat_pubkey,
                "turnId": turn_id,
                "outcome": outcome.outcome,
                "scope": outcome.scope,
                "endedAt": outcome.timestamp,
                "path": rel_path,
                "note": "late outcome",
            });
            self.day_line(DayLog::Index, &line.to_string());
            return;
        }
        // The turn's events have not reached the writer yet (they travel a
        // different path). Hold the outcome until they do.
        self.pending_outcomes.insert(
            turn_id,
            PendingOutcome {
                outcome,
                received: Instant::now(),
            },
        );
    }

    fn finalize(&mut self, turn_id: &str, note: Option<&str>) {
        let Some(state) = self.turns.remove(turn_id) else {
            return;
        };
        let (outcome, scope) = match state.outcome {
            Some((outcome, scope)) => (Some(outcome), scope),
            None => (None, None),
        };
        let mut line = json!({
            "seat": self.seat_pubkey,
            "turnId": turn_id,
            "triggeringEventIds": state.triggering_event_ids,
            "channelId": state.channel_id,
            "scope": scope,
            "sessionId": state.session_id,
            "source": state.source,
            "startedAt": state.started_at,
            "completedAt": state.completed_at,
            "outcome": outcome,
            "events": state.events,
            "path": state.rel_path,
        });
        if let (Some(note), Some(object)) = (note, line.as_object_mut()) {
            object.insert("note".into(), Value::String(note.to_owned()));
        }
        self.day_line(DayLog::Index, &line.to_string());
        self.recent_finished
            .push_back((turn_id.to_owned(), state.rel_path));
        while self.recent_finished.len() > RECENT_FINISHED_CAP {
            self.recent_finished.pop_front();
        }
    }

    /// Index what has waited too long: a turn missing its other half past the
    /// grace period (worker panic, observer lag), a turn silent past the idle
    /// cap (completion lost), and an outcome whose turn never showed up.
    fn sweep(&mut self, now: Instant) {
        let mut expired: Vec<(String, &'static str)> = Vec::new();
        for (id, state) in &self.turns {
            let waited = state
                .waiting_since
                .is_some_and(|since| now.saturating_duration_since(since) >= FINALIZE_GRACE);
            if waited {
                let note = if state.outcome.is_none() {
                    "no outcome from the harness"
                } else {
                    "no turn_completed event"
                };
                expired.push((id.clone(), note));
            } else if now.saturating_duration_since(state.last_event) >= IDLE_CAP {
                expired.push((id.clone(), "idle; turn never completed"));
            }
        }
        for (turn_id, note) in expired {
            self.finalize(&turn_id, Some(note));
        }

        let orphans: Vec<String> = self
            .pending_outcomes
            .iter()
            .filter(|(_, p)| now.saturating_duration_since(p.received) >= FINALIZE_GRACE)
            .map(|(id, _)| id.clone())
            .collect();
        for turn_id in orphans {
            if let Some(pending) = self.pending_outcomes.remove(&turn_id) {
                self.index_orphan_outcome(pending.outcome);
            }
        }
    }

    fn index_orphan_outcome(&mut self, outcome: Outcome) {
        let line = json!({
            "seat": self.seat_pubkey,
            "turnId": outcome.turn_id,
            "outcome": outcome.outcome,
            "scope": outcome.scope,
            "endedAt": outcome.timestamp,
            "path": Value::Null,
            "note": "no observer events for this turn",
        });
        self.day_line(DayLog::Index, &line.to_string());
    }

    fn finalize_all(&mut self, reason: &str) {
        let open: Vec<String> = self.turns.keys().cloned().collect();
        for turn_id in open {
            // No outcome by now means the harness is exiting under the turn:
            // it was still running, or its worker was torn down by shutdown.
            if let Some(state) = self.turns.get_mut(&turn_id) {
                if state.outcome.is_none() {
                    state.outcome = Some((reason.to_owned(), None));
                }
            }
            self.finalize(&turn_id, None);
        }
        let pending: Vec<PendingOutcome> = self.pending_outcomes.drain().map(|(_, p)| p).collect();
        for p in pending {
            self.index_orphan_outcome(p.outcome);
        }
    }
}

fn outcome_line(outcome: &Outcome) -> Value {
    json!({
        "timestamp": outcome.timestamp,
        "kind": "turn_outcome",
        "turnId": outcome.turn_id,
        "payload": { "outcome": outcome.outcome, "scope": outcome.scope },
    })
}

fn new_turn_state(dir: &Path, turn_id: &str, observed: &Observed) -> TurnState {
    let started = observed
        .started_at
        .as_deref()
        .unwrap_or(&observed.timestamp);
    let day = day_of(started);
    let rel_path = format!("turns/{day}/{}.jsonl", safe_file_stem(turn_id));
    if let Err(error) = create_private_dir(&dir.join("turns").join(&day)) {
        tracing::warn!("turn log: cannot create turns/{day}: {error}");
    }
    TurnState {
        file: None,
        rel_path,
        events: 0,
        started_at: observed.started_at.clone(),
        channel_id: observed.channel_id.clone(),
        session_id: observed.session_id.clone(),
        source: None,
        triggering_event_ids: Vec::new(),
        completed_at: None,
        outcome: None,
        waiting_since: None,
        last_event: Instant::now(),
    }
}

/// `YYYY-MM-DD` from an RFC 3339 timestamp; `unknown-date` if it is not one.
fn day_of(timestamp: &str) -> String {
    match chrono::DateTime::parse_from_rfc3339(timestamp) {
        Ok(ts) => ts
            .with_timezone(&chrono::Utc)
            .format("%Y-%m-%d")
            .to_string(),
        Err(_) => "unknown-date".to_owned(),
    }
}

/// Keep only characters that are safe in a file name, so an unexpected turn
/// id can never escape the turns directory.
fn safe_file_stem(turn_id: &str) -> String {
    let stem: String = turn_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .take(128)
        .collect();
    if stem.is_empty() {
        "unnamed-turn".to_owned()
    } else {
        stem
    }
}

fn create_private_dir(path: &Path) -> std::io::Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(path)
}

fn open_private_append(path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

/// Append one line, opening the file on first use. On a failure the handle is
/// dropped so the next line retries the open.
fn append_line(file: &mut Option<File>, path: &Path, line: &str) -> std::io::Result<()> {
    if file.is_none() {
        *file = Some(open_private_append(path)?);
    }
    let mut bytes = Vec::with_capacity(line.len() + 1);
    bytes.extend_from_slice(line.as_bytes());
    bytes.push(b'\n');
    if let Some(handle) = file.as_mut() {
        if let Err(error) = handle.write_all(&bytes) {
            *file = None;
            return Err(error);
        }
    }
    Ok(())
}

/// Warn about a write failure at most once per [`WARN_INTERVAL`], so a full
/// disk does not turn every agent frame into a log line.
fn warn_limited(last_warn: &mut Option<Instant>, path: &Path, error: &std::io::Error) {
    let now = Instant::now();
    if last_warn.is_some_and(|at| now.saturating_duration_since(at) < WARN_INTERVAL) {
        return;
    }
    *last_warn = Some(now);
    tracing::warn!("turn log: write to {} failed: {error}", path.display());
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let dir =
                std::env::temp_dir().join(format!("buzz-acp-turn-log-{}", uuid::Uuid::new_v4()));
            fs::create_dir_all(&dir).expect("create temp dir");
            Self(dir)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn writer(dir: &Path) -> Writer {
        Writer::new(
            dir.to_path_buf(),
            "seat".into(),
            Arc::new(AtomicU64::new(0)),
            Arc::new(AtomicUsize::new(0)),
        )
    }

    fn event(seq: u64, kind: &str, turn_id: Option<&str>, payload: Value) -> ObserverEvent {
        ObserverEvent {
            seq,
            timestamp: "2026-09-18T20:00:00+00:00".into(),
            kind: kind.into(),
            agent_index: Some(0),
            channel_id: Some("8dd69e3d-8b3c-49fd-ad42-a3e32f495379".into()),
            session_id: None,
            turn_id: turn_id.map(str::to_owned),
            started_at: turn_id.map(|_| "2026-09-18T19:59:59+00:00".to_owned()),
            payload,
        }
    }

    fn obs(seq: u64, kind: &str, turn_id: Option<&str>, payload: Value) -> Msg {
        let event = event(seq, kind, turn_id, payload);
        Msg::Observer(Box::new(observed(&event, "seat").expect("serializable")))
    }

    fn started(turn_id: &str) -> Msg {
        obs(
            1,
            "turn_started",
            Some(turn_id),
            json!({"source": "channel", "triggeringEventIds": ["e1", "e2"]}),
        )
    }

    fn outcome(turn_id: &str, label: &str) -> Msg {
        Msg::Outcome(Outcome {
            turn_id: turn_id.into(),
            outcome: label.into(),
            scope: Some("thread:abc".into()),
            timestamp: "2026-09-18T20:00:05+00:00".into(),
        })
    }

    fn lines(path: &Path) -> Vec<Value> {
        fs::read_to_string(path)
            .unwrap_or_default()
            .lines()
            .map(|line| serde_json::from_str(line).expect("valid json line"))
            .collect()
    }

    fn today_file(dir: &Path, sub: &str) -> PathBuf {
        dir.join(sub)
            .join(format!("{}.jsonl", chrono::Utc::now().format("%Y-%m-%d")))
    }

    #[test]
    fn turn_is_indexed_once_whichever_half_arrives_first() {
        for outcome_first in [false, true] {
            let tmp = TempDir::new();
            let mut w = writer(&tmp.0);
            w.handle(started("turn-1"));
            w.handle(obs(
                2,
                "acp_write",
                Some("turn-1"),
                json!({"method": "session/prompt"}),
            ));
            let completed = obs(3, "turn_completed", Some("turn-1"), json!({}));
            if outcome_first {
                w.handle(outcome("turn-1", "ok"));
                w.handle(completed);
            } else {
                w.handle(completed);
                w.handle(outcome("turn-1", "ok"));
            }

            let index = lines(&today_file(&tmp.0, "index"));
            assert_eq!(index.len(), 1, "outcome_first={outcome_first}");
            let row = &index[0];
            assert_eq!(row["seat"], "seat");
            assert_eq!(row["turnId"], "turn-1");
            assert_eq!(row["triggeringEventIds"], json!(["e1", "e2"]));
            assert_eq!(row["outcome"], "ok");
            assert_eq!(row["scope"], "thread:abc");
            assert_eq!(row["source"], "channel");
            assert_eq!(row["startedAt"], "2026-09-18T19:59:59+00:00");
            assert_eq!(row["path"], "turns/2026-09-18/turn-1.jsonl");
            assert!(row.get("note").is_none());

            let turn = lines(&tmp.0.join("turns/2026-09-18/turn-1.jsonl"));
            let kinds: Vec<&str> = turn.iter().map(|l| l["kind"].as_str().unwrap()).collect();
            assert_eq!(kinds.len(), 4);
            assert!(kinds.contains(&"turn_outcome"));
            assert!(w.turns.is_empty());
            assert!(w.pending_outcomes.is_empty());
        }
    }

    #[test]
    fn outcome_before_any_turn_event_is_held_until_the_turn_arrives() {
        let tmp = TempDir::new();
        let mut w = writer(&tmp.0);
        w.handle(outcome("t", "error"));
        assert!(!today_file(&tmp.0, "index").exists(), "held, not indexed");
        w.handle(started("t"));
        w.handle(obs(2, "turn_completed", Some("t"), json!({})));

        let index = lines(&today_file(&tmp.0, "index"));
        assert_eq!(index.len(), 1);
        assert_eq!(index[0]["outcome"], "error");
        assert_eq!(index[0]["triggeringEventIds"], json!(["e1", "e2"]));
        assert_eq!(index[0]["path"], "turns/2026-09-18/t.jsonl");
        let turn = lines(&tmp.0.join("turns/2026-09-18/t.jsonl"));
        assert!(turn.iter().any(|l| l["kind"] == "turn_outcome"));
    }

    #[test]
    fn events_after_finalize_append_to_the_turn_without_reopening_it() {
        let tmp = TempDir::new();
        let mut w = writer(&tmp.0);
        w.handle(started("t"));
        w.handle(outcome("t", "error"));
        w.handle(obs(2, "turn_completed", Some("t"), json!({})));
        // `handle_prompt_result` emits `turn_error` after the outcome.
        w.handle(obs(3, "turn_error", Some("t"), json!({"error": "boom"})));

        assert!(w.turns.is_empty(), "no orphan state holding the file open");
        w.finalize_all("harness_exit");
        let index = lines(&today_file(&tmp.0, "index"));
        assert_eq!(index.len(), 1, "no second index line: {index:?}");
        let turn = lines(&tmp.0.join("turns/2026-09-18/t.jsonl"));
        assert_eq!(turn.last().unwrap()["kind"], "turn_error");
    }

    #[test]
    fn events_without_a_turn_go_to_harness_log_with_the_seat() {
        let tmp = TempDir::new();
        let mut w = writer(&tmp.0);
        w.handle(obs(1, "harness_started", None, json!({})));
        w.handle(Msg::Lagged(7));
        let harness = lines(&today_file(&tmp.0, "harness"));
        assert_eq!(harness[0]["kind"], "harness_started");
        assert_eq!(harness[0]["seat"], "seat");
        assert_eq!(harness[1]["kind"], "turn_log_lagged");
        assert_eq!(harness[1]["droppedObserverEvents"], 7);
        assert!(!today_file(&tmp.0, "index").exists());
    }

    #[test]
    fn completion_without_outcome_is_indexed_after_grace_then_late_outcome_noted() {
        let tmp = TempDir::new();
        let mut w = writer(&tmp.0);
        w.handle(started("t"));
        w.handle(obs(2, "turn_completed", Some("t"), json!({})));
        w.sweep(Instant::now());
        assert!(!today_file(&tmp.0, "index").exists(), "still inside grace");
        w.sweep(Instant::now() + FINALIZE_GRACE + Duration::from_secs(1));
        let index = lines(&today_file(&tmp.0, "index"));
        assert_eq!(index.len(), 1);
        assert_eq!(index[0]["outcome"], Value::Null);
        assert_eq!(index[0]["note"], "no outcome from the harness");

        w.handle(outcome("t", "error"));
        let index = lines(&today_file(&tmp.0, "index"));
        assert_eq!(index.len(), 2);
        assert_eq!(index[1]["note"], "late outcome");
        let turn = lines(&tmp.0.join("turns/2026-09-18/t.jsonl"));
        assert_eq!(turn.last().unwrap()["kind"], "turn_outcome");
    }

    #[test]
    fn outcome_whose_turn_never_appears_is_indexed_after_grace() {
        let tmp = TempDir::new();
        let mut w = writer(&tmp.0);
        w.handle(outcome("ghost", "timeout"));
        w.sweep(Instant::now() + FINALIZE_GRACE + Duration::from_secs(1));
        let index = lines(&today_file(&tmp.0, "index"));
        assert_eq!(index[0]["turnId"], "ghost");
        assert_eq!(index[0]["note"], "no observer events for this turn");
        assert!(w.pending_outcomes.is_empty());
    }

    #[test]
    fn silent_turn_is_closed_at_the_idle_cap() {
        let tmp = TempDir::new();
        let mut w = writer(&tmp.0);
        w.handle(started("t"));
        w.sweep(Instant::now() + IDLE_CAP - Duration::from_secs(1));
        assert_eq!(w.turns.len(), 1);
        w.sweep(Instant::now() + IDLE_CAP + Duration::from_secs(1));
        assert!(w.turns.is_empty());
        let index = lines(&today_file(&tmp.0, "index"));
        assert_eq!(index[0]["note"], "idle; turn never completed");
    }

    #[test]
    fn open_turns_are_indexed_on_harness_exit() {
        let tmp = TempDir::new();
        let mut w = writer(&tmp.0);
        w.handle(started("running"));
        // Completed by the teardown itself, with no outcome from the harness.
        w.handle(started("torn-down"));
        w.handle(obs(2, "turn_completed", Some("torn-down"), json!({})));
        w.finalize_all("harness_exit");
        let index = lines(&today_file(&tmp.0, "index"));
        assert_eq!(index.len(), 2);
        assert!(index.iter().all(|row| row["outcome"] == "harness_exit"));
    }

    #[test]
    fn dropped_records_are_reported() {
        let tmp = TempDir::new();
        let mut w = writer(&tmp.0);
        w.dropped.store(3, Ordering::Relaxed);
        w.handle(Msg::Lagged(1));
        let harness = lines(&today_file(&tmp.0, "harness"));
        assert_eq!(harness[0]["kind"], "turn_log_dropped");
        assert_eq!(harness[0]["droppedRecords"], 3);
    }

    #[test]
    fn sender_drops_instead_of_blocking_or_overbuffering() {
        let (tx, rx) = mpsc::sync_channel(1);
        let sender = Sender {
            tx,
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            dropped: Arc::new(AtomicU64::new(0)),
        };
        assert!(sender.send(Msg::Decision("a".into())));
        // Channel full: dropped and counted, byte accounting unwound.
        assert!(sender.send(Msg::Decision("bb".into())));
        assert_eq!(sender.dropped.load(Ordering::Relaxed), 1);
        assert_eq!(sender.queued_bytes.load(Ordering::Relaxed), 1);
        // Over the byte budget: dropped before it is queued.
        let _ = rx.try_recv();
        sender
            .queued_bytes
            .store(MAX_QUEUED_BYTES, Ordering::Relaxed);
        assert!(sender.send(Msg::Decision("c".into())));
        assert_eq!(sender.dropped.load(Ordering::Relaxed), 2);
        // Writer gone: reported as disconnected.
        sender.queued_bytes.store(0, Ordering::Relaxed);
        drop(rx);
        assert!(!sender.send(Msg::Decision("d".into())));
    }

    #[test]
    fn turn_ids_cannot_escape_the_turns_directory() {
        assert_eq!(safe_file_stem("../../etc/passwd"), "etcpasswd");
        assert_eq!(safe_file_stem("a/b\\c"), "abc");
        assert_eq!(safe_file_stem("//"), "unnamed-turn");
        assert_eq!(
            safe_file_stem("0f7c5f2e-7d7a-4d0e-9d0b-2b8b7d6e5f4a"),
            "0f7c5f2e-7d7a-4d0e-9d0b-2b8b7d6e5f4a"
        );
    }

    #[test]
    fn day_of_normalizes_to_utc() {
        assert_eq!(day_of("2026-09-18T23:30:00-06:00"), "2026-09-19");
        assert_eq!(day_of("not a date"), "unknown-date");
    }

    #[cfg(unix)]
    #[test]
    fn files_are_private() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = TempDir::new();
        let mut w = writer(&tmp.0);
        w.handle(started("t"));
        w.handle(outcome("t", "ok"));
        w.handle(obs(2, "turn_completed", Some("t"), json!({})));
        let mode = |p: PathBuf| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(today_file(&tmp.0, "index")), 0o600);
        assert_eq!(mode(tmp.0.join("index")), 0o700);
        assert_eq!(mode(tmp.0.join("turns/2026-09-18")), 0o700);
        assert_eq!(mode(tmp.0.join("turns/2026-09-18/t.jsonl")), 0o600);
    }

    #[tokio::test]
    async fn records_reach_disk_and_close_flushes_open_turns() {
        let tmp = TempDir::new();
        let observer = crate::observer::ObserverHandle::in_process();
        let log = TurnLog::start(tmp.0.clone(), "seat".into(), observer.subscribe())
            .expect("start turn log");

        let keys = nostr::Keys::generate();
        let root = "a".repeat(64);
        let event = nostr::EventBuilder::new(nostr::Kind::Custom(9), "hi")
            .tag(nostr::Tag::parse(["e", root.as_str(), "", "reply"]).unwrap())
            .sign_with_keys(&keys)
            .unwrap();
        let channel = uuid::Uuid::new_v4();
        log.decision(&event, channel, Decision::AuthorGate, None);
        observer.emit(
            "turn_started",
            Some(0),
            &crate::observer::context_for_turn(
                Some(channel),
                None,
                "open-turn".into(),
                chrono::Utc::now().to_rfc3339(),
            ),
            json!({"source": "channel", "triggeringEventIds": [event.id.to_hex()]}),
        );

        // Give the forwarder task a moment to hand the observer event over,
        // then close from a blocking context, as the harness does at exit.
        tokio::time::sleep(Duration::from_millis(200)).await;
        let closer = log.clone();
        tokio::task::spawn_blocking(move || closer.close(Duration::from_secs(5)))
            .await
            .unwrap();

        let decisions = lines(&today_file(&tmp.0, "decisions"));
        assert_eq!(decisions.len(), 1);
        assert_eq!(decisions[0]["eventId"], event.id.to_hex());
        assert_eq!(decisions[0]["decision"], "author_gate");
        assert_eq!(decisions[0]["channelId"], channel.to_string());
        assert_eq!(decisions[0]["threadRoot"], root);
        assert_eq!(decisions[0]["seat"], "seat");

        let index = lines(&today_file(&tmp.0, "index"));
        assert_eq!(index.len(), 1, "close indexes the open turn: {index:?}");
        assert_eq!(index[0]["turnId"], "open-turn");
        assert_eq!(index[0]["outcome"], "harness_exit");
        assert_eq!(index[0]["triggeringEventIds"], json!([event.id.to_hex()]));
    }
}
