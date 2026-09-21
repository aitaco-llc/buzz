/**
 * Render tests for the three empty/partial states and the incomplete-vs-zero
 * rule, driven through `AgentUsagePanelContent` — the same component the
 * panel renders in production, with only the query wiring lifted out.
 *
 * The rule under test is the one the backend paid for: a counter that was
 * never reported must never appear as `0`. A regression that swaps a cell for
 * `?? 0`, or that collapses "archiving is off" and "nothing collected yet"
 * into one message, fails here.
 */

import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";

import { JSDOM } from "jsdom";
import React, { act } from "react";
import { createRoot } from "react-dom/client";

import { AgentUsagePanelContent } from "./AgentUsagePanel.tsx";

function field(value, incomplete = false) {
  return { value, incomplete };
}

function usage(overrides = {}) {
  return {
    inputTokens: field("1000"),
    outputTokens: field("200"),
    totalTokens: field("1200"),
    estimatedCostUsd: { value: 0.25, incomplete: false },
    cacheReadTokens: field("50"),
    cacheWriteTokens: field("25"),
    freshInputTokens: field("925"),
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
      ...(overrides.coverage ?? {}),
    },
    hasArchivedEvidence: null,
    ...overrides,
  };
}

function agent(overrides = {}) {
  return {
    agentPubkey: "b".repeat(64),
    usage: usage(),
    buckets: [],
    models: [
      {
        harness: "claude-code",
        model: "opus",
        usage: usage(),
        reportCount: 3,
        hasUnknownUsage: false,
      },
    ],
    reportCount: 3,
    hasUnknownUsage: false,
    ...overrides,
  };
}

function render(props) {
  const dom = new JSDOM(
    "<!doctype html><html><body><div id='root'></div></body></html>",
  );
  Object.assign(globalThis, {
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    window: dom.window,
  });
  const container = dom.window.document.getElementById("root");
  const root = createRoot(container);
  return {
    container,
    async mount() {
      await act(async () => {
        root.render(
          React.createElement(AgentUsagePanelContent, {
            days: 7,
            isPending: false,
            error: null,
            onRetry: () => {},
            displayNameFor: () => null,
            ...props,
          }),
        );
      });
    },
    async unmount() {
      await act(async () => {
        root.unmount();
      });
    },
  };
}

async function mounted(props) {
  const view = render(props);
  await view.mount();
  return view;
}

function testId(container, id) {
  return container.querySelector(`[data-testid="${id}"]`);
}

afterEach(() => {
  delete globalThis.document;
  delete globalThis.window;
  delete globalThis.HTMLElement;
  delete globalThis.IS_REACT_ACT_ENVIRONMENT;
});

describe("AgentUsagePanelContent states", () => {
  it("tells the user archiving is off, and where the switch is", async () => {
    const view = await mounted({
      series: series({ collectionEnabled: false }),
    });
    try {
      const message = testId(view.container, "agent-usage-disabled");
      assert.ok(message, "the disabled state must render its own message");
      assert.equal(testId(view.container, "agent-usage-empty"), null);
      assert.match(message.textContent, /archiving is off/i);
      assert.match(
        message.textContent,
        /Archive my agents' turn metrics/,
        "must name the control that fixes it — the only recovery affordance",
      );
    } finally {
      await view.unmount();
    }
  });

  it("distinguishes 'collected nothing yet' from 'archiving is off'", async () => {
    const view = await mounted({ series: series({ collectionEnabled: true }) });
    try {
      const message = testId(view.container, "agent-usage-empty");
      assert.ok(message, "the empty state must render its own message");
      assert.equal(testId(view.container, "agent-usage-disabled"), null);
      assert.match(message.textContent, /Archiving is on/i);
      assert.match(message.textContent, /last 7 days/);
    } finally {
      await view.unmount();
    }
  });

  it("shows historical totals, with a caveat, after archiving is switched off", async () => {
    const view = await mounted({
      series: series({
        collectionEnabled: false,
        agents: [agent()],
        coverage: { reportCount: 3 },
      }),
    });
    try {
      assert.equal(
        testId(view.container, "agent-usage-disabled"),
        null,
        "existing archived turns must not be hidden behind the disabled copy",
      );
      assert.ok(testId(view.container, "agent-usage-notice-collection-off"));
      assert.ok(view.container.querySelector("table"));
    } finally {
      await view.unmount();
    }
  });

  it("flags incomplete coverage separately from unreadable events", async () => {
    const view = await mounted({
      series: series({
        agents: [agent({ hasUnknownUsage: true })],
        coverage: { reportCount: 3, invalidReportCount: 2 },
      }),
    });
    try {
      const partial = testId(
        view.container,
        "agent-usage-notice-partial-coverage",
      );
      const unreadable = testId(
        view.container,
        "agent-usage-notice-unreadable-events",
      );
      assert.ok(partial, "partial coverage must be called out");
      assert.ok(unreadable, "unreadable events must be called out separately");
      assert.notEqual(partial.textContent, unreadable.textContent);
    } finally {
      await view.unmount();
    }
  });
});

