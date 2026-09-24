# aitaco relay lane

This lane moves `wss://buzz.aitaco.co` to a relay image built from `aitaco-llc/buzz`. The live relay is the GCE instance `buzz-relay` (zone `us-central1-a`). It runs Docker Compose from `/opt/buzz`, with `buzzctl` wrapping `run.sh` with TLS on.

- The script is `scripts/aitaco/relay-deploy.sh`. It runs on hip.
- Every live deploy needs rock's go. A deploy that changes the relay for other users is Lloyd's call.

## Images

- **What publishes them.** `docker.yml` on the fork builds `ghcr.io/aitaco-llc/buzz` (repo variable `GHCR_IMAGE`) and `ghcr.io/aitaco-llc/buzz-push-gateway` (`GHCR_PUSH_GATEWAY_IMAGE`) on every push to `main`. Its `qualify` job waits for a green `ci.yml` run on the same commit before publishing.
- **Tags.** Each image is tagged `:main` and `:sha-<7>`. Deploy by **digest** only (`ghcr.io/aitaco-llc/buzz@sha256:…`). The script refuses anything else.
- **Private packages.** GHCR creates packages private, and ours stay private. `buzz-relay` holds no registry credential. Only hip reads the registry, with `GHCR_TOKEN` (a token with `read:packages`, for example `GHCR_TOKEN="$(gh auth token)"`), and the script carries the image to the host (see `carry`).

## Commands

```bash
scripts/aitaco/relay-deploy.sh plan   ghcr.io/aitaco-llc/buzz@sha256:<digest>
scripts/aitaco/relay-deploy.sh carry  ghcr.io/aitaco-llc/buzz@sha256:<digest>
scripts/aitaco/relay-deploy.sh deploy ghcr.io/aitaco-llc/buzz@sha256:<digest> --canary-channel <uuid>
```

**`plan`** changes nothing. It prints:
- the live `BUZZ_IMAGE` and the running container's `org.opencontainers.image.revision`
- the target's revision, read from the registry
- the commits between the two revisions
- any files changed under `migrations/` and `crates/buzz-push-gateway/migrations/`

It refuses three kinds of target:
- a target outside `ghcr.io/aitaco-llc/buzz`. The debug image and the push gateway carry the same revision label, so the digest is what pins the right image.
- a target whose revision is not on `aitaco-llc/buzz` `main`.
- any target at all while `/opt/buzz/.env` and the running containers disagree. A rollback would otherwise restore an image that never ran.

It runs from any directory inside the clone.

**`carry`** runs `plan`, then puts the target image on the host. It changes nothing that runs.
- hip reads the image from GHCR: the index, every platform's manifest, config and layers. It checks each blob against its digest.
- hip writes an OCI layout and streams it over `gcloud compute ssh` into `sudo docker load`. No registry credential reaches the host.
- The host's Docker (29.x) uses the containerd image store. That store keeps the index digest, and the layout names the image by its digest ref. So `docker image inspect <target>` returns the target digest as its Id, and `compose up` finds the image locally instead of pulling it.
- If the host already has the target, `carry` does nothing.

**`deploy`** runs `plan`, then checks that the operator's `buzz` identity can read `--canary-channel` on `https://buzz.aitaco.co`, and stops if not. Nothing has changed at that point. Then it runs these steps in order:
1. **Carry** the target to the host, as `carry` does.
2. **Backup.** It copies `/opt/buzz/.env` to `.env.pre-<stamp>` and runs `/opt/buzz/backup.sh`, which sends Postgres, MinIO, the git volume and `.env` to `gs://aitaco-buzz-backups/<stamp>/`. It then confirms a backup from this run exists.
3. **Follow the logs.** Docker deletes a container's `json-file` log when the container is removed. That log holds the only record of which pubkey each connection was (the `NIP-42 auth successful` lines), so a recreate without this step loses it.
   - For each container, a detached `docker logs -f` writes to `/opt/buzz/deploy-logs/<container>-<id12>-<stamp>-deploy.log.gz` on the host.
   - It writes the history, then keeps writing until compose stops the container, so nothing logged before the removal is lost.
   - After the start, the script checks that each follower has exited and left a complete gzip. A failed check is only a warning.
   - The directory isn't under `/tmp` or `/var/tmp`, so tmpfiles cleanup doesn't touch it. The files stay until someone removes them.
4. **Pin** `BUZZ_IMAGE=<target>` in `/opt/buzz/.env`. The relay and the pair-relay sidecar share this variable.
5. **Start** with `buzzctl start` (`compose up -d --wait`), holding `/run/lock/buzz-relay-deploy.lock`.
6. **Check** three things:
   - both containers run exactly the target image ref and its revision
   - NIP-11 answers at `https://buzz.aitaco.co`
   - a canary message, posted with the operator's `buzz` CLI to `https://buzz.aitaco.co` whatever `BUZZ_RELAY_URL` says, can be read back from `--canary-channel`

**Rollback.** A failure or an interrupt (Ctrl-C, SIGTERM, SIGHUP, a broken stderr pipe) in steps 4–6 **rolls back**:
- On a signal, the script's output moves to `rollback.out` in the hip log directory first, because the terminal that carried it may be gone. The rollback then ignores further signals, so a second Ctrl-C can't cut it off halfway.
- The new containers' logs are followed (`…-rollback.log.gz`). Then `.env.pre-<stamp>` is put back and `buzzctl start` runs again under the same lock. If an interrupted start is still running on the host, the rollback waits for it.
- The rollback is then **verified**: `.env` and both containers must be back on the previous image, and NIP-11 must answer. If any check fails, the script says ROLLBACK DID NOT VERIFY, and a human takes over.

