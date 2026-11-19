#!/bin/bash
# Proof of PGAUTH M3 (docs/postgres-signin.md, Kerberos) with no Docker: GitHub's macos-15 (Apple silicon) and
# macos-15-intel (x86_64) runners, or a Mac by hand. The same rows as scripts/proof-pg-kerberos.sh, on a KDC and a
# PostgreSQL server run here as this user: MIT krb5 from Homebrew (keg-only: krb5kdc, kdb5_util, kadmin.local, kinit)
# and postgresql@18 from Homebrew (it depends on krb5). macOS's own bash 3.2 and BSD tools. Run from the tree's root.
#
#   PGVIGIL_BIN               a pgvigil binary; default: built here (go build)
#   PGBIN, KRB_BIN, KRB_SBIN  the native tools' folders, all three given: Homebrew is not used (a Linux rig run of this
#                             same script, as the pane's box did before its first macOS run)
#   Needs: python3 and openssl; Homebrew and go unless the above are given.
# Leaves nothing of its own: the realm, the cluster, the keytabs and the caches live in the proof's own 0700 temp
# folder; the KDC and the server are stopped on every exit (read back, row Z); postgresql@18 and krb5 are uninstalled
# when this run installed them. The KDC's master password is made per run (openssl rand) and never printed.
#
# The realm PGV.TEST: principals postgres/localhost and pgsvc/localhost (the server's keytab), pgvkrb (the collector's
# keytab). The KDC listens on a free 127.0.0.1 port (TCP, udp_preference_limit = 1), the server on localhost at a free
# port (the SPN postgres/localhost). The repository is a database of the same cluster over its socket (trust). The
# server's pg_hba:
#   local all all trust
#   host  all pgvkrb  all gss include_realm=0 krb_realm=PGV.TEST
#   host  all pgvigil all gss include_realm=0 krb_realm=PGV.TEST
# the roles pgvkrb and pgvigil LOGIN with pg_monitor and no password.
#
# Expected (written before the first run, 2026-11-19):
#  D  the machine, the PostgreSQL and krb5 versions, the server's configure line naming --with-gssapi (a build without
#     it = NOT PROVEN, exit 2).
#  K1 the kerberos: block with the keytab and principal pgvkrb@PGV.TEST, the dsn user=pgvkrb: 'pgvigil check' OK
#     'connected: PostgreSQL ..., as pgvkrb', no WARN (gss sends no password).
#  K2 the block with a credential cache (MIT kinit -k into it): check OK as pgvkrb.
#  K5 krbsrvname=pgsvc (the SPN pgsvc/localhost, in the server's keytab): check OK as pgvkrb.
#  K6 no kerberos: block, no KRB5CCNAME: check FAIL with 'pgvigil has no Kerberos identity'.
#  K7 the dsn user=pgvigil with the principal pgvkrb (include_realm=0 maps it to pgvkrb): check FAIL with the server's
#     'GSSAPI authentication failed for user "pgvigil"'.
#  K8 a long-running collector ('pgvigil run', 200 s) on a credential cache of 1-minute tickets written anew every 30 s
#     (kinit -l 1m -k): the minute collections still end ok after 120 s, none in error.
#  C  (before K3) every PostgreSQL collection once by the keytab, each ok or skipped - a 'partial' or an 'error' is a
#     finding, listed; pg_signin among them.
#  K3 the principal's key rotated at the KDC (cpw -randkey): the old keytab's check FAIL with 'kerberos: pgvkrb@PGV.TEST
#     could not sign in at the KDC'.
#  Z  the KDC and the server stopped, read back 0 and 0.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $*" >&2; exit 1; }
VERDICT=PASS
ok() { echo "ok   $*"; }
bad() { VERDICT=FAIL; echo "FAIL $*"; }
for t in python3 openssl; do command -v "$t" >/dev/null || fail "needs $t"; done
umask 077
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pgvkrn.XXXXXX")
KDCP=; PGD=; RUNP=; KL=; BREWED=; KBREWED=
cleanup() {
  [ -n "$KL" ] && kill "$KL" 2>/dev/null || true
  [ -n "$RUNP" ] && kill "$RUNP" 2>/dev/null || true
  [ -n "$PGD" ] && { "$PGBIN/pg_ctl" -D "$PGD" -m immediate stop >/dev/null 2>&1 || true; }
  [ -n "$KDCP" ] && { kill "$KDCP" 2>/dev/null || true; wait "$KDCP" 2>/dev/null || true; }
  KLEFT=0; [ -n "$KDCP" ] && { kill -0 "$KDCP" 2>/dev/null || listening "$KP"; } && KLEFT=1
  SLEFT=0; [ -n "$PGD" ] && "$PGBIN/pg_ctl" -D "$PGD" status >/dev/null 2>&1 && SLEFT=1
  echo "Z: the KDC left $KLEFT, the server left $SLEFT"
  [ -n "$BREWED" ] && { HOMEBREW_NO_AUTO_UPDATE=1 brew uninstall postgresql@18 >/dev/null 2>&1 || true; }
  [ -n "$KBREWED" ] && { HOMEBREW_NO_AUTO_UPDATE=1 brew uninstall krb5 >/dev/null 2>&1 || true; }
  rm -rf "$WORK"
}
trap cleanup EXIT
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
listening() { python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)' "$1"; }

