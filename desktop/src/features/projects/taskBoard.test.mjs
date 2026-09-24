import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  deriveTaskBoardState,
  FAILURE_NOTICE_PREFIX,
  IN_PROGRESS_WITHIN_SECS,
  STALL_AFTER_SECS,
  WATCHDOG_PUBKEY,
} from "./taskBoard.mjs";

// The same oracle `crates/buzz-core/src/task_board.rs` reads. A divergence
// between this surface and `buzz tasks board` fails here, not in Lloyd's tab.
const FIXTURE = JSON.parse(
  readFileSync(
    new URL("../../../../test-fixtures/task-board-state.json", import.meta.url),
    "utf8",
  ),
);

test("every fixture case derives what it says", () => {
  assert.ok(FIXTURE.cases.length >= 12, "the fixture lost cases");
  for (const c of FIXTURE.cases) {
    const task = {
      createdAt: c.task.createdAt,
      closed: c.task.status === "closed",
      assignee: c.task.assignee,
      blockedBy: c.task.blockedBy,
      linkedThreads: c.links
        .filter((l) => l.kind === "task-thread")
        .map((l) => l.target),
      posts: [
        ...c.posts.map((p) => ({
          thread: p.thread,
          pubkey: p.pubkey,
          createdAt: p.createdAt,
          content: p.content,
        })),
        ...c.comments.map((m) => ({
          thread: null,
          pubkey: m.pubkey,
          createdAt: m.createdAt,
          content: m.content,
        })),
      ],
      assigneeSeatUp: c.assigneeSeatUp,
      assigneeTurnInFlight: c.assigneeTurnInFlight,
    };

    const got = deriveTaskBoardState(task, c.now);
    assert.equal(got.state, c.expect.state, `${c.name}: state`);
    assert.equal(got.activityAt, c.expect.activityAt, `${c.name}: activityAt`);
    assert.equal(got.stalled, c.expect.stalled, `${c.name}: stalled`);
  }
});

// A drift between the fixture's constants and this module's would change which
// posts count as activity while every case still passed, because both sides
// would have moved together.
test("the fixture and this module agree on the exclusions", () => {
  const c = FIXTURE.constants;
  assert.equal(c.failure_notice_prefix, FAILURE_NOTICE_PREFIX);
  assert.equal(c.watchdog_pubkey, WATCHDOG_PUBKEY);
  assert.equal(c.stall_after_secs, STALL_AFTER_SECS);
  assert.equal(c.in_progress_within_secs, IN_PROGRESS_WITHIN_SECS);
});
