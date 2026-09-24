# Native iPad implementation and parity tracker

The goal is **all existing iOS app features in Swift**, deployed as a new app in
Aitaco's TestFlight account. This tracker does not narrow that goal to the initial
messaging implementation. Implementation is not proof of parity: protocol tests,
UI tests, and real community/device evidence are distinct gates.

Source inventory: `mobile/lib/features/{activity,age_gate,channels,forum,home,
invites,pairing,profile,pulse,search,settings}`, `mobile/lib/shared/`, and native
code under `mobile/ios/Runner`, `BuzzPushKit`, and `NotificationService`.

| Surface | Current native implementation | Remaining parity and verification |
|---|---|---|
| Native iPad shell | SwiftUI sidebar; adaptive conversation/thread columns; Dynamic Type text; labels; Cmd+K, Cmd+Return | Split View/Stage Manager, hardware keyboard navigation, VoiceOver audit, reduced motion, all supported sizes/orientations |
| Identity and onboarding | nsec/hex import, atomic Keychain account storage, camera QR/paste-link NIP-AB receiving with dual consent, permission/retry/cancellation UI, NIP-98 requests, NIP-42 live auth, invite joins, and iOS Declared Age Range fail-open gate | Physical camera and real desktop pairing verification, identity export/recovery mode, new identity onboarding, complete membership errors/recovery, age-restricted notification purge parity |
| Communities | Multiple saved communities, isolated stores, switching | Leave/remove flow and durable notification revocation, secure credential cleanup, restore selected community, settings parity |
| Channels | Relay-authoritative joined membership and metadata, paginated open-channel browser and joined refresh, durable join/leave requests with verification and recovery, durable NIP-29 channel creation, metadata editing, archive/delete and add-member commands, draft preservation, stream/forum/DM grouping, persistent local channel stars and mutes with sidebar ordering/actions | Real-relay join/leave/create/edit/archive/delete/add-member verification, private-channel departure when the roster becomes inaccessible, live revocation, permissions, TTL/ephemeral channels, custom sections, DM hide/resurface |
| Conversation reading | Verified cache, signed NIP-CW pages, two-hop aux closure for channel/thread history, composite cursors, indivisible page saves and failed-page recovery, author edits/deletions including withdrawn edits, nested-parent projection, channel-scoped live delivery in compact thread views, native Markdown links/emphasis, bounded fenced-code blocks with copy and lightweight token highlighting, manual refresh, reply counts for explicit and legacy thread tags, and per-community persistent thread follow/unfollow actions | Real-relay paging/reconnect reconciliation, active-history cache pinning, relay-authoritative deletions, message pinning, language-specific grammar coverage, large timeline performance |
| Compose and send | Durable text drafts/outbox, channel and forum posts/replies, Cmd+Return, pending/error display, explicit retry, member-first `@` suggestions and unambiguous exact-name `p` tags; Markdown is rendered on read; composer Preview toggle uses the same bounded renderer without changing the draft | Rich compose toolbar/formatting controls, media attachment drafts, per-action recovery/edit/cancel UI, automatic connectivity-triggered retry, lifecycle durability under termination |
| Reactions and message actions | Shared Unicode/skin-variant catalog, category/search picker, recent choices, signed custom emoji palette and static thumbnails; unique-person counts, own highlighting, add/remove/re-add, who-reacted sheet; copy text/message link, edit, delete with confirmation, follow threads, local notification reminders that deep-link back to the message | Animated/vector custom emoji and creation/upload, real-relay interoperability, moderation/report/block flows, attachment actions |
| DMs | Read/send existing DMs; participant labels and p-tags; new 1:1/group DM recipient picker backed by kind:41010 command response and channel hydration | Authoritative membership refresh before sends, encrypted interoperability where existing client supports it, urgency, lifecycle rules |
| Forums | Read/post/reply with correct event kinds | Full card rendering, forum-specific actions, pagination, drafts, media and mention parity |
| Home, activity and pulse | Activity sheet lists cached mentions, replies, and reactions with channel/thread navigation; Pulse loads global kind:1 notes, filters to the current user, durably posts new notes, and supports heart reactions | Home feed, grouped inbox/read state, reminders/snooze, following/liked/agent timelines, and transcript observer UI; live activity hydration |
| Search | Relay NIP-50 search, bounded pagination with timestamp/event cursors, errors, generation fence, channel-scope filter, result opening | Exact selected-message navigation/scroll highlight, thread-root hydration and inaccessible-content recovery |
| Unread state | Encrypted NIP-44 kind:30078 read-state snapshots, durable local/outbox writes, channel unread counts including replies, sidebar badges, mark-on-open and relaunch recovery | Cross-device live reconciliation, forced-unread overrides, jump-to-oldest-unread behavior, activity/inbox read state |
| Presence and typing | NIP-42 WebSocket ephemeral presence (`online`/`away`/`offline`), throttled composer typing events, 8-second expiry and channel/thread typing indicator | Lifecycle-driven presence heartbeats, persistent preference, richer presence badges and accessibility/device verification |
| Media | NIP-92 `imeta` parsing, MIME-first classification, bounded URL extraction, native image loading, authenticated Blossom image upload, photo picker, voice-note recording/upload, full-screen zoomable image viewer, AVKit video viewer/share, and audio links | Blossom file/video/camera/GIF input, image sanitation, thumbnails, upload progress/cancel/retry, physical-device verification |
| Voice notes | AVFoundation AAC recording with a five-minute bound, microphone permission declaration, authenticated Blossom upload, `imeta` metadata, streamed playback controls, and audio-link rendering | Waveform preview, interrupted-recording recovery, physical-device microphone verification |
| Huddles | Reuses the existing Swift Opus capture/playback engine; native signed start/end lifecycle events, dedicated WebSocket NIP-42 admission, Opus v2 framing, peer roster, remote playback, mute, huddle sheet, and reactions | Route controls, interruption/background teardown, reconnect policy, real-room and physical-device verification |
| Profiles | Display-name lookup; native other-person profile sheet with verified cached fields, avatar, status, and public-key copy; text profile editor retaining other known fields; Blossom-backed profile picture picker with orientation normalization and bounded square crop; NIP-38 status editor with emoji, clear, expiration-aware hydration, and durable retry | Profile hydration/conflicts, avatar camera/emoji/animated editing, richer profile actions, presence |
| Themes and preferences | Persisted system/light/dark scheme, seven native accent choices, semantic SwiftUI colors, and Settings controls | Shared theme catalog, typography preferences, notification/privacy settings, community-specific preferences |
| Push notifications | Native Settings exposes authorization/APNs state and iOS recovery; app requests authorization and registers APNs, buffers tokens/errors, exports verified community/profile/channel state to the App Group snapshot, embeds the Swift `NotificationService` extension, and routes cold/warm notification targets into message deep links | Gateway enroll/renew/revoke journal, avatars/privacy/read suppression parity, portal capability/profile verification, physical iPad push test |
| Links and invitations | Handles message links, canonical HTTPS and `buzz://join` invite links, native invite creation/share/copy, relay invite claiming with a new Keychain identity, and community routing | QR/deep links beyond messages, notification links, invalid/expired/inaccessible target UX, starter-channel recovery |
| Offline and recovery | Separate atomic intent/cache files, scoped stores, bounded retry/cache, persisted errors, joined-channel cache pinning, durable membership recovery independent of cached metadata | Cache rebuild/recovery UI, complete storage failure UX, broader eviction policy, automatic sync, migration/update/restart stress, background lifecycle tests |
| Accessibility | Native controls, semantic text sizes, labeled buttons | End-to-end VoiceOver, duplicate-stop audit, keyboard-only use, larger sizes/contrast/reduced-motion tests |
| Distribution | Native app project now uses Aitaco team `5F7YLJS4YR`, bundle `co.aitaco.buzz`, embeds `co.aitaco.buzz.NotificationService`, and declares the requested push/App Attest/age-range/communication/app-group entitlements | Register/assign the App Group, enable portal capabilities, regenerate profiles, and complete signed archive/TestFlight verification |

