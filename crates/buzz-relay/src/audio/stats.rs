//! Per-peer audio counters, for the question a huddle post-mortem always asks:
//! *was the relay fed, and did the relay feed this peer?*
//!
//! Before this module the audio path counted nothing. `broadcast_frame` drops
//! a frame on the floor with `let _ = try_send(…)` whenever a peer's 8-slot
//! outbound queue is full — 160 ms at 20 ms a frame — and nothing recorded it,
//! so a peer whose socket stalled for a fifth of a second lost audio that no
//! log, metric or trace could later name. The bridge can see its own side of
//! the line and nothing of the return path (`RESEARCH/VOICE_CALL_FBABA8A8_2026-09-21.md`),
//! which left the return path with no instrument at all.
//!
//! The counters are per peer and live as long as that peer's connection. They
//! are read two ways:
//!
//! - an `audio peer stats` log line every [`STATS_INTERVAL`] and once more when
//!   the peer leaves, carrying `channel_id` and `pubkey`, so a specific room
//!   and window can be reconstructed from the relay's own log — the same way
//!   `audio peer joined` / `audio peer left` already are;
//! - low-cardinality Prometheus counters for alerting. Deliberately **not**
//!   labelled by channel or pubkey: a huddle id is a fresh UUID every call, and
//!   a per-call label would grow the series set without bound.
//!
//! Nothing here is on a lock. Every counter is a relaxed atomic add on the
//! frame path; the inbound sequence and arrival tracking is per connection and
//! lives in the receive loop's own stack ([`InboundTracker`]).

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// How often a live peer's counters are written to the log.
pub const STATS_INTERVAL: Duration = Duration::from_secs(5);

/// An inter-arrival gap at or above this is worth naming individually. The
/// bridge uses the same threshold to decide it has heard nothing and must
/// inject silence (`SILENCE_AFTER`, buzz-voice-bridge `call.rs`), so the two
/// sides of one call are directly comparable.
const GAP_NOTABLE: Duration = Duration::from_millis(100);
/// A second threshold, for the stalls a listener actually hears as a cut-out.
const GAP_SEVERE: Duration = Duration::from_millis(500);

/// A `seq` delta at or above this is read as the sequence going *backwards*
/// (reordering, or a sender that restarted its counter) rather than as a
/// forward jump over a pile of lost frames. `seq` is a `u16` that wraps every
/// 65536 frames — about 22 minutes at 20 ms a frame — so a genuine forward gap
/// is never anywhere near half the space.
const SEQ_REGRESSION_FROM: u16 = 1 << 15;

/// Counters for one connected peer, shared between the receive loop (inbound)
/// and the room's fan-out (outbound).
#[derive(Debug, Default)]
pub struct PeerAudioStats {
    /// Frames this peer sent us that we accepted and forwarded.
    frames_in: AtomicU64,
    /// Frames this peer sent us that we refused: oversized, or a v2 header
    /// that would not parse. These never reach another participant.
    frames_in_refused: AtomicU64,
    /// Frames handed to this peer's outbound queue.
    frames_out: AtomicU64,
    /// Frames **dropped** because this peer's outbound queue was full. This is
    /// the relay failing to feed the peer, and it is the counter the return
    /// path never had.
    frames_out_dropped: AtomicU64,
    /// Discontinuities in this peer's inbound `seq`.
    seq_gaps: AtomicU64,
    /// Frames implied missing by those discontinuities.
    seq_missing: AtomicU64,
    /// Times the inbound `seq` went backwards: reordering, or a restart.
    seq_regressions: AtomicU64,
    /// Inbound frames that repeated the previous `seq`.
    seq_duplicates: AtomicU64,
    /// Inter-arrival gaps of at least 100 ms.
    gaps_over_100ms: AtomicU64,
    /// Inter-arrival gaps of at least 500 ms.
    gaps_over_500ms: AtomicU64,
    /// Summed length of the gaps counted in `gaps_over_100ms`, so the log says
    /// how much time was lost and not merely how many times it happened.
    gap_total_ms: AtomicU64,
    /// The single worst inter-arrival gap.
    gap_worst_ms: AtomicU64,
}

