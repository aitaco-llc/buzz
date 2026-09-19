# Taking a fix from Block

`aitaco-llc/buzz` is detached from `block/buzz`. Lloyd decided this on 2026-09-19. Nothing syncs on a schedule. We take a Block change only when we want a specific fix, and it lands the way every other change does: a PR to `aitaco-llc/buzz`, green CI, then a merge to `main`.

## What does not run

- **Actions.** No workflow on the fork has a `schedule:` or `cron` trigger, and none of them syncs from upstream (`git grep -n -E "schedule:|cron" -- .github/workflows` is empty). The 17 workflows that only serve Block's infrastructure are `disabled_manually` on the fork.
- **Bots.** `renovate.json` is Block's configuration, and it does nothing here. The only GitHub App installed on `aitaco-llc` is `claude` (`gh api orgs/aitaco-llc/installations`). Dependabot security updates are off.
- **Hosts.** No timer or cron job on hip or on `buzz-relay` fetches Block's code or images. The relay runs a digest-pinned `ghcr.io/aitaco-llc/buzz` image, and only `scripts/aitaco/relay-deploy.sh` changes it (`RELAY_LANE.md`).

Nothing arrives from Block unless someone opens a PR for it.

## Taking a fix

Our checkouts have no remote for Block, so fetch it by URL:

```bash
git fetch https://github.com/block/buzz.git main               # or pull/<n>/head for an open Block PR
git switch -c take-block-<n> aitaco/main
git cherry-pick -x --signoff <sha>...                           # the usual case: just the fix
# or, only when the fix depends on a lot of upstream:
git merge --no-ff --signoff FETCH_HEAD
```

- **Cherry-pick by default.** `-x` records the upstream sha in the commit message. Merge Block's `main` only when the fix can't be separated from it, and give the reason in the PR.
- **Sign off.** The DCO check fails any commit without `Signed-off-by`. The `commit-msg` hook doesn't cover `cherry-pick` (`AGENTS.md`), so pass `--signoff` there and on `merge`.
- **Name the source.** Title the PR `Take block/buzz#<n>: <subject>` and link the upstream PR or commit.
- **Check migrations before you open it:** `git diff --stat aitaco/main HEAD -- migrations crates/buzz-push-gateway/migrations`. If there are any, the relay deploy needs `--allow-migrations` and rock's go (`RELAY_LANE.md`).
- **Open it against the fork.** Run `gh pr create --repo aitaco-llc/buzz --base main`, and always pass `--repo`. On GitHub this repo is still a fork of `block/buzz`, so the web UI's compare view offers Block's repo as the base. Our checkouts have no `gh repo set-default`. A PR to `block/buzz` is outward-facing, and Lloyd approves each one first.
- **Gate and release as usual.** CI must be green. After the merge, the fix ships through the lane it touches: `RELAY_LANE.md` for the relay, `DESKTOP_LANE.md` for Desktop, and the iOS lane on the Mac.
