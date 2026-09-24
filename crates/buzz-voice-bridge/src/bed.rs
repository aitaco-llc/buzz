//! The working sound: a loop laid under the room track while the seat is
//! thinking, so a wait sounds like work instead of a dead line.
//!
//! **The room track only. Never Gemini's input.** `call.rs` feeds Gemini
//! silence when the human is quiet, and that silence is what its
//! voice-activity detection reads as the end of a turn. A keyboard in there is
//! a keyboard it will answer.
//!
//! The two loops are rendered by `assets/make_earcons.py` from noise and sine
//! envelopes — no recording, no voice, nothing that is anyone's likeness. They
//! are stored as raw little-endian `i16` at [`crate::gemini::OUTPUT_RATE`], an
//! exact multiple of one Opus frame, so a wrap never leaves a partial frame
//! behind and swapping one for the other does not move the level.

use std::fmt;

/// Rendered by `assets/make_earcons.py`; 96000 samples = 4.000 s = 200 frames.
static TYPING: &[u8] = include_bytes!("../assets/working_typing.s16le");
static THINKING: &[u8] = include_bytes!("../assets/working_thinking.s16le");

/// Which loop plays under a wait, or none.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default, clap::ValueEnum)]
pub enum WorkingSound {
    /// Someone at a keyboard: bursts of keys, short pauses, the odd spacebar.
    #[default]
    Typing,
    /// The neutral alternative: sparse soft low blips, no keyboard imagery.
    Thinking,
    /// Silence, as before.
    Off,
}

impl fmt::Display for WorkingSound {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Typing => "typing",
            Self::Thinking => "thinking",
            Self::Off => "off",
        })
    }
}

impl WorkingSound {
    fn pcm(self) -> Option<&'static [u8]> {
        match self {
            Self::Typing => Some(TYPING),
            Self::Thinking => Some(THINKING),
            Self::Off => None,
        }
    }
}

/// A loop with a read cursor. Frames come out at the room's rate, gain applied
/// once here rather than per sample downstream.
pub struct Bed {
    samples: Vec<i16>,
    at: usize,
}

impl Bed {
    /// `None` when the sound is off or the gain silences it, so the caller's
    /// `Option` is the whole switch and there is no silent path that still
    /// costs an encode and a frame.
    pub fn new(sound: WorkingSound, gain: f32) -> Option<Self> {
        let raw = sound.pcm()?;
        // NaN included: a gain that is not a positive number is off.
        if !gain.is_finite() || gain <= 0.0 {
            return None;
        }
        let gain = gain.min(1.0);
        let samples: Vec<i16> = raw
            .chunks_exact(2)
            .map(|pair| {
                let sample = i16::from_le_bytes([pair[0], pair[1]]);
                (f32::from(sample) * gain).round().clamp(-32768.0, 32767.0) as i16
            })
            .collect();
        (!samples.is_empty()).then_some(Self { samples, at: 0 })
    }

    /// Fill one frame, wrapping at the loop's end. The loop length is a whole
    /// number of frames, so the wrap lands on a frame boundary and the seam
    /// measured in `assets/HANDOFF.md` is the only discontinuity.
    pub fn frame(&mut self, out: &mut [i16]) {
        for slot in out.iter_mut() {
            *slot = self.samples[self.at];
            self.at = (self.at + 1) % self.samples.len();
        }
    }

    /// Back to the head of the loop, so every wait starts the same way.
    pub fn rewind(&mut self) {
        self.at = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FRAME: usize = (crate::gemini::OUTPUT_RATE / 50) as usize;

    #[test]
    fn both_loops_are_a_whole_number_of_frames() {
        for sound in [WorkingSound::Typing, WorkingSound::Thinking] {
            let bytes = sound.pcm().expect("has pcm");
            assert_eq!(bytes.len() % 2, 0, "{sound}: not whole samples");
            let samples = bytes.len() / 2;
            assert_eq!(samples % FRAME, 0, "{sound}: {samples} is not whole frames");
            assert_eq!(samples, 96_000, "{sound}: expected 4.000 s at 24 kHz");
        }
    }

    #[test]
    fn off_and_zero_gain_produce_no_bed() {
        assert!(Bed::new(WorkingSound::Off, 1.0).is_none());
        assert!(Bed::new(WorkingSound::Typing, 0.0).is_none());
        assert!(Bed::new(WorkingSound::Typing, -1.0).is_none());
    }

    #[test]
    fn the_cursor_wraps_and_rewind_returns_to_the_head() {
        let mut bed = Bed::new(WorkingSound::Typing, 1.0).expect("bed");
        let head: Vec<i16> = {
            let mut frame = vec![0i16; FRAME];
            bed.frame(&mut frame);
            frame
        };
        // 200 frames to the loop; 199 more lands back on the head.
        let mut frame = vec![0i16; FRAME];
        for _ in 0..199 {
            bed.frame(&mut frame);
        }
        bed.frame(&mut frame);
        assert_eq!(frame, head, "the loop did not wrap onto its own head");

        bed.rewind();
        bed.frame(&mut frame);
        assert_eq!(frame, head, "rewind did not return to the head");
    }

    #[test]
    fn gain_scales_the_loop_without_clipping() {
        let full = Bed::new(WorkingSound::Typing, 1.0).expect("bed");
        let half = Bed::new(WorkingSound::Typing, 0.5).expect("bed");
        let peak = |bed: &Bed| bed.samples.iter().map(|s| s.unsigned_abs()).max().unwrap();
        assert!(peak(&half) < peak(&full), "gain did not lower the peak");
        assert!(
            peak(&half) * 2 >= peak(&full) - 2,
            "gain lost more than rounding"
        );
    }
}
