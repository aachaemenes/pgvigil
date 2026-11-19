#!/usr/bin/env bash
# Proof of PGAUTH M3 (docs/postgres-signin.md, Kerberos): pgvigil signs in to a PostgreSQL server whose pg_hba line is
# 'gss' with the process's ONE Kerberos identity (pgvigil.yaml's kerberos: block; internal/pgkrb on gokrb5). Containers
# only, on one docker network of the proof's own; nothing else is touched.
#
#   PG          the PostgreSQL major of the monitored server (default 18)
#   KDC_IMG     the KDC's base image (default debian:12-slim: MIT krb5-kdc and krb5-admin-server installed in it at the
#               run; run only, never shipped)
#   PGVIGIL_BIN a pgvigil binary; default: built here (go build)
#   Needs: docker, psql; go without PGVIGIL_BIN.
# The image digests are printed (row D). The KDC's master password is made per run (openssl rand) and stays in its
# container; the keytabs and the credential cache are files in the proof's own 0700 temp folder.
#
# The realm PGV.TEST: principals postgres/localhost and pgsvc/localhost (the server's keytab), pgvkrb (the collector's
# keytab). The client reaches the KDC over TCP on a published 127.0.0.1 port (udp_preference_limit = 1), the server on
# its own published port as host=localhost (the SPN postgres/localhost). The server's pg_hba:
#   local all all trust
#   host  all pgvkrb  0.0.0.0/0 gss include_realm=0 krb_realm=PGV.TEST
#   host  all pgvigil 0.0.0.0/0 gss include_realm=0 krb_realm=PGV.TEST
# the roles pgvkrb and pgvigil LOGIN with pg_monitor and no password.
#
# Expected (written before the first run):
#  D  the two images pulled, their digests printed.
#  K1 the kerberos: block with the keytab and principal pgvkrb@PGV.TEST, the dsn user=pgvkrb: 'pgvigil check' OK
#     'connected: PostgreSQL <PG>..., as pgvkrb', no WARN (gss sends no password).
#  K2 the block with a credential cache (kinit -k into it, in the KDC's container): check OK as pgvkrb.
#  K5 krbsrvname=pgsvc (the SPN pgsvc/localhost, in the server's keytab): check OK as pgvkrb.
#  K6 no kerberos: block, no KRB5CCNAME: check FAIL with 'pgvigil has no Kerberos identity'.
#  K7 the dsn user=pgvigil with the principal pgvkrb (include_realm=0 maps it to pgvkrb): check FAIL with the server's
#     'GSSAPI authentication failed for user "pgvigil"'.
#  K3 the principal's key rotated at the KDC (cpw -randkey): the old keytab's check FAIL with 'kerberos: pgvkrb@PGV.TEST
#     could not sign in at the KDC'.
#  C  (before K3) every PostgreSQL collection once by the keytab, each ok or skipped - a 'partial' or an 'error' is a
#     finding, listed; pg_signin among them.
#  Z  the containers and the network removed, read back 0.
set -euo pipefail
cd "$(dirname "$0")/.."
PG=${PG:-18}
KDC_IMG=${KDC_IMG:-debian:12-slim}
fail() { echo "FAIL: $*" >&2; exit 1; }
for t in docker psql openssl; do command -v "$t" >/dev/null || fail "$t is not on this machine"; done
umask 077
WORK=$(mktemp -d); N=pgvkr$RANDOM; NET=$N-net
cleanup() {
  docker rm -f -v "$N-kdc" "$N-pg" "$N-store" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  echo "Z: containers left $(docker ps -aq --filter name=$N | wc -l), networks left $(docker network ls -q --filter name=$NET | wc -l)"
  rm -rf "$WORK"
}
trap cleanup EXIT
VERDICT=PASS
ok() { echo "ok   $*"; }
bad() { VERDICT=FAIL; echo "FAIL $*"; }
if [ -n "${PGVIGIL_BIN:-}" ]; then BIN=$PGVIGIL_BIN; else command -v go >/dev/null || fail "go is not on this machine and PGVIGIL_BIN is not set"
  CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil; BIN=$WORK/pgvigil; fi
for _ in $(seq 1 20); do KP=$((20000 + RANDOM % 20000)); ss -ltn 2>/dev/null | grep -q ":$KP\b" || break; done

echo "== D: the images"
for img in "postgres:$PG" "$KDC_IMG"; do docker pull -q "$img" >/dev/null || fail "docker pull $img"; echo "   $img $(docker image inspect --format '{{index .RepoDigests 0}}' "$img")"; done
docker network create "$NET" >/dev/null
mkdir -p "$WORK/krb"; chmod 777 "$WORK/krb"   # the KDC's container writes the keytabs here as its root

