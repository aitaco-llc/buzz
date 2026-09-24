//! `buzz tasks` — the task board, derived from what every maintainer can read.
//!
//! Sections 6 and 7 of `PLANS/BUZZ_TASK_TRACKER_ARCHITECTURE_2026-09-23.md`.
//! A task is a NIP-34 issue labelled `t=task`; nothing here adds a kind. The
//! derivation itself is [`buzz_core::task_board`], shared with the Desktop read
//! model through `test-fixtures/task-board-state.json`, so this command and
//! Lloyd's Tasks tab cannot disagree about a task. This module only fetches
//! and shapes.
//!
//! `kind:44200` is not read here and must not be: it is owner-scoped, so a
//! seat would see its own turns and no peer's.

use serde::Deserialize;
use serde_json::json;

use crate::client::BuzzClient;
use crate::error::CliError;
use crate::validate::{validate_hex64, validate_repo_id};

/// The label that marks an issue as tracker-managed. An unlabelled issue in
/// the same repository is somebody's ordinary bug and stays off the board.
pub const TASK_LABEL: &str = "task";

const LINK_TASK_THREAD: &str = "task-thread";
const LINK_BLOCKED_BY: &str = "blocked-by";

/// Every field the board reads off an event. Signatures are not returned by
/// the CLI's read path, so this deserializes only what is present.
#[derive(Debug, Clone, Deserialize)]
struct BoardEvent {
    id: String,
    kind: u16,
    pubkey: String,
    created_at: u64,
    #[serde(default)]
    content: String,
    #[serde(default)]
    tags: Vec<Vec<String>>,
}

impl BoardEvent {
    fn tag_values(&self, name: &str) -> Vec<&str> {
        self.tags
            .iter()
            .filter(|t| t.first().map(String::as_str) == Some(name))
            .filter_map(|t| t.get(1).map(String::as_str))
            .collect()
    }

    /// The `e` tag with the given NIP-10 marker, if any.
    fn marked_e(&self, marker: &str) -> Option<&str> {
        self.tags.iter().find_map(|t| match t.as_slice() {
            [name, value, _, m, ..] if name == "e" && m == marker => Some(value.as_str()),
            _ => None,
        })
    }

    /// The thread this post hangs from: its `root` marker, else its first `e`,
    /// else itself for a top-level post. The same key `TurnJoin` publishes and
    /// a `task-thread` link note points at, so the two join with no
    /// translation step.
    fn thread_key(&self) -> &str {
        if let Some(root) = self.marked_e("root") {
            return root;
        }
        self.tag_values("e")
            .first()
            .copied()
            .unwrap_or(self.id.as_str())
    }
}

/// One row of the board, in the shape `--json` emits.
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BoardRow {
    pub id: String,
    pub subject: String,
    pub state: String,
    pub assignee: Option<String>,
    pub blocked_by: Option<String>,
    pub created_at: u64,
    pub activity_at: Option<u64>,
    /// Seconds since the last activity, or since the issue was created.
    pub quiet_for_secs: u64,
    /// Whether the clock alone says this task has stalled. The CLI cannot see
    /// whether the assignee's seat is up or mid-turn, so it reports the clock
    /// and the watchdog ANDs its own two checks (section 7). Naming it for
    /// what it is keeps a reader from treating it as the finding.
    pub stalled_by_clock: bool,
    /// Thread roots this task's `task-thread` link notes name.
    pub linked_threads: Vec<String>,
}

