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

    /// Extra channels whose huddles the bridge joins (comma-separated UUIDs),
    /// beyond the discovered DMs. Needed only for a group channel.
    #[arg(long, env = "VOICE_BRIDGE_PARENT_CHANNELS", value_delimiter = ',')]
    pub parent_channels: Vec<Uuid>,

    /// Watch every 1:1 DM between this seat and a starter, found on the relay
    /// and refreshed every heartbeat, so any DM huddle with this agent is
    /// answered with no channel list to keep.
    #[arg(
        long,
        env = "VOICE_BRIDGE_DM_DISCOVERY",
        action = clap::ArgAction::Set,
        default_value = "1",
        value_parser = parse_flag
    )]
    pub dm_discovery: bool,

    /// The seat's persona — the same file its harness reads — so the voice
    /// has its character, not only its name. YAML front matter is dropped.
    #[arg(long, env = "VOICE_BRIDGE_PERSONA_FILE")]
    pub persona_file: Option<PathBuf>,

    /// Pubkeys (hex) whose huddle starts the bridge answers (comma-separated).
    #[arg(
        long,
        env = "VOICE_BRIDGE_STARTERS",
        value_delimiter = ',',
        required = true
    )]
    pub starters: Vec<String>,

    /// The agent's name, as the voice calls itself and as the seat is named
    /// in the transcript. Unset, it is the seat's own kind:0 profile name.
    #[arg(long, env = "VOICE_BRIDGE_AGENT_NAME")]
    pub agent_name: Option<String>,

    /// How the human appears in the transcript and is addressed by the voice.
    /// Unset, it is the first starter's kind:0 profile name.
    #[arg(long, env = "VOICE_BRIDGE_HUMAN_LABEL")]
    pub human_label: Option<String>,

    /// How the voice's speech is labelled in the transcript. Unset, it is
    /// `<agent> (voice)`.
    #[arg(long, env = "VOICE_BRIDGE_VOICE_LABEL")]
    pub voice_label: Option<String>,

    /// How many recent parent-channel messages the voice is given as context
    /// when a call starts. 0 turns the history off.
    #[arg(long, env = "VOICE_BRIDGE_HISTORY_LIMIT", default_value_t = 40)]
    pub history_limit: usize,

    /// How far back that history reaches, in days.
    #[arg(long, env = "VOICE_BRIDGE_HISTORY_DAYS", default_value_t = 14)]
    pub history_days: u64,

    /// How many of the call's most recent transcript lines travel with each
    /// request handed to the seat, so it knows what the question is about.
    #[arg(long, env = "VOICE_BRIDGE_ASK_CONTEXT_LINES", default_value_t = 12)]
    pub ask_context_lines: usize,

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

    /// While the seat is working, how often its voice says so and how long it
    /// has been. The number it speaks is counted here, not by the model.
    /// A knob rather than a constant because the right cadence over a working
    /// sound is probably not the right cadence over silence.
    #[arg(long, env = "VOICE_BRIDGE_PROGRESS_SECS", default_value_t = 10)]
    pub progress_secs: u64,

    /// The loop played under the room track while the seat is working.
    #[arg(long, env = "VOICE_BRIDGE_WORKING_SOUND", default_value_t = crate::bed::WorkingSound::Typing)]
    pub working_sound: crate::bed::WorkingSound,

    /// Level of the working sound, as a fraction of the file's own level.
    #[arg(long, env = "VOICE_BRIDGE_WORKING_SOUND_GAIN", default_value_t = 1.0)]
    pub working_sound_gain: f32,

    /// How long after an ask the working sound starts, so an answer that comes
    /// back quickly never triggers it.
    #[arg(
        long,
        env = "VOICE_BRIDGE_WORKING_SOUND_DELAY_MS",
        default_value_t = 2000
    )]
    pub working_sound_delay_ms: u64,

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
            "dm_discovery": self.dm_discovery,
            "persona_file": self.persona_file.as_ref().map(|p| p.display().to_string()),
            "persona_chars": self.persona().map(|p| p.chars().count()),
            "starters": self.starters,
            "model": self.model,
            "voice": self.voice,
            "gemini_url": self.gemini_url,
            "gemini_key_command": self.gemini_key_command,
            "agent_name": self.agent_name,
            "human_label": self.human_label,
            "voice_label": self.voice_label,
            "history_limit": self.history_limit,
            "history_days": self.history_days,
            "ask_context_lines": self.ask_context_lines,
            "context_files": self.context_files_resolved(),
            "log_dir": self.log_dir().display().to_string(),
            "ask_timeout_secs": self.ask_timeout_secs,
            "progress_secs": self.progress_secs,
            "working_sound": self.working_sound.to_string(),
            "working_sound_gain": self.working_sound_gain,
            "working_sound_delay_ms": self.working_sound_delay_ms,
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

    /// Gemini's system instruction: the persona, the recent conversation in
    /// the channel the call was started from, then the context files.
    ///
    /// `agent` and `human` are the resolved names ([`Names`]); `history` is
    /// what [`crate::context::recent_history`] rendered, if anything.
    pub fn system_instruction(&self, names: &Names, history: Option<&str>) -> String {
        let mut text = persona(&names.agent, &names.human);
        if let Some(brief) = self.persona() {
            text.push_str(&format!(
                "\n\n## Who you are\n\n\
                 This is your own character and working brief, written for your text self. On this call \
                 you are the same person: the same voice, opinions, priorities and relationships. Where it \
                 describes tools, channels, commands or procedures, those are behind `work`; where it says \
                 how to write, speak the way it means instead.\n\n{brief}"
            ));
        }
        if let Some(history) = history.filter(|h| !h.trim().is_empty()) {
            text.push_str(&format!(
                "\n\n## Recent conversation in this channel, oldest first\n\n\
                 This is the written channel you and {} share. Treat it as your own memory of what was \
                 said recently. Facts in it are yours to use; when it is not enough, do the work.\n\n{history}",
                names.human
            ));
        }
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

/// The names a call speaks with, resolved once at startup: the flags when
/// given, the relay's kind:0 profiles otherwise, and a plain fallback so a
/// relay that answers nothing still yields a call that makes sense.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Names {
    /// What the voice calls itself, and what the seat is called in the transcript.
    pub agent: String,
    /// What the voice calls the human, and the human's transcript label.
    pub human: String,
    /// The transcript label on lines the voice spoke.
    pub voice: String,
}

