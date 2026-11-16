#!/usr/bin/env bash
# Proof of `pgvigil mcp`: the Model Context Protocol door over stdio, as a reader login, against the demo repository.
#   PGVIGIL_REPO_DSN  a connection as a login that may CREATE DATABASE and CREATE ROLE (the demo repository and the
#                     reader login are made and dropped)
# The demo seeds two days (its -dsn by env:, so no password sits on its command line): table growth needs more than one day of the tables history.
# A scripted client (jq + a FIFO pair) talks newline-delimited JSON-RPC to one `pgvigil mcp` process.
# Expected:
#  (1) the owner's login is refused before any message is read: exit 3, "refused", nothing on stdout; (1b) a
#      pgvigil_reader login that also holds DELETE on one repository table is refused the same way;
#  (2) initialize answers protocolVersion 2025-06-18 (the client's) with serverInfo.name pgvigil and a tools capability;
#  (3) tools/list names exactly the ten tools, each with an object inputSchema and readOnlyHint true;
#  (4) every tool answers once, isError false, with its own content: fleet_summary lists the demo's instances,
#      instance_findings has checks, blocking_chain has a snapshot, top_statements has rows, plan_findings by id has
#      the plan, table_state has the table, storage_forecast has volumes; statement_everywhere echoes its hash and
#      answers rows (none when the demo holds no SQL Server statement), find_statements answers its sources;
#  (5) a write is refused: a tools/call of a tool that would terminate a backend is a JSON-RPC error naming
#      read-only, a resources/write method is "not served", and the reader login itself cannot write
#      (INSERT on pgvigil.instances: permission denied) - the door has no path to a write;
#  (6) the reader login's password appears nowhere in stdout or stderr; the process holds no listening socket.
#  (7) fail closed: without -config no instance's query_text policy is known and every
#      instance is read as 'none': top_statements returns its rows (as many as with -config) with no statement text
#      (every query null), blocking_chain no head statement (every head_query null), plan_findings by id (a plan whose
#      stored statement is 40 characters or more and that holds a plan_text; (4)'s may have none) no plan_text and no
#      part of that statement (the repository's own row, read as the owner, is the oracle), and
#      the log says every instance is read as 'none' and names -config; a second process given -config (a file with the
#      repository and no instance: the file's default, full) returns the text, head statements and plan_text for the
#      same calls (decisive both ways).
#      Red at b127f68f: (7) FAIL (the text returned without -config).
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}; BIN=$(readlink -f "$BIN")
: "${PGVIGIL_REPO_DSN:?}"
command -v jq >/dev/null || { echo "FAIL: jq is required" >&2; exit 1; }
SUF=$RANDOM$RANDOM; DB="pgvigil_it_mcp_$SUF"; ROLE="pgvigil_it_mcp_$SUF"; PW="mcp${RANDOM}x${RANDOM}pw"
WORK=$(mktemp -d); MPID=""
cleanup() {
  exec 3>&- 2>/dev/null || true
  [[ -n "$MPID" ]] && kill "$MPID" 2>/dev/null && wait "$MPID" 2>/dev/null || true
  psql "$PGVIGIL_REPO_DSN" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  psql "$PGVIGIL_REPO_DSN" -XAtq -c "drop role if exists $ROLE" -c "drop role if exists ${ROLE}_w" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok $*"; }
HOST=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select coalesce(host(inet_server_addr()),'localhost')")
DBPORT=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select inet_server_port()")
USERNAME=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select current_user")
psql "$PGVIGIL_REPO_DSN" -XAtq -c "create database $DB" >/dev/null
OWNER_DSN="host=$HOST port=$DBPORT user=$USERNAME dbname=$DB sslmode=disable"
[[ "$PGVIGIL_REPO_DSN" =~ password=([^[:space:]]+) ]] && OWNER_DSN="$OWNER_DSN password=${BASH_REMATCH[1]}"
PGVIGIL_PROOF_OWNER_DSN="$OWNER_DSN" "$BIN" demo -dsn env:PGVIGIL_PROOF_OWNER_DSN -instances 3 -days 2 >"$WORK/demo.out" 2>"$WORK/demo.log" || { cat "$WORK/demo.log" >&2; fail "demo seed"; }
psql "$OWNER_DSN" -XAtq -c "create role $ROLE login password '$PW' in role pgvigil_reader" >/dev/null
READER_DSN="host=$HOST port=$DBPORT user=$ROLE password=$PW dbname=$DB sslmode=disable"

# (1) the owner is refused before the protocol starts
set +e
PGVIGIL_MCP_DSN="$OWNER_DSN" "$BIN" mcp </dev/null >"$WORK/owner.out" 2>"$WORK/owner.err"; rc=$?
set -e
[[ $rc == 3 ]] || { cat "$WORK/owner.err" >&2; fail "(1) the owner's login: exit $rc, want 3"; }
grep -q 'refused' "$WORK/owner.err" || fail "(1) no 'refused' line for the owner's login"
[[ ! -s "$WORK/owner.out" ]] || fail "(1) the refused run wrote to stdout"
ok "(1) the owner's login refused (exit 3) before the protocol: $(grep -o 'refused: the login [a-z_0-9]* [^,;]*' "$WORK/owner.err" | head -1)"

# (1b) a reader login given one write grant on any repository table is refused too (not the owner, not a superuser)
psql "$OWNER_DSN" -XAtq -c "create role ${ROLE}_w login password '$PW' in role pgvigil_reader" -c "grant delete on pgvigil.query_text to ${ROLE}_w" >/dev/null
set +e
PGVIGIL_MCP_DSN="host=$HOST port=$DBPORT user=${ROLE}_w password=$PW dbname=$DB sslmode=disable" "$BIN" mcp </dev/null >"$WORK/writer.out" 2>"$WORK/writer.err"; rc=$?
set -e
[[ $rc == 3 ]] && grep -q "may change the repository's tables" "$WORK/writer.err" || { cat "$WORK/writer.err" >&2; fail "(1b) a reader with DELETE on pgvigil.query_text: exit $rc, want 3 and the writer reason"; }
ok "(1b) a reader login with DELETE on one repository table refused (exit 3)"

# the scripted client: requests go in on fd 3, replies come back one line each
mkfifo "$WORK/in"
MERR=mcp.err # the running process's log, which rpc prints when it exits
PGVIGIL_MCP_DSN="$READER_DSN" "$BIN" mcp <"$WORK/in" >"$WORK/out.jsonl" 2>"$WORK/mcp.err" & MPID=$!
exec 3>"$WORK/in"
echo 100 >"$WORK/n"
send() { printf '%s\n' "$1" >&3; }
# rpc <id> <method> <params-json>: send, then wait for the reply with that id and print it
rpc() {
  send "$(jq -cn --argjson id "$1" --arg m "$2" --argjson p "$3" '{jsonrpc:"2.0",id:$id,method:$m,params:$p}')"
  for _ in $(seq 300); do
    r=$(jq -c --argjson id "$1" 'select(.id==$id)' "$WORK/out.jsonl" 2>/dev/null || true)
    [[ -n "$r" ]] && { printf '%s' "$r"; return 0; }
    kill -0 "$MPID" 2>/dev/null || { cat "$WORK/$MERR" >&2; fail "pgvigil mcp exited"; }
    sleep 0.1
  done
  fail "no reply to $2 (id $1) in 30 s"
}
# the id counter lives in a file: tool runs inside $(...), a subshell, where N+=1 would not persist
tool() { local n; n=$(( $(cat "$WORK/n") + 1 )); echo "$n" >"$WORK/n"; rpc "$n" tools/call "$(jq -cn --arg n "$1" --argjson a "$2" '{name:$n,arguments:$a}')"; }
body() { jq -r '.result.content[0].text'; }

# (2) initialize
r=$(rpc 1 initialize '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"proof-mcp","version":"1"}}')
[[ $(jq -r '.result.protocolVersion' <<<"$r") == 2025-06-18 ]] || fail "(2) initialize: $r"
[[ $(jq -r '.result.serverInfo.name' <<<"$r") == pgvigil ]] || fail "(2) serverInfo: $r"
jq -e '.result.capabilities.tools' <<<"$r" >/dev/null || fail "(2) no tools capability: $r"
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
ok "(2) initialize: protocol 2025-06-18, server pgvigil, tools capability"

# (3) tools/list
r=$(rpc 2 tools/list '{}')
names=$(jq -r '[.result.tools[].name]|sort|join(",")' <<<"$r")
want="alert_history,blocking_chain,find_statements,fleet_summary,instance_findings,plan_findings,statement_everywhere,storage_forecast,table_state,top_statements"
[[ "$names" == "$want" ]] || fail "(3) tools: $names, want $want"
jq -e 'all(.result.tools[]; .inputSchema.type=="object" and .annotations.readOnlyHint==true and .annotations.destructiveHint==false)' <<<"$r" >/dev/null \
  || fail "(3) a tool without an object schema or the read-only marks"
ok "(3) tools/list: the ten tools, each read-only with an object schema"

# (4) every tool once
r=$(tool fleet_summary '{}'); [[ $(jq -r '.result.isError' <<<"$r") == false ]] || fail "(4) fleet_summary: $r"
ni=$(body <<<"$r" | jq '.instances|length'); nc=$(body <<<"$r" | jq '.checks|length')
[[ $ni == 3 ]] || fail "(4) fleet_summary: $ni instances, want 3"
INST=$(body <<<"$r" | jq -r '.instances[0].name')
ok "(4) fleet_summary: $ni instances, $nc failing checks"

r=$(tool instance_findings "$(jq -cn --arg i "$INST" '{instance:$i}')"); [[ $(jq -r '.result.isError' <<<"$r") == false ]] || fail "(4) instance_findings: $r"
nc=$(body <<<"$r" | jq '.checks|length'); nf=$(body <<<"$r" | jq '.parameter_findings|length')
(( nc + nf > 0 )) || fail "(4) instance_findings: nothing for $INST"
ok "(4) instance_findings $INST: $nc checks, $nf parameter findings"

r=$(tool blocking_chain "$(jq -cn --arg i "$INST" '{instance:$i}')"); [[ $(jq -r '.result.isError' <<<"$r") == false ]] || fail "(4) blocking_chain: $r"
snap=$(body <<<"$r" | jq -r '.snapshot_at'); nch=$(body <<<"$r" | jq '.chains|length')
[[ "$snap" != null ]] || fail "(4) blocking_chain: no snapshot"
ok "(4) blocking_chain $INST: snapshot $snap, $nch waiter rows"

r=$(tool top_statements "$(jq -cn --arg i "$INST" '{instance:$i,hours:24,limit:5}')"); [[ $(jq -r '.result.isError' <<<"$r") == false ]] || fail "(4) top_statements: $r"
ns=$(body <<<"$r" | jq '.statements|length'); (( ns > 0 && ns <= 5 )) || fail "(4) top_statements: $ns rows"
ok "(4) top_statements $INST: $ns rows (limit 5)"

r=$(tool plan_findings "$(jq -cn --arg i "$INST" '{instance:$i,hours:48}')"); [[ $(jq -r '.result.isError' <<<"$r") == false ]] || fail "(4) plan_findings list: $r"
PID=$(body <<<"$r" | jq -r '.plans[0].plan_id // empty'); [[ -n "$PID" ]] || fail "(4) plan_findings: no plan listed for $INST"
r=$(tool plan_findings "{\"plan_id\":$PID}"); [[ $(jq -r '.result.isError' <<<"$r") == false ]] || fail "(4) plan_findings: $r"
[[ $(body <<<"$r" | jq -r '.plan.plan_id') == "$PID" ]] || fail "(4) plan_findings: plan $PID not returned"
ok "(4) plan_findings: plan $PID with $(body <<<"$r" | jq '.hits|length') rule hit(s)"

SR=$(tool storage_forecast "$(jq -cn --arg i "$INST" '{instance:$i}')"); [[ $(jq -r '.result.isError' <<<"$SR") == false ]] || fail "(4) storage_forecast: $SR"
nv=$(body <<<"$SR" | jq '.volumes|length'); (( nv > 0 )) || fail "(4) storage_forecast: no volume for $INST"
r=$(tool storage_forecast '{}'); [[ $(jq -r '.result.isError' <<<"$r") == false ]] || fail "(4) storage_forecast fleet: $r"
ok "(4) storage_forecast: $nv volume(s) on $INST, $(body <<<"$r" | jq '.volumes|length') in the fleet"

# the table comes from the storage tool's table growth list (no catalog read by hand)
TNAME=$(body <<<"$SR" | jq -r '.tables[0].schema_name + "." + .tables[0].table_name'); TDB=$(body <<<"$SR" | jq -r '.tables[0].datname')
[[ "$TNAME" != "." && -n "$TDB" ]] || fail "(4) storage_forecast listed no table for $INST"
r=$(tool table_state "$(jq -cn --arg i "$INST" --arg t "$TNAME" --arg d "$TDB" '{instance:$i,table:$t,database:$d}')"); [[ $(jq -r '.result.isError' <<<"$r") == false ]] || fail "(4) table_state: $r"
[[ $(body <<<"$r" | jq '.tables|length') == 1 ]] || fail "(4) table_state: not one row for $TDB.$TNAME"
ok "(4) table_state $TDB.$TNAME: $(body <<<"$r" | jq -c '.tables[0]|{total_bytes,dead_pct,checks}')"

# task 406's two SQL Server statement tools, through the same reader login
r=$(tool statement_everywhere '{"query_hash":"0x1A2B3C4D","hours":24}'); [[ $(jq -r '.result.isError' <<<"$r") == false ]] || fail "(4) statement_everywhere: $r"
[[ $(body <<<"$r" | jq -r '.query_hash') == 0x1A2B3C4D ]] || fail "(4) statement_everywhere: the hash is not echoed: $r"
body <<<"$r" | jq -e '.rows|type == "array"' >/dev/null || fail "(4) statement_everywhere: no rows list: $r"
ok "(4) statement_everywhere 0x1A2B3C4D: $(body <<<"$r" | jq '.rows|length') row(s); note: $(body <<<"$r" | jq -r '.note // "none"')"
r=$(tool find_statements '{"text":"select"}'); [[ $(jq -r '.result.isError' <<<"$r") == false ]] || fail "(4) find_statements: $r"
body <<<"$r" | jq -e '.sources|type == "array"' >/dev/null || fail "(4) find_statements: no sources list: $r"
ok "(4) find_statements 'select': $(body <<<"$r" | jq '.sources|length') source(s), $(body <<<"$r" | jq '[.sources[]?.rows.rows // [] | length]|add // 0') row(s)"

# (7) part a: this process was started without -config; the plan read is one whose stored statement is 40 characters
# or more (read as the owner: the oracle), not (4)'s, whose statement the demo may leave empty
PQID=$(psql "$OWNER_DSN" -XAt -c "select plan_id from pgvigil.plans where length(regexp_replace(coalesce(query, ''), '\\s+', ' ', 'g')) >= 40 and plan_text is not null order by plan_id limit 1")
[[ -n "$PQID" ]] || fail "(7) the demo holds no plan with a plan_text and a stored statement of 40 characters"
A_CH=$(tool blocking_chain "$(jq -cn --arg i "$INST" '{instance:$i}')"); [[ $(jq -r '.result.isError' <<<"$A_CH") == false ]] || fail "(7) blocking_chain: $A_CH"
A_TOP=$(tool top_statements "$(jq -cn --arg i "$INST" '{instance:$i,hours:24,limit:5}')"); [[ $(jq -r '.result.isError' <<<"$A_TOP") == false ]] || fail "(7) top_statements: $A_TOP"
A_PLAN=$(tool plan_findings "{\"plan_id\":$PQID}"); [[ $(jq -r '.result.isError' <<<"$A_PLAN") == false ]] || fail "(7) plan_findings: $A_PLAN"

# (5) a refused write, three ways
r=$(tool terminate_backend '{"pid":1}')
jq -e '.error.code == -32602 and (.error.message|test("read-only"))' <<<"$r" >/dev/null || fail "(5) a write tool was not refused: $r"
r=$(rpc 3 resources/write '{"uri":"x"}')
jq -e '.error.code == -32601' <<<"$r" >/dev/null || fail "(5) resources/write was not refused: $r"
set +e
out=$(PGOPTIONS='-c default_transaction_read_only=off' psql "$READER_DSN" -XAtq -c "insert into pgvigil.instances(name) values ('mcp-write-probe')" 2>&1); rc=$?
set -e
[[ $rc != 0 && "$out" == *"permission denied"* ]] || fail "(5) the reader login could write: rc $rc $out"
ok "(5) a write is refused: the tool is unknown (-32602, read-only), resources/write is not served (-32601), the reader login has no INSERT"

# (6) no credential out, no listener
if grep -qF "$PW" "$WORK/out.jsonl" "$WORK/mcp.err" "$WORK/owner.err" "$WORK/writer.err"; then fail "(6) the reader's password reached an output"; fi
if command -v ss >/dev/null; then
  ss -Hltnp 2>/dev/null | grep -q "pid=$MPID," && fail "(6) pgvigil mcp holds a listening socket"
fi
ok "(6) the password is in no output; no listening socket"
exec 3>&-
for _ in $(seq 50); do kill -0 "$MPID" 2>/dev/null || break; sleep 0.1; done
kill -0 "$MPID" 2>/dev/null && fail "pgvigil mcp did not exit when its stdin closed"
wait "$MPID" || fail "pgvigil mcp exit $? after stdin closed"; MPID=""
ok "stdin closed: pgvigil mcp exited 0"

# (7) part b: the same reads through a process given -config (the repository, no instance: the file's default, full)
printf 'repository:\n  dsn: env:PGVIGIL_MCP_DSN\n' > "$WORK/mcp.yaml"
rm -f "$WORK/in" "$WORK/out.jsonl"; mkfifo "$WORK/in"
MERR=mcp2.err
PGVIGIL_MCP_DSN="$READER_DSN" "$BIN" mcp -config "$WORK/mcp.yaml" <"$WORK/in" >"$WORK/out.jsonl" 2>"$WORK/mcp2.err" & MPID=$!
exec 3>"$WORK/in"
r=$(rpc 1 initialize '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"proof-mcp","version":"1"}}')
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
B_TOP=$(tool top_statements "$(jq -cn --arg i "$INST" '{instance:$i,hours:24,limit:5}')"); [[ $(jq -r '.result.isError' <<<"$B_TOP") == false ]] || fail "(7) -config top_statements: $B_TOP"
B_PLAN=$(tool plan_findings "{\"plan_id\":$PQID}"); [[ $(jq -r '.result.isError' <<<"$B_PLAN") == false ]] || fail "(7) -config plan_findings: $B_PLAN"
B_CH=$(tool blocking_chain "$(jq -cn --arg i "$INST" '{instance:$i}')"); [[ $(jq -r '.result.isError' <<<"$B_CH") == false ]] || fail "(7) -config blocking_chain: $B_CH"
exec 3>&-
for _ in $(seq 50); do kill -0 "$MPID" 2>/dev/null || break; sleep 0.1; done
wait "$MPID" || fail "(7) pgvigil mcp -config exit $?"; MPID=""
grep -qF "$PW" "$WORK/out.jsonl" "$WORK/mcp2.err" && fail "(6) the reader's password reached the -config run's output"
# the plan's stored statement, read as the owner, whitespace folded: the oracle for plan_findings
PQ=$(psql "$OWNER_DSN" -XAt -c "select left(regexp_replace(query, '\\s+', ' ', 'g'), 40) from pgvigil.plans where plan_id = $PQID")
[[ ${#PQ} -ge 12 ]] || fail "(7) plan $PQID holds no stored statement to look for ('$PQ')"
holds() { body <<<"$1" | jq --arg p "$PQ" '[.. | strings | gsub("\\s+"; " ") | select(contains($p))] | length'; }
na=$(body <<<"$A_TOP" | jq '[.statements[] | .query | select(. != null and . != "")] | length')
nb=$(body <<<"$B_TOP" | jq '[.statements[] | .query | select(. != null and . != "")] | length')
pa=$(holds "$A_PLAN"); pb=$(holds "$B_PLAN")
ra=$(body <<<"$A_TOP" | jq '.statements|length'); rb=$(body <<<"$B_TOP" | jq '.statements|length')
xa=$(body <<<"$A_PLAN" | jq '[.plan.plan_text | select(. != null and . != "")] | length'); xb=$(body <<<"$B_PLAN" | jq '[.plan.plan_text | select(. != null and . != "")] | length')
ha=$(body <<<"$A_CH" | jq '[.chains[]? | .head_query | select(. != null and . != "")] | length'); hb=$(body <<<"$B_CH" | jq '[.chains[]? | .head_query | select(. != null and . != "")] | length')
(( nb > 0 && pb > 0 && xb > 0 && hb > 0 )) || fail "(7) not decisive: with -config top_statements $nb text(s), plan_findings $pb string(s) holding the stored statement, plan_text $xb, head statements $hb"
(( ra > 0 && ra == rb )) || fail "(7) without -config top_statements answered $ra row(s), with -config $rb"
[[ $na == 0 ]] || fail "(7) without -config top_statements returned $na statement text(s)"
[[ $xa == 0 ]] || fail "(7) without -config plan_findings returned plan $PQID's plan_text"
[[ $ha == 0 ]] || fail "(7) without -config blocking_chain returned $ha head statement(s)"
[[ $pa == 0 ]] || fail "(7) without -config plan_findings returned plan $PQID's stored statement ($pa string(s))"
grep -q "read as 'none'" "$WORK/mcp.err" && grep -q -- "-config" "$WORK/mcp.err" || { cat "$WORK/mcp.err" >&2; fail "(7) no log line saying every instance is read as 'none' and naming -config"; }
ok "(7) without -config: top_statements $ra rows, 0 texts (with -config $nb), plan $PQID's statement in 0 strings and no plan_text (with -config $pb / $xb), 0 head statements (with -config $hb); the log: $(grep -o "without -config[^\"]*'none'" "$WORK/mcp.err" | head -1)"
echo "PASS proof-mcp"
