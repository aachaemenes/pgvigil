#!/usr/bin/env bash
# proof-collector-health.sh - task 201: the collector seen working (migration 0121, internal/collect/heartbeat.go, the
# Collector page). Needs: docker (a systemd container: --privileged, cgroup v2), psql, curl, python3, node, chromium,
# go and npm (unless PGVIGIL_BIN names a built binary with the web UI in it).
#
# The rig: a docker network with a repository (PostgreSQL 18), a target server (PostgreSQL 18: four databases, four
# logins: the instances t1-t4) and a Debian container running systemd, its hostname pgvigil-svc, where pgvigil runs as
# the shipped unit deploy/pgvigil.service (a drop-in only makes the alert spool writable). On this host: `pgvigil serve`
# (its collector watchdog on) and the checks. Every alert goes to a file channel (critical, sent once, cleared at once)
# whose directory both write.
#   A  the heartbeat: a 'systemd unit' collector on pgvigil-svc is up; each instance's runs counted (connections per
#      minute, runs, no failure); every collection's runs, rows and durations; the repository part answers
#   E  a login refused: t2's password changed at the source - t2's 'logins refused' counted; exactly ONE alert on the
#      channel that covers t2 ('authentication failing': the runs that failed at the connect build no 'collection
#      failing'), none on the channel scoped to t1, no 'collector or network'; the service restarted while t2 is still
#      refused: no alert key fired twice, nothing resolved; the password back and the service restarted again: t2's
#      'authentication failing' gone and resolved once, its 'collection failing' within t1's (the plain target's own:
#      some collections fail on every plain target)
#   H  the page: #/collector in both themes (shots), every link on it clicked with its landing (an instance link opens
#      its Collection dates with the collector's line, the line's link comes back), the tree's Collector node, the
#      chart's menu
#   D  failing together (t1-t3 run 'activity' every 10 s; every cut is refused logins - t1-t4 are four databases of
#      one server, so dropped packets for some of them cannot be made here; the cut's second is pinned; the files are
#      counted before and after the lift; each case's spool is kept under .vis/spool-evidence/<case>):
#      D1  t1-t3 cut at :20 for 6 min: the parent once on U (unscoped) and S (scoped to t1) within the cut + 3:05, t1-t3
#          nothing; after the lift the parent resolved once, t1-t3 nothing. D1b the same cut at :55 for 4 min.
#      D2  t1-t3 cut :10 to :50 of one minute: nothing sent, nothing resolved.
#      D3  t1, t2 cut (2 of 4): no parent; 'authentication failing' once each (S: t1 once) within the cut + 2:05; no
#          'collection failing'; resolved once each after.
#      D4  t1 refused first (its alert open on U, S and R - R repeats every 5 min), then t2, t3: during the hold R
#          repeats the parent and not t1, nothing resolves; after the lift t1 resolved once and R repeats it 0 times
#          (its finding stands until the next clean minute is written; the repeat waits inside the window).
#      D5  t1-t3 cut, t1 t2 back, t3 kept: the parent resolves; t3's 'authentication failing' once, 240-480 s after
#          t1 t2 came back (DONE-2 N2: the parent clears the minute after; t3 is handed back once its newest failure is
#          span + 4 minutes past the last minute the three failed together); t1, t2 nothing.
#      DQ  a channel Q in quiet hours from the cut's minute - 1 to its minute + 3: the parent once on Q after the quiet
#          end, t1-t3 nothing.
#   F  many collectors: a second `pgvigil run` on this host collecting the same instances is not refused (the page: 2
#      up); each instance 'collected by more than one collector'
#   B  the service stopped: the page says stopped at once; after 5 minutes 'collector or network' (collector not seen),
#      and serve's watchdog sends it (the collector that would is the one stopped); started again: up, cleared
#   G  purge: 'purge not run in 2 days' on an instance seen 3 days ago; `pgvigil purge` records its run (an old
#      partition dropped and named); the finding gone
#   SC the scale arm (task 201 DONE-2), last: eight more databases and logins on the target server (t5-t12), the
#      service restarted on 12 instances, each with 'activity' every 10 s:
#      SC5  5 of 12 cut (under half: only the 5-or-more arm can raise the parent): the parent once on U and S, its
#           text '5 of the 12', the five's own alerts 0; after the lift the parent resolved once, the five nothing.
#      SC6  5 standing + 1 new (DONE-2 N2: the parent only on failures that BEGAN together): t1-t5 refused one after
#           another 5 minutes apart, then t6 - no parent at any time, nothing held, nothing forming; 'authentication
#           failing' once each (S: t1 once); after the logins come back resolved once each.
#      SC4  4 of 12 cut: no parent, nothing held; 'authentication failing' once each (S: t1 once); resolved once each.
#      BH   a black-holed server (DONE-2 N10): t13 at 192.0.2.1 (TEST-NET-1) with no connect_timeout - its first failed
#           connect within 45 s of the service's restart (the 10 s default; the operating system alone waits about
#           127 s), a timeout in its error, 'server unreachable' once on U two alert passes after the first, no
#           'collection failing'; then the 12-instance file back.
#      SV   a second target server (DONE-2 N8): target2 with t16-t18 stopped - the server's own parent, once, claiming
#           'server postgres:target2:5432 not answering from <T> UTC', t16-t18 held, t1-t12 not; started again, resolved once, none of t16-t18's own alerts after.
#      SC7  slow connects shared (the slow-connect tier's host fold): t1-t12 dialled through a proxy container (slowp)
#           on four ports, three instances each, that holds every new connection 2 s before it forwards it; the root's
#           connect_time threshold set to 0.10 / 0.10 s for SC7 and SL (warning = critical: the channels here send
#           critical only, and a slow member is then critical with its fold - none can stand above a warning fold,
#           where it is rightly sent on its own; one slow minute in the 5-minute window averages 0.2 s or more) - ONE
#           'slow connects' valued pgvigil-svc on U and S (repository-wide), critical, its four server folds held
#           under it, its 12 members held, no 'slow connect' sent; the delay lifted at :57 (a held connect ends before
#           the minute turns): resolved once (the last slow minute leaves the window about 5 minutes later), no
#           member's alert after it.
#      SL   one slow server: t1 alone through slowp (its own port), t2-t12 direct - t1's own 'slow connect' once on U
#           and S, no fold, no other instance's; the delay lifted: resolved once.
#      RT   B24h-1's query round trip through the service (P5a; the lead 11-15 06:1x: READ FROM THE VIEWS - B24h's alert
#           arms are WIRING until the join writes 0300, so nothing is sent; P5b, the alert, runs at that join): t1-t12
#           dialled through four proxies slowq1-slowq4 (each its own container and address: its own host), three each,
#           that hold every frontend 'Q' and 'S' (a server answering late); round_trip_time at its default (0.040 s,
#           warning). After 3 measured minutes through them (none slow, no fold) each 'Q' / 'S' held 0.1 s: within 480 s
#           collector_round_trips slow on all 12, collector_probe_fold 'pgvigil-svc 4/4', collector_probe_findings'
#           12 'query round trip slow' (t1's detail 'query round trip (network and the server's response) ... from
#           pgvigil-svc; warning over 0.04...') and the fold's 'network slow from this collector' ('4 of the 4 hosts this
#           collector reads are slow ...'), the 12 held under it (collector_probe_held), held hosts slowq1-slowq4, no
#           ping row (no probe: no failure, no probe_every_minute); the delay lifted: no fold, nothing slow within 600 s.
#      RT1  one slow host: t1 alone through slowq1, t2-t12 direct - after 0.1 s held: t1's 'query round trip slow'
#           alone, no fold (1 of the 2 judged hosts slowq1 and target), nothing held; lifted: nothing slow.
#      RT2  the ping (P5a's ping half; B24h-1's probe is the TCP handshake to the address the instance dialled, which a
#           proxy cannot slow: the kernel completes it before accept()): tc netem's 50 ms delay on slowq1-slowq4's own
#           interface from a sidecar sharing each one's network (NET_ADMIN on the sidecar only; an image of
#           debian:trixie-slim + iproute2 built here), the service with probe_every_minute: within 540 s every
#           instance's ping_slow (method tcp, its host about 0.05 s over ping_time's 0.010 s), the four hosts' own 'ping
#           slow' rows (source pgvigil repository) and the 12 instances' (held), the fold 4/4 holding every instance's
#           'ping slow'; the delay removed. A sidecar or image the box refuses: 'NOT PROVEN RT2: <why>', not a FAIL.
#   U  uninstall (the join fold, last: the service is gone after it): `pgvigil uninstall` in the service's container
#      retires the host in the repository it keeps (pgvigil.import_collector_retire); the page says retired; no
#      'collector or network' follows (B shows the one a host that only stopped raises)
#   (in A) W  serve's watchdog at its first answer 'starting' or 'on', never empty (DONE-2 N12), then 'on'.
#          W2 a second serve whose alerts login accepts and never answers: 'starting' at its first answer, then
#          'off: the alerts login: ...' once the 20 s ping ends (W alone cannot fail: a local login answers first).
# PROOF_ONLY=E,D1,... runs the rig, A and the named cases only (A E H D1 D1b D2 D3 D4 D5 DQ F B G SC5 SC6 SC4 BH SV SC7 SL RT RT1 RT2 U); unset = all.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .vis/spool-evidence .vis/collector-shots   # fetched back by the box job even when no case wrote to them
WORK=$(mktemp -d); FAILS=0
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
ok() { echo "ok   $*"; }
want() { [[ -z "${PROOF_ONLY:-}" || ",${PROOF_ONLY// /}," == *",$1,"* ]]; }
fp() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
PW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
RP=$(fp); TP=$(fp); SP=$(fp); CDP=$(fp)
NET=pgvch-$$; REPO=pgvch-repo-$$; TGT=pgvch-tgt-$$; TGT2=pgvch-tgt2-$$; SVC=pgvch-svc-$$; SLP=pgvch-slowp-$$; IMG=pgvigil-proof-systemd:1
SLQ=pgvch-slowq-$$; TCI=pgvigil-proof-tc:1   # RT: the four query-delaying proxies $SLQ-1..4; RT2: the tc sidecar's image
SRV=""; CHR=""; SECOND=""; SRV2=""; HANG=""
cleanup() {
  [[ -n "$CHR" ]] && kill -- -"$CHR" 2>/dev/null || true
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$SECOND" ]] && kill "$SECOND" 2>/dev/null || true
  [[ -n "$SRV2" ]] && kill "$SRV2" 2>/dev/null || true
  [[ -n "$HANG" ]] && kill "$HANG" 2>/dev/null || true
  docker rm -f -v "$SVC" "$TGT" "$TGT2" "$SLP" "$SLQ-1" "$SLQ-2" "$SLQ-3" "$SLQ-4" "$REPO" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  for c in "$SVC" "$TGT" "$TGT2" "$SLP" "$SLQ-1" "$SLQ-2" "$SLQ-3" "$SLQ-4" "$REPO"; do docker inspect "$c" >/dev/null 2>&1 && echo "container $c LEFT"; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- the binary ----------------------------------------------------------------------------------------------------
if [[ -n "${PGVIGIL_BIN:-}" ]]; then BIN=$PGVIGIL_BIN; else
  (cd web && npm ci --silent --no-audit --no-fund >/dev/null 2>&1 && npm run build >"$WORK/web.log" 2>&1) || { tail -20 "$WORK/web.log"; exit 1; }
  CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil; BIN=$WORK/pgvigil
fi
cp "$BIN" "$WORK/pgvigil.bin"

# ---- the rig -------------------------------------------------------------------------------------------------------
docker network create "$NET" >/dev/null
docker run -d --name "$REPO" --network "$NET" --network-alias repo -e POSTGRES_PASSWORD="$PW" -p "127.0.0.1:$RP:5432" postgres:18 >/dev/null
docker run -d --name "$TGT" --network "$NET" --network-alias target -e POSTGRES_PASSWORD="$PW" -p "127.0.0.1:$TP:5432" postgres:18 >/dev/null
RDSN="host=127.0.0.1 port=$RP user=postgres password=$PW sslmode=disable"
TDSN="host=127.0.0.1 port=$TP user=postgres password=$PW sslmode=disable dbname=postgres"
for d in "$RDSN dbname=postgres" "$TDSN"; do for _ in $(seq 1 60); do psql "$d" -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 1; done; done; sleep 3
psql "$RDSN dbname=postgres" -XAtqc "create database pgvigil" >/dev/null
for n in 1 2 3 4; do psql "$TDSN" -Xq -v ON_ERROR_STOP=1 -c "create role l$n login password 'p$n' in role pg_monitor" -c "create database db$n owner l$n" >/dev/null; done
q() { psql "$RDSN dbname=pgvigil" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }

if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  mkdir -p "$WORK/img"
  cat > "$WORK/img/Dockerfile" <<'EOF'
FROM debian:trixie-slim
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends systemd systemd-sysv ca-certificates >/dev/null \
 && rm -rf /var/lib/apt/lists/* && useradd -r -s /usr/sbin/nologin pgvigil
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
EOF
  docker build -q -t "$IMG" "$WORK/img" >/dev/null || { echo "FAIL the systemd image did not build"; exit 1; }
fi
mkdir -p "$WORK/spool" "$WORK/spool2" "$WORK/spool3" "$WORK/spool4"; chmod 0711 "$WORK"; chmod 0777 "$WORK"/spool*   # the service's user walks through the folder (not reads it)
instances() { # $1 host, $2 port
  for n in 1 2 3 4; do printf '  - name: t%s\n    dsn: "host=%s port=%s user=l%s password=p%s dbname=db%s sslmode=disable"\n' "$n" "$1" "$2" "$n" "$n" "$n"
    if (( n < 4 )); then printf '    schedules: {activity: 10s}\n'; fi; done
}
# the service sees this folder as /work (systemd mounts a tmpfs over /tmp in the container)
alerts_of() { printf 'alerts:\n  - {name: spool, kind: file, min_severity: critical, repeat: disabled, clear_after: 0, file: {dir: %s/spool}}\n  - {name: scoped, kind: file, min_severity: critical, repeat: disabled, clear_after: 0, instances: [t1], file: {dir: %s/spool2}}\n  - {name: rep, kind: file, min_severity: critical, repeat: 5m, clear_after: 0, file: {dir: %s/spool3}}\n' "$1" "$1" "$1"
  [[ -n "${QUIET:-}" ]] && printf '  - {name: quiet, kind: file, min_severity: critical, repeat: disabled, clear_after: 0, quiet_hours: "%s", timezone: UTC, file: {dir: %s/spool4}}\n' "$QUIET" "$1"; true; }
{ printf 'repository:\n  dsn: "host=repo port=5432 user=postgres password=%s dbname=pgvigil sslmode=disable"\ninstances:\n' "$PW"; instances target 5432; alerts_of /work; } > "$WORK/svc.yaml"
{ printf 'repository:\n  dsn: "%s dbname=pgvigil"\ninstances:\n' "$RDSN"; instances 127.0.0.1 "$TP"; alerts_of "$WORK"; } > "$WORK/host.yaml"
"$BIN" migrate -config "$WORK/host.yaml" >"$WORK/migrate.out" 2>&1 || { cat "$WORK/migrate.out"; exit 1; }

docker run -d --name "$SVC" --hostname pgvigil-svc --network "$NET" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock -v "$WORK:/work" "$IMG" >/dev/null
for _ in $(seq 1 30); do docker exec "$SVC" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break; sleep 1; done
docker exec "$SVC" sh -c "install -m 0755 /work/pgvigil.bin /usr/local/bin/pgvigil && mkdir -p /etc/pgvigil /etc/systemd/system/pgvigil.service.d \
  && install -m 0640 -g pgvigil /work/svc.yaml /etc/pgvigil/pgvigil.yaml && touch /etc/pgvigil/pgvigil.env"
docker cp deploy/pgvigil.service "$SVC:/etc/systemd/system/pgvigil.service"
docker exec "$SVC" sh -c "printf '[Service]\nReadWritePaths=/work/spool /work/spool2 /work/spool3 /work/spool4\n' > /etc/systemd/system/pgvigil.service.d/proof.conf && systemctl daemon-reload && systemctl enable --now pgvigil.service" >/dev/null 2>&1
"$BIN" serve -config "$WORK/host.yaml" -listen "127.0.0.1:$SP" -no-login > "$WORK/serve.log" 2>&1 &
SRV=$!
# serve's first answer: its watchdog as the page reads it then (DONE-2 N12: 'starting' until both logins answered)
WD0=none
for _ in $(seq 1 60); do
  if a0=$(curl -fs "http://127.0.0.1:$SP/api/collector" 2>/dev/null); then
    WD0=$(printf '%s' "$a0" | python3 -c "import json,sys; t=json.load(sys.stdin).get('watchdog') or {}; r=t.get('rows') or []; print(r[0][0] if r and r[0][0] else 'empty')" 2>/dev/null || echo unreadable)
    break
  fi
  sleep 1
done
api() { curl -fs "http://127.0.0.1:$SP/api/collector$1"; }
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); t=d[sys.argv[1]]; c=t['columns']; print(json.dumps([dict(zip(c,r)) for r in t['rows']]))" "$1"; }
# spool_n EVENT SETTING [INSTANCE]: the alert files (one JSON per alert: <time>-<event>-<channel>-<key>.json) of an event
# whose setting is SETTING (and instance INSTANCE). The service writes them 0640 as its own user: made readable first;
# a file still unreadable after 5 tries (one renamed in between) prints -1 and leaves $WORK/unreadable, which fails the
# proof at its end (a sum of counts could hide a -1), so 'nothing sent' is never read off files that could not be read.
spool_n() {
  local n=-1 try
  for try in 1 2 3 4 5; do
    docker exec "$SVC" chmod -R a+rX /work/spool /work/spool2 /work/spool3 /work/spool4 >/dev/null 2>&1
    n=$(python3 - "${SPOOL:-$WORK/spool}" "$@" <<'PY'
import glob, json, os, sys
d, ev, setting = sys.argv[1:4]; inst = sys.argv[4] if len(sys.argv) > 4 else None
skip = set(open(os.environ['SKIP']).read().split()) if os.environ.get('SKIP') else set()
n = bad = 0
for f in glob.glob(os.path.join(d, '*.json')):
    if f'-{ev}-' not in os.path.basename(f) or os.path.basename(f) in skip:
        continue
    try:
        a = json.load(open(f))
    except Exception:
        bad += 1
        continue
    flat = json.dumps(a)
    if f'"{setting}"' in flat and (inst is None or f'"{inst}"' in flat):
        n += 1
print(-1 if bad else n)
PY
)
    [[ "$n" != -1 ]] && break
    sleep 1
  done
  [[ "$n" == -1 ]] && echo "${SPOOL:-$WORK/spool} $*" >> "$WORK/unreadable"
  echo "$n"
}
waitfor() { # $1 seconds, $2 SQL that returns t when done
  local end=$((SECONDS + $1)); while (( SECONDS < end )); do [[ "$(q "$2")" == t ]] && return 0; sleep 5; done; return 1
}
# cnt DIR EVENT SETTINGS INSTANCES [NOTVALUES]: the alert files of an EVENT in DIR whose setting is one of SETTINGS and
# instance one of INSTANCES ('|'-separated; INSTANCES '' = any) and whose value is none of NOTVALUES; SKIP=<a list of
# file names> leaves those out (the files before a lift). An unreadable file prints -1 and fails the proof (spool_n).
cnt() {
  local n=-1 try
  for try in 1 2 3 4 5; do
    docker exec "$SVC" chmod -R a+rX /work/spool /work/spool2 /work/spool3 /work/spool4 >/dev/null 2>&1
    n=$(python3 - "$@" <<'PY'
import glob, json, os, sys
d, ev, sets, insts = sys.argv[1:5]
notv = set(sys.argv[5].split('|')) if len(sys.argv) > 5 and sys.argv[5] else set()
sets = set(sets.split('|')); insts = set(insts.split('|')) if insts else None
skip = set(open(os.environ['SKIP']).read().split()) if os.environ.get('SKIP') else set()
n = bad = 0
for f in glob.glob(os.path.join(d, '*.json')):
    b = os.path.basename(f)
    if f'-{ev}-' not in b or b in skip:
        continue
    try:
        a = json.load(open(f))
    except Exception:
        bad += 1
        continue
    if a.get('setting') in sets and (insts is None or a.get('instance') in insts) and a.get('value') not in notv:
        n += 1
print(-1 if bad else n)
PY
)
    [[ "$n" != -1 ]] && break
    sleep 1
  done
  [[ "$n" == -1 ]] && echo "cnt $*" >> "$WORK/unreadable"
  echo "$n"
}
# within SECONDS DIR EVENT SETTING INSTANCES [N]: the seconds until N (default 1) such files are there (-1: not in time).
# A recovery takes up to two alert passes after its finding left (alert_mark stamps missing_since on the first, the
# resolve needs a pass after it and an ok read since), so a resolve is waited for, never read after a fixed sleep.
within() { local t0=$SECONDS; while (( SECONDS - t0 < $1 )); do [[ "$(cnt "$2" "$3" "$4" "$5")" -ge "${6:-1}" ]] && { echo $((SECONDS - t0)); return 0; }; sleep 5; done; echo -1; }
# snap CASE: the spools' file names now (the files before the lift); keep CASE: the spools copied for the evidence
snap() { (cd "$WORK" && ls spool spool2 spool3 spool4 2>/dev/null | grep '\.json$') > "$WORK/$1.lst" || true; }
keep() { docker exec "$SVC" chmod -R a+rX /work/spool /work/spool2 /work/spool3 /work/spool4 >/dev/null 2>&1; rm -rf ".vis/spool-evidence/$1"; mkdir -p ".vis/spool-evidence/$1"; cp -r "$WORK"/spool* ".vis/spool-evidence/$1/" 2>/dev/null || echo "keep $1: a spool file not copied" >> "$WORK/unreadable"; }
# keymax DIR EVENT: the most files one alert key has for the EVENT in DIR (the key = the file name's last part)
keymax() {
  docker exec "$SVC" chmod -R a+rX /work/spool /work/spool2 /work/spool3 /work/spool4 >/dev/null 2>&1
  python3 -c "import collections, glob, os, sys; c = collections.Counter(os.path.basename(f).rsplit('-', 1)[1] for f in glob.glob(os.path.join(sys.argv[1], '*.json')) if '-' + sys.argv[2] + '-' in os.path.basename(f)); print(max(c.values(), default=0))" "$1" "$2"
}
echo "rig: repository :$RP, target :$TP (t1-t4), serve :$SP, the service in $SVC ($(docker exec "$SVC" systemctl is-active pgvigil.service))"

# ---- A the heartbeat -----------------------------------------------------------------------------------------------
if waitfor 200 "SELECT count(*) >= 2 FROM pgvigil.collector_beats b JOIN pgvigil.collector_heartbeat h USING (collector_id) WHERE h.host = 'pgvigil-svc'"; then
  read -r st ra hs <<<"$(api '' | jget collectors | python3 -c "import json,sys; r=json.load(sys.stdin)[0]; print(r['state'], r['runs_as'].replace(' ','_'), r['host'])")"
  loads=$(api '' | jget load | python3 -c "import json,sys; r=json.load(sys.stdin); print(len(r), all((x['conns_per_min'] or 0) > 0 and (x['attempts_per_min'] or 0) >= (x['conns_per_min'] or 0) for x in r), sum(x['failures_1h'] or 0 for x in r))")
  colls=$(api '' | jget collections | python3 -c "import json,sys; r=json.load(sys.stdin); print(len(r), sum(x['runs'] for x in r), sum(x['rows_written'] for x in r), sum(1 for x in r if x['p95_ms'] is not None))")
  repo=$(api '' | jget repository | python3 -c "import json,sys; r=json.load(sys.stdin)[0]; print(r['size_bytes'] > 0, r['rows_per_min'])")
  [[ "$st $ra $hs" == "up systemd_unit pgvigil-svc" && "${loads% *}" == "4 True" && "${repo%% *}" == True ]] \
    && ok "A heartbeat: $st, runs as $ra on $hs; load: $loads (instances, every one with connections opened <= attempted, failures in the hour); collections (count, runs, rows, with p95): $colls; repository (size read, rows/min): $repo" \
    || fail "A heartbeat: state '$st $ra $hs', load '$loads', collections '$colls', repository '$repo'"
else
  fail "A heartbeat: no two beats from pgvigil-svc in 200 s: $(docker exec "$SVC" journalctl -u pgvigil -n 15 --no-pager 2>&1 | tr '\n' ' ' | cut -c1-900)"
fi
# the run names the instances it reads (collector_instances: written inside each instance's own connect and by every
# beat) - what makes the stored reads' own 'server unreachable' stand back for them
a_names=$(q "SELECT count(DISTINCT ci.instance) FROM pgvigil.collector_instances ci JOIN pgvigil.collector_live l USING (collector_id) WHERE l.host = 'pgvigil-svc' AND ci.instance IN ('t1','t2','t3','t4') AND ci.seen_at > now() - interval '5 minutes'")
[[ "$a_names" == 4 ]] && ok "A names: the live run on pgvigil-svc names its 4 instances, each seen in the last 5 minutes" || fail "A names: $a_names of the 4 instances named by the live run in the last 5 minutes"
wd1=$(api '' | python3 -c "import json,sys; t=json.load(sys.stdin).get('watchdog') or {}; r=t.get('rows') or []; print(r[0][0] if r and r[0][0] else 'empty')" 2>/dev/null || echo unreadable)
if [[ "$WD0" == starting ]]; then wd_seen="'starting' seen on this serve"; else wd_seen="'starting' not seen on this serve (its logins answered before its first answer): W2 shows it"; fi
[[ ( "$WD0" == starting || "$WD0" == on ) && "$wd1" == on ]] \
  && ok "A watchdog: serve's first answer said '$WD0', now '$wd1' - $wd_seen" \
  || fail "A watchdog: serve's first answer '$WD0' (want starting or on), now '$wd1' (want on)"
# ---- W2 (DONE-2 N12): 'starting' shown - a second serve whose alerts login is a listener that accepts and never
# answers. Its first answer must be 'starting' (before N12 it was empty: the page's 'not this process'); the alerts
# login's 20 s ping then ends in 'off: the alerts login: ...'. Its own file channel: nothing reaches the proof's spools.
HP=$(fp); SP2=$(fp); mkdir -p "$WORK/spoolw"
python3 -c $'import socket, sys\ns = socket.socket()\ns.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\ns.bind(("127.0.0.1", int(sys.argv[1])))\ns.listen(64)\nheld = []\nwhile True:\n    held.append(s.accept()[0])' "$HP" &
HANG=$!
# the listener must accept before serve starts: a port not yet bound refuses at once, and serve reads 'off' at once
for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$HP") 2>/dev/null && break; sleep 0.2; done
{ printf 'repository:\n  dsn: "%s dbname=pgvigil"\nalerts_dsn: "host=127.0.0.1 port=%s user=pgvigil_alerts password=x dbname=pgvigil sslmode=disable"\ninstances:\n' "$RDSN" "$HP"
  instances 127.0.0.1 "$TP"
  printf 'alerts:\n  - {name: w2, kind: file, min_severity: critical, repeat: disabled, clear_after: 0, file: {dir: %s/spoolw}}\n' "$WORK"; } > "$WORK/wdog.yaml"
"$BIN" serve -config "$WORK/wdog.yaml" -listen "127.0.0.1:$SP2" -no-login > "$WORK/serve2.log" 2>&1 &
SRV2=$!
wdq() { curl -fs "http://127.0.0.1:$SP2/api/collector" 2>/dev/null \
  | python3 -c "import json,sys; t=json.load(sys.stdin).get('watchdog') or {}; r=t.get('rows') or []; print(r[0][0] if r and r[0][0] else 'empty')" 2>/dev/null; }
wd2a=none; wd2b=none; wd2t=-1
for _ in $(seq 1 30); do if wd2r=$(wdq); then wd2a=$wd2r; break; fi; sleep 1; done
w2_t0=$SECONDS
while (( SECONDS - w2_t0 < 45 )); do wd2b=$(wdq || echo unreadable); [[ "$wd2b" == off:* ]] && { wd2t=$((SECONDS - w2_t0)); break; }; sleep 2; done
kill "$SRV2" "$HANG" 2>/dev/null || true; SRV2=""; HANG=""
[[ "$wd2a" == starting && "$wd2b" == "off: the alerts login:"* ]] \
  && ok "A watchdog W2: a serve whose alerts login never answers said 'starting' at its first answer, then '$(echo "$wd2b" | cut -c1-120)' $wd2t s later" \
  || fail "A watchdog W2: first answer '$wd2a' (want starting), then '$(echo "$wd2b" | cut -c1-160)' (want 'off: the alerts login: ...' within 45 s): $(tail -3 "$WORK/serve2.log" | tr '\n' ' ' | cut -c1-300)"
# ---- W2 end

# ---- E a login refused ---------------------------------------------------------------------------------------------
PER="authentication failing|collection failing|server unreachable"
# plain: the collections failing on the plain target t4 (never cut): host without system_stats, jobs without pg_cron ...
plain() { q "SELECT coalesce(string_agg(f.value, '|'), '') FROM pgvigil.collector_findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 't4' AND f.setting = 'collection failing'"; }
T2="FROM pgvigil.collector_findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 't2'"
if want E; then
rm -f "$WORK"/spool*/*
psql "$TDSN" -XAtqc "alter role l2 password 'changed'" >/dev/null
if waitfor 300 "SELECT EXISTS (SELECT 1 $T2 AND f.setting = 'authentication failing')"; then
  auth=$(api '' | jget load | python3 -c "import json,sys; print({x['instance']: x['auth_failures_24h'] for x in json.load(sys.stdin)})")
  sleep 70   # an alert pass after the findings
  PL=$(plain)
  e_auth=$(cnt "$WORK/spool" firing "authentication failing" t2); e_coll=$(cnt "$WORK/spool" firing "collection failing|server unreachable" t2 "$PL")
  e_s=$(cnt "$WORK/spool2" firing "$PER" t2); e_parent=$(cnt "$WORK/spool" firing "collector or network" "")
  [[ "$e_auth" == 1 && "$e_coll" == 0 && "$e_s" == 0 && "$e_parent" == 0 && "$(q "SELECT EXISTS (SELECT 1 FROM pgvigil.collector_held_instances)")" == f ]] \
    && ok "E login refused: logins refused per instance $auth; alerts: t2 'authentication failing' $e_auth on the channel that covers t2, its 'collection failing' / 'server unreachable' $e_coll (the runs failed at the connect), $e_s on the channel scoped to t1, 'collector or network' $e_parent" \
    || fail "E login refused: refused $auth; t2 auth $e_auth (want 1), collection / unreachable $e_coll (want 0), scoped $e_s (want 0), parent $e_parent (want 0), held $(q "SELECT EXISTS (SELECT 1 FROM pgvigil.collector_held_instances)"): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-600)"
else
  fail "E login refused: t2's 'authentication failing' did not come in 300 s: $(q "SELECT string_agg(setting || '=' || value, ', ') FROM pgvigil.collector_findings")"
fi
docker exec "$SVC" systemctl restart pgvigil.service   # still refused: the restart must send nothing again
sleep 150
dup=$(keymax "$WORK/spool" firing); res=$(cnt "$WORK/spool" resolved "$PER" t2); a1=$(cnt "$WORK/spool" firing "authentication failing" t2)
[[ "$dup" == 1 && "$res" == 0 && "$a1" == 1 ]] \
  && ok "E restart while refused: no alert key fired twice (the most files of one key: $dup), t2 resolved $res, its 'authentication failing' still once" \
  || fail "E restart while refused: one key fired $dup times (want 1), t2 resolved $res (want 0), auth $a1 (want 1): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-600)"
fi

if want H; then
# ---- H the page ----------------------------------------------------------------------------------------------------
setsid chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu --hide-scrollbars \
  --window-size=1600,900 about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null && break; sleep 0.5; done
mkdir -p .vis/collector-shots
cat > "$WORK/page.mjs" <<'EOF'
const [cdp, base, out] = process.argv.slice(2);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${cdp}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let n = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++n; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => (await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true })).result?.result?.value;
const sleep = ms => new Promise(r => setTimeout(r, ms));
let fails = 0; const line = (good, what) => { if (!good) fails++; console.log(`${good ? 'ok  ' : 'FAIL'} H ${what}`); };
const ready = async () => { for (let i = 0; i < 80; i++) { if (await ev(`(() => { const m = document.querySelector('main'); return !!m && !/Loading/.test(m.innerText) && !!m.querySelector('h2'); })()`)) return true; await sleep(250); } return false; };
const go = async h => { await cmd('Page.navigate', { url: 'about:blank' }); await cmd('Page.navigate', { url: base + h }); await sleep(500); return ready(); };
await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 900, deviceScaleFactor: 1, mobile: false });
for (const theme of ['light', 'dark']) {
  await cmd('Page.navigate', { url: base }); await sleep(800);
  await ev(`localStorage.setItem('pgvigil.theme', '${theme}'); true`);
  const r = await go('#/collector');
  const panels = await ev(`[...document.querySelectorAll('main .panel h3.panel-head')].map(h => h.firstChild.textContent).join(' | ')`);
  const tiles = await ev(`document.querySelectorAll('main .tile').length`);
  const s = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  fs.writeFileSync(`${out}/${theme}-collector.png`, Buffer.from(s.result.data, 'base64'));
  line(r && panels === 'Service | Findings | Collections | Failing now | Load on the monitored servers | Repository' && tiles >= 15, `${theme}: ready ${r}; panels ${panels}; ${tiles} tiles; shot ${theme}-collector.png`);
}
// every link on the page, its landing
await go('#/collector');
const links = await ev(`[...new Set([...document.querySelectorAll('main a[href^="#/"]')].map(a => a.getAttribute('href')))]`);
let landed = 0;
for (const h of links) {
  await go(h);
  const at = await ev('location.hash'), title = await ev(`document.querySelector('main h2')?.textContent ?? ''`);
  const lineTxt = await ev(`document.querySelector('main .collector-line')?.textContent ?? ''`);
  const good = h.startsWith('#/collectiondates') ? at.startsWith('#/collectiondates') && /i=\d+/.test(at) && title === 'Collection dates' && lineTxt.startsWith('Collector:') : at.split('?')[0] === h.split('?')[0];
  if (good) landed++; else console.log(`FAIL H link ${h}: landed ${at} '${title}' line '${lineTxt}'`);
  if (good && lineTxt && landed === 1) {
    await ev(`document.querySelector('main .collector-line a').click(); true`); await sleep(300); await ready();
    const back = await ev('location.hash');
    line(back.startsWith('#/collector'), `the collector's line on ${h} ('${lineTxt.slice(0, 160)}'): its link lands on ${back}`);
  }
}
line(links.length > 0 && landed === links.length, `links: ${landed} of ${links.length} landed (${[...new Set(links.map(h => h.split('?')[0]))].join(', ')})`);
// the tree's node under Checks (a root folder's head is a .tree-node: its caret button opens it, its name is a link)
await go('#/summary');
const treeLink = `[...document.querySelectorAll('#tree a')].find(x => x.textContent.trim() === 'Collector')`;
let how = 'open already';
if (!(await ev(`!!${treeLink}`))) {
  how = await ev(`(() => { const n = [...document.querySelectorAll('#tree .tree-node')].find(x => x.querySelector('a, .folder-name')?.textContent.trim() === 'Checks'); if (!n) return 'no Checks node'; const c = n.querySelector('button.caret'); if (!c) return 'no caret'; c.click(); return 'caret ' + c.getAttribute('data-key'); })()`);
  await sleep(600);
}
const tree = await ev(`(() => { const a = ${treeLink}; if (!a) return ''; a.click(); return a.getAttribute('href'); })()`);
await sleep(300); await ready();
const treeAt = await ev('location.hash');
const treeGood = tree !== '' && treeAt.startsWith('#/collector');
line(treeGood, `the tree's Collector node (${tree}) lands on ${treeAt}` + (treeGood ? '' : `; ${how}; nodes: ${await ev(`[...document.querySelectorAll('#tree .tree-node')].map(x => x.textContent.trim().slice(0, 24)).join(' | ')`)}; links: ${await ev(`[...document.querySelectorAll('#tree a')].map(x => x.textContent.trim() + '=' + x.getAttribute('href')).slice(0, 40).join(', ')`)}; #tree ${await ev(`!!document.querySelector('#tree')`)}`));
// the chart's menu
await go('#/collector');
const menu = await ev(`(async () => { const b = [...document.querySelectorAll('main .chart h3 button')].find(x => x.textContent.trim() === '⋯'); if (!b) return 'no menu button'; b.click(); await new Promise(r => setTimeout(r, 300)); const m = document.querySelector('.menu'); const t = m ? [...m.querySelectorAll('button')].map(x => x.textContent).join('|') : 'no menu'; document.activeElement?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); return t; })()`);
line(/Copy image/.test(menu) && /Export data/.test(menu), `the chart's menu: ${menu}`);
console.log(fails ? `FAIL H: ${fails}` : 'H: the page as expected');
ws.close(); process.exit(fails ? 1 : 0);
EOF
node "$WORK/page.mjs" "$CDP" "http://127.0.0.1:$SP/" "$PWD/.vis/collector-shots" || FAILS=$((FAILS + 1))
fi

