import type { RelayEvent } from "@/shared/api/types";

/**
 * In-process fan-out of live message events for a channel.
 *
 * `useChannelSubscription` owns the channel's single live relay subscription
 * and routes thread replies into per-thread caches, so they never reach the
 * main timeline. Consumers that must react to every arriving message, thread
 * replies included (the typing indicator clears an author's entry when their
 * message lands), subscribe here instead of opening a second relay
 * subscription for the same events.
 */
type LiveChannelMessageListener = (event: RelayEvent) => void;

const listenersByChannel = new Map<string, Set<LiveChannelMessageListener>>();

export function publishLiveChannelMessage(
  channelId: string,
  event: RelayEvent,
) {
  const listeners = listenersByChannel.get(channelId);
  if (!listeners) {
    return;
  }
  for (const listener of listeners) {
    // Isolated: the publisher runs inside the live message handler, which
    // still has to file the event after this returns.
    try {
      listener(event);
    } catch (error) {
      console.error("Live channel message listener failed", channelId, error);
    }
  }
}

export function subscribeLiveChannelMessages(
  channelId: string,
  listener: LiveChannelMessageListener,
): () => void {
  const listeners =
    listenersByChannel.get(channelId) ?? new Set<LiveChannelMessageListener>();
  listeners.add(listener);
  listenersByChannel.set(channelId, listeners);
  return () => {
    listeners.delete(listener);
    if (
      listeners.size === 0 &&
      listenersByChannel.get(channelId) === listeners
    ) {
      listenersByChannel.delete(channelId);
    }
  };
}