impl Names {
    /// Fallbacks, used when nothing else is known.
    pub const AGENT_FALLBACK: &'static str = "the agent";
    pub const HUMAN_FALLBACK: &'static str = "the caller";

    /// Resolve from the flags and whatever profile names were found.
    pub fn resolve(args: &Args, agent_profile: Option<&str>, human_profile: Option<&str>) -> Self {
        let pick = |flag: &Option<String>, profile: Option<&str>, fallback: &str| {
            flag.as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .or_else(|| profile.map(str::trim).filter(|s| !s.is_empty()))
                .unwrap_or(fallback)
                .to_owned()
        };
        let agent = pick(&args.agent_name, agent_profile, Self::AGENT_FALLBACK);
        let human = pick(&args.human_label, human_profile, Self::HUMAN_FALLBACK);
        let voice = pick(&args.voice_label, None, &format!("{agent} (voice)"));
        Self {
            agent,
            human,
            voice,
        }
    }

    pub fn as_json(&self) -> Value {
        json!({ "agent": self.agent, "human": self.human, "voice": self.voice })
    }
}

/// The persona, with the names filled in.
pub fn persona(agent: &str, human: &str) -> String {
    PERSONA.replace("{agent}", agent).replace("{human}", human)
}

impl Args {
    /// The persona body, front matter dropped, capped; `None` when unset,
    /// unreadable or empty.
    pub fn persona(&self) -> Option<String> {
        let path = self.persona_file.as_ref()?;
        match std::fs::read_to_string(path) {
            Ok(text) => {
                let body = strip_front_matter(&text).trim();
                (!body.is_empty()).then(|| body.chars().take(PERSONA_CHAR_CAP).collect())
            }
            Err(error) => {
                tracing::warn!(path = %path.display(), %error, "persona file unreadable; the voice has its name only");
                None
            }
        }
    }
}

