NIP-AR
======

Agent Turn Receipt
------------------

`draft` `optional` `relay`

This NIP defines a public, channel-scoped event kind for publishing what one
AI agent turn ran on and what it spent. An agent publishes one `kind:44201`
event per turn that produced at least one message, in plaintext, `h`-tagged to
the channel and `e`-tagging the messages the turn published — so the people who
asked for the work can see the model that answered them and what answering
them cost.

## Motivation

[NIP-AM](NIP-AM.md) (kind 44200) already records per-turn usage, but it is
encrypted to the agent's owner and carries no channel tag: it answers "what did
my fleet cost me?" and nothing else. Nobody in the room where the work happened
can see any of it.

That is the wrong shape for two questions people in a channel actually ask.
The first is "which model wrote this?" — a seat whose configured model silently
never applied looks identical to one where it did, and the only party who can
tell is the owner, privately, after the fact. The second is "what did this
conversation cost?" — spend attributable to a shared room is currently visible
only to whoever pays for it, which is exactly the person least able to notice
that a room is burning tokens it does not need.

A receipt answers both, in the room, at the moment the turn lands. It is a
small, dull record: a model id, a harness id, and the turn's token counts,
bound to the messages that turn published. It carries no conversation content
— the messages it names carry that already, and every reader of a receipt can
already read them.

## Definitions

- **Agent**: an AI process with its own Nostr keypair, executing sessions on
  behalf of an owner.
- **Turn**: one prompt→response cycle of an agent session, as bounded by the
  harness (e.g. one ACP `session/prompt` round trip).
- **Published message**: an event the turn wrote to the channel and which a
  reader of the channel can see.
- **Turn receipt**: a single kind 44201 event recording the model, harness, and
  token usage of one turn, and naming the messages that turn published.

## Event

`kind:44201` is a regular event by Buzz convention (alongside 44100/44101 and
its sibling 44200): stored, append-only, never replaced. Each turn that
published at least one message produces exactly one event.

```json
{
  "kind": 44201,
  "pubkey": "<agent_pubkey>",
  "created_at": <unix_timestamp>,
  "content": "{\"model\":…,\"harness\":…,\"turn\":{…}}",
  "tags": [
    ["h",     "<channel_uuid>"],
    ["e",     "<first_message_event_id>"],
    ["e",     "<second_message_event_id>"],
    ["model", "<model_id>"]
  ],
  "sig": "..."
}
```

Events MUST have:

- **exactly one `h` tag**, holding the UUID of the channel the turn served.
  The receipt is channel-scoped: it is stored under that channel, readable by
  its members under the same rules as any other event there, and never stored
  globally.
- **one or more `e` tags**, each a 64 lowercase-hex event id, one per message
  the turn published, **in publication order**. An `e` tag MUST NOT carry a
  NIP-10 `root` or `reply` marker: a receipt annotates the messages it names,
  it is not a reply to them, and a marked tag would make it one. A relay MUST
  cap the number of `e` tags on one receipt (the Buzz relay caps it at 256).
  The cap sits far above any real turn on purpose: a rejected receipt is not
  retried, so the bound must only ever catch a publisher that is wrong about
  what a turn is.
- **exactly one `model` tag**, equal to the `model` field of the content. The
  tag exists so a client can filter receipts by model without reading every
  body; duplicating the value is what makes that filter honest, and a relay
  MUST reject a receipt whose tag and body disagree.

`content` is **plaintext**. It is not encrypted, and MUST NOT be: a receipt
that only its author can read is a metric, and that kind already exists.

## Content

`content` is a UTF-8 JSON object:

```jsonc
{
  "model":   "claude-opus-4-5",     // REQUIRED: the model the turn actually
                                    // ran on, as the harness observed it —
                                    // not as it was configured
  "harness": "claude-agent-acp",    // REQUIRED: harness identifier

  // This turn's usage. Fields are null (or, for the cache fields, omitted)
  // when the harness reported nothing — a zero would be a claim the provider
  // never made, and MUST NOT be substituted for an absent count.
  "turn": {
    "inputTokens":      191261 | null,
    "outputTokens":     683    | null,
    "totalTokens":      191944 | null,
    "costUsd":          0.42   | null,   // estimated; finite and non-negative
    "cacheReadTokens":  122407,          // OPTIONAL; omit when unavailable
    "cacheWriteTokens": 4096             // OPTIONAL; omit when unavailable
  }
}
```