describe("AgentUsagePanelContent cells", () => {
  it("never renders an unreported counter as 0", async () => {
    const partial = usage({
      // A harness that reports no cache counters at all: unknown, not zero.
      cacheReadTokens: field(null, true),
      cacheWriteTokens: field(null, true),
      // A partially covered window: a lower bound, not a total.
      inputTokens: field("1000", true),
    });
    const view = await mounted({
      series: series({
        agents: [
          agent({
            usage: partial,
            hasUnknownUsage: true,
            models: [
              {
                harness: null,
                model: null,
                usage: partial,
                reportCount: 3,
                hasUnknownUsage: true,
              },
            ],
          }),
        ],
        coverage: { reportCount: 3 },
      }),
    });
    try {
      const text = view.container.textContent;
      assert.match(text, /Unknown/, "unknown counters must say so");
      assert.match(text, /≥/, "a partial sum must be marked as a lower bound");
      assert.match(
        text,
        /Unknown model/,
        "an unattributed model row must be labelled, not blank",
      );
      assert.match(text, /Harness not reported/);

      const zeroCells = [...view.container.querySelectorAll("td")].filter(
        (cell) => cell.textContent.trim() === "0",
      );
      assert.deepEqual(
        zeroCells.map((cell) => cell.textContent),
        [],
        "no unreported counter may be rendered as a bare 0",
      );
    } finally {
      await view.unmount();
    }
  });

  it("renders a genuine zero as 0", async () => {
    const zeroed = usage({ cacheWriteTokens: field("0") });
    const view = await mounted({
      series: series({
        agents: [
          agent({
            usage: zeroed,
            models: [
              {
                harness: "codex",
                model: "gpt-5",
                usage: zeroed,
                reportCount: 1,
                hasUnknownUsage: false,
              },
            ],
          }),
        ],
        coverage: { reportCount: 1 },
      }),
    });
    try {
      const zeroCells = [...view.container.querySelectorAll("td")].filter(
        (cell) => cell.textContent.includes("0"),
      );
      assert.ok(
        zeroCells.length > 0,
        "a reported zero is real data and must still render",
      );
    } finally {
      await view.unmount();
    }
  });

  it("gives the model table real table semantics", async () => {
    const view = await mounted({
      series: series({
        agents: [agent()],
        coverage: { reportCount: 3 },
      }),
    });
    try {
      const table = view.container.querySelector("table");
      assert.ok(table, "the breakdown must be a real table");
      assert.ok(table.querySelector("caption"), "the table needs a caption");
      const columnHeaders = [...table.querySelectorAll('th[scope="col"]')].map(
        (th) => th.textContent,
      );
      assert.deepEqual(columnHeaders, [
        "Model",
        "Input",
        "Output",
        "Cache read",
        "Cache write",
        "Cost",
        "Turns",
      ]);
      assert.ok(
        table.querySelector('tbody th[scope="row"]'),
        "each model row needs a row header",
      );
      const region = view.container.querySelector("section[aria-labelledby]");
      assert.ok(region, "the scroll container must be a named region");
      assert.equal(
        region.getAttribute("tabindex"),
        "0",
        "a scrollable region must be reachable by keyboard",
      );
      const heading = view.container.querySelector("h3");
      assert.equal(region.getAttribute("aria-labelledby"), heading.id);
    } finally {
      await view.unmount();
    }
  });

  it("falls back to a truncated npub when the agent has no profile name", async () => {
    const view = await mounted({
      series: series({ agents: [agent()], coverage: { reportCount: 3 } }),
      displayNameFor: () => null,
    });
    try {
      const heading = view.container.querySelector("h3");
      assert.match(heading.textContent, /^npub1/);
      assert.ok(
        !heading.textContent.includes("bbbb"),
        "raw hex must never be the identity label",
      );
    } finally {
      await view.unmount();
    }
  });

  it("surfaces a read failure with a retry, not an empty state", async () => {
    const view = await mounted({
      error: new Error("archive locked"),
      series: undefined,
    });
    try {
      const error = testId(view.container, "agent-usage-error");
      assert.ok(error);
      assert.match(error.textContent, /archive locked/);
      assert.equal(testId(view.container, "agent-usage-empty"), null);
      assert.equal(testId(view.container, "agent-usage-disabled"), null);
    } finally {
      await view.unmount();
    }
  });
});
