#!/usr/bin/env bash
# Proof of the agent door (migration 0268, internal/mcp's agent tools, internal/web/q_investigate.go, web/src/investigate.ts):
# a person asks for an investigation of a finding (the Investigate button) or asks a question (the Ask box); the
# operator's own agent claims the request through `pgvigil mcp` on a login IN ROLE pgvigil_reader, pgvigil_agent, reads
# with the read tools and run_select, and reports; serve shows the report and runs an ask's one SELECT as reports_dsn.
# The agent here is scripts/agent-client.py: JSON-RPC over the binary's stdio, no model.
#
#   PGVIGIL_ADMIN_DSN   keyword-form connection to a PostgreSQL 14+ cluster as a superuser, no dbname (its password, if
#                       any, through PGPASSWORD or ~/.pgpass: never on a command line). The proof makes a repository
#                       database, a target database and the logins named pgagt_*_<random>, and drops them at the end
#                       (not the cluster-wide group roles pgvigil_*, which migrate makes).
#   PGVIGIL_BIN         a built pgvigil; default: built here. The web bundle must carry the page for part U.
#   PGVIGIL_SKIP_MSSQL=1    no SQL Server line of part M: printed NOT PROVEN.
#   PGVIGIL_SKIP_PAGES=1    no part U: printed NOT PROVEN.
#   PGVIGIL_SKIP_STANDBY=1  no standby line of part R: printed NOT PROVEN.
#   MSSQL_IMAGE, PG_IMAGE   the SQL Server image (M) and the PostgreSQL image of R's primary and standby.
#   Needs: psql, curl, jq, python3, docker (M's SQL Server, R's standby), chromium, node, npm (U, axe-core 4.14.0).
#
# Expected (written before the first run; the base rel-j15 75c72186 is RED on every part: no tables, no tools, no routes).
#  A. off: a serve without the agents: section answers GET and POST /api/investigations 404 with 'agents.enabled is
#     off'; a plain reader login's `pgvigil mcp` lists the nine read tools only and a claim_investigation call is
#     unknown (-32602).
#  R. roles: a login IN ROLE pgvigil_reader, pgvigil_agent lists 16 tools (the nine + list_investigations,
#     wait_for_investigations, claim_investigation, renew_investigation, run_select, report_investigation,
#     release_investigation). Refused at start (exit 3, 'refused' and the reason on stderr, nothing on stdout), each
#     also holding pgvigil_agent: a collector login (pgvigil_collector), an auth member (pgvigil_auth), a reader with
#     DELETE on one table ("may change the repository's tables"), the superuser ('superuser'), pg_read_all_data,
#     pg_read_server_files, pgvigil_alerter (each named), the database owner reaching the agent role through
#     options=-c role= ('pg_database_owner': the check reads the SESSION user); the agent role on a standby ('in
#     recovery'). The plain reader, the reports login and the UI login calling agent_investigation_list are refused:
#     'is not a member of pgvigil_agent' (the function's own check on the session user: apply_roles grants every
#     function outside its lists to the reader at each migrate, until the join file's agent branch takes that back) or,
#     after the join, 'permission denied for function'; the agent login's own INSERT into pgvigil.investigations:
#     permission denied. [R3's words widened after the red run, before any code: the migration cannot take the
#     reader's EXECUTE back while apply_roles grants it at every migrate.]
#  Q. the request: POST /api/investigations without a session 401, without X-Pgvigil 403; with both 200 and an id; the
#     row is kind finding, state open, asked_by the UI user; its journal holds 'asked'; its snapshot is serve's read of
#     the finding (its setting), and a 'snapshot' the body carries is not in it. A user's 11th open request: 409 'already
#     has 10 open'. 25 requests at once from three users: 20 accepted, 5 refused '20 investigations in the last hour'.
#  C. claim (the clock stood for by the owner's UPDATE of lease_until / expires_at): two agents claim one request at
#     once (two processes, one barrier file): one claim_id, the other refused 'claimed by'; renew moves lease_until;
#     a lapsed lease reads open and is claimed again by the other login (claims 2); the first claimer's renew and report
#     refused 'not your claim'; a login with another login's claim id refused 'not your claim'; the third lapse reads
#     expired and a claim is refused 'expired'; a renew past expires_at refused 'expired'; release -> open, journal
#     'released', its reason only in the ui_ text table; wait_for_investigations answers within 2 s of a request made
#     1 s after it started; two requests committed out of order (the first insert's transaction held 4 s) both reach a
#     waiting agent; with the agent's listening session terminated, a wait still answers (the 5 s poll) within 8 s.
#  B. the brief: claim answers request.snapshot.setting = the finding's setting, request.note, next_calls[0] =
#     instance_findings of that instance, budget 30 min / 40 tool calls, under 24,000 characters; a second request of
#     the same finding, after the first was reported: earlier_reports[0] = the first, unreviewed true.
#  S. run_select: a SELECT answers its rows; refused with the server's words and journaled: two statements, an
#     INSERT, a data-modifying WITH, a function that writes, ui_users, ui_password_hash, set_config('role') then
#     ui_users; pg_sleep(20) cut by the statement timeout in under 19 s; 5,000 rows answer 1,000 with cut true; a
#     multi-statement text on a DSN with default_query_exec_mode=simple_protocol refused in under 10 s and its pg_sleep
#     never runs; an advisory lock taken in one call is not held after it; a bogus claim id refused 'not your claim'; a
#     request whose record holds 200 rows refuses the next run "the request's record is full".
#  J. the record: each run_select of S is one 'select' row of the journal (rows, ms, outcome; refused ones included),
#     its text in pgvigil.ui_investigation_journal_text; the plain reader reads the journal but not the text table
#     (permission denied); serve's GET of the request shows a signed-in user each statement's text.
#  P. the report: a summary over 4,000 characters and 51 evidence entries refused with words; a report accepted, state
#     reported; another signed-in user sees its summary and the verdict on the grid; the plain reader reads the row's
#     verdict but not pgvigil.ui_investigation_data (permission denied); close with a reason: state closed, closed_by
#     the user, journal 'closed'.
#  K. the ask: a question is claimed (brief.request.question) and answered with one SELECT (verdict answered); a report
#     whose sql holds two statements refused 'one SELECT'; POST /api/investigations/run {id} as another user runs the
#     STORED SQL (a 'sql' in the body ignored) as reports_dsn: its column n = the instance count, a journal 'run' row of
#     that user; a request whose record is full: Run refused "the request's record is full" and no rows; a serve without
#     reports_dsn: Run refused 'a report on the store runs only as a login IN ROLE pgvigil_reader alone'; an ask whose
#     SQL calls ui_password_hash: Run refused 'permission denied for function ui_password_hash'.
#  E. expiry: a request past expires_at reads expired in serve's list at once, an agent's list of open requests leaves
#     it out and writes it expired; a claim whose lease lapsed reads open in serve's list with no agent running; a
#     user's 10 requests past expires_at do not count against the 10-open cap; investigations_purge() removes a closed
#     request asked 100 days ago and keeps an open one asked 100 days ago whose expiry is ahead.
#  M. masks, through `collect -once activity` of one statement holding a literal LIT and pgp_sym_encrypt(.., P1) on
#     instances under query_text full, normalized and none: run_select over activity_sample + query_text answers the
#     full instance's text with LIT and '<masked>' and without P1, the normalized one without LIT and P1, none no text;
#     no output of any agent client holds P1. SQL Server (415's mask, in this tree): a waiting UPDATE carrying '-P S1'
#     stored by `collect -once mssql_requests` under full: run_select over mssql_statement_text and find_statements
#     answer '<masked>' and never S1.
#  U. the pages (headless Chromium, the session cookie set): #/findings shows an Investigate button on a finding row;
#     #/investigations shows the Ask box, the grid with the requests and a report's 'unreviewed' line; the serve
#     without agents: no Investigate button; axe-core finds 0 violation nodes on #/investigations in both themes.
#  Not here: queue mode (CQ's request queue is not in this tree: its two lines are WIRING at the join); the real agent's
#  run (its own job); go test ./internal/repo (secdef_reader_test.go: the runner's repo part).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 97
: "${PGVIGIL_ADMIN_DSN:?a superuser connection, keyword form, no dbname}"
for t in psql curl jq python3; do command -v $t >/dev/null || { echo "FAIL (setup) $t is required"; exit 1; }; done
SUF=$(head -c 5 /dev/urandom | od -An -tx1 | tr -d ' \n')
WORK=$(mktemp -d); NOTPROVEN=(); FAILS=0; OKS=0
REPO=pgagt_repo_$SUF; TGT=pgagt_tgt_$SUF; PW="Ag${SUF}pw"; UIPW="Ui${SUF}pw"
L() { printf 'pgagt_%s_%s' "$1" "$SUF"; }
LOGINS="ag1 ag2 rd ui rep cola autha wra rada rsfa alra ownm agr"
SRVS=(); CHR=""; MADE_CT=(); MADE_NET=""
cleanup() {
  for p in "${SRVS[@]}" $CHR; do kill "$p" 2>/dev/null; done
  for c in "${MADE_CT[@]}"; do docker rm -f -v "$c" >/dev/null 2>&1; done
  [[ -n $MADE_NET ]] && docker network rm "$MADE_NET" >/dev/null 2>&1
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO with (force)" -c "drop database if exists $TGT with (force)" >/dev/null 2>&1
  for l in $LOGINS; do psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop role if exists $(L $l)" >/dev/null 2>&1; done
  rm -rf "$WORK"
}
trap cleanup EXIT
ok() { OKS=$((OKS + 1)); echo "ok   $*"; }
bad() { FAILS=$((FAILS + 1)); echo "FAIL $*"; }
die() { echo "FAIL (setup) $*"; exit 1; }
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
qa() { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
q() { psql "$PGVIGIL_ADMIN_DSN dbname=$REPO" -XAtq -v ON_ERROR_STOP=1 -c "$1" 2>&1; }
dsn_of() { printf 'host=%s port=%s dbname=%s user=%s password=%s sslmode=disable' "$HOST" "$DBPORT" "$REPO" "$1" "$PW"; }
as() { local who=$1; shift; psql "$(dsn_of "$who")" -XAtq "$@" 2>&1; }

BIN=${PGVIGIL_BIN:-}
if [[ -z "$BIN" ]]; then go build -o "$WORK/pgvigil" ./cmd/pgvigil || die "go build"; BIN=$WORK/pgvigil; fi
BIN=$(readlink -f "$BIN")
HOST=$(psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAt -c "select coalesce(host(inet_server_addr()),'127.0.0.1')")
DBPORT=$(psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAt -c "select inet_server_port()")

# ---- the repository (the demo's findings), the target, the logins ---------------------------------------------------
qa "create database $REPO" >/dev/null || die "create database $REPO"
qa "create database $TGT" >/dev/null || die "create database $TGT"
psql "$PGVIGIL_ADMIN_DSN dbname=$TGT" -XAtq -c "create extension if not exists pgcrypto" >/dev/null || die "pgcrypto in the target"
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO"
"$BIN" demo -dsn env:PGVIGIL_REPO_DSN -instances 3 -days 2 >"$WORK/demo.out" 2>"$WORK/demo.log" || die "demo seed: $(tail -3 "$WORK/demo.log")"
export TGT_DSN="$PGVIGIL_ADMIN_DSN dbname=$TGT"
CFG=$WORK/cfg.yaml
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
reports_dsn: env:REPORTS_DSN
agents:
  enabled: true
instances:
  - name: agt-m-full-$SUF
    dsn: env:TGT_DSN
  - name: agt-m-norm-$SUF
    dsn: env:TGT_DSN
    query_text: normalized
  - name: agt-m-none-$SUF
    dsn: env:TGT_DSN
    query_text: none
EOF
"$BIN" migrate -config "$CFG" >"$WORK/migrate.log" 2>&1 || die "migrate: $(tail -3 "$WORK/migrate.log")"
HAS0268=$(q "select to_regclass('pgvigil.investigations') is not null")
echo "migration 0268 applied: $HAS0268"
mk() { # mk <name> <roles...>: a login IN ROLE pgvigil_reader-like roles; each role granted on its own line (a role the base lacks fails alone)
  local n; n=$(L "$1"); shift
  qa "create role $n login password '$PW'" >/dev/null || die "create role $n"
  for r in "$@"; do qa "grant $r to $n" >/dev/null 2>&1 || echo "note: grant $r to $n failed (absent on this tree?)"; done
}
mk ag1 pgvigil_reader pgvigil_agent; mk ag2 pgvigil_reader pgvigil_agent; mk rd pgvigil_reader; mk ui pgvigil_reader pgvigil_auth
mk rep pgvigil_reader; mk cola pgvigil_collector pgvigil_agent; mk autha pgvigil_reader pgvigil_auth pgvigil_agent
mk wra pgvigil_reader pgvigil_agent; q "grant delete on pgvigil.query_text to $(L wra)" >/dev/null
mk rada pgvigil_reader pgvigil_agent pg_read_all_data; mk rsfa pgvigil_reader pgvigil_agent pg_read_server_files
mk alra pgvigil_reader pgvigil_agent pgvigil_alerter
qa "create role $(L agr) nologin" >/dev/null; qa "grant pgvigil_reader to $(L agr)" >/dev/null; qa "grant pgvigil_agent to $(L agr)" >/dev/null 2>&1
mk ownm "$(L agr)"; qa "alter database $REPO owner to $(L ownm)" >/dev/null || die "the database owner"
export AG1_DSN; AG1_DSN=$(dsn_of "$(L ag1)"); export AG2_DSN; AG2_DSN=$(dsn_of "$(L ag2)"); export RD_DSN; RD_DSN=$(dsn_of "$(L rd)")
export UI_DSN; UI_DSN=$(dsn_of "$(L ui)"); export REPORTS_DSN; REPORTS_DSN=$(dsn_of "$(L rep)")
export AG1S_DSN="$AG1_DSN default_query_exec_mode=simple_protocol"
for u in u1 u2 u3; do PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$CFG" "agt$u$SUF" >/dev/null 2>&1 || die "user add $u"; done
U1=agtu1$SUF; U2=agtu2$SUF; U3=agtu3$SUF

# the finding every request names: the demo's first active finding
read -r FIID FSET FINST < <(q "select f.instance_id, f.setting, i.name from pgvigil.findings_alerts f join pgvigil.instances i using (instance_id) where i.is_active order by case f.severity when 'critical' then 0 when 'warning' then 1 else 2 end, i.name, f.setting limit 1" | tr '|' ' ')
[[ -n "${FIID:-}" && -n "${FSET:-}" ]] || die "the demo seeded no finding"
echo "the finding: instance $FIID ($FINST), setting $FSET"
NINST=$(q "select count(*) from pgvigil.instances")

# ---- the serves ------------------------------------------------------------------------------------------------------
grep -v -E '^agents:|^  enabled:' "$CFG" > "$WORK/cfg-off.yaml"
grep -v '^reports_dsn:' "$CFG" > "$WORK/cfg-norep.yaml"
start_serve() { # start_serve <cfg> -> prints the URL
  local port; port=$(freeport)
  "$BIN" serve -config "$1" -dsn env:UI_DSN -listen "127.0.0.1:$port" >"$WORK/serve-$port.log" 2>&1 &
  SRVS+=($!)
  for n in $(seq 1 60); do curl -sf -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.5; done
  echo "http://127.0.0.1:$port"
}
S1=$(start_serve "$CFG"); S2=$(start_serve "$WORK/cfg-off.yaml"); S3=$(start_serve "$WORK/cfg-norep.yaml")
curl -sf -o /dev/null "$S1/" || die "serve did not answer: $(tail -3 "$WORK"/serve-*.log)"
login() { curl -s -c "$WORK/jar-$2-$3" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$3\",\"password\":\"$UIPW\"}" "$1/api/login" >/dev/null; }
login "$S1" s1 "$U1"; login "$S1" s1 "$U2"; login "$S1" s1 "$U3"; login "$S2" s2 "$U1"; login "$S3" s3 "$U1"
code() { curl -s --max-time 60 -o "$WORK/body" -w '%{http_code}' "$@"; }
# api <serve> <serve tag> <user> <method> <path> [body]
api() { local s=$1 t=$2 u=$3 m=$4 p=$5 b=${6:-}
  if [[ $m == GET ]]; then code -b "$WORK/jar-$t-$u" "$s/api/$p"; else code -b "$WORK/jar-$t-$u" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -X "$m" -d "$b" "$s/api/$p"; fi; }
B() { jq -r "$1" "$WORK/body" 2>/dev/null; }
ask_finding() { api "$S1" s1 "${2:-$U1}" POST investigations "$(jq -cn --argjson i "$FIID" --arg s "$FSET" --arg n "${1:-}" '{kind:"finding",instance_id:$i,setting:$s,note:$n}')" >/dev/null; B '.id // empty'; }
ask_q() { api "$S1" s1 "${2:-$U1}" POST investigations "$(jq -cn --arg q "$1" '{kind:"ask",question:$q}')" >/dev/null; B '.id // empty'; }
reset_inv() { q "delete from pgvigil.investigations" >/dev/null; }

# ---- the scripted agent ----------------------------------------------------------------------------------------------
# mc <dsn var> <name>: runs $WORK/<name>.calls, answers in $WORK/<name>.out
mc() { python3 -I scripts/agent-client.py --bin "$BIN" --dsn-env "$1" "$WORK/$2.calls" > "$WORK/$2.out" 2>"$WORK/$2.err"; }
calls() { local f=$WORK/$1.calls; shift; : > "$f"; for c in "$@"; do printf '%s\n' "$c" >> "$f"; done; }
R() { jq -c "select(.i == $2) | $3" "$WORK/$1.out" 2>/dev/null; }      # R <name> <call index> <jq on the line>
Rr() { jq -r "select(.i == $2) | $3" "$WORK/$1.out" 2>/dev/null; }
tc() { local a=${2:-}; [[ -n $a ]] || a='{}'; jq -cn --arg t "$1" --argjson a "$a" '{tool:$t,args:$a}'; }
lists_tools() { jq -r 'select(.i == 0) | [.reply.result.tools[].name] | sort | join(",")' "$WORK/$1.out" 2>/dev/null; }
READ9="blocking_chain,find_statements,fleet_summary,instance_findings,plan_findings,statement_everywhere,storage_forecast,table_state,top_statements"
ALL16=$(printf '%s\n' blocking_chain find_statements fleet_summary instance_findings plan_findings statement_everywhere storage_forecast table_state top_statements list_investigations wait_for_investigations claim_investigation renew_investigation run_select report_investigation release_investigation | sort | paste -sd,)

echo "--- A. off"
api "$S2" s2 "$U1" GET investigations >/dev/null; a1=$(cat "$WORK/body")
c1=$(api "$S2" s2 "$U1" GET investigations); c2=$(api "$S2" s2 "$U1" POST investigations '{"kind":"ask","question":"x"}'); a2=$(cat "$WORK/body")
[[ $c1 == 404 && $c2 == 404 && $a1 == *"agents.enabled is off"* && $a2 == *"agents.enabled is off"* ]] && ok "A1 the serve without agents: GET and POST 404 with 'agents.enabled is off'" || bad "A1 the serve without agents: GET $c1 POST $c2 (${a1:0:120} | ${a2:0:120})"
calls a_rd '{"rpc":"tools/list","params":{}}' "$(tc claim_investigation '{"id":1,"agent":"x"}')"
mc RD_DSN a_rd
t=$(lists_tools a_rd); e=$(R a_rd 1 '.reply.error.code')
[[ $t == "$READ9" && $e == -32602 ]] && ok "A2 the plain reader's door: the nine read tools, claim_investigation unknown (-32602)" || bad "A2 the plain reader's door: tools '$t', claim error '$e'"

echo "--- R. roles"
calls r_ag '{"rpc":"tools/list","params":{}}'
mc AG1_DSN r_ag; t=$(lists_tools r_ag)
[[ $t == "$ALL16" ]] && ok "R1 the agent login passes and lists 16 tools" || bad "R1 the agent login's tools: '$t' (exit $(jq -r 'select(.exit != null) | .exit' "$WORK/r_ag.out") $(jq -r 'select(.exit != null) | .stderr' "$WORK/r_ag.out" | tail -1 | cut -c1-200))"
refused() { # refused <tag> <dsn> <words>
  local rc
  PGVIGIL_MCP_DSN="$2" timeout 30 "$BIN" mcp </dev/null >"$WORK/rf-$1.out" 2>"$WORK/rf-$1.err"; rc=$?
  if [[ $rc == 3 && ! -s "$WORK/rf-$1.out" ]] && grep -q 'refused' "$WORK/rf-$1.err" && grep -q -- "$3" "$WORK/rf-$1.err"; then ok "R2 $1 refused at start: $(grep -o "refused.*" "$WORK/rf-$1.err" | head -1 | cut -c1-160)"
  else bad "R2 $1: exit $rc, want 3 with 'refused' and '$3': $(tail -2 "$WORK/rf-$1.err" | tr '\n' ' ' | cut -c1-240)"; fi
}
refused collector "$(dsn_of "$(L cola)")" pgvigil_collector
refused auth "$(dsn_of "$(L autha)")" pgvigil_auth
refused writer "$(dsn_of "$(L wra)")" "may change the repository's tables"
refused superuser "$PGVIGIL_ADMIN_DSN dbname=$REPO" superuser
refused read_all_data "$(dsn_of "$(L rada)")" pg_read_all_data
refused read_server_files "$(dsn_of "$(L rsfa)")" pg_read_server_files
refused alerter "$(dsn_of "$(L alra)")" pgvigil_alerter
refused owner_by_role "$(dsn_of "$(L ownm)") options='-c role=$(L agr)'" pg_database_owner
for who in rd rep ui; do
  out=$(as "$(L $who)" -c "select pgvigil.agent_investigation_list(null::text, null::text, 1)")
  [[ $out == *"permission denied for function agent_investigation_list"* || $out == *"is not a member of pgvigil_agent"* ]] && ok "R3 the $who login may not call the agent's functions" || bad "R3 the $who login calling agent_investigation_list: ${out:0:200}"
done
out=$(as "$(L ag1)" -c "insert into pgvigil.investigations (kind) values ('ask')")
[[ $out == *"permission denied for table investigations"* ]] && ok "R4 the agent login has no INSERT on investigations" || bad "R4 the agent login's INSERT: ${out:0:200}"
if [[ -n "${PGVIGIL_SKIP_STANDBY:-}" ]] || ! command -v docker >/dev/null; then NOTPROVEN+=("R5 the agent role on a standby (PGVIGIL_SKIP_STANDBY or no docker)")
else
  IMG=${PG_IMAGE:-postgres:18}; NET=pgagt-net-$SUF; PRI=pgagt-pri-$SUF; STB=pgagt-stb-$SUF
  docker network create "$NET" >/dev/null && MADE_NET=$NET && MADE_CT+=("$PRI" "$STB")
  docker run -d --name "$PRI" --network "$NET" -e POSTGRES_HOST_AUTH_METHOD=trust "$IMG" -c wal_level=replica >/dev/null
  for _ in $(seq 1 60); do docker exec "$PRI" psql -U postgres -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 1; done
  # the image's own data folder ($PGDATA: /var/lib/postgresql/18/docker on 18, .../data before), read inside the container
  docker exec "$PRI" bash -c 'echo "host replication all all trust" >> "$PGDATA/pg_hba.conf" && psql -U postgres -XAtqc "select pg_reload_conf()" -c "create database sb"' >/dev/null \
    || echo "note: the primary's replication line or its database sb: $(docker exec "$PRI" bash -c 'echo $PGDATA; ls "$PGDATA" | head -3' 2>&1 | tr '\n' ' ')"
  PRIIP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$PRI")
  printf 'repository:\n  dsn: env:SBP_DSN\ninstances: []\n' > "$WORK/cfg-sb.yaml"
  SBP_DSN="host=$PRIIP port=5432 user=postgres dbname=sb sslmode=disable" "$BIN" migrate -config "$WORK/cfg-sb.yaml" >"$WORK/sb-migrate.log" 2>&1 || echo "note: the standby's primary did not migrate: $(tail -2 "$WORK/sb-migrate.log")"
  docker exec "$PRI" psql -U postgres -d sb -XAtqc "create role sbagent login password '$PW' in role pgvigil_reader, pgvigil_agent" >/dev/null 2>&1
  docker run -d --name "$STB" --network "$NET" --entrypoint bash "$IMG" -c "until pg_basebackup -h $PRI -U postgres -D /tmp/sb -R -X stream; do sleep 1; done; chown -R postgres /tmp/sb; chmod 700 /tmp/sb; exec su postgres -c 'postgres -D /tmp/sb -c listen_addresses=*'" >/dev/null
  STBIP=""; for _ in $(seq 1 90); do STBIP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$STB" 2>/dev/null); docker exec "$STB" psql -h 127.0.0.1 -U postgres -d sb -XAtqc 'select pg_is_in_recovery()' 2>/dev/null | grep -q t && break; sleep 1; done
  if docker exec "$STB" psql -h 127.0.0.1 -U postgres -d sb -XAtqc 'select pg_is_in_recovery()' 2>/dev/null | grep -q t; then
    refused standby "host=$STBIP port=5432 dbname=sb user=sbagent password=$PW sslmode=disable" "in recovery"
  else bad "R5 the standby did not come up in recovery: $(docker logs "$STB" 2>&1 | tail -3 | tr '\n' ' ' | cut -c1-200)"; fi
fi

echo "--- Q. the request"
reset_inv
c=$(code -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{"kind":"ask","question":"x"}' "$S1/api/investigations")
c2=$(code -b "$WORK/jar-s1-$U1" -H 'Content-Type: application/json' -d '{"kind":"ask","question":"x"}' "$S1/api/investigations")
[[ $c == 401 && $c2 == 403 ]] && ok "Q1 POST without a session 401, without X-Pgvigil 403" || bad "Q1 no session $c, no header $c2"
c=$(api "$S1" s1 "$U1" POST investigations "$(jq -cn --argjson i "$FIID" --arg s "$FSET" '{kind:"finding",instance_id:$i,setting:$s,note:"Q note",snapshot:{forged:true}}')"); Q1=$(B '.id // empty')
row=$(q "select kind||'|'||state||'|'||asked_by from pgvigil.investigations where id = ${Q1:-0}")
jr=$(q "select string_agg(event, ',' order by id) from pgvigil.investigation_journal where investigation_id = ${Q1:-0}")
sn=$(q "select (d.snapshot->>'setting') || '|' || (d.snapshot ? 'forged')::text || '|' || d.note from pgvigil.ui_investigation_data d where d.investigation_id = ${Q1:-0}")
[[ $c == 200 && $row == "finding|open|$U1" && $jr == asked && $sn == "$FSET|false|Q note" ]] && ok "Q2 a request: 200, row '$row', journal '$jr', the snapshot serve's read of $FSET (no forged key)" || bad "Q2 the request: http $c id '${Q1:-}' row '$row' journal '$jr' snapshot '$sn' ($(head -c 200 "$WORK/body"))"
for n in $(seq 2 10); do ask_q "q$n" >/dev/null; done
c=$(api "$S1" s1 "$U1" POST investigations '{"kind":"ask","question":"the eleventh"}')
[[ $c == 409 && $(cat "$WORK/body") == *"already has 10 open"* ]] && ok "Q3 the 11th open request of a user: 409 'already has 10 open'" || bad "Q3 the 11th: $c $(head -c 200 "$WORK/body")"
reset_inv
for n in $(seq 1 25); do u=$U1; ((n > 9)) && u=$U2; ((n > 17)) && u=$U3
  curl -s --max-time 60 -o "$WORK/cc-$n" -w '%{http_code}\n' -b "$WORK/jar-s1-$u" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"kind\":\"ask\",\"question\":\"c$n\"}" "$S1/api/investigations" > "$WORK/cc-$n.code" &
done; wait
n200=$(cat "$WORK"/cc-*.code | grep -c '^200$'); n409=$(cat "$WORK"/cc-*.code | grep -c '^409$'); w=$(grep -l '20 investigations in the last hour' "$WORK"/cc-[0-9]* 2>/dev/null | wc -l)
[[ $n200 == 20 && $n409 == 5 && $w == 5 ]] && ok "Q4 25 requests at once from three users: 20 accepted, 5 refused '20 investigations in the last hour'" || bad "Q4 25 at once: $n200 accepted, $n409 refused, $w with the words"
NOTPROVEN+=("Q5 / K7 queue mode: CQ's request queue (pgvigil_requester, customReportsOff in queue mode) is not in this tree; its lines are WIRING at the join")

echo "--- C. claim"
reset_inv
C1=$(ask_finding "C note")
rm -f "$WORK/go" "$WORK/ra" "$WORK/rb"
calls c_a '{"touch":"'"$WORK"'/ra"}' '{"barrier":"'"$WORK"'/go"}' "$(tc claim_investigation "{\"id\":${C1:-0},\"agent\":\"agent-a\"}")"
calls c_b '{"touch":"'"$WORK"'/rb"}' '{"barrier":"'"$WORK"'/go"}' "$(tc claim_investigation "{\"id\":${C1:-0},\"agent\":\"agent-b\"}")"
mc AG1_DSN c_a & pa=$!; mc AG2_DSN c_b & pb=$!
for _ in $(seq 1 300); do [[ -f "$WORK/ra" && -f "$WORK/rb" ]] && break; sleep 0.1; done; touch "$WORK/go"; wait $pa $pb
ea=$(Rr c_a 2 '.isError'); eb=$(Rr c_b 2 '.isError')
if [[ $ea == false && $eb == true ]]; then W=ag1; WV=AG1_DSN; O=ag2; OV=AG2_DSN; CID=$(Rr c_a 2 '.body.claim_id'); LOSER=$(Rr c_b 2 '.body')
elif [[ $ea == true && $eb == false ]]; then W=ag2; WV=AG2_DSN; O=ag1; OV=AG1_DSN; CID=$(Rr c_b 2 '.body.claim_id'); LOSER=$(Rr c_a 2 '.body')
else W=""; CID=""; LOSER=""; fi
[[ -n $W && -n $CID && $LOSER == *"claimed by"* ]] && ok "C1 two agents at once: one claim ($W), the other refused '${LOSER:0:80}'" || bad "C1 the race: a isError '$ea', b isError '$eb' ($(R c_a 2 '.body' | cut -c1-120) | $(R c_b 2 '.body' | cut -c1-120))"
W=${W:-ag1}; WV=${WV:-AG1_DSN}; O=${O:-ag2}; OV=${OV:-AG2_DSN}
l0=$(q "select extract(epoch from lease_until) from pgvigil.investigations where id = ${C1:-0}")
calls c_r "$(tc renew_investigation "{\"id\":${C1:-0},\"claim_id\":\"$CID\"}")"; sleep 1; mc "$WV" c_r
l1=$(q "select extract(epoch from lease_until) from pgvigil.investigations where id = ${C1:-0}")
[[ $(Rr c_r 0 '.isError') == false ]] && python3 -c "import sys; sys.exit(0 if float('${l1:-0}') > float('${l0:-0}') else 1)" 2>/dev/null && ok "C2 renew moves lease_until" || bad "C2 renew: $(R c_r 0 '.body' | cut -c1-200) ($l0 -> $l1)"
lapse() { q "update pgvigil.investigations set lease_until = now() - interval '1 second' where id = $1" >/dev/null; }
lapse "${C1:-0}"
calls c_o "$(tc list_investigations '{"state":"open","limit":100}')" "$(tc claim_investigation "{\"id\":${C1:-0},\"agent\":\"agent-o\"}")"
mc "$OV" c_o; CID2=$(Rr c_o 1 '.body.claim_id')
inl=$(Rr c_o 0 "[.body.investigations[]? | select(.id == ${C1:-0})] | length")
[[ $inl == 1 && $(Rr c_o 1 '.isError') == false && $(q "select claims from pgvigil.investigations where id = ${C1:-0}") == 2 ]] && ok "C3 a lapsed lease reads open and the other login claims it (claims 2)" || bad "C3 lapsed: listed $inl, claim $(R c_o 1 '.body' | cut -c1-160), claims $(q "select claims from pgvigil.investigations where id = ${C1:-0}")"
calls c_w "$(tc renew_investigation "{\"id\":${C1:-0},\"claim_id\":\"$CID\"}")" "$(tc report_investigation "{\"id\":${C1:-0},\"claim_id\":\"$CID\",\"verdict\":\"real\",\"summary\":\"s\",\"body\":\"b\"}")" "$(tc renew_investigation "{\"id\":${C1:-0},\"claim_id\":\"$CID2\"}")"
mc "$WV" c_w
[[ $(Rr c_w 0 '.body') == *"not your claim"* && $(Rr c_w 1 '.body') == *"not your claim"* ]] && ok "C4 the first claimer's renew and report after the retake: 'not your claim'" || bad "C4 the stale claimer: $(R c_w 0 '.body' | cut -c1-120) | $(R c_w 1 '.body' | cut -c1-120)"
[[ $(Rr c_w 2 '.isError') == true && $(Rr c_w 2 '.body') == *"not your claim"* ]] && ok "C5 a login holding another login's claim id: 'not your claim'" || bad "C5 another login's claim id: $(R c_w 2 '.body' | cut -c1-160)"
lapse "${C1:-0}"
calls c_t "$(tc claim_investigation "{\"id\":${C1:-0},\"agent\":\"agent-t\"}")"; mc "$WV" c_t; lapse "${C1:-0}"
st=$(q "select state from pgvigil.investigations_now where id = ${C1:-0}")
calls c_x "$(tc claim_investigation "{\"id\":${C1:-0},\"agent\":\"agent-x\"}")"; mc "$OV" c_x
[[ $st == expired && $(Rr c_x 0 '.body') == *"expired"* ]] && ok "C6 the third lapse reads expired; a claim is refused 'expired'" || bad "C6 the third lapse: state '$st', claim $(R c_x 0 '.body' | cut -c1-160)"
C2=$(ask_q "renew past expiry")
calls c_e "$(tc claim_investigation "{\"id\":${C2:-0},\"agent\":\"agent-e\"}")" '{"touch":"'"$WORK"'/e1"}' '{"sleep":2}' "$(tc renew_investigation "{\"id\":${C2:-0},\"claim_id\":\"\$claim\"}")"
mc AG1_DSN c_e & pe=$!
for _ in $(seq 1 100); do [[ -f "$WORK/e1" ]] && break; sleep 0.1; done
q "update pgvigil.investigations set expires_at = now() - interval '1 second' where id = ${C2:-0}" >/dev/null; wait $pe
[[ $(Rr c_e 3 '.isError') == true && $(Rr c_e 3 '.body') == *"expired"* ]] && ok "C7 a renew past expires_at: 'expired'" || bad "C7 renew past expiry: $(R c_e 3 '.body' | cut -c1-160)"
C3=$(ask_q "release me")
calls c_rl "$(tc claim_investigation "{\"id\":${C3:-0},\"agent\":\"agent-r\"}")" "$(tc release_investigation "{\"id\":${C3:-0},\"claim_id\":\"\$claim\",\"reason\":\"not mine $SUF\"}")"
mc AG1_DSN c_rl
st=$(q "select state from pgvigil.investigations where id = ${C3:-0}"); ev=$(q "select count(*) from pgvigil.investigation_journal where investigation_id = ${C3:-0} and event = 'released'")
inj=$(q "select count(*) from pgvigil.investigation_journal j where j.investigation_id = ${C3:-0} and row_to_json(j)::text like '%not mine $SUF%'")
txt=$(q "select count(*) from pgvigil.ui_investigation_journal_text t join pgvigil.investigation_journal j on j.id = t.journal_id where j.investigation_id = ${C3:-0} and t.text = 'not mine $SUF'")
[[ $st == open && $ev == 1 && $inj == 0 && $txt == 1 ]] && ok "C8 release: open, journal 'released', its reason only in the ui_ text table" || bad "C8 release: state '$st', released $ev, reason in the journal $inj, in the text table $txt ($(R c_rl 1 '.body' | cut -c1-120))"
reset_inv; rm -f "$WORK/w1"
calls c_wt '{"touch":"'"$WORK"'/w1"}' "$(tc wait_for_investigations '{"known":[],"timeout_s":20}')"
mc AG1_DSN c_wt & pw=$!
for _ in $(seq 1 100); do [[ -f "$WORK/w1" ]] && break; sleep 0.1; done; sleep 1; C4=$(ask_q "wake me"); wait $pw
ms=$(Rr c_wt 1 '.ms'); got=$(Rr c_wt 1 "[.body.open[]? | select(.id == ${C4:-0})] | length")
[[ $got == 1 && ${ms:-99999} -le 3500 ]] && ok "C9 wait answered the new request in ${ms} ms (asked 1 s after it started)" || bad "C9 wait: the request seen '$got' in '${ms}' ms ($(R c_wt 1 '.body' | cut -c1-160))"
reset_inv; rm -f "$WORK/w2"
calls c_oo '{"touch":"'"$WORK"'/w2"}' "$(tc wait_for_investigations '{"known":[],"timeout_s":20}')" "$(tc wait_for_investigations '{"known":"$open","timeout_s":20}')"
mc AG1_DSN c_oo & po=$!
for _ in $(seq 1 100); do [[ -f "$WORK/w2" ]] && break; sleep 0.1; done
psql "$PGVIGIL_REPO_DSN" -XAtq -c "begin" -c "select pgvigil.import_investigation_request(now(), '{\"ui_user\":\"$U1\",\"client\":\"psql\",\"kind\":\"ask\",\"question\":\"first insert, last commit\"}'::jsonb)" -c "select pg_sleep(4)" -c "commit" >"$WORK/oo1" 2>&1 &
pp=$!; sleep 1; C6=$(ask_q "second insert, first commit"); wait $pp $po
C5=$(q "select id from pgvigil.investigations where kind = 'ask' and asked_by = '$U1' order by id limit 1")
seen=$(jq -r 'select(.i == 1 or .i == 2) | .body.open[]?.id' "$WORK/c_oo.out" 2>/dev/null | sort -u | paste -sd,)
[[ -n "$C5" && -n "$C6" && ",$seen," == *",$C5,"* && ",$seen," == *",$C6,"* && $C5 -lt $C6 ]] && ok "C10 two requests committed out of order ($C5 committed after $C6) both reach the waiting agent" || bad "C10 out of order: ids $C5 / $C6, seen '$seen' ($(head -c 200 "$WORK/oo1"))"
reset_inv; rm -f "$WORK/w3"
calls c_ld '{"touch":"'"$WORK"'/w3"}' '{"sleep":3}' "$(tc wait_for_investigations '{"known":[],"timeout_s":20}')"
mc AG1_DSN c_ld & pl=$!
for _ in $(seq 1 100); do [[ -f "$WORK/w3" ]] && break; sleep 0.1; done
killed=$(q "select count(pg_terminate_backend(pid)) from pg_stat_activity where usename = '$(L ag1)' and application_name = 'pgvigil-mcp-agent'")
sleep 4; C7=$(ask_q "after the listener died"); wait $pl
ms=$(Rr c_ld 2 '.ms'); got=$(Rr c_ld 2 "[.body.open[]? | select(.id == ${C7:-0})] | length")
[[ $killed -ge 1 && $got == 1 && ${ms:-99999} -le 8000 ]] && ok "C11 with the listening session terminated ($killed), wait still answered in ${ms} ms" || bad "C11 the listener dropped: terminated '$killed', seen '$got' in '${ms}' ms ($(R c_ld 2 '.body' | cut -c1-160))"

echo "--- B. the brief"
reset_inv
B1=$(ask_finding "B note $SUF")
calls b_1 "$(tc claim_investigation "{\"id\":${B1:-0},\"agent\":\"agent-b\"}")" "$(tc report_investigation "{\"id\":${B1:-0},\"claim_id\":\"\$claim\",\"verdict\":\"real\",\"summary\":\"first look $SUF\",\"body\":\"b\"}")"
mc AG1_DSN b_1
br=$(R b_1 0 '.body.brief')
chk=$(jq -r --arg s "$FSET" --arg n "B note $SUF" --arg i "$FINST" '[(.request.snapshot.setting == $s), (.request.note == $n), (.next_calls[0].tool == "instance_findings"), (.next_calls[0].args.instance == $i), (.budget.minutes == 30), (.budget.tool_calls == 40)] | map(tostring) | join(",")' <<<"${br:-null}" 2>/dev/null)
blen=$(printf '%s' "${br:-}" | wc -c)
[[ $chk == "true,true,true,true,true,true" && $blen -gt 2 && $blen -lt 24000 ]] && ok "B1 the brief: the snapshot's setting, the note, next_calls instance_findings($FINST), budget 30 min / 40 calls, $blen characters" || bad "B1 the brief: checks '$chk', $blen characters: ${br:0:240}"
B2=$(ask_finding "again")
calls b_2 "$(tc claim_investigation "{\"id\":${B2:-0},\"agent\":\"agent-b\"}")"; mc AG1_DSN b_2
er=$(Rr b_2 0 '.body.brief.earlier_reports[0] | "\(.id)|\(.unreviewed)"')
[[ $er == "${B1:-x}|true" ]] && ok "B2 a second request of the same finding: earlier_reports[0] = $B1, unreviewed" || bad "B2 earlier reports: '$er' (want ${B1:-?}|true)"

echo "--- S. run_select / J. the record"
reset_inv
S1R=$(ask_q "selects")
sel() { tc run_select "$(jq -cn --argjson i "${S1R:-0}" --arg s "$1" '{id:$i,claim_id:"$claim",sql:$s}')"; }
calls s_1 "$(tc claim_investigation "{\"id\":${S1R:-0},\"agent\":\"agent-s\"}")" \
  "$(sel "SELECT count(*) AS n FROM pgvigil.instances")" \
  "$(sel "SELECT 1; SELECT 2")" \
  "$(sel "INSERT INTO pgvigil.instances (name) VALUES ('x')")" \
  "$(sel "WITH d AS (DELETE FROM pgvigil.query_text RETURNING 1) SELECT * FROM d")" \
  "$(sel "SELECT pgvigil.ensure_instance('agt-zz', 'onprem', null, null, false, '{}')")" \
  "$(sel "SELECT * FROM pgvigil.ui_users")" \
  "$(sel "SELECT pgvigil.ui_password_hash('x')")" \
  "$(sel "SELECT set_config('role', 'none', true) AS r, (SELECT count(*) FROM pgvigil.ui_users) AS n")" \
  "$(sel "SELECT pg_sleep(20)")" \
  "$(sel "SELECT g FROM generate_series(1, 5000) g")" \
  "$(sel "SELECT pg_advisory_lock(4242) IS NOT NULL AS got")" \
  "$(tc run_select "{\"id\":${S1R:-0},\"claim_id\":\"bogus\",\"sql\":\"SELECT 1\"}")"
mc AG1_DSN s_1
n=$(Rr s_1 1 '.body.rows[0][0]')
[[ $(Rr s_1 1 '.isError') == false && $n == "$NINST" ]] && ok "S1 a SELECT answers its rows (instances: $n)" || bad "S1 the SELECT: $(R s_1 1 '.body' | cut -c1-200) (want $NINST)"
for pair in "2:syntax error|multiple commands" "3:syntax error" "4:syntax error|data-modifying|read-only|permission denied" "5:permission denied|read-only transaction" "6:permission denied for table ui_users" "7:permission denied for function ui_password_hash" "8:permission denied"; do
  i=${pair%%:*}; w=${pair#*:}; e=$(Rr s_1 "$i" '.isError'); b=$(Rr s_1 "$i" '.body')
  [[ $e == true ]] && grep -q -E "$w" <<<"$b" && ok "S2.$i refused: $(jq -r '.call.args.sql' <<<"$(R s_1 "$i" '.')" | cut -c1-60) -> ${b:0:90}" || bad "S2.$i want refused /$w/: isError '$e' ${b:0:200}"
done
ms=$(Rr s_1 9 '.ms'); b=$(Rr s_1 9 '.body')
[[ $(Rr s_1 9 '.isError') == true && $b == *"statement timeout"* && ${ms:-99999} -lt 19000 ]] && ok "S3 pg_sleep(20) cut by the statement timeout in $ms ms" || bad "S3 pg_sleep(20): ${b:0:160} in $ms ms"
[[ $(Rr s_1 10 '.body.row_count') == 1000 && $(Rr s_1 10 '.body.cut') == true ]] && ok "S4 5,000 rows answer 1,000, cut true" || bad "S4 5,000 rows: $(R s_1 10 '.body | {row_count, cut}')"
held=$(q "select count(*) from pg_locks where locktype = 'advisory' and objid = 4242")
[[ $(Rr s_1 11 '.isError') == false && $held == 0 ]] && ok "S5 an advisory lock taken in one call is not held after it" || bad "S5 the advisory lock: $(R s_1 11 '.body' | cut -c1-120), held now $held"
[[ $(Rr s_1 12 '.isError') == true && $(Rr s_1 12 '.body') == *"not your claim"* ]] && ok "S6 a bogus claim id: 'not your claim'" || bad "S6 a bogus claim id: $(R s_1 12 '.body' | cut -c1-160)"
S2R=$(ask_q "simple protocol")
calls s_2 "$(tc claim_investigation "{\"id\":${S2R:-0},\"agent\":\"agent-s2\"}")" "$(tc run_select "$(jq -cn --argjson i "${S2R:-0}" '{id:$i,claim_id:"$claim",sql:"SELECT 1) AS q; COMMIT; SET statement_timeout = 0; SELECT pg_sleep(60); SELECT * FROM (SELECT 1"}')")"
mc AG1S_DSN s_2
slept=$(q "select count(*) from pg_stat_activity where usename = '$(L ag1)' and query like '%pg_sleep(60)%' and pid <> pg_backend_pid()")
ms=$(Rr s_2 1 '.ms')
[[ $(Rr s_2 1 '.isError') == true && ${ms:-99999} -lt 10000 && $slept == 0 ]] && ok "S7 the multi-statement text on a simple_protocol DSN refused in $ms ms, its pg_sleep never ran" || bad "S7 simple_protocol: $(R s_2 1 '.body' | cut -c1-160) in $ms ms, sleeping $slept ($(jq -r 'select(.exit != null) | .stderr' "$WORK/s_2.out" | tail -1 | cut -c1-120))"
# J: every run_select of s_1 with a valid claim (11; the bogus claim id is refused before the record) is one select row
nsel=$(q "select count(*) from pgvigil.investigation_journal where investigation_id = ${S1R:-0} and event = 'select'")
nms=$(q "select count(*) from pgvigil.investigation_journal where investigation_id = ${S1R:-0} and event = 'select' and ms is not null and outcome is not null")
ntx=$(q "select count(*) from pgvigil.ui_investigation_journal_text t join pgvigil.investigation_journal j on j.id = t.journal_id where j.investigation_id = ${S1R:-0} and j.event = 'select'")
nref=$(q "select count(*) from pgvigil.investigation_journal where investigation_id = ${S1R:-0} and event = 'select' and outcome like 'refused%'")
[[ $nsel == 11 && $nms == 11 && $ntx == 11 && $nref -ge 8 ]] && ok "J1 the record: 11 select rows (rows, ms, outcome; $nref refused), 11 texts in the ui_ table" || bad "J1 the record: $nsel select rows, $nms with ms and outcome, $ntx texts, $nref refused (want 11, 11, 11, >= 8)"
a=$(as "$(L rd)" -c "select count(*) from pgvigil.investigation_journal"); b=$(as "$(L rd)" -c "select count(*) from pgvigil.ui_investigation_journal_text")
[[ $a =~ ^[0-9]+$ && $b == *"permission denied"* ]] && ok "J2 the plain reader reads the journal ($a rows), not its texts" || bad "J2 the plain reader: journal '${a:0:80}', texts '${b:0:120}'"
api "$S1" s1 "$U2" GET "investigations?id=${S1R:-0}" >/dev/null
[[ $(B '[.journal[]? | select(.event == "select") | .text] | map(select(. != null)) | length') == 11 && $(B '[.journal[]? | .text] | any(. == "SELECT count(*) AS n FROM pgvigil.instances")') == true ]] && ok "J3 serve shows a signed-in user each statement's text" || bad "J3 serve's journal: $(head -c 240 "$WORK/body")"
# filled to 199: the claim writes row 200, the run's would be the 201st
q "insert into pgvigil.investigation_journal (investigation_id, at, event, login, outcome) select ${S1R:-0}, now(), 'select', 'proof', 'filler' from generate_series(1, greatest(0, 199 - (select count(*) from pgvigil.investigation_journal where investigation_id = ${S1R:-0})))" >/dev/null
calls s_3 "$(tc claim_investigation "{\"id\":${S1R:-0},\"agent\":\"agent-s\"}")" "$(sel "SELECT 1")"
q "update pgvigil.investigations set lease_until = now() - interval '1 second' where id = ${S1R:-0}" >/dev/null
mc AG1_DSN s_3
[[ $(Rr s_3 1 '.isError') == true && $(Rr s_3 1 '.body') == *"the request's record is full"* ]] && ok "S8 a request whose record holds 200 rows refuses the next run" || bad "S8 the full record: $(R s_3 1 '.body' | cut -c1-200) (claim: $(R s_3 0 '.body' | cut -c1-100))"

echo "--- P. the report"
reset_inv
P1=$(ask_finding "P")
long=$(head -c 4001 /dev/zero | tr '\0' 'x')
ev51=$(jq -cn '[range(51) | {tool:"instance_findings",arguments:{},key_numbers:"n",basis:"verified"}]')
calls p_1 "$(tc claim_investigation "{\"id\":${P1:-0},\"agent\":\"agent-p\"}")" \
  "$(tc report_investigation "$(jq -cn --argjson i "${P1:-0}" --arg s "$long" '{id:$i,claim_id:"$claim",verdict:"real",summary:$s,body:"b"}')")" \
  "$(tc report_investigation "$(jq -cn --argjson i "${P1:-0}" --argjson e "$ev51" '{id:$i,claim_id:"$claim",verdict:"real",summary:"s",body:"b",evidence:$e}')")" \
  "$(tc report_investigation "$(jq -cn --argjson i "${P1:-0}" --arg s "P summary $SUF" '{id:$i,claim_id:"$claim",verdict:"real",summary:$s,body:"the body",evidence:[{tool:"instance_findings",arguments:{},key_numbers:"1 finding",basis:"verified"}],queries_run:["SELECT 1"]}')")"
mc AG1_DSN p_1
[[ $(Rr p_1 1 '.isError') == true && $(Rr p_1 1 '.body') == *"summary"* && $(Rr p_1 2 '.isError') == true && $(Rr p_1 2 '.body') == *"evidence"* ]] && ok "P1 a 4,001-character summary and 51 evidence entries refused with words" || bad "P1 the limits: $(R p_1 1 '.body' | cut -c1-120) | $(R p_1 2 '.body' | cut -c1-120)"
st=$(q "select state from pgvigil.investigations where id = ${P1:-0}")
[[ $(Rr p_1 3 '.isError') == false && $st == reported ]] && ok "P2 a report accepted: reported" || bad "P2 the report: $(R p_1 3 '.body' | cut -c1-160), state '$st'"
api "$S1" s1 "$U2" GET "investigations?id=${P1:-0}" >/dev/null; s=$(B '.report.summary')
api "$S1" s1 "$U2" GET investigations >/dev/null; v=$(B "[.rows[]? | select(.id == ${P1:-0}) | .verdict] | first")
[[ $s == "P summary $SUF" && $v == real ]] && ok "P3 another signed-in user sees the summary and the verdict on the grid" || bad "P3 another user: summary '$s', verdict '$v'"
a=$(as "$(L rd)" -c "select verdict from pgvigil.investigations where id = ${P1:-0}"); b=$(as "$(L rd)" -c "select count(*) from pgvigil.ui_investigation_data")
[[ $a == real && $b == *"permission denied"* ]] && ok "P4 the plain reader reads the verdict, not the texts" || bad "P4 the plain reader: verdict '${a:0:80}', texts '${b:0:120}'"
c=$(api "$S1" s1 "$U1" POST investigations/close "{\"id\":${P1:-0},\"reason\":\"done $SUF\"}")
r=$(q "select state || '|' || closed_by from pgvigil.investigations where id = ${P1:-0}"); j=$(q "select count(*) from pgvigil.investigation_journal where investigation_id = ${P1:-0} and event = 'closed'")
[[ $c == 200 && $r == "closed|$U1" && $j == 1 ]] && ok "P5 close with a reason: closed by $U1, journal 'closed'" || bad "P5 close: http $c, '$r', journal $j ($(head -c 160 "$WORK/body"))"

echo "--- K. the ask"
reset_inv
K1=$(ask_q "how many instances? $SUF")
calls k_1 "$(tc claim_investigation "{\"id\":${K1:-0},\"agent\":\"agent-k\"}")" \
  "$(tc report_investigation "$(jq -cn --argjson i "${K1:-0}" '{id:$i,claim_id:"$claim",verdict:"answered",summary:"two",body:"b",sql:"SELECT 1; SELECT 2"}')")" \
  "$(tc report_investigation "$(jq -cn --argjson i "${K1:-0}" '{id:$i,claim_id:"$claim",verdict:"answered",summary:"the count",body:"b",sql:"SELECT count(*) AS n FROM pgvigil.instances"}')")"
mc AG1_DSN k_1
[[ $(Rr k_1 0 '.body.brief.request.question') == "how many instances? $SUF" ]] && ok "K1 the ask's brief carries the question" || bad "K1 the ask's brief: $(R k_1 0 '.body.brief.request' | cut -c1-160)"
[[ $(Rr k_1 1 '.isError') == true && $(Rr k_1 1 '.body') == *"one SELECT"* && $(Rr k_1 2 '.isError') == false ]] && ok "K2 a report sql of two statements refused 'one SELECT'; one SELECT accepted" || bad "K2 the report's sql: $(R k_1 1 '.body' | cut -c1-120) | $(R k_1 2 '.body' | cut -c1-120)"
c=$(api "$S1" s1 "$U2" POST investigations/run "{\"id\":${K1:-0},\"sql\":\"SELECT 1 AS forged\"}")
col=$(B '.columns[0]'); v=$(B '.rows[0][0]'); jr=$(q "select count(*) from pgvigil.investigation_journal where investigation_id = ${K1:-0} and event = 'run' and login = '$U2'")
[[ $c == 200 && $col == n && $v == "$NINST" && $jr == 1 ]] && ok "K3 Run runs the stored SQL as reports_dsn: n = $v, a journal 'run' row of $U2" || bad "K3 Run: http $c column '$col' value '$v' (want n = $NINST), run rows of $U2: $jr ($(head -c 200 "$WORK/body"))"
c=$(api "$S3" s3 "$U1" POST investigations/run "{\"id\":${K1:-0}}")
[[ $(cat "$WORK/body") == *"a report on the store runs only as a login IN ROLE pgvigil_reader alone"* && $(B '.rows // [] | length') == 0 ]] && ok "K4 a serve without reports_dsn: Run refused with the store words" || bad "K4 no reports_dsn: http $c $(head -c 200 "$WORK/body")"
K2=$(ask_q "the hashes")
calls k_2 "$(tc claim_investigation "{\"id\":${K2:-0},\"agent\":\"agent-k\"}")" "$(tc report_investigation "$(jq -cn --argjson i "${K2:-0}" '{id:$i,claim_id:"$claim",verdict:"answered",summary:"h",body:"b",sql:"SELECT pgvigil.ui_password_hash('"'"'x'"'"') AS h"}')")"
mc AG1_DSN k_2
c=$(api "$S1" s1 "$U1" POST investigations/run "{\"id\":${K2:-0}}")
[[ $(cat "$WORK/body") == *"permission denied for function ui_password_hash"* && $(B '.rows // [] | length') == 0 ]] && ok "K5 an ask calling ui_password_hash: Run refused by the reports login" || bad "K5 ui_password_hash through Run: http $c $(head -c 200 "$WORK/body")"
q "insert into pgvigil.investigation_journal (investigation_id, at, event, login, outcome) select ${K1:-0}, now(), 'select', 'proof', 'filler' from generate_series(1, greatest(0, 200 - (select count(*) from pgvigil.investigation_journal where investigation_id = ${K1:-0})))" >/dev/null
c=$(api "$S1" s1 "$U1" POST investigations/run "{\"id\":${K1:-0}}")
[[ $(cat "$WORK/body") == *"the request's record is full"* && $(B '.rows // [] | length') == 0 ]] && ok "K6 the record full: Run refused, no rows (the audit before the rows)" || bad "K6 Run on a full record: http $c $(head -c 200 "$WORK/body")"

echo "--- E. expiry"
reset_inv
E1=$(ask_q "old"); q "update pgvigil.investigations set expires_at = now() - interval '1 second' where id = ${E1:-0}" >/dev/null
api "$S1" s1 "$U1" GET investigations >/dev/null; st=$(B "[.rows[]? | select(.id == ${E1:-0}) | .state] | first")
calls e_1 "$(tc list_investigations '{"state":"open","limit":100}')"; mc AG1_DSN e_1
inl=$(Rr e_1 0 "[.body.investigations[]? | select(.id == ${E1:-0})] | length"); stored=$(q "select state from pgvigil.investigations where id = ${E1:-0}")
[[ $st == expired && $inl == 0 && $stored == expired ]] && ok "E1 past expires_at: serve's list says expired at once, the agent's open list leaves it out and writes it" || bad "E1 expiry: serve '$st', in the agent's open list $inl, stored '$stored'"
E2=$(ask_q "dead claim")
calls e_2 "$(tc claim_investigation "{\"id\":${E2:-0},\"agent\":\"agent-e\"}")"; mc AG1_DSN e_2; lapse "${E2:-0}"
api "$S1" s1 "$U1" GET investigations >/dev/null; st=$(B "[.rows[]? | select(.id == ${E2:-0}) | .state] | first")
[[ $st == open ]] && ok "E2 a lapsed claim reads open on serve's list with no agent running" || bad "E2 a dead claim on serve's list: '$st'"
reset_inv
for n in $(seq 1 10); do ask_q "e$n" >/dev/null; done
q "update pgvigil.investigations set expires_at = now() - interval '1 second'" >/dev/null
c=$(api "$S1" s1 "$U1" POST investigations '{"kind":"ask","question":"after ten dead"}')
[[ $c == 200 ]] && ok "E3 ten requests past expires_at do not count against the 10-open cap" || bad "E3 the cap with ten dead: $c $(head -c 160 "$WORK/body")"
reset_inv
E4=$(ask_q "closed long ago"); api "$S1" s1 "$U1" POST investigations/close "{\"id\":${E4:-0},\"reason\":\"old\"}" >/dev/null
E5=$(ask_q "open long ago")
q "update pgvigil.investigations set asked_at = now() - interval '100 days' where id in (${E4:-0}, ${E5:-0})" >/dev/null
q "update pgvigil.investigations set expires_at = now() + interval '1 hour' where id = ${E5:-0}" >/dev/null
q "select pgvigil.investigations_purge()" >/dev/null
left=$(q "select string_agg(id::text, ',' order by id) from pgvigil.investigations where id in (${E4:-0}, ${E5:-0})")
[[ $left == "${E5:-x}" ]] && ok "E4 purge: the closed request of 100 days ago gone, the open one kept" || bad "E4 purge: left '$left' (want ${E5:-?})"

echo "--- M. masks"
reset_inv
LIT="LIT$SUF"; P1="k3yP$SUF"
psql "$TGT_DSN" -XAtq -c "select pg_sleep(25), pgp_sym_encrypt('d', '$P1') as e, '$LIT' as l" >/dev/null 2>&1 &
pm=$!; sleep 2
for i in full norm none; do "$BIN" collect -config "$CFG" -once activity -instance "agt-m-$i-$SUF" >"$WORK/collect-$i.log" 2>&1 || echo "note: collect -once activity agt-m-$i: $(tail -2 "$WORK/collect-$i.log")"; done
M1=$(ask_q "masks")
calls m_1 "$(tc claim_investigation "{\"id\":${M1:-0},\"agent\":\"agent-m\"}")" \
  "$(tc run_select "$(jq -cn --argjson i "${M1:-0}" --arg s "agt-m-%-$SUF" '{id:$i,claim_id:"$claim",sql:("SELECT i.name, coalesce(q.query, '"'"'(none)'"'"') AS query FROM pgvigil.activity_sample a JOIN pgvigil.instances i USING (instance_id) LEFT JOIN pgvigil.query_text q USING (query_hash) WHERE i.name LIKE '"'"'" + $s + "'"'"' AND (q.query IS NULL OR q.query LIKE '"'"'%pg_sleep(%'"'"') AND a.pid <> 0")}')")"
mc AG1_DSN m_1; kill $pm 2>/dev/null
jq -r 'select(.i == 1) | .body.rows[]? | @tsv' "$WORK/m_1.out" > "$WORK/m_rows" 2>/dev/null
full=$(grep -F "agt-m-full-$SUF" "$WORK/m_rows" | grep 'pg_sleep(' | head -1); norm=$(grep -F "agt-m-norm-$SUF" "$WORK/m_rows" | grep 'pg_sleep(' | head -1)
none=$(grep -F "agt-m-none-$SUF" "$WORK/m_rows" | grep -c 'pg_sleep('); nonerows=$(grep -c -F "agt-m-none-$SUF" "$WORK/m_rows")
[[ $full == *"$LIT"* && $full == *"<masked>"* && $full != *"$P1"* ]] && ok "M1 full: the text with its literal and '<masked>', no key" || bad "M1 full: '${full:0:200}'"
[[ -n $norm && $norm != *"$LIT"* && $norm != *"$P1"* ]] && ok "M2 normalized: no literal, no key" || bad "M2 normalized: '${norm:0:200}'"
[[ $nonerows -ge 1 && $none == 0 ]] && ok "M3 none: $nonerows sampled row(s), no text" || bad "M3 none: $nonerows sampled row(s), $none with the text"
if grep -l -F "$P1" "$WORK"/*.out >/dev/null 2>&1; then bad "M4 the key reached an agent client's output: $(grep -l -F "$P1" "$WORK"/*.out | head -3 | tr '\n' ' ')"; else ok "M4 no agent client's output holds the key"; fi
if [[ -n "${PGVIGIL_SKIP_MSSQL:-}" ]] || ! command -v docker >/dev/null; then NOTPROVEN+=("M5 the SQL Server line under query_text full (PGVIGIL_SKIP_MSSQL or no docker)")
else
  S1K="S3cret$SUF"; SQLC=pgagt-sql-$SUF; MADE_CT+=("$SQLC"); SAPW="Pm9$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; MONPW="Pm9$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  export SQLCMDPASSWORD="$SAPW"
  printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nMSSQL_MEMORY_LIMIT_MB=2048\n' "$SAPW" > "$WORK/sa.env"
  docker run -d --name "$SQLC" --memory 3g --env-file "$WORK/sa.env" -p 127.0.0.1::1433 "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || die "docker run SQL Server"
  SQLPORT=$(docker port "$SQLC" 1433 | head -1 | sed 's/.*://'); SQLCMD=/opt/mssql-tools18/bin/sqlcmd
  sq() { docker exec -e SQLCMDPASSWORD "$SQLC" $SQLCMD -S localhost -U sa -C -b -W -h -1 -Q "SET NOCOUNT ON; $1"; }
  for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
  printf "CREATE LOGIN pgagt_mon WITH PASSWORD = '%s', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO pgagt_mon; GRANT VIEW ANY DEFINITION TO pgagt_mon;" "$MONPW" \
    | docker exec -i -e SQLCMDPASSWORD "$SQLC" $SQLCMD -S localhost -U sa -C -b -i /dev/stdin >/dev/null || die "the SQL Server login"
  export MS_DSN="sqlserver://pgagt_mon:$MONPW@127.0.0.1:$SQLPORT?database=master&encrypt=true&TrustServerCertificate=true"
  cp "$CFG" "$WORK/cfg-ms.yaml"; printf '  - name: agt-sql-full-%s\n    engine: sqlserver\n    dsn: env:MS_DSN\n' "$SUF" >> "$WORK/cfg-ms.yaml"
  sq "CREATE DATABASE pgagtm;" >/dev/null
  docker exec -e SQLCMDPASSWORD "$SQLC" $SQLCMD -S localhost -U sa -C -b -d pgagtm -Q "CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, v int NOT NULL); INSERT dbo.t VALUES (1, 0);" >/dev/null
  docker exec -e SQLCMDPASSWORD "$SQLC" $SQLCMD -S localhost -U sa -C -d pgagtm -H "pgagth$SUF" -Q "BEGIN TRAN; UPDATE dbo.t SET v = v + 1 WHERE id = 1; WAITFOR DELAY '00:01:00'; ROLLBACK;" >/dev/null 2>&1 &
  sleep 3
  docker exec -e SQLCMDPASSWORD "$SQLC" $SQLCMD -S localhost -U sa -C -d pgagtm -H "pgagtw$SUF" -Q "UPDATE dbo.t SET v = v + 1 WHERE id = (SELECT 1) AND N'sqlcmd -S . -U app -P $S1K -Q x' <> N''" >/dev/null 2>&1 &
  for _ in $(seq 1 50); do [[ $(sq "SELECT COUNT(*) FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.host_name = 'pgagtw$SUF' AND r.blocking_session_id > 0") == 1 ]] && break; sleep 0.2; done
  "$BIN" collect -config "$WORK/cfg-ms.yaml" -once mssql_requests -instance "agt-sql-full-$SUF" >"$WORK/collect-ms.log" 2>&1 || echo "note: collect -once mssql_requests: $(tail -2 "$WORK/collect-ms.log")"
  calls m_2 "$(tc claim_investigation "{\"id\":${M1:-0},\"agent\":\"agent-m\"}")" \
    "$(tc run_select "$(jq -cn --argjson i "${M1:-0}" '{id:$i,claim_id:"$claim",sql:"SELECT t.statement FROM pgvigil.mssql_statement_text t WHERE t.statement LIKE '"'"'%sqlcmd -S . -U app%'"'"'"}')")" \
    "$(tc find_statements '{"text":"sqlcmd -S . -U app"}')"
  q "update pgvigil.investigations set lease_until = now() - interval '1 second' where id = ${M1:-0}" >/dev/null
  mc AG1_DSN m_2
  r1=$(Rr m_2 1 '.body.rows[0][0] // empty'); f=$(R m_2 2 '.body')
  [[ $r1 == *"-P <masked>"* && $r1 != *"$S1K"* && $f == *"<masked>"* && $f != *"$S1K"* ]] && ok "M5 SQL Server under full: run_select and find_statements answer '-P <masked>', never the password" || bad "M5 SQL Server: run_select '${r1:0:160}' find_statements '${f:0:160}'"
fi

echo "--- U. the pages"
if [[ -n "${PGVIGIL_SKIP_PAGES:-}" ]]; then NOTPROVEN+=("U the pages (PGVIGIL_SKIP_PAGES)"); else
  for t in chromium node npm; do command -v $t >/dev/null || die "U: $t is not on this machine (PGVIGIL_SKIP_PAGES=1 leaves the pages out)"; done
  (cd "$WORK" && npm install --silent --no-audit --no-fund --no-package-lock axe-core@4.14.0 >/dev/null 2>&1) || die "U: npm install axe-core"
  reset_inv; U1R=$(ask_finding "U"); calls u_1 "$(tc claim_investigation "{\"id\":${U1R:-0},\"agent\":\"agent-u\"}")" "$(tc report_investigation "{\"id\":${U1R:-0},\"claim_id\":\"\$claim\",\"verdict\":\"real\",\"summary\":\"U summary\",\"body\":\"b\"}")"; mc AG1_DSN u_1
  CDP=$(freeport)
  chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank >"$WORK/chrome.log" 2>&1 & CHR=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
  cat > "$WORK/u.mjs" <<'JS'
const [port, base, cookie, hash, axePath, theme] = process.argv.slice(2);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const t = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(t.webSocketDebuggerUrl);
await new Promise((r, j) => { ws.addEventListener('open', r); ws.addEventListener('error', j); });
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(res => { const i = ++id; wait.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => (await cmd('Runtime.evaluate', { returnByValue: true, awaitPromise: true, expression: e })).result?.result?.value;
await cmd('Network.enable'); await cmd('Page.enable');
await cmd('Network.setCookie', { name: 'pgvigil_session', value: cookie, url: base });
if (theme) await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
await cmd('Page.navigate', { url: base + hash });
await sleep(4000);
const out = await ev(`(() => {
  const btns = [...document.querySelectorAll('main button')].map(b => b.textContent.trim());
  return { investigate: btns.filter(x => x === 'Investigate').length,
           ask: !!document.querySelector('main textarea[aria-label="Ask"], main textarea[name="ask"]'),
           rows: document.querySelectorAll('main table tbody tr').length,
           unreviewed: /unreviewed/i.test(document.querySelector('main')?.textContent || '') };
})()`);
if (axePath) {
  const src = (await import('node:fs')).readFileSync(axePath, 'utf8');
  await ev(src + '; true');
  out.axeNodes = await ev(`axe.run(document.querySelector('main') || document, { resultTypes: ['violations'] }).then(r => r.violations.reduce((n, v) => n + v.nodes.length, 0))`);
}
console.log(JSON.stringify(out));
await fetch(`http://127.0.0.1:${port}/json/close/${t.id}`).catch(() => {});
process.exit(0);
JS
  CK1=$(awk '$6 == "pgvigil_session" {print $7}' "$WORK/jar-s1-$U1"); CK2=$(awk '$6 == "pgvigil_session" {print $7}' "$WORK/jar-s2-$U1")
  pg() { timeout 90 node "$WORK/u.mjs" "$CDP" "$1/" "$2" "$3" "${4:-}" "${5:-}" 2>&1 | tail -1; }
  f=$(pg "$S1" "$CK1" "#/findings"); i=$(pg "$S1" "$CK1" "#/investigations?id=${U1R:-0}"); off=$(pg "$S2" "$CK2" "#/findings")
  [[ $(jq -r '.investigate' <<<"$f" 2>/dev/null) -ge 1 ]] && ok "U1 #/findings: an Investigate button on a finding row" || bad "U1 #/findings: $f"
  [[ $(jq -r '[.ask, (.rows >= 1), .unreviewed] | all' <<<"$i" 2>/dev/null) == true ]] && ok "U2 #/investigations: the Ask box, the grid, the report's 'unreviewed' line" || bad "U2 #/investigations: $i"
  [[ $(jq -r '.investigate' <<<"$off" 2>/dev/null) == 0 ]] && ok "U3 the serve without agents: no Investigate button" || bad "U3 the serve without agents: $off"
  for th in light dark; do a=$(pg "$S1" "$CK1" "#/investigations?id=${U1R:-0}" "$WORK/node_modules/axe-core/axe.min.js" "$th")
    [[ $(jq -r '.axeNodes' <<<"$a" 2>/dev/null) == 0 ]] && ok "U4 axe-core on #/investigations ($th): 0 violation nodes" || bad "U4 axe-core ($th): $a"; done
fi

echo "--- the end"
for n in "${NOTPROVEN[@]}"; do echo "NOT PROVEN: $n"; done
echo "AGENT: $OKS ok, $FAILS FAIL"
[[ $FAILS == 0 ]]