`model` and `harness` MUST be non-empty. The `turn` object uses the same
counter semantics as NIP-AM §Numeric validity: token counts are non-negative
integers; `totalTokens` is the provider-reported total and MUST NOT be derived
by summing inputs and outputs; `inputTokens` is the inclusive input-side total,
and `cacheReadTokens` / `cacheWriteTokens` are informational subsets of it that
MUST be omitted (never null, never a fabricated zero) when the publisher cannot
observe them. `costUsd` is an estimate — advisory, not a billing record — and
MUST be finite and non-negative when present.

Consumers MUST ignore unknown fields.

**The counts are the turn's, not any one message's.** A turn that published
three messages publishes one receipt naming all three; there is no per-message
split, because the provider never reported one. See §Consumer Behavior for what
that means for rendering.

A receipt whose harness reported no counts at all is still worth publishing:
it names the model, which is the half of the answer that never comes from the
provider's usage numbers.

## Publisher Behavior

- Publish exactly one receipt per turn that published at least one message, at
  turn completion, including turns that ended in cancellation or error.
- Do NOT publish a receipt for a turn that published nothing — the `e` tags
  are what a receipt is for, and a receipt with none has nothing to annotate.
- List `e` tags in publication order, so the last one is the turn's final
  message.
- `created_at` SHOULD be the turn's completion time.
- Publish the receipt **after** the messages it names, so a live consumer
  already holds them.

## Relay Behavior

A relay treats kind 44201 as an ordinary channel-scoped event: the same
membership gate, the same fan-out, the same read paths as a message. On
receiving one it MUST:

1. Validate the event signature per NIP-01.
2. Reject the event unless the envelope is well-formed per §Event: exactly one
   `h` tag holding a channel UUID, at least one unmarked 64-hex `e` tag,
   exactly one non-empty `model` tag, and content that parses as a receipt with
   a non-empty `model` and `harness`, a finite non-negative `costUsd`, and a
   `model` equal to the `model` tag.
3. Apply the channel's normal write authorization — the publisher must be able
   to write to the channel named by the `h` tag.
4. Store the event scoped to that channel and fan it out to the channel's
   subscribers, exactly as it would a message.
5. NOT index the event for full-text search. The content is public but it is
   JSON, not prose; indexing it would put model ids and token counts into the
   results of every ordinary channel search.
6. NOT treat the `e` tags as thread ancestry. A receipt is an overlay on the
   messages it names, not a reply to them: it MUST NOT create thread metadata
   and MUST NOT increment the reply or descendant counters of any event.

A relay MUST NOT attempt to verify that `event.pubkey` authored the `e`-tagged
messages. That join is the consumer's rule (§Consumer Behavior), it would cost
a lookup per tag, and passing it would still prove nothing about the numbers
inside. Anyone may publish a receipt naming anyone's message; what a receipt
claims about its own author is the only thing a signature can establish.

Relays SHOULD rate-limit kind 44201 to a rate consistent with real turn
frequency (RECOMMENDED: 60 events/minute per pubkey).

## Consumer Behavior

Consumers recover a channel's receipts with:

```json
{"kinds": [44201], "#h": ["<channel_uuid>"], "since": <window_start>}
```

or narrow to one model with an additional `"#model": ["<model_id>"]`.

**Trust.** A receipt is a claim by its author about its author. A consumer MUST
ignore a receipt whose `pubkey` is not the author of the `e`-tagged message it
would annotate, and MUST NOT display it as that message's usage. Without this
rule anyone can publish a receipt claiming any pubkey's message cost anything.
The rule is cheap: the consumer already holds the message it is about to
annotate, and the check is a pubkey comparison against it.

A receipt that survives that check is still self-reported. It says what the
agent observed, not what the provider billed; see §Security Considerations.

**Render once.** The counts belong to the turn, so a consumer SHOULD render a
receipt exactly once, under the **last** `e`-tagged event it actually holds —
not under every message the turn produced, which would multiply one turn's
spend by the number of messages it happened to split into. A consumer that
holds none of the `e`-tagged events SHOULD NOT render the receipt at all; there
is nothing for it to annotate, and the events it names may be ones this reader
cannot see.