if want E; then
psql "$TDSN" -XAtqc "alter role l2 password 'p2'" >/dev/null
docker exec "$SVC" systemctl restart pgvigil.service   # a changed password is fixed and the service restarted
# t2 back to t1's state: no 'authentication failing', and t2 fails no collection t1 does not (some collections fail on
# every plain target: host without system_stats, jobs without pg_cron, ...)
CF="SELECT f.value FROM pgvigil.collector_findings f JOIN pgvigil.instances i USING (instance_id) WHERE f.setting = 'collection failing' AND i.name ="
if waitfor 300 "SELECT NOT EXISTS (SELECT 1 $T2 AND f.setting = 'authentication failing') AND NOT EXISTS ($CF 't2' EXCEPT $CF 't1')"; then
  e_w=$(within 240 "$WORK/spool" resolved "authentication failing" t2); e_res=$(cnt "$WORK/spool" resolved "authentication failing" t2)
  [[ "$e_res" == 1 ]] && ok "E restart: the password back and the service restarted - t2's 'authentication failing' gone and resolved once ($e_w s after it left the view), its 'collection failing' within t1's ($(q "SELECT count(*) FROM ($CF 't1') x") on t1: $(q "SELECT string_agg(value, ' ') FROM ($CF 't1') x"))" \
    || fail "E restart: t2's 'authentication failing' resolved $e_res times in 240 s (want 1)"
