//! Reading the open board the extractor decides against.
//!
//! [`crate::task_extract`] cannot tell `attach` from `create` without it:
//! "where are we with assessing spark 1.3?" attaches and "where are we at in
//! all our initiatives?" does not, and nothing in the text separates them. So
//! the board is an input to every extraction, and this is where it comes from.
//!
//! # A reduced read, on purpose
//!
//! This is **not** the full board derivation. `buzz tasks board`
//! (`crates/buzz-cli/src/commands/tasks.rs`) resolves assignment, blocked-by
//! links, thread activity and the Blocked/In Progress/Up Next ordering, at the
//! cost of one extra query per linked thread. The extractor needs one thing
//! from all of that: **which pieces of work are open, and what are they
//! called.** Everything else would be tokens in a prompt that does not read
//! them.
//!
//! Two queries, no per-issue round trips.

use std::collections::HashMap;

use serde_json::json;
use tracing::debug;

use crate::task_extract::BoardTask;

/// NIP-34 repository announcement.
const KIND_REPO_ANNOUNCEMENT: u16 = 30617;
/// NIP-34 issue.
const KIND_ISSUE: u16 = 1621;
/// The label `buzz issues create` puts on a task, and `buzz tasks board`
/// filters by.
const TASK_LABEL: &str = "task";
/// Cap on issues read. The extractor sends at most `MAX_BOARD_ENTRIES` of them
/// anyway; this is the wire bound.
const ISSUE_QUERY_LIMIT: usize = 500;

/// The repository bound to a channel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelRepo {
    pub owner: String,
    pub id: String,
}

impl ChannelRepo {
    /// The NIP-34 `a` coordinate an issue tags.
    pub fn coordinate(&self) -> String {
        format!("{KIND_REPO_ANNOUNCEMENT}:{}:{}", self.owner.to_ascii_lowercase(), self.id)
    }
}

/// Find the repository bound to `channel` in a set of `kind:30617` events.
///
/// A repository announces its channel with a `buzz-channel` tag; the owner is
/// the announcement's author and the id is its `d` tag. An announcement that
/// names a different channel, or none, is not this channel's repository even
/// when it is the only one the query returned.
pub fn repo_from_announcements(events: &[serde_json::Value], channel: &str) -> Option<ChannelRepo> {
    events.iter().find_map(|e| {
        if e.get("kind").and_then(|k| k.as_u64()) != Some(KIND_REPO_ANNOUNCEMENT as u64) {
            return None;
        }
        if first_tag(e, "buzz-channel")? != channel {
            return None;
        }
        Some(ChannelRepo {
            owner: e.get("pubkey")?.as_str()?.to_ascii_lowercase(),
            id: first_tag(e, "d")?.to_string(),
        })
    })
}

/// Reduce issues and their status events into the open board.
///
/// An issue with no status event is open: `buzz issues create` does not publish
/// one, so treating "no status" as "not open" would hide every task nobody has
/// touched — which is most of them, and exactly the ones a duplicate would be
/// created for.
///
/// Only the newest status per issue counts, by `created_at` and then by id, so
/// a reopened task is open and the reduction is deterministic when two status
/// events share a second.
pub fn reduce_open(issues: &[serde_json::Value], statuses: &[serde_json::Value]) -> Vec<BoardTask> {
    let mut newest: HashMap<&str, (u64, &str, u16)> = HashMap::new();
    for s in statuses {
        let Some(kind) = s.get("kind").and_then(|k| k.as_u64()) else { continue };
        if !(1630..=1633).contains(&kind) {
            continue;
        }
        let created = s.get("created_at").and_then(|c| c.as_u64()).unwrap_or(0);
        let sid = s.get("id").and_then(|i| i.as_str()).unwrap_or("");
        for target in tag_values(s, "e") {
            let entry = newest.entry(target).or_insert((0, "", 1630));
            if (created, sid) > (entry.0, entry.1) {
                *entry = (created, sid, kind as u16);
            }
        }
    }

    let mut open = Vec::new();
    for issue in issues {
        if issue.get("kind").and_then(|k| k.as_u64()) != Some(KIND_ISSUE as u64) {
            continue;
        }
        let Some(id) = issue.get("id").and_then(|i| i.as_str()) else { continue };
        // 1630 is open; 1631 applied, 1632 closed, 1633 draft are not.
        if let Some((_, _, kind)) = newest.get(id) {
            if *kind != 1630 {
                continue;
            }
        }
        let subject = first_tag(issue, "subject")
            .map(str::to_string)
            .or_else(|| {
                issue
                    .get("content")
                    .and_then(|c| c.as_str())
                    .map(|c| c.lines().next().unwrap_or("").trim().to_string())
            })
            .unwrap_or_default();
        if subject.is_empty() {
            continue;
        }
        open.push(BoardTask {
            id: id.to_string(),
            subject,
            state: "open".to_string(),
            assignee: None,
        });
    }
    open
}

