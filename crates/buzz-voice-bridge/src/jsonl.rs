//! Append-only JSONL logs, and the two things they need to stay useful: a
//! retention sweep, and a rate limiter so a 50 frames/s fault cannot drown the
//! file it is being reported in.
//!
//! Two logs use this. One per call, named for the huddle, and one for the
//! watcher itself (`bridge.jsonl`), which outlives every call. **No audio is
//! ever written to either**, only counts of it.

use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};
use tracing::warn;

/// `bridge.jsonl` is rotated once past this, keeping one previous file. A
/// call log is bounded by the call, so it is never rotated.
pub const ROTATE_AT_BYTES: u64 = 8 * 1024 * 1024;

pub struct JsonlLog {
    path: PathBuf,
    file: Option<std::fs::File>,
}

impl JsonlLog {
    /// Open `path` for append, creating its directory. A log that cannot be
    /// opened warns once and then swallows records: losing the log must never
    /// take the call down with it.
    pub fn open(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let file = path
            .parent()
            .map(std::fs::create_dir_all)
            .transpose()
            .and_then(|_| {
                std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&path)
            });
        match file {
            Ok(file) => Self {
                path,
                file: Some(file),
            },
            Err(error) => {
                warn!(path = %path.display(), %error, "log unavailable");
                Self { path, file: None }
            }
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn is_open(&self) -> bool {
        self.file.is_some()
    }

    pub fn record(&mut self, event: &str, data: Value) {
        let Some(file) = self.file.as_mut() else {
            return;
        };
        let line = json!({ "t": chrono::Utc::now().to_rfc3339(), "event": event, "data": data });
        if let Err(error) = writeln!(file, "{line}") {
            warn!(%error, "log write failed");
        }
    }
}

/// Rename `path` to `path.1` when it has grown past `max_bytes`, so an
/// append-only log that outlives every call stays bounded. Keeps one previous
/// file; a missing or smaller file is left alone.
pub fn rotate_if_over(path: &Path, max_bytes: u64) {
    let too_big = std::fs::metadata(path).is_ok_and(|meta| meta.len() > max_bytes);
    if !too_big {
        return;
    }
    let mut previous = path.as_os_str().to_owned();
    previous.push(".1");
    if let Err(error) = std::fs::rename(path, PathBuf::from(previous)) {
        warn!(path = %path.display(), %error, "log rotation failed");
    }
}

/// Delete `*.jsonl` in `dir` last written more than `days` ago, `keep` aside.
/// Call logs hold every word spoken on the call, so they expire; the watcher's
/// own log holds no speech and is kept. Returns how many were removed.
pub fn sweep_older_than(dir: &Path, days: u64, keep: &Path) -> usize {
    let Some(cutoff) = SystemTime::now().checked_sub(Duration::from_secs(days * 24 * 60 * 60))
    else {
        return 0;
    };
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    let mut removed = 0;
    for entry in entries.flatten() {
        let path = entry.path();
        if path == keep || path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
            continue;
        }
        let old = entry
            .metadata()
            .and_then(|meta| meta.modified())
            .is_ok_and(|modified| modified < cutoff);
        if old {
            match std::fs::remove_file(&path) {
                Ok(()) => removed += 1,
                Err(error) => warn!(path = %path.display(), %error, "expired log not removed"),
            }
        }
    }
    removed
}

/// Emit at most one record per window, counting what was dropped in between.
pub struct RateLimit {
    window: Duration,
    last: Option<Instant>,
    suppressed: u64,
}

impl RateLimit {
    pub fn new(window: Duration) -> Self {
        Self {
            window,
            last: None,
            suppressed: 0,
        }
    }

    /// `Some(n)` when the caller should emit, `n` being how many it swallowed
    /// since the last emission. `None` means stay quiet.
    pub fn allow(&mut self) -> Option<u64> {
        let due = self.last.is_none_or(|last| last.elapsed() >= self.window);
        if due {
            self.last = Some(Instant::now());
            return Some(std::mem::take(&mut self.suppressed));
        }
        self.suppressed += 1;
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("voice-bridge-jsonl-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        dir
    }

    #[test]
    fn records_one_object_per_line_and_creates_the_directory() {
        let dir = temp_dir("record");
        let mut log = JsonlLog::open(dir.join("nested/call.jsonl"));
        assert!(log.is_open());
        log.record("call_start", json!({ "a": 1 }));
        log.record("call_end", json!({ "reason": "done" }));
        let text = std::fs::read_to_string(dir.join("nested/call.jsonl")).expect("read");
        let lines: Vec<Value> = text
            .lines()
            .map(|line| serde_json::from_str(line).expect("json"))
            .collect();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0]["event"], "call_start");
        assert_eq!(lines[0]["data"]["a"], 1);
        assert!(lines[0]["t"].as_str().is_some_and(|t| t.contains('T')));
        assert_eq!(lines[1]["data"]["reason"], "done");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_unopenable_log_swallows_records_instead_of_failing() {
        let dir = temp_dir("unopenable");
        let blocker = dir.join("blocked");
        std::fs::write(&blocker, "not a directory").expect("write");
        let mut log = JsonlLog::open(blocker.join("call.jsonl"));
        assert!(!log.is_open());
        log.record("call_start", json!({}));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn rotation_keeps_one_previous_file() {
        let dir = temp_dir("rotate");
        let path = dir.join("bridge.jsonl");
        std::fs::write(&path, "x".repeat(100)).expect("write");
        rotate_if_over(&path, 1000);
        assert!(path.exists(), "a small log is left alone");
        rotate_if_over(&path, 10);
        assert!(!path.exists());
        assert_eq!(
            std::fs::read_to_string(dir.join("bridge.jsonl.1")).expect("read"),
            "x".repeat(100)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_sweep_takes_old_call_logs_and_leaves_the_bridge_log() {
        let dir = temp_dir("sweep");
        let bridge = dir.join("bridge.jsonl");
        let old = dir.join("20250101T000000Z-abcdef12.jsonl");
        let fresh = dir.join("20260919T000000Z-abcdef12.jsonl");
        let other = dir.join("notes.txt");
        for path in [&bridge, &old, &fresh, &other] {
            std::fs::write(path, "{}\n").expect("write");
        }
        let long_ago = SystemTime::now() - Duration::from_secs(40 * 24 * 60 * 60);
        for path in [&bridge, &old] {
            let file = std::fs::File::options()
                .write(true)
                .open(path)
                .expect("open");
            file.set_modified(long_ago).expect("mtime");
        }
        assert_eq!(sweep_older_than(&dir, 30, &bridge), 1);
        assert!(bridge.exists(), "the watcher's own log is kept");
        assert!(!old.exists());
        assert!(fresh.exists());
        assert!(other.exists(), "only *.jsonl is swept");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_rate_limit_emits_once_and_counts_what_it_swallowed() {
        let mut limit = RateLimit::new(Duration::from_millis(50));
        assert_eq!(limit.allow(), Some(0), "the first is always emitted");
        assert_eq!(limit.allow(), None);
        assert_eq!(limit.allow(), None);
        std::thread::sleep(Duration::from_millis(60));
        assert_eq!(limit.allow(), Some(2), "and it reports the two it dropped");
        assert_eq!(limit.allow(), None);
    }
}