echo "== D: the tools ($(uname -s) $(uname -m), bash $BASH_VERSION)"
if [ -n "${PGBIN:-}" ] && [ -n "${KRB_BIN:-}" ] && [ -n "${KRB_SBIN:-}" ]; then
  HOW="the native tools given (PGBIN, KRB_BIN, KRB_SBIN)"
else
  [ "$(uname -s)" = Darwin ] || fail "not macOS ($(uname -s)), and PGBIN / KRB_BIN / KRB_SBIN are not all given"
  command -v brew >/dev/null || fail "needs Homebrew"
  BF=; [ "$(uname -m)" = x86_64 ] && BF=--force-bottle   # Intel macOS is Homebrew's Tier 3: a bottle or nothing
  brew list krb5 >/dev/null 2>&1 || KBREWED=1
  if ! brew list postgresql@18 >/dev/null 2>&1; then
    if ! HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew install $BF postgresql@18 >"$WORK/brew.log" 2>&1; then
      tail -20 "$WORK/brew.log"
      [ -n "$BF" ] && { echo "NOT PROVEN: Kerberos on $(uname -m): Homebrew has no bottle of postgresql@18 here"; exit 2; }
      fail "brew install postgresql@18"
    fi
    BREWED=1
  fi
  brew list krb5 >/dev/null 2>&1 || fail "krb5 is not installed (postgresql@18 should have brought it)"
  [ -n "$KBREWED" ] && [ -z "$BREWED" ] && KBREWED=
  PGBIN="$(brew --prefix postgresql@18)/bin"; KRB_BIN="$(brew --prefix krb5)/bin"; KRB_SBIN="$(brew --prefix krb5)/sbin"
  HOW="Homebrew: postgresql@18 $(brew list --versions postgresql@18 | cut -d' ' -f2), krb5 $(brew list --versions krb5 | cut -d' ' -f2)"
fi
for f in "$PGBIN/postgres" "$PGBIN/initdb" "$PGBIN/pg_ctl" "$PGBIN/psql" "$KRB_SBIN/krb5kdc" "$KRB_SBIN/kdb5_util" "$KRB_SBIN/kadmin.local" "$KRB_BIN/kinit"; do
  [ -x "$f" ] || fail "$f is not there"
done
if [ -x "$PGBIN/pg_config" ]; then
  "$PGBIN/pg_config" --configure | grep -q -- '--with-gssapi' || { echo "NOT PROVEN: this PostgreSQL ($("$PGBIN/postgres" --version)) is built without GSSAPI"; exit 2; }
  GSSB="its configure line names --with-gssapi"
