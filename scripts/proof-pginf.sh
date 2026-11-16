#!/usr/bin/env bash
# proof-pginf.sh - +/-infinity and the float specials from pgx's rows.Values() reach the repository and the pages in a
# form PostgreSQL reads back (internal/collect/jsonvalue.go: rowsToMaps; internal/web: query, queryTx). Runs on the
# lab box (a Cloud-Box job): go, docker, psql. One postgres:18 container of the run's own, published on 127.0.0.1
# only, removed at the end.
#
#   scripts/proof-pginf.sh            the seven rows below, then (PGINF_FULL=1) the whole collect and web packages
#
# EXPECTED (written before any run):
#   red  (the tests on pgvigil main 32c7aace's code, rel-pginf's first commit):
#     TestRowsToMapsJSONValues           FAIL 'the rows do not marshal ... json: unsupported value: NaN'
#     TestRowsToMapsInfinityLive         FAIL 'the rows do not marshal ... unsupported value: NaN'
#     TestRolesValidUntilInfinityImport  FAIL 'did not import: ERROR: invalid input syntax for type timestamp with
#                                        time zone: "1" (SQLSTATE 22007)' - the RDS lab's error, on-prem
#     TestQueryJSONValues                FAIL 'query: the table does not marshal ... unsupported value: NaN'
#     TestPgCellJSONValues               FAIL 'the cells do not marshal ... unsupported value: NaN' (added with the
#                                        review's fold; red on f22a85b3, whose fix did not reach custom reports' pgCell)
#   PGINF-2 (migration 0270, written before its run):
#     TestRolesMinusInfinityText         red (the tests on 70f74171): FAIL - role_flags got 'login | login | login,valid
#                                        until 2026-01-02 03:04 UTC | login' (the non-finite 'valid until' dropped) and
#                                        the finding's detail got NULL; green (0270): PASS
#   PGINF-2's review fold (written before its run):
#     TestReportPwageNonFinite           red (on 59a71dd8): FAIL 'the Password age report's PostgreSQL part failed ...
#                                        cannot convert infinity to integer' (PostgreSQL 18); green: PASS
#   green (the fix): all seven PASS (counted: a skip or a missing test is a FAIL); PGINF_FULL=1: 'ok   tsc --noEmit' for
#     web/ (roles.ts: '-infinity' badged expired) and ok for
#     ./internal/collect/ and ./internal/web/ - their other tests gated on PGVIGIL_REPO_DSN / PGVIGIL_REPO_TEST_DSN
#     run against this throwaway database too (collect: dms, statements, pi, versions, cloudwatch_io; web: actions,
#     q_plans, q_storage, migrate, perf_scope and more); every other database test skips without its own variable.
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
go test ./internal/collect/ -run '^(TestRowsToMapsJSONValues|TestRowsToMapsInfinityLive|TestRolesValidUntilInfinityImport|TestRolesMinusInfinityText)$' -count=1 -v > "$W/c.out" 2>&1 || RC=1
pick "$W/c.out"
go test ./internal/web/ -run '^(TestQueryJSONValues|TestPgCellJSONValues|TestReportPwageNonFinite)$' -count=1 -v > "$W/w.out" 2>&1 || RC=1
pick "$W/w.out"
# a test that skipped (its variable unset) or matched nothing passes go test: the seven are counted
NP=$(cat "$W/c.out" "$W/w.out" | grep -cE '^--- PASS: (TestRowsToMapsJSONValues|TestRowsToMapsInfinityLive|TestRolesValidUntilInfinityImport|TestRolesMinusInfinityText|TestQueryJSONValues|TestPgCellJSONValues|TestReportPwageNonFinite) ')
NS=$(cat "$W/c.out" "$W/w.out" | grep -c '^--- SKIP')
[ "$NP" = 7 ] && [ "$NS" = 0 ] || { echo "FAIL $NP of the 7 rows passed, $NS skipped"; RC=1; }
[ "$RC" = 0 ] || { echo "pginf: the whole output of the rows:"; cat "$W/c.out" "$W/w.out"; }
if [ "${PGINF_FULL:-0}" = 1 ]; then
  echo "pginf: the whole collect and web packages"
  go test ./internal/collect/ ./internal/web/ -count=1 2>&1 | tail -20
  [ "${PIPESTATUS[0]}" = 0 ] || RC=1
  echo "pginf: the web's type check (roles.ts)"
  if (cd web && npm ci --silent --no-audit --no-fund >/dev/null 2>&1 && npx --no-install tsc --noEmit -p . 2>&1 | tail -10; exit "${PIPESTATUS[0]}"); then echo "ok   tsc --noEmit"
  else echo "FAIL tsc --noEmit (or npm ci)"; RC=1; fi
fi
echo "pginf: exit $RC"
exit $RC