else fail "E restart: t2 still $(q "SELECT string_agg(f.setting || ' ' || f.value, ', ') $T2") 300 s after the restart"; fi
keep E
fi

# ---- D failing together -------------------------------------------------------------------------------------------
# logins HOW NAME...: the logins of the instances (t1 -> l1) turned login | nologin at the source (a refused login)
logins() { local how=$1 a=() n; shift; for n in "$@"; do a+=(-c "alter role l${n#t} $how"); done; psql "$TDSN" -Xq "${a[@]}" >/dev/null; }
# pin_at S: wait for the second S of a wall-clock minute (the cut's second)
pin_at() { local i; for i in $(seq 1 700); do [[ "$((10#$(date -u +%S)))" == "$1" ]] && return 0; sleep 0.1; done; return 0; }
NOPARENT="SELECT NOT EXISTS (SELECT 1 FROM pgvigil.collector_parent) AND NOT EXISTS (SELECT 1 FROM pgvigil.collector_held_instances) AND NOT EXISTS (SELECT 1 FROM pgvigil.collector_findings WHERE setting IN ('authentication failing', 'server unreachable'))"
# d_clean: every login back, no parent, nothing held, no refusal standing, a pass after it; the spools emptied
d_clean() { logins login t1 t2 t3 t4; waitfor 600 "$NOPARENT" || fail "D: not clean 600 s after the logins came back"; sleep 70; rm -f "$WORK"/spool*/*; }
# per DIR EVENT INSTANCES: the instances' own alerts ($PER), the collections failing on the plain target left out
per() { cnt "$1" "$2" "$PER" "$3" "$(plain)"; }
PAR="collector or network"
# d_cut CASE SECOND MINUTES: t1-t3 cut at the SECOND of a minute for MINUTES (D1, D1b)
d_cut() {
  local c=$1 t0 c0 tp left up sp pr pr2 ur sr af ar s1 L k want_k want_k1
  d_clean; pin_at "$2"; logins nologin t1 t2 t3; t0=$SECONDS; c0=$(date -u +%s)
  tp=$(within 185 "$WORK/spool" firing "$PAR" "")
  left=$(( $3 * 60 - (SECONDS - t0) )); if (( left > 0 )); then sleep "$left"; fi
  snap "$c"; L=$WORK/$c.lst
  up=$(cnt "$WORK/spool" firing "$PAR" ""); sp=$(cnt "$WORK/spool2" firing "$PAR" "")
  pr=$(per "$WORK/spool" firing "t1|t2|t3"); pr2=$(per "$WORK/spool2" firing t1)
  # k: t1-t3 with a failed run in the cut's minute (a run starts 0-10 s off its slot: a cut at :55 may reach only some);
  # fewer than 3 = no 'collector or network' forming, so those k alert at once (a single instance is never delayed) and
  # resolve after the lift; 3 = nothing of t1-t3 goes out
  k=$(q "SELECT count(DISTINCT l.instance_id) FROM pgvigil.collector_load l JOIN pgvigil.instances i USING (instance_id) WHERE i.name IN ('t1','t2','t3') AND l.failures > 0 AND l.minute = date_trunc('minute', to_timestamp($c0))")
  want_k=$(( k >= 3 ? 0 : k )); want_k1=$(q "SELECT count(*) FROM pgvigil.collector_load l JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 't1' AND l.failures > 0 AND l.minute = date_trunc('minute', to_timestamp($c0))"); if (( k >= 3 )); then want_k1=0; fi
  logins login t1 t2 t3
  waitfor 480 "$NOPARENT" || fail "$c: the parent still standing 480 s after the lift"
  SKIP=$L within 240 "$WORK/spool" resolved "$PAR" "" >/dev/null; SKIP=$L within 60 "$WORK/spool2" resolved "$PAR" "" >/dev/null
  sleep 60   # one more pass: nothing of t1-t3 may follow the parent's recovery
  ur=$(SKIP=$L cnt "$WORK/spool" resolved "$PAR" ""); sr=$(SKIP=$L cnt "$WORK/spool2" resolved "$PAR" "")
  if (( want_k > 0 )); then within 240 "$WORK/spool" resolved "$PER" "t1|t2|t3" "$want_k" >/dev/null; fi
  af=$(SKIP=$L per "$WORK/spool" firing "t1|t2|t3"); ar=$(per "$WORK/spool" resolved "t1|t2|t3"); s1=$(per "$WORK/spool2" resolved t1)
  keep "$c"
  if [[ "$tp" -ge 0 && "$up" == 1 && "$sp" == 1 && "$pr" == "$want_k" && "$pr2" == "$want_k1" && "$ur" == 1 && "$sr" == 1 && "$af" == 0 && "$ar" == "$want_k" && "$s1" == "$want_k1" ]]; then
    ok "$c: t1-t3 cut at :$2 for $3 min - 'collector or network' sent $tp s after the cut, once on U and once on S; $k of t1-t3 failed a run in the cut's minute: their own alerts $pr (S: t1 $pr2), want $want_k / $want_k1; after the lift the parent resolved once on each, t1-t3 sent 0, resolved $ar"
  else
    fail "$c: parent $tp s after the cut (want 0-185), U $up / S $sp (want 1 / 1), t1-t3 before the lift $pr / S $pr2 (want $want_k / $want_k1: $k failed in the cut's minute); after it: parent resolved U $ur / S $sr (want 1 / 1), t1-t3 sent $af resolved $ar, S t1 resolved $s1 (want 0 $want_k $want_k1): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-700)"
  fi
}
if want D1; then d_cut D1 20 6; fi
if want D1b; then d_cut D1b 55 4; fi
if want D2; then
  d_clean; pin_at 10; logins nologin t1 t2 t3; sleep 40; logins login t1 t2 t3; sleep 200
  d2a=$(per "$WORK/spool" firing "t1|t2|t3"); d2b=$(per "$WORK/spool" resolved "t1|t2|t3"); d2c=$(cnt "$WORK/spool" firing "$PAR" ""); d2d=$(per "$WORK/spool2" firing t1)
  keep D2
  [[ "$d2a$d2b$d2c$d2d" == 0000 ]] && ok "D2: t1-t3 cut :10 to :50 of one minute - nothing sent, nothing resolved (U: own $d2a, resolved $d2b, parent $d2c; S: $d2d)" \
    || fail "D2: U own $d2a, resolved $d2b, parent $d2c; S $d2d (want 0 0 0 0): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-500)"
fi
if want D3; then
  d_clean; pin_at 20; logins nologin t1 t2; t0=$SECONDS; tw=-1
  while (( SECONDS - t0 < 125 )); do [[ "$(cnt "$WORK/spool" firing "authentication failing" "t1|t2")" == 2 ]] && { tw=$((SECONDS - t0)); break; }; sleep 5; done
  left=$(( 240 - (SECONDS - t0) )); if (( left > 0 )); then sleep "$left"; fi   # the cut stands 4 min: nothing more goes out
  d3a=$(cnt "$WORK/spool" firing "authentication failing" "t1|t2"); d3c=$(cnt "$WORK/spool" firing "collection failing|server unreachable" "t1|t2" "$(plain)")
  d3p=$(cnt "$WORK/spool" firing "$PAR" ""); d3h=$(q "SELECT EXISTS (SELECT 1 FROM pgvigil.collector_held_instances)"); d3s=$(cnt "$WORK/spool2" firing "authentication failing" t1)
  logins login t1 t2; waitfor 300 "$NOPARENT" || true
  within 240 "$WORK/spool" resolved "authentication failing" "t1|t2" 2 >/dev/null; within 60 "$WORK/spool2" resolved "authentication failing" t1 >/dev/null
  d3r=$(cnt "$WORK/spool" resolved "authentication failing" "t1|t2"); d3sr=$(cnt "$WORK/spool2" resolved "authentication failing" t1)
  keep D3
  [[ "$tw" -ge 0 && "$d3a" == 2 && "$d3c" == 0 && "$d3p" == 0 && "$d3h" == f && "$d3s" == 1 && "$d3r" == 2 && "$d3sr" == 1 ]] \
    && ok "D3: t1, t2 cut (2 of 4) - no parent, nothing held; 'authentication failing' once each within $tw s of the cut (S: t1 once), no 'collection failing' / 'server unreachable'; resolved once each after (S: t1 once)" \
    || fail "D3: both auth after $tw s (want 0-125), U auth $d3a (want 2), collection / unreachable $d3c (want 0), parent $d3p (want 0), held $d3h (want f), S auth $d3s (want 1); resolved U $d3r (want 2), S $d3sr (want 1): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-500)"
fi
if want D4; then
  d_clean; logins nologin t1; t0=$SECONDS; tw=-1
  while (( SECONDS - t0 < 150 )); do [[ "$(cnt "$WORK/spool3" firing "authentication failing" t1)" == 1 ]] && { tw=$((SECONDS - t0)); break; }; sleep 5; done
  pin_at 20; logins nologin t2 t3; t0=$SECONDS
  tp=$(within 185 "$WORK/spool" firing "$PAR" "")
  left=$(( 540 - (SECONDS - t0) )); if (( left > 0 )); then sleep "$left"; fi   # 9 min: R's 5-minute repeat of the parent falls inside the hold
  d4rp=$(cnt "$WORK/spool3" repeat "$PAR" ""); d4rt=$(cnt "$WORK/spool3" repeat "authentication failing" t1)
  d4h=$(cnt "$WORK/spool" resolved "authentication failing" t1)$(cnt "$WORK/spool2" resolved "authentication failing" t1)
  d4o=$(per "$WORK/spool" firing "t2|t3"); d4d=$(q "SELECT detail FROM pgvigil.collector_findings WHERE setting = '$PAR'" | grep -o 'it covers.*' | cut -c1-160 || true)
  snap D4; L=$WORK/D4.lst
  logins login t1 t2 t3; waitfor 480 "$NOPARENT" || fail "D4: the parent still standing 480 s after the lift"
  SKIP=$L within 240 "$WORK/spool" resolved "authentication failing" t1 >/dev/null; SKIP=$L within 60 "$WORK/spool2" resolved "authentication failing" t1 >/dev/null; sleep 60
  d4a=$(SKIP=$L cnt "$WORK/spool" resolved "authentication failing" t1)$(SKIP=$L cnt "$WORK/spool2" resolved "authentication failing" t1)
  d4o2=$(per "$WORK/spool" firing "t2|t3"); d4rt2=$(SKIP=$L cnt "$WORK/spool3" repeat "authentication failing" t1)
  keep D4
  [[ "$tw" -ge 0 && "$tp" -ge 0 && "$d4rp" -ge 1 && "$d4rt" == 0 && "$d4h" == 00 && "$d4o" == 0 && "$d4d" == *"t1 authentication failing"* && "$d4a" == 11 && "$d4o2" == 0 && "$d4rt2" == 0 ]] \
    && ok "D4: t1 refused first (its alert out in $tw s on U, S and R), then t2, t3 - the parent $tp s after; during the hold R repeated the parent $d4rp time(s) and t1 0 times, t1 resolved 0, t2 t3 sent 0; the parent's text '$d4d'; after the lift t1 resolved once on U and on S, and R sent $d4rt2 repeat(s) of t1 (its repeat waits while its newest failure is inside the window: the resolve arrives alone)" \
    || fail "D4: t1 out after $tw s, parent after $tp s; R repeats parent $d4rp (want >= 1) / t1 $d4rt (want 0); t1 resolved during the hold U+S '$d4h' (want 00); t2 t3 sent $d4o (want 0); covers '$d4d'; after: t1 resolved U+S '$d4a' (want 11), t2 t3 $d4o2, R t1 repeats after the lift $d4rt2 (want 0): $(ls "$WORK/spool" "$WORK/spool3" | tr '\n' ' ' | cut -c1-700)"
fi
if want D5; then
  d_clean; pin_at 20; logins nologin t1 t2 t3; t0=$SECONDS
  tp=$(within 185 "$WORK/spool" firing "$PAR" "")
  left=$(( 240 - (SECONDS - t0) )); if (( left > 0 )); then sleep "$left"; fi
  logins login t1 t2; d5_l0=$SECONDS
  # DONE-2 (N2): the parent clears the minute after the lift; t3 is handed back once its newest failure is span + 4
  # minutes past the last minute the three failed together (collector_in_window) - timed from the lift, never from the
  # parent's leaving (DONE-1's parent left later: vis-201q's D5 logged t3 back before its alert)
  t3w=-1; t3l=-1
  if waitfor 480 "SELECT NOT EXISTS (SELECT 1 FROM pgvigil.collector_parent)"; then
    t3w=$(within 480 "$WORK/spool" firing "authentication failing" t3); if [[ "$t3w" -ge 0 ]]; then t3l=$((SECONDS - d5_l0)); fi
  fi
  within 240 "$WORK/spool" resolved "$PAR" "" >/dev/null; within 60 "$WORK/spool2" resolved "$PAR" "" >/dev/null
  d5p=$(cnt "$WORK/spool" resolved "$PAR" ""); d5o=$(per "$WORK/spool" firing "t1|t2")$(per "$WORK/spool" resolved "t1|t2")
  d5t=$(cnt "$WORK/spool" firing "authentication failing" t3)$(cnt "$WORK/spool" resolved "authentication failing" t3)
  d5s=$(cnt "$WORK/spool2" firing "$PAR" "")$(cnt "$WORK/spool2" resolved "$PAR" "")$(per "$WORK/spool2" firing t1)
  logins login t3; waitfor 300 "$NOPARENT" || true; within 240 "$WORK/spool" resolved "authentication failing" t3 >/dev/null
  d5t2=$(cnt "$WORK/spool" resolved "authentication failing" t3)
  keep D5
  [[ "$tp" -ge 0 && "$d5p" == 1 && "$d5o" == 00 && "$t3l" -ge 240 && "$t3l" -le 480 && "$d5t" == 10 && "$d5s" == 110 && "$d5t2" == 1 ]] \
    && ok "D5: t1-t3 cut, t1 t2 back after 4 min, t3 kept - the parent ($tp s) resolved once; t3's 'authentication failing' once, $t3l s after t1 t2 came back (its window's end); t1 t2 sent / resolved $d5o; S parent / resolved / t1 $d5s; t3 resolved once when back" \
    || fail "D5: parent after $tp s, resolved $d5p (want 1); t1 t2 sent+resolved '$d5o' (want 00); t3 $t3l s after t1 t2 came back (want 240-480), t3 sent+resolved '$d5t' (want 10); S '$d5s' (want 110); t3 resolved when back $d5t2 (want 1): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-600)"
fi
if want DQ; then
  d_clean
  C=$(( $(date -u +%s) / 60 + 2 ))   # the cut's minute: two on (the service restarts with the quiet channel first)
  QUIET="$(date -u -d @$(( (C - 1) * 60 )) +%H:%M)-$(date -u -d @$(( (C + 3) * 60 )) +%H:%M)"; QEND=$(date -u -d @$(( (C + 3) * 60 )) +%Y%m%dT%H%M%S)
  { printf 'repository:\n  dsn: "host=repo port=5432 user=postgres password=%s dbname=pgvigil sslmode=disable"\ninstances:\n' "$PW"; instances target 5432; alerts_of /work; } > "$WORK/svc.yaml"
  docker exec "$SVC" sh -c "install -m 0640 -g pgvigil /work/svc.yaml /etc/pgvigil/pgvigil.yaml && systemctl restart pgvigil.service"
  left=$(( C * 60 + 20 - $(date -u +%s) )); if (( left > 0 )); then sleep "$left"; fi
  logins nologin t1 t2 t3; sleep 300
  dq1=$(cnt "$WORK/spool4" firing "$PAR" ""); dqo=$(per "$WORK/spool4" firing "t1|t2|t3")
  # the parent's own first file (a new channel also sends the standing findings of the plain target)
  firstpar() { python3 -c "import glob, json, os, sys; print(min((os.path.basename(f)[:15] for f in glob.glob(sys.argv[1] + '/*-firing-*.json') if json.load(open(f)).get('setting') == 'collector or network'), default=''))" "$1" 2>/dev/null || true; }
  dqt=$(firstpar "$WORK/spool4"); dqu=$(firstpar "$WORK/spool")   # U sends at once: its file before the quiet end shows Q held it
  logins login t1 t2 t3; waitfor 480 "$NOPARENT" || true
  dqh=$QUIET; unset QUIET   # the quiet channel leaves the configuration; its window kept for the line below
  { printf 'repository:\n  dsn: "host=repo port=5432 user=postgres password=%s dbname=pgvigil sslmode=disable"\ninstances:\n' "$PW"; instances target 5432; alerts_of /work; } > "$WORK/svc.yaml"
  docker exec "$SVC" sh -c "install -m 0640 -g pgvigil /work/svc.yaml /etc/pgvigil/pgvigil.yaml && systemctl restart pgvigil.service"
  keep DQ
  [[ "$dq1" == 1 && "$dqo" == 0 && -n "$dqt" && -n "$dqu" && "$dqu" < "$QEND" ]] && ! [[ "$dqt" < "$QEND" ]] \
    && ok "DQ: quiet hours $dqh UTC over the cut - the parent once on the quiet channel, its first file at $dqt (the quiet end $QEND; U's at $dqu, before it), t1-t3 0" \
    || fail "DQ: quiet $dqh: the parent $dq1 (want 1), first file '$dqt' (want at or after $QEND), U's '$dqu' (want before it), t1-t3 $dqo (want 0): $(ls "$WORK/spool4" | tr '\n' ' ' | cut -c1-500)"
fi
logins login t1 t2 t3 t4

# ---- F many collectors on one repository ---------------------------------------------------------------------------
if want F; then
timeout 240 "$BIN" run -config "$WORK/host.yaml" > "$WORK/second.log" 2>&1 &
SECOND=$!
if waitfor 200 "SELECT count(DISTINCT f.instance_id) = 4 FROM pgvigil.collector_findings f WHERE f.setting = 'collected by more than one collector'"; then
  up=$(api '' | jget collectors | python3 -c "import json,sys; print(sum(1 for r in json.load(sys.stdin) if r['state'] == 'up'))")
  [[ "$up" == 2 ]] && kill -0 $SECOND 2>/dev/null \
    && ok "F many: a second collector on $(hostname) runs beside pgvigil-svc (not refused; the page: $up up); 'collected by more than one collector' on t1-t4: $(q "SELECT detail FROM pgvigil.collector_findings WHERE setting = 'collected by more than one collector' LIMIT 1" | cut -c1-200)" \
    || fail "F many: up $up (want 2), the second alive $(kill -0 $SECOND 2>/dev/null && echo yes || echo no): $(tail -3 "$WORK/second.log" | tr '\n' ' ' | cut -c1-400)"
else fail "F many: no 'collected by more than one collector' on the 4 instances in 200 s: $(tail -3 "$WORK/second.log" | tr '\n' ' ' | cut -c1-400)"; fi
kill -TERM $SECOND 2>/dev/null || true; wait $SECOND 2>/dev/null || true; SECOND=""
waitfor 60 "SELECT (SELECT count(*) FROM pgvigil.collector_live) = 1" || fail "F many: the second collector still live 60 s after it was stopped"
sleep 130   # pgvigil-svc beats past the second collector's stop: the second's instances are read by another host since

fi

# ---- B the service stopped -----------------------------------------------------------------------------------------
if want B; then
waitfor 150 "SELECT count(*) = 1 FROM pgvigil.collector_live" || true
rm -f "$WORK"/spool/* "$WORK"/spool2/*
docker exec "$SVC" systemctl stop pgvigil.service
sleep 5
st=$(api '' | jget collectors | python3 -c "import json,sys; r=max((x for x in json.load(sys.stdin) if x['host'] == 'pgvigil-svc'), key=lambda x: x['started_at']); print(r['state'])")
[[ "$st" == stopped ]] && ok "B stopped: the page says '$st' at once (a clean stop)" || fail "B stopped: the page says '$st'"
if waitfor 600 "SELECT EXISTS (SELECT 1 FROM pgvigil.collector_parent WHERE why = 'collector not seen' AND host = 'pgvigil-svc')"; then
  sleep 130   # serve's watchdog: its next minute
  sent=$(spool_n firing "collector or network"); sent2=$(SPOOL=$WORK/spool2 spool_n firing "collector or network")
  heldb=$(q "SELECT string_agg(i.name, ' ' ORDER BY i.name) FROM pgvigil.collector_held_instances h JOIN pgvigil.instances i USING (instance_id)")
  [[ "$sent" == 1 && "$sent2" == 1 && "$heldb" == "t1 t2 t3 t4" ]] && grep -qE 'collector_down(=|":)true' "$WORK/serve.log" \
    && ok "B not seen: 'collector or network' (collector not seen: pgvigil-svc) after $(q "SELECT floor(extract(epoch FROM now() - max(beat_at)) / 60) FROM pgvigil.collector_heartbeat WHERE host = 'pgvigil-svc'") min, sent once on each channel by serve's watchdog; held: $heldb" \
    || fail "B not seen: alerts $sent / scoped $sent2 (want 1 / 1), held '$heldb' (want t1 t2 t3 t4); serve log: $(grep -i watchdog "$WORK/serve.log" | tail -3 | tr '\n' ' ' | cut -c1-400)"
else fail "B not seen: no 'collector not seen' 8 min after the stop"; fi
docker exec "$SVC" systemctl start pgvigil.service
waitfor 200 "SELECT (SELECT count(*) FROM pgvigil.collector_live) = 1 AND NOT EXISTS (SELECT 1 FROM pgvigil.collector_parent)" \
  && ok "B started: up again, the parent cleared" || fail "B started: not up with the parent cleared in 200 s"

fi

# ---- G purge -------------------------------------------------------------------------------------------------------
if want G; then
q "UPDATE pgvigil.instances SET first_seen = now() - interval '3 days' WHERE name = 't1'" >/dev/null
before=$(q "SELECT value FROM pgvigil.collector_findings WHERE setting = 'purge not run in 2 days'")
old=$(date -u -d '-4 months' +%Y%m)
q "CREATE TABLE IF NOT EXISTS pgvigil.wait_sample_$old PARTITION OF pgvigil.wait_sample FOR VALUES FROM ('$(date -u -d "-4 months" +%Y-%m-01)') TO ('$(date -u -d "-3 months" +%Y-%m-01)')" >/dev/null 2>&1 \
  || q "SELECT pgvigil.ensure_month_partition('wait_sample', '$(date -u -d '-4 months' +%Y-%m-15)'::timestamptz)" >/dev/null 2>&1 || true
"$BIN" purge -config "$WORK/host.yaml" > "$WORK/purge.out" 2>&1 || true
row=$(q "SELECT days || ' days, ' || cardinality(partitions_dropped) || ' partition(s): ' || array_to_string(partitions_dropped, ' ') || ', rows ' || rows_deleted FROM pgvigil.purge_runs ORDER BY run_id DESC LIMIT 1")
after=$(q "SELECT count(*) FROM pgvigil.collector_findings WHERE setting = 'purge not run in 2 days'")
page=$(api '' | jget repository | python3 -c "import json,sys; r=json.load(sys.stdin)[0]; print(r['purge_at'] is not None, r['purge_dropped'])")
[[ "$before" == never && -n "$row" && "$row" == *"wait_sample_$old"* && "$after" == 0 && "${page%% *}" == True ]] \
  && ok "G purge: the finding said '$before'; the run: $row; the page: $page; the finding gone" \
  || fail "G purge: finding before '$before', run '$row', after $after, page '$page': $(tail -2 "$WORK/purge.out" | tr '\n' ' ')"

fi

# ---- SC the scale arm (the last cases: they change the service's instance list) ------------------------------------
if want SC5 || want SC6 || want SC4 || want BH || want SV || want SC7 || want SL || want RT || want RT1 || want RT2; then
for n in 5 6 7 8 9 10 11 12; do psql "$TDSN" -Xq -v ON_ERROR_STOP=1 -c "create role l$n login password 'p$n' in role pg_monitor" -c "create database db$n owner l$n" >/dev/null; done
instances12() { # $1 host, $2 port: t1-t12, each with 'activity' every 10 s (a cut at :20 reaches every cut instance in its first minute)
  local n; for n in $(seq 1 12); do printf '  - name: t%s\n    dsn: "host=%s port=%s user=l%s password=p%s dbname=db%s sslmode=disable"\n    schedules: {activity: 10s}\n' "$n" "$1" "$2" "$n" "$n" "$n"; done
}
{ printf 'repository:\n  dsn: "host=repo port=5432 user=postgres password=%s dbname=pgvigil sslmode=disable"\ninstances:\n' "$PW"; instances12 target 5432; alerts_of /work; } > "$WORK/svc12.yaml"
docker exec "$SVC" sh -c "install -m 0640 -g pgvigil /work/svc12.yaml /etc/pgvigil/pgvigil.yaml && systemctl restart pgvigil.service"
ALL12="t1 t2 t3 t4 t5 t6 t7 t8 t9 t10 t11 t12"; CUT5="t1|t2|t3|t4|t5"; CUT4="t1|t2|t3|t4"
# the 12 collected by the restarted service: two written minutes each in the last 3
waitfor 300 "SELECT count(*) = 12 FROM (SELECT l.instance_id FROM pgvigil.collector_load l JOIN pgvigil.instances i USING (instance_id) WHERE i.name ~ '^t([1-9]|1[0-2])\$' AND l.minute > now() - interval '3 minutes' AND l.runs > 0 GROUP BY l.instance_id HAVING count(*) >= 2) x" \
  || fail "SC: the 12 instances not all collected 300 s after the restart: $(q "SELECT count(DISTINCT l.instance_id) FROM pgvigil.collector_load l WHERE l.minute > now() - interval '3 minutes'") seen"
# sc_clean: every login back, no parent, nothing held, no refusal standing, a pass after it; the spools emptied
sc_clean() { # shellcheck disable=SC2086
  logins login $ALL12; waitfor 600 "$NOPARENT" || fail "SC: not clean 600 s after the logins came back"; sleep 70; rm -f "$WORK"/spool*/*; }
