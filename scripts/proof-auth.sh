#!/usr/bin/env bash
# Proof of the UI login (migration 0015) and the TLS listen, on a throwaway repository.
#   PGVIGIL_REPO_DSN  repository owner connection (creates and drops two logins and one UI user)
# Expected: migrate applies 0015; `pgvigil user add` stores a $argon2id$ hash and `user list` shows the
# row; a pgvigil_reader-only login gets permission denied on ui_users and on ui_password_hash(); a
# reader+auth login gets the hash and still cannot read ui_users; serve with a reader-only login refuses
# to start naming GRANT pgvigil_auth; a 0.0.0.0 listen without TLS refuses naming -tls-cert; -no-login
# beyond loopback refuses; on loopback with the login: GET /api/instances 401, GET / 200, POST
# /api/login without the header 403, a wrong password 401, the right one 200 with an HttpOnly
# SameSite=Strict cookie without Secure (http), the cookie opens /api/instances (200) and names the user
# in /api/session, logout 204 and the cookie is dead (401), a disabled user 401 and enabled again 200, a
# changed password: old 401 new 200, five failures then 429 with Retry-After; `pgvigil cert` writes
# pgvigil.crt and a 0600 pgvigil.key and refuses to overwrite; serve with that pair on loopback answers
# https 200 with Strict-Transport-Security and a Secure cookie; plain http on the TLS port is 400.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
RO="pgvigil_it_ro_$RANDOM"; UI="pgvigil_it_ui_$RANDOM"; PW="pw$RANDOM$RANDOM"
USR="proofuser$RANDOM"; UPW="proof-password-$RANDOM"; UPW2="changed-password-$RANDOM"
PORT=$((20000 + RANDOM % 20000)); TLSPORT=$((PORT + 1))
CFG=$(mktemp); TMPD=$(mktemp -d); LOG=$(mktemp); SRVPID=""; CJ="$TMPD/cookies"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  "$BIN" user remove -config "$CFG" "$USR" >/dev/null 2>&1 || true
  psql "$PGVIGIL_REPO_DSN" -XAtq -c "drop role if exists $RO" -c "drop role if exists $UI" >/dev/null 2>&1 || true
  rm -rf "$CFG" "$LOG" "$TMPD"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; [[ -s "$LOG" ]] && sed 's/^/  serve: /' "$LOG" >&2; exit 1; }
HOST=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select coalesce(host(inet_server_addr()),'localhost')")
DBPORT=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select inet_server_port()")
DB=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select current_database()")
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"

"$BIN" migrate -config "$CFG" >/dev/null
psql "$PGVIGIL_REPO_DSN" -XAt -c "select 1 from pgvigil.schema_version where version = '0015_ui_login.sql'" | grep -q 1 || fail "0015 not applied"
PGVIGIL_PASSWORD="$UPW" "$BIN" user add -config "$CFG" "$USR" 2>/dev/null || fail "user add"
"$BIN" user list -config "$CFG" | grep -q "^$USR  *enabled" || fail "user list does not show $USR enabled"
[[ $(psql "$PGVIGIL_REPO_DSN" -XAt -c "select password_hash like '\$argon2id\$v=19\$%' from pgvigil.ui_users where username = '$USR'") == t ]] || fail "the stored hash is not argon2id"
if PGVIGIL_PASSWORD="short" "$BIN" user add -config "$CFG" "other$RANDOM" 2>/dev/null; then fail "a short password was accepted"; fi
if PGVIGIL_PASSWORD="$UPW" "$BIN" user add -config "$CFG" "$USR" 2>/dev/null; then fail "a second add of one name succeeded"; fi

psql "$PGVIGIL_REPO_DSN" -XAtq -c "create role $RO login password '$PW' in role pgvigil_reader" \
  -c "create role $UI login password '$PW' in role pgvigil_reader, pgvigil_auth" >/dev/null
