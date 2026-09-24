import * as React from "react";

import type { AgentUsage, ReportedUsage } from "@/shared/api/tauriArchive";
import { cn } from "@/shared/lib/cn";
import { truncateNpub } from "@/shared/lib/pubkey";

import {
  formatCostField,
  formatCount,
  formatTokenField,
  modelLabel,
  type UsageCell,
} from "../agentUsageFormat";

/**
 * Column order for the per-model breakdown. `key` is only used for React
 * identity; the accessor is what binds each column to its backend field, so a
 * renamed wire field breaks the build rather than silently blanking a column.
 */
const COLUMNS: ReadonlyArray<{
  key: string;
  label: string;
  cell: (usage: ReportedUsage) => UsageCell;
}> = [
  {
    key: "input",
    label: "Input",
    cell: (u) => formatTokenField(u.inputTokens),
  },
  {
    key: "output",
    label: "Output",
    cell: (u) => formatTokenField(u.outputTokens),
  },
  {
    key: "cache-read",
    label: "Cache read",
    cell: (u) => formatTokenField(u.cacheReadTokens),
  },
  {
    key: "cache-write",
    label: "Cache write",
    cell: (u) => formatTokenField(u.cacheWriteTokens),
  },
  {
    key: "cost",
    label: "Cost",
    cell: (u) => formatCostField(u.estimatedCostUsd),
  },
];

/**
 * A counter cell. The glyphs that carry meaning here (`—` for not reported,
 * `≥` for a lower bound) do not read aloud usefully, so the spoken string is
 * rendered separately and the visible text is hidden from assistive tech —
 * one label, one owner, no duplicate stop.
 */
function UsageValue({ cell }: { cell: UsageCell }) {
  return (
    <span
      className={cn(
        "tabular-nums",
        cell.kind === "notReported" && "text-muted-foreground/60",
        cell.kind === "unknown" && "text-muted-foreground",
      )}
      title={cell.detail ?? undefined}
    >
      <span aria-hidden="true">{cell.text}</span>
      <span className="sr-only">{cell.srText}</span>
    </span>
  );
}

function ModelRowHeader({ row }: { row: ReturnType<typeof modelLabel> }) {
  return (
    <>
      <span className="block truncate font-medium">{row.model}</span>
      <span className="block truncate text-2xs font-normal text-muted-foreground/70">
        {row.harness ?? "Harness not reported"}
      </span>
    </>
  );
}

/**
 * One agent: its identity, how many turns the numbers rest on, and the
 * per-`(harness, model)` breakdown with an all-models total row.
 */
export function AgentUsageAgentCard({
  agent,
  displayName,
}: {
  agent: AgentUsage;
  displayName: string | null;
}) {
  const headingId = React.useId();
  const label = displayName?.trim() || truncateNpub(agent.agentPubkey);
  const turns = `${formatCount(agent.reportCount)} ${agent.reportCount === 1 ? "turn" : "turns"}`;

  return (
    <article
      aria-labelledby={headingId}
      className="px-4 py-4"
      data-testid={`agent-usage-agent-${agent.agentPubkey}`}
    >
      <div className="mb-3 min-w-0">
        <h3 className="truncate text-sm font-medium" id={headingId}>
          {label}
        </h3>
        <p className="text-xs text-muted-foreground/70">
          {turns}
          {displayName?.trim() ? ` · ${truncateNpub(agent.agentPubkey)}` : ""}
        </p>
      </div>

      {/* WCAG 2.1.1: a horizontally scrollable region has no other keyboard
          path to the columns it clips, so the scroll container itself must be
          focusable. It is named by the agent heading it already owns, so this
          adds a scroll stop, not a second label. */}
      <section
        aria-labelledby={headingId}
        className="overflow-x-auto rounded-lg border border-border/60"
        // biome-ignore lint/a11y/noNoninteractiveTabindex: keyboard access to a scrollable table region (WCAG 2.1.1)
        tabIndex={0}
      >
        <table className="w-full border-collapse text-xs">
          <caption className="sr-only">
            Archived token usage by model for {label}
          </caption>
          <thead>
            <tr className="border-b border-border/60 bg-muted/20">
              <th
                className="whitespace-nowrap px-3 py-2 text-left text-2xs font-semibold uppercase tracking-wide text-muted-foreground"
                scope="col"
              >
                Model
              </th>
              {COLUMNS.map((column) => (
                <th
                  className="whitespace-nowrap px-3 py-2 text-right text-2xs font-semibold uppercase tracking-wide text-muted-foreground"
                  key={column.key}
                  scope="col"
                >
                  {column.label}
                </th>
              ))}
              <th
                className="whitespace-nowrap px-3 py-2 text-right text-2xs font-semibold uppercase tracking-wide text-muted-foreground"
                scope="col"
              >
                Turns
              </th>
            </tr>
          </thead>
          <tbody>
            {agent.models.map((model) => (
              <tr
                className="border-b border-border/40 last:border-b-0"
                key={`${model.harness ?? ""}|${model.model ?? ""}`}
              >
                <th
                  className="max-w-[16rem] px-3 py-2 text-left align-top font-normal"
                  scope="row"
                >
                  <ModelRowHeader row={modelLabel(model)} />
                </th>
                {COLUMNS.map((column) => (
                  <td
                    className="whitespace-nowrap px-3 py-2 text-right align-top"
                    key={column.key}
                  >
                    <UsageValue cell={column.cell(model.usage)} />
                  </td>
                ))}
                <td className="whitespace-nowrap px-3 py-2 text-right align-top tabular-nums text-muted-foreground">
                  {formatCount(model.reportCount)}
                </td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr className="border-t border-border/60 bg-muted/20">
              <th className="px-3 py-2 text-left font-medium" scope="row">
                All models
              </th>
              {COLUMNS.map((column) => (
                <td
                  className="whitespace-nowrap px-3 py-2 text-right font-medium"
                  key={column.key}
                >
                  <UsageValue cell={column.cell(agent.usage)} />
                </td>
              ))}
              <td className="whitespace-nowrap px-3 py-2 text-right font-medium tabular-nums">
                {formatCount(agent.reportCount)}
              </td>
            </tr>
          </tfoot>
        </table>
      </section>
    </article>
  );
}
