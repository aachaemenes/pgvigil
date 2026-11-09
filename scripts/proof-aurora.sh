#!/usr/bin/env bash
# Aurora proof: platform detection and the read-only collections against the AWS lab cluster
# (IAM authentication: the token is the password, good for 15 minutes). Read only on the
# target; the repository is the local sandbox. Needs an active `aws login --profile <profile>`.
#
#   PGVIGIL_REPO_DSN   repository
#   AWS_PROFILE        default dba-lab;  CLUSTER  default dba-lab-pg;  DBUSER default postgres
#
# Expected: instance_state.platform = 'aurora', is_replica false on the writer endpoint,
# collection_dates: instance ok, activity ok, dbstats ok, statements 'skipped' with the note
# "pg_stat_statements is not installed in the connected database" (the lab has not created it);
# the first query after a Serverless v2 pause can take about 15 s (statement_timeout is 30 s).
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
PROFILE=${AWS_PROFILE:-dba-lab}; CLUSTER=${CLUSTER:-dba-lab-pg}; DBUSER=${DBUSER:-postgres}
CFG=$(mktemp); trap 'rm -f "$CFG"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }

H=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].Endpoint' --output text --profile "$PROFILE")
[ -n "$H" ] && [ "$H" != "None" ] || fail "no writer endpoint for $CLUSTER"
TOKEN=$(aws rds generate-db-auth-token --hostname "$H" --port 5432 --username "$DBUSER" --profile "$PROFILE")
export AURORA_DSN="host=$H port=5432 user=$DBUSER dbname=postgres sslmode=require password=$TOKEN"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: lab-aurora-writer
    dsn: env:AURORA_DSN
    tags: [lab, aurora]
EOF
"$BIN" migrate -config "$CFG" >/dev/null
for c in instance activity dbstats statements; do
  "$BIN" collect -config "$CFG" -once "$c" || true      # a skip prints its reason, a failure exits 1 and is graded below
done
iid=$(q "select instance_id from pgvigil.instances where name='lab-aurora-writer'")
[ -n "$iid" ] || fail "no instance row"
plat=$(q "select platform || '/' || is_replica || '/' || server_version_num from pgvigil.instance_state where instance_id=$iid")
echo "instance: platform/is_replica/version = $plat"
[[ "$plat" == aurora/false/* ]] || fail "platform not aurora on the writer: $plat"
q "select collection || ': ' || status || coalesce(' (' || note || ')', '') from pgvigil.collection_dates where instance_id=$iid order by 1"
[ "$(q "select status from pgvigil.collection_dates where instance_id=$iid and collection='activity'")" = "ok" ] || fail "activity not ok"
[ "$(q "select status from pgvigil.collection_dates where instance_id=$iid and collection='dbstats'")" = "ok" ] || fail "dbstats not ok"
echo "proof-aurora: OK"
