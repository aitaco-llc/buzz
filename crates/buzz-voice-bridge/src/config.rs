//! Command-line and environment configuration.

use anyhow::{bail, Context, Result};
use clap::Parser;
use std::path::PathBuf;
use uuid::Uuid;

#[derive(Debug, Clone, Parser)]
#[command(
    name = "buzz-voice-bridge",
    about = "Join a Buzz huddle as a seat's voice and run a Gemini Live conversation"
)]
pub struct Args {
    /// Relay WebSocket URL.
    #[arg(long, env = "BUZZ_RELAY_URL")]
    pub relay_url: String,

    /// Env file that holds the seat's BUZZ_PRIVATE_KEY. Point this at the file
    /// the seat itself reads; the bridge keeps no copy of the key.
    #[arg(long, env = "VOICE_BRIDGE_KEY_FILE")]
    pub key_file: PathBuf,

    /// Parent channels whose huddles the bridge joins (comma-separated UUIDs).
    #[arg(
        long,
        env = "VOICE_BRIDGE_PARENT_CHANNELS",
        value_delimiter = ',',
        required = true
    )]
    pub parent_channels: Vec<Uuid>,

    /// Pubkeys (hex) whose huddle starts the bridge answers (comma-separated).
    #[arg(
        long,
        env = "VOICE_BRIDGE_STARTERS",
        value_delimiter = ',',
        required = true
    )]
    pub starters: Vec<String>,

    /// How the human appears in the transcript.
    #[arg(long, env = "VOICE_BRIDGE_HUMAN_LABEL", default_value = "Lloyd")]
    pub human_label: String,

    /// How Gemini's speech appears in the transcript.
    #[arg(
        long,
        env = "VOICE_BRIDGE_VOICE_LABEL",
        default_value = "rock (voice, Gemini)"
    )]
    pub voice_label: String,

    /// Gemini Live model.
    #[arg(long, env = "VOICE_BRIDGE_MODEL", default_value = "gemini-3.8-live")]
    pub model: String,

    /// Prebuilt Gemini voice name; the model default when unset.
    #[arg(long, env = "VOICE_BRIDGE_VOICE")]
    pub voice: Option<String>,

    /// Gemini Live WebSocket URL (overridable for tests).
    #[arg(long, env = "VOICE_BRIDGE_GEMINI_URL", default_value = crate::gemini::DEFAULT_URL)]
    pub gemini_url: String,

    /// Command that prints the Gemini API key on stdout. Used when
    /// GEMINI_API_KEY is not set.
    #[arg(
        long,
        env = "VOICE_BRIDGE_GEMINI_KEY_COMMAND",
        default_value = "gcloud secrets versions access latest --secret gemini-live-api-key --project aitaco-ml-dev"
    )]
    pub gemini_key_command: String,

    /// Files appended to Gemini's system instruction as context, 16 KiB each
    /// at most (comma-separated paths).
    #[arg(long, env = "VOICE_BRIDGE_CONTEXT_FILES", value_delimiter = ',')]
    pub context_files: Vec<PathBuf>,

    /// Where each call's JSONL log is written.
    #[arg(long, env = "VOICE_BRIDGE_LOG_DIR")]
    pub log_dir: Option<PathBuf>,

    /// How long to wait for the seat's answer to one ask.
    #[arg(long, env = "VOICE_BRIDGE_ASK_TIMEOUT_SECS", default_value_t = 900)]
    pub ask_timeout_secs: u64,
}

impl Args {
    pub fn validate(&mut self) -> Result<()> {
        for starter in &mut self.starters {
            *starter = starter.trim().to_ascii_lowercase();
            if starter.len() != 64 || !starter.bytes().all(|b| b.is_ascii_hexdigit()) {
                bail!("starter {starter:?} is not a 64-char hex pubkey");
            }
        }
        if !(self.relay_url.starts_with("ws://") || self.relay_url.starts_with("wss://")) {
            bail!("relay URL must be ws:// or wss://");
        }
        Ok(())
    }

    pub fn log_dir(&self) -> PathBuf {
        self.log_dir.clone().unwrap_or_else(|| {
            let home = std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_default();
            home.join(".local/state/buzz-voice-bridge")
        })
    }

    /// The Gemini key: `GEMINI_API_KEY` when set, else the key command's output.
    pub fn gemini_api_key(&self) -> Result<String> {
        if let Ok(key) = std::env::var("GEMINI_API_KEY") {
            if !key.trim().is_empty() {
                return Ok(key.trim().to_owned());
            }
        }
        let output = std::process::Command::new("sh")
            .arg("-c")
            .arg(&self.gemini_key_command)
            .stderr(std::process::Stdio::null())
            .output()
            .context("run the Gemini key command")?;
        if !output.status.success() {
            bail!("the Gemini key command exited with {}", output.status);
        }
        let key = String::from_utf8(output.stdout).context("key is not UTF-8")?;
        let key = key.trim();
        if key.is_empty() {
            bail!("the Gemini key command printed nothing");
        }
        Ok(key.to_owned())
    }

    /// Gemini's system instruction: the persona plus the context files.
    pub fn system_instruction(&self) -> String {
        let mut text = PERSONA.replace("{human}", &self.human_label);
        for path in &self.context_files {
            match std::fs::read_to_string(path) {
                Ok(content) => {
                    let capped: String = content.chars().take(16 * 1024).collect();
                    text.push_str(&format!(
                        "\n\n## Context: {}\n\n{capped}",
                        path.file_name().and_then(|n| n.to_str()).unwrap_or("file")
                    ));
                }
                Err(error) => {
                    tracing::warn!(path = %path.display(), %error, "context file unreadable; skipped")
                }
            }
        }
        text
    }
}

const PERSONA: &str = "\
You are rock's voice in a live voice call with {human}. rock is the chief of staff of {human}'s AI team at aitaco. \
You speak for rock, but you are not the one who decides or acts: rock, a Claude seat with tools, repositories, memory \
and the rest of the team, does that.

How to talk: short and plain, one to three sentences, like a colleague on a call. No lists, no markdown, no reading \
out links or hashes.

What you answer yourself: greetings, small talk, clarifying questions, and facts that appear in the context below.

What you hand to rock: anything that needs a lookup, a decision, an action, a delegation, or anything you are not \
sure of. Call ask_rock with {human}'s request in his own words and every detail he gave, then tell him briefly that \
you are checking with rock. Keep talking with him while rock works. When a message arrives that starts with \
\"rock answered\", tell {human} the answer in your own words, briefly.

Never invent status, numbers, dates or commitments. Never say something was done unless rock's answer says so.";
