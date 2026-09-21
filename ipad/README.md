# Buzz for iPad — native Swift client

A standalone SwiftUI iPad app, with no Flutter or Dart runtime. The existing
`mobile/` iOS app is the behavioral reference; `VISION_MOBILE.md` remains the
product contract. This is active implementation, **not feature complete or
ready for TestFlight distribution**. See [PARITY.md](PARITY.md) for the full
remaining scope and [TESTING.md](TESTING.md) for verified workflows.

Open `BuzzNative.xcodeproj` and select the **Buzz** scheme. The checked-in
project is generated from `project.yml` with XcodeGen. Requires Xcode 26 or
later (Swift 6.1+ for the pinned crypto dependency), iPadOS 17+, and XcodeGen
when regenerating the project.

```sh
# Full native check: packages, formatting, simulator workflow, unsigned Release.
ipad/scripts/check.sh

# Or individual commands:
cd ipad
xcodegen generate
swift test --package-path BuzzCore
xcodebuild -project BuzzNative.xcodeproj -scheme Buzz \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData -skipPackagePluginValidation build
```

`swift-secp256k1` is pinned to 0.23.2. Its reviewed `SharedSourcesPlugin` copies
Swift source files from the package's `Sources/Shared` into its build directory.
The command-scoped `-skipPackagePluginValidation` permits that build plugin in
headless builds; it does not change Xcode's global trust settings. Review the
plugin again when upgrading this dependency. The previous 0.21.1 pin does not
compile with Xcode 27's standard library (`UInt256.words` ambiguity).

## Architecture

- `Buzz/`: SwiftUI app, iPad sidebar, conversations and adjacent threads,
  community selection, search, profile settings, Keychain credentials.
- `BuzzCore/`: signed Nostr events, NIP-98 HTTP bridge, NIP-42 live subscriptions,
  channel/message projections, and actor-isolated durable storage.
- `../mobile/ios/BuzzPushKit/`: shared event verification and existing native
  notification primitives. Sharing the package does not mean push is integrated
  into this app yet.
- `BuzzUITests/`: exercises the production UI/store through a local fixture
  relay compiled only in Debug. There are no demo credentials in Release.

### Two build systems compile `Buzz/`

`project.yml` generates `BuzzNative.xcodeproj` — the standalone app that
`scripts/check.sh` and the `native-ipad` CI job build. `Package.swift` builds
the same directory as the `BuzzPadApp` library, which the universal Flutter app
links as a local package (`mobile/ios/Runner.xcodeproj`) and launches on iPad
from `mobile/ios/Runner/main.swift`. The `Mobile Swift` CI job builds that one.

They reach shared `mobile/` sources differently. The xcodegen side names them by
path and excludes `Buzz/Embedded/**`; SwiftPM cannot reference sources outside
its target path, so the same files appear as symlinks *in* `Buzz/Embedded/`.
**Adding a shared file means doing both** — a `project.yml` entry and an
`Embedded/` symlink. Only the first leaves `native-ipad` green while
`Mobile Swift` fails with `cannot find <Type> in scope`. The two copies land in
different modules, so there is no duplicate symbol. `HuddleAudioEngine.swift`
and `MediaSanitizer.swift` are the current examples.

`check.sh` does not build the universal app. To check that path:

```sh
export PATH="$PWD/bin:$PATH"   # hermit; there is no system flutter
cd mobile && flutter pub get && flutter build ios --simulator --debug --no-pub
```

The identity is stored in Keychain, never preferences or an event cache. Account
metadata and credentials share one Keychain record, so successful imports
remain discoverable after a restart without a separate manifest write. Records
are accessible only while the device is unlocked and never migrate to another
device. The initial prototype's metadata manifest is migrated on startup.
Local stores are partitioned by canonical community origin **and** public key. A
separate intent journal holds drafts and signed pending events. Moving a draft
to the outbox is one atomic save. Accepted events enter the cache before the
journal entry is removed. Retry sends the same event ID. Only the currently
implemented idempotent event kinds are admitted to this outbox; moderation
commands must not be added without their distinct ambiguity/retry contract.

Channel discovery verifies the relay signing key from NIP-11's `self` field.
Joined-channel refresh and the open-channel browser use bounded composite-cursor
pages, including events with equal timestamps. Joined membership and metadata are
pinned against message-cache eviction; superseded rosters are removed together.
Channel membership commands have their own durable journal: a successful publish
receipt alone does not prove that a join or leave took effect. The client checks a
relay-signed roster, retains unconfirmed requests across restarts, and offers
status checks, an explicitly confirmed new attempt, or dismissal. Retry uses the
saved request even if channel metadata has been evicted. Leaving preserves drafts.

The composer recognizes profile names after `@`, ranks channel members first,
and adds `p` tags only for unambiguous exact-name mentions. Fuzzy suggestions
never silently retarget a recipient.