echo "== the KDC (realm PGV.TEST, TCP on 127.0.0.1:$KP)"
printf '[libdefaults]\n  default_realm = PGV.TEST\n  dns_lookup_kdc = false\n  rdns = false\n  udp_preference_limit = 1\n[realms]\n  PGV.TEST = {\n    kdc = localhost\n    admin_server = localhost\n  }\n' > "$WORK/krb/kdc-krb5.conf"
chmod 644 "$WORK/krb/kdc-krb5.conf"
docker run -d --name "$N-kdc" --network "$NET" --network-alias kdc -p "127.0.0.1:$KP:88/tcp" -e PGVKR_MASTER="$(openssl rand -hex 12)" \
  -v "$WORK/krb:/out" "$KDC_IMG" sleep infinity >/dev/null
docker exec "$N-kdc" sh -c 'apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq krb5-kdc krb5-admin-server >/dev/null' || fail "the KDC's packages did not install"
docker exec "$N-kdc" sh -c 'set -e; cp /out/kdc-krb5.conf /etc/krb5.conf
  printf "[kdcdefaults]\n  kdc_tcp_listen = 88\n  kdc_listen = 88\n[realms]\n  PGV.TEST = {\n    database_name = /var/lib/krb5kdc/principal\n    key_stash_file = /etc/krb5kdc/stash\n  }\n" > /etc/krb5kdc/kdc.conf
  kdb5_util create -s -r PGV.TEST -P "$PGVKR_MASTER" >/dev/null 2>&1; unset PGVKR_MASTER
  for p in postgres/localhost pgsvc/localhost pgvkrb; do kadmin.local -q "addprinc -randkey $p" >/dev/null; done
  kadmin.local -q "ktadd -k /out/server.keytab postgres/localhost pgsvc/localhost" >/dev/null
  kadmin.local -q "ktadd -k /out/client.keytab pgvkrb" >/dev/null
  chmod 644 /out/server.keytab /out/client.keytab' || fail "the realm was not made"
docker exec -d "$N-kdc" krb5kdc -n
for _ in $(seq 1 30); do (exec 3<>/dev/tcp/127.0.0.1/$KP) 2>/dev/null && break; sleep 1; done
printf '[libdefaults]\n  default_realm = PGV.TEST\n  dns_lookup_kdc = false\n  rdns = false\n  udp_preference_limit = 1\n[realms]\n  PGV.TEST = {\n    kdc = 127.0.0.1:%s\n  }\n' "$KP" > "$WORK/krb5.conf"
cp "$WORK/krb/client.keytab" "$WORK/client.keytab"; chmod 600 "$WORK/client.keytab"

echo "== the monitored server (postgres:$PG, gss for pgvkrb and pgvigil)"
mkdir -p "$WORK/pgconf"
printf 'local all all trust\nhost all pgvkrb 0.0.0.0/0 gss include_realm=0 krb_realm=PGV.TEST\nhost all pgvigil 0.0.0.0/0 gss include_realm=0 krb_realm=PGV.TEST\n' > "$WORK/pgconf/pg_hba.conf"
cp "$WORK/krb/server.keytab" "$WORK/krb/kdc-krb5.conf" "$WORK/pgconf/"
chmod 755 "$WORK/pgconf"; chmod 644 "$WORK/pgconf/"*
docker run -d --name "$N-pg" --network "$NET" -p 127.0.0.1::5432 -e POSTGRES_HOST_AUTH_METHOD=trust -e KRB5_CONFIG=/etc/pgvsi/kdc-krb5.conf \
  -v "$WORK/pgconf:/pgconf:ro" --entrypoint sh "postgres:$PG" -c 'set -e; mkdir -p /etc/pgvsi; cp /pgconf/* /etc/pgvsi/
