import { resolveModelLabel } from "@/features/agents/lib/formatAgentModelLabel";
import {
  describeTurnReceipt,
  formatTurnReceiptCounts,
} from "@/features/messages/lib/turnReceiptFormat";
import type { TimelineTurnReceipt } from "@/features/messages/types";

/**
 * The NIP-AR footer: what this agent turn ran on, and what it consumed.
 *
 * Rendered under the message body of the **last** message the turn published
 * (see `agentTurnReceipt.ts`), never under each of them — the counts belong to
 * the turn, and repeating them per message reads as multiplied spend.
 *
 * Accessibility: the visible row is a line of abbreviations and em dashes that
 * announces as a run of bare numbers, so it is hidden from the accessibility
 * tree and replaced by exactly one spoken sentence. One owner per label, one
 * screen-reader stop, nothing interactive.
 */
export function MessageTurnReceipt({
  receipt,
}: {
  receipt?: TimelineTurnReceipt;
}) {
  if (!receipt) return null;

  // Same label formatter the agent surfaces use, so "claude-opus-4-5" reads
  // identically in a profile popover and under a message.
  const modelLabel = resolveModelLabel(receipt.model, null, null);
  const counts = formatTurnReceiptCounts(receipt);

  return (
    <div
      className="mt-1 text-2xs text-muted-foreground"
      data-testid="message-turn-receipt"
    >
      <span className="sr-only">
        {describeTurnReceipt(receipt, modelLabel)}
      </span>
      <span
        aria-hidden
        className="flex flex-wrap items-center gap-x-1.5 gap-y-0.5"
      >
        <span className="font-medium" title={`Harness: ${receipt.harness}`}>
          {modelLabel}
        </span>
        {counts.map((count) => (
          <span className="flex items-center gap-x-1" key={count.key}>
            <span aria-hidden className="opacity-50">
              ·
            </span>
            <span
              className={
                count.kind === "notReported" ? "opacity-70" : undefined
              }
              title={count.detail ?? undefined}
            >
              {count.text} {count.label}
            </span>
          </span>
        ))}
      </span>
    </div>
  );
}
