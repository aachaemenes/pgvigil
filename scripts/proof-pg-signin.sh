#!/usr/bin/env bash
# Proof of PGAUTH M1 and M2 (docs/postgres-signin.md): a pg_monitor read login with no password role of its own signs in by
# pg_hba's ldap, radius and pam methods, and pgvigil's guard warns - never refuses - when such a method signs in
# without sslmode=verify-full. Containers only, on one docker network of the proof's own; nothing else is touched.
#
#   PG             the PostgreSQL major of the monitored server (default 18)
#   LDAP_IMG       the directory (default osixia/openldap:1.5.0, MIT; run only, never shipped)
#   RADIUS_IMG     the RADIUS server (default freeradius/freeradius-server:3.2.7, GPL-2.0; run only, never shipped)
#   PGVIGIL_BIN    a pgvigil binary; default: built here (go build)
#   Needs: docker, psql, openssl; go without PGVIGIL_BIN.
# The image digests are printed (row D) so a run can be repeated on the same bytes.
# Every password and secret is made per run (openssl rand) and reaches a container through its environment or a file
# in the proof's own 0700 temp folder; none is printed, and every container goes at the end.
#
# The monitored server 'pg' (postgres:<PG>, TLS on with the proof's own CA: a server certificate for localhost /
# 127.0.0.1, so the box reaches it through a published 127.0.0.1 port with sslmode=verify-full), its pg_hba lines:
#   host all pgvigil  0.0.0.0/0 ldap ldapserver=ldap ldapprefix="uid=" ldapsuffix=",ou=people,dc=pgv,dc=test"
#   host all pgvrad   0.0.0.0/0 radius radiusservers=radius radiussecrets=<the proof's secret>
#   host all pgvpam   0.0.0.0/0 pam pamservice=pgvigil-proof
#   host all pgvscram 0.0.0.0/0 scram-sha-256
#   host all pgvtrust 0.0.0.0/0 trust
#   hostssl all pgvcert 0.0.0.0/0 cert          (M2: the client certificate's CN is the role; the server's ssl_ca_file the CA)
# each role LOGIN with pg_monitor and no password of its own but pgvscram's. PAM is pam_unix on an OS user of the
# container: PostgreSQL's docs warn that PAM reading /etc/shadow fails as a non-root server, so the proof puts the
# postgres account in the shadow group (the lab's own container only). The store is a second postgres:<PG>.
#
# Expected (written before the first run):
#  D  the three images pulled, their digests printed.
#  L1 ldap, sslmode=verify-full with the proof's CA: psql signs in; SYSTEM_USER = 'ldap:uid=pgvigil,ou=people,dc=pgv,dc=test';
#     pg_stat_ssl.ssl true; 'pgvigil check' on the instance: OK 'connected: PostgreSQL <PG>..., as pgvigil', no WARN.
#  L2 ldap, sslmode=require: check OK and a WARN 'the server signs this login in by ldap ... sslmode=require checks no
#     server certificate', exit 3.
#  L3 ldap, sslmode=disable: the WARN begins 'this session runs without TLS:'.
#  L4 ldap, a wrong password: check FAIL with the server's words ('LDAP authentication failed for user "pgvigil"').
#  L5 verify-full against another CA: check FAIL (the certificate is not trusted), and no WARN.
#  R1 radius, verify-full: SYSTEM_USER 'radius:pgvrad', check OK no WARN; R2 sslmode=require: the WARN 'by radius';
#     R3 a wrong password: FAIL ('RADIUS authentication failed for user "pgvrad"').
#  P1 pam, verify-full: SYSTEM_USER 'pam:pgvpam', check OK no WARN; P2 sslmode=require: the WARN 'by pam';
#     P3 a wrong password: FAIL ('PAM authentication failed for user "pgvpam"').
#  S  scram-sha-256, sslmode=prefer: SYSTEM_USER 'scram-sha-256:pgvscram', check OK, no WARN (no password crosses).
#  T  trust: SYSTEM_USER NULL, check OK, no WARN.
#  X1 (M2) cert, verify-full, the client certificate for CN=pgvcert: SYSTEM_USER 'cert:pgvcert|t' [inferred: clientname
#     defaults to CN, auth.c's CheckCertAuth sets the CN as the identity], check OK, no WARN (no password crosses);
#     X2 a certificate of another CN: FAIL 'certificate authentication failed for user "pgvcert"'; X3 sslkey naming a file
#     that is not there: FAIL in words naming the key file.
#  C  per method (ldap, radius, pam at verify-full): every PostgreSQL collection once ('collect -once'), each ok or
#     skipped - a 'partial' or an 'error' is a finding, listed; pg_signin among them ok, its stored row the method word
#     and sslmode verify-full.
#  Z  the containers and the network removed, read back 0.
set -euo pipefail
cd "$(dirname "$0")/.."
PG=${PG:-18}
LDAP_IMG=${LDAP_IMG:-osixia/openldap:1.5.0}
RADIUS_IMG=${RADIUS_IMG:-freeradius/freeradius-server:3.2.7}
fail() { echo "FAIL: $*" >&2; exit 1; }
for t in docker psql openssl; do command -v "$t" >/dev/null || fail "$t is not on this machine"; done
umask 077
WORK=$(mktemp -d); N=pgvsi$RANDOM; NET=$N-net
cleanup() {
  docker rm -f -v "$N-pg" "$N-ldap" "$N-radius" "$N-store" >/dev/null 2>&1 || true
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
secret() { openssl rand -hex 12; }
LDAP_ADMIN_PW=$(secret); LDAP_PW=$(secret); RAD_SECRET=$(secret); RAD_PW=$(secret); PAM_PW=$(secret); SCRAM_PW=$(secret)

echo "== D: the images"
for img in "postgres:$PG" "$LDAP_IMG" "$RADIUS_IMG"; do docker pull -q "$img" >/dev/null || fail "docker pull $img"; echo "   $img $(docker image inspect --format '{{index .RepoDigests 0}}' "$img")"; done
docker network create "$NET" >/dev/null

echo "== the CA, the server certificate (localhost, 127.0.0.1) and another CA"
( cd "$WORK" && mkdir certs && cd certs &&
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=pgvsi-ca -addext 'basicConstraints=critical,CA:TRUE' -keyout ca.key -out ca.pem 2>/dev/null &&
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=pgvsi-other -addext 'basicConstraints=critical,CA:TRUE' -keyout other.key -out other.pem 2>/dev/null &&
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' > server.ext &&
  openssl req -newkey rsa:2048 -nodes -subj /CN=localhost -keyout server.key -out server.csr 2>/dev/null &&
  openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -extfile server.ext -out server.pem 2>/dev/null &&
  openssl verify -CAfile ca.pem server.pem >/dev/null &&
  printf 'extendedKeyUsage=clientAuth\n' > client.ext &&
  for cn in pgvcert pgvother; do openssl req -newkey rsa:2048 -nodes -subj "/CN=$cn" -keyout "$cn.key" -out "$cn.csr" 2>/dev/null &&
    openssl x509 -req -in "$cn.csr" -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -extfile client.ext -out "$cn.pem" 2>/dev/null || exit 1; done ) || fail "the certificates were not made"

echo "== the directory (uid=pgvigil,ou=people,dc=pgv,dc=test)"
docker run -d --name "$N-ldap" --network "$NET" --network-alias ldap -e LDAP_ORGANISATION=pgv -e LDAP_DOMAIN=pgv.test \
  -e LDAP_ADMIN_PASSWORD="$LDAP_ADMIN_PW" -e LDAP_TLS=false "$LDAP_IMG" >/dev/null
for _ in $(seq 1 60); do docker exec "$N-ldap" ldapsearch -x -H ldap://localhost -b dc=pgv,dc=test -D cn=admin,dc=pgv,dc=test -w "$LDAP_ADMIN_PW" -s base >/dev/null 2>&1 && break; sleep 2; done
printf 'dn: ou=people,dc=pgv,dc=test\nobjectClass: organizationalUnit\nou: people\n\ndn: uid=pgvigil,ou=people,dc=pgv,dc=test\nobjectClass: inetOrgPerson\nuid: pgvigil\ncn: pgvigil\nsn: pgvigil\n' \
  | docker exec -i "$N-ldap" ldapadd -x -H ldap://localhost -D cn=admin,dc=pgv,dc=test -w "$LDAP_ADMIN_PW" >/dev/null || fail "the directory's entries were not added"
docker exec "$N-ldap" ldappasswd -x -H ldap://localhost -D cn=admin,dc=pgv,dc=test -w "$LDAP_ADMIN_PW" -s "$LDAP_PW" uid=pgvigil,ou=people,dc=pgv,dc=test >/dev/null || fail "the directory account's password was not set"

echo "== the RADIUS server (the user pgvrad)"
mkdir -p "$WORK/raddb"
printf 'client pgnet {\n  ipaddr = 0.0.0.0/0\n  secret = %s\n}\n' "$RAD_SECRET" > "$WORK/raddb/clients.conf"
printf 'pgvrad Cleartext-Password := "%s"\n' "$RAD_PW" > "$WORK/raddb/authorize"
chmod 644 "$WORK/raddb/clients.conf" "$WORK/raddb/authorize"
# the image's configuration folder: /etc/raddb (FreeRADIUS's own layout) or /etc/freeradius (Debian's), read from the image
RDB=$(docker run --rm --entrypoint sh "$RADIUS_IMG" -c 'for d in /etc/raddb /etc/freeradius/3.0 /etc/freeradius; do [ -f "$d/clients.conf" ] && { echo "$d"; break; }; done')
[ -n "$RDB" ] || fail "the RADIUS image holds no clients.conf in /etc/raddb or /etc/freeradius"
echo "   the RADIUS configuration folder: $RDB"
docker run -d --name "$N-radius" --network "$NET" --network-alias radius \
  -v "$WORK/raddb/clients.conf:$RDB/clients.conf:ro" -v "$WORK/raddb/authorize:$RDB/mods-config/files/authorize:ro" "$RADIUS_IMG" >/dev/null

echo "== the monitored server (postgres:$PG, TLS, the pg_hba lines above)"
mkdir -p "$WORK/pgconf"
cp "$WORK/certs/server.pem" "$WORK/certs/server.key" "$WORK/certs/ca.pem" "$WORK/pgconf/"
cat > "$WORK/pgconf/pg_hba.conf" <<EOF
local all all trust
host all pgvigil 0.0.0.0/0 ldap ldapserver=ldap ldapprefix="uid=" ldapsuffix=",ou=people,dc=pgv,dc=test"
host all pgvrad 0.0.0.0/0 radius radiusservers=radius radiussecrets=$RAD_SECRET
host all pgvpam 0.0.0.0/0 pam pamservice=pgvigil-proof
host all pgvscram 0.0.0.0/0 scram-sha-256
host all pgvtrust 0.0.0.0/0 trust
hostssl all pgvcert 0.0.0.0/0 cert
EOF
chmod 755 "$WORK/pgconf"; chmod 644 "$WORK/pgconf/"*
# as root before the image's entrypoint: the server's files the postgres account's own (a key file of another owner is
# refused), the PAM user (its password from the environment, never on a command line) and the postgres account in the
# shadow group (pam_unix reads /etc/shadow; the lab's own container only) - then the entrypoint, which starts the
# server as postgres with the TLS files and the hba file named
docker run -d --name "$N-pg" --network "$NET" -p 127.0.0.1::5432 -e POSTGRES_HOST_AUTH_METHOD=trust -e PGVSI_PAM_PW="$PAM_PW" \
  -v "$WORK/pgconf:/pgconf:ro" --entrypoint sh "postgres:$PG" -c 'set -e; mkdir -p /etc/pgvsi; cp /pgconf/server.pem /pgconf/server.key /pgconf/ca.pem /pgconf/pg_hba.conf /etc/pgvsi/
chown postgres:postgres /etc/pgvsi/*; chmod 600 /etc/pgvsi/server.key
useradd -M pgvpam; echo "pgvpam:$PGVSI_PAM_PW" | chpasswd; unset PGVSI_PAM_PW; usermod -a -G shadow postgres
printf "auth required pam_unix.so\naccount required pam_unix.so\n" > /etc/pam.d/pgvigil-proof
exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/etc/pgvsi/server.pem -c ssl_key_file=/etc/pgvsi/server.key -c ssl_ca_file=/etc/pgvsi/ca.pem -c hba_file=/etc/pgvsi/pg_hba.conf' >/dev/null
up=0; for _ in $(seq 1 90); do docker exec "$N-pg" pg_isready -q -h /var/run/postgresql >/dev/null 2>&1 && docker exec "$N-pg" psql -U postgres -XAtqc 'select 1' >/dev/null 2>&1 && { up=1; break; }; sleep 1; done
[ "$up" = 1 ] || { docker logs --tail 20 "$N-pg" 2>&1 | sed 's/^/     /'; fail "the monitored server did not start"; }
docker exec -i "$N-pg" psql -U postgres -XAtq -v ON_ERROR_STOP=1 >/dev/null <<SQL || fail "the roles were not made"
CREATE ROLE pgvigil LOGIN; CREATE ROLE pgvrad LOGIN; CREATE ROLE pgvpam LOGIN; CREATE ROLE pgvtrust LOGIN; CREATE ROLE pgvcert LOGIN;
CREATE ROLE pgvscram LOGIN PASSWORD '$SCRAM_PW';
GRANT pg_monitor TO pgvigil, pgvrad, pgvpam, pgvscram, pgvtrust, pgvcert;
SQL
PORT=$(docker port "$N-pg" 5432/tcp | sed -n '1s/.*://p')
[ "$(docker exec "$N-pg" psql -U postgres -XAtc 'show ssl')" = on ] || fail "TLS is not on in the server"

echo "== the store"
docker run -d --name "$N-store" -p 127.0.0.1::5432 -e POSTGRES_HOST_AUTH_METHOD=trust "postgres:$PG" >/dev/null
SPORT=$(docker port "$N-store" 5432/tcp | sed -n '1s/.*://p')
for _ in $(seq 1 60); do psql "host=127.0.0.1 port=$SPORT user=postgres dbname=postgres" -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 1; done
export PGVIGIL_REPO_DSN="host=127.0.0.1 port=$SPORT user=postgres dbname=postgres"
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$WORK/m.yaml"
"$BIN" migrate -config "$WORK/m.yaml" > "$WORK/migrate.out" 2>&1 || { tail -3 "$WORK/migrate.out"; fail "the store did not migrate"; }

# pf <name> <user> <password> <sslmode> [sslrootcert]: the instance's passfile and dsn (the password never inline)
# (a passfile line is matched against host=, never hostaddr=: its host field is '*')
pf() { printf '*:%s:*:%s:%s\n' "$PORT" "$2" "$3" > "$WORK/$1.pgpass"
  echo "host=localhost hostaddr=127.0.0.1 port=$PORT dbname=postgres user=$2 sslmode=$4${5:+ sslrootcert=$5} passfile=$WORK/$1.pgpass connect_timeout=10"; }
# check <name> <dsn>: 'pgvigil check' on one instance; its output and exit into $WORK/<name>.check
check() { printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: %s\n    engine: postgres\n    dsn: "%s"\n' "$1" "$2" > "$WORK/$1.yaml"
  set +e; "$BIN" check -config "$WORK/$1.yaml" > "$WORK/$1.check" 2>&1; echo "exit $?" >> "$WORK/$1.check"; set -e; }
# sysuser <dsn>: SYSTEM_USER|ssl as psql reads it - its whole output kept in SU_ALL (an error is several lines: under
# pipefail a 'head' would end the proof on SIGPIPE), the first line printed
SU_ALL=
sysuser() { SU_ALL=$(psql "$1" -XAtc "select coalesce(system_user, 'NULL') || '|' || (select ssl from pg_stat_ssl where pid = pg_backend_pid())" 2>&1) || true; printf '%s' "${SU_ALL%%$'\n'*}"; }
has() { grep -qF -- "$2" "$WORK/$1.check"; }
row() { # row <label> <name> <dsn> <system_user|ssl wanted or -> <OK|WARN|FAIL> <words>
  local label=$1 name=$2 dsn=$3 want=$4 level=$5 words=$6 got=
  [ "$want" = - ] || got=$(sysuser "$dsn")
  check "$name" "$dsn"
  local warn=; has "$name" "WARN instance $name" && warn=1
  case $level in
    OK) if [ "$want" != - ] && [ "$got" != "$want" ]; then bad "$label: SYSTEM_USER|ssl '$got', want '$want'"; sed 's/^/     psql: /' <<<"$SU_ALL"; sed 's/^/     /' "$WORK/$name.check"; return; fi
        if has "$name" "OK   instance $name" || has "$name" "OK instance $name"; then :; else bad "$label: no OK line"; sed 's/^/     /' "$WORK/$name.check"; return; fi
        if [ -n "$warn" ]; then bad "$label: a WARN where none is wanted"; sed 's/^/     /' "$WORK/$name.check"; return; fi
        ok "$label: SYSTEM_USER|ssl '$got', check OK, no WARN" ;;
    WARN) if [ -n "$warn" ] && has "$name" "$words" && has "$name" "exit 3"; then ok "$label: the WARN '$words', exit 3"; else bad "$label: want a WARN with '$words' and exit 3"; sed 's/^/     /' "$WORK/$name.check"; fi ;;
    FAIL) if has "$name" "FAIL" && has "$name" "$words" && [ -z "$warn" ]; then ok "$label: FAIL with '$words'"; else bad "$label: want a FAIL with '$words' and no WARN"; sed 's/^/     /' "$WORK/$name.check"; fi ;;
  esac
}
CA=$WORK/certs/ca.pem
echo "== L: ldap"
row L1 l1 "$(pf l1 pgvigil "$LDAP_PW" verify-full "$CA")" "ldap:uid=pgvigil,ou=people,dc=pgv,dc=test|t" OK ""
row L2 l2 "$(pf l2 pgvigil "$LDAP_PW" require)" - WARN "by ldap"
has l2 "sslmode=require checks no server certificate" || bad "L2: the WARN does not name sslmode=require"
row L3 l3 "$(pf l3 pgvigil "$LDAP_PW" disable)" - WARN "this session runs without TLS:"
row L4 l4 "$(pf l4 pgvigil wrong-password verify-full "$CA")" - FAIL 'LDAP authentication failed for user "pgvigil"'
row L5 l5 "$(pf l5 pgvigil "$LDAP_PW" verify-full "$WORK/certs/other.pem")" - FAIL "certificate"
echo "== R: radius"
row R1 r1 "$(pf r1 pgvrad "$RAD_PW" verify-full "$CA")" "radius:pgvrad|t" OK ""
row R2 r2 "$(pf r2 pgvrad "$RAD_PW" require)" - WARN "by radius"
row R3 r3 "$(pf r3 pgvrad wrong-password verify-full "$CA")" - FAIL 'RADIUS authentication failed for user "pgvrad"'
echo "== P: pam"
row P1 p1 "$(pf p1 pgvpam "$PAM_PW" verify-full "$CA")" "pam:pgvpam|t" OK ""
row P2 p2 "$(pf p2 pgvpam "$PAM_PW" require)" - WARN "by pam"
row P3 p3 "$(pf p3 pgvpam wrong-password verify-full "$CA")" - FAIL 'PAM authentication failed for user "pgvpam"'
echo "== S, T: the controls"
row S s1 "$(pf s1 pgvscram "$SCRAM_PW" prefer)" "scram-sha-256:pgvscram|t" OK ""
row T t1 "$(pf t1 pgvtrust x prefer)" "NULL|t" OK ""

echo "== X: client certificates (M2)"
cd0="host=localhost hostaddr=127.0.0.1 port=$PORT dbname=postgres user=pgvcert sslmode=verify-full sslrootcert=$CA connect_timeout=10"
row X1 x1 "$cd0 sslcert=$WORK/certs/pgvcert.pem sslkey=$WORK/certs/pgvcert.key" "cert:pgvcert|t" OK ""
row X2 x2 "$cd0 sslcert=$WORK/certs/pgvother.pem sslkey=$WORK/certs/pgvother.key" - FAIL 'certificate authentication failed for user "pgvcert"'
row X3 x3 "$cd0 sslcert=$WORK/certs/pgvcert.pem sslkey=$WORK/certs/no-such.key" - FAIL "no-such.key"

echo "== C: every PostgreSQL collection once, per method at verify-full"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -F '|' -c "$1"; }
for m in l1:ldap r1:radius p1:pam; do
  name=${m%%:*}; meth=${m#*:}
  COLLS=$("$BIN" collect -config "$WORK/$name.yaml" -once no_such_collection 2>&1 | grep -o 'known: \[[^]]*\]' | tr -d '[]' | tr ' ' '\n' | grep -v '^mssql_\|^known:' | grep . || true)
  [ "$(grep -c . <<<"$COLLS")" -ge 20 ] || { bad "C $meth: the PostgreSQL collections were not listed"; continue; }
  for c in $COLLS; do "$BIN" collect -config "$WORK/$name.yaml" -once "$c" -instance "$name" >> "$WORK/c-$name.out" 2>&1 || true; done
  BADC=$(q "select d.collection || ' ' || d.status || ' ' || left(coalesce(d.note, ''), 120) from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = '$name' and d.status not in ('ok', 'skipped') order by 1")
  NC=$(q "select count(*) from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = '$name'")
  if [ -z "$BADC" ]; then ok "C $meth: $NC collections, each ok or skipped"; else bad "C $meth: not ok or skipped:"; sed 's/^/     /' <<<"$BADC"; fi
  SI=$(q "select d.status from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = '$name' and d.collection = 'pg_signin'")
  [ "$SI" = ok ] && ok "C $meth: pg_signin ok" || bad "C $meth: pg_signin '$SI'"
done
echo "proof-pg-signin: $VERDICT"
[ "$VERDICT" = PASS ]
