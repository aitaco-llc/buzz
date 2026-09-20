import * as React from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";

import {
  getAgentUsageSeries,
  onAgentMetricsChanged,
  type AgentUsageSeries,
} from "@/shared/api/tauriArchive";

import {
  buildLocalDayBoundaries,
  nextLocalMidnightMs,
  startOfLocalDaySeconds,
} from "./agentUsageFormat";

/**
 * Root of every usage-series query key. Invalidation is issued against this
 * prefix so a metrics change refreshes every mounted window (7d overview and a
 * 30d drill-in can be on screen at once) rather than only the caller's.
 */
export const AGENT_USAGE_SERIES_QUERY_ROOT = "agent-usage-series";

export function agentUsageSeriesQueryKey(
  bucketBoundaries: readonly number[],
  agentPubkey?: string,
) {
  return [
    AGENT_USAGE_SERIES_QUERY_ROOT,
    agentPubkey?.toLowerCase() ?? null,
    bucketBoundaries,
  ] as const;
}

/**
 * The local day the window is anchored to, refreshed when the clock crosses
 * midnight so a long-lived window does not keep reporting yesterday's "last 30
 * days" forever. The timer is re-armed from the *calendar* day, so it survives
 * DST transitions that make a day 23 or 25 hours long.
 */
function useLocalDayAnchorSeconds(): number {
  const [anchor, setAnchor] = React.useState(() =>
    startOfLocalDaySeconds(Math.floor(Date.now() / 1_000)),
  );

  React.useEffect(() => {
    // Measured from the anchored day, not from "now": that is what makes the
    // timer re-arm exactly once per rollover. The +1s keeps a timer that fires
    // a hair early from re-resolving to the same day; a machine that slept
    // past several midnights lands here with a clamped 1s delay, resolves to a
    // strictly later day, and re-arms properly — it cannot spin, because a
    // delay of 0 implies the anchored day is already over.
    const delay =
      Math.max(0, nextLocalMidnightMs(new Date(anchor * 1_000)) - Date.now()) +
      1_000;
    const timer = window.setTimeout(() => {
      setAnchor(startOfLocalDaySeconds(Math.floor(Date.now() / 1_000)));
    }, delay);
    return () => window.clearTimeout(timer);
  }, [anchor]);

  return anchor;
}

export type UseAgentUsageSeriesOptions = {
  /** Civil days the window covers, ending with today-so-far. */
  days: number;
  /** 64-hex author filter for a single agent, or omit for every agent. */
  agentPubkey?: string;
  enabled?: boolean;
};

/**
 * Read the locally archived NIP-AM usage series for the active identity and
 * relay.
 *
 * Invalidation is push-based, not polled: `onAgentMetricsChanged` fires when a
 * kind-44200 subscription mutation succeeds here and when the native archive
 * sync task persists new metric rows (bridged from the
 * `archive-agent-metrics-changed` Tauri event by
 * `useArchiveAgentMetricsBridge`). Both producers mean the same thing — the
 * archive this query reads has changed underneath it.
 */
export function useAgentUsageSeries({
  days,
  agentPubkey,
  enabled = true,
}: UseAgentUsageSeriesOptions) {
  const queryClient = useQueryClient();
  const dayAnchor = useLocalDayAnchorSeconds();

  const bucketBoundaries = React.useMemo(
    () => buildLocalDayBoundaries(new Date(dayAnchor * 1_000), days),
    [dayAnchor, days],
  );

  React.useEffect(
    () =>
      onAgentMetricsChanged(() => {
        void queryClient.invalidateQueries({
          queryKey: [AGENT_USAGE_SERIES_QUERY_ROOT],
        });
      }),
    [queryClient],
  );

  return useQuery<AgentUsageSeries>({
    enabled,
    queryKey: agentUsageSeriesQueryKey(bucketBoundaries, agentPubkey),
    queryFn: () =>
      getAgentUsageSeries(
        agentPubkey
          ? { bucketBoundaries, agentPubkey: agentPubkey.toLowerCase() }
          : { bucketBoundaries },
      ),
    // The archive is local and the notifier covers every write path, so a
    // short stale window only guards remounts, not freshness.
    staleTime: 30_000,
  });
}
