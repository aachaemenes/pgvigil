#!/usr/bin/env bash
# proof-gridmenu.sh: the grid menu's browser check on a fresh build - the web bundle (npm ci, npm run build: tsc and
# esbuild), then scripts/menu-check.mjs with PGVIGIL_MENU_ONLY=G (case G, the base's grid lines, and the GM cases
# G-menu .. G-themes; menu-check.mjs's header names each). menu-check itself builds the binary, seeds the demo into a
# throwaway database on PGVIGIL_ADMIN_DSN, serves it on loopback and drives a headless Chromium; it removes all three.
#   PGVIGIL_ADMIN_DSN="host=127.0.0.1 port=5432 user=postgres" bash scripts/proof-gridmenu.sh
#   PGVIGIL_GRIDMENU_OUT  the folder for the logs and the pictures (default: a new temporary folder, named at the end)
#   PGVIGIL_MENU_ONLY     the cases (default G); PGVIGIL_MENU_SHOTS the pictures (default <out>/shots)
# Needs node 22+, npm, go, psql and chromium. Exit: menu-check's (0 = every case ok), 1 = the build failed, 2 = no DSN.
#
# Expected (the red run, on main 1aba474 with this file and menu-check.mjs copied in - written before it): the build
# green; case G's six rows ok (G grid menu, its Export Excel, G selection, G filter, G text column, G export: main holds
# task 172's flat menu); every GM row FAIL - G-menu and its header row '(no .tm-menu)', G-copy and G-copy empty, G-file
# (no file), G-order (no Copy > Column), G-rownum, G-transpose, G-filters, G-bars, G-keys (Tab lands on the grid's
# scroll box, not in the table), G-grouped (no .tm-menu), G-themes (no menu background); 'FAIL: 13 case(s)', rc 1.
set -uo pipefail
cd "$(dirname "$0")/.."
[[ -n "${PGVIGIL_ADMIN_DSN:-}" ]] || { echo "FAIL: PGVIGIL_ADMIN_DSN is not set"; exit 2; }
OUT="${PGVIGIL_GRIDMENU_OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
echo "== proof-gridmenu: node $(node --version), go $(go env GOVERSION 2>/dev/null), $(chromium --version 2>/dev/null | head -1); out $OUT"
( cd web && npm ci --no-audit --no-fund ) > "$OUT/npm.log" 2>&1 || { tail -20 "$OUT/npm.log"; echo "FAIL: npm ci (the log: $OUT/npm.log)"; exit 1; }
( cd web && npm run build ) > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo "FAIL: the web build (the log: $OUT/build.log)"; exit 1; }
PGVIGIL_MENU_ONLY="${PGVIGIL_MENU_ONLY:-G}" PGVIGIL_MENU_SHOTS="${PGVIGIL_MENU_SHOTS:-$OUT/shots}" \
  node scripts/menu-check.mjs 2>&1 | tee "$OUT/menu-check.log"
R=${PIPESTATUS[0]}
echo "== proof-gridmenu rc $R (the log: $OUT/menu-check.log)"
exit "$R"