# sc_k NAMES EPOCH: how many of the instances NAMES ('a|b') had a failed run in the minute of EPOCH
sc_k() { q "SELECT count(DISTINCT l.instance_id) FROM pgvigil.collector_load l JOIN pgvigil.instances i USING (instance_id) WHERE i.name ~ '^($1)\$' AND l.failures > 0 AND l.minute = date_trunc('minute', to_timestamp($2))"; }

if want SC5; then
  sc_clean; pin_at 20; logins nologin t1 t2 t3 t4 t5; sc_t0=$SECONDS; sc_c0=$(date -u +%s)
  sc_tp=$(within 185 "$WORK/spool" firing "$PAR" "")
  sc_left=$(( 300 - (SECONDS - sc_t0) )); if (( sc_left > 0 )); then sleep "$sc_left"; fi
  snap SC5; sc_L=$WORK/SC5.lst
  sc_up=$(cnt "$WORK/spool" firing "$PAR" ""); sc_sp=$(cnt "$WORK/spool2" firing "$PAR" "")
  sc_pr=$(per "$WORK/spool" firing "$CUT5"); sc_pr2=$(per "$WORK/spool2" firing t1)
  sc_k5=$(sc_k "$CUT5" "$sc_c0")
  sc_det=$(q "SELECT coalesce(max(split_part(detail, ' in the minute', 1)), '-') FROM pgvigil.collector_parent WHERE why = 'instances failing together'")
  logins login t1 t2 t3 t4 t5
  waitfor 480 "$NOPARENT" || fail "SC5: the parent still standing 480 s after the lift"
  SKIP=$sc_L within 240 "$WORK/spool" resolved "$PAR" "" >/dev/null; SKIP=$sc_L within 60 "$WORK/spool2" resolved "$PAR" "" >/dev/null
  sleep 60   # one more pass: nothing of the five may follow the parent's recovery
  sc_ur=$(SKIP=$sc_L cnt "$WORK/spool" resolved "$PAR" ""); sc_sr=$(SKIP=$sc_L cnt "$WORK/spool2" resolved "$PAR" "")
  sc_af=$(SKIP=$sc_L per "$WORK/spool" firing "$CUT5"); sc_ar=$(per "$WORK/spool" resolved "$CUT5")
  keep SC5
  if [[ "$sc_tp" -ge 0 && "$sc_up" == 1 && "$sc_sp" == 1 && "$sc_k5" == 5 && "$sc_pr" == 0 && "$sc_pr2" == 0 && "$sc_det" == "5 of the 12 instance(s) pgvigil-svc ran failed every run" && "$sc_ur" == 1 && "$sc_sr" == 1 && "$sc_af" == 0 && "$sc_ar" == 0 ]]; then
    ok "SC5: 5 of 12 cut (t1-t5, under half) at :20 for 5 min - 'collector or network' sent $sc_tp s after the cut, once on U and once on S, its text '$sc_det'; $sc_k5 of the five failed a run in the cut's minute and their own alerts are $sc_pr (S: t1 $sc_pr2); after the lift the parent resolved once on each, the five sent $sc_af, resolved $sc_ar"
  else
    fail "SC5: parent $sc_tp s after the cut (want 0-185), U $sc_up / S $sc_sp (want 1 / 1), text '$sc_det' (want '5 of the 12 instance(s) pgvigil-svc ran failed every run'), $sc_k5 of the five failed in the cut's minute (want 5), their own alerts $sc_pr / S $sc_pr2 (want 0 / 0); after the lift: parent resolved U $sc_ur / S $sc_sr (want 1 / 1), the five sent $sc_af resolved $sc_ar (want 0 0): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-700)"
  fi
