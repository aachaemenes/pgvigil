#!/usr/bin/env python3
"""A scripted MCP client for scripts/proof-agent.sh: one `pgvigil mcp` process over stdio, no model.

    agent-client.py --bin BIN --dsn-env NAME CALLS.jsonl > OUT.jsonl

The server runs with PGVIGIL_MCP_DSN set from the environment variable NAME (the DSN never rides a command line).
CALLS.jsonl holds one call a line:
    {"tool": "<name>", "args": {...}}          a tools/call
    {"rpc": "<method>", "params": {...}}       any other JSON-RPC request
    {"barrier": "<path>"}                      wait (30 s at most) until the file exists - two clients start a call at once
    {"touch": "<path>"}                        make a file (tells the proof a step was reached)
    {"sleep": <seconds>}
A string value "$claim" anywhere in args is replaced by the claim_id of the latest successful claim_investigation,
"$open" by the list of request ids in the latest wait_for_investigations answer's open set, and "$known" by that
answer's known list (its open ids where the answer has none).
OUT.jsonl gets one line a call: {"i", "call", "ms", "reply", "isError", "body"} (body = the first content text parsed as
JSON when it is JSON, else the text), then {"exit": <code>, "skipped": <calls not sent>, "stderr": <its last 4 KB>}.
When the server exits before a call (a refused login exits 3 before the first message), the remaining calls are skipped
and the exit line counts them.
"""
import argparse
import json
import os
import subprocess
import sys
import threading
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--dsn-env", required=True)
    ap.add_argument("--timeout", type=float, default=60.0, help="seconds to wait for one reply")
    ap.add_argument("calls")
    a = ap.parse_args()
    env = dict(os.environ)
    env["PGVIGIL_MCP_DSN"] = os.environ[a.dsn_env]
    p = subprocess.Popen([a.bin, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         env=env, text=True, bufsize=1)
    replies = {}
    cv = threading.Condition()
    err = []

    def read_out():
        for line in p.stdout:
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if "id" in m:
                with cv:
                    replies[m["id"]] = m
                    cv.notify_all()
        with cv:
            cv.notify_all()

    def read_err():
        for line in p.stderr:
            err.append(line)

    reader = threading.Thread(target=read_out, daemon=True)
    reader.start()
    threading.Thread(target=read_err, daemon=True).start()
    out = sys.stdout
    nid = [0]

    def emit(d):
        out.write(json.dumps(d) + "\n")
        out.flush()

    def request(method, params):
        nid[0] += 1
        i = nid[0]
        try:
            p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n")
            p.stdin.flush()
        except (BrokenPipeError, ValueError):
            return None
        end = time.monotonic() + a.timeout
        with cv:
            while i not in replies:
                left = end - time.monotonic()
                if left <= 0:
                    return None
                if p.poll() is not None:
                    break
                cv.wait(min(left, 0.2))
            else:
                return replies.pop(i)
        # the server exited: its last replies may still be in the pipe - the reader ends at EOF
        reader.join(timeout=5)
        with cv:
            return replies.pop(i, None)

    def subst(v, vars_):
        if isinstance(v, str):
            return vars_[v[1:]] if v in ("$claim", "$open", "$known") and vars_.get(v[1:]) is not None else v
        if isinstance(v, list):
            return [subst(x, vars_) for x in v]
        if isinstance(v, dict):
            return {k: subst(x, vars_) for k, x in v.items()}
        return v

    calls = [json.loads(l) for l in open(a.calls) if l.strip()]
    time.sleep(0.3)
    alive = p.poll() is None
    if alive:
        r = request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                   "clientInfo": {"name": "proof-agent", "version": "1"}})
        alive = r is not None and "result" in r
        if alive:
            p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
            p.stdin.flush()
    vars_ = {"claim": None, "open": None, "known": None}
    skipped = 0
    for n, c in enumerate(calls):
        if not alive or p.poll() is not None:
            skipped = sum(1 for x in calls[n:] if "tool" in x or "rpc" in x)
            break
        if "barrier" in c:
            end = time.monotonic() + 30
            while not os.path.exists(c["barrier"]) and time.monotonic() < end:
                time.sleep(0.02)
            continue
        if "touch" in c:
            open(c["touch"], "w").close()
            continue
        if "sleep" in c:
            time.sleep(float(c["sleep"]))
            continue
        t0 = time.monotonic()
        if "tool" in c:
            r = request("tools/call", {"name": c["tool"], "arguments": subst(c.get("args", {}), vars_)})
        else:
            r = request(c["rpc"], subst(c.get("params", {}), vars_))
        ms = int((time.monotonic() - t0) * 1000)
        body, is_err = None, None
        if r is not None and "result" in r and isinstance(r["result"], dict):
            is_err = bool(r["result"].get("isError", False))
            cont = r["result"].get("content") or []
            if cont and isinstance(cont[0], dict) and "text" in cont[0]:
                try:
                    body = json.loads(cont[0]["text"])
                except ValueError:
                    body = cont[0]["text"]
        if c.get("tool") == "claim_investigation" and is_err is False and isinstance(body, dict) and body.get("claim_id"):
            vars_["claim"] = body["claim_id"]
        if c.get("tool") == "wait_for_investigations" and is_err is False and isinstance(body, dict):
            vars_["open"] = [x.get("id") for x in body.get("open") or [] if isinstance(x, dict)]
            vars_["known"] = body["known"] if isinstance(body.get("known"), list) else vars_["open"]
        emit({"i": n, "call": c, "ms": ms, "reply": r, "isError": is_err, "body": body})
    try:
        p.stdin.close()
    except (BrokenPipeError, ValueError):
        pass
    try:
        rc = p.wait(timeout=20)
    except subprocess.TimeoutExpired:
        p.kill()
        rc = p.wait()
    time.sleep(0.1)
    emit({"exit": rc, "skipped": skipped, "stderr": "".join(err)[-4096:]})


if __name__ == "__main__":
    main()
