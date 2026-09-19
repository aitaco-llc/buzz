# aitaco relay lane

This lane moves `wss://buzz.aitaco.co` to a relay image built from `aitaco-llc/buzz`. The live relay is the GCE instance `buzz-relay` (zone `us-central1-a`). It runs Docker Compose from `/opt/buzz`, with `buzzctl` wrapping `run.sh` with TLS on.

- The script is `scripts/aitaco/relay-deploy.sh`. It runs on hip.
- Every live deploy needs rock's go. A deploy that changes the relay for other users is Lloyd's call.

## Images

- **What publishes them.** `docker.yml` on the fork builds `ghcr.io/aitaco-llc/buzz` (repo variable `GHCR_IMAGE`) and `ghcr.io/aitaco-llc/buzz-push-gateway` (`GHCR_PUSH_GATEWAY_IMAGE`) on every push to `main`. Its `qualify` job waits for a green `ci.yml` run on the same commit before publishing.
- **Tags.** Each image is tagged `:main` and `:sha-<7>`. Deploy by **digest** only (`ghcr.io/aitaco-llc/buzz@sha256:…`). The script refuses anything else.
- **Pulling private packages.** GHCR creates packages private. Either make them public, or log docker on `buzz-relay` in to GHCR. Reading the target's revision label from hip then also needs `GHCR_TOKEN` (a token with `read:packages`).

## Commands

```bash
scripts/aitaco/relay-deploy.sh plan   ghcr.io/aitaco-llc/buzz@sha256:<digest>
scripts/aitaco/relay-deploy.sh deploy ghcr.io/aitaco-llc/buzz@sha256:<digest> --canary-channel <uuid>
```

**`plan`** changes nothing. It prints:
- the live `BUZZ_IMAGE` and the running container's `org.opencontainers.image.revision`
- the target's revision, read from the registry
- the commits between the two revisions
- any files changed under `migrations/` and `crates/buzz-push-gateway/migrations/`

It refuses a target whose revision is not on `aitaco-llc/buzz` `main`.

**`deploy`** runs `plan`, then these steps in order:
1. **Backup.** It copies `/opt/buzz/.env` to `.env.pre-<stamp>` and runs `/opt/buzz/backup.sh`, which sends Postgres, MinIO, the git volume and `.env` to `gs://aitaco-buzz-backups/<stamp>/`. It then confirms a backup from this run exists.
2. **Pull** the target on the host.
3. **Pin** `BUZZ_IMAGE=<target>` in `/opt/buzz/.env`. The relay and the pair-relay sidecar share this variable.
4. **Start** with `buzzctl start` (`compose up -d --wait`).
5. **Check** three things:
   - both containers report the target revision
   - NIP-11 answers at `https://buzz.aitaco.co`
   - a canary message posted with the operator's `buzz` CLI can be read back from `--canary-channel`

Any failure in steps 3–5 **rolls back**: `.env.pre-<stamp>` is put back, `buzzctl start` runs again, and NIP-11 is re-checked. Each run appends one line to `/opt/buzz/deploys.log` on the host. Logs stay on hip under `~/.local/state/buzz-relay-deploys/`.

**When rollback is only a digest swap.** Rollback puts the old image back. It does not touch the database, which is only safe when no migration ran between the two revisions. So `deploy` refuses a target that adds migrations unless you pass `--allow-migrations`. Once migrations have run, going back means restoring the step 1 backup. That's a manual, planned operation (see `backup.sh` for what a restore needs).

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
  3. `plan` against its digest.
  4. rock's go.
  5. `deploy`.

## Canary channel

Use a channel whose members are fine seeing a line per deploy. The canary mentions nobody, so it wakes no seat, but humans see it. A dedicated `#relay-canary` is cleanest. Creating it is rock's call.