fi
if want SC6; then
  # 5 standing + 1 new (DONE-2 N2): each refusal its own onset, 5 minutes apart (a cohort holds the spells begun within
  # the span plus 3 minutes of one another; the span here is 1 minute) - no parent at any time, each alerts on its own
  # both holds read: the parent's instances (collector_held_instances) and the forming wait (collector_forming: one
  # new refusal of 12 is no shared cause, so it stays empty)
  sc_clean; sc6_par=0; sc6_held=0; sc6_form=0; ONE6="t1|t2|t3|t4|t5|t6"
  sc6_watch() { local end=$((SECONDS + $1)); while (( SECONDS < end )); do
      [[ "$(q "SELECT count(*) FROM pgvigil.collector_parent")" == 0 ]] || sc6_par=$((sc6_par + 1))
      [[ "$(q "SELECT EXISTS (SELECT 1 FROM pgvigil.collector_held_instances)")" == f ]] || sc6_held=$((sc6_held + 1))
      [[ "$(q "SELECT count(*) FROM pgvigil.collector_forming")" == 0 ]] || sc6_form=$((sc6_form + 1))
      sleep 20; done; }
  for n in 1 2 3 4 5; do logins nologin "t$n"; sc6_watch 300; done
  logins nologin t6; sc6_watch 180
  snap SC6; sc_L=$WORK/SC6.lst
  sc6_a=$(cnt "$WORK/spool" firing "authentication failing" "$ONE6"); sc6_c=$(cnt "$WORK/spool" firing "collection failing|server unreachable" "$ONE6" "$(plain)")
  sc6_p=$(cnt "$WORK/spool" firing "$PAR" ""); sc6_s=$(cnt "$WORK/spool2" firing "authentication failing" t1)
  logins login t1 t2 t3 t4 t5 t6; waitfor 300 "$NOPARENT" || true
  within 240 "$WORK/spool" resolved "authentication failing" "$ONE6" 6 >/dev/null
  sc6_r=$(cnt "$WORK/spool" resolved "authentication failing" "$ONE6")
  keep SC6
  [[ "$sc6_par" == 0 && "$sc6_held" == 0 && "$sc6_form" == 0 && "$sc6_a" == 6 && "$sc6_c" == 0 && "$sc6_p" == 0 && "$sc6_s" == 1 && "$sc6_r" == 6 ]] \
    && ok "SC6: 5 standing + 1 new - t1-t5 refused 5 minutes apart, then t6: no parent at any read (every 20 s for 28 min), nothing held, nothing forming; 'authentication failing' once each for the six (S: t1 once), no 'collection failing' / 'server unreachable', no 'collector or network'; resolved once each after" \
    || fail "SC6: reads with a parent $sc6_par (want 0), with held instances $sc6_held (want 0), with instances forming $sc6_form (want 0); U auth $sc6_a (want 6), collection / unreachable $sc6_c (want 0), parent sent $sc6_p (want 0), S auth $sc6_s (want 1); resolved $sc6_r (want 6)"
