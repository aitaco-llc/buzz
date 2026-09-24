/**
 * Board rows for the Tasks tab: the issues, their links, and the derived state.
 *
 * The shaping half of the Desktop read model. State itself comes from
 * `deriveTaskBoardState` (`../projects/taskBoard.mjs`), the mirror of
 * `crates/buzz-core/src/task_board.rs`, both checked against
 * `test-fixtures/task-board-state.json`. This file decides only which events
 * are a task, which are its links, and which posts belong to it.
 *
 * Pure on purpose: the fetch lives in `taskBoardFetch.ts` so every rule here is
 * testable with no relay.
 *
 * `kind:44200` is not read. It is owner-scoped, so even Lloyd's client must not
 * use it for board state — his tab and a seat's `buzz tasks board` would then
 * disagree about the same task.
 */

import { deriveTaskBoardState } from "../projects/taskBoard.mjs";

/** Marks an issue as tracker-managed. An unlabelled issue stays off the board. */
export const TASK_LABEL = "task";

const LINK_TASK_THREAD = "task-thread";
const LINK_BLOCKED_BY = "blocked-by";

function tagValues(event, name) {
  return (event.tags ?? [])
    .filter((tag) => tag[0] === name && tag[1])
    .map((tag) => tag[1]);
}

/** The `e` tag carrying a given NIP-10 marker. */
function markedE(event, marker) {
  return (event.tags ?? []).find(
    (tag) => tag[0] === "e" && tag[3] === marker,
  )?.[1];
}

/**
 * The thread a post hangs from: its `root` marker, else its first `e`, else
 * itself. The same key a `task-thread` note points at and a turn metric
 * publishes, so the two join with no translation step.
 */
export function threadKeyOf(event) {
  const root = markedE(event, "root");
  if (root) return root;
  return tagValues(event, "e")[0] ?? event.id;
}

/**
 * The threads an issue links and the issue blocking it, from its kind-1 notes.
 *
 * A link's target is its `mention`-marked `e` tag; the `root` one is the issue
 * itself. A note with neither label is an assignment or a comment.
 */
export function linksFor(issueId, notes) {
  const threads = [];
  let blockedBy = null;
  for (const note of notes) {
    if (note.kind !== 1) continue;
    if (!tagValues(note, "e").includes(issueId)) continue;
    const labels = tagValues(note, "t");
    const target = markedE(note, "mention");
    if (!target) continue;
    if (labels.includes(LINK_TASK_THREAD)) {
      if (!threads.includes(target)) threads.push(target);
    } else if (labels.includes(LINK_BLOCKED_BY)) {
      // Newest wins: a blocker named twice is a blocker that moved.
      blockedBy = target;
    }
  }
  return { threads, blockedBy };
}

/**
 * Build the board's rows.
 *
 * `issues` are already-reduced `ProjectIssue`s — `projectIssueEventsToIssues`
 * has applied the NIP-34 trust rule to their status and assignees, including
 * the repository's maintainers, so this does not re-decide any of that.
 *
 * `assigneeSeatUp` and `assigneeTurnInFlight` are false here and stay false:
 * a client cannot see a seat. They only ever suppress the watchdog's nudge,
 * and the tab does not nudge, so the board state is unaffected.
 */
export function taskRowsFrom({
  issues,
  linkNotes = [],
  threadPosts = [],
  now,
}) {
  return issues
    .filter((issue) => (issue.labels ?? []).includes(TASK_LABEL))
    .map((issue) => {
      const { threads, blockedBy } = linksFor(issue.id, linkNotes);
      // Not filtered to `threads` here on purpose. `deriveTaskBoardState`
      // already decides which threads count, and a second copy of that rule in
      // the shaping layer is a rule that can drift — a mutation that deleted
      // the filter changed nothing, which is the proof it was never load
      // bearing. The fetch only queries linked threads, so the list is scoped
      // before it arrives.
      const posts = [
        ...threadPosts.map((post) => ({
          thread: threadKeyOf(post),
          pubkey: post.pubkey,
          createdAt: post.created_at,
          content: post.content ?? "",
        })),
        ...(issue.comments ?? []).map((comment) => ({
          thread: null,
          pubkey: comment.author,
          createdAt: comment.createdAt,
          content: comment.content ?? "",
        })),
      ];

      const derived = deriveTaskBoardState(
        {
          createdAt: issue.createdAt,
          closed: issue.status === "Closed" || issue.status === "Done",
          assignee: (issue.assignees ?? [])[0] ?? null,
          blockedBy,
          linkedThreads: threads,
          posts,
          assigneeSeatUp: false,
          assigneeTurnInFlight: false,
        },
        now,
      );

      return {
        id: issue.id,
        subject: issue.title,
        content: issue.content,
        author: issue.author,
        createdAt: issue.createdAt,
        assignee: (issue.assignees ?? [])[0] ?? null,
        blockedBy,
        linkedThreads: threads,
        state: derived.state,
        activityAt: derived.activityAt,
        commentCount: (issue.comments ?? []).length,
      };
    })
    .sort(
      (left, right) =>
        (right.activityAt ?? right.createdAt) -
        (left.activityAt ?? left.createdAt),
    );
}

/** The order a reader should act on the board in. */
export const TASK_GROUP_ORDER = [
  "Unassigned",
  "Blocked",
  "In Progress",
  "Up Next",
  "Done",
];

/**
 * The default view is the work: everything except Done, which sits behind the
 * toggle. Blocked rows render under their blocker, so they are returned but
 * grouped separately by the caller.
 */
export function groupTaskRows(rows, { showDone = false } = {}) {
  const groups = new Map(TASK_GROUP_ORDER.map((name) => [name, []]));
  for (const row of rows) {
    if (!showDone && row.state === "Done") continue;
    groups.get(row.state)?.push(row);
  }
  return TASK_GROUP_ORDER.map((name) => ({
    name,
    rows: groups.get(name) ?? [],
  })).filter((group) => group.rows.length > 0);
}

/**
 * How long ago a task last moved, in words.
 *
 * Coarse and relative on purpose: the board answers "is anyone on this",
 * not "when exactly". A task with no activity says so rather than borrowing
 * its creation time, or a brand-new task reads as if somebody just touched it.
 */
export function lastActivity(row, now = Math.floor(Date.now() / 1000)) {
  if (row.activityAt === null || row.activityAt === undefined) {
    return "no activity yet";
  }
  const secs = Math.max(0, now - row.activityAt);
  if (secs < 90 * 60) return `${Math.floor(secs / 60)}m ago`;
  if (secs < 48 * 3600) return `${Math.floor(secs / 3600)}h ago`;
  return `${Math.floor(secs / 86400)}d ago`;
}
