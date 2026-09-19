# Native iPad testing

Read the root `TESTING.md`, `VISION.md` and `VISION_MOBILE.md` first. Keep tests
bound to the production path. No infrastructure is needed for these tests.

```sh
swift test --package-path ipad/BuzzCore
swift test --package-path mobile/ios/BuzzPushKit
cd ipad
xcodegen generate
xcrun simctl list devices available
xcodebuild -project BuzzNative.xcodeproj -scheme Buzz \
  -destination 'platform=iOS Simulator,id=<IPAD-SIMULATOR-UUID>' \
  -derivedDataPath DerivedData -skipPackagePluginValidation \
  -parallel-testing-enabled NO test
```

Core tests cover signing/tamper rejection, unique NIP-98 requests, canonical
origin validation, query wire format, HTTP rejection/acceptance checks, durable
outbox failure/restart/retry, community and account isolation, draft preservation,
and author-scoped edit/deletion projections. The live socket test uses a local
Network.framework WebSocket fixture to exercise NIP-42 auth and history/live
delivery across EOSE on the production subscription.

Membership tests exercise the production journal and reconciliation manager:
lost acknowledgment/restart without replay, acknowledgment without side effects,
empty/forged/stale rosters, explicit new attempts, wrong-account rejection, and
atomic journal failure before publication. Cache pressure tests insert over
10,000 signed events to verify joined-channel pinning and roster replacement.
Discovery tests cover NIP-11 `self` rather than the operator's `pubkey`, no
credentials on public discovery, cursor violations, and 505 joined channels
sharing one timestamp. Empty discovery responses preserve cached memberships.
Cursor fixtures follow the SQL contract in `crates/buzz-db/src/store/event.rs`:
descending timestamp, ascending ID, and `id > before_id` for equal timestamps.

Conversation-page tests exercise signed NIP-CW bounds, exact request binding,
wrong-authority/signature/scope/type rejection, scan cursors for omitted rows,
empty-but-continuing and full-but-exhausted windows, two-hop aux closure, clean
fallback filters, nested/broadcast projection, and 205 same-second thread replies.
Thread cursors advance in ascending `(created_at, id)` order; channel history
advances in descending timestamp and ascending ID order. The wire-key assertions
exercise the production filter encoder.
Thread auxiliary tests send 200 same-second replies plus newer reactions and
deletions, then an empty reply page with root overlays. Only reply rows advance
the cursor. They reject unrelated and third-hop auxiliaries, wrong channels and
tampered signatures; deleted author edits fall back to the preceding edit.
The cache-pressure test also rejects a page before writing when eviction would
drop an auxiliary event, and verifies the unchanged cache after reopening it.

Reaction tests exercise distinct-person grouping, duplicate own reactions, last-e
targeting, unscoped Flutter reaction/deletion events, author and relay-authority
deletion checks, and immutable reaction image tags. The NIP-CW two-hop fixture
includes reactions and deletions without `h`. Custom palette tests cover latest
sets, replacement by an empty set, shortcode normalization and deterministic ties.
Atomic write failure and restart tests bind emoji ranking to the outgoing event.
Catalog tests cover search tiers and skin variants; an app test loads all 3,395
variants from the actual bundled Flutter asset.
Read-state tests bind the production workspace and store: a channel with an
unread message is marked read, the encrypted kind:30078 event is retained in
the durable outbox, and a newly opened store projects it as read. Invalid and
foreign encrypted markers cannot move the boundary.

Pairing tests bind the production NIP-19 importer, NIP-44 cipher and NIP-AB
receiver: official session/SAS/transcript vectors, independent desktop
ciphertext, invalid keys and QR parameters, authentication/padding/size checks,
both confirmation orders, payload opacity before consent, wrong peer/recipient,
tampering, duplicates, out-of-order retries, denial and expiration. Real local
WebSocket fixtures drive both open and NIP-42 pairing relay sessions through
credential delivery and an explicitly requested completion message.

`BuzzAppTests` runs on the iPad simulator against the actual Keychain, using a
unique service for each test. It verifies atomic account/credential discovery,
updates, legacy credential migration, when-unlocked/device-only protection, and
visible failures for malformed records. Test records are removed afterward.
An additional app test retries a durable membership request with no channel cache,
preserves its draft and display name through restart, and rejects stale retries.
Four history-state tests cover retrying the exact failed cursor, failed atomic
cache writes, a transport that completes after cancellation, live arrivals during
a head query, and preservation/recovery of cached history after an unserved window.
Reaction action tests use the production workspace, signer, store and outbox to
add, remove every own duplicate, and re-add with a fresh ID. Public image tests
exercise the production loader through URLProtocol, checking credential removal,
thumbnail caching, declared response size and decoded dimension limits.
Thread tests fetch and persist existing edits/reactions, preserve the previous
page after an invalid refresh, and recover with a fresh query. A live-transport
fixture drives the production workspace with nested-reply edits, reactions and
reaction deletions; its captured filter proves that a thread-only view subscribes
to the channel without a root-only `e` restriction. The separate local WebSocket
test continues to verify the actual NIP-42 transport.

Scanner tests use the production `PairingScanner` with controllable permission,
camera and parser boundaries. They exercise authorization/denial/restriction,
missing hardware, invalid and duplicate codes, interruption, and late permission,
camera-start and validation completions after cancellation or backgrounding. The
late-completion checks await the retired operation before asserting that it cannot
deliver a link. They do not exercise physical AVFoundation capture hardware.