fi
if want SC4; then
  sc_clean; pin_at 20; logins nologin t1 t2 t3 t4; sc_t0=$SECONDS; sc_tw=-1
  while (( SECONDS - sc_t0 < 125 )); do [[ "$(cnt "$WORK/spool" firing "authentication failing" "$CUT4")" == 4 ]] && { sc_tw=$((SECONDS - sc_t0)); break; }; sleep 5; done
  sc_left=$(( 240 - (SECONDS - sc_t0) )); if (( sc_left > 0 )); then sleep "$sc_left"; fi   # the cut stands 4 min: nothing more goes out
  sc_a=$(cnt "$WORK/spool" firing "authentication failing" "$CUT4"); sc_c=$(cnt "$WORK/spool" firing "collection failing|server unreachable" "$CUT4" "$(plain)")
  sc_p=$(cnt "$WORK/spool" firing "$PAR" ""); sc_h=$(q "SELECT EXISTS (SELECT 1 FROM pgvigil.collector_held_instances)"); sc_s=$(cnt "$WORK/spool2" firing "authentication failing" t1)
  logins login t1 t2 t3 t4; waitfor 300 "$NOPARENT" || true
  within 240 "$WORK/spool" resolved "authentication failing" "$CUT4" 4 >/dev/null; within 60 "$WORK/spool2" resolved "authentication failing" t1 >/dev/null
  sc_r=$(cnt "$WORK/spool" resolved "authentication failing" "$CUT4"); sc_rs=$(cnt "$WORK/spool2" resolved "authentication failing" t1)
  keep SC4
  [[ "$sc_tw" -ge 0 && "$sc_a" == 4 && "$sc_c" == 0 && "$sc_p" == 0 && "$sc_h" == f && "$sc_s" == 1 && "$sc_r" == 4 && "$sc_rs" == 1 ]] \
    && ok "SC4: 4 of 12 cut (t1-t4) at :20 for 4 min - no parent, nothing held; 'authentication failing' once each within $sc_tw s of the cut (S: t1 once), no 'collection failing' / 'server unreachable'; resolved once each after (S: t1 once)" \
    || fail "SC4: the four auth after $sc_tw s (want 0-125), U auth $sc_a (want 4), collection / unreachable $sc_c (want 0), parent $sc_p (want 0), held $sc_h (want f), S auth $sc_s (want 1); resolved U $sc_r (want 4), S $sc_rs (want 1): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-500)"
fi
if want BH; then
  # t13: a black-holed server - TEST-NET-1 (RFC 5737) is routed nowhere, its SYN never answered - and no connect_timeout
  # in its DSN: the service's connect ends at the 10 s default (DONE-2 N10), so its first failed connect is written within
  # 45 s of the restart (the first run starts 0-10 s in); without the default the operating system waits about 127 s
  { printf 'repository:\n  dsn: "host=repo port=5432 user=postgres password=%s dbname=pgvigil sslmode=disable"\ninstances:\n' "$PW"; instances12 target 5432
    printf '  - name: t13\n    dsn: "host=192.0.2.1 port=5432 user=l13 password=p13 dbname=db13 sslmode=disable"\n    schedules: {activity: 10s}\n'
    alerts_of /work; } > "$WORK/svc13.yaml"
  rm -f "$WORK"/spool*/*
  docker exec "$SVC" sh -c "install -m 0640 -g pgvigil /work/svc13.yaml /etc/pgvigil/pgvigil.yaml && systemctl restart pgvigil.service"; bh_t0=$(date -u +%s)
  bh_tw=$(within 300 "$WORK/spool" firing "server unreachable" t13)
  bh_q="FROM pgvigil.collector_streaks s JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 't13' AND s.collection = '(connect)'"
  bh_since=$(q "SELECT coalesce(min(extract(epoch FROM s.failing_since))::bigint::text, '-') $bh_q")
  bh_err=$(q "SELECT coalesce(max(s.last_error), '-') $bh_q")
  # one finding per server: two more alert passes before the count (0118's own 'server unreachable' beside 0121's would
  # land a pass later), and no 'collection failing' for t13
  sleep 130
  bh_n=$(cnt "$WORK/spool" firing "server unreachable" t13); bh_cf=$(cnt "$WORK/spool" firing "collection failing" t13)
  bh_d=-1; if [[ "$bh_since" =~ ^[0-9]+$ ]]; then bh_d=$(( bh_since - bh_t0 )); fi
  keep BH
  if [[ "$bh_d" -ge 0 && "$bh_d" -le 45 && "$bh_err" =~ [Tt]imeout|deadline && "$bh_n" == 1 && "$bh_cf" == 0 ]]; then
    ok "BH: t13 at 192.0.2.1 (black-holed, no connect_timeout): its first failed connect written $bh_d s after the service's restart (the 10 s default), its error '$(echo "$bh_err" | cut -c1-160)'; 'server unreachable' once on U ($bh_tw s after the restart, counted two passes later), no 'collection failing'"
  elif [[ "$bh_err" =~ "no route"|"network is unreachable"|refused ]]; then
    fail "BH: 192.0.2.1 answered at once on this box ('$(echo "$bh_err" | cut -c1-160)'): no black hole here, so this row does not show the 10 s default"
  else
    fail "BH: first failed connect $bh_d s after the restart (want 0-45), error '$(echo "$bh_err" | cut -c1-200)' (want a timeout), 'server unreachable' on U $bh_n (want 1) after $bh_tw s, 'collection failing' $bh_cf (want 0)"
  fi
  # the 12-instance file back after the verdict: a failed restore cannot take BH's line with it
  docker exec "$SVC" sh -c "install -m 0640 -g pgvigil /work/svc12.yaml /etc/pgvigil/pgvigil.yaml && systemctl restart pgvigil.service"
fi
if want SV; then
  # SV (DONE-2 N8): a second target server - target2 (PostgreSQL 18, alias target2) with t16-t18 beside t1-t12 on
  # target - stopped: every connect of t16-t18 gets no answer (the name leaves the network). The server's own quorum
  # (all four: one dial target, no answer, new, every instance of it): ONE 'collector or network' claiming 'server
  # postgres:target2:5432 not answering', t16-t18 held (none of their 'server unreachable' sent), nothing of t1-t12 held;
  # target2 started again: the parent resolved once
  docker run -d --name "$TGT2" --network "$NET" --network-alias target2 -e POSTGRES_PASSWORD="$PW" postgres:18 >/dev/null
  for _ in $(seq 1 60); do docker exec "$TGT2" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done; sleep 3
  for n in 16 17 18; do docker exec "$TGT2" psql -U postgres -Xq -v ON_ERROR_STOP=1 -c "create role l$n login password 'p$n' in role pg_monitor" -c "create database db$n owner l$n" >/dev/null; done
  { printf 'repository:\n  dsn: "host=repo port=5432 user=postgres password=%s dbname=pgvigil sslmode=disable"\ninstances:\n' "$PW"; instances12 target 5432
    for n in 16 17 18; do printf '  - name: t%s\n    dsn: "host=target2 port=5432 user=l%s password=p%s dbname=db%s sslmode=disable"\n    schedules: {activity: 10s}\n' "$n" "$n" "$n" "$n"; done
    alerts_of /work; } > "$WORK/svc15.yaml"
  docker exec "$SVC" sh -c "install -m 0640 -g pgvigil /work/svc15.yaml /etc/pgvigil/pgvigil.yaml && systemctl restart pgvigil.service"
  sv_ok=1; waitfor 300 "SELECT count(*) = 3 FROM (SELECT l.instance_id FROM pgvigil.collector_load l JOIN pgvigil.instances i USING (instance_id) WHERE i.name IN ('t16','t17','t18') AND l.target = 'postgres:target2:5432' AND l.opened > 0 AND l.minute > now() - interval '3 minutes' GROUP BY 1 HAVING count(*) >= 2) x" || sv_ok=0
  waitfor 300 "$NOPARENT" || true   # review part E's nit 7: SV starts from a clean state (no parent standing)
  rm -f "$WORK"/spool*/*
  docker stop "$TGT2" >/dev/null
  sv_tp=$(within 300 "$WORK/spool" firing "$PAR" "")
  sv_claim=$(q "SELECT coalesce(max(regexp_replace(pgvigil.collector_claim(detail), ' from [0-9-]+ [0-9:]+ UTC\$', ' from <t>')), '-') FROM pgvigil.collector_findings WHERE setting = 'collector or network'")
  sv_why=$(q "SELECT coalesce(string_agg(why, ','), '-') FROM pgvigil.collector_parent")
  sv_held=$(q "SELECT coalesce(string_agg(i.name, ' ' ORDER BY i.name), '-') FROM pgvigil.collector_held_instances h JOIN pgvigil.instances i USING (instance_id)")
  sleep 130   # two alert passes: nothing more of t16-t18 may go out while the parent stands
  sv_n=$(cnt "$WORK/spool" firing "$PAR" ""); sv_su=$(cnt "$WORK/spool" firing "server unreachable|collection failing" "t16|t17|t18")
  docker start "$TGT2" >/dev/null; waitfor 480 "$NOPARENT" || true
  within 240 "$WORK/spool" resolved "$PAR" "" >/dev/null; sv_r=$(cnt "$WORK/spool" resolved "$PAR" "")
  # review part D's D-1: a member whose connects in the restart's minute fell before target2 came back waits as a
  # cohort's straggler does - none of t16-t18's own alerts in two more alert passes after the parent resolved
  sleep 130; sv_after=$(cnt "$WORK/spool" firing "server unreachable|collection failing" "t16|t17|t18")
  keep SV
  if [[ "$sv_ok" == 1 && "$sv_tp" -ge 0 && "$sv_n" == 1 && "$sv_claim" == "server postgres:target2:5432 not answering from <t>" && "$sv_why" == "server not answering" && "$sv_held" == "t16 t17 t18" && "$sv_su" == 0 && "$sv_r" == 1 && "$sv_after" == 0 ]]; then
    ok "SV: target2 (t16-t18) stopped - 'collector or network' $sv_tp s after, once on U, claiming '$sv_claim'; held $sv_held, none of their own alerts; t1-t12 not held; started again: resolved once, none of their own alerts after it"
  else
    fail "SV: t16-t18 read through target2 first $sv_ok (want 1); parent $sv_tp s after the stop (want 0-300), sent $sv_n (want 1), claim '$sv_claim' (want 'server postgres:target2:5432 not answering from <t>'), why '$sv_why', held '$sv_held' (want 't16 t17 t18'), their own alerts $sv_su (want 0), resolved $sv_r (want 1), their own alerts after the resolve $sv_after (want 0): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-500)"
  fi
  docker exec "$SVC" sh -c "install -m 0640 -g pgvigil /work/svc12.yaml /etc/pgvigil/pgvigil.yaml && systemctl restart pgvigil.service"
fi
# ---- SC7 / SL the slow-connect tier on the service: a proxy that delays new connections, the root's connect_time
# threshold low and warning = critical (0.10 / 0.10 s): one slow minute in an instance's 5-minute window is over it, and
# a slow member is critical with its fold (a member above a WARNING fold is sent on its own, as designed: the SQL rows
# C27l (one instance) and C27n (a server under a warning collector fold) prove that edge, C27p a fold falling from
# critical to warning, not this case). The delay starts only after 5 written minutes through the new address (a
# restart runs every collection once within 5 minutes: those minutes hold far more connects than a later one, and a
# window full of them would dilute the first slow minute); it is lifted at :57, so a connect held 2 s ends before the
# minute turns and the lift's minute is fast
if want SC7 || want SL; then
  # slowp: every new connection on its ports waits /tmp/delay seconds (none: 0), then goes on to target:5432
  cat > "$WORK/slowp.py" <<'PY'
import asyncio, sys

def delay():
    try:
        with open('/tmp/delay') as f:
            return float(f.read().strip() or 0)
    except (OSError, ValueError):
        return 0.0

async def pipe(r, w):
    try:
        while True:
            b = await r.read(65536)
            if not b:
                break
            w.write(b)
            await w.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        w.close()

async def handle(cr, cw):
    d = delay()
    if d > 0:
        await asyncio.sleep(d)
    try:
        ur, uw = await asyncio.open_connection('target', 5432)
    except OSError:
        cw.close()
        return
    await asyncio.gather(pipe(cr, uw), pipe(ur, cw))

async def main():
    servers = [await asyncio.start_server(handle, '0.0.0.0', int(p)) for p in sys.argv[1:]]
    print('slowp on', ' '.join(sys.argv[1:]), flush=True)
    await asyncio.gather(*(s.serve_forever() for s in servers))

asyncio.run(main())
PY
  docker image inspect python:3-slim >/dev/null 2>&1 || docker pull -q python:3-slim >/dev/null || fail "SC7 / SL: docker pull python:3-slim"
  docker run -d --name "$SLP" --network "$NET" --network-alias slowp -v "$WORK/slowp.py:/slowp.py:ro" python:3-slim python3 -u /slowp.py 6001 6002 6003 6004 6005 >/dev/null
  for _ in $(seq 1 30); do docker logs "$SLP" 2>&1 | grep -q 'slowp on' && break; sleep 1; done
  slow() { docker exec "$SLP" sh -c "echo $1 > /tmp/delay"; }
  # thr WARN CRIT: the root's connect_time threshold set; prints the outcome ('error': the repository has no such function)
  thr() { q "SELECT pgvigil.import_pg_threshold(now(), jsonb_build_object('op', 'set', 'ui_user', 'proof', 'key', 'connect_time', 'level', 'root', 'warn', $1, 'crit', $2))->>'outcome'" || echo error; }
  svc_head() { printf 'repository:\n  dsn: "host=repo port=5432 user=postgres password=%s dbname=pgvigil sslmode=disable"\ninstances:\n' "$PW"; }
  inst() { printf '  - name: t%s\n    dsn: "host=%s port=%s user=l%s password=p%s dbname=db%s sslmode=disable"\n    schedules: {activity: 10s}\n' "$1" "$2" "$3" "$1" "$1" "$1"; }
  { svc_head; for n in $(seq 1 12); do inst "$n" slowp $((6001 + (n - 1) / 3)); done; alerts_of /work; } > "$WORK/svc-sc7.yaml"
  { svc_head; inst 1 slowp 6005; for n in $(seq 2 12); do inst "$n" target 5432; done; alerts_of /work; } > "$WORK/svc-sl.yaml"
  sc_dial() { docker exec "$SVC" sh -c "install -m 0640 -g pgvigil /work/$1 /etc/pgvigil/pgvigil.yaml && systemctl restart pgvigil.service"; }
  # sc_through NAMES TARGET N: N of the instances NAMES (a regex) with 5 written minutes of opened connects through
  # TARGET (a LIKE pattern) in the last 7
  sc_through() { waitfor 540 "SELECT count(*) = $3 FROM (SELECT l.instance_id FROM pgvigil.collector_load l JOIN pgvigil.instances i USING (instance_id) WHERE i.name ~ '^($1)\$' AND l.target LIKE '$2' AND l.opened > 0 AND l.minute > now() - interval '7 minutes' GROUP BY 1 HAVING count(*) >= 5) x"; }
  slow 0; sc_thr=$(thr 0.10 0.10)