fn first_tag<'a>(event: &'a serde_json::Value, name: &str) -> Option<&'a str> {
    event
        .get("tags")?
        .as_array()?
        .iter()
        .filter_map(|t| t.as_array())
        .find(|t| t.first().and_then(|v| v.as_str()) == Some(name))
        .and_then(|t| t.get(1))
        .and_then(|v| v.as_str())
}

fn tag_values<'a>(event: &'a serde_json::Value, name: &str) -> Vec<&'a str> {
    event
        .get("tags")
        .and_then(|t| t.as_array())
        .map(|tags| {
            tags.iter()
                .filter_map(|t| t.as_array())
                .filter(|t| t.first().and_then(|v| v.as_str()) == Some(name))
                .filter_map(|t| t.get(1).and_then(|v| v.as_str()))
                .collect()
        })
        .unwrap_or_default()
}

/// The two filters that fetch a channel's open board.
///
/// Returned rather than executed so the shape is testable without a relay —
/// a filter that names the wrong tag returns an empty board, which reads
/// exactly like a channel with no tasks.
pub fn issue_filters(repo: &ChannelRepo) -> Vec<serde_json::Value> {
    vec![json!({
        "kinds": [KIND_ISSUE],
        "#a": [repo.coordinate()],
        "#t": [TASK_LABEL],
        "limit": ISSUE_QUERY_LIMIT,
    })]
}

/// Filter for the status events of `ids`.
pub fn status_filter(ids: &[String]) -> serde_json::Value {
    json!({ "kinds": [1630, 1631, 1632, 1633], "#e": ids, "limit": 1000 })
}

/// Filter for the repository announcements bound to `channel`.
pub fn repo_filter(channel: &str) -> serde_json::Value {
    json!({ "kinds": [KIND_REPO_ANNOUNCEMENT], "#buzz-channel": [channel], "limit": 20 })
}

/// Read the open board for `channel`, or an empty board when the channel has no
/// repository.
///
/// An empty board is not an error: a channel with no repository has nothing to
/// attach to, and the extractor skips its board-match pass rather than paying
/// for a call with nothing to compare against.
pub async fn fetch(relay: &crate::relay::RestClient, channel: &str) -> Result<Vec<BoardTask>, String> {
    let announcements = query(relay, vec![repo_filter(channel)]).await?;
    let Some(repo) = repo_from_announcements(&announcements, channel) else {
        debug!(%channel, "no repository bound to this channel — extracting against an empty board");
        return Ok(Vec::new());
    };

    let issues = query(relay, issue_filters(&repo)).await?;
    if issues.is_empty() {
        return Ok(Vec::new());
    }
    let ids: Vec<String> = issues
        .iter()
        .filter_map(|i| i.get("id").and_then(|v| v.as_str()).map(str::to_string))
        .collect();
    let statuses = query(relay, vec![status_filter(&ids)]).await?;

    let open = reduce_open(&issues, &statuses);
    debug!(
        %channel,
        repo = %repo.coordinate(),
        issues = issues.len(),
        open = open.len(),
        "read the open board for extraction"
    );
    Ok(open)
}

