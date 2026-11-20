#!/usr/bin/env bash
# Proof of the saved views store (migration 0259: saved page views and dashboards, one store).
# Needs: go, psql, curl, python3, ss, and
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a PostgreSQL 13+ cluster as a superuser; the proof makes a repository
#                      database and a reader login of its own and removes them on every exit path the shell can catch
#   PGVIGIL_PARTS      the parts to run (default 'S A U N')
#   PGVIGIL_WIRING     1 (default) applies scripts/proof-views-wiring.patch (web.go's routes, config.go's views key,
#                      serve.go's line) to this copy when the tree has the handlers and web.go lacks the routes
#
# Expected (written before the first run):
#  S  the store's doors: pgvigil.ui_views and pgvigil.ui_view_log exist (migration 0259); a login IN ROLE pgvigil_reader
#     alone (a store custom report's or a Grafana reader's) has no SELECT on either and no EXECUTE on ui_view_list,
#     ui_view_get, import_view_save or import_view_delete - its SELECT of ui_views is refused 'permission denied'; the
#     four functions are SECURITY DEFINER.
#  A  the API (serve with the UI login; u1 and u3 are admins, u2 a viewer named in views.shared_editors - B24f: a shared
#     view needs the admin role, the key no longer decides):
#     S1 u1 saves a personal page view on root:fleet -> 200, version 1; u1's list has it ('mine'); u2's list does not;
#        u2's GET of its id -> 404 in words.
#     S2 u2 saves a shared view -> 403 in words naming the admin role, nothing stored; u1 saves the shared 'team'
#        -> 200; u2's list shows it, not 'mine'; u2's edit of it -> 403.
#     S2b the owner check: u2 saves its personal 'u2mine' -> 200; u2's save and delete of u1's personal
#        'mine' -> 403 ('only its owner'), 'mine' unchanged; editor u1's save of u2's 'u2mine' -> 403.
#     S3 u1 saves 'mine' again with version 0 (stale) -> 409 naming the stored version 1; with version 1 -> 200,
#        version 2.
#     S4 u1 saves a second personal 'MINE' on root:fleet -> 409 (the name is taken, case-blind); 'MINE' on
#        instance:slowqueries -> 200.
#     S5 the default order: u1 marks 'mine' its default and 'team' the shared default of root:fleet: u1's list loads
#        'mine' by default, u2's loads 'team'; u1 marks the second personal 'mine2' its default: 'mine' is no longer it
#        (one default per owner and page), its version moved.
#     S6 a state over 64 KB -> 400 in words, nothing stored.
#     S7 the page-key rule: a page view saved with params {i, tag, w, ms} keeps {ms} only; with keep_range its state.range
#        keeps w; a page key 'Fleet!' -> 400.
#     S7b a page view's state other than {params, layouts, range} with text params -> 400 in words: a
#        top-level 'i', params as a string, a number parameter.
#     S8 un-sharing keeps the owner: u1's personal 'flip' shared by u1, then un-shared by editor u3 ->
#        200, still u1's (in u1's list as mine, not in u3's).
#     S11 every POST of A left one ui_view_log row, its outcome the HTTP answer's (200 done, 400 refused, 403 forbidden,
#        409 conflict), compared one by one as counts per outcome.
#     S12 delete: u1's delete of 'mine2' with a stale version -> 409; with its version -> 200 and the view is gone; u2's
#        delete of 'team' -> 403.
#  U  a removed user (pgvigil user remove u1): u1's personal views are deleted with it; the shared 'team' stays, its
#     owner NULL, still in u2's list; u2's own personal 'u2mine' stays (only u1's go); the log rows stay.
#  N  a -no-login serve: GET /api/views lists the shared views ('team' when part A ran) with writable false and the
#     reason naming -no-login;
#     POST /api/views -> 403 with it, nothing written.
#  Red before the store: S 'no table pgvigil.ui_views'; A, N the route answers 404 'no such endpoint'.
set -uo pipefail
: "${PGVIGIL_ADMIN_DSN:?}"
cd "$(dirname "$0")/.."
PARTS=${PGVIGIL_PARTS:-S A U N}
part() { [[ " $PARTS " == *" $1 "* ]]; }
SUF=$RANDOM
REPO=pgvigil_views_$SUF; RDR=pgvigil_views_rdr_$SUF
PW=p$RANDOM$RANDOM$RANDOM; U1=ed$SUF; U2=vw$SUF; U3=ex$SUF; U1PW=a$RANDOM$RANDOM$RANDOM; U2PW=b$RANDOM$RANDOM$RANDOM; U3PW=c$RANDOM$RANDOM$RANDOM
WORK=$(mktemp -d); SRV=""; SRV2=""; ATT=0; : > "$WORK/attempts"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$SRV2" ]] && kill "$SRV2" 2>/dev/null || true
  wait 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO with (force)" \
    -c "drop role if exists $RDR" >/dev/null 2>&1 || echo "CLEANUP: $REPO or $RDR not dropped" >&2
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in go psql curl python3 ss; do command -v $t >/dev/null || fail "$t is not on this machine"; done
freeport() {
  local p
  for _ in $(seq 1 50); do
    p=$((20000 + RANDOM % 20000))
    ss -ltn | awk '{print $4}' | grep -qE "(^|[:\]])$p$" || { echo "$p"; return; }
  done
  fail "no free port"
}
HAVE=0; grep -q 'func (s \*Server) Views(' internal/web/*.go 2>/dev/null && HAVE=1
if [[ "${PGVIGIL_WIRING:-1}" == 1 && $HAVE == 1 ]] && ! grep -q '/api/views' internal/web/web.go; then
  git apply scripts/proof-views-wiring.patch 2>/dev/null || patch -p1 < scripts/proof-views-wiring.patch >/dev/null || fail "the wiring patch"
  echo "wiring applied to this copy (web.go, config.go, serve.go)"
fi
BIN=$WORK/pgvigil
go build -o "$BIN" ./cmd/pgvigil || fail "go build"

psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO" >/dev/null || fail "create database"
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
{ printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n'
  # u2, a viewer, is named in the key that decided before the roles: S2 proves it no longer decides;
  # a tree before the store is given no such key (its red is the missing table and route)
  [[ $HAVE == 1 ]] && printf 'views:\n  shared_editors: [%s]\n' "$U2"
} > "$WORK/cfg.yaml"
CFG=$WORK/cfg.yaml
"$BIN" migrate -config "$CFG" > "$WORK/migrate.out" 2>&1 || { tail -5 "$WORK/migrate.out" >&2; fail "migrate"; }
"$BIN" migrate -config "$CFG" > "$WORK/migrate2.out" 2>&1 || { tail -5 "$WORK/migrate2.out" >&2; fail "migrate twice"; }
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create role $RDR login password '$PW' in role pgvigil_reader" >/dev/null || fail "the reader login"
as_rdr() { psql "$PGVIGIL_ADMIN_DSN dbname=$REPO user=$RDR password=$PW" -XAt -c "$1" 2>&1 || true; }
PGVIGIL_PASSWORD=$U1PW "$BIN" user add -config "$CFG" -role admin "$U1" >/dev/null 2>&1 || fail "user add $U1"
PGVIGIL_PASSWORD=$U2PW "$BIN" user add -config "$CFG" -role viewer "$U2" >/dev/null 2>&1 || fail "user add $U2"
PGVIGIL_PASSWORD=$U3PW "$BIN" user add -config "$CFG" -role admin "$U3" >/dev/null 2>&1 || fail "user add $U3"
echo "ok   setup: repository $REPO on PostgreSQL $(q "select current_setting('server_version')"), users $U1 and $U3 (admins) and $U2 (a viewer, named in views.shared_editors)"

if part S; then
  [[ $(q "select to_regclass('pgvigil.ui_views') is not null and to_regclass('pgvigil.ui_view_log') is not null") == t ]] || fail "S: no table pgvigil.ui_views / ui_view_log (red before 0259)"
  [[ $(as_rdr "select has_table_privilege('pgvigil.ui_views', 'SELECT'), has_table_privilege('pgvigil.ui_view_log', 'SELECT')") == "f|f" ]] || fail "S: the reader may read the store: $(as_rdr "select has_table_privilege('pgvigil.ui_views', 'SELECT'), has_table_privilege('pgvigil.ui_view_log', 'SELECT')")"
  out=$(as_rdr "select count(*) from pgvigil.ui_views"); [[ $out == *"permission denied for table ui_views"* ]] || fail "S: the reader's SELECT of ui_views: $out"
  for f in "ui_view_list(text, text)" "ui_view_get(text, bigint)" "import_view_save(timestamptz, jsonb)" "import_view_delete(timestamptz, jsonb)"; do
    [[ $(as_rdr "select has_function_privilege('pgvigil.$f', 'EXECUTE')") == f ]] || fail "S: the reader may run $f"
    [[ $(q "select prosecdef from pg_proc where oid = 'pgvigil.$f'::regprocedure") == t ]] || fail "S: $f is not SECURITY DEFINER"
  done
  ok "S: ui_views and ui_view_log owner-only by name: the reader's SELECT refused, no EXECUTE on the four functions; each SECURITY DEFINER"
fi

serve_up() {   # serve_up <var for the pid> <port> [extra flags]: never inside $(...) (its fail would end the subshell only)
  local var=$1 port=$2; shift 2
  "$BIN" serve -config "$CFG" -listen "127.0.0.1:$port" "$@" >> "$WORK/serve-$port.log" 2>&1 &
  printf -v "$var" '%s' "$!"
  for _ in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$port/api/session" 2>/dev/null && break; sleep 0.1; done
  kill -0 "${!var}" 2>/dev/null || { tail -5 "$WORK/serve-$port.log" >&2; fail "serve exited"; }
}
login() {   # login <jar> <user> <password>
  [[ $(curl -s -o /dev/null -w '%{http_code}' -c "$1" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$2\",\"password\":\"$3\"}" "$U/api/login") == 200 ]] || fail "the API login of $2"
}
# call <jar or -> <GET|POST> <path> [body file]: the HTTP code; the body in $WORK/out.json
call() {
  local jar=$1 m=$2 p=$3 d=${4:-} c=()
  [[ $jar != - ]] && c=(-b "$jar")
  if [[ $m == GET ]]; then curl -s -o "$WORK/out.json" -w '%{http_code}' "${c[@]}" -H 'X-Pgvigil: 1' "$U$p"
  else local code; code=$(curl -s -o "$WORK/out.json" -w '%{http_code}' "${c[@]}" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$d" "$U$p")
    echo "$code" >> "$WORK/attempts"; echo "$code"; fi
}
body() { printf '%s' "$1" > "$WORK/in.json"; echo "$WORK/in.json"; }
# js <python expression over d (the reply) and rows(t) (a {columns, rows} table as dicts)>
js() { python3 -c "import json; d=json.load(open('$WORK/out.json')); rows=lambda t: [dict(zip(t['columns'], r)) for r in (t.get('rows') or [])] if t else []; print($1)"; }
expect() { [[ $1 == "$2" ]] || fail "$3: HTTP $1, want $2: $(head -c 300 "$WORK/out.json")"; }

if part A; then
  PORT=$(freeport); U="http://127.0.0.1:$PORT"; serve_up SRV "$PORT"
  J1=$WORK/j1; J2=$WORK/j2; login "$J1" "$U1" "$U1PW"; login "$J2" "$U2" "$U2PW"
  # S1
  c=$(call "$J1" POST /api/views "$(body '{"kind":"page","page":"root:fleet","name":"mine","state":{"params":{"focus":"1"},"layouts":[]}}')")
  [[ $c == 404 ]] && fail "S1: POST /api/views: HTTP 404 (red before the store: no route)"
  expect "$c" 200 "S1: u1's personal save"; MINE=$(js "d['view_id']"); [[ $(js "d['version']") == 1 ]] || fail "S1: version $(js "d['version']")"
  expect "$(call "$J1" GET '/api/views?page=root:fleet')" 200 "S1: u1's list"
  [[ $(js "[v['mine'] for v in rows(d['views']) if v['name'] == 'mine']") == "[True]" ]] || fail "S1: u1's list: $(head -c 300 "$WORK/out.json")"
  expect "$(call "$J2" GET '/api/views?page=root:fleet')" 200 "S1: u2's list"
  [[ $(js "len([v for v in rows(d['views']) if v['name'] == 'mine'])") == 0 ]] || fail "S1: u2 lists u1's personal view"
  c=$(call "$J2" GET "/api/views?id=$MINE"); expect "$c" 404 "S1: u2's GET of u1's personal view"
  ok "S1: a personal view: u1 lists and reads it, u2 neither lists nor reads it (404 in words: $(js "d.get('error')"))"
  # S2
  c=$(call "$J2" POST /api/views "$(body '{"kind":"page","page":"root:fleet","name":"u2shared","shared":true,"state":{"params":{}}}')")
  expect "$c" 403 "S2: u2's shared save"; [[ $(js "d.get('error', '')") == *"needs the admin role"* ]] || fail "S2: the refusal does not name the admin role: $(js "d")"
  [[ $(q "select count(*) from pgvigil.ui_views where name = 'u2shared'") == 0 ]] || fail "S2: u2's shared view stored"
  c=$(call "$J1" POST /api/views "$(body '{"kind":"page","page":"root:fleet","name":"team","shared":true,"state":{"params":{"focus":"0"}}}')")
  expect "$c" 200 "S2: u1's shared save"; TEAM=$(js "d['view_id']")
  expect "$(call "$J2" GET '/api/views?page=root:fleet')" 200 "S2: u2's list"
  [[ $(js "[(v['shared'], v['mine']) for v in rows(d['views']) if v['name'] == 'team']") == "[(True, False)]" ]] || fail "S2: u2's list of 'team': $(head -c 300 "$WORK/out.json")"
  c=$(call "$J2" POST /api/views "$(body "{\"view_id\":$TEAM,\"version\":1,\"kind\":\"page\",\"page\":\"root:fleet\",\"name\":\"team\",\"shared\":true,\"state\":{\"params\":{\"focus\":\"1\"}}}")")
  expect "$c" 403 "S2: u2's edit of the shared view"
  ok "S2: shared writes only by an admin (u2, a viewer named in views.shared_editors, refused in words: create and edit); u2 reads 'team'"
  J3=$WORK/j3; login "$J3" "$U3" "$U3PW"
  c=$(call "$J2" POST /api/views "$(body '{"kind":"page","page":"root:fleet","name":"u2mine","state":{"params":{}}}')"); expect "$c" 200 "S2b: u2's personal save"; U2MINE=$(js "d['view_id']")
  c=$(call "$J2" POST /api/views "$(body "{\"view_id\":$MINE,\"version\":1,\"kind\":\"page\",\"page\":\"root:fleet\",\"name\":\"taken\",\"state\":{\"params\":{}}}")")
  expect "$c" 403 "S2b: u2's save of u1's personal view"; [[ $(js "d.get('error', '')") == *"only its owner"* ]] || fail "S2b: the refusal: $(js "d")"
  c=$(call "$J2" POST /api/views/delete "$(body "{\"view_id\":$MINE,\"version\":1}")"); expect "$c" 403 "S2b: u2's delete of u1's personal view"
  [[ $(q "select name || ' ' || version from pgvigil.ui_views where view_id = $MINE") == "mine 1" ]] || fail "S2b: 'mine' changed: $(q "select name, version from pgvigil.ui_views where view_id = $MINE")"
  c=$(call "$J1" POST /api/views "$(body "{\"view_id\":$U2MINE,\"version\":1,\"kind\":\"page\",\"page\":\"root:fleet\",\"name\":\"u2mine\",\"state\":{\"params\":{\"x\":\"1\"}}}")")
  expect "$c" 403 "S2b: editor u1's save of u2's personal view"
  ok "S2b: a personal view is changed and deleted by its owner only (u2 on u1's, editor u1 on u2's: 403), unchanged"
  # S3
  c=$(call "$J1" POST /api/views "$(body "{\"view_id\":$MINE,\"version\":0,\"kind\":\"page\",\"page\":\"root:fleet\",\"name\":\"mine\",\"state\":{\"params\":{\"focus\":\"0\"}}}")")
  expect "$c" 409 "S3: a stale version"; [[ $(js "d.get('error', '')") == *"version 1"* ]] || fail "S3: the 409 does not name the stored version: $(js "d")"
  c=$(call "$J1" POST /api/views "$(body "{\"view_id\":$MINE,\"version\":1,\"kind\":\"page\",\"page\":\"root:fleet\",\"name\":\"mine\",\"state\":{\"params\":{\"focus\":\"0\"}}}")")
  expect "$c" 200 "S3: the right version"; [[ $(js "d['version']") == 2 ]] || fail "S3: version $(js "d['version']"), want 2"
  ok "S3: a stale version -> 409 naming the stored one; the right one -> 200, version 2"
  # S4
  c=$(call "$J1" POST /api/views "$(body '{"kind":"page","page":"root:fleet","name":"MINE","state":{"params":{}}}')")
  expect "$c" 409 "S4: a taken name (case-blind)"
  c=$(call "$J1" POST /api/views "$(body '{"kind":"page","page":"instance:slowqueries","name":"MINE","state":{"params":{}}}')")
  expect "$c" 200 "S4: the same name on another page"
  ok "S4: a name is one per owner and page, case-blind (409 in words: $(q "select detail from pgvigil.ui_view_log where outcome = 'conflict' order by log_id desc limit 1"))"
  # S5
  c=$(call "$J1" POST /api/views "$(body "{\"view_id\":$MINE,\"version\":2,\"kind\":\"page\",\"page\":\"root:fleet\",\"name\":\"mine\",\"is_default\":true,\"state\":{\"params\":{\"focus\":\"0\"}}}")")
  expect "$c" 200 "S5: u1's personal default"
  c=$(call "$J1" POST /api/views "$(body "{\"view_id\":$TEAM,\"version\":1,\"kind\":\"page\",\"page\":\"root:fleet\",\"name\":\"team\",\"shared\":true,\"is_default\":true,\"state\":{\"params\":{\"focus\":\"0\"}}}")")
  expect "$c" 200 "S5: the shared default"
  expect "$(call "$J1" GET '/api/views?page=root:fleet')" 200 "S5: u1's list"
  [[ $(js "[v['name'] for v in rows(d['views']) if v['loads_by_default']]") == "['mine']" ]] || fail "S5: u1 loads by default: $(js "[v['name'] for v in rows(d['views']) if v['loads_by_default']]")"
  expect "$(call "$J2" GET '/api/views?page=root:fleet')" 200 "S5: u2's list"
  [[ $(js "[v['name'] for v in rows(d['views']) if v['loads_by_default']]") == "['team']" ]] || fail "S5: u2 loads by default: $(js "[v['name'] for v in rows(d['views']) if v['loads_by_default']]")"
  c=$(call "$J1" POST /api/views "$(body '{"kind":"page","page":"root:fleet","name":"mine2","is_default":true,"state":{"params":{}}}')")
  expect "$c" 200 "S5: a second personal default"; MINE2=$(js "d['view_id']")
  [[ $(q "select is_default::text || ' ' || version from pgvigil.ui_views where view_id = $MINE") == "false 4" ]] || fail "S5: 'mine' after 'mine2' became the default: $(q "select is_default, version from pgvigil.ui_views where view_id = $MINE")"
  ok "S5: u1 loads its own default, u2 the shared one; one default per owner and page (the old one cleared, its version moved)"
  # S6
  python3 -c "import json; print(json.dumps({'kind':'page','page':'root:fleet','name':'big','state':{'params':{'x':'y'*70000}}}))" > "$WORK/big.json"
  c=$(call "$J1" POST /api/views "$WORK/big.json"); expect "$c" 400 "S6: over 64 KB"
  [[ $(q "select count(*) from pgvigil.ui_views where name = 'big'") == 0 ]] || fail "S6: the big view stored"
  ok "S6: a state over 64 KB refused in words ($(js "d.get('error')")), nothing stored"
  # S7
  c=$(call "$J1" POST /api/views "$(body '{"kind":"page","page":"instance:slowqueries","name":"rule","state":{"params":{"i":"7","tag":"env:x","w":"24h","view":"3","ms":"5000"}}}')")
  expect "$c" 200 "S7: a page view with i, tag, w"; RULE=$(js "d['view_id']")
  [[ $(q "select state->'params' from pgvigil.ui_views where view_id = $RULE") == '{"ms": "5000"}' ]] || fail "S7: params kept: $(q "select state->'params' from pgvigil.ui_views where view_id = $RULE")"
  c=$(call "$J1" POST /api/views "$(body '{"kind":"page","page":"instance:slowqueries","name":"ranged","keep_range":true,"state":{"params":{"i":"7","w":"24h","ms":"5000"}}}')")
  expect "$c" 200 "S7: keep_range"; RANGED=$(js "d['view_id']")
  [[ $(q "select (state->'params')::text || ' ' || (state->'range')::text from pgvigil.ui_views where view_id = $RANGED") == '{"ms": "5000"} {"w": "24h"}' ]] || fail "S7: keep_range: $(q "select state from pgvigil.ui_views where view_id = $RANGED")"
  c=$(call "$J1" POST /api/views "$(body '{"kind":"page","page":"Fleet!","name":"bad","state":{"params":{}}}')"); expect "$c" 400 "S7: a bad page key"
  ok "S7: a page view keeps its page's parameters only (i, tag, view, the range dropped; the range kept by keep_range); a bad page key 400"
  for bad in '{"params":{},"i":"7"}' '{"params":"i=7&ms=5"}' '{"params":{"ms":5}}'; do
    c=$(call "$J1" POST /api/views "$(body "{\"kind\":\"page\",\"page\":\"root:fleet\",\"name\":\"shape\",\"state\":$bad}")"); expect "$c" 400 "S7b: the state $bad"
  done
  [[ $(q "select count(*) from pgvigil.ui_views where name = 'shape'") == 0 ]] || fail "S7b: a bad shape stored"
  ok "S7b: a page view's state is {params, layouts, range} with text params ($(js "d.get('error')"))"
  c=$(call "$J1" POST /api/views "$(body '{"kind":"page","page":"root:fleet","name":"flip","state":{"params":{}}}')"); expect "$c" 200 "S8: u1's personal 'flip'"; FLIP=$(js "d['view_id']")
  c=$(call "$J1" POST /api/views "$(body "{\"view_id\":$FLIP,\"version\":1,\"kind\":\"page\",\"page\":\"root:fleet\",\"name\":\"flip\",\"shared\":true,\"state\":{\"params\":{}}}")"); expect "$c" 200 "S8: u1 shares 'flip'"
  c=$(call "$J3" POST /api/views "$(body "{\"view_id\":$FLIP,\"version\":2,\"kind\":\"page\",\"page\":\"root:fleet\",\"name\":\"flip\",\"shared\":false,\"state\":{\"params\":{}}}")"); expect "$c" 200 "S8: editor u3 un-shares 'flip'"
  [[ $(q "select u.username from pgvigil.ui_views v join pgvigil.ui_users u on u.user_id = v.owner_user_id where v.view_id = $FLIP") == "$U1" ]] || fail "S8: 'flip' is no longer u1's"
  expect "$(call "$J1" GET '/api/views?page=root:fleet')" 200 "S8: u1's list"; [[ $(js "[v['mine'] for v in rows(d['views']) if v['name'] == 'flip']") == "[True]" ]] || fail "S8: u1's list of 'flip'"
  expect "$(call "$J3" GET '/api/views?page=root:fleet')" 200 "S8: u3's list"; [[ $(js "len([v for v in rows(d['views']) if v['name'] == 'flip'])") == 0 ]] || fail "S8: u3 lists u1's personal 'flip'"
  ok "S8: un-sharing keeps the owner: u3 un-shared u1's 'flip', it is u1's personal view again"
  # S12
  c=$(call "$J1" POST /api/views/delete "$(body "{\"view_id\":$MINE2,\"version\":0}")"); expect "$c" 409 "S12: a stale delete"
  c=$(call "$J1" POST /api/views/delete "$(body "{\"view_id\":$MINE2,\"version\":1}")"); expect "$c" 200 "S12: the delete"
  [[ $(q "select count(*) from pgvigil.ui_views where view_id = $MINE2") == 0 ]] || fail "S12: 'mine2' still stored"
  c=$(call "$J2" POST /api/views/delete "$(body "{\"view_id\":$TEAM,\"version\":2}")"); expect "$c" 403 "S12: u2's delete of a shared view"
  ok "S12: a delete checks the version (409) and the right (403); the view is gone"
  # S11
  ATT=$(wc -l < "$WORK/attempts")
  WANT=$(python3 -c "import collections,sys; m={'200':'done','400':'refused','403':'forbidden','409':'conflict'}; c=collections.Counter(m.get(l.strip(), 'http'+l.strip()) for l in open(sys.argv[1]) if l.strip()); print(', '.join(f'{k} {c[k]}' for k in sorted(c)))" "$WORK/attempts")
  GOT=$(q "select string_agg(outcome || ' ' || n, ', ' order by outcome) from (select outcome, count(*) n from pgvigil.ui_view_log group by 1) x")
  [[ "$GOT" == "$WANT" ]] || fail "S11: the log's outcomes '$GOT', the answers' '$WANT'"
  ok "S11: one ui_view_log row per attempt ($ATT): $(q "select string_agg(outcome || ' ' || n, ', ' order by outcome) from (select outcome, count(*) n from pgvigil.ui_view_log group by 1) x")"
fi

if part U; then
  [[ -n "${TEAM:-}" ]] || fail "U: needs part A's views"
  LOGN=$(q "select count(*) from pgvigil.ui_view_log")
  "$BIN" user remove -config "$CFG" "$U1" > "$WORK/remove.out" 2>&1 || { cat "$WORK/remove.out" >&2; fail "U: user remove $U1"; }
  [[ $(q "select count(*) from pgvigil.ui_views where not shared and created_by = '$U1'") == 0 ]] || fail "U: u1's personal views kept: $(q "select name from pgvigil.ui_views where not shared and created_by = '$U1'")"
  [[ $(q "select count(*) from pgvigil.ui_views where view_id = $U2MINE") == 1 ]] || fail "U: u2's own personal view went with u1"
  [[ $(q "select coalesce(owner_user_id::text, 'null') from pgvigil.ui_views where view_id = $TEAM") == null ]] || fail "U: the shared view's owner after the remove"
  [[ $(q "select count(*) from pgvigil.ui_view_log") == "$LOGN" ]] || fail "U: log rows lost"
  expect "$(call "$J2" GET '/api/views?page=root:fleet')" 200 "U: u2's list"
  [[ $(js "[v['name'] for v in rows(d['views'])]") == "['u2mine', 'team']" ]] || fail "U: u2's list after the remove: $(js "[v['name'] for v in rows(d['views'])]")"
  ok "U: removing u1 deleted its personal views only (u2's 'u2mine' stays), kept the shared 'team' (owner NULL, still listed) and every log row"
fi

if part N; then
  PORT2=$(freeport); U="http://127.0.0.1:$PORT2"; serve_up SRV2 "$PORT2" -no-login
  c=$(call - GET '/api/views?page=root:fleet')
  [[ $c == 404 ]] && fail "N: GET /api/views: HTTP 404 (red before the store: no route)"
  expect "$c" 200 "N: the -no-login list"
  [[ $(js "d['writable']") == False && $(js "d.get('off', '')") == *-no-login* ]] || fail "N: writable / off: $(js "(d['writable'], d.get('off'))")"
  if [[ -n "${TEAM:-}" ]]; then [[ $(js "[v['name'] for v in rows(d['views'])]") == "['team']" ]] || fail "N: the shared views listed: $(js "[v['name'] for v in rows(d['views'])]")"; fi
  N0=$(q "select count(*) from pgvigil.ui_views")
  c=$(call - POST /api/views "$(body '{"kind":"page","page":"root:fleet","name":"anon","state":{"params":{}}}')"); expect "$c" 403 "N: a -no-login save"
  [[ $(q "select count(*) from pgvigil.ui_views") == "$N0" ]] || fail "N: a -no-login save stored"
  ok "N: -no-login lists the shared views read-only ($(js "d.get('error', '')"))"
fi
echo "PASS: proof-views ($PARTS)"