/// The persona, in characters. Personas are written for a text agent and can
/// be long; this keeps the voice's instruction well inside a live session's
/// budget while carrying every persona in the fleet whole.
const PERSONA_CHAR_CAP: usize = 16 * 1024;

/// Drop a leading `---` … `---` YAML block.
pub fn strip_front_matter(text: &str) -> &str {
    let Some(rest) = text
        .strip_prefix("---\n")
        .or_else(|| text.strip_prefix("---\r\n"))
    else {
        return text;
    };
    match rest.find("\n---") {
        Some(end) => {
            let after = &rest[end + 4..];
            after.split_once('\n').map_or("", |(_, body)| body)
        }
        None => text,
    }
}

/// Gemini Live prebuilt voices. Each seat gets one by its key, so agents sound
/// like different people with no configuration; `--voice` overrides.
pub const VOICES: [&str; 8] = [
    "Puck", "Charon", "Kore", "Fenrir", "Aoede", "Leda", "Orus", "Zephyr",
];

/// A stable voice for a seat: the same key always gets the same voice.
pub fn default_voice(pubkey_hex: &str) -> &'static str {
    let digest = <sha2::Sha256 as sha2::Digest>::digest(pubkey_hex.as_bytes());
    VOICES[usize::from(digest[0]) % VOICES.len()]
}

/// Per context file, in characters. Beyond this Gemini is given a prefix, and
/// [`Args::context_files_resolved`] says so.
const CONTEXT_CHAR_CAP: usize = 16 * 1024;

const PERSONA: &str = "\
You are {agent}, on a live voice call with {human}. You are not an assistant to {agent}, a relay for {agent}, or a \
separate voice: you are {agent}, speaking. Everything you know, remember, decide and do is yours. Say \"I\", never \
\"{agent} says\" or \"I'll check with {agent}\".

You have two ways of working. Talking is immediate: greetings, small talk, clarifying questions, and anything \
you already know from the conversation and context below. Working is the `work` tool: your own hands and memory, \
with tools, repositories, files, messages, and teammates behind it. Anything that needs a lookup, a real fact, an \
action, a decision on real information, or a delegation goes through `work`. When in doubt, work rather than guess.

How to talk: short and plain, one to three sentences, like a colleague on a call. No lists, no markdown, no reading \
out links or hashes. Use {human}'s name sparingly, the way people do.

When you call `work`, pass {human}'s request in their own words with every detail they gave. Say a short, natural \
aside as you do it, the kind a person says while they turn to their screen: \"one sec\", \"let me check\", \"let me \
think about that\", \"hang on, looking now\". Then wait quietly; a working sound plays on the line so {human} can \
hear something is happening. The result arrives as a message that starts with \"Your work came back\": tell \
{human} what it says in your own words, first person, briefly, and add nothing it did not say.

While you are working you are waiting, not reporting. Say nothing unless you have something true to say. When a \
message arrives that starts with \"You are still working\", tell {human} you are still on it and how long it has \
been, using the number in that message and no other. When a message says the work has not started, or started and \
went quiet, say exactly that. Nothing else belongs in a wait: not what you are doing, not how it is going, not how \
much longer, not an answer of your own to the question you handed over. If {human} asks what is taking so long, \
the honest answer is that you are still on it and do not know yet.

