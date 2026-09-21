/**
 * The predicate `MessageRow`'s `React.memo` actually runs.
 *
 * A hand-written comparator fails silently in one direction: a rendered
 * `message.*` field it forgets to compare simply never updates on screen. The
 * NIP-AR receipt is the worst case for that, because the NIP requires the
 * receipt to be published *after* the messages it names — so it always arrives
 * as a second render of an already-memoized row. Deleting the
 * `turnReceiptEqual` line from `messageRowPropsEqual` must fail here.
 */

import assert from "node:assert/strict";
import test from "node:test";

import { messageRowPropsEqual } from "./messageRowPropsEqual.ts";

function message(overrides = {}) {
  return {
    id: "1".repeat(64),
    createdAt: 1_700_000_000,
    pubkey: "a".repeat(64),
    author: "claude",
    time: "9:53 AM",
    body: "done",
    depth: 0,
    ...overrides,
  };
}

function receipt(overrides = {}) {
  return {
    id: "9".repeat(64),
    model: "claude-opus-4-5",
    harness: "claude-agent-acp",
    inputTokens: 191261,
    outputTokens: 683,
    cacheReadTokens: 122407,
    cacheWriteTokens: null,
    ...overrides,
  };
}

test("a row with unchanged values stays memoized across a fresh format pass", () => {
  assert.equal(
    messageRowPropsEqual(
      { message: message({ turnReceipt: receipt() }) },
      { message: message({ turnReceipt: receipt() }) },
    ),
    true,
  );
});

test("a receipt arriving after its message re-renders the row", () => {
  assert.equal(
    messageRowPropsEqual(
      { message: message() },
      { message: message({ turnReceipt: receipt() }) },
    ),
    false,
  );
});

test("a receipt disappearing re-renders the row", () => {
  assert.equal(
    messageRowPropsEqual(
      { message: message({ turnReceipt: receipt() }) },
      { message: message() },
    ),
    false,
  );
});

test("any changed receipt field re-renders the row", () => {
  const changes = [
    { id: "8".repeat(64) },
    { model: "claude-haiku-4-5" },
    { harness: "goose" },
    { inputTokens: 191262 },
    { outputTokens: 684 },
    { cacheReadTokens: 1 },
    // null → 0 is the exact collapse the presentation layer forbids; the
    // comparator must see it as a change, not as "both falsy".
    { cacheWriteTokens: 0 },
  ];
  for (const change of changes) {
    assert.equal(
      messageRowPropsEqual(
        { message: message({ turnReceipt: receipt() }) },
        { message: message({ turnReceipt: receipt(change) }) },
      ),
      false,
      `changing ${Object.keys(change)[0]} must re-render`,
    );
  }
});

test("an unrelated prop change still re-renders the row", () => {
  const props = { message: message({ turnReceipt: receipt() }) };
  assert.equal(
    messageRowPropsEqual(props, { ...props, isUnread: true }),
    false,
  );
});