Each `deploy` that reaches the pin appends one line to `/opt/buzz/deploys.log` on the host. `plan`, `carry`, and deploys that stop before the pin don't. Every run keeps its log on hip under `~/.local/state/buzz-relay-deploys/`.

Run `deploy` in a terminal or background job that can outlive a 2-minute tool timeout. The carry, the backup and `--wait` together take minutes.

**When rollback is only a digest swap.** Rollback puts the old image back. It does not touch the database, which is only safe when no migration ran between the two revisions. So `deploy` refuses a target that adds migrations unless you pass `--allow-migrations`.
- The live `.env` sets `BUZZ_AUTO_MIGRATE=true`, so the new relay applies migrations at startup.
- The old binary then refuses a schema it doesn't know.
- For that reason, once the new relay has started, a failure in a migrating deploy is **not** rolled back by digest. The script stops, leaves the new relay up, and prints the backup to restore from. Going back is a manual restore (see `backup.sh` for what it needs).

## Host configuration (`/opt/buzz/.env`)

`.env` exists only on the host. Nothing in this repository generates it, and `relay-deploy.sh` rewrites exactly one line in it, `BUZZ_IMAGE=` (`scripts/aitaco/relay-deploy.sh:312`). Compose hands the whole file to the relay (`env_file: - .env`), so every key in it reaches the process.

That cuts both ways. A line added by hand survives every later deploy — and a line never added stays missing through every later deploy, with a green deploy each time.

- **A host that was never configured ships config-gated features dark.** On 2026-09-21 the relay ran #33's code from 01:55Z with `BUZZ_APPLE_APP_IDS` unset, and it took a reconciliation 20 minutes later to notice. `/.well-known/apple-app-site-association` answered 404 and iOS universal links did not work. Every image check passed, because the image was right; the host was not.
- **`.env.pre-<stamp>` is not a rollback for a later hand edit.** `deploy` copies `.env` at step 2, *before* it pins the new `BUZZ_IMAGE` at step 4, so that copy names the **previous** image. Restoring it after an unrelated edit starts the old relay against a schema the new one may already have migrated. Take a fresh copy immediately before editing, and roll back by undoing the edit, not by restoring a file.

### What this deployment needs beyond the template

`deploy/compose/.env.example` is the template the live `.env` matches. Anything below is not in it, or is commented out in it:

| Variable | Value on `buzz.aitaco.co` | What is dark without it |
| --- | --- | --- |
| `BUZZ_APPLE_APP_IDS` | `5F7YLJS4YR.co.aitaco.buzz` | `GET /.well-known/apple-app-site-association` answers 404 (`crates/buzz-relay/src/api/app_links.rs:25-26`), so `https://buzz.aitaco.co/invite/<code>` opens Safari instead of the iOS app. Set 2026-09-21. |

The format is `<10-character team id>.<bundle id>`, comma-separated, written bare: no quotes, no trailing comment. The team id must be uppercase and digits only. A malformed entry **fails relay startup** (`crates/buzz-relay/src/config.rs:380-407`), so a typo here is an outage rather than a 404.

### Editing `.env` by hand

Same go as a deploy, and the same window: `buzzctl start` recreates the relay, which drops every WebSocket connection, so not during a live voice call.

1. **Follow the logs** first, as in deploy step 3. A recreate deletes the container's `json-file` log, whether or not the image changed.
2. **Fresh copy:** `sudo cp -p /opt/buzz/.env /opt/buzz/.env.rollback-<stamp>`, and `cmp` it.
3. **Edit**, then `diff` against that copy and confirm the change is the only one.
4. **Start:** `sudo flock -w 300 /run/lock/buzz-relay-deploy.lock /opt/buzz/buzzctl start`. `up -d --wait` blocks on the relay's health check, so a value that fails to parse comes back as a non-zero exit rather than as silence.
5. **Prove the relay came up.** A feature endpoint answering is not that proof; a relay that failed to start answers nothing, which looks the same as a feature still being off. Check the container's `config_load` phase reaching `"status":"succeeded"` in `docker logs`, NIP-11 answering at `https://buzz.aitaco.co`, and `buzz_ws_connections_active` back above zero on the metrics port.

### A PR that gates behaviour on configuration

Name its `.env` line in the PR body — the variable, the value for this host, and what stays dark without it. Merging the code is not shipping the feature, so the line goes in with or before the deploy that carries the code, and the check afterwards is the feature's own endpoint. A digest and a revision label cannot tell you whether the host was configured.

Add the variable to `deploy/compose/.env.example` in the same PR, commented out. The root `.env.example` is the single-process template; the compose file is the one a rebuilt host copies, and #33 updated only the first.

## The first cutover (Block's image → ours)

- **What's live** (read 2026-09-19):
  - `ghcr.io/block/buzz@sha256:ffedb1f56f1d…`, revision `01b6174a1`, label `version=main`.
  - It is Block's `main`, not the `relay-v0.2.1` tag, and `01b6174a1` is exactly where our fork branched.
- **What changes between it and our `main` on the server side:**
  - **No migrations.** Both migration directories are unchanged from `01b6174a1` to `a6cb53e34` and to the sync branch.
  - **Only additive code.** Our relay-side change is `crates/buzz-sdk/src/builders.rs`, which adds the NIP-43 membership builders. The relay doesn't call them.
  - So the first cutover can be rolled back by swapping the digest.
- **Order:**
  1. CI green on `main`.
  2. `docker.yml` re-enabled (`gh workflow enable docker.yml -R aitaco-llc/buzz`) and one image published.
  3. `plan` against its digest, then `carry` it.
  4. rock's go.
  5. `deploy`.

## Canary channel

Use a channel whose members are fine seeing a line per deploy. The canary mentions nobody, so it wakes no seat, but humans see it. A dedicated `#relay-canary` is cleanest. Creating it is rock's call.