/// Fetch and reduce the board for one repository.
///
/// Four batched queries, then one per linked thread. The per-thread queries
/// are the cost: a task with no linked thread is free, which is the usual case
/// for a task nobody has started.
async fn fetch_board(
    client: &BuzzClient,
    repo_owner: &str,
    repo_id: &str,
) -> Result<Vec<BoardRow>, CliError> {
    let a_value = format!("30617:{}:{}", repo_owner.to_ascii_lowercase(), repo_id);

    // The repository's own announcement rides along for its `maintainers` tag:
    // a maintainer's assignment is trusted for other people (buzz#71), and a
    // board that ignored the tag would show a maintainer's work unassigned.
    let head: Vec<BoardEvent> = query(
        client,
        &[
            json!({ "kinds": [1621], "#a": [a_value], "#t": [TASK_LABEL], "limit": 500 }),
            json!({ "kinds": [30617], "authors": [repo_owner.to_ascii_lowercase()],
                    "#d": [repo_id], "limit": 1 }),
        ],
    )
    .await?;
    let maintainers: Vec<String> = head
        .iter()
        .find(|e| e.kind == 30617)
        .map(|e| {
            e.tags
                .iter()
                .filter(|t| t.first().map(String::as_str) == Some("maintainers"))
                .flat_map(|t| t.iter().skip(1))
                .cloned()
                .collect()
        })
        .unwrap_or_default();
    let issues: Vec<BoardEvent> = head.into_iter().filter(|e| e.kind == 1621).collect();
    if issues.is_empty() {
        return Ok(Vec::new());
    }
    let ids: Vec<&str> = issues.iter().map(|i| i.id.as_str()).collect();

    // Status (1630-1633), the labelled kind-1 notes (assignment, unassignment,
    // task-thread, blocked-by) and NIP-22 comments, in one round trip.
    let notes: Vec<BoardEvent> = query(
        client,
        &[
            json!({ "kinds": [1630, 1631, 1632, 1633], "#e": ids, "limit": 1000 }),
            json!({ "kinds": [1], "#e": ids, "limit": 1000 }),
            json!({ "kinds": [1111], "#e": ids, "limit": 1000 }),
        ],
    )
    .await?;

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| CliError::Other(format!("read system clock: {e}")))?
        .as_secs();

    let mut rows = Vec::with_capacity(issues.len());
    for issue in &issues {
        let mine: Vec<&BoardEvent> = notes
            .iter()
            .filter(|n| n.tag_values("e").contains(&issue.id.as_str()))
            .collect();
        rows.push(reduce_one(client, issue, &mine, repo_owner, &maintainers, now).await?);
    }
    rows.sort_by(|a, b| {
        b.activity_at
            .cmp(&a.activity_at)
            .then(b.created_at.cmp(&a.created_at))
    });
    Ok(rows)
}

async fn reduce_one(
    client: &BuzzClient,
    issue: &BoardEvent,
    notes: &[&BoardEvent],
    repo_owner: &str,
    maintainers: &[String],
    now: u64,
) -> Result<BoardRow, CliError> {
    // Status: the newest from a signer the reader trusts. Trust is the same
    // rule assignment uses and lives in `issues.rs`; a status from anyone else
    // is ignored on read, so a hostile 1632 cannot close someone's task.
    let closed = notes
        .iter()
        .filter(|n| (1630..=1633).contains(&n.kind))
        .filter(|n| {
            n.pubkey.eq_ignore_ascii_case(&issue.pubkey)
                || n.pubkey.eq_ignore_ascii_case(repo_owner)
        })
        .max_by_key(|n| (n.created_at, n.id.clone()))
        .is_some_and(|n| n.kind == 1632 || n.kind == 1631);

    let assignment_events: Vec<crate::commands::issues::AssignmentEvent> = notes
        .iter()
        .filter(|n| n.kind == 1)
        .map(|n| crate::commands::issues::AssignmentEvent {
            id: n.id.clone(),
            pubkey: n.pubkey.clone(),
            created_at: n.created_at,
            tags: n.tags.clone(),
        })
        .collect();
    let assignee = crate::commands::issues::board_assignee(
        &issue.id,
        &issue.pubkey,
        repo_owner,
        maintainers,
        &assignment_events,
    );

    let (linked_threads, blocked_by) = links_from(notes);

    // Comments on the issue count wherever they are; kind-9s count only in a
    // linked thread, so only linked threads are fetched.
    let mut posts: Vec<buzz_core::task_board::Post<'_>> = Vec::new();
    let mut thread_posts: Vec<BoardEvent> = Vec::new();
    for thread in &linked_threads {
        let rows: Vec<BoardEvent> = query(
            client,
            &[json!({ "kinds": [9], "#e": [thread], "limit": 500 })],
        )
        .await?;
        thread_posts.extend(rows);
    }
    for post in &thread_posts {
        posts.push(buzz_core::task_board::Post {
            thread: Some(post.thread_key()),
            pubkey: &post.pubkey,
            created_at: post.created_at,
            content: &post.content,
        });
    }
    for comment in notes.iter().filter(|n| n.kind == 1111) {
        posts.push(buzz_core::task_board::Post {
            thread: None,
            pubkey: &comment.pubkey,
            created_at: comment.created_at,
            content: &comment.content,
        });
    }

    let thread_refs: Vec<&str> = linked_threads.iter().map(String::as_str).collect();
    let facts = buzz_core::task_board::TaskFacts {
        created_at: issue.created_at,
        closed,
        assignee: assignee.as_deref(),
        blocked_by: blocked_by.as_deref(),
        linked_threads: &thread_refs,
        posts: &posts,
        // The CLI cannot see a seat. The watchdog ANDs these itself, which is
        // why the row reports `stalledByClock` rather than a finding.
        assignee_seat_up: true,
        assignee_turn_in_flight: false,
    };
    let derived = buzz_core::task_board::derive(&facts, now);

    Ok(BoardRow {
        id: issue.id.clone(),
        subject: issue
            .tag_values("subject")
            .first()
            .map(|s| (*s).to_owned())
            .unwrap_or_else(|| {
                issue
                    .content
                    .lines()
                    .next()
                    .unwrap_or("Untitled")
                    .to_owned()
            }),
        state: state_name(derived.state).to_owned(),
        assignee,
        blocked_by,
        created_at: issue.created_at,
        activity_at: derived.activity_at,
        quiet_for_secs: now.saturating_sub(derived.activity_at.unwrap_or(issue.created_at)),
        stalled_by_clock: derived.stalled,
        linked_threads,
    })
}