chown postgres:postgres /etc/pgvsi/*; chmod 600 /etc/pgvsi/server.keytab
exec docker-entrypoint.sh postgres -c krb_server_keyfile=FILE:/etc/pgvsi/server.keytab -c hba_file=/etc/pgvsi/pg_hba.conf' >/dev/null
up=0; for _ in $(seq 1 90); do docker exec "$N-pg" psql -U postgres -XAtqc 'select 1' >/dev/null 2>&1 && { up=1; break; }; sleep 1; done
[ "$up" = 1 ] || { docker logs --tail 20 "$N-pg" 2>&1 | sed 's/^/     /'; fail "the monitored server did not start"; }
docker exec -i "$N-pg" psql -U postgres -XAtq -v ON_ERROR_STOP=1 >/dev/null <<'SQL' || fail "the roles were not made"
CREATE ROLE pgvkrb LOGIN; CREATE ROLE pgvigil LOGIN; GRANT pg_monitor TO pgvkrb, pgvigil;
SQL
PORT=$(docker port "$N-pg" 5432/tcp | sed -n '1s/.*://p')

echo "== the store"
docker run -d --name "$N-store" -p 127.0.0.1::5432 -e POSTGRES_HOST_AUTH_METHOD=trust "postgres:$PG" >/dev/null
SPORT=$(docker port "$N-store" 5432/tcp | sed -n '1s/.*://p')
for _ in $(seq 1 60); do psql "host=127.0.0.1 port=$SPORT user=postgres dbname=postgres" -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 1; done
export PGVIGIL_REPO_DSN="host=127.0.0.1 port=$SPORT user=postgres dbname=postgres"
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$WORK/m.yaml"
"$BIN" migrate -config "$WORK/m.yaml" > "$WORK/migrate.out" 2>&1 || { tail -3 "$WORK/migrate.out"; fail "the store did not migrate"; }
unset KRB5CCNAME KRB5_KTNAME KRB5_CONFIG

# yml <name> <user> <the kerberos: block or nothing> [dsn extra]: the file; check <name>: 'pgvigil check' on it
yml() { { printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\n'; [ -z "$3" ] || printf '%s\n' "$3"
  printf 'instances:\n  - name: %s\n    engine: postgres\n    dsn: "host=localhost port=%s dbname=postgres user=%s sslmode=disable connect_timeout=10%s"\n' "$1" "$PORT" "$2" "${4:+ $4}"; } > "$WORK/$1.yaml"; }
check() { set +e; "$BIN" check -config "$WORK/$1.yaml" > "$WORK/$1.check" 2>&1; echo "exit $?" >> "$WORK/$1.check"; set -e; }
has() { grep -qF -- "$2" "$WORK/$1.check"; }
okrow() { check "$2"; if has "$2" "OK   instance $2: connected: PostgreSQL" && has "$2" "as pgvkrb" && ! has "$2" "WARN instance $2"; then ok "$1: check OK as pgvkrb, no WARN"; else bad "$1: want check OK as pgvkrb and no WARN"; sed 's/^/     /' "$WORK/$2.check"; fi; }
failrow() { check "$2"; if has "$2" "FAIL instance $2" && has "$2" "$3"; then ok "$1: FAIL with '$3'"; else bad "$1: want a FAIL with '$3'"; sed 's/^/     /' "$WORK/$2.check"; fi; }
KT="kerberos:
  keytab: $WORK/client.keytab
  principal: pgvkrb@PGV.TEST
  krb5_conf: $WORK/krb5.conf"
echo "== K: Kerberos"
yml k1 pgvkrb "$KT"; okrow K1 k1
docker exec "$N-kdc" sh -c 'kinit -k -t /out/client.keytab -c /out/client.ccache pgvkrb@PGV.TEST && chmod 644 /out/client.ccache' || bad "K2: kinit in the KDC's container"
cp "$WORK/krb/client.ccache" "$WORK/client.ccache" 2>/dev/null && chmod 600 "$WORK/client.ccache"
yml k2 pgvkrb "kerberos:
  ccache: $WORK/client.ccache
  krb5_conf: $WORK/krb5.conf"; okrow K2 k2
yml k5 pgvkrb "$KT" "krbsrvname=pgsvc"; okrow K5 k5
yml k6 pgvkrb ""; failrow K6 k6 "pgvigil has no Kerberos identity"
yml k7 pgvigil "$KT"; failrow K7 k7 'GSSAPI authentication failed for user "pgvigil"'

echo "== C: every PostgreSQL collection once, by the keytab"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -F '|' -c "$1"; }
COLLS=$("$BIN" collect -config "$WORK/k1.yaml" -once no_such_collection 2>&1 | grep -o 'known: \[[^]]*\]' | tr -d '[]' | tr ' ' '\n' | grep -v '^mssql_\|^known:' | grep . || true)
if [ "$(grep -c . <<<"$COLLS")" -ge 20 ]; then
  for c in $COLLS; do "$BIN" collect -config "$WORK/k1.yaml" -once "$c" -instance k1 >> "$WORK/c.out" 2>&1 || true; done
  BADC=$(q "select d.collection || ' ' || d.status || ' ' || left(coalesce(d.note, ''), 120) from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'k1' and d.status not in ('ok', 'skipped') order by 1")
  NC=$(q "select count(*) from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'k1'")
  if [ -z "$BADC" ]; then ok "C: $NC collections by the keytab, each ok or skipped"; else bad "C: not ok or skipped:"; sed 's/^/     /' <<<"$BADC"; fi
else bad "C: the PostgreSQL collections were not listed"; fi

echo "== K3: the principal's key rotated at the KDC"
docker exec "$N-kdc" kadmin.local -q "cpw -randkey pgvkrb" >/dev/null || bad "K3: the key was not rotated"
yml k3 pgvkrb "$KT"; failrow K3 k3 "kerberos: pgvkrb@PGV.TEST could not sign in at the KDC"
echo "proof-pg-kerberos: $VERDICT"
[ "$VERDICT" = PASS ]
