/**
 * Tests for the NIP-AM usage presentation contract.
 *
 * The backend spends real effort keeping "not reported" distinct from "zero"
 * (`archive/agent_usage.rs`: a `UsageField` is `{ value, incomplete }`, and a
 * counter no harness reported comes back `value: null, incomplete: true`).
 * These tests bind that distinction to the production formatter — the one the
 * table cells call — so a `?? 0` anywhere in it fails here rather than
 * silently inventing a zero in the UI.
 */

// Pinned before the Date-dependent tests so the DST assertions describe a real
// transition instead of whatever the runner's ambient zone happens to be.
process.env.TZ = "America/New_York";

import assert from "node:assert/strict";
import test from "node:test";

import {
  buildAgentUsageNotices,
  buildLocalDayBoundaries,
  formatCostField,
  formatCount,
  formatCoverageSummary,
  formatTokenField,
  modelLabel,
  nextLocalMidnightMs,
  parseTokenValue,
  resolveAgentUsageState,
  startOfLocalDaySeconds,
} from "./agentUsageFormat.ts";

/** Digits only, so assertions survive any locale's grouping separator. */
function digits(text) {
  return text.replace(/[^0-9]/g, "");
}

function usage(overrides = {}) {
  const complete = (value) => ({ value, incomplete: false });
  return {
    inputTokens: complete("100"),
    outputTokens: complete("10"),
    totalTokens: complete("110"),
    estimatedCostUsd: { value: 1, incomplete: false },
    cacheReadTokens: complete("5"),
    cacheWriteTokens: complete("5"),
    freshInputTokens: complete("90"),
    ...overrides,
  };
}

function series(overrides = {}) {
  return {
    collectionEnabled: true,
    buckets: [],
    agents: [],
    coverage: {
      firstArchivedAt: null,
      lastArchivedAt: null,
      firstReportedAt: null,
      lastReportedAt: null,
      reportCount: 0,
      invalidReportCount: 0,
      hasUnknownUsage: false,
    },
    hasArchivedEvidence: null,
    ...overrides,
  };
}

function agent(overrides = {}) {
  return {
    agentPubkey: "a".repeat(64),
    usage: usage(),
    buckets: [],
    models: [],
    reportCount: 1,
    hasUnknownUsage: false,
    ...overrides,
  };
}

// ── Token fields: the four wire states ───────────────────────────────────────

test("token field with a complete value renders the exact number", () => {
  const cell = formatTokenField({ value: "1234567", incomplete: false });
  assert.equal(cell.kind, "exact");
  assert.equal(digits(cell.text), "1234567");
  assert.equal(cell.detail, null);
});

test("token field of exactly zero renders 0, because that zero is real", () => {
  const cell = formatTokenField({ value: "0", incomplete: false });
  assert.equal(cell.kind, "exact");
  assert.equal(cell.text, "0");
  assert.equal(cell.srText, "0");
});

test("unreported token field never renders as 0", () => {
  const cell = formatTokenField({ value: null, incomplete: false });
  assert.equal(cell.kind, "notReported");
  assert.notEqual(cell.text, "0");
  assert.equal(digits(cell.text), "");
  assert.equal(cell.srText, "Not reported");
  assert.match(cell.detail, /[Nn]ot the same as zero/);
});

test("unknown token field never renders as 0 and reads as unknown", () => {
  const cell = formatTokenField({ value: null, incomplete: true });
  assert.equal(cell.kind, "unknown");
  assert.equal(cell.text, "Unknown");
  assert.notEqual(cell.text, "0");
  assert.match(cell.detail, /not zero/);
});

test("unknown and not-reported are distinguishable, not one blank state", () => {
  const unknown = formatTokenField({ value: null, incomplete: true });
  const missing = formatTokenField({ value: null, incomplete: false });
  assert.notEqual(unknown.kind, missing.kind);
  assert.notEqual(unknown.text, missing.text);
  assert.notEqual(unknown.srText, missing.srText);
});

test("partial token field renders as a lower bound, not a total", () => {
  const cell = formatTokenField({ value: "4096", incomplete: true });
  assert.equal(cell.kind, "atLeast");
  assert.ok(
    cell.text.startsWith("≥ "),
    `expected a ≥ prefix, got ${cell.text}`,
  );
  assert.equal(digits(cell.text), "4096");
  assert.match(cell.srText, /^at least /);
  assert.match(cell.detail, /[Ll]ower bound/);
});

test("u64 token counts above 2^53 survive formatting exactly", () => {
  const cell = formatTokenField({
    value: "18446744073709551615",
    incomplete: false,
  });
  assert.equal(cell.kind, "exact");
  assert.equal(digits(cell.text), "18446744073709551615");
});

test("an unreadable token value degrades to unknown, not to zero", () => {
  for (const value of ["", "  12  ", "12.5", "-3", "0x10", "nope"]) {
    const cell = formatTokenField({ value, incomplete: false });
    assert.equal(cell.kind, "unknown", `value ${JSON.stringify(value)}`);
    assert.notEqual(cell.text, "0");
  }
});

