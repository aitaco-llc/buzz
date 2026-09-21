import * as React from "react";
import { AlertTriangle } from "lucide-react";

import { useUsersBatchQuery } from "@/features/profile/hooks";
import { SettingsOptionGroup } from "@/features/settings/ui/SettingsOptionGroup";
import type { AgentUsageSeries } from "@/shared/api/tauriArchive";
import { cn } from "@/shared/lib/cn";
import { Button } from "@/shared/ui/button";
import { SegmentedControl } from "@/shared/ui/segmented-control";

import {
  buildAgentUsageNotices,
  formatCoverageSummary,
  resolveAgentUsageState,
} from "../agentUsageFormat";
import { useAgentUsageSeries } from "../useAgentUsageSeries";
import { AgentUsageAgentCard } from "./AgentUsageAgentCard";

const RANGE_OPTIONS = [
  { value: "7", label: "7 days" },
  { value: "30", label: "30 days" },
] as const;

type RangeValue = (typeof RANGE_OPTIONS)[number]["value"];

function formatBoundaryDate(unixSeconds: number): string {
  return new Date(unixSeconds * 1_000).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });
}

function PanelMessage({
  children,
  testId,
}: {
  children: React.ReactNode;
  testId: string;
}) {
  return (
    <div
      className="px-4 py-4 text-sm font-normal text-muted-foreground"
      data-testid={testId}
    >
      {children}
    </div>
  );
}

function NoticeRow({
  tone,
  children,
}: {
  tone: "info" | "warning";
  children: React.ReactNode;
}) {
  return (
    <p
      className={cn(
        "flex items-start gap-2 px-4 py-3 text-xs",
        tone === "warning" ? "text-foreground" : "text-muted-foreground",
      )}
    >
      <AlertTriangle
        aria-hidden="true"
        className="mt-0.5 h-3.5 w-3.5 shrink-0 text-muted-foreground"
      />
      <span>{children}</span>
    </p>
  );
}

export type AgentUsagePanelContentProps = {
  days: number;
  isPending: boolean;
  error: unknown;
  series: AgentUsageSeries | undefined;
  onRetry: () => void;
  displayNameFor: (agentPubkey: string) => string | null;
};

/**
 * Everything inside the panel frame, as a pure function of the query result.
 *
 * Split out from the data wiring so the states that matter most — archiving
 * off, archiving on with nothing collected, and partial coverage — are
 * rendered by tests through this exact code path rather than through a
 * re-implementation of it.
 */
export function AgentUsagePanelContent({
  days,
  isPending,
  error,
  series,
  onRetry,
  displayNameFor,
}: AgentUsagePanelContentProps) {
  if (isPending) {
    return <PanelMessage testId="agent-usage-loading">Loading…</PanelMessage>;
  }

  if (error !== null || !series) {
    return (
      <div
        className="flex flex-wrap items-center justify-between gap-3 px-4 py-4"
        data-testid="agent-usage-error"
      >
        <p className="text-sm font-normal text-muted-foreground">
          Could not read archived usage:{" "}
          {error instanceof Error ? error.message : "unknown error"}
        </p>
        <Button onClick={onRetry} size="sm" type="button" variant="outline">
          Try again
        </Button>
      </div>
    );
  }

  const state = resolveAgentUsageState(series);

  if (state === "disabled") {
    return (
      <PanelMessage testId="agent-usage-disabled">
        Turn-metric archiving is off, so no usage has been recorded. Turn on
        “Archive my agents' turn metrics” above to start collecting it — turns
        your agents have already taken cannot be recovered.
      </PanelMessage>
    );
  }

  if (state === "empty") {
    return (
      <PanelMessage testId="agent-usage-empty">
        Archiving is on, but no agent turn has been recorded in the last {days}{" "}
        days. Usage appears here once one of your agents finishes a turn and its
        metric event reaches this device.
      </PanelMessage>
    );
  }

  const notices = buildAgentUsageNotices(series);
  const coverage = formatCoverageSummary(series, formatBoundaryDate);

  return (
    <>
      {notices.map((notice) => (
        <NoticeRow key={notice.id} tone={notice.tone}>
          <span data-testid={`agent-usage-notice-${notice.id}`}>
            {notice.text}
          </span>
        </NoticeRow>
      ))}
      {coverage ? (
        <p
          className="px-4 py-3 text-xs text-muted-foreground/70"
          data-testid="agent-usage-coverage"
        >
          {coverage}
        </p>
      ) : null}
      {series.agents.map((agent) => (
        <AgentUsageAgentCard
          agent={agent}
          displayName={displayNameFor(agent.agentPubkey)}
          key={agent.agentPubkey}
        />
      ))}
    </>
  );
}

/**
 * Token usage for the user's own agents, read from the local NIP-AM archive.
 *
 * Every number here comes from `get_agent_usage_series`, which deliberately
 * keeps "not reported" separate from "zero"; the rendering rule is that a
 * missing count never appears as `0`. The three ways this panel can be empty —
 * archiving off, archiving on with nothing collected, and partial coverage —
 * each read differently, because each has a different cause and a different
 * fix.
 */
export function AgentUsagePanel() {
  const [range, setRange] = React.useState<RangeValue>("7");
  const days = Number(range);
  const query = useAgentUsageSeries({ days });
  const series = query.data;

  const agentPubkeys = React.useMemo(
    () => (series?.agents ?? []).map((agent) => agent.agentPubkey),
    [series],
  );
  const profilesQuery = useUsersBatchQuery(agentPubkeys);
  const profiles = profilesQuery.data?.profiles;

  const displayNameFor = React.useCallback(
    (agentPubkey: string) => {
      const summary = profiles?.[agentPubkey.toLowerCase()];
      return summary?.displayName ?? summary?.name ?? null;
    },
    [profiles],
  );

  const handleRetry = React.useCallback(() => {
    void query.refetch();
  }, [query.refetch]);

  return (
    <div data-testid="agent-usage-panel">
      <SettingsOptionGroup
        description={`Token usage your agents reported over the last ${days} days, read from this device's archive.`}
        headerAction={
          <SegmentedControl
            legend="Usage window"
            onValueChange={setRange}
            optionTestIdPrefix="agent-usage-range"
            options={RANGE_OPTIONS}
            size="compact"
            testId="agent-usage-range"
            value={range}
          />
        }
        title="Agent token usage"
      >
        <AgentUsagePanelContent
          days={days}
          displayNameFor={displayNameFor}
          error={query.error}
          isPending={query.isPending}
          onRetry={handleRetry}
          series={series}
        />
      </SettingsOptionGroup>
    </div>
  );
}
