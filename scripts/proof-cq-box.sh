#!/usr/bin/env bash
# The driver of scripts/proof-cq.sh on a lab box (a copy of the source tree, as setup/Cloud-Box.ps1 Run sends it):
# the wiring patches applied in that copy, the web bundle and the binary built, PgBouncer through a container shim
# when the box has no pgbouncer binary, then the proof; every line the proof prints that a grade reads, and any
# container of the proof left behind.
#
#   bash scripts/proof-cq-box.sh            from the top of the tree; the output goes into $CQ_OUT
#
#   CQ_OUT                 the folder of this run's files (default .proof-cq): build.txt, proof-cq.txt
#   PGVIGIL_ADMIN_DSN      as proof-cq.sh (default: host=127.0.0.1 port=5432 user=postgres)
#   PGVIGIL_COMMUNITY_DIR  as proof-cq.sh: frk-install-all.sql, darlingdata.sql, sp_WhoIsActive.sql (default
#                          .cq/community); without sp_WhoIsActive.sql the SQL Server rows are NOT PROVEN, said so
#   PGB_IMAGE              the PgBouncer image of the shim (default edoburu/pgbouncer:v1.26.1-p0)
#   Needs: go, node / npm, docker, psql, curl, python3; at least 5 GB free on /.
#
# The wiring patches (scripts/cq-wiring-a.patch, cq-wiring-a2.patch: the purge arm and serve's GET /api/requests/{id}
# and POST /api/requests/{id}/cancel routes) go in at the join; a tree that already holds them is left as it is, and a
# tree this driver patched is put back at its end. A copied worktree's .git pointer that names a path missing here is
# removed (git then reads no repository); any other .git is left alone.
# Exit: proof-cq.sh's exit code; 3 under 5 GB free; 11 the binary did not build; 12 the wiring or the web build failed.
set -u
cd "$(dirname "$0")/.." || exit 2
export PATH=$HOME/go/bin:/usr/local/go/bin:$PATH
echo "sha: $(git rev-parse --short HEAD 2>/dev/null || cat .cq/sha 2>/dev/null || echo unknown)"
if [ -f .git ] && ! [ -d "$(sed -n 's/^gitdir: //p' .git)" ]; then rm -f .git; fi
O=${CQ_OUT:-.proof-cq}; mkdir -p "$O" bin
UNWIRE=0; SHIM=""
done_() {
  rc=$?
  [ -n "$SHIM" ] && rm -rf "$SHIM"
  if [ "$UNWIRE" = 1 ]; then git apply -R scripts/cq-wiring-a2.patch && git apply -R scripts/cq-wiring-a.patch && echo "wiring: taken back" || { echo "THE WIRING PATCHES WERE NOT TAKEN BACK"; rc=12; }; fi
  exit $rc
}
trap done_ EXIT
free_mb() { df -BM --output=avail / | tail -1 | tr -dc '0-9'; }
echo "load $(cut -d' ' -f1-3 /proc/loadavg) on $(nproc) CPUs; disk $(free_mb) MB free; memory $(free -m | awk '/^Mem:/{print $7}') MB available"
[ "$(free_mb)" -ge 5120 ] || { echo "STOP: under 5 GB free"; exit 3; }
echo "=== B. wiring, web build, the binary $(date -u +%H:%M:%S)"
if grep -q 'RequestGet' internal/web/web.go; then echo "wiring: already in this tree"
else git apply scripts/cq-wiring-a.patch && git apply scripts/cq-wiring-a2.patch && UNWIRE=1 && echo "wiring: cq-wiring-a.patch and -a2.patch applied" || { echo "THE WIRING PATCHES DID NOT APPLY"; exit 12; }; fi
(cd web && npm ci --no-audit --no-fund >/dev/null 2>&1 && npm run build > "../$O/build.txt" 2>&1) && echo "built: bundle $(wc -c < internal/web/dist/app.js) bytes" || { echo "WEB BUILD FAILED"; grep -E 'error TS|ERROR' "$O/build.txt" | head -20; exit 12; }
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
docker ps -a --format '{{.Names}}' | grep -E '^cq(net|repo|serve|ms|pgb)_' | sed 's/^/LEFT BEHIND: /'
echo "disk $(free_mb) MB free at the end"
echo "proof-cq-box done $(date -u +%H:%M:%S)"
exit $rc
