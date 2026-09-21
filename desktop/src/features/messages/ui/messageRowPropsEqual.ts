/**
 * `MessageRow`'s `React.memo` comparator.
 *
 * It lives outside the component so it can be exercised directly: a hand
 * written comparator is a silent-failure machine — every `message.*` field the
 * row renders but the comparator forgets simply never updates on screen, with
 * no error anywhere. Binding the tests to *this* function binds them to the
 * exact predicate `React.memo` runs in production.
 *
 * The props are typed structurally rather than imported from `MessageRow`,
 * which would make the module graph circular (the same reason
 * `depthGuideActionsEqual` restates its shape). Fields the comparator only
 * identity-checks are typed `unknown` — their shape is irrelevant to `===`,
 * and a wider parameter type is exactly what a comparator for a narrower prop
 * type may have.
 */

import {
  depthGuideActionsEqual,
  numberArrayEqual,
  reactionsEqual,
  tagsEqual,
  turnReceiptEqual,
} from "@/features/messages/lib/messageRowEquality";
import type { TimelineMessage } from "@/features/messages/types";

export type MessageRowMemoProps = {
  message: TimelineMessage;
  currentPubkey?: string;
  collapseDepthGuideActions?: ReadonlyArray<{
    active?: boolean;
    depth: number;
    label: string;
    message: TimelineMessage;
  }>;
  collapseDescendantsLabel?: string;
  connectDescendants?: boolean;
  depthGuideDepths?: ReadonlyArray<number>;
  highlightDescendantRail?: boolean;
  highlighted?: boolean;
  highlightReplyConnector?: boolean;
  highlightThreadLineDepths?: ReadonlyArray<number>;
  hoverBackground?: boolean;
  huddleMemberPubkeys?: readonly string[];
  huddleMemberPubkeysPending?: boolean;
  hideAgentAccessBadge?: boolean;
  isContinuation?: boolean;
  isFollowingThread?: boolean;
  isUnread?: boolean;
  layoutVariant?: "default" | "thread-reply";
  onCollapseDepthGuide?: unknown;
  onCollapseDepthGuideHoverChange?: unknown;
  onCollapseDescendants?: unknown;
  onCollapseDescendantsHoverChange?: unknown;
  onEntranceComplete?: unknown;
  playEntrance?: boolean;
  onSendToChannel?: unknown;
  profiles?: unknown;
  searchQuery?: string;
  videoReviewCommentRootId?: string;
  videoReviewContext?: unknown;
};

// Callbacks (onReply, onToggleReaction) intentionally excluded: inline arrows
// from parent create new refs every render — including them defeats memo.
export function messageRowPropsEqual(
  prev: Readonly<MessageRowMemoProps>,
  next: Readonly<MessageRowMemoProps>,
): boolean {
  return (
    prev.message.id === next.message.id &&
    prev.message.pubkey === next.message.pubkey &&
    prev.message.body === next.message.body &&
    prev.message.author === next.message.author &&
    prev.message.isAgent === next.message.isAgent &&
    prev.message.ownerPubkey === next.message.ownerPubkey &&
    prev.message.ownerLabel === next.message.ownerLabel &&
    prev.message.avatarUrl === next.message.avatarUrl &&
    prev.message.accent === next.message.accent &&
    // The header timestamp and hover gutter both derive from createdAt (the
    // old `time` prop was the same value pre-formatted; this row reads neither).
    prev.message.createdAt === next.message.createdAt &&
    prev.message.depth === next.message.depth &&
    prev.message.kind === next.message.kind &&
    prev.message.pending === next.message.pending &&
    prev.message.edited === next.message.edited &&
    // Value comparisons, not identity: these arrays are rebuilt with fresh
    // identities on every ingest/refetch even when unchanged — identity
    // checks made every row re-render on every streamed event in an open
    // thread (see messageRowEquality.ts).
    reactionsEqual(prev.message.reactions, next.message.reactions) &&
    tagsEqual(prev.message.tags, next.message.tags) &&
    // NIP-AR mandates the receipt is published AFTER the messages it names, so
    // it always arrives as a second render of an already-memoized row. Drop
    // this line and the usage footer never appears.
    turnReceiptEqual(prev.message.turnReceipt, next.message.turnReceipt) &&
    prev.message.role === next.message.role &&
    prev.message.personaDisplayName === next.message.personaDisplayName &&
    prev.currentPubkey === next.currentPubkey &&
    depthGuideActionsEqual(
      prev.collapseDepthGuideActions,
      next.collapseDepthGuideActions,
    ) &&
    prev.collapseDescendantsLabel === next.collapseDescendantsLabel &&
    prev.connectDescendants === next.connectDescendants &&
    numberArrayEqual(prev.depthGuideDepths, next.depthGuideDepths) &&
    prev.highlightDescendantRail === next.highlightDescendantRail &&
    prev.highlighted === next.highlighted &&
    prev.highlightReplyConnector === next.highlightReplyConnector &&
    numberArrayEqual(
      prev.highlightThreadLineDepths,
      next.highlightThreadLineDepths,
    ) &&
    prev.hoverBackground === next.hoverBackground &&
    prev.huddleMemberPubkeys === next.huddleMemberPubkeys &&
    prev.huddleMemberPubkeysPending === next.huddleMemberPubkeysPending &&
    prev.hideAgentAccessBadge === next.hideAgentAccessBadge &&
    prev.isContinuation === next.isContinuation &&
    prev.isFollowingThread === next.isFollowingThread &&
    prev.isUnread === next.isUnread &&
    prev.layoutVariant === next.layoutVariant &&
    prev.onCollapseDepthGuide === next.onCollapseDepthGuide &&
    prev.onCollapseDepthGuideHoverChange ===
      next.onCollapseDepthGuideHoverChange &&
    prev.onCollapseDescendants === next.onCollapseDescendants &&
    prev.onCollapseDescendantsHoverChange ===
      next.onCollapseDescendantsHoverChange &&
    prev.onEntranceComplete === next.onEntranceComplete &&
    prev.playEntrance === next.playEntrance &&
    prev.onSendToChannel === next.onSendToChannel &&
    prev.profiles === next.profiles &&
    prev.searchQuery === next.searchQuery &&
    prev.videoReviewCommentRootId === next.videoReviewCommentRootId &&
    prev.videoReviewContext === next.videoReviewContext
  );
}
