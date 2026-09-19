//! Turns Gemini's streaming transcription fragments into speaker-labelled lines.
//!
//! Gemini sends input transcription (what the human said) and output
//! transcription (what the model said) as fragments. A human line is complete
//! when the model starts answering or the turn ends; a model line is complete
//! at `turnComplete`, or cut short by `interrupted`.

use chrono::{DateTime, Utc};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Speaker {
    /// The person in the huddle.
    Human,
    /// Gemini, speaking with the bridge's identity.
    Voice,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    pub speaker: Speaker,
    pub text: String,
    pub interrupted: bool,
    pub at: DateTime<Utc>,
}

#[derive(Debug)]
pub struct Transcript {
    human_label: String,
    voice_label: String,
    pending_human: String,
    pending_voice: String,
    lines: Vec<Line>,
}

impl Transcript {
    pub fn new(human_label: impl Into<String>, voice_label: impl Into<String>) -> Self {
        Self {
            human_label: human_label.into(),
            voice_label: voice_label.into(),
            pending_human: String::new(),
            pending_voice: String::new(),
            lines: Vec::new(),
        }
    }

    /// A fragment of what the human said.
    pub fn human(&mut self, fragment: &str) {
        self.pending_human.push_str(fragment);
    }

    /// A fragment of what the model said. The human's pending words are a
    /// complete line once the model starts answering.
    pub fn voice(&mut self, fragment: &str) -> Vec<Line> {
        let done = self.flush(Speaker::Human, false).into_iter().collect();
        self.pending_voice.push_str(fragment);
        done
    }

    /// The model finished its turn.
    pub fn turn_complete(&mut self) -> Vec<Line> {
        [
            self.flush(Speaker::Human, false),
            self.flush(Speaker::Voice, false),
        ]
        .into_iter()
        .flatten()
        .collect()
    }

    /// The human spoke over the model; its line ends where it was cut.
    pub fn interrupted(&mut self) -> Vec<Line> {
        self.flush(Speaker::Voice, true).into_iter().collect()
    }

    /// Everything still pending, at the end of the call.
    pub fn finish(&mut self) -> Vec<Line> {
        [
            self.flush(Speaker::Human, false),
            self.flush(Speaker::Voice, true),
        ]
        .into_iter()
        .flatten()
        .collect()
    }

    pub fn render(&self, line: &Line) -> String {
        let label = match line.speaker {
            Speaker::Human => &self.human_label,
            Speaker::Voice => &self.voice_label,
        };
        let cut = if line.interrupted {
            " …(interrupted)"
        } else {
            ""
        };
        format!("{label}: {}{cut}", line.text)
    }

    /// The whole call, one line per utterance, with UTC times.
    pub fn full_text(&self) -> String {
        self.lines
            .iter()
            .map(|line| format!("[{}] {}", line.at.format("%H:%M:%S"), self.render(line)))
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn is_empty(&self) -> bool {
        self.lines.is_empty()
    }

    fn flush(&mut self, speaker: Speaker, interrupted: bool) -> Option<Line> {
        let pending = match speaker {
            Speaker::Human => &mut self.pending_human,
            Speaker::Voice => &mut self.pending_voice,
        };
        let text = normalize(pending);
        pending.clear();
        if text.is_empty() {
            return None;
        }
        let line = Line {
            speaker,
            text,
            interrupted: interrupted && speaker == Speaker::Voice,
            at: Utc::now(),
        };
        self.lines.push(line.clone());
        Some(line)
    }
}

/// Collapse whitespace runs; transcription fragments carry their own spacing.
fn normalize(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(lines: &[Line]) -> Vec<(Speaker, String, bool)> {
        lines
            .iter()
            .map(|l| (l.speaker, l.text.clone(), l.interrupted))
            .collect()
    }

    #[test]
    fn human_line_closes_when_the_model_starts() {
        let mut t = Transcript::new("Lloyd", "rock (voice)");
        t.human(" what's the");
        t.human(" status ");
        let done = t.voice("Checking");
        assert_eq!(
            texts(&done),
            vec![(Speaker::Human, "what's the status".into(), false)]
        );
        assert!(t.voice(" with rock.").is_empty());
        let done = t.turn_complete();
        assert_eq!(
            texts(&done),
            vec![(Speaker::Voice, "Checking with rock.".into(), false)]
        );
        assert_eq!(t.lines.len(), 2);
    }

    #[test]
    fn barge_in_marks_the_cut_line() {
        let mut t = Transcript::new("Lloyd", "rock (voice)");
        t.voice("The build is");
        let done = t.interrupted();
        assert_eq!(
            texts(&done),
            vec![(Speaker::Voice, "The build is".into(), true)]
        );
        assert_eq!(
            t.render(&done[0]),
            "rock (voice): The build is …(interrupted)"
        );
    }

    #[test]
    fn empty_fragments_make_no_lines() {
        let mut t = Transcript::new("Lloyd", "rock (voice)");
        t.human("   ");
        assert!(t.turn_complete().is_empty());
        assert!(t.is_empty());
    }

    #[test]
    fn full_text_labels_every_line() {
        let mut t = Transcript::new("Lloyd", "rock (voice)");
        t.human("hi");
        t.voice("hello");
        t.turn_complete();
        let text = t.full_text();
        assert!(text.contains("] Lloyd: hi"));
        assert!(text.contains("] rock (voice): hello"));
    }
}
