#!/usr/bin/env bash
# Proof of the -open switch (serve and demo): the UI opened in an app-mode browser window.
#   PGVIGIL_REPO_DSN  a connection as a login that may CREATE DATABASE (the demo repository is made and dropped)
# A stub browser on the child's PATH records what pgvigil launches; no real browser opens.
# Expected: (1) `demo -serve -open` with a stub `chromium` first on PATH launches it with exactly
# `--app=http://127.0.0.1:<the bound port>/`, the port is the one the log names, and the browser sits in its own
# process group (a Ctrl-C in pgvigil's terminal must not close it); (2) `serve -open`
# with only a stub `xdg-open` launches that with the bare URL (the default-browser fallback);
# (3) `serve -open` with no browser at all logs the "no browser could be started" warning and
# still answers /api/health 200. Linux only (the candidates differ per OS; the Windows run is by hand).
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}; BIN=$(readlink -f "$BIN")
: "${PGVIGIL_REPO_DSN:?}"
DB="pgvigil_it_open_$RANDOM"; WORK=$(mktemp -d); DPID=""; SPID=""
cleanup() {
  [[ -n "$DPID" ]] && kill -INT "$DPID" 2>/dev/null && wait "$DPID" 2>/dev/null || true
  [[ -n "$SPID" ]] && kill "$SPID" 2>/dev/null && wait "$SPID" 2>/dev/null || true
  psql "$PGVIGIL_REPO_DSN" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok $*"; }
HOST=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select coalesce(host(inet_server_addr()),'localhost')")
DBPORT=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select inet_server_port()")
USERNAME=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select current_user")
psql "$PGVIGIL_REPO_DSN" -XAtq -c "create database $DB" >/dev/null
export DEMO_DSN="host=$HOST port=$DBPORT user=$USERNAME dbname=$DB sslmode=disable"
[[ "$PGVIGIL_REPO_DSN" =~ password=([^[:space:]]+) ]] && DEMO_DSN="$DEMO_DSN password=${BASH_REMATCH[1]}"
printf 'repository:\n  dsn: env:DEMO_DSN\ninstances: []\n' > "$WORK/cfg.yaml"

# the stubs: each records its argv, one per line, and exits; the app stub also records its process group
# (it runs with the proof's stub-only PATH, so it sets its own for ps and tr)
mkdir -p "$WORK/stub-app" "$WORK/stub-default" "$WORK/stub-none"
printf '#!/bin/sh\nPATH=/usr/bin:/bin\nprintf "%%s\\n" "$@" > "%s/app.args"\nps -o pgid= -p $$ | tr -d " " > "%s/app.pgid"\n' "$WORK" "$WORK" > "$WORK/stub-app/chromium"; chmod +x "$WORK/stub-app/chromium"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/default.args"\n' "$WORK" > "$WORK/stub-default/xdg-open"; chmod +x "$WORK/stub-default/xdg-open"

# (1) demo -serve -open: seeds (one instance, one day: the switch is under test, not the seed), serves on a picked
# port, launches the app window on that port, in its own process group
PATH="$WORK/stub-app" "$BIN" demo -dsn "$DEMO_DSN" -instances 1 -days 1 -serve -listen 127.0.0.1:0 -open >"$WORK/demo.out" 2>"$WORK/demo.log" & DPID=$!
PORT=""
for _ in $(seq 600); do PORT=$(grep -m1 -o 'url=http://127.0.0.1:[0-9]*' "$WORK/demo.log" | grep -o '[0-9]*$' || true); [[ -n "$PORT" ]] && break; sleep 0.5; done
[[ -n "$PORT" ]] || { cat "$WORK/demo.log" >&2; fail "demo: no serving URL logged"; }
for _ in $(seq 50); do [[ -s "$WORK/app.args" ]] && break; sleep 0.1; done
[[ -s "$WORK/app.args" ]] || { cat "$WORK/demo.log" >&2; fail "demo -open: the stub browser was not launched"; }
got=$(cat "$WORK/app.args")
[[ "$got" == "--app=http://127.0.0.1:$PORT/" ]] || fail "demo -open launched with '$got', want --app=http://127.0.0.1:$PORT/"
grep -q 'open: app window' "$WORK/demo.log" || fail "demo -open: no 'app window' log line"
my_pgid=$(ps -o pgid= -p "$DPID" | tr -d ' '); stub_pgid=$(cat "$WORK/app.pgid" 2>/dev/null || true)
[[ -n "$stub_pgid" && "$stub_pgid" != "$my_pgid" ]] || fail "the browser shares pgvigil's process group ($stub_pgid vs $my_pgid): a Ctrl-C would close it"
curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null || fail "demo: the served URL does not answer"
ok "demo -serve -open: chromium launched with --app=http://127.0.0.1:$PORT/ (the logged port) in its own process group, the UI answers"
kill -INT "$DPID"; wait "$DPID" 2>/dev/null || true; DPID=""

# (2) serve -open with only xdg-open: the default-browser fallback gets the bare URL
PATH="$WORK/stub-default" "$BIN" serve -config "$WORK/cfg.yaml" -no-login -listen 127.0.0.1:0 -open 2>"$WORK/serve2.log" & SPID=$!
PORT=""
for _ in $(seq 100); do PORT=$(grep -m1 -o 'url=http://127.0.0.1:[0-9]*' "$WORK/serve2.log" | grep -o '[0-9]*$' || true); [[ -n "$PORT" ]] && break; sleep 0.1; done
[[ -n "$PORT" ]] || { cat "$WORK/serve2.log" >&2; fail "serve: no URL logged"; }
for _ in $(seq 50); do [[ -s "$WORK/default.args" ]] && break; sleep 0.1; done
got=$(cat "$WORK/default.args" 2>/dev/null || true)
[[ "$got" == "http://127.0.0.1:$PORT/" ]] || { cat "$WORK/serve2.log" >&2; fail "serve -open fallback launched with '$got', want http://127.0.0.1:$PORT/"; }
grep -q 'open: default browser' "$WORK/serve2.log" || fail "serve -open: no 'default browser' log line"
curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null || fail "serve on a picked port: the served URL does not answer (Host check)"
ok "serve -open without Edge or Chrome: xdg-open launched with the URL"
kill "$SPID"; wait "$SPID" 2>/dev/null || true; SPID=""

# (3) serve -open with no browser at all: a warning, the server still serves
PATH="$WORK/stub-none" "$BIN" serve -config "$WORK/cfg.yaml" -no-login -listen 127.0.0.1:0 -open 2>"$WORK/serve3.log" & SPID=$!
PORT=""
for _ in $(seq 100); do PORT=$(grep -m1 -o 'url=http://127.0.0.1:[0-9]*' "$WORK/serve3.log" | grep -o '[0-9]*$' || true); [[ -n "$PORT" ]] && break; sleep 0.1; done
[[ -n "$PORT" ]] || { cat "$WORK/serve3.log" >&2; fail "serve (3): no URL logged"; }
for _ in $(seq 50); do grep -q 'no browser could be started' "$WORK/serve3.log" && break; sleep 0.1; done
grep -q 'no browser could be started' "$WORK/serve3.log" || { cat "$WORK/serve3.log" >&2; fail "serve -open with no browser: no warning logged"; }
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/health")
[[ "$code" == 200 ]] || fail "serve -open with no browser: health $code"
kill -0 "$SPID" 2>/dev/null || fail "serve exited after the failed open"
ok "serve -open with no browser: warned, still serving (health 200)"
echo "PASS proof-open"