impl PeerAudioStats {
    /// One accepted inbound frame.
    pub fn frame_in(&self) {
        self.frames_in.fetch_add(1, Ordering::Relaxed);
        metrics::counter!("buzz_audio_frames_in_total").increment(1);
    }

    /// One inbound frame refused before fan-out.
    pub fn frame_in_refused(&self, reason: &'static str) {
        self.frames_in_refused.fetch_add(1, Ordering::Relaxed);
        metrics::counter!("buzz_audio_frames_refused_total", "reason" => reason).increment(1);
    }

    /// One frame accepted by this peer's outbound queue.
    pub fn frame_out(&self) {
        self.frames_out.fetch_add(1, Ordering::Relaxed);
        metrics::counter!("buzz_audio_frames_out_total").increment(1);
    }

    /// One frame dropped because this peer's outbound queue was full.
    pub fn frame_out_dropped(&self) {
        self.frames_out_dropped.fetch_add(1, Ordering::Relaxed);
        metrics::counter!("buzz_audio_frames_out_dropped_total").increment(1);
    }

    fn note_gap(&self, gap: Duration) {
        let ms = gap.as_millis().min(u64::MAX as u128) as u64;
        self.gap_worst_ms.fetch_max(ms, Ordering::Relaxed);
        if gap < GAP_NOTABLE {
            return;
        }
        self.gaps_over_100ms.fetch_add(1, Ordering::Relaxed);
        self.gap_total_ms.fetch_add(ms, Ordering::Relaxed);
        metrics::counter!("buzz_audio_inbound_gaps_over_100ms_total").increment(1);
        if gap >= GAP_SEVERE {
            self.gaps_over_500ms.fetch_add(1, Ordering::Relaxed);
        }
    }

    fn note_seq(&self, step: SeqStep) {
        match step {
            SeqStep::Contiguous => {}
            SeqStep::Duplicate => {
                self.seq_duplicates.fetch_add(1, Ordering::Relaxed);
            }
            SeqStep::Regression => {
                self.seq_regressions.fetch_add(1, Ordering::Relaxed);
            }
            SeqStep::Gap { missing } => {
                self.seq_gaps.fetch_add(1, Ordering::Relaxed);
                self.seq_missing.fetch_add(missing, Ordering::Relaxed);
                metrics::counter!("buzz_audio_inbound_seq_gaps_total").increment(1);
            }
        }
    }

    /// A plain, consistent-enough read for a log line. Counters are read one
    /// at a time and a frame may land between reads; that is fine for a
    /// post-mortem and costs nothing on the frame path.
    pub fn snapshot(&self) -> PeerAudioSnapshot {
        PeerAudioSnapshot {
            frames_in: self.frames_in.load(Ordering::Relaxed),
            frames_in_refused: self.frames_in_refused.load(Ordering::Relaxed),
            frames_out: self.frames_out.load(Ordering::Relaxed),
            frames_out_dropped: self.frames_out_dropped.load(Ordering::Relaxed),
            seq_gaps: self.seq_gaps.load(Ordering::Relaxed),
            seq_missing: self.seq_missing.load(Ordering::Relaxed),
            seq_regressions: self.seq_regressions.load(Ordering::Relaxed),
            seq_duplicates: self.seq_duplicates.load(Ordering::Relaxed),
            gaps_over_100ms: self.gaps_over_100ms.load(Ordering::Relaxed),
            gaps_over_500ms: self.gaps_over_500ms.load(Ordering::Relaxed),
            gap_total_ms: self.gap_total_ms.load(Ordering::Relaxed),
            gap_worst_ms: self.gap_worst_ms.load(Ordering::Relaxed),
        }
    }
}

