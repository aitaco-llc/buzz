//! Task board state and stall derivation.
//!
//! Sections 6 and 7 of `PLANS/BUZZ_TASK_TRACKER_ARCHITECTURE_2026-09-23.md`,
//! in one place so the `buzz tasks board` reducer and the Desktop read model
//! cannot disagree about a task. `test-fixtures/task-board-state.json` is the
//! shared oracle; the Desktop TS mirror reads the same file.
//!
//! **`kind:44200` is not an input here and must never become one.** It is
//! owner-scoped by NIP-AM's design — the relay delivers it only to the `#p`
//! owner — so a seat can decrypt its own metrics and no peer's. A board that
//! read it would show every other seat's task as `UpNext` forever from any
//! seat but the owner's, and Lloyd's tab and a seat's board would disagree
//! about the same task. Cost and the waterfall are the owner's client only.

use serde::{Deserialize, Serialize};

/// Opening of the notice buzz-acp posts when a turn was cut off before it
/// replied (`buzz-acp` `FAILURE_NOTICE_PREFIX`). A post that starts with it is
/// the harness reporting that nothing was done, so counting it as activity
/// would make a task look worked-on precisely because it was not.
pub const FAILURE_NOTICE_PREFIX: &str = "⚠️ I couldn't process the last request";

/// The fleet watchdog's own pubkey. Its stall nudge lands in the task's own
/// thread, so without this exclusion the nudge would reset the very clock that
/// produced it and `TASK_STALLED` could fire exactly once per task, ever.
pub const WATCHDOG_PUBKEY: &str =
    "f84515c5827ced5aa43d3e2d0aaeba822b00f30d6f8d35ed4232bd4da229898b";

/// No activity for this long makes an open task a stall candidate.
pub const STALL_AFTER_SECS: u64 = 4 * 60 * 60;

/// Activity this recent makes an open task `InProgress`.
pub const IN_PROGRESS_WITHIN_SECS: u64 = 24 * 60 * 60;

/// Where a task sits on the board. Derived, never stored.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BoardState {
    /// Closed (`1632`), with or without `t=dropped`. Behind the toggle.
    Done,
    /// Open with no assignee — a tracker fault, pinned to the top.
    Unassigned,
    /// Open with an unresolved `blocked-by` link. Renders under its blocker.
    Blocked,
    /// Open with activity inside [`IN_PROGRESS_WITHIN_SECS`].
    InProgress,
    /// Open, assigned, and quiet.
    UpNext,
}

/// A message in a thread the task links, or a comment on the issue.
#[derive(Debug, Clone)]
pub struct Post<'a> {
    /// Thread root for a kind-9; `None` for a NIP-22 comment on the issue,
    /// which needs no link to count.
    pub thread: Option<&'a str>,
    /// Who signed it. Compared against [`WATCHDOG_PUBKEY`].
    pub pubkey: &'a str,
    /// Unix seconds.
    pub created_at: u64,
    /// Compared against [`FAILURE_NOTICE_PREFIX`]; nothing else reads it.
    pub content: &'a str,
}

/// Everything the derivation reads. All of it is public: a maintainer with
/// relay access can reconstruct every field.
#[derive(Debug, Clone)]
pub struct TaskFacts<'a> {
    /// The issue's own `created_at`, the lower bound on activity.
    pub created_at: u64,
    /// Status `1632`, with or without `t=dropped`.
    pub closed: bool,
    /// The one accountable assignee, or `None` — which is a tracker fault.
    pub assignee: Option<&'a str>,
    /// The blocking issue, when a `blocked-by` link names one that is still open.
    pub blocked_by: Option<&'a str>,
    /// Thread roots carried by this task's `task-thread` link notes.
    pub linked_threads: &'a [&'a str],
    /// Kind-9s in any thread, and NIP-22 comments on the issue. Filtering to
    /// the linked threads happens here, not at the caller, so one rule owns it.
    pub posts: &'a [Post<'a>],
    /// Whether the assignee's seat is running. A seat that is down cannot
    /// answer a nudge; its being down is the watchdog's `UNIT_DOWN` finding.
    pub assignee_seat_up: bool,
    /// Whether the assignee's seat has a turn in flight. Readable only where
    /// the watchdog can see the seat's turn index (hip); `false` elsewhere,
    /// which costs a Mac seat the suppression and never a false silence.
    pub assignee_turn_in_flight: bool,
}

/// What the board shows for one task.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Derived {
    /// Where the task renders.
    pub state: BoardState,
    /// Newest qualifying activity, or `None` when there is none.
    pub activity_at: Option<u64>,
    /// Whether `TASK_STALLED` should fire this tick.
    pub stalled: bool,
}

/// Whether a post counts as activity on this task.
///
/// Status, assignment and link notes are bookkeeping and never reach here —
/// the caller passes kind-9s and NIP-22 comments only.
fn counts_as_activity(task_created_at: u64, linked_threads: &[&str], post: &Post<'_>) -> bool {
    // A task extracted from a message in a long-running thread inherits that
    // thread's history. Without this bound every such task is born InProgress.
    if post.created_at <= task_created_at {
        return false;
    }
    if post.pubkey.eq_ignore_ascii_case(WATCHDOG_PUBKEY) {
        return false;
    }
    if post.content.starts_with(FAILURE_NOTICE_PREFIX) {
        return false;
    }
    match post.thread {
        // A comment on the issue needs no link.
        None => true,
        // A kind-9 counts only in a thread the task links. Work in an unlinked
        // thread is a linking gap, closed by `buzz issues link --kind thread`,
        // not by reaching for the owner's metrics.
        Some(thread) => linked_threads
            .iter()
            .any(|t| t.eq_ignore_ascii_case(thread)),
    }
}