test("a missing field object is unknown rather than zero", () => {
  assert.equal(formatTokenField(undefined).kind, "unknown");
  assert.equal(formatTokenField(null).kind, "unknown");
});

test("parseTokenValue accepts only plain non-negative integers", () => {
  assert.equal(parseTokenValue("42"), 42n);
  assert.equal(parseTokenValue(""), null);
  assert.equal(parseTokenValue("-1"), null);
  assert.equal(parseTokenValue("1e3"), null);
});

// ── Cost fields ──────────────────────────────────────────────────────────────

test("unreported and unknown costs never render as $0.00", () => {
  const missing = formatCostField({ value: null, incomplete: false });
  const unknown = formatCostField({ value: null, incomplete: true });
  assert.equal(missing.kind, "notReported");
  assert.equal(unknown.kind, "unknown");
  for (const cell of [missing, unknown]) {
    assert.equal(digits(cell.text), "");
  }
});

test("a real zero cost renders as a currency zero", () => {
  const cell = formatCostField({ value: 0, incomplete: false });
  assert.equal(cell.kind, "exact");
  assert.equal(digits(cell.text), "000");
});

test("sub-cent costs keep enough precision to differ from zero", () => {
  const cell = formatCostField({ value: 0.0042, incomplete: false });
  assert.equal(cell.kind, "exact");
  assert.equal(digits(cell.text), "00042");
  assert.notEqual(digits(cell.text), "000");
});

test("partial cost renders as a lower bound", () => {
  const cell = formatCostField({ value: 12.5, incomplete: true });
  assert.equal(cell.kind, "atLeast");
  assert.ok(cell.text.startsWith("≥ "));
  assert.equal(digits(cell.text), "1250");
});

test("a non-finite cost is unknown, not a rendered Infinity", () => {
  const cell = formatCostField({
    value: Number.POSITIVE_INFINITY,
    incomplete: false,
  });
  assert.equal(cell.kind, "unknown");
});

// ── Model labels ─────────────────────────────────────────────────────────────

test("model rows label both halves of the (harness, model) key", () => {
  assert.deepEqual(
    modelLabel({ harness: "claude-code", model: "opus", usage: usage() }),
    { model: "opus", harness: "claude-code" },
  );
  const unattributed = modelLabel({ harness: null, model: null });
  assert.equal(unattributed.model, "Unknown model");
  assert.equal(unattributed.harness, null);
});

test("formatCount groups plain cardinalities", () => {
  assert.equal(digits(formatCount(12345)), "12345");
});

// ── Panel state ──────────────────────────────────────────────────────────────

test("collection off with nothing archived is the disabled state", () => {
  assert.equal(
    resolveAgentUsageState(series({ collectionEnabled: false })),
    "disabled",
  );
});

test("collection on with nothing archived is the empty state, not disabled", () => {
  assert.equal(
    resolveAgentUsageState(series({ collectionEnabled: true })),
    "empty",
  );
});

test("archived rows are shown even after collection is switched off", () => {
  const withHistory = series({
    collectionEnabled: false,
    agents: [agent()],
    coverage: { ...series().coverage, reportCount: 1 },
  });
  assert.equal(resolveAgentUsageState(withHistory), "ready");
  const notices = buildAgentUsageNotices(withHistory);
  assert.deepEqual(
    notices.map((n) => n.id),
    ["collection-off"],
  );
});

test("a clean, complete series carries no caveats", () => {
  const clean = series({
    agents: [agent()],
    buckets: [
      {
        start: 0,
        end: 1,
        usage: usage(),
        reportCount: 1,
        hasUnknownUsage: false,
      },
    ],
    coverage: { ...series().coverage, reportCount: 1 },
  });
  assert.deepEqual(buildAgentUsageNotices(clean), []);
});

test("an agent with unknown usage raises the incomplete-coverage caveat", () => {
  const notices = buildAgentUsageNotices(
    series({ agents: [agent({ hasUnknownUsage: true })] }),
  );
  assert.deepEqual(
    notices.map((n) => n.id),
    ["partial-coverage"],
  );
  assert.match(notices[0].text, /not that it was zero/);
});

test("a bucket with unknown usage raises the caveat even when agents look clean", () => {
  const notices = buildAgentUsageNotices(
    series({
      agents: [agent()],
      buckets: [
        {
          start: 0,
          end: 1,
          usage: usage(),
          reportCount: 1,
          hasUnknownUsage: true,
        },
      ],
    }),
  );
  assert.deepEqual(
    notices.map((n) => n.id),
    ["partial-coverage"],
  );
});