The composer has a Preview toggle that renders the current draft with the same
bounded Markdown and fenced-code renderer used by message rows. Preview is
local UI state and never changes the draft or send path.

The composer can record a bounded AAC voice note, upload it through Blossom,
and send the authenticated audio attachment with its `imeta` descriptor.

Message rows parse NIP-92 `imeta` tags and use bounded native image loading for
recognized attachments. The composer can pick an image, upload it through the
authenticated Blossom endpoint, and send its URL plus `imeta` tag atomically
with the message. Tapping an image opens a full-screen zoomable viewer with
sharing; video attachments open an AVKit viewer, while audio uses native
playback controls.

The sidebar can create one-to-one or group DMs by submitting kind `41010`,
validating the relay's returned channel ID, and hydrating signed metadata and
membership events before selecting the new conversation.

Stream and forum channels can be starred or muted from their sidebar context
menu. These choices are stored locally in the same atomic preferences snapshot;
stars sort first and mute state is visible without changing relay membership.

Message links using `buzz://message?channel=…&id=…` are accepted on warm and cold
launches; uncached events are hydrated before the channel and thread are opened.

Community invites are supported from Settings. Authorized members can mint a
bounded invite at `/api/invites`, copy or share its canonical HTTPS link, and
the app accepts both that link and `buzz://join` handoffs. Claiming an invite
generates a new identity and stores it in the Keychain only after the relay
accepts the claim.

On iOS 26 and later, the app requests the system Declared Age Range for the
18+ gate. An explicit under-18 range shows the restriction screen; unavailable
or declined checks fail open so launch and existing-account recovery remain
available.

Settings includes device-local appearance controls for System, Light, or Dark
mode and seven accent colors. These choices are persisted as a single local
snapshot and never leave the iPad or enter relay events.

The native target requests notification permission and registers for APNs, and
ships the existing Swift notification-service extension in the Aitaco app
bundle. APNs registration updates are buffered, verified community/profile/
channel state is exported to the Aitaco App Group snapshot, and notification
targets route through the same message deep-link path on warm and cold launch.
Gateway enrollment and lease renewal remain dependent on the production push
service. Settings shows authorization and APNs registration state and provides
the iOS notification-settings recovery path.

Huddles use a separate native WebSocket for NIP-42 admission and binary Opus
v2 media. The Swift engine captures and plays audio on the iPad, while the
transport handles peer roster changes, bounded framing, mute, and teardown.
The app still needs a real relay and physical-device verification for route,
interruption, background, and reconnect behavior.

The channel directory can also create public or private stream/forum channels.
Creation is signed as kind `9007`, stored in the durable outbox, and retried
through the normal relay recovery path.

Channel details can edit the name and description with a durable kind `9002`
metadata command before retrying delivery.

The same details sheet exposes explicitly confirmed archive and delete actions;
these queue kind `9002` archive and kind `9008` delete commands for relay retry.

It also lists channel participants and accepts a validated public key for a
durable kind `9000` add-member command, including the requested role.

The live connection also publishes NIP-42 authenticated ephemeral presence and
typing events. Typing indicators are scoped to the channel or thread and expire
after eight seconds without entering the durable message cache.

Message context menus can follow or unfollow a thread. Followed root IDs are
bounded and persisted per community and identity so the preference survives
relaunches without adding relay state.

Settings also publishes the current user's NIP-38 status as a replaceable
kind `30315` event, preserving the emoji and expiration tags and retaining it
in the durable outbox until the relay acknowledges it.

Profile settings can choose an image, upload it through Blossom, and publish the
resulting `picture` URL while preserving the other known profile fields.

The sidebar also exposes Activity and Pulse. Activity derives bounded mentions,
replies, and reactions from verified cached events with channel/thread navigation.
Pulse queries the global kind `1` note stream, supports a current-user filter,
supports durable heart reactions, and queues new notes durably before retrying
delivery.

An empty membership response is not proof of departure. In particular, leaving a
private channel may make its new roster inaccessible; this currently leaves an
unconfirmed request with recovery controls. Live revocation and that private-channel
case still need end-to-end implementation and verification against a real relay.

Conversation history uses NIP-CW pages of 50 top-level rows with their auxiliary
events. The client checks the relay signature, exact channel/request binding and
cursor progress before using window bounds; only those bounds establish exhaustion.
It echoes the relay's scan cursor even when the corresponding row was not delivered.
Unsupported head windows fall back to a clean standard query. Thread replies use
the recursive query's ascending composite cursor in pages of 200. They request
the bridge's two-hop auxiliary closure for the root and returned replies, so
existing reactions, edits, and their author deletions arrive with the page.
Auxiliary events never count toward the reply limit or advance its cursor.

Message bodies use Swift Foundation Markdown parsing on the signed source text,
preserving emphasis and link attributes with a plain-text fallback for parser
failures. Links remain native SwiftUI text interactions and message selection
continues to work. Fenced code blocks are split before Markdown parsing, shown
in bounded monospaced scroll views with a language label, and can be copied.
Common keywords, strings, numbers, and comments receive lightweight native
syntax colors without allowing the highlighter to change the signed text.