else GSSB="its configure line unread (no pg_config)"; fi
echo "   $HOW; $("$PGBIN/postgres" --version), $GSSB; $("$KRB_BIN/krb5-config" --version 2>/dev/null || echo 'krb5-config absent')"
if [ -n "${PGVIGIL_BIN:-}" ]; then BIN=$PGVIGIL_BIN; else command -v go >/dev/null || fail "go is not on this machine and PGVIGIL_BIN is not set"
  CGO_ENABLED=0 go build -trimpath -o "$WORK/pgvigil" ./cmd/pgvigil || fail "go build"; BIN=$WORK/pgvigil; fi
psql() { "$PGBIN/psql" "$@"; }

KP=$(freeport); PORT=$(freeport)
echo "== the KDC (realm PGV.TEST, TCP on 127.0.0.1:$KP)"
mkdir -p "$WORK/kdc"
printf '[libdefaults]\n  default_realm = PGV.TEST\n  dns_lookup_kdc = false\n  rdns = false\n  udp_preference_limit = 1\n[realms]\n  PGV.TEST = {\n    kdc = 127.0.0.1:%s\n    admin_server = 127.0.0.1\n  }\n' "$KP" > "$WORK/krb5.conf"
printf '[kdcdefaults]\n  kdc_listen = 127.0.0.1:%s\n  kdc_tcp_listen = 127.0.0.1:%s\n[realms]\n  PGV.TEST = {\n    database_name = %s/kdc/principal\n    key_stash_file = %s/kdc/stash\n    acl_file = %s/kdc/kadm5.acl\n  }\n[logging]\n  kdc = FILE:%s/kdc/kdc.log\n' \
  "$KP" "$KP" "$WORK" "$WORK" "$WORK" "$WORK" > "$WORK/kdc/kdc.conf"
: > "$WORK/kdc/kadm5.acl"
kenv() { KRB5_CONFIG="$WORK/krb5.conf" KRB5_KDC_PROFILE="$WORK/kdc/kdc.conf" "$@"; }
MASTER=$(openssl rand -hex 12)
kenv "$KRB_SBIN/kdb5_util" create -s -r PGV.TEST -P "$MASTER" >"$WORK/kdc/create.log" 2>&1 || { tail -5 "$WORK/kdc/create.log"; fail "the realm was not made"; }
MASTER=
for p in postgres/localhost pgsvc/localhost pgvkrb; do kenv "$KRB_SBIN/kadmin.local" -q "addprinc -randkey $p" >/dev/null 2>&1 || fail "addprinc $p"; done
kenv "$KRB_SBIN/kadmin.local" -q "ktadd -k $WORK/server.keytab postgres/localhost pgsvc/localhost" >/dev/null 2>&1 || fail "the server's keytab"
kenv "$KRB_SBIN/kadmin.local" -q "ktadd -k $WORK/client.keytab pgvkrb" >/dev/null 2>&1 || fail "the collector's keytab"
KRB5_CONFIG="$WORK/krb5.conf" KRB5_KDC_PROFILE="$WORK/kdc/kdc.conf" "$KRB_SBIN/krb5kdc" -n -r PGV.TEST >"$WORK/kdc/krb5kdc.out" 2>&1 & KDCP=$!
up=0; for _ in $(seq 1 30); do listening "$KP" && { up=1; break; }; sleep 1; done
[ "$up" = 1 ] || { tail -5 "$WORK/kdc/krb5kdc.out" "$WORK/kdc/kdc.log" 2>/dev/null; fail "the KDC did not listen"; }

