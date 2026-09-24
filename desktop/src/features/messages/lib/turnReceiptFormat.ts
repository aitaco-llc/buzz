/**
 * Presentation logic for a NIP-AR turn receipt's counters.
 *
 * This is the message-timeline counterpart of
 * `features/local-archive/agentUsageFormat.ts`, and deliberately borrows its
 * vocabulary — a `kind`, a visible `text`, and a separate `srText` — so the
 * two surfaces answer the "missing count" question the same way. The rule both
 * exist to enforce: **`null` is not `0`.** A harness that reported no cache
 * counters made no claim about caching, and rendering `0` would invent one.
 *
 * The receipt covers a single turn, so there is no partial-sum (`≥`) case
 * here: a counter is either reported exactly or not reported at all.
 */

import type { TimelineTurnReceipt } from "@/features/messages/types";

const NOT_REPORTED_GLYPH = "—";

/** Matches `agentUsageFormat.ts`: group separators, locale-aware. */
const tokenFormatter = new Intl.NumberFormat(undefined, { useGrouping: true });

export const NOT_REPORTED_DETAIL =
  "Not reported by the harness for this turn. Not the same as zero.";

export type TurnReceiptCountKey =
  | "input"
  | "output"
  | "cacheRead"
  | "cacheWrite";

export type TurnReceiptCount = {
  key: TurnReceiptCountKey;
  /** Compact visible label, e.g. "in". */
  label: string;
  /** Spoken label, e.g. "input tokens" — "in" does not read aloud usefully. */
  srLabel: string;
  kind: "exact" | "notReported";
  /** Visible text. A `0` here means the harness genuinely reported zero. */
  text: string;
  /** Provenance for a `title`, or `null` when the number is a real count. */
  detail: string | null;
};

const COUNTERS: ReadonlyArray<{
  key: TurnReceiptCountKey;
  label: string;
  srLabel: string;
  read: (receipt: TimelineTurnReceipt) => number | null;
}> = [
  {
    key: "input",
    label: "in",
    srLabel: "input tokens",
    read: (receipt) => receipt.inputTokens,
  },
  {
    key: "output",
    label: "out",
    srLabel: "output tokens",
    read: (receipt) => receipt.outputTokens,
  },
  {
    key: "cacheRead",
    label: "cache read",
    srLabel: "cache read tokens",
    read: (receipt) => receipt.cacheReadTokens,
  },
  {
    key: "cacheWrite",
    label: "cache write",
    srLabel: "cache write tokens",
    read: (receipt) => receipt.cacheWriteTokens,
  },
];

/**
 * The four counters in a fixed order, each rendered honestly. Every counter is
 * always present in the result — an omitted row would read as "this turn had
 * no cache reads", which is a different claim from "nobody counted them".
 */
export function formatTurnReceiptCounts(
  receipt: TimelineTurnReceipt,
): TurnReceiptCount[] {
  return COUNTERS.map(({ key, label, srLabel, read }) => {
    const value = read(receipt);
    if (value === null) {
      return {
        key,
        label,
        srLabel,
        kind: "notReported" as const,
        text: NOT_REPORTED_GLYPH,
        detail: NOT_REPORTED_DETAIL,
      };
    }
    return {
      key,
      label,
      srLabel,
      kind: "exact" as const,
      text: tokenFormatter.format(value),
      detail: null,
    };
  });
}

/**
 * The whole footer as one sentence, for assistive technology.
 *
 * The visible row is a string of abbreviations and dashes that reads as a pile
 * of bare numbers; this is the single spoken stop that replaces it, so the row
 * itself is hidden from the accessibility tree rather than announced twice.
 */
export function describeTurnReceipt(
  receipt: TimelineTurnReceipt,
  modelLabel: string,
): string {
  const counts = formatTurnReceiptCounts(receipt)
    .map((count) =>
      count.kind === "notReported"
        ? `${count.srLabel} not reported`
        : `${count.text} ${count.srLabel}`,
    )
    .join(", ");
  return `Agent turn ran on ${modelLabel}, via ${receipt.harness}. Usage for this turn: ${counts}.`;
}