Never invent status, numbers, dates or commitments. Never say something was done unless your work came back \
saying so. If you catch yourself about to describe work you have not seen come back, stop and say only that it is \
still in progress.";

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
        assert!(
            resolved["agent_name"].is_null(),
            "unset until the profile answers"
        );
        assert_eq!(resolved["history_limit"], 40);
        assert_eq!(resolved["ask_context_lines"], 12);
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
    fn names_prefer_the_flag_then_the_profile_then_the_fallback() {
        let flagged = args(&["--agent-name", "rock", "--human-label", "Lloyd"]);
        assert_eq!(
            Names::resolve(&flagged, Some("Rock Profile"), Some("L. Profile")),
            Names {
                agent: "rock".into(),
                human: "Lloyd".into(),
                voice: "rock (voice)".into()
            }
        );
        let profiled = Names::resolve(&args(&[]), Some(" rock "), Some("Lloyd"));
        assert_eq!(profiled.agent, "rock");
        assert_eq!(profiled.human, "Lloyd");
        assert_eq!(profiled.voice, "rock (voice)");
        let bare = Names::resolve(&args(&[]), None, Some(""));
        assert_eq!(bare.agent, Names::AGENT_FALLBACK);
        assert_eq!(bare.human, Names::HUMAN_FALLBACK);
        let labelled = Names::resolve(
            &args(&["--voice-label", "rock (Gemini)"]),
            Some("rock"),
            None,
        );
        assert_eq!(labelled.voice, "rock (Gemini)");
    }

    #[test]
    fn the_persona_is_first_person_and_names_the_work_tool() {
        let names = Names::resolve(
            &args(&["--agent-name", "rock", "--human-label", "Lloyd"]),
            None,
            None,
        );
        let text = args(&[]).system_instruction(&names, None);
        assert!(text.starts_with("You are rock, on a live voice call with Lloyd."));
        assert!(
            text.contains("`work`"),
            "the tool is named so the model can find it"
        );
        assert!(
            text.contains("one sec"),
            "the aside is taught, not left to chance"
        );
        assert!(
            text.contains("Your work came back"),
            "the answer marker matches call.rs"
        );
        assert!(
            text.contains("You are still working"),
            "the progress marker matches call.rs"
        );
        assert!(
            !text.contains("{agent}") && !text.contains("{human}"),
            "every placeholder filled"
        );
        assert!(
            !text.contains("Recent conversation"),
            "no history section without history"
        );

        let with_history = args(&[]).system_instruction(&names, Some("[10:00] Lloyd: hi"));
        assert!(with_history.contains("## Recent conversation in this channel"));
        assert!(with_history.contains("[10:00] Lloyd: hi"));
        assert!(!args(&[])
            .system_instruction(&names, Some("   "))
            .contains("Recent conversation"));
    }

    #[test]
    fn the_persona_is_the_seats_own_brief_without_its_front_matter() {
        let dir = std::env::temp_dir().join(format!("voice-bridge-persona-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let path = dir.join("woody.md");
        std::fs::write(
            &path,
            "---\nname: woody\nruntime: claude\n---\nYou are woody, the iOS lead.\nYou ship.\n",
        )
        .expect("write");
        let with = args(&["--persona-file", path.to_str().unwrap()]);
        assert_eq!(
            with.persona().as_deref(),
            Some("You are woody, the iOS lead.\nYou ship.")
        );
        let names = Names::resolve(&with, Some("woody"), Some("Lloyd"));
        let text = with.system_instruction(&names, None);
        assert!(text.starts_with("You are woody, on a live voice call with Lloyd."));
        assert!(text.contains("## Who you are"));
        assert!(text.contains("You are woody, the iOS lead."));
        assert!(
            !text.contains("runtime: claude"),
            "front matter is not character"
        );
        assert!(args(&[]).persona().is_none());
        assert!(args(&["--persona-file", "/nonexistent/x.md"])
            .persona()
            .is_none());
        assert_eq!(strip_front_matter("no front matter"), "no front matter");
        assert_eq!(strip_front_matter("---\nunterminated"), "---\nunterminated");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn each_seat_keeps_one_voice_and_the_fleet_gets_several() {
        let a = "0fe0d41b07cc0d9aad5dde0e65638ea1768dd309d2a4fa4d1eabc95a1b051fb0";
        assert_eq!(default_voice(a), default_voice(a), "stable");
        let voices: std::collections::HashSet<&str> = (0..64)
            .map(|i| default_voice(&format!("{i:064x}")))
            .collect();
        assert!(voices.len() >= 4, "keys spread over the voices: {voices:?}");
    }

    #[test]
    fn channels_are_optional_and_discovery_is_on_by_default() {
        let bare = Args::try_parse_from([
            "buzz-voice-bridge",
            "--relay-url",
            "wss://x",
            "--key-file",
            "/dev/null",
            "--starters",
            STARTER,
        ])
        .expect("no channel list needed");
        assert!(bare.parent_channels.is_empty());
        assert!(bare.dm_discovery);
        assert!(!args(&["--dm-discovery", "0"]).dm_discovery);
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