/// Cumulative counters for one peer, as of one instant.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PeerAudioSnapshot {
    /// Frames accepted from this peer and forwarded.
    pub frames_in: u64,
    /// Frames from this peer refused before fan-out.
    pub frames_in_refused: u64,
    /// Frames handed to this peer's outbound queue.
    pub frames_out: u64,
    /// Frames dropped because this peer's outbound queue was full.
    pub frames_out_dropped: u64,
    /// Discontinuities in this peer's inbound `seq`.
    pub seq_gaps: u64,
    /// Frames implied missing by those discontinuities.
    pub seq_missing: u64,
    /// Times the inbound `seq` went backwards.
    pub seq_regressions: u64,
    /// Inbound frames that repeated the previous `seq`.
    pub seq_duplicates: u64,
    /// Inter-arrival gaps of at least 100 ms.
    pub gaps_over_100ms: u64,
    /// Inter-arrival gaps of at least 500 ms.
    pub gaps_over_500ms: u64,
    /// Summed length of the gaps counted in `gaps_over_100ms`.
    pub gap_total_ms: u64,
    /// The single worst inter-arrival gap.
    pub gap_worst_ms: u64,
}

/// What one inbound `seq` did relative to the one before it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SeqStep {
    /// Exactly one more than the last.
    Contiguous,
    /// The same as the last.
    Duplicate,
    /// Backwards: reordering, or a sender that restarted its counter.
    Regression,
    /// Forwards by more than one; `missing` frames never arrived.
    Gap { missing: u64 },
}

/// Per-connection inbound state. Lives on the receive loop's stack, so it
/// needs no lock and no atomics — only the derived counters are shared.
#[derive(Debug, Default)]
pub struct InboundTracker {
    last_seq: Option<u16>,
    last_arrival: Option<Instant>,
}

impl InboundTracker {
    /// Record one accepted inbound frame, folding its sequence step and its
    /// distance from the previous frame into `stats`.
    pub fn observe(&mut self, stats: &PeerAudioStats, seq: u16, now: Instant) {
        if let Some(previous) = self.last_arrival {
            stats.note_gap(now.saturating_duration_since(previous));
        }
        self.last_arrival = Some(now);

        if let Some(last) = self.last_seq {
            stats.note_seq(classify_seq(last, seq));
        }
        // A regression replaces the reference rather than holding the old one:
        // a sender that restarted must not then report every later frame as a
        // fresh regression.
        self.last_seq = Some(seq);
    }
}