The UI test runs on an iPad simulator using Debug-only `--ui-testing` fixtures.
It sends a message, opens/replies to a thread, verifies a draft and accepted
message survive relaunch, and searches. It uses the same views, event signer,
store and outbox as the app; only relay transport is replaced. Its reset flag
only removes the isolated `BuzzNativeUITests` store. Screenshots are attached to
the xcresult; use the repository screenshot posting script if opening a PR.
The second UI test reaches the native pairing screen, opens the real scanner on
the simulator, verifies the camera-unavailable fallback, returns to paste a link,
rejects invalid links, and verifies that retry remains available. A screenshot
of the scanner fallback is attached to the result bundle.
The channel workflow browses and joins an open channel, writes a draft, confirms
departure, rejoins, and verifies that the draft is restored. The directory screenshot
is retained as an xcresult attachment. These tests use the production signing,
storage, membership verification and views with a local fixture transport.
The history workflow reads a 121-message channel through three NIP-CW pages,
recovers from an injected HTTP 503 on the first older-page request, reaches the
oldest message and returns to Latest. Its screenshot is retained in the xcresult.
The reaction workflow opens the picker, searches for a heart, adds and removes
it, adds it again, and verifies the count and own-reaction highlight after relaunch.
Search is explicitly visible when the picker opens; the UI test caught its being
hidden by automatic navigation placement. Picker and reaction-pill screenshots
are retained as xcresult attachments.
The thread workflow starts with overlays held only by its fixture relay, opens
the thread, and verifies the retained edit and reaction while the deleted reply,
withdrawn edit and removed reaction stay absent. Its screenshot is attached to
the result bundle. Each pane has its own visible header; the test checks that
the channel and thread headers each expose one Refresh control, and verifies that
closing the thread leaves the channel available.

Current evidence (2026-09-18): Xcode 27; iPad Pro 13-inch (M5), iPadOS 26.5
simulator; local **Buzz Studio fixture**, not a live production community.

- BuzzCore: 53 tests pass, including both open/authenticated pairing relay
  exchanges, a live subscription exchange, membership/discovery and atomic storage
  failure injection.
- Shared BuzzPushKit: 79 XCTest cases and 42 Swift Testing cases pass.
- Native app: 36 non-Keychain tests pass (3 Keychain tests currently fail at the
  simulator `SecItemAdd` boundary with `errSecMissingEntitlement`; 7 scanner
  lifecycle, 5 membership recovery,
  6 history/live-thread recovery, 3 reaction actions, 1 emoji image loader,
  1 encrypted read-state workflow, 1 mention-tag send workflow and 1 DM
  command/channel hydration workflow, 1 status workflow, 1 age-gate decision
  workflow, 1 invite-link parsing workflow, 1 ephemeral presence/typing
  workflow, 1 huddle lifecycle workflow, 1 activity projection workflow, 1 Pulse
  projection workflow, 1 thread-follow persistence workflow and 1 deep-link
  parsing workflow pass on the iPad simulator. The credential tests remain
  enabled and must pass before the simulator gate is green.
- Native UI: 6 tests pass covering compose, reply, relaunch/draft recovery,
  search, camera fallback, invalid-pairing-link recovery, and browse/join/leave
  with draft recovery, paginated history with failure/retry, and reaction
  search/add/remove/re-add/relaunch, existing thread edits/reactions/deletions,
  and the production unread badge projection is covered by the app read-state test.
  Conversation, scanner, directory, history, picker, reaction and thread screenshots are
  retained as xcresult attachments.
- Swift formatting/lint passes. Unsigned iOS device Release build succeeds.
- CI workflow has been added but has not run remotely.
A passing fixture test does not prove live relay compatibility or device push,
audio, camera, background behavior, accessibility, or full mobile feature parity.

The huddle transport is currently verified by simulator/device compilation;
there is no fixture that can prove microphone permissions, Opus hardware
support, or admission against a production huddle relay. Those checks require
an iPad and a relay with the huddle WebSocket enabled.

When upgrading the shared crypto pin, run both package suites and build the
native iOS target. `BuzzPushKit` is also consumed by the Flutter iOS app and its
notification extension; keep its Xcode workspace resolution in sync.

## Physical camera acceptance

Before claiming camera or pairing parity, use a signed build on a physical iPad:

1. Scan a freshly generated desktop pairing QR, compare all six digits on both
   devices, confirm on both, and verify the saved community survives relaunch.
2. Deny camera permission, use the paste-link fallback, then grant permission in
   Settings and retry scanning. Also verify the restricted-permission explanation.
3. Scan an unrelated or malformed QR and then a valid pairing QR without leaving
   the scanner; no unrelated URL should open and the valid code should transfer once.
4. Close or background the scanner during permission, camera startup and detection.
   Verify the camera indicator clears and no late detection starts a pairing session.
5. Check preview orientation and decoding in all supported orientations and iPad
   multitasking sizes. Interrupt camera availability and verify retry/fallback controls.
6. Exercise the scan screen with VoiceOver, larger Dynamic Type and reduced motion.

The simulator does not prove physical recognition, camera power/indicator behavior,
preview orientation or the end-to-end desktop credential transfer.