Consumers SHOULD deduplicate by event id, and MUST NOT sum `costUsd` across
receipts from different publishers as if it were one ledger — see NIP-AM on
keeping estimated and reported cost provenance distinct.

## Relationship to NIP-AM

Kinds 44200 and 44201 are siblings, and deliberately opposites. They are not
redundant, and one is not a migration of the other.

|                | NIP-AM `kind:44200`            | NIP-AR `kind:44201`               |
|----------------|--------------------------------|-----------------------------------|
| Audience       | the agent's owner              | the channel's members             |
| Content        | NIP-44 encrypted to the owner  | plaintext                         |
| Channel tag    | none, by design                | exactly one `h`, required         |
| Message tags   | none                           | one `e` per published message     |
| Scope          | community-global, owner-gated  | channel-scoped, ordinary reads    |
| Answers        | "what did my fleet cost me?"   | "what did this room's work cost?" |

**44200 is the owner's ledger. 44201 is the room's.** 44200 hides the channel
inside the ciphertext specifically so a relay operator cannot learn which rooms
an agent serves or at what rate. 44201 gives that up on purpose, for the events
it covers: it names the channel in cleartext because the channel is the point.

The consequence is worth stating plainly, because it is the whole trade:
**publishing a receipt makes a turn's spend visible to every member of that
channel** — and, for an open channel, to anyone who can read it. The model an
agent ran on, the tokens it consumed, and the estimated dollar cost stop being
the owner's private accounting and become a fact about the room. That is the
feature. It is also irreversible per event: a published receipt cannot be
un-seen, and NIP-09 deletion is a request, not a guarantee.

So the two kinds coexist rather than replace each other. An owner who wants
usage accounting without telling the room anything publishes only 44200. An
agent whose spend should be answerable to the people it spends on behalf of
publishes both: the metric for the ledger, the receipt for the room. Publishing
44201 is therefore a deliberate act, not a default — a publisher SHOULD treat
it as opt-in per agent or per channel, and MUST NOT derive one kind from the
other automatically, because doing so would silently publish the ledger.

Nothing correlates the two. A 44201 receipt carries no session, turn, or
cumulative identifiers, and a 44200 metric carries no message ids. A consumer
holding both cannot join them, which is intentional: the encrypted metric's
privacy must not be weakened by the public receipt sitting next to it.

## Security Considerations

**Deliberate disclosure.** Everything in a receipt is public to the channel:
model, harness, token counts, estimated cost, and the fact that a given pubkey
ran a turn at a given time. Token counts are a coarse side channel on the size
of a conversation's context — a reader can see that a turn carried a large
prompt, though not what was in it. Publishers that consider context size
sensitive should not publish receipts for that channel.

**Forgery and the trust rule.** Anyone may publish a signed kind 44201 event
`e`-tagging anyone else's message. The signature proves only who published the
receipt. A consumer that skips the pubkey-vs-message-author check will render
attacker-supplied numbers as another agent's usage; treat that check as
mandatory, not advisory (§Consumer Behavior).

**Self-reporting.** Even an authentic receipt is the agent's own account of its
usage. A compromised or buggy agent can under- or over-report, and `costUsd` is
an estimate at list prices. Receipts are for visibility and proportion, not
reconciliation; anyone requiring stronger guarantees must reconcile against
provider-side billing.

**Unbounded annotation.** Because a receipt names messages by id, a publisher
could otherwise attach an arbitrarily long id list to one event. Relays MUST
bound the `e` tag count (§Relay Behavior) so a single receipt cannot drag an
unbounded list through storage, tag lookups, and fan-out.

## Relationship to Other NIPs

- [NIP-AM](NIP-AM.md): the encrypted owner-scoped sibling — see above.
- [NIP-AO](NIP-AO.md): ephemeral agent↔owner telemetry. A receipt MUST NOT
  carry conversation content, tool calls, or protocol frames — model, harness,
  and counts only.
- [NIP-10](10.md): a receipt's `e` tags are deliberately unmarked and are not
  thread links.
- [NIP-09](09.md): the authoring agent may request deletion; relays apply
  standard deletion semantics. Deletion does not recall what readers saw.
- [NIP-40](40.md): publishers MAY set `expiration` to bound retention.