/// The threads a task links, and the issue blocking it.
///
/// Pure, because this is the only new reading in the command: everything else
/// is a query or [`buzz_core::task_board`]. A note with neither label is an
/// assignment, a comment or somebody's reply and is not a link.
fn links_from(notes: &[&BoardEvent]) -> (Vec<String>, Option<String>) {
    let mut threads: Vec<String> = Vec::new();
    let mut blocked_by = None;
    for note in notes.iter().filter(|n| n.kind == 1) {
        let labels = note.tag_values("t");
        // The link's target rides in the `mention`-marked `e` tag; the `root`
        // one is the issue itself. A note missing it links nothing.
        let Some(target) = note.marked_e("mention") else {
            continue;
        };
        if labels.contains(&LINK_TASK_THREAD) {
            if !threads.iter().any(|t| t == target) {
                threads.push(target.to_owned());
            }
        } else if labels.contains(&LINK_BLOCKED_BY) {
            // Newest wins: a blocker named twice is a blocker that moved.
            blocked_by = Some(target.to_owned());
        }
    }
    (threads, blocked_by)
}

fn state_name(state: buzz_core::task_board::BoardState) -> &'static str {
    use buzz_core::task_board::BoardState as S;
    match state {
        S::Done => "Done",
        S::Unassigned => "Unassigned",
        S::Blocked => "Blocked",
        S::InProgress => "In Progress",
        S::UpNext => "Up Next",
    }
}

async fn query(
    client: &BuzzClient,
    filters: &[serde_json::Value],
) -> Result<Vec<BoardEvent>, CliError> {
    let raw = client.query_multi(filters).await?;
    serde_json::from_str(&raw).map_err(|e| CliError::Other(format!("parse board events: {e}")))
}

/// `buzz tasks board`.
pub async fn cmd_board(
    client: &BuzzClient,
    repo_owner: &str,
    repo_id: &str,
    show_done: bool,
    assignee_filter: Option<&str>,
    as_json: bool,
) -> Result<(), CliError> {
    validate_hex64(repo_owner)?;
    validate_repo_id(repo_id)?;
    if let Some(pk) = assignee_filter {
        validate_hex64(pk)?;
    }

    let rows: Vec<BoardRow> = fetch_board(client, repo_owner, repo_id)
        .await?
        .into_iter()
        // Default view is the work: In Progress and Up Next, with Unassigned
        // pinned above them because it is a fault. Done is behind the toggle.
        .filter(|r| show_done || r.state != "Done")
        .filter(|r| {
            assignee_filter.is_none_or(|pk| {
                r.assignee
                    .as_deref()
                    .is_some_and(|a| a.eq_ignore_ascii_case(pk))
            })
        })
        .collect();

    if as_json {
        println!(
            "{}",
            serde_json::to_string(&rows).map_err(|e| CliError::Other(e.to_string()))?
        );
        return Ok(());
    }

    if rows.is_empty() {
        println!("no tasks");
        return Ok(());
    }
    // Groups in the order a reader should act on them.
    for group in ["Unassigned", "Blocked", "In Progress", "Up Next", "Done"] {
        let in_group: Vec<&BoardRow> = rows.iter().filter(|r| r.state == group).collect();
        if in_group.is_empty() {
            continue;
        }
        println!("\n{group} ({})", in_group.len());
        for row in in_group {
            let who = row
                .assignee
                .as_deref()
                .map(|a| a[..8].to_owned())
                .unwrap_or_else(|| "unassigned".to_owned());
            let quiet = humanize(row.quiet_for_secs);
            let flag = if row.stalled_by_clock { "  ⏳" } else { "" };
            println!("  {}  {:<10} quiet {}{}", &row.id[..8], who, quiet, flag);
            println!("      {}", row.subject);
        }
    }
    Ok(())
}

