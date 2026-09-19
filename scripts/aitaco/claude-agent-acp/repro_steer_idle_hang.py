#!/usr/bin/env python3
"""Drive claude-agent-acp over stdio into the steered-turn idle-debt hang.

  1. session/prompt P: start a background subagent, then a foreground sleep.
  2. _session/steering S during the sleep, so P becomes a steered turn.
  3. The steered cycle ends. The subagent's task-notification followup runs
     straight after it, and its autonomous result owes a trailing idle.
  4. The CLI emits one idle for the whole sequence. claude-agent-acp 0.79.0
     absorbs it as that debt, so P's session/prompt never gets a response.

Exit 0: P resolved. Exit 1: P still unresolved --hang-wait seconds after the
first task-notification result (the script then sends session/cancel and
reports how that resolves). Exit 2: the model did not follow the script.
--no-steer runs the control: the same prompt with no step 2.

It spends real model calls (haiku by default, about 50k tokens a run). It
strips the parent's CLAUDE_* session variables and every BUZZ_* variable from
the adapter's environment, so the test session cannot post to Buzz.

  repro_steer_idle_hang.py [--agent CMD] [--no-steer] [--out DIR]
      [--hang-wait SECS] [--model haiku]
"""
import argparse, asyncio, json, os, sys, tempfile, time

PROMPT = (
    "This is an automated harness test. Follow these steps exactly and do nothing else.\n"
    "1. Call the Agent tool with run_in_background set to true, subagent_type "
    "\"general-purpose\", description \"sleeper\", and prompt: "
    "\"Run the Bash command `sleep 45` and then reply with the single word DONE.\"\n"
    "2. Then run the Bash command `sleep 20` in the foreground.\n"
    "3. Then reply with the single word WAITING and end your turn. "
    "Do not wait for or check on the background agent.\n"
    "When the background agent's notification arrives later, reply with the single word NOTED."
)
STEER = "Harness steer: in your reply, write STEERED instead of WAITING. Change nothing else."


