/**
 * Mounted-hook tests for `useAgentUsageSeries`.
 *
 * The invalidation contract is the reason this hook exists in its documented
 * form: `tauriArchive.notifyAgentMetricsChanged` is described as the thing
 * "`useAgentUsageSeries` subscribes to", and two producers fire it — a
 * kind-44200 subscription mutation, and the native archive sync task via
 * `useArchiveAgentMetricsBridge`. These tests bind the real hook to the real
 * notifier and the real Tauri command boundary, so deleting the subscription
 * (or the unsubscribe) fails here rather than degrading into a stale panel
 * nobody notices.
 */

import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";

import { JSDOM } from "jsdom";
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

import { notifyAgentMetricsChanged } from "@/shared/api/tauriArchive";
import { useAgentUsageSeries } from "./useAgentUsageSeries.ts";

function emptySeries() {
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
  };
}

/**
 * Mounts the real hook over an intercepted `window.__TAURI_INTERNALS__.invoke`
 * — the same boundary `invokeTauri` calls in production.
 */
function mountHook({ days = 7, agentPubkey } = {}) {
  const dom = new JSDOM(
    "<!doctype html><html><body><div id='root'></div></body></html>",
  );
  const requests = [];
  dom.window.__TAURI_INTERNALS__ = {
    invoke: (cmd, args) => {
      if (cmd === "get_agent_usage_series") {
        requests.push(args?.request);
        return Promise.resolve(emptySeries());
      }
      return Promise.resolve(null);
    },
    metadata: { currentWindow: { label: "main" } },
    transformCallback: () => Math.random(),
  };
  Object.assign(globalThis, {
    isTauri: true,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    window: dom.window,
  });

  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 } },
  });
  const results = [];

  function Harness() {
    results.push(useAgentUsageSeries({ days, agentPubkey }));
    return null;
  }

  const root = createRoot(dom.window.document.getElementById("root"));

  return {
    requests,
    results,
    async mount() {
      await act(async () => {
        root.render(
          React.createElement(
            QueryClientProvider,
            { client: queryClient },
            React.createElement(Harness),
          ),
        );
      });
    },
    async notify() {
      await act(async () => {
        notifyAgentMetricsChanged();
        await Promise.resolve();
      });
    },
    async unmount() {
      await act(async () => {
        root.unmount();
      });
      queryClient.clear();
    },
  };
}

afterEach(() => {
  delete globalThis.isTauri;
  delete globalThis.document;
  delete globalThis.window;
  delete globalThis.HTMLElement;
  delete globalThis.IS_REACT_ACT_ENVIRONMENT;
});

describe("useAgentUsageSeries", () => {
  it("requests a boundary grid the backend will accept", async () => {
    const harness = mountHook({ days: 7 });
    try {
      await harness.mount();

      assert.equal(harness.requests.length, 1);
      const { bucketBoundaries, agentPubkey } = harness.requests[0];
      assert.equal(bucketBoundaries.length, 8, "7 buckets need 8 boundaries");
      assert.equal(
        agentPubkey,
        undefined,
        "the overview carries no author filter",
      );
      for (let i = 0; i < bucketBoundaries.length - 1; i += 1) {
        const interval = bucketBoundaries[i + 1] - bucketBoundaries[i];
        assert.ok(interval > 0 && interval <= 48 * 3600);
      }
    } finally {
      await harness.unmount();
    }
  });

  it("passes a normalized author filter for a single-agent window", async () => {
    const harness = mountHook({ days: 30, agentPubkey: "A".repeat(64) });
    try {
      await harness.mount();

      assert.equal(harness.requests[0].bucketBoundaries.length, 31);
      assert.equal(harness.requests[0].agentPubkey, "a".repeat(64));
    } finally {
      await harness.unmount();
    }
  });

  it("refetches when the agent-metrics notifier fires", async () => {
    const harness = mountHook();
    try {
      await harness.mount();
      assert.equal(harness.requests.length, 1);

      await harness.notify();

      assert.equal(
        harness.requests.length,
        2,
        "a persisted metric batch must invalidate the series, not wait for a poll",
      );
    } finally {
      // Unconditional: the hook arms a real midnight timer, and leaving one
      // pending on a failed assertion hangs the runner instead of reporting.
      await harness.unmount();
    }
  });

  it("stops listening once unmounted", async () => {
    const harness = mountHook();
    await harness.mount();
    await harness.unmount();

    const before = harness.requests.length;
    notifyAgentMetricsChanged();
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.equal(
      harness.requests.length,
      before,
      "an unmounted panel must not keep refetching on every archive write",
    );
  });
});
