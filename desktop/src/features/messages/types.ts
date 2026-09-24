export type TimelineReaction = {
  emoji: string;
  /** Custom (image) emoji URL from the reaction's NIP-30 `emoji` tag, if any. */
  emojiUrl?: string;
  count: number;
  reactedByCurrentUser?: boolean;
  users: Array<{
    pubkey: string;
    displayName: string;
    avatarUrl: string | null;
  }>;
};

/**
 * One NIP-AR (kind:44201) turn receipt, resolved onto the single message it
 * annotates.
 *
 * The counts belong to the *turn*, not to any one message: a turn that
 * published three messages emits one receipt naming all three, and this object
 * is attached to exactly one of them (the last one this client holds). Every
 * count is nullable because `null` means "the harness reported nothing", which
 * is a different claim from zero — see `turnReceiptFormat.ts`.
 */
export type TimelineTurnReceipt = {
  /** The receipt event's id. Stable key, and what deduplicates redeliveries. */
  id: string;
  /** Model the turn actually ran on, as the harness observed it. */
  model: string;
  /** Harness identifier (`claude-agent-acp`, `goose`, …). */
  harness: string;
  inputTokens: number | null;
  outputTokens: number | null;
  cacheReadTokens: number | null;
  cacheWriteTokens: number | null;
};

export type TimelineMessage = {
  id: string;
  /** Stable local key used to avoid remounting optimistic rows on send ack. */
  renderKey?: string;
  createdAt: number;
  pubkey?: string;
  /**
   * Raw signer pubkey (`event.pubkey`), normalized to lowercase hex.
   * Distinct from `pubkey`, which may be a delegated author on an event signed
   * by the active relay. Use this field for checks that require the process or
   * user that cryptographically signed the event.
   */
  signerPubkey?: string;
  author: string;
  /** True when the displayed author is known to be an agent. */
  isAgent?: boolean;
  /** Verified owner pubkey for an agent author, when available. */
  ownerPubkey?: string | null;
  /** Viewer-relative owner label (for example, "you" or "baxen"). */
  ownerLabel?: string | null;
  avatarUrl?: string | null;
  role?: string;
  /** For bot messages, the display name of the persona this bot was created from. */
  personaDisplayName?: string;
  /** For bot messages, the respond-to mode (who can interact with this bot). */
  respondTo?: "owner-only" | "allowlist" | "anyone";
  time: string;
  body: string;
  parentId?: string | null;
  rootId?: string | null;
  depth: number;
  accent?: boolean;
  pending?: boolean;
  edited?: boolean;
  highlighted?: boolean;
  kind?: number;
  tags?: string[][];
  reactions?: TimelineReaction[];
  /**
   * NIP-AR turn receipt anchored to this message. Present on at most one
   * message per turn — the last `e`-tagged message this client actually holds
   * — so a three-message turn never renders its cost three times.
   */
  turnReceipt?: TimelineTurnReceipt;
};