async fn query(
    relay: &crate::relay::RestClient,
    filters: Vec<serde_json::Value>,
) -> Result<Vec<serde_json::Value>, String> {
    let value = relay.query_raw(&filters).await.map_err(|e| e.to_string())?;
    Ok(value
        .get("events")
        .and_then(|e| e.as_array())
        .cloned()
        .unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn announcement(owner: &str, id: &str, channel: Option<&str>) -> serde_json::Value {
        let mut tags = vec![json!(["d", id])];
        if let Some(c) = channel {
            tags.push(json!(["buzz-channel", c]));
        }
        json!({ "kind": 30617, "pubkey": owner, "tags": tags })
    }

    fn issue(id: &str, subject: &str) -> serde_json::Value {
        json!({ "kind": 1621, "id": id, "tags": [["subject", subject]], "content": "body" })
    }

    fn status(id: &str, kind: u64, target: &str, created_at: u64) -> serde_json::Value {
        json!({ "kind": kind, "id": id, "created_at": created_at, "tags": [["e", target]] })
    }

    #[test]
    fn a_repo_is_this_channels_only_when_it_says_so() {
        let ours = announcement("aa", "buzz", Some("chan-1"));
        let theirs = announcement("bb", "other", Some("chan-2"));
        let unbound = announcement("cc", "loose", None);
        assert_eq!(
            repo_from_announcements(&[theirs.clone(), ours.clone()], "chan-1"),
            Some(ChannelRepo { owner: "aa".into(), id: "buzz".into() })
        );
        // The only announcement returned is still not this channel's repo.
        assert_eq!(repo_from_announcements(&[theirs, unbound], "chan-1"), None);
    }

    #[test]
    fn the_coordinate_lowercases_the_owner_because_the_a_tag_does() {
        let repo = ChannelRepo { owner: "AABB".into(), id: "buzz".into() };
        assert_eq!(repo.coordinate(), "30617:aabb:buzz");
        let filter = &issue_filters(&repo)[0];
        assert_eq!(filter["#a"][0], "30617:aabb:buzz");
        assert_eq!(filter["#t"][0], TASK_LABEL);
    }

    #[test]
    fn an_issue_with_no_status_is_open() {
        // `buzz issues create` publishes no status event. Treating "no status"
        // as "not open" would hide every task nobody has touched — which is
        // most of them, and exactly the ones a duplicate gets created for.
        let open = reduce_open(&[issue("i1", "Assess Spark 1.3")], &[]);
        assert_eq!(open.len(), 1);
        assert_eq!(open[0].subject, "Assess Spark 1.3");
        assert_eq!(open[0].state, "open");
    }

    #[test]
    fn a_closed_issue_is_not_on_the_board() {
        let open = reduce_open(
            &[issue("i1", "Done thing"), issue("i2", "Live thing")],
            &[status("s1", 1632, "i1", 100)],
        );
        assert_eq!(open.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), vec!["i2"]);
    }

    #[test]
    fn the_newest_status_wins_so_a_reopened_task_is_open() {
        let open = reduce_open(
            &[issue("i1", "Reopened")],
            &[status("s1", 1632, "i1", 100), status("s2", 1630, "i1", 200)],
        );
        assert_eq!(open.len(), 1);
    }

    #[test]
    fn a_tie_on_created_at_is_broken_deterministically() {
        // Two status events in the same second must not make the board depend
        // on relay ordering.
        let a = reduce_open(
            &[issue("i1", "x")],
            &[status("aaa", 1630, "i1", 100), status("bbb", 1632, "i1", 100)],
        );
        let b = reduce_open(
            &[issue("i1", "x")],
            &[status("bbb", 1632, "i1", 100), status("aaa", 1630, "i1", 100)],
        );
        assert_eq!(a.len(), b.len());
        assert!(a.is_empty(), "the higher id wins, and it is the close");
    }

    #[test]
    fn a_status_for_another_issue_does_not_close_this_one() {
        let open = reduce_open(&[issue("i1", "Mine")], &[status("s1", 1632, "i9", 100)]);
        assert_eq!(open.len(), 1);
    }

    #[test]
    fn an_issue_with_no_subject_falls_back_to_the_first_line_of_the_body() {
        let bare = json!({ "kind": 1621, "id": "i1", "tags": [], "content": "Fix the thing\n\nmore" });
        let open = reduce_open(&[bare], &[]);
        assert_eq!(open[0].subject, "Fix the thing");
    }

    #[test]
    fn an_issue_with_nothing_to_call_it_is_skipped() {
        // A board row the model cannot read is worse than one row fewer: it
        // spends tokens and offers an id nothing can be matched to.
        let nameless = json!({ "kind": 1621, "id": "i1", "tags": [], "content": "   " });
        assert!(reduce_open(&[nameless], &[]).is_empty());
    }

    #[test]
    fn non_issue_events_in_the_same_response_are_ignored() {
        let mixed = vec![issue("i1", "Real"), announcement("aa", "buzz", Some("c"))];
        let open = reduce_open(&mixed, &[]);
        assert_eq!(open.len(), 1);
    }

    #[test]
    fn a_non_status_kind_tagged_at_an_issue_does_not_close_it() {
        // Assignment notes and comments are kind 1 and 1111 and also carry an
        // `e` tag at the issue.
        let note = json!({ "kind": 1, "id": "n1", "created_at": 500, "tags": [["e", "i1"]] });
        assert_eq!(reduce_open(&[issue("i1", "Mine")], &[note]).len(), 1);
    }
}
