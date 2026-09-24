/**
 * Presentation logic for the locally archived NIP-AM agent usage series.
 *
 * The backend (`desktop/src-tauri/src/archive/agent_usage.rs`) deliberately
 * keeps "not reported" distinct from "zero": every counter crosses the wire as
 * `{ value: string | null, incomplete: boolean }`, and the four combinations
 * mean four different things. This module is the only place that decision is
 * turned into text, so no component can quietly collapse a missing count into
 * `0` with a `?? 0`.
 *
 * Token counters are `u64` decimal strings — parsed with `BigInt`, never
 * `Number`, so a value above 2^53 is rendered exactly rather than rounded.
 */

import type {
  AgentUsageModel,
  AgentUsageSeries,
  CostField,
  UsageField,
} from "@/shared/api/tauriArchive";

// ── Cells ────────────────────────────────────────────────────────────────────

/**
 * How one counter should read.
 *
 * - `exact` — every turn in scope reported it; the number is complete.
 * - `atLeast` — a partial sum: at least one turn contributed nothing usable,
 *   so the number is a lower bound (`incomplete: true` with a value).
 * - `unknown` — turns exist in scope but none produced a usable value. This is
 *   the case the "never render a missing count as 0" rule is about.
 * - `notReported` — nothing in scope carried this counter at all.
 */
export type UsageCellKind = "exact" | "atLeast" | "unknown" | "notReported";

export type UsageCell = {
  kind: UsageCellKind;
  /** Visible text. `0` appears only when the backend reported an exact zero. */
  text: string;
  /** Spoken text — the visible glyphs (`—`, `≥`) do not read aloud usefully. */
  srText: string;
  /** Provenance sentence for a `title`, or `null` when the value is complete. */
  detail: string | null;
};

const NOT_REPORTED_GLYPH = "—";

const tokenFormatter = new Intl.NumberFormat(undefined, { useGrouping: true });

