/**
 * Render tests for the NIP-AR usage footer, driven through the same component
 * `MessageRow` renders in production.
 *
 * Two guarantees are worth a rendered DOM rather than a formatter unit test:
 * an unreported counter must never reach the screen as `0`, and the row of
 * abbreviations must announce as one sentence rather than a pile of numbers.
 */

import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";

import { JSDOM } from "jsdom";
import React, { act } from "react";
import { createRoot } from "react-dom/client";

import { MessageTurnReceipt } from "./MessageTurnReceipt.tsx";

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

let cleanup = null;

function render(element) {
  const dom = new JSDOM("<!doctype html><html><body></body></html>");
  const previous = {
    window: globalThis.window,
    document: globalThis.document,
    navigator: globalThis.navigator,
  };
  globalThis.window = dom.window;
  globalThis.document = dom.window.document;
  Object.defineProperty(globalThis, "navigator", {
    value: dom.window.navigator,
    configurable: true,
  });
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;

  const container = dom.window.document.createElement("div");
  dom.window.document.body.append(container);
  const root = createRoot(container);
  act(() => {
    root.render(element);
  });

  cleanup = () => {
    act(() => {
      root.unmount();
    });
    globalThis.window = previous.window;
    globalThis.document = previous.document;
    Object.defineProperty(globalThis, "navigator", {
      value: previous.navigator,
      configurable: true,
    });
  };

  return container;
}

describe("MessageTurnReceipt", () => {
  afterEach(() => {
    cleanup?.();
    cleanup = null;
  });

  it("renders nothing for a message with no receipt", () => {
    const container = render(React.createElement(MessageTurnReceipt, {}));
    assert.equal(container.textContent, "");
  });

  it("shows the model the turn ran on and every reported count", () => {
    const container = render(
      React.createElement(MessageTurnReceipt, { receipt: receipt() }),
    );
    const visible = container.querySelector("[aria-hidden]").textContent;
    assert.ok(visible.includes("claude-opus-4-5"), visible);
    assert.ok(visible.includes("191,261 in"), visible);
    assert.ok(visible.includes("683 out"), visible);
    assert.ok(visible.includes("122,407 cache read"), visible);
    assert.ok(visible.includes("4,096 cache write"), visible);
  });

  it("renders an unreported count as an em dash, never as 0", () => {
    const container = render(
      React.createElement(MessageTurnReceipt, {
        receipt: receipt({ cacheReadTokens: null, cacheWriteTokens: null }),
      }),
    );
    const visible = container.querySelector("[aria-hidden]").textContent;
    assert.ok(visible.includes("— cache read"), visible);
    assert.ok(visible.includes("— cache write"), visible);
    assert.ok(!visible.includes("0 cache read"), visible);
    assert.ok(!visible.includes("0 cache write"), visible);
  });

  it("announces one sentence and hides the abbreviated row from assistive tech", () => {
    const container = render(
      React.createElement(MessageTurnReceipt, {
        receipt: receipt({ cacheWriteTokens: null }),
      }),
    );
    const spoken = container.querySelectorAll(".sr-only");
    assert.equal(spoken.length, 1, "exactly one screen-reader stop");
    assert.ok(spoken[0].textContent.includes("191,261 input tokens"));
    assert.ok(
      spoken[0].textContent.includes("cache write tokens not reported"),
    );

    // The visible glyph row must be hidden, or every number is announced
    // twice — once unlabelled.
    const row = container.querySelector("[data-testid='message-turn-receipt']");
    assert.equal(
      row.querySelector(":scope > [aria-hidden='true']") !== null,
      true,
    );
    // Nothing in the footer is interactive, so nothing needs a label owner.
    assert.equal(row.querySelectorAll("button, a, input").length, 0);
  });
});
