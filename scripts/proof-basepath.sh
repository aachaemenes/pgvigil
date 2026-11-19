#!/usr/bin/env bash
# Proof of RELNOTES L55 (docs/configuration.md, "The UI under a sub-path, behind a reverse proxy"): the demo fleet
# served with -base-path /pgvigil behind an nginx container that passes the path whole, its own and the API's answers
# read through it, the session cookie under the base, and the click-through walk (scripts/proof-clickthrough.sh) run
# through the proxy; then the same walk at the root, unchanged. Needs go, psql, docker, curl, chromium, node 22+ and
# the web bundle built with scripts/L55-wiring.patch applied (the UI's /api reads under the base).
#   PGVIGIL_ADMIN_DSN    keyword-form connection to a cluster as a login that may create a database
#   NGINX_IMG            the proxy's image (default nginx:1.27-alpine), its digest printed
#   PGVIGIL_DEMO_WAIT_S  seconds to wait for the seeded demo (default 300)
#
# Expected (written before the first run, 2026-11-19):
#  D  the nginx image's digest.
#  P1 through the proxy: GET /pgvigil/ 200 with <base href="/pgvigil/"> in the shell; GET /pgvigil/api/instances 200
#     JSON; GET /pgvigil/livez 200; GET /pgvigil/app.css 200; GET /pgvigil 301 to /pgvigil/.
#  P2 straight to the demo's listener: GET /api/instances 404 naming /pgvigil/, GET / 404; the demo's log names the
#     base once ('a request outside web.base_path').
#  P3 a serve with the login on, -base-path /pgvigil, through a second proxy location: POST /pgvigil/api/login sets
#     pgvigil_session with Path=/pgvigil/; GET /pgvigil/api/session with it says the user; POST /pgvigil/api/logout
#     clears it with Path=/pgvigil/.
#  W1 scripts/proof-clickthrough.sh with PGVIGIL_DEMO_URL=http://127.0.0.1:<nginx>/pgvigil/: its own verdict PASS (every
#     page, tab, button, menu item and tree node; every /api read under the base below 400, graded against
#     scripts/clickthrough-expected.txt).
#  W2 scripts/proof-clickthrough.sh at the root (its own seeded demo, no base): PASS as before.
#  Z  the containers removed, read back 0.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
NGINX_IMG=${NGINX_IMG:-nginx:1.27-alpine}
fail() { echo "FAIL: $*" >&2; exit 1; }
for t in go psql docker curl chromium node; do command -v "$t" >/dev/null || fail "$t is not on this machine"; done
grep -q 'apiURL' web/src/api.ts || fail "web/src has no apiURL: apply scripts/L55-wiring.patch and build the bundle first"
WORK=$(mktemp -d); N=pgvbp$RANDOM; DB="pgvigil_bp_$RANDOM"; DB2="${DB}_l"; SRV=""; SRV2=""
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$SRV2" ]] && kill "$SRV2" 2>/dev/null || true
  docker rm -f -v "$N" >/dev/null 2>&1 || true
  for d in "$DB" "$DB2"; do psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1 || true; done
  echo "Z: containers left $(docker ps -aq --filter name=$N | wc -l)"
  rm -rf "$WORK"
}
trap cleanup EXIT
VERDICT=PASS
ok() { echo "ok   $*"; }
bad() { VERDICT=FAIL; echo "FAIL $*"; }
PORT=$(freeport); PORT2=$(freeport); NGPORT=$(freeport)