**Older messages** opens the history controls. Failed reads or cache writes keep
the current page and cursor available for retry. An unserved window followed by
an empty standard response retains existing cached messages. Appending pages
preserves the previous boundary in view, and **Latest** remains available. Each
view has a bounded cursor chain and cancellation generation; superseded responses
cannot install a new page. Newly arriving messages stay separate from page cursors.
The cache must retain every event in a page, including auxiliary events, before
the save can commit. An oversized page leaves the previous cache intact and an
error available for recovery instead of silently dropping its deletions.

Channel read markers use the Flutter-compatible encrypted kind `30078` payload:
the current identity encrypts a bounded context map with its NIP-44 self-key,
and the event is queued atomically before relay delivery. Opening a channel
advances its marker through all loaded messages and the sidebar counts newer
messages and replies. The marker and unread result survive restart; malformed
or foreign read-state events are ignored.

The live WebSocket subscription starts alongside history loading and remains open
after EOSE. Subscription buffers, frame sizes, HTTP response sizes, caches, pending
actions, authentication time, and reconnect attempts are bounded. After repeated
connection failure, a visible error and explicit Refresh remain available. Complete
reconnect reconciliation, active-history pinning under later cache pressure,
summary counts and production-relay verification remain parity work. Threads keep
a channel-scoped live stream even when the compact layout hides the channel view;
root-only filters would miss overlays targeting nested replies.
Channel and thread controls live in separate visible pane headers, avoiding
ambiguous duplicated controls in a shared navigation bar.

Reactions use the same Unicode catalog as the Flutter app, including skin variants,
categories and search. Community emoji come from members' latest signed NIP-30
sets; a reaction retains its own image tag. Reaction pills count distinct people,
highlight your choices, toggle removal, and offer **Who reacted**. Adding from the
picker is idempotent. Removing a reaction deletes every known duplicate from your
identity, while a later addition gets a fresh event ID. Reactions and local emoji
frequency ranking are saved in one atomic intent write before delivery.

The history/live path accepts Flutter reactions and author deletions without an
`h` tag, deriving their channel from the referenced message. Custom images use
bounded public requests without account credentials. The current renderer shows
static thumbnails; animated/vector emoji and custom emoji creation remain outstanding.

## Identity import and desktop pairing

Add community accepts a checksummed `nsec` or a 64-character hexadecimal private
key. **Pair with Buzz Desktop** scans the desktop pairing QR with AVFoundation or
accepts a copied pairing link. The camera runs on a separate serial executor;
permission denial, missing hardware and interruptions retain a paste-link fallback.
Backgrounding or closing the scanner invalidates pending detections and stops capture.
The native receiver authenticates with an ephemeral identity,
shows the six-digit comparison code, verifies the source's transcript, and only
extracts transferred credentials after the user confirms locally. It checks
community access and saves the account before sending `complete` to the desktop.
Failure to deliver that final advisory confirmation never removes a saved account.

Pairing uses NIP-44 v2 with CryptoKit SHA-256/HKDF/HMAC, the pinned secp256k1
implementation, and CryptoSwift 1.10.0 for raw IETF ChaCha20. Payloads are capped
at NIP-AB's 65,535-byte limit. Sessions last at most 120 seconds; cancellation,
authentication and input buffers are bounded. Invalid/out-of-order packets are
silently discarded as NIP-AB requires. Local tests cover the protocol vectors and
desktop-produced ciphertext, plus real local WebSocket exchanges with open and
authenticated pairing relays. Camera recognition/orientation on a physical iPad,
recovery/export mode, and a real desktop-to-iPad pairing run remain outstanding.

## Aitaco distribution configuration

The user selected a **new** Aitaco app, then supplied the already registered
`co.aitaco.buzz` identifiers. See [DISTRIBUTION.md](DISTRIBUTION.md) for the
verified Apple API state and remaining signed-in setup. The local prototype
currently uses:

- Bundle ID: `com.aitaco.buzz.ipad` (prototype only; reconcile with the user’s
  registered `co.aitaco.buzz` identity before production signing).
- Development team: `5F7YLJS4YR`, the Aitaco LLC team documented in the local
  Aitaco Abracade project's signing configuration.
- Scheme: `Buzz`, version `0.1.0`, build `1`.
- Device family: iPad only. All four iPad orientations; resizable native UI.
- Existing Buzz icon reused from the iOS source app.

An unsigned device Release build has been verified. No App Store Connect app
record, provisioning profile, push capability, signed release archive, or
TestFlight upload has been verified. App registration, notification
extension/app-group configuration, archive signing, privacy/export declarations,
and beta metadata remain part of this goal. Do not describe this build as
TestFlight-ready until the release checklist in PARITY.md is complete.
