/**
 * NIP-AR receipt parsing, trust, and anchor selection.
 *
 * The two rules under test are the ones the NIP calls mandatory, and both
 * fail silently if broken: a forged receipt renders attacker-supplied numbers
 * under someone else's name, and a per-message render multiplies one turn's
 * spend by however many messages it happened to split into.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  isNewerTurnReceipt,
  parseTurnReceiptEvent,
  selectTurnReceiptAnchor,
} from "./agentTurnReceipt.ts";
import { KIND_AGENT_TURN_RECEIPT } from "@/shared/constants/kinds";

const CHANNEL_ID = "36411e44-0e2d-4cfe-bd6e-567eb169db9f";
const AGENT_PUBKEY = "a".repeat(64);
const STRANGER_PUBKEY = "f".repeat(64);
const MSG_1 = "1".repeat(64);
const MSG_2 = "2".repeat(64);
const MSG_3 = "3".repeat(64);

function receiptEvent(overrides = {}) {
  const {
    targets = [MSG_1],
    model = "claude-opus-4-5",
    modelTag = model,
    turn = { inputTokens: 191261, outputTokens: 683, cacheReadTokens: 122407 },
    harness = "claude-agent-acp",
    content,
    ...rest
  } = overrides;
  return {
    id: "9".repeat(64),
    pubkey: AGENT_PUBKEY,
    kind: KIND_AGENT_TURN_RECEIPT,
    created_at: 1_700_000_100,
    content: content ?? JSON.stringify({ model, harness, turn }),
    tags: [
      ["h", CHANNEL_ID],
      ...targets.map((id) => ["e", id]),
      ["model", modelTag],
    ],
    sig: "sig",
    ...rest,
  };
}

function message(id, pubkey = AGENT_PUBKEY) {
  return {
    id,
    pubkey,
    kind: 9,
    created_at: 1_700_000_000,
    content: "hi",
    tags: [["h", CHANNEL_ID]],
    sig: "sig",
  };
}

function anchorFor(event, held) {
  const parsed = parseTurnReceiptEvent(event);
  if (!parsed) return null;
  const byId = new Map(held.map((m) => [m.id, m]));
  return selectTurnReceiptAnchor({
    parsed,
    receiptPubkey: event.pubkey,
    getHeldEvent: (id) => byId.get(id),
    resolveAuthor: (target) => target.pubkey,
  });
}

test("a receipt carries the model, harness, and every reported count", () => {
  const parsed = parseTurnReceiptEvent(receiptEvent());
  assert.equal(parsed.receipt.model, "claude-opus-4-5");
  assert.equal(parsed.receipt.harness, "claude-agent-acp");
  assert.equal(parsed.receipt.inputTokens, 191261);
  assert.equal(parsed.receipt.outputTokens, 683);
  assert.equal(parsed.receipt.cacheReadTokens, 122407);
  assert.deepEqual(parsed.targetIds, [MSG_1]);
});

test("a count the harness did not report parses as null, never as zero", () => {
  const parsed = parseTurnReceiptEvent(
    receiptEvent({ turn: { inputTokens: 10, outputTokens: null } }),
  );
  assert.equal(parsed.receipt.inputTokens, 10);
  assert.equal(parsed.receipt.outputTokens, null);
  // Omitted entirely (the NIP's shape for unobservable cache counters).
  assert.equal(parsed.receipt.cacheReadTokens, null);
  assert.equal(parsed.receipt.cacheWriteTokens, null);
});

test("a genuine zero count survives parsing as zero", () => {
  const parsed = parseTurnReceiptEvent(
    receiptEvent({ turn: { inputTokens: 0, cacheWriteTokens: 0 } }),
  );
  assert.equal(parsed.receipt.inputTokens, 0);
  assert.equal(parsed.receipt.cacheWriteTokens, 0);
});

test("a count that is not a non-negative integer is treated as unreported", () => {
  for (const bad of ["1000", -5, 1.5, Number.NaN, Number.POSITIVE_INFINITY]) {
    const parsed = parseTurnReceiptEvent(
      receiptEvent({ turn: { inputTokens: bad } }),
    );
    assert.equal(parsed.receipt.inputTokens, null, `${String(bad)}`);
  }
});

test("a receipt with no e tags, no model, or unparseable content is rejected", () => {
  assert.equal(parseTurnReceiptEvent(receiptEvent({ targets: [] })), null);
  assert.equal(parseTurnReceiptEvent(receiptEvent({ model: "  " })), null);
  assert.equal(parseTurnReceiptEvent(receiptEvent({ harness: "" })), null);
  assert.equal(
    parseTurnReceiptEvent(receiptEvent({ content: "not json" })),
    null,
  );
  assert.equal(parseTurnReceiptEvent({ ...receiptEvent(), kind: 9 }), null);
});

test("a receipt whose model tag disagrees with its body is rejected", () => {
  assert.equal(
    parseTurnReceiptEvent(
      receiptEvent({ model: "claude-opus-4-5", modelTag: "claude-haiku-4-5" }),
    ),
    null,
  );
});

test("a receipt whose e tag carries a NIP-10 marker is rejected", () => {
  // The predicate that channel-scopes 44201 is the same one that resolves
  // thread ancestry, so a marked tag would make a receipt a reply and inflate
  // the annotated message's reply_count. The relay refuses it at ingest; both
  // clients refuse it too, so neither depends on that and neither drifts.
  const marked = receiptEvent();
  marked.tags = marked.tags.map((tag) =>
    tag[0] === "e" ? [tag[0], tag[1], "", "reply"] : tag,
  );
  assert.equal(parseTurnReceiptEvent(marked), null);

  // An unmarked tag with a relay hint is still a plain reference.
  const hinted = receiptEvent();
  hinted.tags = hinted.tags.map((tag) =>
    tag[0] === "e" ? [tag[0], tag[1], "wss://relay.example"] : tag,
  );
  assert.notEqual(parseTurnReceiptEvent(hinted), null);
});

test("a receipt from a different pubkey than the message author is ignored", () => {
  const forged = receiptEvent({ pubkey: STRANGER_PUBKEY, targets: [MSG_1] });
  assert.equal(anchorFor(forged, [message(MSG_1, AGENT_PUBKEY)]), null);
});

test("a three-message turn anchors once, under the last message held", () => {
  const event = receiptEvent({ targets: [MSG_1, MSG_2, MSG_3] });
  const held = [message(MSG_1), message(MSG_2), message(MSG_3)];
  assert.equal(anchorFor(event, held), MSG_3);
});

test("a turn whose last messages are missing anchors to the last one held", () => {
  const event = receiptEvent({ targets: [MSG_1, MSG_2, MSG_3] });
  assert.equal(anchorFor(event, [message(MSG_1), message(MSG_2)]), MSG_2);
});

test("a receipt naming no message this client holds anchors nowhere", () => {
  const event = receiptEvent({ targets: [MSG_1, MSG_2] });
  assert.equal(anchorFor(event, []), null);
});

test("duplicate e tags do not change which message a receipt anchors to", () => {
  const event = receiptEvent({ targets: [MSG_1, MSG_2, MSG_1] });
  const parsed = parseTurnReceiptEvent(event);
  assert.deepEqual(parsed.targetIds, [MSG_1, MSG_2]);
  assert.equal(anchorFor(event, [message(MSG_1), message(MSG_2)]), MSG_2);
});

test("the newer of two receipts wins the same anchor, order-independently", () => {
  const older = parseTurnReceiptEvent(receiptEvent({ created_at: 10 }));
  const newer = parseTurnReceiptEvent(
    receiptEvent({ created_at: 20, id: "8".repeat(64) }),
  );
  assert.equal(isNewerTurnReceipt(newer, older), true);
  assert.equal(isNewerTurnReceipt(older, newer), false);
  // Same second: the id breaks the tie both ways, so delivery order cannot
  // decide which receipt is displayed.
  const tieA = parseTurnReceiptEvent(
    receiptEvent({ created_at: 10, id: "7".repeat(64) }),
  );
  const tieB = parseTurnReceiptEvent(
    receiptEvent({ created_at: 10, id: "8".repeat(64) }),
  );
  assert.equal(isNewerTurnReceipt(tieB, tieA), true);
  assert.equal(isNewerTurnReceipt(tieA, tieB), false);
});
