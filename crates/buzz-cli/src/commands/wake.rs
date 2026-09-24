//! `buzz wake`: wake yourself when background work finishes.
//!
//! A seat is purely reactive — it runs only when a relay event is handed to
//! it — so a bench, a CI run or a long build it starts finishes into silence.
//! `buzz wake` closes that loop. It optionally runs a command to completion,
//! then posts one message signed with the seat's own key, addressed to the
//! seat, carrying a self-wake tag (`job=done` by default). A seat whose
//! harness runs with `BUZZ_ACP_SELF_WAKE_TAG` listing that tag is woken by it
//! with the result in hand; every other self-authored post is still ignored.
//!
//! ```text
//! nohup buzz wake --channel <uuid> --reply-to <event> -- ./bench.sh >/dev/null 2>&1 &
//! nohup buzz wake --channel <uuid> -- gh pr checks 78 --repo o/r --watch >/dev/null 2>&1 &
//! buzz wake --channel <uuid> --content "the nightly export finished"
//! ```
//!
//! The command's output is echoed to stderr as it arrives and only its last
//! lines are kept for the message, so a noisy job cannot grow the post or the
//! process without bound. stdout carries only the JSON write result.

use std::collections::VecDeque;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::io::{AsyncBufReadExt, AsyncRead, BufReader};

use crate::client::{normalize_write_response, BuzzClient};
use crate::error::CliError;
use crate::validate::{parse_uuid, read_or_stdin, validate_hex64};

/// Lines of output kept for the message.
const TAIL_LINES: usize = 30;
/// Characters kept per line; a minified blob is one enormous line.
const LINE_CHAR_CAP: usize = 300;

#[derive(clap::Args)]
pub struct WakeArgs {
    /// Channel the wake is posted to — normally the channel the work was asked in.
    #[arg(long)]
    pub channel: String,
    /// Event to thread the wake under — normally the request the work answers.
    #[arg(long)]
    pub reply_to: Option<String>,
    /// A note to include (`-` reads stdin).
    #[arg(long)]
    pub content: Option<String>,
    /// The self-wake tag, `name=value`; it must be listed in the seat's
    /// `BUZZ_ACP_SELF_WAKE_TAG` or the post wakes nothing.
    #[arg(long, default_value = "job=done")]
    pub tag: String,
    /// Give up on the command after this many seconds (it is killed, and the
    /// wake says so). No limit by default.
    #[arg(long)]
    pub timeout_secs: Option<u64>,
    /// The command to run to completion before waking, after `--`.
    #[arg(last = true)]
    pub command: Vec<String>,
}

/// How the watched command ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Ending {
    Exited(i32),
    Signalled,
    TimedOut(u64),
    FailedToStart(String),
}

impl Ending {
    fn describe(&self) -> String {
        match self {
            Self::Exited(0) => "succeeded (exit 0)".into(),
            Self::Exited(code) => format!("FAILED (exit {code})"),
            Self::Signalled => "was killed by a signal".into(),
            Self::TimedOut(secs) => format!("TIMED OUT after {secs}s and was killed"),
            Self::FailedToStart(error) => format!("could not start: {error}"),
        }
    }
}

/// A bounded tail of output lines.
#[derive(Default)]
struct Tail {
    lines: VecDeque<String>,
    dropped: usize,
}

impl Tail {
    fn push(&mut self, line: &str) {
        let line: String = line.chars().take(LINE_CHAR_CAP).collect();
        if self.lines.len() == TAIL_LINES {
            self.lines.pop_front();
            self.dropped += 1;
        }
        self.lines.push_back(line);
    }
}

async fn pump<R: AsyncRead + Unpin>(reader: R, tail: Arc<Mutex<Tail>>) {
    let mut lines = BufReader::new(reader).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        eprintln!("{line}");
        if let Ok(mut tail) = tail.lock() {
            tail.push(&line);
        }
    }
}

