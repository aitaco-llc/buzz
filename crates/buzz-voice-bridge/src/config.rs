//! Command-line and environment configuration.

use anyhow::{bail, Context, Result};
use clap::Parser;
use serde_json::{json, Value};
use std::path::PathBuf;
use uuid::Uuid;

#[derive(Debug, Clone, Parser)]
#[command(
    name = "buzz-voice-bridge",
    version = crate::VERSION,
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

    /// How often the watcher proves its huddle subscription is still live, by
    /// running a REQ to EOSE on the same socket.
    #[arg(long, env = "VOICE_BRIDGE_HEARTBEAT_SECS", default_value_t = 60)]
    pub heartbeat_secs: u64,

    /// How long a call's JSONL log is kept. Call logs hold every word spoken,
    /// so they expire; `bridge.jsonl` holds no speech and is kept.
    #[arg(long, env = "VOICE_BRIDGE_RETENTION_DAYS", default_value_t = 30)]
    pub retention_days: u64,

    /// Write every Gemini server message to a per-call sidecar, with the audio
    /// elided. Off by default: it is a debugging tool, not an artifact.
    #[arg(
        long,
        env = "VOICE_BRIDGE_TRACE_FRAMES",
        action = clap::ArgAction::Set,
        default_value = "0",
        value_parser = parse_flag
    )]
    pub trace_frames: bool,
}

/// `1`/`true`/`yes`/`on` and their opposites, so an env var can carry a flag.
fn parse_flag(value: &str) -> Result<bool, String> {
    match value.trim().to_ascii_lowercase().as_str() {
        "" | "0" | "false" | "no" | "off" => Ok(false),
        "1" | "true" | "yes" | "on" => Ok(true),
        other => Err(format!("expected 0 or 1, got {other:?}")),
    }
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

    /// Everything that shapes a call, as it was actually resolved. Recorded on
    /// `up` and again on every `call_start`, so a log explains itself without
    /// anyone having to guess at the unit file that produced it. No secret is
    /// included: the key command is named, never its output.
    pub fn resolved(&self) -> Value {
        json!({
            "relay_url": self.relay_url,
            "key_file": self.key_file.display().to_string(),
            "parent_channels": self.parent_channels,
            "starters": self.starters,
            "model": self.model,
            "voice": self.voice,
            "gemini_url": self.gemini_url,
            "gemini_key_command": self.gemini_key_command,
            "human_label": self.human_label,
            "voice_label": self.voice_label,
            "context_files": self.context_files_resolved(),
            "log_dir": self.log_dir().display().to_string(),
            "ask_timeout_secs": self.ask_timeout_secs,
            "heartbeat_secs": self.heartbeat_secs,
            "retention_days": self.retention_days,
            "trace_frames": self.trace_frames,
        })
    }

    /// Each context file with the size Gemini was actually given: a file that
    /// vanished, or one truncated by the 16 KiB cap, changes what the voice
    /// knows and must be visible in the log.
    pub fn context_files_resolved(&self) -> Vec<Value> {
        self.context_files
            .iter()
            .map(|path| match std::fs::read_to_string(path) {
                Ok(content) => {
                    let chars = content.chars().count();
                    json!({
                        "path": path.display().to_string(),
                        "bytes": content.len(),
                        "truncated_at_chars": (chars > CONTEXT_CHAR_CAP).then_some(CONTEXT_CHAR_CAP),
                    })
                }
                Err(error) => json!({
                    "path": path.display().to_string(),
                    "error": error.to_string(),
                }),
            })
            .collect()
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
                    let capped: String = content.chars().take(CONTEXT_CHAR_CAP).collect();
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

/// Per context file, in characters. Beyond this Gemini is given a prefix, and
/// [`Args::context_files_resolved`] says so.
const CONTEXT_CHAR_CAP: usize = 16 * 1024;

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

#[cfg(test)]
mod tests {
    use super::*;

    const STARTER: &str = "0f8471300f7806058507999b06f16805168c640aad3ffa5474cf8ec9e7c6a0ca";
    const PARENT: &str = "daa0371a-17fc-41a8-bb70-272b7c7e8be0";

    fn args(extra: &[&str]) -> Args {
        let mut argv = vec![
            "buzz-voice-bridge",
            "--relay-url",
            "wss://buzz.aitaco.co",
            "--key-file",
            "/dev/null",
            "--parent-channels",
            PARENT,
            "--starters",
            STARTER,
        ];
        argv.extend_from_slice(extra);
        Args::try_parse_from(argv).expect("parse")
    }

    #[test]
    fn the_trace_flag_takes_the_shapes_an_env_var_carries() {
        assert!(!args(&[]).trace_frames, "off unless asked for");
        assert!(args(&["--trace-frames", "1"]).trace_frames);
        assert!(args(&["--trace-frames", "true"]).trace_frames);
        assert!(!args(&["--trace-frames", "0"]).trace_frames);
        assert_eq!(parse_flag("Yes"), Ok(true));
        assert!(parse_flag("maybe").is_err());
    }

    #[test]
    fn the_resolved_config_carries_what_shapes_a_call_and_no_secret() {
        let resolved = args(&["--voice", "Charon"]).resolved();
        assert_eq!(resolved["relay_url"], "wss://buzz.aitaco.co");
        assert_eq!(resolved["parent_channels"][0], PARENT);
        assert_eq!(resolved["starters"][0], STARTER);
        assert_eq!(resolved["voice"], "Charon");
        assert_eq!(resolved["ask_timeout_secs"], 900);
        assert_eq!(resolved["heartbeat_secs"], 60);
        assert_eq!(resolved["retention_days"], 30);
        assert_eq!(resolved["trace_frames"], false);
        // The key command is named so a bad key is diagnosable; its output,
        // which is the key itself, is never in the log.
        assert!(resolved["gemini_key_command"]
            .as_str()
            .is_some_and(|command| command.contains("gemini-live-api-key")));
        assert!(resolved.get("gemini_key").is_none());
    }

    #[test]
    fn context_files_report_their_size_their_truncation_and_their_absence() {
        let dir = std::env::temp_dir().join(format!("voice-bridge-context-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let small = dir.join("roster.md");
        let big = dir.join("big.md");
        std::fs::write(&small, "# roster\n").expect("write");
        std::fs::write(&big, "x".repeat(CONTEXT_CHAR_CAP + 10)).expect("write");
        let missing = dir.join("gone.md");

        let files = args(&[
            "--context-files",
            &format!(
                "{},{},{}",
                small.display(),
                big.display(),
                missing.display()
            ),
        ])
        .context_files_resolved();

        assert_eq!(files[0]["bytes"], 9);
        assert!(files[0]["truncated_at_chars"].is_null());
        assert_eq!(files[1]["truncated_at_chars"], CONTEXT_CHAR_CAP);
        assert!(files[2]["error"].as_str().is_some_and(|e| !e.is_empty()));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
