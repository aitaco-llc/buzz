//! buzz-voice-bridge: a seat's voice in a Buzz huddle. The binary is
//! `src/main.rs`; the modules are public so the lab tools in `examples/` can
//! speak the same wire protocol.

pub mod call;
pub mod config;
pub mod gemini;
pub mod relay_io;
pub mod room;
pub mod transcript;
pub mod wire;