test("unreadable archived events are reported separately from partial turns", () => {
  const one = buildAgentUsageNotices(
    series({ coverage: { ...series().coverage, invalidReportCount: 1 } }),
  );
  assert.deepEqual(
    one.map((n) => n.id),
    ["unreadable-events"],
  );
  assert.match(one[0].text, /1 archived metric event could not be read/);

  const many = buildAgentUsageNotices(
    series({ coverage: { ...series().coverage, invalidReportCount: 3 } }),
  );
  assert.match(many[0].text, /3 archived metric events could not be read/);
});

test("every caveat that applies is surfaced, not just the first", () => {
  const notices = buildAgentUsageNotices(
    series({
      collectionEnabled: false,
      agents: [agent({ hasUnknownUsage: true })],
      coverage: { ...series().coverage, reportCount: 2, invalidReportCount: 2 },
    }),
  );
  assert.deepEqual(
    notices.map((n) => n.id),
    ["collection-off", "partial-coverage", "unreadable-events"],
  );
});

// ── Coverage line ────────────────────────────────────────────────────────────

test("coverage summary is omitted when nothing was reported", () => {
  assert.equal(
    formatCoverageSummary(series(), () => "X"),
    null,
  );
});

test("coverage summary names the reported span, not the requested window", () => {
  const line = formatCoverageSummary(
    series({
      coverage: {
        ...series().coverage,
        reportCount: 12,
        firstReportedAt: 1_000,
        lastReportedAt: 2_000,
      },
    }),
    (seconds) => `T${seconds}`,
  );
  assert.equal(line, "12 turns archived between T1000 and T2000.");
});

test("coverage summary collapses a single-day span", () => {
  const line = formatCoverageSummary(
    series({
      coverage: {
        ...series().coverage,
        reportCount: 1,
        firstReportedAt: 1_000,
        lastReportedAt: 1_500,
      },
    }),
    () => "Jun 3",
  );
  assert.equal(line, "1 turn archived on Jun 3.");
});

// ── Bucket boundaries ────────────────────────────────────────────────────────

test("boundaries describe N buckets ending at tomorrow's local midnight", () => {
  const now = new Date(2026, 5, 14, 13, 45, 30);
  const boundaries = buildLocalDayBoundaries(now, 7);
  assert.equal(boundaries.length, 8);
  assert.equal(
    boundaries[7],
    Math.floor(new Date(2026, 5, 15).getTime() / 1_000),
    "last boundary is tomorrow's midnight so today-so-far is inside the window",
  );
  assert.equal(
    boundaries[0],
    Math.floor(new Date(2026, 5, 8).getTime() / 1_000),
  );
});

test("boundaries satisfy the backend's validation contract", () => {
  const boundaries = buildLocalDayBoundaries(new Date(2026, 2, 12, 9), 30);
  assert.equal(boundaries.length, 31);
  for (let i = 0; i < boundaries.length - 1; i += 1) {
    const interval = boundaries[i + 1] - boundaries[i];
    assert.ok(interval > 0, `boundary ${i} must be strictly increasing`);
    assert.ok(interval <= 48 * 3600, `boundary ${i} interval exceeds 48h`);
  }
});

test("every boundary lands on local midnight", () => {
  const boundaries = buildLocalDayBoundaries(new Date(2026, 2, 12, 9), 30);
  for (const boundary of boundaries) {
    const local = new Date(boundary * 1_000);
    assert.equal(local.getHours(), 0);
    assert.equal(local.getMinutes(), 0);
    assert.equal(local.getSeconds(), 0);
  }
});

test("a DST day is 23 or 25 hours long, not a fixed 86400 step", () => {
  // 2026-03-08 (spring forward) and 2026-11-01 (fall back) in America/New_York.
  // The first bucket of each window is the transition day itself.
  const spring = buildLocalDayBoundaries(new Date(2026, 2, 9, 12), 2);
  assert.equal(spring[1] - spring[0], 23 * 3600);
  assert.equal(spring[2] - spring[1], 24 * 3600);

  const fall = buildLocalDayBoundaries(new Date(2026, 10, 2, 12), 2);
  assert.equal(fall[1] - fall[0], 25 * 3600);
  assert.equal(fall[2] - fall[1], 24 * 3600);
});

test("buildLocalDayBoundaries rejects a window that describes no bucket", () => {
  assert.throws(
    () => buildLocalDayBoundaries(new Date(), 0),
    /positive integer/,
  );
  assert.throws(
    () => buildLocalDayBoundaries(new Date(), 1.5),
    /positive integer/,
  );
});

test("startOfLocalDaySeconds and nextLocalMidnightMs agree across a DST day", () => {
  const during = new Date(2026, 2, 8, 14, 0, 0);
  const start = startOfLocalDaySeconds(Math.floor(during.getTime() / 1_000));
  assert.equal(start, Math.floor(new Date(2026, 2, 8).getTime() / 1_000));
  assert.equal(
    nextLocalMidnightMs(during),
    new Date(2026, 2, 9).getTime(),
    "next midnight is the next calendar day, not +24h",
  );
  assert.equal((nextLocalMidnightMs(during) / 1_000 - start) / 3600, 23);
});
