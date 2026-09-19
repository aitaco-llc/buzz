# aitaco Desktop lane

This lane builds our own macOS Buzz Desktop from `aitaco-llc/buzz`. It is signed under Apple team `5F7YLJS4YR` and updates from our own feed.
- The lane script is `scripts/aitaco/desktop-release.sh`.
- Builds run on the Mac. Signing, notarization and the updater private key never leave it.
- This file and the script live under `aitaco/` paths, so a Block fix we take (`UPSTREAM.md`) cannot conflict with them. Block's `RELEASING.md` and `release.yml` do not apply. `release.yml` is disabled on the fork.

Status: written on hip, where nothing Apple can be built. The first run on the Mac settles the items under "Unverified".

**Blocked (2026-09-19): no Developer ID Application certificate.** The build Mac has none for any team. The only `5F7YLJS4YR` identity there is `Apple Development` (jessie, #buzz-platform). Getting one is Lloyd's call, or woody's as the team's portal admin. Everything else in "One-time setup" is done except the environment file.

## Identity

| | Value | Why |
|---|---|---|
| Bundle identifier | `co.aitaco.buzz.desktop` | Keeps our app's data, single-instance socket, agent marker and updater separate from Block's. It is set in the generated release overlay, so `tauri.conf.json` keeps Block's value and a Block merge never touches it. |
| Dev identifier | `xyz.block.buzz.app.dev`, unchanged | `migration.rs:24,48-53` recognises dev builds by this exact name. A dev build under any other name is treated as production and uses `~/.buzz`. |
| Product name / executable | `Buzz` / `buzz-desktop`, unchanged | `instance_reaper.rs:5-12` decides whether a desktop is alive by these names. Under any other name, a Block Desktop on the same Mac would kill our agents every 60 s. |
| Keychain item | service `buzz-desktop`, account `secrets`, unchanged | This name is fixed for every release build (`app_state_keyring.rs:9-23`), so our build reads the **same** identity key as Block's. |
| Deep link | `buzz://`, unchanged | Hard-coded in `build_identity.rs:49-53`. macOS routes it to one app, so remove Block's app. |

## Versions and tags

- Tags have the form `aitaco-desktop-vX.Y.Z` on `aitaco-llc/buzz`. They never match upstream's `desktop-v*`, `relay-v*`, `mobile-v*`, `chart-v*`, `push-chart-v*` or `sprig-v*`.
- Our version line starts at `1.0.0` and only goes up:
  - The script refuses a version that is not above the one the feed serves.
  - The updater never downgrades. `tauri-plugin-updater` only offers `release.version > current`.
- The script sets the version in the working tree at build time and reverts it on exit. Tracked files keep upstream's version.

## Updater

- **Feed:** `https://github.com/aitaco-llc/buzz/releases/download/aitaco-desktop-latest/latest.json`. `aitaco-desktop-latest` is a release that only holds `latest.json`. Do not delete it: installed apps read it.
- **When the updater exists:** it is compiled in only when `BUZZ_UPDATER_PUBLIC_KEY` and `BUZZ_UPDATER_ENDPOINT` are both set (`desktop/src-tauri/build.rs:128-139`). The script sets both.
- **Why Block can't replace our build:**
  - Our app carries only our key and our feed.
  - Block's updater can only replace the bundle it runs from.
  - After the first install below, Block's app is gone.

## One-time setup on the Mac

1. **Signing identity.** `security find-identity -v -p codesigning` must list a `Developer ID Application: … (5F7YLJS4YR)`. If none exists, stop. Creating one is Lloyd's call.
2. **Notarization key.** An App Store Connect API key (`.p8`) with its key id and issuer id, for `notarytool` through Tauri.
3. **Updater keypair: done 2026-09-19 by jessie.** She ran `node_modules/.bin/tauri signer generate`, not `pnpm tauri`, because the pnpm wrapper echoes the password.
   - **Key id `77A198D97C39AD51`.** The script pins it (`AITACO_UPDATER_KEY_ID`). It refuses a public key or an updater signature from any other key.
   - **Public key** (for `BUZZ_UPDATER_PUBLIC_KEY`):
     `dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDc3QTE5OEQ5N0MzOUFENTEKUldSUnJUbDgyWmloZDRXUUZ6bUE2aXlORzRGdzQwMHE3YUJHa21aQnA0NnZSaGpET2RBL21ZK1IK`
   - **Private key:** `~/.tauri/aitaco-buzz-updater.key` on the Mac (mode 600). Its password is in the login keychain, service `aitaco-buzz-updater-key-password`.
   - **Losing the private key strands every installed copy,** because they only accept updates signed by it. It is not backed up anywhere yet. Back it up where Lloyd keeps secrets.
4. **Tools.** `jq`, `gh` (logged in with release rights on `aitaco-llc/buzz`), Xcode command-line tools. Hermit supplies Rust, Node, pnpm and just.
5. **Environment file.** Create it outside the repo, e.g. `~/.config/aitaco/desktop-lane.env`, mode `600`:
   ```bash
   APPLE_SIGNING_IDENTITY="Developer ID Application: <name> (5F7YLJS4YR)"
   APPLE_API_ISSUER=<issuer uuid>
   APPLE_API_KEY=<key id>
   APPLE_API_KEY_PATH=$HOME/.appstoreconnect/AuthKey_<key id>.p8
   TAURI_SIGNING_PRIVATE_KEY=$HOME/.tauri/aitaco-buzz-updater.key
   TAURI_SIGNING_PRIVATE_KEY_PASSWORD=<password>
   BUZZ_UPDATER_PUBLIC_KEY=<contents of the .pub file>
   ```

## Releasing

From a clean checkout of a commit on `aitaco/main`:

```bash
set -a; . ~/.config/aitaco/desktop-lane.env; set +a
scripts/aitaco/desktop-release.sh 1.0.0            # build and verify; prints artifacts and sha256s
scripts/aitaco/desktop-release.sh 1.0.0 --publish  # also tag, create the release, move the feed
```

**Before it builds, the script checks:**
- it is on an Apple Silicon Mac
- the tree is clean, with no untracked files either
- the version is above the one published. The feed must answer: only a 404 counts as "no feed yet".
- all signing variables are set, for team `5F7YLJS4YR`
- the updater public key is key `77A198D97C39AD51`

It then builds with every `BUZZ_*` variable cleared except the updater's. `build.rs` would otherwise bake `BUZZ_RELAY_URL` and `BUZZ_BUILD_*` from the shell into the app.
- with `--publish` only: `HEAD` is on `aitaco-llc/buzz` `main` and the tag is new. A build-only run may test a branch.

**It builds:**
- the six sidecars
- the app from the release overlay, without `--features mesh-llm`. We don't run Share Compute, and leaving it out skips the llama.cpp build.

**It fails unless all of these hold:**
- the bundle id, version and executable name are the expected ones
- the signature verifies under `codesign --verify --deep --strict`
- the TeamIdentifier is `5F7YLJS4YR`
- `spctl` accepts the app
- the stapled ticket validates
- the entitlements pass `desktop/scripts/verify-macos-entitlements.sh`
- the updater archive and its signature exist, and the signature is from key `77A198D97C39AD51`
- the DMG, which Tauri signs but does not notarize, is notarized, stapled and accepted by `spctl`

**Artifacts** stay in `~/.local/state/aitaco-desktop-releases/<version>/`.

**`--publish` steps:**
1. It creates the release as a draft, then publishes it. A draft makes no tag, so a failed upload can be deleted and the run repeated.
2. It checks the feed again, then moves it.

If moving the feed fails, finish by hand with `gh release upload aitaco-desktop-latest -R aitaco-llc/buzz ~/.local/state/aitaco-desktop-releases/<version>/latest.json --clobber`. The script confirms the feed serves the new version. Then post the release in #buzz-platform: version, commit, identifier, and one line on what changed.

## First install on Lloyd's Mac (from Block's Buzz)

This needs Lloyd's go at the time, and rock's go for the Mac seats (see "Mac seats" below). Here is what survives, and how:

| What | Where it lives | How it survives |
|---|---|---|
| Identity key, agent keys | Login keychain `buzz-desktop`/`secrets` | Shared by name. On first read our app asks for keychain access once. Choose **Always Allow**. |
| Communities (relay URL, token), theme and other UI preferences | WebKit localStorage, `~/Library/WebKit/<identifier>` | Copied in step 2 |
| Settings, managed agents, templates, caches | `~/Library/Application Support/<identifier>` | Copied in step 2 |
| Archive, nest | `~/.buzz` | Shared by path, nothing to do |
| Camera, microphone, notification and local-network permissions | macOS, per app | Not carried. They are asked for again on first use |

**Steps:**

0. **Back up the key.** In Block's Buzz, export the encrypted key backup (`create_ncryptsec_backup`, `desktop/src-tauri/src/lib.rs:555-559`) to a file Lloyd keeps.
1. **Quit Block's Buzz completely.** `pgrep -x buzz-desktop` must print nothing. Its managed agents stop with it.
2. **Copy its data under the new identifier:**
   ```bash
   OLD=xyz.block.buzz.app NEW=co.aitaco.buzz.desktop
   AS="$HOME/Library/Application Support"; WK="$HOME/Library/WebKit"
   test ! -e "$AS/$NEW" && test ! -e "$WK/$NEW"      # never copy over an existing profile
   ditto "$AS/$OLD" "$AS/$NEW"
   ditto "$WK/$OLD" "$WK/$NEW"
   ls "$AS/$NEW/identity.migrated" "$AS/$NEW/identity.key" 2>/dev/null   # at least one must exist
   ```
   `identity.migrated` must be in the copy. With it, a denied keychain read shows the recovery screen. Without it, the app silently creates a new identity (`app_state.rs:540-556`), and a later launch can write that new key over the shared keychain entry. If neither file exists, stop.
3. **Move Block's app aside** and never launch it again: `mv /Applications/Buzz.app ~/Buzz-block.app`.
4. **Install ours** from the DMG to `/Applications/Buzz.app` and launch it. Answer the keychain prompt with **Always Allow**.
5. **Verify:**
   - the npub is the same as before
   - the communities are listed and `buzz.aitaco.co` connects
   - the agents are listed
   - `ps -E -ww -p "$(pgrep -x buzz-desktop)" | tr ' ' '\n' | grep __CFBundleIdentifier` shows `co.aitaco.buzz.desktop`
6. **After a week of normal use,** delete `~/Buzz-block.app` and the two `xyz.block.buzz.app` folders. Until then they are the rollback: quit ours, then move Block's app back. Its folders were never touched.

## Do not

- **Do not use Sign out or Reset in our build.** It removes the shared keychain item and `~/.buzz` (`reset.rs:244-246,272-273`), and both are shared with Block's build and with anything else using the nest.
- **Do not run Block's Buzz and ours at the same time after the copy.** Both would start the same managed agents (`managed_agents/restore.rs:174-200`), and each agent would then run twice on the relay.
- **Do not rename the executable** (`mainBinaryName`) or the product.
- **Do not publish a version at or below the feed's.** The script refuses it, and an installed app would ignore it anyway.

## Mac seats: settle this before the first install

The fleet's Mac seats run under launchd from `aitaco-llc/agents`, not under Desktop. Neither `master` nor `metal-launchd` sets `BUZZ_MANAGED_AGENT` (`git grep`, 2026-09-19: 0 hits), so the marker-based sweeps (`instance_reaper.rs`, `orphan_sweep.rs`) leave them alone.

But the seats get their binaries from the app bundle. `deploy/deploy.sh:105-106` on `metal-launchd` links `buzz` and `buzz-acp` to `/Applications/Buzz.app/Contents/MacOS/`. That has two consequences, read from code and not yet observed on the Mac:
- **Desktop kills the seats when it starts.** `sweep_untracked_bundle_harnesses` (`desktop/src-tauri/src/managed_agents/runtime/sweep.rs:492-520`) runs at Desktop boot. It kills every `buzz-acp` whose resolved path is the bundle's own `Contents/MacOS/buzz-acp` and that Desktop did not start itself, with no marker check. If the seats run through that symlink, every launch of Buzz Desktop, Block's today and ours tomorrow, kills them, and launchd restarts them.
- **Installing `Buzz.app` is a harness deploy for the Mac seats.** Replacing the bundle swaps the `buzz-acp` they run. The next Desktop start then kills them onto the new binary.

So the first install waits for rock. Either the seats move off the bundle's binaries first (their own `buzz-acp` outside `Buzz.app`), or rock schedules the install as a Mac seat deploy. To confirm on the Mac:
- `readlink ~/.local/bin/buzz-acp` shows where the link points.
- `ps -o pid,lstart,command -p <seat pids>`, compared with when Buzz last started, shows whether the seats restart with Desktop.
- `ps -E -ww -p <seat pid> | grep -c BUZZ_MANAGED_AGENT` should print 0.

## Unverified until the first Mac run

- That Tauri 2 signs, notarizes and staples in one `tauri build`, given the `APPLE_*` variables. `release.yml` signs after the build instead, with Block's action.
- Whether copying `~/Library/WebKit/<identifier>` carries localStorage across identifiers. Both use the same `tauri://localhost` origin. If it doesn't, re-add the community by URL.
- Whether a Finder-launched release process carries `__CFBundleIdentifier` in its environment. The reaper relies on it to see a release desktop as alive.
- How the keychain prompt behaves for an item created by Block's signed app, and whether "Always Allow" survives our rebuilds.

## Still pointing at Block (see `RESEARCH/BUZZ_BLOCK_DEPENDENCIES.md` on hip)

- The hosted-community buttons call Block's Builderlab (D1). Lloyd decides whether to hide them.
- The manual-update link (`use-updater.ts:33`) and the invite page's download buttons point at `block/buzz`.
- `buzz channels create --template` reads Block's data folder (`crates/buzz-cli/src/commands/channel_templates.rs:18`). Pass `--templates-file`.
