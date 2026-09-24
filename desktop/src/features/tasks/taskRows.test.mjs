import assert from "node:assert/strict";
import test from "node:test";

import {
  groupTaskRows,
  lastActivity,
  linksFor,
  taskRowsFrom,
  threadKeyOf,
} from "./taskRows.mjs";

const ISSUE = "b".repeat(64);
const THREAD = "c".repeat(64);
const ME = "a".repeat(64);
const NOW = 1790200000;

function issue(overrides = {}) {
  return {
    id: ISSUE,
    title: "ship the thing",
    content: "body",
    author: ME,
    createdAt: 1790100000,
    labels: ["task"],
    assignees: [ME],
    status: "Backlog",
    comments: [],
    ...overrides,
  };
}

function linkNote(label, target, issueId = ISSUE) {
  return {
    id: "d".repeat(64),
    kind: 1,
    pubkey: ME,
    created_at: 1790100500,
    content: "",
    tags: [
      ["e", issueId, "", "root"],
      ["t", label],
      ["e", target, "", "mention"],
    ],
  };
}

function post(createdAt, thread = THREAD, pubkey = ME, content = "on it") {
  return {
    id: "e".repeat(64),
    kind: 9,
    pubkey,
    created_at: createdAt,
    content,
    tags: [["e", thread, "", "root"]],
  };
}

test("an unlabelled issue is not a task", () => {
  const rows = taskRowsFrom({ issues: [issue({ labels: ["bug"] })], now: NOW });
  assert.deepEqual(rows, []);
});

test("a task with a linked thread and a recent post is In Progress", () => {
  const rows = taskRowsFrom({
    issues: [issue()],
    linkNotes: [linkNote("task-thread", THREAD)],
    threadPosts: [post(1790199000)],
    now: NOW,
  });
  assert.equal(rows.length, 1);
  assert.equal(rows[0].state, "In Progress");
  assert.equal(rows[0].activityAt, 1790199000);
  assert.deepEqual(rows[0].linkedThreads, [THREAD]);
});

test("the same post in an unlinked thread leaves it Up Next", () => {
  const rows = taskRowsFrom({
    issues: [issue()],
    linkNotes: [],
    threadPosts: [post(1790199000)],
    now: NOW,
  });
  assert.equal(rows[0].state, "Up Next");
  assert.equal(rows[0].activityAt, null);
});

test("a task nobody owns is Unassigned, which outranks Up Next", () => {
  const rows = taskRowsFrom({ issues: [issue({ assignees: [] })], now: NOW });
  assert.equal(rows[0].state, "Unassigned");
});

test("a blocked task stays Blocked even with recent activity", () => {
  const rows = taskRowsFrom({
    issues: [issue()],
    linkNotes: [
      linkNote("task-thread", THREAD),
      linkNote("blocked-by", "9".repeat(64)),
    ],
    threadPosts: [post(1790199000)],
    now: NOW,
  });
  assert.equal(rows[0].state, "Blocked");
  assert.equal(rows[0].blockedBy, "9".repeat(64));
});

test("a NIP-22 comment counts as activity without any linked thread", () => {
  const rows = taskRowsFrom({
    issues: [
      issue({
        comments: [
          { author: ME, createdAt: 1790198000, content: "root-caused" },
        ],
      }),
    ],
    now: NOW,
  });
  assert.equal(rows[0].state, "In Progress");
  assert.equal(rows[0].activityAt, 1790198000);
});

test("a link note belonging to another issue is ignored", () => {
  const { threads } = linksFor(ISSUE, [
    linkNote("task-thread", THREAD, "f".repeat(64)),
  ]);
  assert.deepEqual(threads, []);
});

test("an assignment note is not a link", () => {
  const note = {
    id: "d".repeat(64),
    kind: 1,
    pubkey: ME,
    created_at: 1,
    tags: [
      ["e", ISSUE, "", "root"],
      ["p", ME],
      ["t", "assignment"],
    ],
  };
  assert.deepEqual(linksFor(ISSUE, [note]), { threads: [], blockedBy: null });
});

test("a post's thread key is its root marker, then its first e, then itself", () => {
  const marked = {
    id: "z".repeat(64),
    tags: [
      ["e", "1".repeat(64)],
      ["e", THREAD, "", "root"],
    ],
  };
  assert.equal(threadKeyOf(marked), THREAD);
  const unmarked = { id: "z".repeat(64), tags: [["e", "1".repeat(64)]] };
  assert.equal(threadKeyOf(unmarked), "1".repeat(64));
  const top = { id: "z".repeat(64), tags: [["h", "channel"]] };
  assert.equal(threadKeyOf(top), "z".repeat(64));
});

test("Done is behind the toggle and the groups come out in reading order", () => {
  const rows = taskRowsFrom({
    issues: [
      issue({ id: "1".repeat(64), status: "Closed" }),
      issue({ id: "2".repeat(64), assignees: [] }),
      issue({ id: "3".repeat(64) }),
    ],
    now: NOW,
  });

  const shown = groupTaskRows(rows);
  assert.deepEqual(
    shown.map((g) => g.name),
    ["Unassigned", "Up Next"],
    "Done hidden, and Unassigned pinned above Up Next",
  );

  const all = groupTaskRows(rows, { showDone: true });
  assert.deepEqual(
    all.map((g) => g.name),
    ["Unassigned", "Up Next", "Done"],
  );
});

// `lastActivity` lives here, not in the view: it is the one derived string on
// the screen, and a task with no activity must say so rather than borrowing
// its creation time — otherwise a brand-new task reads as if somebody just
// touched it.
test("last activity is coarse, relative, and honest about having none", () => {
  assert.equal(
    lastActivity({ activityAt: null, createdAt: 1 }, NOW),
    "no activity yet",
  );
  assert.equal(
    lastActivity({ activityAt: NOW - 300, createdAt: 1 }, NOW),
    "5m ago",
  );
  assert.equal(
    lastActivity({ activityAt: NOW - 7200, createdAt: 1 }, NOW),
    "2h ago",
  );
  assert.equal(
    lastActivity({ activityAt: NOW - 3 * 86400, createdAt: 1 }, NOW),
    "3d ago",
  );
  assert.equal(
    lastActivity({ activityAt: NOW + 60, createdAt: 1 }, NOW),
    "0m ago",
    "a clock that ran backwards must not print a negative age",
  );
});
