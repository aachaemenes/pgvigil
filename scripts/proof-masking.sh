#!/usr/bin/env bash
# Proof that a password literal never reaches the repository: runs CREATE ROLE ... PASSWORD and
# ALTER ROLE ... PASSWORD on the target (a throwaway server), collects statements and activity,
# and searches every stored text for the literal.
#   PGVIGIL_REPO_DSN  repository;  ADMIN_DSN  superuser connection to the monitored server
# Expected: the statements collection stores the CREATE ROLE text with '<masked>' in place of the
# literal (pg_stat_statements keeps utility statements verbatim), and no stored text anywhere in
# the repository contains the literal.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${ADMIN_DSN:?}"
SECRET="Zq9$RANDOM$RANDOM"; ROLE="pgvigil_mask_$RANDOM"
CFG=$(mktemp); cleanup() { rm -f "$CFG"; psql "$ADMIN_DSN" -XAtq -c "drop role if exists $ROLE" >/dev/null 2>&1 || true; }; trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: proof-masking\n    dsn: env:ADMIN_DSN\n' > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null
[ "$(psql "$ADMIN_DSN" -XAt -c "select current_setting('pg_stat_statements.track_utility')" 2>/dev/null)" = "on" ] || echo "note: track_utility is off, the statements half of this proof cannot see the CREATE ROLE"
psql "$ADMIN_DSN" -XAtq -c "create role $ROLE login password '$SECRET'" -c "alter role $ROLE password '$SECRET'" >/dev/null
"$BIN" collect -config "$CFG" -once statements >/dev/null
"$BIN" collect -config "$CFG" -once activity >/dev/null
leak=$(q "select count(*) from (select query from pgvigil.statement_text union all select query from pgvigil.query_text) t where query like '%$SECRET%'")
[ "$leak" = "0" ] || fail "the password literal is stored in $leak text row(s)"
masked=$(q "select count(*) from pgvigil.statement_text where query ilike '%role $ROLE%' and query like '%<masked>%'")
echo "stored CREATE/ALTER ROLE texts with <masked>: $masked; rows containing the literal: $leak"
echo "proof-masking: OK"