const usdFormatter = new Intl.NumberFormat(undefined, {
  style: "currency",
  currency: "USD",
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

/**
 * Sub-cent costs are the common case for a single turn, and a 2-decimal
 * formatter renders every one of them as `$0.00` — indistinguishable from a
 * genuine zero, which is exactly the collapse this module exists to prevent.
 */
const usdPreciseFormatter = new Intl.NumberFormat(undefined, {
  style: "currency",
  currency: "USD",
  minimumFractionDigits: 4,
  maximumFractionDigits: 4,
});

const UNSIGNED_INTEGER = /^\d+$/;

const DETAIL_LOWER_BOUND =
  "Lower bound: some archived turns in this window did not report this counter.";
const DETAIL_UNKNOWN =
  "Unknown, not zero: turns were archived in this window, but none reported a usable value for this counter.";
const DETAIL_NOT_REPORTED =
  "Nothing in this window reported this counter. Not the same as zero.";
const DETAIL_UNREADABLE =
  "The archive reported a value for this counter that could not be read.";

function notReportedCell(): UsageCell {
  return {
    kind: "notReported",
    text: NOT_REPORTED_GLYPH,
    srText: "Not reported",
    detail: DETAIL_NOT_REPORTED,
  };
}

function unknownCell(detail: string = DETAIL_UNKNOWN): UsageCell {
  return { kind: "unknown", text: "Unknown", srText: "Unknown", detail };
}

/**
 * Parse a wire token counter. Returns `null` for anything that is not a plain
 * non-negative integer string, which the caller renders as unknown — never as
 * zero.
 */
export function parseTokenValue(raw: string): bigint | null {
  if (!UNSIGNED_INTEGER.test(raw)) return null;
  try {
    return BigInt(raw);
  } catch {
    return null;
  }
}

/** Render one `UsageField` (a `u64` token counter) honestly. */
export function formatTokenField(
  field: UsageField | null | undefined,
): UsageCell {
  if (!field) return unknownCell(DETAIL_UNREADABLE);
  if (field.value === null) {
    return field.incomplete ? unknownCell() : notReportedCell();
  }
  const parsed = parseTokenValue(field.value);
  if (parsed === null) return unknownCell(DETAIL_UNREADABLE);

  const formatted = tokenFormatter.format(parsed);
  if (field.incomplete) {
    return {
      kind: "atLeast",
      text: `≥ ${formatted}`,
      srText: `at least ${formatted}`,
      detail: DETAIL_LOWER_BOUND,
    };
  }
  return { kind: "exact", text: formatted, srText: formatted, detail: null };
}

/**
 * Group-separated plain count (turn counts, event counts). These are `i64`
 * cardinalities the backend always knows, so they carry no completeness
 * question and never need a `UsageCell`.
 */
export function formatCount(value: number): string {
  return tokenFormatter.format(value);
}

function formatUsd(value: number): string {
  const magnitude = Math.abs(value);
  const formatter =
    magnitude > 0 && magnitude < 0.01 ? usdPreciseFormatter : usdFormatter;
  return formatter.format(value);
}

/** Render one `CostField` (an `f64` USD estimate) honestly. */
export function formatCostField(
  field: CostField | null | undefined,
): UsageCell {
  if (!field) return unknownCell(DETAIL_UNREADABLE);
  if (field.value === null) {
    return field.incomplete ? unknownCell() : notReportedCell();
  }
  if (!Number.isFinite(field.value)) return unknownCell(DETAIL_UNREADABLE);

  const formatted = formatUsd(field.value);
  if (field.incomplete) {
    return {
      kind: "atLeast",
      text: `≥ ${formatted}`,
      srText: `at least ${formatted}`,
      detail: DETAIL_LOWER_BOUND,
    };
  }
  return { kind: "exact", text: formatted, srText: formatted, detail: null };
}

// ── Model labels ─────────────────────────────────────────────────────────────

export type ModelLabel = {
  /** Model name, or an explicit unknown marker — never a blank cell. */
  model: string;
  /** Harness that produced the turns, or `null` when it was not reported. */
  harness: string | null;
};

/**
 * The backend keys model rows by `(harness, model)`, and either half can be
 * `null` when the harness did not report it. Both halves are labelled rather
 * than blanked so an unattributed row is visibly unattributed.
 */
export function modelLabel(row: AgentUsageModel): ModelLabel {
  return {
    model: row.model ?? "Unknown model",
    harness: row.harness,
  };
}

// ── Window state ─────────────────────────────────────────────────────────────

/**
 * The three honest outcomes this panel can be in, which the product
 * requirement insists must read differently:
 *
 * - `disabled` — turn-metric archiving is off and nothing was ever archived.
 * - `empty` — archiving is on, but no turn landed inside this window.
 * - `ready` — there is something to show (possibly with partial coverage, and
 *   possibly historical data with archiving now switched off).
 */
export type AgentUsageStateKind = "disabled" | "empty" | "ready";

export function resolveAgentUsageState(
  series: AgentUsageSeries,
): AgentUsageStateKind {
  const hasRows = series.agents.length > 0 || series.coverage.reportCount > 0;
  if (hasRows) return "ready";
  // Archiving off with nothing archived is a different problem (and a
  // different fix) from archiving on with nothing collected yet.
  return series.collectionEnabled ? "empty" : "disabled";
}

export type UsageNotice = {
  id: "collection-off" | "partial-coverage" | "unreadable-events";
  tone: "info" | "warning";
  text: string;
};

/**
 * Caveats that must travel with the numbers. `hasUnknownUsage` on the series
 * coverage folds in `invalidReportCount`, so the two causes are separated here
 * rather than reported as one undifferentiated "something is missing".
 */
export function buildAgentUsageNotices(
  series: AgentUsageSeries,
): UsageNotice[] {
  const notices: UsageNotice[] = [];

  if (!series.collectionEnabled) {
    notices.push({
      id: "collection-off",
      tone: "warning",
      text: "Turn-metric archiving is off, so nothing new is being recorded. These totals cover turns archived earlier.",
    });
  }

  const partialTurns =
    series.agents.some((agent) => agent.hasUnknownUsage) ||
    series.buckets.some((bucket) => bucket.hasUnknownUsage);
  if (partialTurns) {
    notices.push({
      id: "partial-coverage",
      tone: "warning",
      text: 'Coverage is incomplete. A "≥" total is a lower bound, and "Unknown" means the counter was never reported — not that it was zero.',
    });
  }

  const invalid = series.coverage.invalidReportCount;
  if (invalid > 0) {
    notices.push({
      id: "unreadable-events",
      tone: "warning",
      text: `${invalid} archived metric ${invalid === 1 ? "event" : "events"} could not be read and ${invalid === 1 ? "is" : "are"} excluded from every total below.`,
    });
  }

  return notices;
}

/**
 * One line of provenance: how many turns these totals rest on, and the span
 * they were actually reported over (which can be narrower than the window).
 */
export function formatCoverageSummary(
  series: AgentUsageSeries,
  formatDate: (unixSeconds: number) => string,
): string | null {
  const { reportCount, firstReportedAt, lastReportedAt } = series.coverage;
  if (reportCount === 0) return null;

  const turns = `${tokenFormatter.format(reportCount)} ${reportCount === 1 ? "turn" : "turns"}`;
  if (firstReportedAt === null || lastReportedAt === null) {
    return `${turns} archived.`;
  }
  const first = formatDate(firstReportedAt);
  const last = formatDate(lastReportedAt);
  return first === last
    ? `${turns} archived on ${first}.`
    : `${turns} archived between ${first} and ${last}.`;
}

// ── Local-day bucket boundaries ──────────────────────────────────────────────

/** Local midnight of the calendar day containing `unixSeconds`. */
export function startOfLocalDaySeconds(unixSeconds: number): number {
  const date = new Date(unixSeconds * 1_000);
  return Math.floor(
    new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime() /
      1_000,
  );
}

/** Local midnight of the day after the one containing `date`. */
export function nextLocalMidnightMs(date: Date): number {
  return new Date(
    date.getFullYear(),
    date.getMonth(),
    date.getDate() + 1,
  ).getTime();
}

/**
 * `days + 1` exact local-midnight boundaries ending at tomorrow's midnight, so
 * the last bucket is today-so-far and the request covers `days` civil days.
 *
 * Each step is built by advancing the *calendar day* and re-deriving the
 * instant, never by adding `86_400`: a DST day is 23 or 25 hours long and a
 * fixed-seconds ladder would drift off midnight and mis-bucket every later
 * day. The backend validates the same shape (strictly increasing, no interval
 * above 48h), so a drifting ladder would eventually be rejected outright.
 */
export function buildLocalDayBoundaries(now: Date, days: number): number[] {
  if (!Number.isInteger(days) || days < 1) {
    throw new Error(`days must be a positive integer, got ${days}`);
  }
  const firstDay = now.getDate() - (days - 1);
  const boundaries: number[] = [];
  for (let offset = 0; offset <= days; offset += 1) {
    const boundary = new Date(
      now.getFullYear(),
      now.getMonth(),
      firstDay + offset,
    );
    boundaries.push(Math.floor(boundary.getTime() / 1_000));
  }
  return boundaries;
}