export RO_DSN="host=$HOST port=$DBPORT user=$RO password=$PW dbname=$DB sslmode=disable"
export UI_DSN="host=$HOST port=$DBPORT user=$UI password=$PW dbname=$DB sslmode=disable"
out=$(psql "$RO_DSN" -XAt -c "select count(*) from pgvigil.ui_users" 2>&1 || true)
[[ "$out" == *"permission denied"* ]] || fail "a reader could read ui_users: $out"
out=$(psql "$RO_DSN" -XAt -c "select pgvigil.ui_password_hash('$USR')" 2>&1 || true)
[[ "$out" == *"permission denied"* ]] || fail "a reader could call ui_password_hash: $out"
out=$(psql "$UI_DSN" -XAt -c "select pgvigil.ui_password_hash('$USR')" 2>&1)
[[ "$out" == \$argon2id\$* ]] || fail "the UI login did not get the hash: $out"
out=$(psql "$UI_DSN" -XAt -c "select count(*) from pgvigil.ui_users" 2>&1 || true)
[[ "$out" == *"permission denied"* ]] || fail "the UI login could read ui_users: $out"
echo "ok: roles (reader: no table, no hash; ui: hash yes, table no)"

if "$BIN" serve -config "$CFG" -dsn env:RO_DSN -listen "127.0.0.1:$PORT" >"$LOG" 2>&1; then fail "serve started with a reader-only login"; fi
grep -q 'GRANT pgvigil_auth' "$LOG" || fail "the reader-only refusal did not name GRANT pgvigil_auth"
if "$BIN" serve -config "$CFG" -dsn env:UI_DSN -listen "0.0.0.0:$PORT" >"$LOG" 2>&1; then fail "serve started on 0.0.0.0 without TLS"; fi
grep -q 'tls-cert' "$LOG" || fail "the 0.0.0.0 refusal did not name -tls-cert"
if "$BIN" serve -config "$CFG" -dsn env:UI_DSN -listen "0.0.0.0:$PORT" -tls-cert x -tls-key y -no-login >"$LOG" 2>&1; then fail "serve started on 0.0.0.0 with -no-login"; fi
grep -q 'no-login is allowed on a loopback' "$LOG" || fail "the -no-login refusal text"
echo "ok: refusals (reader-only login, 0.0.0.0 without TLS, -no-login beyond loopback)"

