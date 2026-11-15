#!/usr/bin/env bash
# proof-pginf.sh - +/-infinity and the float specials from pgx's rows.Values() reach the repository and the pages in a
# form PostgreSQL reads back (internal/collect/jsonvalue.go: rowsToMaps; internal/web: query, queryTx). Runs on the
# lab box (a Cloud-Box job): go, docker, psql. One postgres:18 container of the run's own, published on 127.0.0.1
# only, removed at the end.
#
#   scripts/proof-pginf.sh            the four rows below, then (PGINF_FULL=1) the whole collect and web packages
#
# EXPECTED (written 2026-11-15 15:4x PST before any run):
#   red  (the tests on pgvigil main 32c7aace's code, rel-pginf's first commit):
#     TestRowsToMapsJSONValues           FAIL 'the rows do not marshal ... json: unsupported value: NaN'
#     TestRowsToMapsInfinityLive         FAIL 'the rows do not marshal ... unsupported value: NaN'
#     TestRolesValidUntilInfinityImport  FAIL 'did not import: ERROR: invalid input syntax for type timestamp with
#                                        time zone: "1" (SQLSTATE 22007)' - the RDS lab's error, on-prem
#     TestQueryJSONValues                FAIL 'query: the table does not marshal ... unsupported value: NaN'
#   green (the fix): all four PASS; PGINF_FULL=1: ok for ./internal/collect/ and ./internal/web/ (their other
#     database tests skip unless their own variables are set).
set -uo pipefail
cd "$(dirname "$0")/.."
TAG=pginf-$$-$RANDOM
PW=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
cleanup() {
  docker rm -f -v "$TAG" >/dev/null 2>&1
  docker inspect "$TAG" >/dev/null 2>&1 && echo "CLEANUP: container $TAG LEFT" >&2
}
trap cleanup EXIT
RP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
docker run -d --name "$TAG" -e POSTGRES_PASSWORD="$PW" -p "127.0.0.1:$RP:5432" postgres:18 >/dev/null || { echo "FAIL the container did not start"; exit 1; }
ADM="host=127.0.0.1 port=$RP user=postgres password=$PW sslmode=disable"
for _ in $(seq 1 60); do psql "$ADM dbname=postgres" -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 1; done; sleep 2
psql "$ADM dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database pgvigil" >/dev/null || { echo "FAIL the repository database was not made"; exit 1; }
echo "pginf: $(psql "$ADM dbname=postgres" -XAtqc 'select version()')"
export PGVIGIL_REPO_DSN="$ADM dbname=pgvigil" PGVIGIL_REPO_TEST_DSN="$ADM dbname=pgvigil"
RC=0
go vet ./internal/collect/ ./internal/web/ || { echo "FAIL go vet"; RC=1; }
W=$(mktemp -d); trap 'cleanup; rm -rf "$W"' EXIT
pick() { grep -E '^(=== RUN|--- |ok|FAIL|PASS|panic)|jsonvalue_test.go' "$1"; }
go test ./internal/collect/ -run '^(TestRowsToMapsJSONValues|TestRowsToMapsInfinityLive|TestRolesValidUntilInfinityImport)$' -count=1 -v > "$W/c.out" 2>&1 || RC=1
pick "$W/c.out"
go test ./internal/web/ -run '^TestQueryJSONValues$' -count=1 -v > "$W/w.out" 2>&1 || RC=1
pick "$W/w.out"
if [ "${PGINF_FULL:-0}" = 1 ]; then
  echo "pginf: the whole collect and web packages"
  go test ./internal/collect/ ./internal/web/ -count=1 2>&1 | tail -20
  [ "${PIPESTATUS[0]}" = 0 ] || RC=1
fi
echo "pginf: exit $RC"
exit $RC
