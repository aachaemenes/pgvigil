#!/usr/bin/env bash
# proof-gridmenu.sh: the grid menu's browser check on a fresh build - the web bundle (npm ci, npm run build: tsc and
# esbuild), a SQL Server container for case G-sql (docker; removed at the end), then scripts/menu-check.mjs with
# PGVIGIL_MENU_ONLY=G (the GM cases G-menu .. G-themes; case G retired into G-select; menu-check.mjs's header names
# each). menu-check itself builds the binary, seeds the demo into a throwaway database on PGVIGIL_ADMIN_DSN, serves it on
# loopback and drives a headless Chromium; it removes all three. G-sql runs the grid's two SQL files on that PostgreSQL
# and on the container.
#   PGVIGIL_ADMIN_DSN="host=127.0.0.1 port=5432 user=postgres" bash scripts/proof-gridmenu.sh
#   PGVIGIL_GRIDMENU_OUT  the folder for the logs and the pictures (default: a new temporary folder, named at the end)
#   PGVIGIL_MENU_ONLY     the cases (default G); PGVIGIL_MENU_SHOTS the pictures (default <out>/shots)
#                         P = the parity rows of P01 / P02 / P04 alone (P-chooser .. P-opengrid); G,P = both
#   PGVIGIL_GRIDMENU_NO_MSSQL=1  no container (G-sql then fails, saying so); a run whose cases name neither G nor G-sql
#                         starts none by itself (the container serves G-sql alone)
# Needs node 22+, npm, go, psql, chromium and docker. Exit: menu-check's (0 = every case ok), 1 = the build or the
# container failed, 2 = no DSN.
#
# Expected (the red run, on main 1aba474 with this file and menu-check.mjs copied in - written before it, after the
# fold of the design pass; case G of task 172 retired into G-select): the build green; the container answers;
# G-chart ok (the chart's menu is unchanged by design); every other GM row FAIL - G-menu, G-select, G-header, G-copy,
# G-copy JSON values, G-copy empty, G-file, G-hidden, G-order, G-rownum, G-transpose, G-filters, G-filters quoting,
# G-in, G-bars, G-keys (Tab lands on the grid's scroll box), G-grouped, G-empty0, G-dialog, G-sql (no SQL file),
# G-stmt, G-plain, G-mssql, G-big, G-themes (no menu background) - each '(no .tm-menu)' or the item absent;
# 'FAIL: 25 case(s)', rc 1.
#
# Expected of the P rows' red run (PGVIGIL_MENU_ONLY=P on rel-j16-last 65083820 with this file and menu-check.mjs
# copied in; written 11-16 before it): the build green; no container; P-opengrid ok (Open Grid reads the grid's own JSON
# on the base); the eight others FAIL, each in its own words - P-chooser (the panel's buttons hold no None and no Toggle
# selected, no undrawn name listed), P-rowhead (Row Headers null on the header and on a cell, 'Row numbers' still at
# the top), P-freeze (Freeze Column null), P-editfilter (no Edit Filter dialog), P-groupby (Group By... on the header
# false, the one-click 'Group by ...' items left), P-bars (the submenu's five items of the base), P-script (Save Table
# false), P-copysum (the toolbar's Copy is not there, for both scopes); no case 'threw'; 'FAIL: 8 case(s)', rc 1.
set -uo pipefail
cd "$(dirname "$0")/.."
[[ -n "${PGVIGIL_ADMIN_DSN:-}" ]] || { echo "FAIL: PGVIGIL_ADMIN_DSN is not set"; exit 2; }
OUT="${PGVIGIL_GRIDMENU_OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
SQLC=""; ENVF=""
cleanup() { [[ -n "$SQLC" ]] && docker rm -fv "$SQLC" >/dev/null 2>&1; [[ -n "$ENVF" ]] && rm -f "$ENVF"; return 0; }
trap cleanup EXIT
trap 'exit 130' INT TERM
echo "== proof-gridmenu: node $(node --version), go $(go env GOVERSION 2>/dev/null), $(chromium --version 2>/dev/null | head -1); out $OUT"
# the container serves case G-sql alone: a run that names its cases, none of them G or G-sql, starts none
case ",${PGVIGIL_MENU_ONLY:-G}," in *,G,*|*,G-sql,*) ;; *) PGVIGIL_GRIDMENU_NO_MSSQL=1 ;; esac
if [[ "${PGVIGIL_GRIDMENU_NO_MSSQL:-}" != 1 ]]; then
  # the sa password in a file of its own (never on a command line), the container on no published port
  SQLC="gridmenu-mssql-$$"; ENVF=$(mktemp); PW="Gm$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')!a1"
  printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$PW" "$PW" > "$ENVF"; unset PW
  docker run -d --name "$SQLC" --env-file "$ENVF" mcr.microsoft.com/mssql/server:2022-latest >/dev/null || { echo "FAIL: the SQL Server container did not start"; exit 1; }
  up=""
  for _ in $(seq 1 60); do
    if docker exec --env-file "$ENVF" "$SQLC" bash -c 'SQLCMDPASSWORD=$SA_PW /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -h -1 -Q "SET NOCOUNT ON; SELECT 1"' >/dev/null 2>&1; then up=1; break; fi
    sleep 3
  done
  [[ -n "$up" ]] || { docker logs "$SQLC" 2>&1 | tail -10; echo "FAIL: the SQL Server container did not answer in 180 s"; exit 1; }
  echo "== SQL Server container $SQLC answers"
  export PGVIGIL_MENU_MSSQL="$SQLC" PGVIGIL_MENU_MSSQL_ENV="$ENVF"
fi
( cd web && npm ci --no-audit --no-fund ) > "$OUT/npm.log" 2>&1 || { tail -20 "$OUT/npm.log"; echo "FAIL: npm ci (the log: $OUT/npm.log)"; exit 1; }
( cd web && npm run build ) > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo "FAIL: the web build (the log: $OUT/build.log)"; exit 1; }
PGVIGIL_MENU_ONLY="${PGVIGIL_MENU_ONLY:-G}" PGVIGIL_MENU_SHOTS="${PGVIGIL_MENU_SHOTS:-$OUT/shots}" \
  node scripts/menu-check.mjs 2>&1 | tee "$OUT/menu-check.log"
R=${PIPESTATUS[0]}
echo "== proof-gridmenu rc $R (the log: $OUT/menu-check.log)"
exit "$R"