fn humanize(secs: u64) -> String {
    match secs {
        s if s < 90 * 60 => format!("{}m", s / 60),
        s if s < 48 * 3600 => format!("{}h", s / 3600),
        s => format!("{}d", s / 86400),
    }
}

pub async fn dispatch(cmd: crate::TasksCmd, client: &BuzzClient) -> Result<(), CliError> {
    match cmd {
        crate::TasksCmd::Board {
            repo_owner,
            repo_id,
            show_done,
            assignee,
            json,
        } => {
            cmd_board(
                client,
                &repo_owner,
                &repo_id,
                show_done,
                assignee.as_deref(),
                json,
            )
            .await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(kind: u16, tags: &[&[&str]]) -> BoardEvent {
        BoardEvent {
            id: "e".repeat(64),
            kind,
            pubkey: "a".repeat(64),
            created_at: 100,
            content: String::new(),
            tags: tags
                .iter()
                .map(|t| t.iter().map(|s| (*s).to_owned()).collect())
                .collect(),
        }
    }

    #[test]
    fn a_link_notes_target_is_its_mention_not_its_root() {
        let issue = "b".repeat(64);
        let thread = "c".repeat(64);
        let n = note(
            1,
            &[
                &["e", &issue, "", "root"],
                &["t", "task-thread"],
                &["e", &thread, "", "mention"],
            ],
        );

        let (threads, blocked) = links_from(&[&n]);

        assert_eq!(threads, vec![thread], "the root is the issue, not the link");
        assert_eq!(blocked, None);
    }

    #[test]
    fn an_assignment_note_is_not_a_link() {
        let issue = "b".repeat(64);
        let n = note(
            1,
            &[
                &["e", &issue, "", "root"],
                &["p", &"d".repeat(64)],
                &["t", "assignment"],
            ],
        );
        assert_eq!(links_from(&[&n]), (Vec::new(), None));
    }

    #[test]
    fn the_newest_blocker_wins_and_threads_accumulate() {
        let issue = "b".repeat(64);
        let mk = |label: &str, target: &str| {
            note(
                1,
                &[
                    &["e", &issue, "", "root"],
                    &["t", label],
                    &["e", target, "", "mention"],
                ],
            )
        };
        let t1 = mk("task-thread", &"1".repeat(64));
        let t2 = mk("task-thread", &"2".repeat(64));
        let dup = mk("task-thread", &"1".repeat(64));
        let b1 = mk("blocked-by", &"8".repeat(64));
        let b2 = mk("blocked-by", &"9".repeat(64));

        let (threads, blocked) = links_from(&[&t1, &t2, &dup, &b1, &b2]);

        assert_eq!(threads, vec!["1".repeat(64), "2".repeat(64)], "deduped");
        assert_eq!(blocked, Some("9".repeat(64)), "a blocker that moved");
    }

    /// The key the board joins on. It must equal what `TurnJoin::thread_root`
    /// publishes and what a `task-thread` note points at, or the two halves of
    /// the join never meet.
    #[test]
    fn a_posts_thread_key_is_its_root_then_its_first_e_then_itself() {
        let root = "1".repeat(64);
        let other = "2".repeat(64);

        let marked = note(9, &[&["e", &other], &["e", &root, "", "root"]]);
        assert_eq!(marked.thread_key(), root, "a root marker wins");

        let unmarked = note(9, &[&["e", &other]]);
        assert_eq!(unmarked.thread_key(), other, "else the first e tag");

        let top = note(9, &[&["h", "channel"]]);
        assert_eq!(top.thread_key(), top.id, "a top-level post roots itself");
    }
}
