/**
 * Task board state and stall derivation.
 *
 * Sections 6 and 7 of `PLANS/BUZZ_TASK_TRACKER_ARCHITECTURE_2026-09-23.md`.
 * The mirror of `crates/buzz-core/src/task_board.rs`; both read
 * `test-fixtures/task-board-state.json` as their oracle, so this surface and
 * `buzz tasks board` cannot disagree about one task.
 *
 * `kind:44200` is NOT an input here and must never become one. It is
 * owner-scoped by NIP-AM's design — the relay delivers it only to the `#p`
 * owner — so a seat can decrypt its own metrics and no peer's. A board that
 * read it would show every other seat's task as "Up Next" forever from any
 * seat but Lloyd's, and his tab and a seat's board would disagree. Cost and
 * the waterfall are the owner's client only, and they are a different view.
 */

/** `buzz-acp` FAILURE_NOTICE_PREFIX: the harness saying a turn was cut off. */
export const FAILURE_NOTICE_PREFIX = "⚠️ I couldn't process the last request";

/** The fleet watchdog's own key; its nudge lands in the task's own thread. */
export const WATCHDOG_PUBKEY =
  "f84515c5827ced5aa43d3e2d0aaeba822b00f30d6f8d35ed4232bd4da229898b";

export const STALL_AFTER_SECS = 4 * 60 * 60;
export const IN_PROGRESS_WITHIN_SECS = 24 * 60 * 60;

export const TASK_BOARD_STATE = {
  DONE: "Done",
  UNASSIGNED: "Unassigned",
  BLOCKED: "Blocked",
  IN_PROGRESS: "In Progress",
  UP_NEXT: "Up Next",
};

/**
 * Whether one post counts as activity on a task.
 *
 * `post.thread` is the thread root for a kind-9 and null for a NIP-22 comment
 * on the issue, which needs no link to count.
 */
function countsAsActivity(taskCreatedAt, linkedThreads, post) {
  // A task extracted from a message in a long-running thread inherits that
  // thread's history. Without this bound every such task is born In Progress.
  if (post.createdAt <= taskCreatedAt) return false;
  if (post.pubkey?.toLowerCase() === WATCHDOG_PUBKEY) return false;
  if ((post.content ?? "").startsWith(FAILURE_NOTICE_PREFIX)) return false;
  if (post.thread == null) return true;
  // Work in an unlinked thread is a linking gap, closed by
  // `buzz issues link --kind thread`, not by reaching for the owner's metrics.
  return linkedThreads.some(
    (thread) => thread.toLowerCase() === post.thread.toLowerCase(),
  );
}

/** Newest qualifying activity, or null. */
export function taskActivityAt(task) {
  const times = (task.posts ?? [])
    .filter((post) =>
      countsAsActivity(task.createdAt, task.linkedThreads ?? [], post),
    )
    .map((post) => post.createdAt);
  return times.length ? Math.max(...times) : null;
}

/**
 * Derive everything the board and the nudge need, from public events only.
 *
 * Precedence is fixed here because section 6's table does not order its rows:
 * `Done` outranks all; `Unassigned` outranks `Up Next` because it is a fault,
 * not a queue position; `Blocked` outranks `In Progress` because chipping at
 * the unblocked part has not unblocked it. See the fixture's `precedence`.
 */
export function deriveTaskBoardState(task, now) {
  const activityAt = taskActivityAt(task);

  let state;
  if (task.closed) state = TASK_BOARD_STATE.DONE;
  else if (!task.assignee) state = TASK_BOARD_STATE.UNASSIGNED;
  else if (task.blockedBy) state = TASK_BOARD_STATE.BLOCKED;
  else if (activityAt !== null && now - activityAt <= IN_PROGRESS_WITHIN_SECS)
    state = TASK_BOARD_STATE.IN_PROGRESS;
  else state = TASK_BOARD_STATE.UP_NEXT;

  const quietFor = now - (activityAt ?? task.createdAt);
  const stalled =
    !task.closed &&
    Boolean(task.assignee) &&
    !task.blockedBy &&
    Boolean(task.assigneeSeatUp) &&
    // Nagging a seat that is mid-turn is the false alarm section 7 avoids. An
    // in-flight turn has published nothing yet, so it suppresses the nudge
    // without making the task In Progress.
    !task.assigneeTurnInFlight &&
    quietFor > STALL_AFTER_SECS;

  return { state, activityAt, stalled };
}