/// Classify `seq` against the frame before it, wrap-aware.
fn classify_seq(last: u16, seq: u16) -> SeqStep {
    let delta = seq.wrapping_sub(last);
    match delta {
        0 => SeqStep::Duplicate,
        1 => SeqStep::Contiguous,
        d if d >= SEQ_REGRESSION_FROM => SeqStep::Regression,
        d => SeqStep::Gap {
            missing: u64::from(d) - 1,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_contiguous_sequence_counts_nothing() {
        let stats = PeerAudioStats::default();
        let mut tracker = InboundTracker::default();
        let t0 = Instant::now();
        for (i, seq) in (100u16..=110).enumerate() {
            tracker.observe(&stats, seq, t0 + Duration::from_millis(20 * i as u64));
        }
        let s = stats.snapshot();
        assert_eq!(s.seq_gaps, 0, "no gaps");
        assert_eq!(s.seq_missing, 0, "nothing missing");
        assert_eq!(s.gaps_over_100ms, 0, "20 ms spacing is not a gap");
        assert_eq!(s.gap_worst_ms, 20, "worst gap is the frame interval");
    }

    #[test]
    fn a_jump_counts_one_gap_and_the_frames_it_skipped() {
        let stats = PeerAudioStats::default();
        let mut tracker = InboundTracker::default();
        let t0 = Instant::now();
        tracker.observe(&stats, 10, t0);
        tracker.observe(&stats, 15, t0 + Duration::from_millis(20));
        let s = stats.snapshot();
        assert_eq!(s.seq_gaps, 1, "one discontinuity");
        assert_eq!(s.seq_missing, 4, "11, 12, 13 and 14 never arrived");
        assert_eq!(s.seq_regressions, 0, "forwards is not a regression");
    }

    /// `seq` is a u16 that wraps about every 22 minutes. A wrap is ordinary
    /// continuity, and reading it as a 65535-frame gap would make every long
    /// call report a fault it did not have.
    #[test]
    fn a_wrap_is_continuity_not_a_sixty_five_thousand_frame_gap() {
        let stats = PeerAudioStats::default();
        let mut tracker = InboundTracker::default();
        let t0 = Instant::now();
        tracker.observe(&stats, u16::MAX, t0);
        tracker.observe(&stats, 0, t0 + Duration::from_millis(20));
        let s = stats.snapshot();
        assert_eq!(s.seq_gaps, 0, "65535 → 0 is the next frame");
        assert_eq!(s.seq_missing, 0);
        assert_eq!(s.seq_regressions, 0);
    }

    #[test]
    fn a_sequence_that_goes_backwards_is_a_regression_not_a_gap() {
        let stats = PeerAudioStats::default();
        let mut tracker = InboundTracker::default();
        let t0 = Instant::now();
        tracker.observe(&stats, 500, t0);
        tracker.observe(&stats, 400, t0 + Duration::from_millis(20));
        let s = stats.snapshot();
        assert_eq!(s.seq_regressions, 1, "backwards");
        assert_eq!(s.seq_gaps, 0, "and not counted as a forward gap");
        assert_eq!(s.seq_missing, 0);
    }

    /// The reference must move to the out-of-order frame. Holding the old one
    /// would report every subsequent frame as another regression.
    #[test]
    fn a_regression_does_not_cascade() {
        let stats = PeerAudioStats::default();
        let mut tracker = InboundTracker::default();
        let t0 = Instant::now();
        tracker.observe(&stats, 500, t0);
        tracker.observe(&stats, 400, t0 + Duration::from_millis(20));
        tracker.observe(&stats, 401, t0 + Duration::from_millis(40));
        tracker.observe(&stats, 402, t0 + Duration::from_millis(60));
        assert_eq!(
            stats.snapshot().seq_regressions,
            1,
            "one regression, not three"
        );
    }

    #[test]
    fn a_repeated_sequence_number_is_a_duplicate() {
        let stats = PeerAudioStats::default();
        let mut tracker = InboundTracker::default();
        let t0 = Instant::now();
        tracker.observe(&stats, 7, t0);
        tracker.observe(&stats, 7, t0 + Duration::from_millis(20));
        let s = stats.snapshot();
        assert_eq!(s.seq_duplicates, 1);
        assert_eq!(s.seq_gaps, 0);
        assert_eq!(s.seq_regressions, 0);
    }

    /// The threshold is the one the bridge injects silence at, so the two
    /// sides of a call can be compared without converting anything.
    #[test]
    fn a_gap_is_counted_with_its_length_only_past_a_hundred_milliseconds() {
        let stats = PeerAudioStats::default();
        let mut tracker = InboundTracker::default();
        let t0 = Instant::now();
        tracker.observe(&stats, 1, t0);
        tracker.observe(&stats, 2, t0 + Duration::from_millis(99));
        assert_eq!(stats.snapshot().gaps_over_100ms, 0, "99 ms is not a gap");
        tracker.observe(&stats, 3, t0 + Duration::from_millis(99 + 100));
        tracker.observe(&stats, 4, t0 + Duration::from_millis(99 + 100 + 700));
        let s = stats.snapshot();
        assert_eq!(s.gaps_over_100ms, 2, "100 ms and 700 ms");
        assert_eq!(s.gaps_over_500ms, 1, "only the 700 ms one is severe");
        assert_eq!(s.gap_total_ms, 800, "their summed length, not their count");
        assert_eq!(s.gap_worst_ms, 700);
    }

    /// The first frame of a connection has nothing to be late relative to.
    #[test]
    fn the_first_frame_is_never_a_gap() {
        let stats = PeerAudioStats::default();
        let mut tracker = InboundTracker::default();
        tracker.observe(&stats, 1, Instant::now());
        let s = stats.snapshot();
        assert_eq!(s.gaps_over_100ms, 0);
        assert_eq!(s.gap_worst_ms, 0);
        assert_eq!(s.seq_gaps, 0);
    }

    #[test]
    fn outbound_counts_what_was_delivered_and_what_was_dropped() {
        let stats = PeerAudioStats::default();
        stats.frame_out();
        stats.frame_out();
        stats.frame_out_dropped();
        let s = stats.snapshot();
        assert_eq!(s.frames_out, 2);
        assert_eq!(s.frames_out_dropped, 1);
    }
}
