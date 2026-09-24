import assert from "node:assert/strict";
import test from "node:test";

import {
  describeTurnReceipt,
  formatTurnReceiptCounts,
} from "./turnReceiptFormat.ts";

function receipt(overrides = {}) {
  return {
    id: "9".repeat(64),
    model: "claude-opus-4-5",
    harness: "claude-agent-acp",
    inputTokens: 191261,
    outputTokens: 683,
    cacheReadTokens: 122407,
    cacheWriteTokens: 4096,
    ...overrides,
  };
}

function cell(counts, key) {
  return counts.find((count) => count.key === key);
}

test("every reported count renders as a grouped number", () => {
  const counts = formatTurnReceiptCounts(receipt());
  assert.equal(cell(counts, "input").kind, "exact");
  assert.equal(cell(counts, "input").text, "191,261");
  assert.equal(cell(counts, "output").text, "683");
  assert.equal(cell(counts, "cacheRead").text, "122,407");
  assert.equal(cell(counts, "cacheWrite").text, "4,096");
});

test("a null count never renders as 0", () => {
  const counts = formatTurnReceiptCounts(
    receipt({ cacheReadTokens: null, cacheWriteTokens: null }),
  );
  for (const key of ["cacheRead", "cacheWrite"]) {
    const missing = cell(counts, key);
    assert.equal(missing.kind, "notReported");
    assert.notEqual(missing.text, "0");
    assert.equal(missing.text, "—");
    assert.ok(
      missing.detail?.includes("Not the same as zero"),
      "a missing count explains itself",
    );
  }
});

test("a genuine zero renders as 0 and is not confused with unreported", () => {
  const counts = formatTurnReceiptCounts(receipt({ cacheWriteTokens: 0 }));
  const zero = cell(counts, "cacheWrite");
  assert.equal(zero.kind, "exact");
  assert.equal(zero.text, "0");
  assert.equal(zero.detail, null);
});

test("every counter appears even when unreported, so no absence reads as zero", () => {
  const counts = formatTurnReceiptCounts(
    receipt({
      inputTokens: null,
      outputTokens: null,
      cacheReadTokens: null,
      cacheWriteTokens: null,
    }),
  );
  assert.deepEqual(
    counts.map((count) => count.key),
    ["input", "output", "cacheRead", "cacheWrite"],
  );
  assert.ok(counts.every((count) => count.kind === "notReported"));
});

test("the spoken sentence names each counter instead of reading bare numbers", () => {
  const spoken = describeTurnReceipt(
    receipt({ cacheWriteTokens: null }),
    "Opus 4.5",
  );
  assert.ok(spoken.includes("ran on Opus 4.5"), spoken);
  assert.ok(spoken.includes("191,261 input tokens"), spoken);
  assert.ok(spoken.includes("683 output tokens"), spoken);
  assert.ok(spoken.includes("cache write tokens not reported"), spoken);
  // The visible em dash never reaches the screen reader.
  assert.ok(!spoken.includes("—"), spoken);
});