def now():
    return time.strftime("%H:%M:%S", time.gmtime()) + f".{int(time.time()*1000)%1000:03d}Z"


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent", default="claude-agent-acp")
    ap.add_argument("--no-steer", action="store_true")
    ap.add_argument("--out", default=None,
                    help="directory for the wire log and adapter log (default: a new temp dir)")
    ap.add_argument("--hang-wait", type=float, default=60.0,
                    help="seconds after the autonomous result before declaring a hang")
    ap.add_argument("--model", default="haiku")
    a = ap.parse_args()
    out = a.out or tempfile.mkdtemp(prefix="steer-hang-")
    os.makedirs(out, exist_ok=True)
    work = tempfile.mkdtemp(prefix="work-", dir=out)
    print(f"{now()} logs in {out}", flush=True)

    env = {k: v for k, v in os.environ.items()
           if not k.startswith("BUZZ_") and not k.startswith("CLAUDE_CODE_")
           and k not in ("CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT")}
    env["CLAUDE_AGENT_LOGS"] = out

    logf = open(os.path.join(out, "wire.jsonl"), "w")
    def log(kind, payload):
        logf.write(json.dumps({"t": now(), "kind": kind, "payload": payload}) + "\n")
        logf.flush()

    proc = await asyncio.create_subprocess_exec(
        *a.agent.split(), stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=open(os.path.join(out, "adapter.stderr"), "w"), env=env, cwd=work,
        limit=64 * 1024 * 1024)

    next_id = 0
    pending = {}
    ev = {"steer_ready": asyncio.Event(), "autonomous_result": asyncio.Event()}
    state = {"results": []}

    async def send(obj):
        log("write", obj)
        proc.stdin.write((json.dumps(obj) + "\n").encode())
        await proc.stdin.drain()

    async def request(method, params):
        nonlocal next_id
        next_id += 1
        rid = next_id
        fut = asyncio.get_running_loop().create_future()
        pending[rid] = fut
        await send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        return rid, fut

    async def reader():
        while True:
            line = await proc.stdout.readline()
            if not line:
                log("eof", None)
                return
            msg = json.loads(line)
            log("read", msg)
            if "id" in msg and "method" not in msg:
                fut = pending.pop(msg["id"], None)
                if fut and not fut.done():
                    fut.set_result(msg)
                continue
            m = msg.get("method")
            if m == "session/update":
                u = msg["params"]["update"]
                su = u.get("sessionUpdate")
                if su in ("tool_call", "tool_call_update"):
                    cmd = json.dumps(u.get("rawInput") or {})
                    if "sleep 20" in cmd:
                        ev["steer_ready"].set()
                if su == "usage_update" and "cost" in u:
                    origin = ((u.get("_meta") or {}).get("_claude/origin") or {}).get("kind")
                    state["results"].append((now(), origin))
                    print(f"{now()} result origin={origin}", flush=True)
                    if origin == "task-notification":
                        ev["autonomous_result"].set()
                if su == "agent_message_chunk":
                    t = (u.get("content") or {}).get("text", "")
                    if t.strip():
                        print(f"{now()} text: {t.strip()[:80]!r}", flush=True)
            elif "id" in msg:
                # Agent -> client request. Allow permissions, refuse the rest.
                if m == "session/request_permission":
                    opts = msg["params"].get("options", [])
                    pick = next((o for o in opts if o.get("kind") == "allow_once"), opts[0] if opts else None)
                    await send({"jsonrpc": "2.0", "id": msg["id"],
                                "result": {"outcome": {"outcome": "selected", "optionId": pick["optionId"]}}})
                else:
                    await send({"jsonrpc": "2.0", "id": msg["id"],
                                "error": {"code": -32601, "message": f"harness: {m} unsupported"}})

    rt = asyncio.create_task(reader())

    _, f = await request("initialize", {"protocolVersion": 1, "clientCapabilities": {
        "fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False}})
    init = await f
    print(f"{now()} agent {init['result'].get('agentInfo')}", flush=True)
    _, f = await request("session/new", {"cwd": work, "mcpServers": []})
    sess = (await f)["result"]["sessionId"]
    print(f"{now()} session {sess}", flush=True)
    for cid, val in (("mode", "bypassPermissions"), ("model", a.model)):
        _, f = await request("session/set_config_option", {"sessionId": sess, "configId": cid, "value": val})
        r = await f
        if "error" in r:
            print(f"{now()} set {cid}={val} failed: {r['error']}", flush=True)

    pid, pfut = await request("session/prompt", {"sessionId": sess, "prompt": [{"type": "text", "text": PROMPT}]})
    t0 = time.time()
    print(f"{now()} prompt sent id={pid}", flush=True)

    if not a.no_steer:
        try:
            await asyncio.wait_for(ev["steer_ready"].wait(), 120)
        except asyncio.TimeoutError:
            print(f"{now()} never saw the foreground sleep; aborting", flush=True)
            proc.kill(); return 2
        await asyncio.sleep(4)
        sid, sfut = await request("_session/steering", {"sessionId": sess, "prompt": [{"type": "text", "text": STEER}]})
        print(f"{now()} steer sent id={sid} -> {(await sfut).get('result')}", flush=True)

    # Wait for the prompt response, or the autonomous result plus hang-wait.
    async def autonomous_then_wait():
        await ev["autonomous_result"].wait()
        await asyncio.sleep(a.hang_wait)

    done, _ = await asyncio.wait({pfut, asyncio.create_task(autonomous_then_wait())},
                                 timeout=300, return_when=asyncio.FIRST_COMPLETED)
    verdict = 0
    if pfut.done():
        print(f"{now()} PROMPT RESOLVED after {time.time()-t0:.1f}s: {json.dumps(pfut.result().get('result') or pfut.result().get('error'))[:200]}", flush=True)
        # Linger to see whether the autonomous cycle still runs afterwards.
        if not ev["autonomous_result"].is_set():
            try:
                await asyncio.wait_for(ev["autonomous_result"].wait(), 120)
            except asyncio.TimeoutError:
                pass
    else:
        ar = ev["autonomous_result"].is_set()
        print(f"{now()} HANG: prompt id={pid} unresolved {time.time()-t0:.1f}s after send "
              f"(autonomous result seen={ar}, waited {a.hang_wait:.0f}s past it)", flush=True)
        verdict = 1
        await send({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": sess}})
        try:
            r = await asyncio.wait_for(asyncio.shield(pfut), 45)
            print(f"{now()} after cancel: prompt resolved {json.dumps(r.get('result') or r.get('error'))[:200]}", flush=True)
        except asyncio.TimeoutError:
            print(f"{now()} after cancel: prompt still unresolved at +45s", flush=True)
    print(f"{now()} results: {state['results']}", flush=True)
    proc.stdin.close()
    try:
        await asyncio.wait_for(proc.wait(), 10)
    except asyncio.TimeoutError:
        proc.kill()
    rt.cancel()
    return verdict


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