/// Newest qualifying activity on a task.
pub fn activity_at(facts: &TaskFacts<'_>) -> Option<u64> {
    facts
        .posts
        .iter()
        .filter(|p| counts_as_activity(facts.created_at, facts.linked_threads, p))
        .map(|p| p.created_at)
        .max()
}

/// Derive everything the board and the nudge need, from public events only.
///
/// Precedence is fixed here because section 6's table does not order its rows,
/// and two implementations that order them differently would disagree about
/// the same task. `Done` outranks all; `Unassigned` outranks `UpNext` because
/// it is a fault, not a queue position; and `Blocked` outranks `InProgress`
/// because someone chipping at the unblocked part has not unblocked it.
pub fn derive(facts: &TaskFacts<'_>, now: u64) -> Derived {
    let activity = activity_at(facts);

    let state = if facts.closed {
        BoardState::Done
    } else if facts.assignee.is_none() {
        BoardState::Unassigned
    } else if facts.blocked_by.is_some() {
        BoardState::Blocked
    } else if activity.is_some_and(|at| now.saturating_sub(at) <= IN_PROGRESS_WITHIN_SECS) {
        BoardState::InProgress
    } else {
        BoardState::UpNext
    };

    // The nudge asks a person to act, so it fires only where someone can.
    let quiet_for = now.saturating_sub(activity.unwrap_or(facts.created_at));
    let stalled = !facts.closed
        && facts.assignee.is_some()
        && facts.blocked_by.is_none()
        && facts.assignee_seat_up
        // Nagging a seat that is mid-turn is the false alarm section 7 avoids.
        // An in-flight turn has published nothing yet, so it suppresses the
        // nudge without making the task InProgress.
        && !facts.assignee_turn_in_flight
        && quiet_for > STALL_AFTER_SECS;

    Derived {
        state,
        activity_at: activity,
        stalled,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    /// The shared oracle. The Desktop TS read model reads the same file, so a
    /// divergence between the two surfaces fails here rather than in Lloyd's
    /// tab.
    const FIXTURE: &str = include_str!("../../../test-fixtures/task-board-state.json");

    fn state_name(state: BoardState) -> &'static str {
        match state {
            BoardState::Done => "Done",
            BoardState::Unassigned => "Unassigned",
            BoardState::Blocked => "Blocked",
            BoardState::InProgress => "In Progress",
            BoardState::UpNext => "Up Next",
        }
    }

    #[test]
    fn every_fixture_case_derives_what_it_says() {
        let doc: Value = serde_json::from_str(FIXTURE).expect("fixture parses");
        let cases = doc["cases"].as_array().expect("cases");
        assert!(cases.len() >= 12, "the fixture lost cases: {}", cases.len());

        for case in cases {
            let name = case["name"].as_str().unwrap();
            let now = case["now"].as_u64().unwrap();
            let task = &case["task"];

            let threads: Vec<String> = case["links"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|l| l["kind"] == "task-thread")
                .map(|l| l["target"].as_str().unwrap().to_owned())
                .collect();
            let thread_refs: Vec<&str> = threads.iter().map(String::as_str).collect();

            let mut posts: Vec<Post<'_>> = case["posts"]
                .as_array()
                .unwrap()
                .iter()
                .map(|p| Post {
                    thread: Some(p["thread"].as_str().unwrap()),
                    pubkey: p["pubkey"].as_str().unwrap(),
                    created_at: p["createdAt"].as_u64().unwrap(),
                    content: p["content"].as_str().unwrap(),
                })
                .collect();
            posts.extend(case["comments"].as_array().unwrap().iter().map(|c| Post {
                thread: None,
                pubkey: c["pubkey"].as_str().unwrap(),
                created_at: c["createdAt"].as_u64().unwrap(),
                content: c["content"].as_str().unwrap(),
            }));

            let facts = TaskFacts {
                created_at: task["createdAt"].as_u64().unwrap(),
                closed: task["status"] == "closed",
                assignee: task["assignee"].as_str(),
                blocked_by: task["blockedBy"].as_str(),
                linked_threads: &thread_refs,
                posts: &posts,
                assignee_seat_up: case["assigneeSeatUp"].as_bool().unwrap(),
                assignee_turn_in_flight: case["assigneeTurnInFlight"].as_bool().unwrap(),
            };

            let got = derive(&facts, now);
            let want = &case["expect"];
            assert_eq!(
                state_name(got.state),
                want["state"].as_str().unwrap(),
                "{name}: state"
            );
            assert_eq!(
                got.activity_at,
                want["activityAt"].as_u64(),
                "{name}: activityAt"
            );
            assert_eq!(
                got.stalled,
                want["stalled"].as_bool().unwrap(),
                "{name}: stalled"
            );
        }
    }

    /// The two constants the fixture and this module both hardcode. A drift
    /// between them would silently change which posts count as activity, and
    /// the fixture cases that depend on it would still pass because both sides
    /// moved together.
    #[test]
    fn the_fixture_and_the_code_agree_on_the_exclusions() {
        let doc: Value = serde_json::from_str(FIXTURE).unwrap();
        let c = &doc["constants"];
        assert_eq!(
            c["failure_notice_prefix"].as_str(),
            Some(FAILURE_NOTICE_PREFIX)
        );
        assert_eq!(c["watchdog_pubkey"].as_str(), Some(WATCHDOG_PUBKEY));
        assert_eq!(c["stall_after_secs"].as_u64(), Some(STALL_AFTER_SECS));
        assert_eq!(
            c["in_progress_within_secs"].as_u64(),
            Some(IN_PROGRESS_WITHIN_SECS)
        );
    }
}
