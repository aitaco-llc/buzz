//! buzz-voice-bridge: a seat's voice in a Buzz huddle. The binary is
//! `src/main.rs`; the modules are public so the lab tools in `examples/` can
//! speak the same wire protocol.
//!
//! **Audio is never written to disk.** The bridge logs what it did with the
//! audio — frames, samples, decode errors, latencies — and the transcript
//! Gemini returns, never the audio itself. The per-call logs hold every word
//! spoken on the call in plaintext, so they expire (`--retention-days`,
//! 30 by default); `bridge.jsonl`, which holds no speech, is kept.

pub mod bed;
pub mod call;
pub mod config;
pub mod context;
pub mod discovery;
pub mod gemini;
pub mod jsonl;
pub mod outcome;
pub mod recovery;
pub mod relay_io;
pub mod room;
pub mod transcript;
pub mod wire;

/// The commit this binary was built from, stamped by `build.rs`.
pub const BUILD_SHA: &str = env!("BUILD_SHA");

/// What `--version` prints, and what every log's `build_sha` carries.
pub const VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "+", env!("BUILD_SHA"));
