# claude-agent-acp: steered-turn idle-debt fix (aitaco carry)

Every seat on hip runs `claude-agent-acp` 0.79.0 under `buzz-acp`. In that
version a steered turn can finish its work and still never answer its
`session/prompt`. The seat then sits until buzz-acp's idle timeout (1500 s on
the fleet), cancels, respawns the adapter and requeues the batch. This
directory carries a one-branch fix for that until upstream ships one.

## The bug

A steered turn settles on the CLI's `session_state_changed: idle`, not on a
result (`Turn.steeredEchoes` in `dist/acp-agent.js`). The idle handler checks
`owedTrailingIdles > 0` **before** the steer lane. A `task-notification`
followup result that lands inside the steered turn still records an owed idle:
`owesTrailingIdle = isAutonomousResult || !isSteering(...)`. The CLI runs that
followup straight after the steered cycle, so it emits one idle for both. The
owed branch absorbs that idle, the steer lane never runs, and the prompt stays
unresolved. It resolves only if the client cancels, through the 30 s
force-cancel floor, or if a later steer arrives in the same session.

Instrumented run, logging only (`instrument-0.79.0.patch`):

```
result origin=human             autonomous=false owes=false owed=0 steering=true echoes=1
replay echo                     steering=true echoes=0
result origin=human             autonomous=false owes=false owed=0 steering=true echoes=0
result origin=task-notification autonomous=true  owes=true  owed=1 steering=true echoes=0
state running->idle owed=1 steering=true echoes=0 steeredSettle=true   <- absorbed; prompt never resolves
```

The fix (`steer-idle-debt-0.79.0.patch`) adds an idle branch ahead of the owed
branch. The branch settles a steered turn that is ready, meaning its steered
echoes have replayed and a result has been recorded. It pays one unit of the
debt, and the next `running` transition sweeps any remainder, as it already
does. The branch settles through the same subagent gate as the existing steer
lane.

Upstream: agentclientprotocol/claude-agent-acp#1114 describes this hang and
lists the owed-idle ordering as one of three candidate causes. #1027 and #1039
are neighbouring steered-turn hangs. This patch does not address those two.

## Use

```sh
scripts/aitaco/claude-agent-acp/apply.sh check     # read-only
scripts/aitaco/claude-agent-acp/apply.sh apply     # fleet deploy: needs rock's go
scripts/aitaco/claude-agent-acp/apply.sh revert
```

`apply` checks that the installed file is byte-for-byte the published 0.79.0
file. It refuses any other version or content. It keeps the original as
`dist/acp-agent.js.orig-0.79.0`, checks the patched file's syntax and sha256,
and renames it into place. Running adapter processes keep the code they
loaded. Every adapter buzz-acp spawns afterwards, including a respawn after a
timeout, loads the patched file. No seat restart is needed. A seat restart
does not hurt.

A `npm install -g` of claude-agent-acp overwrites the patch. On a new version,
check whether upstream fixed the ordering. If it did not, regenerate the patch
against the new file.

On the Mac seats the package is not an npm global. `~/.local/bin/claude-agent-acp`
links into Buzz Desktop's own copy, so pass that directory:

```sh
scripts/aitaco/claude-agent-acp/apply.sh check \
  "$HOME/Library/Application Support/Buzz/node-tools/lib/node_modules/@agentclientprotocol/claude-agent-acp"
```

A Buzz Desktop update that reinstalls its node tools overwrites the patch too.
Run `check` against that path after every Desktop update. The script uses only
flags that GNU and BSD tools both accept, so the same commands work on hip and
on the Mac.

## Reproduce

```sh
scripts/aitaco/claude-agent-acp/repro_steer_idle_hang.py                    # installed adapter
scripts/aitaco/claude-agent-acp/repro_steer_idle_hang.py --no-steer         # control
scripts/aitaco/claude-agent-acp/repro_steer_idle_hang.py --agent "node <pkg>/dist/index.js"
```

The script sends a prompt that starts a background subagent and then a
foreground sleep, and steers during the sleep. Exit code 1 means the prompt was
still unresolved 60 s after the first `task-notification` result. Exit code 0
means it resolved. The script uses haiku, about 50k tokens a run, and strips
the `BUZZ_*` and parent `CLAUDE_*` variables so the test session cannot post
anywhere.