/// Run `command` to completion, echoing its output and keeping the tail.
async fn run(command: &[String], timeout: Option<Duration>) -> (Ending, Vec<String>, usize) {
    let tail = Arc::new(Mutex::new(Tail::default()));
    let spawned = tokio::process::Command::new(&command[0])
        .args(&command[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn();
    let mut child = match spawned {
        Ok(child) => child,
        Err(error) => return (Ending::FailedToStart(error.to_string()), Vec::new(), 0),
    };
    let out = child
        .stdout
        .take()
        .map(|s| tokio::spawn(pump(s, tail.clone())));
    let err = child
        .stderr
        .take()
        .map(|s| tokio::spawn(pump(s, tail.clone())));
    let waited = match timeout {
        Some(limit) => tokio::time::timeout(limit, child.wait()).await.ok(),
        None => Some(child.wait().await),
    };
    let ending = match waited {
        Some(Ok(status)) => match status.code() {
            Some(code) => Ending::Exited(code),
            None => Ending::Signalled,
        },
        Some(Err(error)) => Ending::FailedToStart(error.to_string()),
        None => {
            let _ = child.kill().await;
            Ending::TimedOut(timeout.map(|t| t.as_secs()).unwrap_or_default())
        }
    };
    // The pumps end when the pipes close; a grandchild that kept them open
    // must not hold the wake hostage.
    for pump in [out, err].into_iter().flatten() {
        let _ = tokio::time::timeout(Duration::from_secs(5), pump).await;
    }
    let tail = tail
        .lock()
        .map(|t| (t.lines.iter().cloned().collect(), t.dropped));
    let (lines, dropped) = tail.unwrap_or_default();
    (ending, lines, dropped)
}

fn human_duration(duration: Duration) -> String {
    let secs = duration.as_secs();
    match secs {
        0..=59 => format!("{secs}s"),
        60..=3599 => format!("{}m{:02}s", secs / 60, secs % 60),
        _ => format!("{}h{:02}m", secs / 3600, (secs % 3600) / 60),
    }
}

/// The wake message. First line is what happened; the rest is evidence.
pub fn wake_content(
    note: Option<&str>,
    command: &[String],
    ending: Option<&Ending>,
    elapsed: Duration,
    tail: &[String],
    dropped: usize,
) -> String {
    let mut out = String::new();
    match ending {
        Some(ending) => out.push_str(&format!(
            "Background job finished: `{}` {} after {}.",
            command.join(" ").replace('`', "'"),
            ending.describe(),
            human_duration(elapsed)
        )),
        None => out.push_str("Background job finished."),
    }
    out.push_str(
        " This is your own wake-up: pick the work back up — check the result, act on it, \
         and report to whoever asked.",
    );
    if let Some(note) = note.filter(|n| !n.trim().is_empty()) {
        out.push_str("\n\n");
        out.push_str(note.trim());
    }
    if !tail.is_empty() {
        out.push_str("\n\nLast output");
        if dropped > 0 {
            out.push_str(&format!(" ({dropped} earlier lines not shown)"));
        }
        out.push_str(":\n```\n");
        out.push_str(&tail.join("\n").replace("```", "'''"));
        out.push_str("\n```");
    }
    out
}

/// Parse `name=value` the way the harness does, so a typo fails here rather
/// than posting a wake nothing will ever hear.
fn parse_tag(raw: &str) -> Result<(String, String), CliError> {
    let (name, value) = raw
        .split_once('=')
        .ok_or_else(|| CliError::Usage(format!("--tag must be name=value, got {raw:?}")))?;
    let valid = |part: &str| {
        !part.is_empty()
            && part
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    };
    if !valid(name) || !valid(value) || name.len() < 2 {
        return Err(CliError::Usage(format!(
            "--tag name and value must be [A-Za-z0-9_-], name at least two characters, got {raw:?}"
        )));
    }
    Ok((name.to_owned(), value.to_owned()))
}

pub async fn cmd_wake(client: &BuzzClient, args: WakeArgs) -> Result<(), CliError> {
    let channel = parse_uuid(&args.channel)?;
    if let Some(reply_to) = &args.reply_to {
        validate_hex64(reply_to)?;
    }
    let (tag_name, tag_value) = parse_tag(&args.tag)?;
    let note = args.content.as_deref().map(read_or_stdin).transpose()?;

    let started = Instant::now();
    let (ending, tail, dropped) = if args.command.is_empty() {
        (None, Vec::new(), 0)
    } else {
        let (ending, tail, dropped) =
            run(&args.command, args.timeout_secs.map(Duration::from_secs)).await;
        (Some(ending), tail, dropped)
    };
    let content = wake_content(
        note.as_deref(),
        &args.command,
        ending.as_ref(),
        started.elapsed(),
        &tail,
        dropped,
    );

    let thread = match &args.reply_to {
        Some(reply_to) => Some(super::messages::resolve_thread_ref(client, reply_to).await?),
        None => None,
    };
    let me = client.keys().public_key().to_hex();
    let builder = buzz_sdk::build_message(
        channel,
        &content,
        thread.as_ref(),
        &[me.as_str()],
        false,
        &[],
        &[],
    )
    .map_err(|e| CliError::Other(format!("build_message failed: {e}")))?
    .tag(
        nostr::Tag::parse([tag_name.as_str(), tag_value.as_str()])
            .map_err(|e| CliError::Other(format!("wake tag: {e}")))?,
    );
    let event = client.sign_event(builder)?;
    let response = client.submit_event(event).await?;
    println!("{}", normalize_write_response(&response));
    match ending {
        // The wake was delivered; the exit code says how the job went, so a
        // caller chaining on it still sees the failure.
        Some(Ending::Exited(code)) if code != 0 => Err(CliError::Other(format!(
            "the watched command exited {code}; the wake was posted"
        ))),
        Some(Ending::Signalled | Ending::TimedOut(_) | Ending::FailedToStart(_)) => {
            Err(CliError::Other(
                "the watched command did not finish cleanly; the wake was posted".into(),
            ))
        }
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_tail_is_bounded_in_lines_and_in_width() {
        let mut tail = Tail::default();
        for i in 0..100 {
            tail.push(&format!("line {i}"));
        }
        assert_eq!(tail.lines.len(), TAIL_LINES);
        assert_eq!(tail.dropped, 100 - TAIL_LINES);
        assert_eq!(tail.lines.back().map(String::as_str), Some("line 99"));
        tail.push(&"x".repeat(10_000));
        assert_eq!(
            tail.lines.back().map(|l| l.chars().count()),
            Some(LINE_CHAR_CAP)
        );
    }

    #[test]
    fn the_message_leads_with_the_outcome_and_carries_the_evidence() {
        let command = vec!["./bench.sh".to_owned(), "--full".to_owned()];
        let text = wake_content(
            Some("the 80k-token run"),
            &command,
            Some(&Ending::Exited(1)),
            Duration::from_secs(754),
            &["accuracy 0.80".to_owned(), "```inner```".to_owned()],
            12,
        );
        assert!(text.starts_with(
            "Background job finished: `./bench.sh --full` FAILED (exit 1) after 12m34s."
        ));
        assert!(text.contains("This is your own wake-up"));
        assert!(text.contains("the 80k-token run"));
        assert!(text.contains("(12 earlier lines not shown)"));
        assert!(text.contains("accuracy 0.80"));
        assert!(
            !text.contains("```inner```"),
            "a fence in the output cannot close ours"
        );

        let bare = wake_content(None, &[], None, Duration::ZERO, &[], 0);
        assert!(bare.starts_with("Background job finished. This is your own wake-up"));
        assert!(!bare.contains("Last output"));
    }

    #[test]
    fn every_ending_reads_plainly() {
        assert_eq!(Ending::Exited(0).describe(), "succeeded (exit 0)");
        assert!(Ending::TimedOut(60)
            .describe()
            .contains("TIMED OUT after 60s"));
        assert!(Ending::FailedToStart("no such file".into())
            .describe()
            .contains("no such file"));
    }

    #[test]
    fn the_tag_is_checked_the_way_the_harness_checks_it() {
        assert_eq!(
            parse_tag("job=done").unwrap(),
            ("job".into(), "done".into())
        );
        for bad in ["job", "p=done", "job=", "job=do ne", "=done"] {
            assert!(parse_tag(bad).is_err(), "{bad:?}");
        }
    }

    #[tokio::test]
    async fn a_command_runs_to_completion_and_its_tail_is_kept() {
        let (ending, tail, dropped) = run(
            &[
                "sh".into(),
                "-c".into(),
                "echo out; echo err >&2; exit 3".into(),
            ],
            None,
        )
        .await;
        assert_eq!(ending, Ending::Exited(3));
        assert_eq!(dropped, 0);
        assert!(tail.contains(&"out".to_owned()) && tail.contains(&"err".to_owned()));

        let (ending, _, _) = run(
            &["sleep".into(), "5".into()],
            Some(Duration::from_millis(200)),
        )
        .await;
        assert_eq!(ending, Ending::TimedOut(0));

        let (ending, _, _) = run(&["/definitely/not/here".into()], None).await;
        assert!(matches!(ending, Ending::FailedToStart(_)));
    }
}
