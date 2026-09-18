/**
 * Behavioral tests for useChannelTyping's clear-on-message path.
 *
 * An author's message must end their typing in the thread it was posted to and
 * on the channel, including a reply posted in a thread, which never reaches
 * the main timeline (`latestMessageEvent`) and arrives through the live
 * channel messages fan-out. Agents announce typing on the channel while they
 * answer a top-level mention in its thread, so a same-thread-only clear left
 * their indicator up for the rest of the turn. Sibling threads, and messages
 * too old to have ended any live indicator, must not clear anything.
 */

import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "http://localhost",
});
before(() => {
  Object.assign(globalThis, {
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    window: dom.window,
    localStorage: dom.window.localStorage,
  });
});
after(() => dom.window.close());

const CHANNEL = "11111111-1111-4111-8111-111111111111";
const OTHER_CHANNEL = "22222222-2222-4222-8222-222222222222";
const VIEWER = "a".repeat(64);
const AGENT = "b".repeat(64);
const OTHER_AGENT = "c".repeat(64);
const TRIGGER = "d".repeat(64);

const realNow = Date.now;
let nowMs = realNow();
const seconds = () => Math.floor(nowMs / 1000);

function typing(pubkey, { root = null, channel = CHANNEL, createdAt } = {}) {
  const tags = [["h", channel]];
  if (root) tags.push(["e", root, "", "reply"]);
  return {
    id: `typing-${Math.random()}`,
    kind: 20002,
    pubkey,
    content: "",
    created_at: createdAt ?? seconds(),
    tags,
    sig: "",
  };
}

function message(pubkey, { root = null, channel = CHANNEL, createdAt } = {}) {
  const tags = [["h", channel]];
  if (root) tags.push(["e", root, "", "reply"]);
  return {
    id: `msg-${Math.random()}`,
    kind: 9,
    pubkey,
    content: "answer",
    created_at: createdAt ?? seconds(),
    tags,
    sig: "",
  };
}

async function mount() {
  const { act, cleanup, renderHook } = await import("@testing-library/react");
  const { relayClient } = await import("@/shared/api/relayClient");
  const { useChannelTyping } = await import("./useChannelTyping.ts");
  const { publishLiveChannelMessage } = await import(
    "./liveChannelMessages.ts"
  );

  const original = relayClient.subscribeToTypingIndicators;
  let deliverTyping = null;
  relayClient.subscribeToTypingIndicators = async (_channelId, onEvent) => {
    deliverTyping = onEvent;
    return async () => {};
  };
  Date.now = () => nowMs;

  const channel = { id: CHANNEL, channelType: "stream" };
  const hook = renderHook(
    ({ latest }) => useChannelTyping(channel, VIEWER, latest, null),
    { initialProps: { latest: null } },
  );
  // Let the typing subscription promise resolve.
  await act(async () => {});

  return {
    act,
    result: hook.result,
    rerender: hook.rerender,
    typing: (event) => act(() => deliverTyping(event)),
    liveMessage: (event) =>
      act(() => publishLiveChannelMessage(CHANNEL, event)),
    teardown: () => {
      hook.unmount();
      cleanup();
      relayClient.subscribeToTypingIndicators = original;
      Date.now = realNow;
    },
  };
}

test("a thread reply clears the author's channel-keyed typing", async () => {
  const h = await mount();
  try {
    await h.typing(typing(AGENT));
    assert.deepEqual(h.result.current, [{ pubkey: AGENT, threadHeadId: null }]);

    // The agent answers in the thread under the mention.
    await h.liveMessage(message(AGENT, { root: TRIGGER }));
    assert.deepEqual(h.result.current, []);
  } finally {
    h.teardown();
  }
});

test("a thread reply clears the author's thread-keyed typing", async () => {
  const h = await mount();
  try {
    await h.typing(typing(AGENT, { root: TRIGGER }));
    assert.deepEqual(h.result.current, [
      { pubkey: AGENT, threadHeadId: TRIGGER },
    ]);
    await h.liveMessage(message(AGENT, { root: TRIGGER }));
    assert.deepEqual(h.result.current, []);
  } finally {
    h.teardown();
  }
});

test("other authors keep typing when one author's message lands", async () => {
  const h = await mount();
  try {
    await h.typing(typing(AGENT));
    await h.typing(typing(OTHER_AGENT, { root: TRIGGER }));
    await h.liveMessage(message(AGENT, { root: TRIGGER }));
    assert.deepEqual(h.result.current, [
      { pubkey: OTHER_AGENT, threadHeadId: TRIGGER },
    ]);
  } finally {
    h.teardown();
  }
});

test("typing that predates the author's message is stale on the channel", async () => {
  const h = await mount();
  try {
    const postedAt = seconds();
    await h.liveMessage(message(AGENT, { root: TRIGGER, createdAt: postedAt }));

    // A channel-keyed refresh signed in the same second, delivered late.
    nowMs += 2_500; // past the post-message suppression window
    await h.typing(typing(AGENT, { createdAt: postedAt }));
    assert.deepEqual(h.result.current, []);

    // A newer refresh means the author is still at it: show it again.
    await h.typing(typing(AGENT));
    assert.deepEqual(h.result.current, [{ pubkey: AGENT, threadHeadId: null }]);
  } finally {
    h.teardown();
  }
});

test("typing right after a message is suppressed briefly", async () => {
  const h = await mount();
  try {
    await h.liveMessage(message(AGENT, { root: TRIGGER }));
    nowMs += 1_000;
    await h.typing(typing(AGENT));
    assert.deepEqual(h.result.current, []);
  } finally {
    h.teardown();
  }
});

test("a main-timeline message still clears typing", async () => {
  const h = await mount();
  try {
    await h.typing(typing(AGENT));
    await h.act(() => {
      h.rerender({ latest: message(AGENT) });
    });
    assert.deepEqual(h.result.current, []);
  } finally {
    h.teardown();
  }
});

test("messages from another channel do not clear typing", async () => {
  const h = await mount();
  try {
    await h.typing(typing(AGENT));
    await h.liveMessage(message(AGENT, { channel: OTHER_CHANNEL }));
    assert.deepEqual(h.result.current, [{ pubkey: AGENT, threadHeadId: null }]);
  } finally {
    h.teardown();
  }
});

test("a reply in one thread keeps the author's typing in a sibling thread", async () => {
  const h = await mount();
  const SIBLING = "e".repeat(64);
  try {
    await h.typing(typing(AGENT, { root: TRIGGER }));
    await h.typing(typing(AGENT, { root: SIBLING }));
    await h.liveMessage(message(AGENT, { root: TRIGGER }));
    assert.deepEqual(h.result.current, [
      { pubkey: AGENT, threadHeadId: SIBLING },
    ]);

    // The sibling's next refresh is not held back by the other thread's post.
    await h.typing(typing(AGENT, { root: SIBLING }));
    assert.deepEqual(h.result.current, [
      { pubkey: AGENT, threadHeadId: SIBLING },
    ]);
  } finally {
    h.teardown();
  }
});

test("a replayed old message does not clear current typing", async () => {
  const h = await mount();
  try {
    await h.typing(typing(AGENT));
    // Reconnect replay of a message the agent posted ten minutes ago.
    await h.liveMessage(message(AGENT, { createdAt: seconds() - 600 }));
    assert.deepEqual(h.result.current, [{ pubkey: AGENT, threadHeadId: null }]);
  } finally {
    h.teardown();
  }
});
