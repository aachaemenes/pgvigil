#!/usr/bin/env bash
# Proof of the query_text policy on the local sandbox: the same marked session (a literal and a string in
# its text) is collected under full, normalized and none; the repository holds the literal only under full,
# a ? form under normalized, and no text row at all under none.
#   PGVIGIL_REPO_DSN   repository;  TARGET_DSN  the monitored sandbox (default = the repository connection)
# Expected: full -> query_text has the marker with 4711 and 'needle'; normalized -> the marker's row reads
# "... = ? and name = ?" with neither literal; none -> no query_text row carries the marker, the
# activity_sample row still exists with its query_hash.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
TARGET=${TARGET_DSN:-$PGVIGIL_REPO_DSN}
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }
CFG=$(mktemp); PIDS=""
cleanup() { rm -f "$CFG"; [[ -n "$PIDS" ]] && kill $PIDS 2>/dev/null || true; }
trap cleanup EXIT
export QT_TARGET_DSN="$TARGET"
for MODE in full normalized none; do
  TAG="pgvigil_qt_$RANDOM"
  cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
query_text: $MODE
instances:
  - name: qt-$MODE-$TAG
    dsn: env:QT_TARGET_DSN
EOF
  "$BIN" migrate -config "$CFG" >/dev/null
  # a session active for a few seconds whose text carries the marker, a number and a string
  psql "$TARGET" -XAtq -c "select pg_sleep(6) from (select 1) x where 4711 = 4711 and 'needle' = 'needle' and '$TAG' = '$TAG'" >/dev/null 2>&1 & PIDS="$PIDS $!"
  sleep 1
  "$BIN" collect -config "$CFG" -once activity >/dev/null || fail "collect activity ($MODE)"
  iid=$(q "select instance_id from pgvigil.instances where name='qt-$MODE-$TAG'")
  S=$(q "select count(*) from pgvigil.activity_sample where instance_id=$iid and query_hash is not null")
  [[ "$S" -ge 1 ]] || fail "$MODE: no activity_sample row with a query_hash"
  case $MODE in
    full)       T=$(q "select count(*) from pgvigil.query_text t join pgvigil.activity_sample s using (query_hash) where s.instance_id=$iid and t.query like '%$TAG%' and t.query like '%4711%' and t.query like '%needle%'")
                [[ "$T" == 1 ]] || fail "full: marker row with both literals = $T, want 1" ;;
    normalized) T=$(q "select count(*) from pgvigil.query_text t join pgvigil.activity_sample s using (query_hash) where s.instance_id=$iid and t.query like '%? = ? and ? = ? and ? = ?%' and t.query not like '%4711%' and t.query not like '%needle%' and t.query not like '%$TAG%'")
                [[ "$T" == 1 ]] || fail "normalized: ? row without literals = $T, want 1 (rows: $(q "select t.query from pgvigil.query_text t join pgvigil.activity_sample s using (query_hash) where s.instance_id=$iid"))" ;;
    none)       T=$(q "select count(*) from pgvigil.query_text t where t.query like '%$TAG%'")
                [[ "$T" == 0 ]] || fail "none: $T text row(s) carry the marker"
                N=$(q "select count(*) from pgvigil.query_text t join pgvigil.activity_sample s using (query_hash) where s.instance_id=$iid")
                [[ "$N" == 0 ]] || fail "none: $N query_text row(s) joined to this instance's samples" ;;
  esac
  echo "ok $MODE"
  wait $PIDS 2>/dev/null || true; PIDS=""
  q "delete from pgvigil.instances where instance_id=$iid" >/dev/null
done
echo "proof-querytext: OK (full keeps literals, normalized stores ?, none stores no text)"