fi
if want SC7; then
  # t1-t12 through slowp's four ports (three each): the delay of 2 s for 5 minutes - ONE 'slow connects' (the host fold)
  sc_clean; sc_dial svc-sc7.yaml
  sc7_in=1; sc_through 't([1-9]|1[0-2])' 'postgres:slowp:600_' 12 || sc7_in=0
  waitfor 300 "$NOPARENT" || true; sleep 65; rm -f "$WORK"/spool*/*
  sc7_b=$(q "SELECT count(*) FROM pgvigil.collector_connects WHERE level > 0") || sc7_b=error
  pin_at 3; slow 2; sc7_t0=$SECONDS
  sc7_tp=$(within 300 "$WORK/spool" firing "slow connects" "")
  sc_left=$(( 300 - (SECONDS - sc7_t0) )); if (( sc_left > 0 )); then sleep "$sc_left"; fi
  sc7_f=$(q "SELECT coalesce(string_agg(kind || ' ' || value || ' ' || level || CASE WHEN under_host THEN ' under' ELSE '' END || ' ' || cardinality(members), '; ' ORDER BY kind, value), '-') FROM pgvigil.collector_slow_folds") || sc7_f=error
  sc7_h=$(q "SELECT count(*) FROM pgvigil.collector_slow_held") || sc7_h=error
  sc7_a=$(q "SELECT coalesce(min(avg_s) || ' - ' || max(avg_s) || ' s', '-') FROM pgvigil.collector_connects WHERE target LIKE 'postgres:slowp:%'") || sc7_a=error
  sc7_d=$(q "SELECT coalesce(max(detail), '-') FROM pgvigil.collector_slow_folds WHERE kind = 'host'") || sc7_d=error
  snap SC7; sc_L=$WORK/SC7.lst
  sc7_u=$(cnt "$WORK/spool" firing "slow connects" ""); sc7_ut=$(cnt "$WORK/spool" firing "slow connects" "" "pgvigil-svc")
  sc7_s=$(cnt "$WORK/spool2" firing "slow connects" ""); sc7_m=$(cnt "$WORK/spool" firing "slow connect" ""); sc7_m2=$(cnt "$WORK/spool2" firing "slow connect" "")
  pin_at 57; slow 0
  sc7_tr=-1; if [[ "$sc7_tp" -ge 0 ]]; then sc7_tr=$(SKIP=$sc_L within 600 "$WORK/spool" resolved "slow connects" ""); fi
  sleep 130   # two more passes: no member's own alert after the fold's recovery
  sc7_r=$(cnt "$WORK/spool" resolved "slow connects" ""); sc7_n=$(cnt "$WORK/spool" firing "slow connects" ""); sc7_x=$(cnt "$WORK/spool" firing "slow connect" "")
  keep SC7
  SC7_F="host pgvigil-svc 2 12; target postgres:slowp:6001 2 under 3; target postgres:slowp:6002 2 under 3; target postgres:slowp:6003 2 under 3; target postgres:slowp:6004 2 under 3"
  if [[ "$sc_thr" == done && "$sc7_in" == 1 && "$sc7_b" == 0 && "$sc7_tp" -ge 0 && "$sc7_tp" -le 240 && "$sc7_u" == 1 && "$sc7_ut" == 0 && "$sc7_s" == 1 \
        && "$sc7_m" == 0 && "$sc7_m2" == 0 && "$sc7_f" == "$SC7_F" && "$sc7_h" == 12 \
        && "$sc7_d" == "connects slow from collector pgvigil-svc: 4 of its 4 judged target(s) over their warning"* \
        && "$sc7_tr" -ge 0 && "$sc7_r" == 1 && "$sc7_n" == 1 && "$sc7_x" == 0 ]]; then
    ok "SC7: t1-t12 through slowp's four ports held 2 s for 5 minutes (connect_time 0.10 / 0.10 s) - 'slow connects' $sc7_tp s after, once on U and S, valued pgvigil-svc; the folds '$sc7_f', $sc7_h held, averages $sc7_a; no 'slow connect' sent; the detail '$(echo "$sc7_d" | cut -c1-240)'; lifted: resolved once $sc7_tr s after, nothing after it"
  else
    fail "SC7: threshold '$sc_thr' (want done), the 12 through slowp $sc7_in (want 1), slow before the delay $sc7_b (want 0); 'slow connects' $sc7_tp s after (want 0-240), U $sc7_u (want 1), of another value $sc7_ut (want 0), S $sc7_s (want 1); 'slow connect' U $sc7_m / S $sc7_m2 (want 0 / 0); folds '$sc7_f' (want '$SC7_F'), held $sc7_h (want 12), averages $sc7_a, detail '$(echo "$sc7_d" | cut -c1-200)'; lifted: resolved after $sc7_tr s, $sc7_r (want 1), sent in all $sc7_n (want 1), members after $sc7_x (want 0): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-500)"
  fi
fi
if want SL; then
  # t1 alone through slowp (port 6005), t2-t12 direct: the delay of 2 s for 4 minutes - t1's own 'slow connect' only
  sc_clean; sc_dial svc-sl.yaml
  sl_in=1; sc_through 't1' 'postgres:slowp:6005' 1 || sl_in=0
  sc_through 't([2-9]|1[0-2])' 'postgres:target:5432' 11 || sl_in=0
  waitfor 300 "$NOPARENT" || true; sleep 65; rm -f "$WORK"/spool*/*
  sl_b=$(q "SELECT count(*) FROM pgvigil.collector_connects WHERE level > 0") || sl_b=error
  pin_at 3; slow 2; sl_t0=$SECONDS
  sl_tp=$(within 300 "$WORK/spool" firing "slow connect" t1)
  sc_left=$(( 240 - (SECONDS - sl_t0) )); if (( sc_left > 0 )); then sleep "$sc_left"; fi
  sl_f=$(q "SELECT count(*) FROM pgvigil.collector_slow_folds") || sl_f=error
  sl_c=$(q "SELECT coalesce(string_agg(name || ' ' || level || ' ' || avg_s || ' s', ', ' ORDER BY name), '-') FROM pgvigil.collector_connects WHERE level > 0") || sl_c=error
  snap SL; sc_L=$WORK/SL.lst
  sl_u=$(cnt "$WORK/spool" firing "slow connect" t1); sl_o=$(cnt "$WORK/spool" firing "slow connect" "t2|t3|t4|t5|t6|t7|t8|t9|t10|t11|t12")
  sl_s=$(cnt "$WORK/spool2" firing "slow connect" t1); sl_fs=$(cnt "$WORK/spool" firing "slow connects" "")
  pin_at 57; slow 0
  sl_tr=-1; if [[ "$sl_tp" -ge 0 ]]; then sl_tr=$(SKIP=$sc_L within 600 "$WORK/spool" resolved "slow connect" t1); fi
  sl_r=$(cnt "$WORK/spool" resolved "slow connect" t1); sl_n=$(cnt "$WORK/spool" firing "slow connect" t1)
  keep SL
  if [[ "$sc_thr" == done && "$sl_in" == 1 && "$sl_b" == 0 && "$sl_tp" -ge 0 && "$sl_tp" -le 240 && "$sl_u" == 1 && "$sl_o" == 0 && "$sl_s" == 1 && "$sl_fs" == 0 \
        && "$sl_f" == 0 && "$sl_c" =~ ^t1\ 2\ [0-9.]+\ s$ && "$sl_tr" -ge 0 && "$sl_r" == 1 && "$sl_n" == 1 ]]; then
    ok "SL: t1 alone through slowp held 2 s for 4 minutes (connect_time 0.10 / 0.10 s) - its own 'slow connect' $sl_tp s after, once on U and S ('$sl_c'), no fold, no other instance's; lifted: resolved once $sl_tr s after"
  else
    fail "SL: threshold '$sc_thr' (want done), t1 through slowp and the rest direct $sl_in (want 1), slow before the delay $sl_b (want 0); t1's 'slow connect' $sl_tp s after (want 0-240), U $sl_u (want 1), the others' $sl_o (want 0), S $sl_s (want 1), 'slow connects' $sl_fs (want 0), folds $sl_f (want 0), slow '$sl_c' (want t1 alone, critical); lifted: resolved after $sl_tr s, $sl_r (want 1), sent in all $sl_n (want 1): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-500)"
  fi
fi
if want SC7 || want SL; then
  # the dial back first (slowp still answers while the service restarts), then slowp removed; the root's connect_time
  # row ended ('inherit': the built-in default again, no row left behind)
  docker exec "$SVC" sh -c "install -m 0640 -g pgvigil /work/svc12.yaml /etc/pgvigil/pgvigil.yaml && systemctl restart pgvigil.service"
  docker rm -f -v "$SLP" >/dev/null 2>&1 || true
  sc_thr2=$(q "SELECT pgvigil.import_pg_threshold(now(), jsonb_build_object('op', 'inherit', 'ui_user', 'proof', 'key', 'connect_time', 'level', 'root'))->>'outcome'" || echo error)
  [[ "$sc_thr" != done || "$sc_thr2" == done ]] || fail "SC7 / SL: the root's connect_time row ended ('inherit'): '$sc_thr2'"
fi
# ---- SC7 / SL end
# ---- RT / RT1 / RT2 B24h-1's query round trip and probe through the service (P5a: read from the views; the header's
# rows). slowq: one listener (argument 1) passing everything to target:5432, the frontend's untyped startup as it
# comes, then each 'Q' (a simple query) and 'S' (an extended-protocol Sync) held /tmp/qdelay seconds (none: 0) first
if want RT || want RT1 || want RT2; then
  cat > "$WORK/slowq.py" <<'PY'
import asyncio, struct, sys

def qdelay():
    try:
        with open('/tmp/qdelay') as f:
            return float(f.read().strip() or 0)
    except (OSError, ValueError):
        return 0.0

async def back(r, w):
    try:
        while True:
            b = await r.read(65536)
            if not b:
                break
            w.write(b)
            await w.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        w.close()

async def front(r, w):
    try:
        while True:  # the untyped startup; an SSLRequest / GSSENCRequest first is answered by the server, then the startup
            n = struct.unpack('!I', await r.readexactly(4))[0]
            body = await r.readexactly(n - 4)
            w.write(struct.pack('!I', n) + body)
            await w.drain()
            if struct.unpack('!I', body[:4])[0] not in (80877103, 80877104):
                break
        while True:
            hdr = await r.readexactly(5)
            body = await r.readexactly(struct.unpack('!I', hdr[1:])[0] - 4)
            if hdr[:1] in (b'Q', b'S'):
                d = qdelay()
                if d > 0:
                    await asyncio.sleep(d)
            w.write(hdr + body)
            await w.drain()
    except (asyncio.IncompleteReadError, ConnectionError, OSError, struct.error):
        pass
    finally:
        w.close()

async def handle(cr, cw):
    try:
        ur, uw = await asyncio.open_connection('target', 5432)
    except OSError:
        cw.close()
        return
    await asyncio.gather(front(cr, uw), back(ur, cw))

async def main():
    s = await asyncio.start_server(handle, '0.0.0.0', int(sys.argv[1]))
    print('slowq on', sys.argv[1], flush=True)
    await s.serve_forever()

asyncio.run(main())
PY
  docker image inspect python:3-slim >/dev/null 2>&1 || docker pull -q python:3-slim >/dev/null || fail "RT: docker pull python:3-slim"
  for k in 1 2 3 4; do docker run -d --name "$SLQ-$k" --network "$NET" --network-alias "slowq$k" -v "$WORK/slowq.py:/slowq.py:ro" python:3-slim python3 -u /slowq.py 6001 >/dev/null; done
  for k in 1 2 3 4; do for _ in $(seq 1 30); do docker logs "$SLQ-$k" 2>&1 | grep -q 'slowq on' && break; sleep 1; done; done
  qslow() { local k; for k in 1 2 3 4; do docker exec "$SLQ-$k" sh -c "echo $1 > /tmp/qdelay"; done; }
  rt_head() { printf 'repository:\n  dsn: "host=repo port=5432 user=postgres password=%s dbname=pgvigil sslmode=disable"\n%binstances:\n' "$PW" "${1:-}"; }
  rt_inst() { printf '  - name: t%s\n    dsn: "host=%s port=%s user=l%s password=p%s dbname=db%s sslmode=disable"\n    schedules: {activity: 10s}\n' "$1" "$2" "$3" "$1" "$1" "$1"; }
  { rt_head; for n in $(seq 1 12); do rt_inst "$n" "slowq$(( (n - 1) / 3 + 1 ))" 6001; done; alerts_of /work; } > "$WORK/svc-rt.yaml"
  { rt_head; rt_inst 1 slowq1 6001; for n in $(seq 2 12); do rt_inst "$n" target 5432; done; alerts_of /work; } > "$WORK/svc-rt1.yaml"
  { rt_head 'probe_every_minute: true\n'; for n in $(seq 1 12); do rt_inst "$n" "slowq$(( (n - 1) / 3 + 1 ))" 6001; done; alerts_of /work; } > "$WORK/svc-rt2.yaml"
  rt_dial() { docker exec "$SVC" sh -c "install -m 0640 -g pgvigil /work/$1 /etc/pgvigil/pgvigil.yaml && systemctl restart pgvigil.service"; }
  # rt_through NAMES TARGET N: N of the instances NAMES (a regex) with 3 or more measured round trips through TARGET (a
  # LIKE pattern) in the last 8 minutes
  rt_through() { waitfor 420 "SELECT count(*) = $3 FROM (SELECT l.instance_id FROM pgvigil.collector_load l JOIN pgvigil.instances i USING (instance_id) WHERE i.name ~ '^($1)\$' AND l.target LIKE '$2' AND l.rt_count > 0 AND l.minute > now() - interval '8 minutes' GROUP BY 1 HAVING count(*) >= 3) x"; }
  RT12='t([1-9]|1[0-2])'
  rt_slow() { q "SELECT coalesce(string_agg(name, ' ' ORDER BY name), '-') FROM pgvigil.collector_round_trips WHERE slow" || echo error; }
  rt_fold() { q "SELECT coalesce(string_agg(collector_host || ' ' || slow_hosts || '/' || hosts, '; '), '-') FROM pgvigil.collector_probe_fold" || echo error; }
  NOSLOW="SELECT NOT EXISTS (SELECT 1 FROM pgvigil.collector_probe_fold) AND NOT EXISTS (SELECT 1 FROM pgvigil.collector_round_trips WHERE slow)"