echo "== the monitored server ($("$PGBIN/postgres" --version | sed 's/^postgres //'), gss for pgvkrb and pgvigil) and the store"
PGD=$WORK/pgdata
"$PGBIN/initdb" -D "$PGD" -U postgres -A trust >"$WORK/initdb.log" 2>&1 || { tail -20 "$WORK/initdb.log"; PGD=; fail "initdb"; }
printf 'local all all trust\nhost all pgvkrb all gss include_realm=0 krb_realm=PGV.TEST\nhost all pgvigil all gss include_realm=0 krb_realm=PGV.TEST\n' > "$PGD/pg_hba.conf"
KRB5_CONFIG="$WORK/krb5.conf" "$PGBIN/pg_ctl" -D "$PGD" -l "$WORK/pg.log" -w -o "-p $PORT -k $WORK -c listen_addresses=localhost -c krb_server_keyfile=FILE:$WORK/server.keytab" start >/dev/null \
  || { tail -20 "$WORK/pg.log"; fail "pg_ctl start"; }
SOCK="host=$WORK port=$PORT user=postgres"
psql "$SOCK dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c 'CREATE ROLE pgvkrb LOGIN' -c 'CREATE ROLE pgvigil LOGIN' -c 'GRANT pg_monitor TO pgvkrb, pgvigil' -c 'CREATE DATABASE pgvstore' >/dev/null || fail "the roles and the store were not made"
export PGVIGIL_REPO_DSN="$SOCK dbname=pgvstore"
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$WORK/m.yaml"
"$BIN" migrate -config "$WORK/m.yaml" > "$WORK/migrate.out" 2>&1 || { tail -3 "$WORK/migrate.out"; fail "the store did not migrate"; }
unset KRB5CCNAME KRB5_KTNAME KRB5_CONFIG KRB5_KDC_PROFILE

# yml <name> <user> <the kerberos: block or nothing> [dsn extra]: the file; check <name>: 'pgvigil check' on it
yml() { { printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\n'; [ -z "$3" ] || printf '%s\n' "$3"
  printf 'instances:\n  - name: %s\n    engine: postgres\n    dsn: "host=localhost port=%s dbname=postgres user=%s sslmode=disable connect_timeout=10%s"\n' "$1" "$PORT" "$2" "${4:+ $4}"; } > "$WORK/$1.yaml"; }
check() { set +e; "$BIN" check -config "$WORK/$1.yaml" > "$WORK/$1.check" 2>&1; echo "exit $?" >> "$WORK/$1.check"; set -e; }
has() { grep -qF -- "$2" "$WORK/$1.check"; }
okrow() { check "$2"; if has "$2" "OK   instance $2: connected: PostgreSQL" && has "$2" "as pgvkrb" && ! has "$2" "WARN instance $2"; then ok "$1: check OK as pgvkrb, no WARN"; else bad "$1: want check OK as pgvkrb and no WARN"; sed 's/^/     /' "$WORK/$2.check"; fi; }
failrow() { check "$2"; if has "$2" "FAIL instance $2" && has "$2" "$3"; then ok "$1: FAIL with '$3'"; else bad "$1: want a FAIL with '$3'"; sed 's/^/     /' "$WORK/$2.check"; fi; }
kinit_() { KRB5_CONFIG="$WORK/krb5.conf" "$KRB_BIN/kinit" "$@"; }
KT="kerberos:
  keytab: $WORK/client.keytab
  principal: pgvkrb@PGV.TEST
  krb5_conf: $WORK/krb5.conf"
echo "== K: Kerberos"
yml k1 pgvkrb "$KT"; okrow K1 k1
kinit_ -k -t "$WORK/client.keytab" -c "FILE:$WORK/client.ccache" pgvkrb@PGV.TEST >/dev/null 2>&1 || bad "K2: kinit -k"
yml k2 pgvkrb "kerberos:
  ccache: $WORK/client.ccache
  krb5_conf: $WORK/krb5.conf"; okrow K2 k2
yml k5 pgvkrb "$KT" "krbsrvname=pgsvc"; okrow K5 k5
yml k6 pgvkrb ""; failrow K6 k6 "pgvigil has no Kerberos identity"
yml k7 pgvigil "$KT"; failrow K7 k7 'GSSAPI authentication failed for user "pgvigil"'

