/**
 * NIP-AR (kind:44201) turn receipts: parsing, trust, and anchor selection.
 *
 * A receipt says what one agent *turn* ran on and what it spent, and names —
 * by `e` tag, in publication order — every message that turn published. Two
 * rules from the NIP are load-bearing and both live here:
 *
 * 1. **Trust.** Anyone may publish a signed receipt `e`-tagging anyone else's
 *    message. A receipt whose publisher is not the author of the message it
 *    would annotate is attacker-supplied numbers wearing someone else's name,
 *    and is dropped outright ({@link selectTurnReceiptAnchor}).
 * 2. **Render once.** The counts are the turn's, not any one message's. A turn
 *    that published three messages emits ONE receipt naming all three; showing
 *    it under each would read as triple the spend. The receipt anchors to the
 *    **last** `e`-tagged message this client actually holds, and a receipt
 *    whose targets are all missing anchors nowhere and renders not at all.
 *
 * Counts are deliberately `number | null`: `null` means the harness reported
 * nothing, which is not zero. Nothing in this module substitutes a `0`.
 */

import type { TimelineTurnReceipt } from "@/features/messages/types";
import type { RelayEvent } from "@/shared/api/types";
import { KIND_AGENT_TURN_RECEIPT } from "@/shared/constants/kinds";
import { normalizePubkey } from "@/shared/lib/pubkey";

const HEX64_RE = /^[0-9a-f]{64}$/i;

/** A parsed, well-formed receipt event, before it is bound to a message. */
export type ParsedTurnReceipt = {
  /** Event ids this turn published, in publication order (NIP-AR order). */
  targetIds: string[];
  /** `created_at`, used to break ties when two receipts claim one anchor. */
  createdAt: number;
  receipt: TimelineTurnReceipt;
};

/**
 * A token counter from the receipt body. Anything that is not a non-negative
 * finite integer — a string, a float, a negative, `NaN`, an absent field — is
 * `null`, never `0`: a fabricated zero is a claim the provider never made.
 */
function parseCount(raw: unknown): number | null {
  if (typeof raw !== "number") return null;
  if (!Number.isFinite(raw) || !Number.isInteger(raw) || raw < 0) return null;
  return raw;
}

function firstTagValue(tags: string[][], name: string): string | null {
  for (const tag of tags) {
    if (tag[0] === name && typeof tag[1] === "string" && tag[1].length > 0) {
      return tag[1];
    }
  }
  return null;
}

/**
 * Parse one kind:44201 event into a receipt, or `null` when it is not a
 * well-formed one.
 *
 * The `model` tag must agree with the body's `model`: the tag exists so a
 * client can filter by model without reading every body, and a client that
 * renders the body while the tag says something else makes that filter a lie.
 * The relay rejects disagreement, so a disagreeing event reaching us means
 * something upstream is wrong and the honest response is to show nothing.
 */
export function parseTurnReceiptEvent(
  event: RelayEvent,
): ParsedTurnReceipt | null {
  if (event.kind !== KIND_AGENT_TURN_RECEIPT) return null;

  const targetIds: string[] = [];
  const seen = new Set<string>();
  for (const tag of event.tags) {
    if (tag[0] !== "e" || typeof tag[1] !== "string") continue;
    if (!HEX64_RE.test(tag[1])) continue;
    // NIP-AR: an `e` tag MUST NOT carry a NIP-10 `root`/`reply` marker. The
    // relay refuses such a receipt at ingest, because the predicate that
    // channel-scopes 44201 is the same one that resolves thread ancestry — a
    // marked tag would make a receipt a *reply* and inflate the annotated
    // message's reply_count. Refuse it here too rather than rely on that:
    // mobile reads the rule this way, and two clients disagreeing about one
    // spec line is how they drift apart.
    if (typeof tag[3] === "string" && tag[3].length > 0) return null;
    const id = tag[1].toLowerCase();
    if (seen.has(id)) continue;
    seen.add(id);
    targetIds.push(id);
  }
  if (targetIds.length === 0) return null;

  let body: unknown;
  try {
    body = JSON.parse(event.content);
  } catch {
    return null;
  }
  if (typeof body !== "object" || body === null) return null;

  const payload = body as {
    model?: unknown;
    harness?: unknown;
    turn?: unknown;
  };
  const model = typeof payload.model === "string" ? payload.model.trim() : "";
  const harness =
    typeof payload.harness === "string" ? payload.harness.trim() : "";
  if (!model || !harness) return null;

  const modelTag = firstTagValue(event.tags, "model");
  if (modelTag === null || modelTag.trim() !== model) return null;

  const turn =
    typeof payload.turn === "object" && payload.turn !== null
      ? (payload.turn as Record<string, unknown>)
      : {};

  return {
    targetIds,
    createdAt: event.created_at,
    receipt: {
      id: event.id,
      model,
      harness,
      inputTokens: parseCount(turn.inputTokens),
      outputTokens: parseCount(turn.outputTokens),
      cacheReadTokens: parseCount(turn.cacheReadTokens),
      cacheWriteTokens: parseCount(turn.cacheWriteTokens),
    },
  };
}

/**
 * Choose the one message a receipt annotates, or `null` for none.
 *
 * Walks the `e` tags newest-first (publication order, reversed) and takes the
 * last target this client actually holds — that is the "render once, under the
 * last message you have" rule. The chosen target is then trust-checked against
 * the receipt's publisher; a mismatch drops the whole receipt rather than
 * sliding down to an earlier target, because a receipt naming a message its
 * publisher did not write is forged, not merely misaddressed.
 *
 * @param resolveAuthor - the message's author pubkey, already resolved through
 *   whatever delegation the surface honours (relay-signed events carry their
 *   real author in an actor tag). The comparison is against that author, not
 *   the raw signer, so a relay-signed agent message still matches its agent's
 *   receipt.
 */
export function selectTurnReceiptAnchor(input: {
  parsed: ParsedTurnReceipt;
  receiptPubkey: string;
  /** Returns the held event for an id, or `undefined` when absent/hidden. */
  getHeldEvent: (eventId: string) => RelayEvent | undefined;
  resolveAuthor: (event: RelayEvent) => string;
}): string | null {
  const { parsed, getHeldEvent, resolveAuthor } = input;
  const publisher = normalizePubkey(input.receiptPubkey);

  for (let index = parsed.targetIds.length - 1; index >= 0; index -= 1) {
    const id = parsed.targetIds[index];
    const target = getHeldEvent(id);
    if (!target) continue;
    // Trust (NIP-AR §Consumer Behavior): the publisher must be the author of
    // the message it annotates. Without this check anyone can publish a
    // receipt claiming any pubkey's message cost anything.
    if (normalizePubkey(resolveAuthor(target)) !== publisher) return null;
    return id;
  }

  return null;
}

/**
 * Later receipt wins when two would anchor to the same message. Ties on
 * `created_at` break on event id so the result never depends on delivery
 * order, and a redelivered receipt (same id) is idempotent.
 */
export function isNewerTurnReceipt(
  candidate: ParsedTurnReceipt,
  incumbent: ParsedTurnReceipt,
): boolean {
  if (candidate.createdAt !== incumbent.createdAt) {
    return candidate.createdAt > incumbent.createdAt;
  }
  return candidate.receipt.id > incumbent.receipt.id;
}