: > "$LOG"
"$BIN" serve -config "$CFG" -dsn env:UI_DSN -listen "127.0.0.1:$PORT" >"$LOG" 2>&1 & SRVPID=$!
U="http://127.0.0.1:$PORT"
for _ in $(seq 1 50); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || fail "serve exited"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
login() { # login <user> <password> [curl args]; prints the status code; the cookie jar is written
  curl -s -o "$TMPD/body" -w '%{http_code}' -c "$CJ" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' \
    --data "{\"username\":\"$1\",\"password\":\"$2\"}" "${@:3}" "$U/api/login"
}
[[ $(code "$U/api/instances") == 401 ]] || fail "instances without a session was not 401"
[[ $(code "$U/api/health") == 401 ]] || fail "health without a session was not 401"
[[ $(code "$U/") == 200 ]] || fail "the shell was not public"
[[ $(code "$U/api/session") == 401 ]] || fail "session without a cookie was not 401"
[[ $(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data "{\"username\":\"$USR\",\"password\":\"$UPW\"}" "$U/api/login") == 403 ]] || fail "login without the header was not 403"
[[ $(login "$USR" "not-the-password-1") == 401 ]] || fail "a wrong password was not 401"
[[ $(login "nobody$RANDOM" "$UPW") == 401 ]] || fail "an unknown user was not 401"
[[ $(login "$USR" "$UPW" -D "$TMPD/hdr") == 200 ]] || fail "the right password was not 200: $(cat "$TMPD/body")"
grep -qi '^set-cookie: pgvigil_session=.*HttpOnly' "$TMPD/hdr" || fail "the cookie is not HttpOnly: $(grep -i set-cookie "$TMPD/hdr")"
grep -qi '^set-cookie: .*SameSite=Strict' "$TMPD/hdr" || fail "the cookie is not SameSite=Strict"
if grep -qi '^set-cookie: .*Secure' "$TMPD/hdr"; then fail "a Secure cookie on plain http (the browser would drop it)"; fi
[[ $(code -b "$CJ" "$U/api/instances") == 200 ]] || fail "instances with the cookie was not 200"
curl -s -b "$CJ" "$U/api/session" | grep -q "\"user\":\"$USR\"" || fail "session does not name the user"
[[ $(code -b "$CJ" -H 'X-Pgvigil: 1' -X POST "$U/api/logout") == 204 ]] || fail "logout was not 204"
[[ $(code -b "$CJ" "$U/api/instances") == 401 ]] || fail "the cookie survived logout"
"$BIN" user disable -config "$CFG" "$USR" 2>/dev/null
[[ $(login "$USR" "$UPW") == 401 ]] || fail "a disabled user logged in"
"$BIN" user enable -config "$CFG" "$USR" 2>/dev/null
[[ $(login "$USR" "$UPW") == 200 ]] || fail "an enabled user could not log in"
PGVIGIL_PASSWORD="$UPW2" "$BIN" user passwd -config "$CFG" "$USR" 2>/dev/null
[[ $(login "$USR" "$UPW") == 401 ]] || fail "the old password still works"
[[ $(login "$USR" "$UPW2") == 200 ]] || fail "the new password does not work"
for i in 1 2 3 4 5; do [[ $(login "$USR" "wrong-$i-$RANDOM") == 401 ]] || fail "failure $i was not 401"; done
[[ $(login "$USR" "$UPW2" -D "$TMPD/hdr") == 429 ]] || fail "the sixth attempt was not 429"
grep -qi '^retry-after: [0-9]' "$TMPD/hdr" || fail "429 without Retry-After"
echo "ok: login on loopback (401/403/401/200+cookie/200/204/401, disable, passwd, 429)"
kill "$SRVPID"; wait "$SRVPID" 2>/dev/null || true; SRVPID=""

"$BIN" cert -out "$TMPD" -hosts localhost,127.0.0.1 >/dev/null || fail "pgvigil cert"
[[ -s "$TMPD/pgvigil.crt" && -s "$TMPD/pgvigil.key" ]] || fail "cert files missing"
[[ $(stat -c %a "$TMPD/pgvigil.key") == 600 ]] || fail "key mode $(stat -c %a "$TMPD/pgvigil.key"), want 600"
if "$BIN" cert -out "$TMPD" >/dev/null 2>&1; then fail "cert overwrote an existing pair"; fi
: > "$LOG"
"$BIN" serve -config "$CFG" -dsn env:UI_DSN -listen "127.0.0.1:$TLSPORT" -tls-cert "$TMPD/pgvigil.crt" -tls-key "$TMPD/pgvigil.key" >"$LOG" 2>&1 & SRVPID=$!
T="https://127.0.0.1:$TLSPORT"
for _ in $(seq 1 50); do curl -sk -o /dev/null "$T/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || fail "TLS serve exited"
curl -sk -D "$TMPD/hdr" "$T/" | grep -q '<title>pgvigil</title>' || fail "the shell over TLS"
grep -qi '^strict-transport-security: max-age=' "$TMPD/hdr" || fail "no HSTS header over TLS"
[[ $(curl -sk -o /dev/null -w '%{http_code}' -D "$TMPD/hdr" -c "$CJ" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "{\"username\":\"$USR\",\"password\":\"$UPW2\"}" "$T/api/login") == 200 ]] || fail "login over TLS"
grep -qi '^set-cookie: pgvigil_session=.*Secure' "$TMPD/hdr" || fail "the cookie over TLS is not Secure"
plain=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TLSPORT/" || true)
[[ "$plain" == 400 || "$plain" == 000 ]] || fail "plain http on the TLS port answered $plain"
echo "ok: TLS (cert 0600, no overwrite, https 200, HSTS, Secure cookie, plain http refused)"
echo "proof-auth: OK"