## Next implementation priorities

1. Complete onboarding/pairing and live community verification; scope-safe
   membership revocation and real-relay history/reconnect verification.
2. Fill messaging parity: channel management, Blossom attachments and upload,
   thread actions, home/pulse, presence lifecycle and typing.
3. Port native media/audio and notification extension integrations; wire
   preferences, invites, age eligibility and moderation.
4. Run the full iOS feature matrix on iPad, including offline/reconnect,
   community changes during async work, accessibility, and a physical device.
5. Complete the signed-in Apple setup recorded in [DISTRIBUTION.md](DISTRIBUTION.md),
   reconcile the prototype bundle identity, then sign/upload the Aitaco app
   after it is ready to review.

## Release evidence required

- New App Store Connect app and bundle ID belong to Aitaco; record numeric app ID.
- Explicit APNs/app-group/extension entitlements match that new app.
- All parity rows implemented and verified against their actual workflows.
- Native unit/network tests and simulator UI suite pass; physical iPad push,
  camera/microphone/huddle and background/reconnect tests pass.
- Release archive builds, signs under Aitaco, and validates for distribution.
- Required privacy manifest, permission strings, privacy/export declarations,
  beta details and review credentials are populated truthfully.
- Uploaded build finishes processing and appears in the intended TestFlight
  testing group. Record version, build number and App Store Connect URL.

Do not mark the overall goal complete based on the core or simulator tests alone.