fi
if want RT; then
  rt_dial svc-rt.yaml
  rt_in=1; rt_through "$RT12" 'postgres:slowq_:6001' 12 || rt_in=0
  rt_b=$(rt_slow); rt_bf=$(rt_fold)
  qslow 0.1; rt_t0=$SECONDS
  rt_tp=-1; waitfor 480 "SELECT count(*) = 12 FROM pgvigil.collector_round_trips WHERE slow AND name ~ '^($RT12)\$'" && rt_tp=$((SECONDS - rt_t0))
  rt_f=$(rt_fold)
  rt_n=$(q "SELECT count(*) FROM pgvigil.collector_probe_findings WHERE setting = 'query round trip slow' AND source = 'pgvigil collector' AND value ~ '^($RT12)\$'" || echo error)
  rt_fd=$(q "SELECT coalesce(max(detail), '-') FROM pgvigil.collector_probe_findings WHERE setting = 'network slow from this collector' AND value = 'pgvigil-svc' AND source = 'pgvigil repository'" || echo error)
  rt_h=$(q "SELECT count(DISTINCT instance_id) || ' ' || count(*) FILTER (WHERE setting = 'query round trip slow') FROM pgvigil.collector_probe_held" || echo error)
  rt_hh=$(q "SELECT coalesce(string_agg(host, ' ' ORDER BY host), '-') FROM pgvigil.collector_probe_held_hosts" || echo error)
  rt_a=$(q "SELECT coalesce(min(avg_s) || ' - ' || max(avg_s) || ' s', '-') FROM pgvigil.collector_round_trips WHERE name ~ '^($RT12)\$'" || echo error)
  rt_d=$(q "SELECT coalesce(max(detail), '-') FROM pgvigil.collector_probe_findings WHERE setting = 'query round trip slow' AND value = 't1'" || echo error)
  rt_p=$(q "SELECT count(*) FROM pgvigil.collector_probe_findings WHERE setting IN ('ping slow', 'host not answering ping')" || echo error)
  qslow 0; rt_t1=$SECONDS
  rt_tr=-1; waitfor 600 "$NOSLOW" && rt_tr=$((SECONDS - rt_t1))
  if [[ "$rt_in" == 1 && "$rt_b" == - && "$rt_bf" == - && "$rt_tp" -ge 0 && "$rt_f" == "pgvigil-svc 4/4" && "$rt_n" == 12 \
        && "$rt_fd" == "4 of the 4 hosts this collector reads are slow"* && "$rt_h" == "12 12" && "$rt_hh" == "slowq1 slowq2 slowq3 slowq4" \
        && "$rt_d" == "query round trip (network and the server's response) "*"from pgvigil-svc; warning over 0.04"* && "$rt_p" == 0 && "$rt_tr" -ge 0 ]]; then
    ok "RT: t1-t12 through slowq1-slowq4 with each 'Q' / 'S' held 0.1 s - all 12 slow $rt_tp s after (averages $rt_a), the fold '$rt_f' ('$(echo "$rt_fd" | cut -c1-120)'), 12 'query round trip slow' held under it, held hosts '$rt_hh', no ping row; t1 '$(echo "$rt_d" | cut -c1-160)'; lifted: no fold, nothing slow $rt_tr s after"
  else
    fail "RT: the 12 through slowq $rt_in (want 1); before the delay slow '$rt_b' fold '$rt_bf' (want - / -); all 12 slow after $rt_tp s (want 0-480); fold '$rt_f' (want 'pgvigil-svc 4/4'); findings $rt_n (want 12); the fold's row '$(echo "$rt_fd" | cut -c1-160)'; held '$rt_h' (want '12 12'), held hosts '$rt_hh'; averages $rt_a; t1 '$(echo "$rt_d" | cut -c1-200)'; ping rows $rt_p (want 0); lifted after $rt_tr s (want 0-600)"
  fi
fi
if want RT1; then
  rt_dial svc-rt1.yaml
  r1_in=1; rt_through t1 'postgres:slowq1:6001' 1 || r1_in=0; rt_through 't([2-9]|1[0-2])' 'postgres:target:5432' 11 || r1_in=0
  waitfor 600 "$NOSLOW" || true; r1_b=$(rt_slow)
  qslow 0.1; r1_t0=$SECONDS
  r1_tp=-1; waitfor 480 "SELECT count(*) = 1 FROM pgvigil.collector_round_trips WHERE slow AND name = 't1'" && r1_tp=$((SECONDS - r1_t0))
  sleep 60   # one minute more: no other instance turns slow, no fold forms
  r1_s=$(rt_slow); r1_f=$(rt_fold)
  r1_n=$(q "SELECT coalesce(string_agg(setting || ' ' || value, ', ' ORDER BY setting, value), '-') FROM pgvigil.collector_probe_findings" || echo error)
  r1_h=$(q "SELECT count(*) FROM pgvigil.collector_probe_held" || echo error)
  r1_hosts=$(q "SELECT coalesce(string_agg(DISTINCT host, ' ' ORDER BY host), '-') FROM pgvigil.collector_probe_judged" || echo error)
  qslow 0; r1_t1=$SECONDS
  r1_tr=-1; waitfor 600 "$NOSLOW" && r1_tr=$((SECONDS - r1_t1))
  if [[ "$r1_in" == 1 && "$r1_b" == - && "$r1_tp" -ge 0 && "$r1_s" == t1 && "$r1_f" == - && "$r1_n" == "query round trip slow t1" && "$r1_h" == 0 \
        && "$r1_hosts" == "slowq1 target" && "$r1_tr" -ge 0 ]]; then
    ok "RT1: t1 alone through slowq1 held 0.1 s, t2-t12 direct - t1 slow $r1_tp s after, its 'query round trip slow' alone, no fold (judged hosts '$r1_hosts'), nothing held; lifted: nothing slow $r1_tr s after"
  else
    fail "RT1: t1 through slowq1 and the rest direct $r1_in (want 1); slow before '$r1_b' (want -); t1 slow after $r1_tp s (want 0-480); slow '$r1_s' (want t1); fold '$r1_f' (want -); findings '$r1_n' (want 'query round trip slow t1'); held $r1_h (want 0); judged hosts '$r1_hosts' (want 'slowq1 target'); lifted after $r1_tr s (want 0-600)"
  fi
fi
if want RT2; then
  r2_why=""
  if ! docker image inspect "$TCI" >/dev/null 2>&1; then
    mkdir -p "$WORK/tcimg"
    printf 'FROM debian:trixie-slim\nRUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends iproute2 >/dev/null && rm -rf /var/lib/apt/lists/*\n' > "$WORK/tcimg/Dockerfile"
    docker build -q -t "$TCI" "$WORK/tcimg" >/dev/null 2>"$WORK/tcimg.err" || r2_why="the tc image did not build: $(tail -2 "$WORK/tcimg.err" | tr '\n' ' ' | cut -c1-200)"
  fi
  tcq() { docker run --rm --net "container:$1" --cap-add NET_ADMIN "$TCI" sh -c "$2" 2>&1; }
  if [[ -z "$r2_why" ]]; then
    for k in 1 2 3 4; do e=$(tcq "$SLQ-$k" 'tc qdisc add dev eth0 root netem delay 50ms') || { r2_why="tc netem on slowq$k: $(echo "$e" | tail -2 | tr '\n' ' ' | cut -c1-200)"; break; }; done
  fi
  if [[ -n "$r2_why" ]]; then
    echo "NOT PROVEN RT2: $r2_why"
  else
    qslow 0; rt_dial svc-rt2.yaml; r2_t0=$SECONDS
    r2_tp=-1; waitfor 540 "SELECT count(*) = 12 FROM pgvigil.collector_probe_judged WHERE ping_slow AND name ~ '^($RT12)\$'" && r2_tp=$((SECONDS - r2_t0))
    r2_m=$(q "SELECT coalesce(string_agg(DISTINCT method, ' '), '-') || ' ' || coalesce(min(ping_avg_s) || ' - ' || max(ping_avg_s) || ' s', '-') FROM pgvigil.collector_probe_judged WHERE name ~ '^($RT12)\$'" || echo error)
    r2_hr=$(q "SELECT coalesce(string_agg(value, ' ' ORDER BY value), '-') FROM pgvigil.collector_probe_findings WHERE setting = 'ping slow' AND source = 'pgvigil repository'" || echo error)
    r2_ir=$(q "SELECT count(*) FROM pgvigil.collector_probe_findings WHERE setting = 'ping slow' AND source = 'pgvigil collector'" || echo error)
    r2_f=$(rt_fold); r2_h=$(q "SELECT count(*) FROM pgvigil.collector_probe_held WHERE setting = 'ping slow'" || echo error)
    for k in 1 2 3 4; do tcq "$SLQ-$k" 'tc qdisc del dev eth0 root' >/dev/null || true; done
    if [[ "$r2_tp" -ge 0 && "$r2_m" == "tcp 0.0"* && "$r2_hr" == "slowq1 slowq2 slowq3 slowq4" && "$r2_ir" == 12 && "$r2_f" == "pgvigil-svc 4/4" && "$r2_h" == 12 ]]; then
      ok "RT2: tc netem's 50 ms on slowq1-slowq4 (a sidecar on each one's network), probe_every_minute - every instance's ping slow $r2_tp s after ('$r2_m'), the hosts' rows '$r2_hr', 12 instance rows, the fold '$r2_f' holding the 12; the delay removed"
    else
      fail "RT2: all 12 ping_slow after $r2_tp s (want 0-540); method and averages '$r2_m' (want tcp, about 0.05 s); host rows '$r2_hr' (want slowq1-slowq4); instance rows $r2_ir (want 12); fold '$r2_f' (want 'pgvigil-svc 4/4'); held ping $r2_h (want 12)"
    fi
  fi
fi
if want RT || want RT1 || want RT2; then
  # the dial back first (slowq still answers while the service restarts), then the four proxies removed
  docker exec "$SVC" sh -c "install -m 0640 -g pgvigil /work/svc12.yaml /etc/pgvigil/pgvigil.yaml && systemctl restart pgvigil.service"
  for k in 1 2 3 4; do docker rm -f -v "$SLQ-$k" >/dev/null 2>&1 || true; done
fi
# ---- RT / RT1 / RT2 end
# shellcheck disable=SC2086
logins login $ALL12
fi

# ---- U uninstall retires the host (the last case: the service is gone after it) ------------------------------------
if want U; then
waitfor 150 "SELECT count(*) = 1 FROM pgvigil.collector_live" || true
rm -f "$WORK"/spool/* "$WORK"/spool2/*
u_out=$(docker exec "$SVC" /usr/local/bin/pgvigil uninstall 2>&1) || true
u_ret=$(q "SELECT count(*) FROM pgvigil.collector_heartbeat WHERE host = 'pgvigil-svc' AND retired_at IS NOT NULL")
u_all=$(q "SELECT count(*) FROM pgvigil.collector_heartbeat WHERE host = 'pgvigil-svc'")
u_st=$(api '' | jget collectors | python3 -c "import json,sys; print(','.join(sorted(set(x['state'] for x in json.load(sys.stdin) if x['host'] == 'pgvigil-svc'))))")
sleep 400   # past the 5 minutes after which a host not seen raises 'collector or network', and serve's watchdog minute
u_par=$(q "SELECT count(*) FROM pgvigil.collector_parent"); u_down=$(q "SELECT pgvigil.collector_down()")
u_sent=$(spool_n firing "collector or network")
[[ "$u_out" == *"retired as a collector"* && "$u_ret" -ge 1 && "$u_ret" == "$u_all" && "$u_st" == retired && "$u_par" == 0 && "$u_down" == f && "$u_sent" == 0 ]] \
  && ok "U uninstall: 'pgvigil uninstall' in the service's container retired pgvigil-svc in the repository it keeps ($u_ret of its $u_all run(s)); the page says '$u_st'; 400 s later no 'collector or network' (parent $u_par, collector_down $u_down, sent $u_sent) - B shows the alert a host only stopped raises" \
  || fail "U uninstall: its output '$(echo "$u_out" | tail -3 | tr '\n' ' ' | cut -c1-400)'; retired $u_ret of $u_all run(s), the page's state '$u_st' (want retired); after 400 s parent $u_par (want 0), collector_down $u_down (want f), sent $u_sent (want 0)"

fi

echo "the service's journal (last lines): $(docker exec "$SVC" journalctl -u pgvigil -n 4 --no-pager 2>&1 | tr '\n' ' ' | cut -c1-600)"
[[ -s "$WORK/unreadable" ]] && fail "alert files unreadable after 5 tries (a count read as -1): $(tr '\n' ';' < "$WORK/unreadable")"
if (( FAILS )); then echo "FAIL: $FAILS case(s)"; exit 1; fi
echo "proof-collector-health: OK (the heartbeat of a systemd unit, its load and a refused login, the page, failing together and a stopped collector each one alert with only their unread instances held, many collectors on one repository, the purge recorded)"
