#!/usr/bin/env bash
# Proof of RELNOTES L55 (docs/configuration.md, "The UI under a sub-path, behind a reverse proxy"): the demo fleet
# served with -base-path /pgvigil behind an nginx container that passes the path whole, its own and the API's answers
# read through it, the session cookie under the base, and the click-through walk (scripts/proof-clickthrough.sh) run
# through the proxy; then the same walk at the root, unchanged. Needs go, psql, docker, curl, chromium, node 22+ and
# the web bundle built from a web/src whose /api reads go through apiURL (web/src/api.ts: the reads under the base).
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
# Expected (the sub-path fold, written before its run): P1 also GET /pgvigil/api 301 to /pgvigil/api/ (the mux's own
#  redirect kept under the base); P2 also GET /pgvigil?x=1 straight to the demo 301 to /pgvigil/?x=1 (pgvigil's
#  redirect, not nginx's); P3 through its own nginx server (a second port, the path passed whole, no rewrite) with a
#  curl cookie jar: the login's cookie Path=/pgvigil/, the session read with the jar's cookie, the jar sends nothing to
#  /other/ (the cookie stays under the base), the logout clears it; W1 counts any answer outside /pgvigil/ and any
#  root link under the base as FAIL rows. The design's axe row is not in this proof (the a11y walk runs at the root in
#  its own proof).
# Expected (rn-9c, after rn-9b's fold - written before it): D, P1, P2 as rn-9; P3 all three ok now that the login and
#  the logout carry the X-Pgvigil header (rn-9b's 401 / 403 were the proof's own requests); W1 and W2 [unverified]: if
#  either fails, its NEW rows are listed by kind and page, and the rows new under /pgvigil/ but not at the root are the
#  base path's own (0 of them = L55 adds no click-through FAIL; the root walk's rows are then the base tree's, said
#  apart). Each walk about 1 h 40 min on the box.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
NGINX_IMG=${NGINX_IMG:-nginx:1.27-alpine}
fail() { echo "FAIL: $*" >&2; exit 1; }
for t in go psql docker curl chromium node python3 openssl; do command -v "$t" >/dev/null || fail "$t is not on this machine"; done
grep -q 'apiURL' web/src/api.ts || fail "web/src has no apiURL: its /api reads must go through apiURL (web/src/api.ts) and the bundle be built from it"
grep -qF 'querySelector("base")' internal/web/dist/app.js || fail "the embedded bundle internal/web/dist/app.js was not built from the wired source: build it (npm run build) after the patch"
WORK=$(mktemp -d); N=pgvbp$RANDOM; DB="pgvigil_bp_$RANDOM"; DB2="${DB}_l"; SRV=""; SRV2=""
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$SRV2" ]] && kill "$SRV2" 2>/dev/null || true
  docker rm -f -v "$N" >/dev/null 2>&1 || true
  for d in "$DB" "$DB2"; do psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1 || true; done
  echo "Z: containers left $(docker ps -aq --filter "name=^${N}\$" | wc -l)"
  rm -rf "$WORK"
}
trap cleanup EXIT
VERDICT=PASS
ok() { echo "ok   $*"; }
bad() { VERDICT=FAIL; echo "FAIL $*"; }
PORT=$(freeport); PORT2=$(freeport); NGPORT=$(freeport); NGPORT2=$(freeport)

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
  }
  server {
    listen 127.0.0.1:$NGPORT2;
    location /pgvigil/ { proxy_pass http://127.0.0.1:$PORT2; proxy_http_version 1.1; }
    location /other/ { return 200 "other: \$http_cookie\n"; }
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
c=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$G/pgvigil/api"); case $c in 301\ */pgvigil/api/) ok "P1 /pgvigil/api (the mux's redirect): $c" ;; *) bad "P1 /pgvigil/api: $c (want 301 to /pgvigil/api/)" ;; esac

echo "== P2: outside the base, straight to the demo"
for p in api/instances ""; do c=$(code "http://127.0.0.1:$PORT/$p"); [ "$c" = 404 ] && grep -qF '/pgvigil/' "$WORK/body" && ok "P2 /$p: 404 naming /pgvigil/" || bad "P2 /$p: $c $(head -c 120 "$WORK/body")"; done
n=$(grep -c 'a request outside web.base_path' "$WORK/demo.log" || true); [ "$n" = 1 ] && ok "P2 the log names the base once" || bad "P2 the log named it $n times"
loc=$(curl -s -o /dev/null -D - "http://127.0.0.1:$PORT/pgvigil?x=1" | tr -d '\r' | sed -n 's/^[Ll]ocation: //p'); [ "$loc" = "/pgvigil/?x=1" ] && ok "P2 /pgvigil?x=1 straight to the demo: 301 to $loc (pgvigil's own)" || bad "P2 /pgvigil?x=1: Location '$loc', want /pgvigil/?x=1"

echo "== P3: the session cookie under the base (the login on)"
L="http://127.0.0.1:$NGPORT2/pgvigil"; JAR="$WORK/jar"
# every read here may find nothing: under set -e a grep with no match inside an assignment ended the script without a
# word (rn-9), so each one says what it saw instead
said() { echo "status $1, body '$(head -c 200 "$2" 2>/dev/null | tr '\n' ' ')', headers '$(grep -i '^HTTP\|^set-cookie\|^location' "$3" 2>/dev/null | tr -d '\r' | tr '\n' ' ')', the serve's log '$(tail -3 "$WORK/serve.log" | cut -c1-200 | tr '\n' ' ')'"; }
lc=$(curl -s -c "$JAR" -b "$JAR" -D "$WORK/h1" -o "$WORK/login.body" -w '%{http_code}' -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"bpuser\",\"password\":\"$UPW\"}" "$L/api/login" || true)
SC=$(grep -i '^set-cookie: pgvigil_session=' "$WORK/h1" 2>/dev/null | head -1 | tr -d '\r' || true)
TOK=$(sed -n 's/^[Ss]et-[Cc]ookie: pgvigil_session=\([^;]*\).*/\1/p' <<<"$SC")
[[ -n "$TOK" && "$SC" == *"Path=/pgvigil/"* ]] && ok "P3 the login's cookie: Path=/pgvigil/" || bad "P3 the login's cookie: $(said "$lc" "$WORK/login.body" "$WORK/h1")"
c=$(code -b "$JAR" "$L/api/session" || true); grep -q 'bpuser' "$WORK/body" && ok "P3 /pgvigil/api/session with the jar's cookie: the user ($c)" || bad "P3 the session: $c $(head -c 120 "$WORK/body")"
o=$(curl -s -b "$JAR" "http://127.0.0.1:$NGPORT2/other/" || true); [[ "$o" == "other: " || "$o" == "other: -" ]] && ok "P3 the jar sends nothing to /other/ (the cookie stays under /pgvigil/)" || bad "P3 /other/ got: $o"
oc=$(curl -s -b "$JAR" -c "$JAR" -D "$WORK/h2" -o "$WORK/logout.body" -w '%{http_code}' -X POST -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{}' "$L/api/logout" || true)
SC2=$(grep -i '^set-cookie: pgvigil_session=' "$WORK/h2" 2>/dev/null | head -1 | tr -d '\r' || true)
[[ "$SC2" == *"Path=/pgvigil/"* && ( "$SC2" == *"Max-Age=0"* || "$SC2" == *"Expires="* ) ]] && ok "P3 the logout clears it under Path=/pgvigil/" || bad "P3 the logout's cookie: $(said "$oc" "$WORK/logout.body" "$WORK/h2")"

# each walk's output is kept outside the work folder, which the cleanup removes: the grader prints its NEW rows before
# the expected rows, so a tail of its log never showed them (rn-9b: 240 and 203 rows, all lost)
KEEP="${PGVIGIL_BASEPATH_OUT:-.out/basepath-$(date +%Y%m%d-%H%M%S)}"; mkdir -p "$KEEP"
newrows() { [ -f "$1/clickthrough.tsv" ] || return 0; awk -F'\t' '$7 == "NEW" {print $2 "\t" $3 "\t" $4 "\t" $5}' "$1/clickthrough.tsv" | LC_ALL=C sort -u; }
walked() { grep -E '^(pages|rows): ' "$KEEP/$1.log" | cut -c1-300 | sed 's/^/     /' || true; }

echo "== W1: the click-through walk through the proxy under /pgvigil/"
PGVIGIL_DEMO_URL="$G/pgvigil/" PGVIGIL_CLICKTHROUGH_OUT="$KEEP/w1" bash scripts/proof-clickthrough.sh > "$KEEP/w1.log" 2>&1 && ok "W1 the walk under /pgvigil/: PASS" || bad "W1 the walk under /pgvigil/: $(grep '^click-through: \|^FAIL: ' "$KEEP/w1.log" | tail -1 | cut -c1-200)"
walked w1

echo "== W2: the same walk at the root (its own seeded demo, no base)"
PGVIGIL_CLICKTHROUGH_OUT="$KEEP/w2" bash scripts/proof-clickthrough.sh > "$KEEP/w2.log" 2>&1 && ok "W2 the walk at the root: PASS" || bad "W2 the walk at the root: $(grep '^click-through: \|^FAIL: ' "$KEEP/w2.log" | tail -1 | cut -c1-200)"
walked w2

echo "== the walks' NEW rows (kept in $KEEP: w1/ and w2/ each with clickthrough.tsv, grade.txt and contact.html)"
for w in w1 w2; do
  echo "   $w: $(newrows "$KEEP/$w" | wc -l) distinct NEW row(s); by kind, scope and page:"
  { newrows "$KEEP/$w" | awk -F'\t' '{print $4 " | " $1 " " $2}' | sort | uniq -c | sort -rn | head -30 | sed 's/^/     /'; } || true
done
LC_ALL=C comm -23 <(newrows "$KEEP/w1") <(newrows "$KEEP/w2") > "$KEEP/new-under-base-only.tsv" || true
echo "   NEW under /pgvigil/ and not at the root (the base path's own): $(wc -l < "$KEEP/new-under-base-only.tsv") row(s)"
{ head -60 "$KEEP/new-under-base-only.tsv" | tr '\t' '|' | cut -c1-240 | sed 's/^/     /'; } || true
echo "proof-basepath: $VERDICT"
[ "$VERDICT" = PASS ]