echo "== build; the demo seeded into $DB and served under /pgvigil on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
"$WORK/pgvigil" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -serve -listen "127.0.0.1:$PORT" -base-path /pgvigil -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-300}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { tail -5 "$WORK/demo.log"; fail "the demo died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || fail "the demo did not come up"
grep -q 'url=http://127.0.0.1:'"$PORT"'/pgvigil/' "$WORK/demo.log" && ok "the demo's serving line names /pgvigil/" || bad "the serving line: $(grep -m1 'demo serving' "$WORK/demo.log")"

echo "== a serve with the login on, under /pgvigil, on 127.0.0.1:$PORT2 (its own empty store $DB2)"
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB2" >/dev/null
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB2"
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\nweb:\n  base_path: /pgvigil\n' > "$WORK/l.yaml"
"$WORK/pgvigil" migrate -config "$WORK/l.yaml" > "$WORK/migrate.out" 2>&1 || { tail -3 "$WORK/migrate.out"; fail "migrate"; }
UPW="Pv9$(openssl rand -hex 10)"
PGVIGIL_PASSWORD="$UPW" "$WORK/pgvigil" user add -config "$WORK/l.yaml" bpuser > "$WORK/user.out" 2>&1 || { tail -3 "$WORK/user.out"; fail "user add"; }
"$WORK/pgvigil" serve -config "$WORK/l.yaml" -listen "127.0.0.1:$PORT2" > "$WORK/serve.log" 2>&1 &
SRV2=$!
for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$PORT2/pgvigil/livez" && break; sleep 1; done

echo "== D: the proxy ($NGINX_IMG on 127.0.0.1:$NGPORT, the path passed whole)"
docker pull -q "$NGINX_IMG" >/dev/null || fail "docker pull $NGINX_IMG"
echo "   $NGINX_IMG $(docker image inspect --format '{{index .RepoDigests 0}}' "$NGINX_IMG")"
cat > "$WORK/nginx.conf" <<EOF
events {}
http {
  server {
    listen 127.0.0.1:$NGPORT;
    location /pgvigil/ { proxy_pass http://127.0.0.1:$PORT; proxy_http_version 1.1; proxy_buffering off; }
    location /login/pgvigil/ { rewrite ^/login(/pgvigil/.*)\$ \$1 break; proxy_pass http://127.0.0.1:$PORT2; }
  }
}
EOF
chmod 644 "$WORK/nginx.conf"; chmod 755 "$WORK"
docker run -d --name "$N" --network host -v "$WORK/nginx.conf:/etc/nginx/nginx.conf:ro" "$NGINX_IMG" >/dev/null
for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$NGPORT/pgvigil/livez" && break; sleep 1; done
G="http://127.0.0.1:$NGPORT"

echo "== P1: through the proxy"
code() { curl -s -o "$WORK/body" -w '%{http_code}' "$@"; }
[ "$(code "$G/pgvigil/")" = 200 ] && grep -qF '<base href="/pgvigil/">' "$WORK/body" && ok "P1 /pgvigil/: 200, the shell's <base href=\"/pgvigil/\">" || bad "P1 /pgvigil/: no shell with the base"
c=$(code "$G/pgvigil/api/instances"); [ "$c" = 200 ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$WORK/body" && ok "P1 /pgvigil/api/instances: 200 JSON" || bad "P1 /pgvigil/api/instances: $c"
for p in livez app.css; do c=$(code "$G/pgvigil/$p"); [ "$c" = 200 ] && ok "P1 /pgvigil/$p: 200" || bad "P1 /pgvigil/$p: $c"; done
c=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$G/pgvigil"); case $c in 301\ */pgvigil/) ok "P1 /pgvigil: $c" ;; *) bad "P1 /pgvigil: $c" ;; esac

echo "== P2: outside the base, straight to the demo"
for p in api/instances ""; do c=$(code "http://127.0.0.1:$PORT/$p"); [ "$c" = 404 ] && grep -qF '/pgvigil/' "$WORK/body" && ok "P2 /$p: 404 naming /pgvigil/" || bad "P2 /$p: $c $(head -c 120 "$WORK/body")"; done
n=$(grep -c 'a request outside web.base_path' "$WORK/demo.log" || true); [ "$n" = 1 ] && ok "P2 the log names the base once" || bad "P2 the log named it $n times"

echo "== P3: the session cookie under the base (the login on)"
L="$G/login/pgvigil"
# every read here may find nothing: under set -e a grep with no match inside an assignment ended the script without a
# word (rn-9), so each one says what it saw instead
said() { echo "status $1, body '$(head -c 200 "$2" 2>/dev/null | tr '\n' ' ')', headers '$(grep -i '^HTTP\|^set-cookie\|^location' "$3" 2>/dev/null | tr -d '\r' | tr '\n' ' ')', the serve's log '$(tail -3 "$WORK/serve.log" | cut -c1-200 | tr '\n' ' ')'"; }
lc=$(curl -s -D "$WORK/h1" -o "$WORK/login.body" -w '%{http_code}' -H 'Content-Type: application/json' -d "{\"username\":\"bpuser\",\"password\":\"$UPW\"}" "$L/api/login" || true)
SC=$(grep -i '^set-cookie: pgvigil_session=' "$WORK/h1" 2>/dev/null | head -1 | tr -d '\r' || true)
TOK=$(sed -n 's/^[Ss]et-[Cc]ookie: pgvigil_session=\([^;]*\).*/\1/p' <<<"$SC")
[[ -n "$TOK" && "$SC" == *"Path=/pgvigil/"* ]] && ok "P3 the login's cookie: Path=/pgvigil/" || bad "P3 the login's cookie: $(said "$lc" "$WORK/login.body" "$WORK/h1")"
c=$(code -H "Cookie: pgvigil_session=$TOK" "$L/api/session" || true); grep -q 'bpuser' "$WORK/body" && ok "P3 /pgvigil/api/session with it: the user ($c)" || bad "P3 the session: $c $(head -c 120 "$WORK/body")"
oc=$(curl -s -D "$WORK/h2" -o "$WORK/logout.body" -w '%{http_code}' -X POST -H "Cookie: pgvigil_session=$TOK" -H 'Content-Type: application/json' -d '{}' "$L/api/logout" || true)
SC2=$(grep -i '^set-cookie: pgvigil_session=' "$WORK/h2" 2>/dev/null | head -1 | tr -d '\r' || true)
[[ "$SC2" == *"Path=/pgvigil/"* && ( "$SC2" == *"Max-Age=0"* || "$SC2" == *"Expires="* ) ]] && ok "P3 the logout clears it under Path=/pgvigil/" || bad "P3 the logout's cookie: $(said "$oc" "$WORK/logout.body" "$WORK/h2")"

echo "== W1: the click-through walk through the proxy under /pgvigil/"
PGVIGIL_DEMO_URL="$G/pgvigil/" PGVIGIL_CLICKTHROUGH_OUT="$WORK/w1" bash scripts/proof-clickthrough.sh > "$WORK/w1.log" 2>&1 && ok "W1 the walk under /pgvigil/: PASS" || { bad "W1 the walk under /pgvigil/"; tail -25 "$WORK/w1.log" | cut -c1-240 | sed 's/^/     /'; }
grep -E '^(ok|FAIL|NOT)' "$WORK/w1.log" | tail -8 | sed 's/^/     /'

echo "== W2: the same walk at the root (its own seeded demo, no base)"
PGVIGIL_CLICKTHROUGH_OUT="$WORK/w2" bash scripts/proof-clickthrough.sh > "$WORK/w2.log" 2>&1 && ok "W2 the walk at the root: PASS" || { bad "W2 the walk at the root"; tail -25 "$WORK/w2.log" | cut -c1-240 | sed 's/^/     /'; }
grep -E '^(ok|FAIL|NOT)' "$WORK/w2.log" | tail -8 | sed 's/^/     /'
echo "proof-basepath: $VERDICT"
[ "$VERDICT" = PASS ]
