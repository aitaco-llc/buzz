# Aitaco Apple setup — verified 2026-09-18

The user supplied the following intended Apple setup for Buzz:

| Item | Value |
|---|---|
| Developer team | `5F7YLJS4YR` |
| App bundle identifier | `co.aitaco.buzz` |
| Notification extension | `co.aitaco.buzz.NotificationService` |
| App Group | `group.co.aitaco.buzz` |
| App Store Connect name | `Buzz by aitaco` (availability unverified) |
| SKU | `buzz` |
| Home-screen name | `Buzz` |

The native app target now uses `co.aitaco.buzz`, embeds the existing
`co.aitaco.buzz.NotificationService` source, and declares the requested
entitlements. Portal-side group/capability configuration still needs to be
completed before production signing. No native build has been uploaded.

## Live API evidence

Authenticated using the existing local Aitaco App Store Connect API key. No
private key or JWT is stored in this repository or these notes.

- `co.aitaco.buzz`: resource `6FACXY989T`, seed/team `5F7YLJS4YR`.
  Enabled capabilities: `IN_APP_PURCHASE`, `PUSH_NOTIFICATIONS`, `APP_GROUPS`.
- `co.aitaco.buzz.NotificationService`: resource `6VGJBTMZ3B`, same seed/team.
  Enabled capabilities: `IN_APP_PURCHASE`, `APP_GROUPS`.
- Querying App Store Connect apps by exact bundle ID `co.aitaco.buzz` returned
  no app records accessible to this key.
- Direct attempts to enable `APP_ATTEST`, `USERNOTIFICATIONS_COMMUNICATION`,
  and `DECLARED_AGE_RANGE` through `POST /v1/bundleIdCapabilities` each returned
  HTTP 409, code `ENTITY_ERROR.ATTRIBUTE.TYPE`. Apple explicitly rejected each
  value as unsupported. A subsequent capability read confirmed no changes.
- Apple's downloaded public OpenAPI specification version 4.4.1 exposes no
  App Group resource endpoints and no `POST /v1/apps`. Enabling `APP_GROUPS`
  is distinct from registering and assigning the actual group identifier.
- Apple's current App Store Connect API documentation explicitly says not to
  use the API to create new apps; app records must be created in the App Store
  Connect website.
- App Group registration and membership could not be verified through this
  public API. Do not claim that `group.co.aitaco.buzz` is missing or configured
  solely from the `APP_GROUPS` capability flags.

## Remaining signed-in Apple session work

An Account Holder/Admin session can complete these steps in the developer
portal and App Store Connect. Apple ID session automation via Fastlane is also
possible; its `produce` actions do not accept ASC API-key authentication and
may require interactive two-factor authentication. There was no local Fastlane
session directory or executable in this environment when checked.

1. Register or locate `group.co.aitaco.buzz`, then assign it to both bundle IDs.
2. Enable App Attest, Communication Notifications and Declared Age Range on
   `co.aitaco.buzz`.
3. Create the App Store Connect app with bundle ID `co.aitaco.buzz`, SKU `buzz`,
   and name `Buzz by aitaco`, subject to Apple's name availability check.
4. Regenerate/download provisioning profiles and inspect the actual signed
   entitlements before claiming that signing is unblocked.

The push certificate is deferred as the user requested. This setup is not a
build upload approval, and no messages have been sent to woody or jessie.

Sources:
- [Apple public API specification](https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip)
- [Apple: Apps API](https://developer.apple.com/documentation/appstoreconnectapi/apps)
- [Apple: Register an App Group](https://developer.apple.com/help/account/identifiers/register-an-app-group/)
- [Fastlane produce](https://docs.fastlane.tools/actions/produce/)
- [Fastlane API-key support matrix](https://docs.fastlane.tools/app-store-connect-api/)
