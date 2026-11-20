#!/usr/bin/env bash
# The driver of scripts/proof-cq.sh on a lab box (a copy of the source tree sent to the box):
# the wiring patches applied in that copy, the web bundle and the binary built, PgBouncer through a container shim
# when the box has no pgbouncer binary, then the proof; every line the proof prints that a grade reads, and any
# container of the proof left behind.
#
#   bash scripts/proof-cq-box.sh            from the top of the tree; the output goes into $CQ_OUT
#
#   CQ_OUT                 the folder of this run's files (default .proof-cq; a relative one is under the tree's top):
#                          build.txt, proof-cq.txt
#   CQ_SHA                 the commit the sender copied, printed on the 'sha:' line (a box copy holds no repository;
#                          without it the line says what git answers here, else 'unknown')
#   PGVIGIL_ADMIN_DSN      as proof-cq.sh (default: host=127.0.0.1 port=5432 user=postgres)
#   PGVIGIL_COMMUNITY_DIR  as proof-cq.sh: frk-install-all.sql, darlingdata.sql, sp_WhoIsActive.sql (default
#                          .cq/community); without sp_WhoIsActive.sql the SQL Server rows are NOT PROVEN, said so
#   PGB_IMAGE              the PgBouncer image of the shim (default edoburu/pgbouncer:v1.26.1-p0)
#   Needs: go, node / npm, docker, psql, curl, python3; at least 5 GB free on /.
#
# The wiring patches (scripts/cq-purge-wiring.patch, cq-routes-wiring.patch: the purge arm and serve's GET /api/requests/{id}
# and POST /api/requests/{id}/cancel routes) go in with the release wiring; each patch a tree already holds is left as it is, and
# each patch this driver applied is taken back at its end, a half-applied pair included. A copied worktree's .git
# pointer that names a path missing here is removed (git then reads no repository); any other .git is left alone. The
# web build rewrites the tracked bundle internal/web/dist/app.js and leaves it so: on a working tree,
# 'git checkout -- internal/web/dist' after the run.
# Exit: proof-cq.sh's exit code; 2 the tree's top not found; 3 under 5 GB free; 11 the binary did not build; 12 the
# wiring or the web build failed, or a patch this driver applied could not be taken back (that 12 replaces the
# proof's own code: its 'proof-cq rc' line still says what the proof answered).
set -u
cd "$(dirname "$0")/.." || exit 2
export PATH=$HOME/go/bin:/usr/local/go/bin:$PATH
echo "sha: ${CQ_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
if [ -f .git ] && ! [ -d "$(sed -n 's/^gitdir: //p' .git)" ]; then rm -f .git; fi
mkdir -p "${CQ_OUT:-.proof-cq}" bin || exit 2; O=$(realpath "${CQ_OUT:-.proof-cq}") || exit 2
WA=0; WA2=0; SHIM=""
done_() {
  rc=$?
  [ -n "$SHIM" ] && rm -rf "$SHIM"
  if [ "$WA2" = 1 ]; then git apply -R scripts/cq-routes-wiring.patch && echo "wiring: cq-routes-wiring.patch taken back" || { echo "cq-routes-wiring.patch WAS NOT TAKEN BACK"; rc=12; }; fi
  if [ "$WA" = 1 ]; then git apply -R scripts/cq-purge-wiring.patch && echo "wiring: cq-purge-wiring.patch taken back" || { echo "cq-purge-wiring.patch WAS NOT TAKEN BACK"; rc=12; }; fi
  exit $rc
}
trap done_ EXIT
free_mb() { df -BM --output=avail / | tail -1 | tr -dc '0-9'; }
echo "load $(cut -d' ' -f1-3 /proc/loadavg) on $(nproc) CPUs; disk $(free_mb) MB free; memory $(free -m | awk '/^Mem:/{print $7}') MB available"
[ "$(free_mb)" -ge 5120 ] || { echo "STOP: under 5 GB free"; exit 3; }
echo "=== B. wiring, web build, the binary $(date -u +%H:%M:%S)"
# each patch on its own: one the tree holds (its reverse applies) is left as it is
for pt in purge routes; do
  f=scripts/cq-$pt-wiring.patch
  if git apply -R --check "$f" 2>/dev/null; then echo "wiring: $f already in this tree"
  elif git apply "$f"; then if [ $pt = purge ]; then WA=1; else WA2=1; fi; echo "wiring: $f applied"
  else echo "THE WIRING PATCH $f DID NOT APPLY"; exit 12; fi
done
(cd web && npm ci --no-audit --no-fund >/dev/null 2>&1 && npm run build > "$O/build.txt" 2>&1) && echo "built: bundle $(wc -c < internal/web/dist/app.js) bytes" || { echo "WEB BUILD FAILED"; grep -E 'error TS|ERROR' "$O/build.txt" | head -20; exit 12; }
CGO_ENABLED=0 go build -o bin/pgvigil ./cmd/pgvigil && echo "bin/pgvigil built" || { echo "BUILD FAILED"; exit 11; }
if ! command -v pgbouncer >/dev/null; then
  SHIM=$(mktemp -d); cp scripts/proof-cq-pgbouncer-shim.sh "$SHIM/pgbouncer"; chmod 755 "$SHIM/pgbouncer"; export PATH=$SHIM:$PATH
  echo "pgbouncer: the shim (${PGB_IMAGE:-edoburu/pgbouncer:v1.26.1-p0} on the host network)"
fi
echo "=== C. proof-cq $(date -u +%H:%M:%S)"
PGVIGIL_ADMIN_DSN=${PGVIGIL_ADMIN_DSN:-'host=127.0.0.1 port=5432 user=postgres'} PGVIGIL_COMMUNITY_DIR=${PGVIGIL_COMMUNITY_DIR:-$PWD/.cq/community} PGVIGIL_BIN=$PWD/bin/pgvigil \
  bash scripts/proof-cq.sh > "$O/proof-cq.txt" 2>&1; rc=$?
echo "proof-cq rc $rc $(date -u +%H:%M:%S)"
grep -E '^(ok|FAIL|NOT PROVEN|OK cq proof|cq proof)' "$O/proof-cq.txt" | cut -c1-600
[ $rc -eq 0 ] || tail -15 "$O/proof-cq.txt" | cut -c1-400
docker ps -a --format '{{.Names}}' | grep -E '^cq(repo|serve|ms|pgb)_' | sed 's/^/LEFT BEHIND: container /'
docker network ls --format '{{.Name}}' | grep -E '^cqnet_' | sed 's/^/LEFT BEHIND: network /'
psql "${PGVIGIL_ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres} dbname=postgres" -XAtqc "select 'database ' || datname from pg_database where datname like 'cqt\_%' union all select 'role ' || rolname from pg_roles where rolname like 'cqmon\_%'" 2>/dev/null | sed 's/^/LEFT BEHIND: /'
echo "disk $(free_mb) MB free at the end"
echo "proof-cq-box done $(date -u +%H:%M:%S)"
exit $rc
