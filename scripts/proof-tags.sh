#!/usr/bin/env bash
# Proof of tags as key:value pairs, the ui: block and the repository-side override (migration 0032, pgvigil tag,
# GET /api/tags, the instances read) on the sandbox; the sandbox server is both the repository and the monitored one.
#   PGVIGIL_REPO_DSN  repository owner connection. Creates and drops one instance and one login with a random suffix.
# Needs the join's wiring: the 'tag' command in main.go, GET /api/tags and the merged tags column of the instances read.
# Expected: migrate applies 0032; a config whose tag is "env:" is refused ("has no value") and one with group_by
# [env, env] ("listed twice"); a collection writes the config's [prod, erp, env:prod, team:billing] as written and
# instance_tags_merged shows {env:prod,erp,prod,team:billing}, all four pairs source config; `pgvigil tag <i>
# team=payments,ledger` -> {env:prod,erp,prod,team:ledger,team:payments} with team source override (its listing
# says "override"); `-env` hides env -> {erp,prod,team:ledger,team:payments} (listing "env:* hidden"); a second
# collection (the config redeployed) keeps both overrides; `-reset <i> team env` brings back the config's four;
# `tag=prod` replaces the plain words -> {env:prod,prod,team:billing}, then -reset tag; a reader login gets
# permission denied writing instance_tag_overrides and `pgvigil tag` on a reader dsn names the repository owner;
# an unknown instance is refused naming its first collection; serve: /api/instances carries the merged tags,
# /api/tags gives group_by [env,team], env_order [prod,staging,dev], the keys env, tag, team and the pairs.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
R=$RANDOM$RANDOM; I="proof-tags-$R"; RD="pgvigil_it_rd_$R"; PW="pw$RANDOM$RANDOM"
PORT=$((20000 + RANDOM % 20000))
CFG=$(mktemp); BAD=$(mktemp); RCFG=$(mktemp); LOG=$(mktemp); SRVPID=""
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  psql "$PGVIGIL_REPO_DSN" -XAtq -c "delete from pgvigil.instances where name = '$I'" -c "drop role if exists $RD" >/dev/null 2>&1 || true
  rm -f "$CFG" "$BAD" "$RCFG" "$LOG"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; [[ -s "$LOG" ]] && sed 's/^/  serve: /' "$LOG" >&2; exit 1; }
HOST=$(q "select coalesce(host(inet_server_addr()),'localhost')"); DBPORT=$(q "select inet_server_port()"); DB=$(q "select current_database()")
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
ui:
  group_by: [env, team]
  env_order: [prod, staging, dev]
instances:
  - name: $I
    dsn: env:PGVIGIL_REPO_DSN
    tags: [prod, erp, "env:prod", "team:billing"]
EOF
"$BIN" migrate -config "$CFG" >/dev/null
[[ $(q "select count(*) from pgvigil.schema_version where version = '0032_tags.sql'") == 1 ]] || fail "0032 not applied"
echo "ok: migrate applied 0032"

sed 's/"team:billing"/"env:"/' "$CFG" > "$BAD"
out=$("$BIN" migrate -config "$BAD" 2>&1) && fail "a tag without a value was accepted"
[[ "$out" == *"has no value"* ]] || fail "the empty tag refusal does not say why: $out"
sed 's/group_by: \[env, team\]/group_by: [env, env]/' "$CFG" > "$BAD"
out=$("$BIN" migrate -config "$BAD" 2>&1) && fail "group_by [env, env] was accepted"
[[ "$out" == *"listed twice"* ]] || fail "the group_by refusal does not say why: $out"
echo "ok: a tag without a value and a key grouped twice are refused"

merged() { q "select m.tags from pgvigil.instance_tags_merged m join pgvigil.instances i using (instance_id) where i.name = '$I'"; }
pairs() { q "select string_agg(key || '=' || value || '/' || source, ' ' order by key, value) from pgvigil.instance_tag_pairs p join pgvigil.instances i using (instance_id) where i.name = '$I'"; }
expect() { local got; got=$(merged); [[ "$got" == "$1" ]] || fail "$2: merged tags $got, expected $1"; echo "ok: $2: $got"; }

"$BIN" collect -config "$CFG" -once instance >/dev/null 2>&1 || fail "collect -once instance"
[[ $(q "select tags from pgvigil.instances where name = '$I'") == '{prod,erp,env:prod,team:billing}' ]] || fail "instances.tags is not the config's list as written"
expect '{env:prod,erp,prod,team:billing}' "the config's tags"
[[ $(pairs) == "env=prod/config tag=erp/config tag=prod/config team=billing/config" ]] || fail "pairs: $(pairs)"