echo "== K8: a long-running collector on a credential cache of 1-minute tickets, a new cache every 30 s"
kc() { kinit_ -l 1m -k -t "$WORK/client.keytab" -c "FILE:$WORK/k8.ccache.new" pgvkrb@PGV.TEST && mv "$WORK/k8.ccache.new" "$WORK/k8.ccache"; }
kc >/dev/null 2>&1 || bad "K8: the first kinit"
( for _ in 1 2 3 4 5 6 7; do sleep 30; kc >/dev/null 2>&1 || echo "K8: a kinit failed" >> "$WORK/k8.loop"; done ) & KL=$!
yml k8 pgvkrb "kerberos:
  ccache: $WORK/k8.ccache
  krb5_conf: $WORK/krb5.conf"
K8T0=$(date -u +%s)
"$BIN" run -config "$WORK/k8.yaml" > "$WORK/k8.run" 2>&1 & RUNP=$!
sleep 200; kill "$RUNP" 2>/dev/null || true; wait "$RUNP" 2>/dev/null || true; RUNP=
kill "$KL" 2>/dev/null || true; wait "$KL" 2>/dev/null || true; KL=
K8=$(psql "$PGVIGIL_REPO_DSN" -XAt -F '|' -c "select count(*) filter (where d.status = 'ok' and d.snapshot_at > to_timestamp($K8T0 + 120)), count(*) filter (where d.status = 'error') from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'k8' and d.collection in ('activity', 'dbstats', 'connections', 'waits')")
KF=0; [ -f "$WORK/k8.loop" ] && KF=$(grep -c . "$WORK/k8.loop")
echo "   K8: minute collections ok after 120 s | in error: $K8; $KF failed kinit(s)"
IFS='|' read -r K8OK K8ERR <<<"$K8"
if [ "${K8OK:-0}" -ge 2 ] && [ "${K8ERR:-1}" = 0 ]; then ok "K8: the minute collections ok past the first ticket's minute, none in error"
else bad "K8: want 2 or more minute collections ok after 120 s and none in error"; grep -iE 'kerberos|gss' "$WORK/k8.run" | tail -5 | sed 's/^/     /'; fi

echo "== C: every PostgreSQL collection once, by the keytab"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -F '|' -c "$1"; }
COLLS=$("$BIN" collect -config "$WORK/k1.yaml" -once no_such_collection 2>&1 | grep -o 'known: \[[^]]*\]' | tr -d '[]' | tr ' ' '\n' | grep -v '^mssql_\|^known:' | grep . || true)
if [ "$(printf '%s\n' "$COLLS" | grep -c .)" -ge 20 ]; then
  for c in $COLLS; do "$BIN" collect -config "$WORK/k1.yaml" -once "$c" -instance k1 >> "$WORK/c.out" 2>&1 || true; done
  BADC=$(q "select d.collection || ' ' || d.status || ' ' || left(coalesce(d.note, ''), 120) from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'k1' and d.status not in ('ok', 'skipped') order by 1")
  NC=$(q "select count(*) from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'k1'")
  if [ -z "$BADC" ]; then ok "C: $NC collections by the keytab, each ok or skipped"; else bad "C: not ok or skipped:"; printf '%s\n' "$BADC" | sed 's/^/     /'; fi
else bad "C: the PostgreSQL collections were not listed"; fi

echo "== K3: the principal's key rotated at the KDC"
KRB5_CONFIG="$WORK/krb5.conf" KRB5_KDC_PROFILE="$WORK/kdc/kdc.conf" "$KRB_SBIN/kadmin.local" -q "cpw -randkey pgvkrb" >/dev/null 2>&1 || bad "K3: the key was not rotated"
yml k3 pgvkrb "$KT"; failrow K3 k3 "kerberos: pgvkrb@PGV.TEST could not sign in at the KDC"
echo "proof-pg-kerberos-native: $VERDICT"
[ "$VERDICT" = PASS ]