out=$("$BIN" tag -config "$CFG" "$I" team=payments,ledger)
grep -q 'team:payments  *override' <<<"$out" || fail "the listing does not mark the override: $out"
expect '{env:prod,erp,prod,team:ledger,team:payments}' "team=payments,ledger"
[[ $(pairs) == "env=prod/config tag=erp/config tag=prod/config team=ledger/override team=payments/override" ]] || fail "pairs: $(pairs)"

out=$("$BIN" tag -config "$CFG" "$I" -env)
grep -q 'env:\*  *hidden' <<<"$out" || fail "the listing does not show env hidden: $out"
expect '{erp,prod,team:ledger,team:payments}' "-env"

"$BIN" collect -config "$CFG" -once instance >/dev/null 2>&1 || fail "the second collect"
expect '{erp,prod,team:ledger,team:payments}' "a redeploy (second collection) keeps the overrides"

"$BIN" tag -config "$CFG" -reset "$I" team env >/dev/null
expect '{env:prod,erp,prod,team:billing}' "-reset team env"
"$BIN" tag -config "$CFG" "$I" tag=prod >/dev/null
expect '{env:prod,prod,team:billing}' "tag=prod (the plain words replaced)"
"$BIN" tag -config "$CFG" -reset "$I" tag >/dev/null
expect '{env:prod,erp,prod,team:billing}' "-reset tag"

q "create role $RD login password '$PW' in role pgvigil_reader" >/dev/null
RDSN="host=$HOST port=$DBPORT user=$RD password=$PW dbname=$DB sslmode=disable"
out=$(psql "$RDSN" -XAt -c "insert into pgvigil.instance_tag_overrides (instance_id, key, vals) select instance_id, 'env', '{x}' from pgvigil.instances where name = '$I'" 2>&1 || true)
[[ "$out" == *"permission denied"* ]] || fail "a reader could write an override: $out"
[[ $(psql "$RDSN" -XAt -c "select count(*) from pgvigil.instance_tags_merged") -ge 1 ]] || fail "a reader cannot read instance_tags_merged"
sed "s|dsn: env:PGVIGIL_REPO_DSN|dsn: env:RDSN|" "$CFG" > "$RCFG"
out=$(RDSN="$RDSN" "$BIN" tag -config "$RCFG" "$I" env=dev 2>&1) && fail "pgvigil tag on a reader login succeeded"
[[ "$out" == *"repository owner"* ]] || fail "the reader refusal does not name the owner: $out"
out=$("$BIN" tag -config "$CFG" "no-such-instance-$R" env=dev 2>&1) && fail "an unknown instance was accepted"
[[ "$out" == *"first collection"* ]] || fail "the unknown instance refusal does not say why: $out"
echo "ok: a reader cannot write overrides and pgvigil tag names the owner; an unknown instance is refused"

"$BIN" tag -config "$CFG" "$I" team=payments >/dev/null
"$BIN" serve -config "$CFG" -no-login -listen "127.0.0.1:$PORT" >"$LOG" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/health" && break; sleep 0.2; done
inst=$(curl -s "http://127.0.0.1:$PORT/api/instances")
python3 -c '
import json, sys
d = json.loads(sys.argv[1]); name = sys.argv[2]
rows = [dict(zip(d["columns"], r)) for r in d["rows"]]
r = [x for x in rows if x["name"] == name]
assert r and r[0]["tags"] == ["env:prod", "erp", "prod", "team:payments"], r and r[0]["tags"]
' "$inst" "$I" || fail "/api/instances does not carry the merged tags"
tags=$(curl -s "http://127.0.0.1:$PORT/api/tags")
python3 -c '
import json, sys
d = json.loads(sys.argv[1]); name_id = int(sys.argv[2])
assert d["group_by"] == ["env", "team"], d["group_by"]
assert d["env_order"] == ["prod", "staging", "dev"], d["env_order"]
keys = [r[0] for r in d["keys"]["rows"]]
assert {"env", "tag", "team"} <= set(keys), keys
p = [dict(zip(d["pairs"]["columns"], r)) for r in d["pairs"]["rows"] if r[0] == name_id]
got = sorted((x["key"], x["value"], x["source"]) for x in p)
assert got == [("env", "prod", "config"), ("tag", "erp", "config"), ("tag", "prod", "config"), ("team", "payments", "override")], got
' "$tags" "$(q "select instance_id from pgvigil.instances where name = '$I'")" || fail "/api/tags is not the ui: block with the merged pairs"
echo "ok: /api/instances carries the merged tags; /api/tags gives group_by [env,team], env_order [prod,staging,dev], the keys and the pairs"
echo "PASS: proof-tags"
