#!/usr/bin/env bash
# Proof of `pgvigil export`, the repository's read-only export to Parquet (docs/parquet-export.md), on a throwaway
# repository database. The whole proof body is one Python program in a container of its own: it seeds rows with
# pg8000, runs the build's `pgvigil export`, and reads every file back with pyarrow - a Parquet reader that shares no
# code with the writer. Row G writes to an S3-compatible server and to Azurite, both containers this script starts
# and removes. Nothing leaves the machine.
#
#   PGVIGIL_ADMIN_DSN  keyword-form connection (host, port, user[, password]) to a cluster as a superuser, reachable
#                      on the host's network; the proof makes pgvigil_pqproof_<n> and its logins and drops them
#   PGVIGIL_BIN        the build to prove (default bin/pgvigil; a static build: it runs inside the Python container)
#   PROOF_ROWS         the rows to run, space separated (default: all): I A A2 B B2 C D E F G H J
#   PROOF_SEED_ONLY    1 = every row's seed statements and nothing else (a check of the proof's own SQL)
#   docker             the three images below
#
# Test-only tools, never shipped and never linked into pgvigil: python:3.12-slim with pyarrow, boto3,
# azure-storage-blob (Apache 2.0, Apache 2.0, MIT) and pg8000 (BSD 3-clause); chrislusf/seaweedfs (Apache 2.0) as the
# S3-compatible server; mcr.microsoft.com/azure-storage/azurite (MIT), started with --skipApiVersionCheck because the
# Python client asks for a newer API version than it lists, and with an account key made for this run.
# NOT PROVEN here: real AWS S3 and real Azure Blob, the AWS profile, the Azure default credential, the FIPS build.
#
# Times: H0 is the start of the repository's current clock hour; Wk is the window [H0 - k h, H0 - (k - 1) h), so W1
# is the newest complete hour. Wd is the newest complete window that starts at 00:00 UTC (the day's first window).
# Every config has settle_minutes 0 unless a row says otherwise. The proof waits for the hour to turn when fewer
# than 10 minutes of it are left.
#
# Expected (written before the first run):
#  I.  off by default: with no `export:` section `pgvigil export` exits 3 and its one line names the section; `pgvigil
#      serve` with an `export:` section opens no session named pgvigil-export and writes nothing at the destination.
#  A.  the catalogue: `-tables-list -json` names every table of the schema that is not a partition, each once, none a
#      partition (partitions of two months exist); class, time column, carry, text columns and dropped columns equal
#      scripts/proof-parquet-census.tsv line by line (that list was read from how each import writes its table), the
#      key columns equal the primary key in the catalogs. A table the map does not name stops a run before any read:
#      exit 1, 'is not classed', nothing at the destination.
#  A2. classes: a state table (host_state) is absent from an hourly window's manifest and whole in Wd's; `instances`
#      is in both; with carry [text] a dimension (statement_text) carries in an hourly window the text last seen in
#      or after it and not the one last seen before it, and both in Wd; without carry it is in `skipped` with the
#      carry it needs, as an audit table (hba_rules) is.
#  B.  a window and the types: of five host_sample rows (at the window's start, inside, 1 microsecond before its end,
#      at its end, 1 microsecond before its start) W2's file holds exactly the first three; an event stored now with
#      event_at in W4 is in W4's file and not in W2's. Read back by pyarrow: every column OPTIONAL and in the table's
#      own order, pages ZSTD, and one seeded value of each of the schema's 19 column types under its Parquet type
#      (the list is in the row), NULLs as nulls; a timestamp of infinity and a NaN in a DECIMAL column are null and
#      the manifest's column says 'infinite as null'; the three identity figures are DECIMAL(38, 0) and hold
#      18446744073709551615 exactly.
#  B2. the final pass: after pass 1 of W4 (manifest pass 1) a job run and a Query Store interval are stored with
#      their time in W4; a run with final_after_hours 2 exports W4 again under the same names: the manifest says
#      final, both late rows are in the files, the marker _manifests/_final/<window> exists; W1 is still pass 1 with
#      no marker. A final pass killed while it reads leaves the files it had written, no manifest for its window
#      and no marker, and the next run does it again.
#  C.  the manifest: contract_version 1 is its first key; each file's sha256, byte_size and row_count are the file's
#      own, the table's figures their sums; a table with no row in the window has an entry with row_count 0 and no
#      file. A subset run (-tables) writes a manifest and files marked __t<8 hex> beside the full ones, whose sha256
#      still hold. (Data first, manifest last: the cut of row B2 and the order of row G.)
#  D.  due windows: three hours behind with max_windows_per_run 2: the first run writes the two oldest (W3, W2) and
#      says one more is due, exit 0; the second writes W1; the third writes nothing; W4, older than
#      max_window_age_hours 3, is never written. Two runs at once: one works, the other exits 0 saying it is locked
#      and writes nothing.
#  E.  guards: a login that could write is refused before any read, exit 3, the line naming why - a member of the
#      collector role, of the alerter role, a NOINHERIT member of the owner, a superuser, a login with a stray UPDATE
#      grant. The reading session: a row-security probe on database_sizes raises unless the transaction is READ ONLY
#      and REPEATABLE READ, application_name is pgvigil-export, lock_timeout 5s, work_mem 16MB, no parallel workers,
#      statement_timeout 2min and the statement starts with /* pgvigil-export:database_sizes */ - the export reads
#      the table (its rows are in the file) while the same login in a plain session is refused by the probe. A table
#      whose read outlasts statement_timeout fails its window twice (exit 1, no manifest) and on the third run is in
#      the manifest's failed[] with the window complete (exit 1).
#  F.  left out and dropped: no ui_users file, the table in `skipped`; report_mail_sends is carried without html,
#      xlsx, recipients and subject, the four named in dropped_columns; mssql_errorlog is carried without message
#      (named in dropped_columns as text) and with it under carry [text].
#  G.  destinations: one window written to a folder, to the S3-compatible server and to Azurite: the three listings
#      hold the same names, every file's sha256 is the one its own manifest gives, each table's rows are equal across
#      the three, each manifest is the newest object of its window; a table of about 175 MB of text (over the 64 MB
#      line, so in parts on S3 and in blocks on Blob) reads back with its row count in all three and in more than
#      one row group.
#  H.  the page door: a run by a login in the exporter role leaves one export_runs row per window (outcome ok, its
#      files / rows / bytes the manifest's) and the export_state row; the same login's own INSERT into export_runs is
#      refused; GET /api/export lists the runs; a failed run (its destination a file) is a row with outcome failed
#      and export_service names 'the last run failed'; the newest run moved 4 hours back makes it name the hours
#      behind; after `pgvigil export -off` export_state is empty and export_service has no row.
#  J.  doors and caps: `-plan -json` lists the three due windows and each table's kind and writes nothing; `-check`
#      exits 0 on a good folder (left empty) and 3 on a destination that cannot be written; a hole between the
#      oldest manifest and the age line is named with its -from / -to line, exit 1, and `-status -json` lists it;
#      `-gap` writes gap manifests and the next run exits 0; 1,000,001 rows of one table and window come out as two
#      files (the second __p2) of 1,000,000 and 1 rows in row groups of at most 50,000; `-out` writes an explicit
#      window to another folder and leaves the configured destination as it was.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
BIN=$(realpath "${PGVIGIL_BIN:-bin/pgvigil}")
[ -x "$BIN" ] || { echo "FAIL: no build at $BIN" >&2; exit 1; }
IMG_PY=python:3.12-slim
IMG_S3=chrislusf/seaweedfs@sha256:ccad23e18639c8b98cee17e7100b95830a06077b56d8e5b006d6dcf8ec5e94a0
IMG_AZ=mcr.microsoft.com/azure-storage/azurite:3.37.0
SUF=$RANDOM; ROWS=${PROOF_ROWS:-I A A2 B B2 C D E F G H J}
WORK=$(mktemp -d); chmod 755 "$WORK"
S3C=pgvigil-pqproof-s3-$SUF; AZC=pgvigil-pqproof-az-$SUF; PYC=pgvigil-pqproof-py-$SUF
cleanup() {
  docker rm -f "$PYC" "$S3C" "$AZC" >/dev/null 2>&1 || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists pgvigil_pqproof_$SUF with (force)" >/dev/null 2>&1 || true
  for r in $(psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "select rolname from pg_roles where rolname like 'pqp\_%\_$SUF'" 2>/dev/null); do
    psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop role if exists \"$r\"" >/dev/null 2>&1 || true
  done
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
S3URL=""; AZCONN=""
if [[ " $ROWS " == *" G "* && "${PROOF_SEED_ONLY:-}" != 1 ]]; then
  AZK=$(openssl rand -base64 32); AZA=pqproof
  docker run -d --rm --name "$S3C" -p 127.0.0.1::8333 "$IMG_S3" server -s3 -dir=/data >/dev/null
  docker run -d --rm --name "$AZC" -p 127.0.0.1::10000 -e AZURITE_ACCOUNTS="$AZA:$AZK" "$IMG_AZ" \
    azurite-blob --blobHost 0.0.0.0 --blobPort 10000 -l /data --skipApiVersionCheck >/dev/null
  PS3=$(docker port "$S3C" 8333/tcp | head -1 | sed 's/.*://'); PAZ=$(docker port "$AZC" 10000/tcp | head -1 | sed 's/.*://')
  S3URL="http://127.0.0.1:$PS3"
  AZCONN=$(printf 'DefaultEndpointsProtocol=http;AccountName=%s;AccountKey=%s;BlobEndpoint=http://127.0.0.1:%s/%s;' "$AZA" "$AZK" "$PAZ" "$AZA")
fi
cp scripts/proof-parquet-census.tsv "$WORK/census.tsv"
cat > "$WORK/proof.py" <<'PY'
import os, sys, json, subprocess, hashlib, time, re, glob, socket, shutil, datetime as dt, decimal, csv, traceback
sys.path.insert(0, '/tmp/py')
import pg8000.native as pg
import pyarrow.parquet as pq

ROWS = os.environ['PROOF_ROWS'].split(); SEED_ONLY = os.environ.get('PROOF_SEED_ONLY') == '1'
SUF = os.environ['SUF']; BIN = '/pgvigil'; W = '/w'; DB = 'pgvigil_pqproof_' + SUF; NAME = 'proofrepo'
kv = dict(p.split('=', 1) for p in os.environ['PGVIGIL_ADMIN_DSN'].split())
HOST = kv.get('host', '127.0.0.1'); PORT = int(kv.get('port', '5432')); ADM = kv.get('user', 'postgres'); APW = kv.get('password')
nok = nfail = 0
def check(cond, msg):
    global nok, nfail
    if cond: nok += 1; print('ok   ' + msg)
    else: nfail += 1; print('FAIL ' + msg)
    sys.stdout.flush(); return bool(cond)
def conn(user, pw, database):
    c = pg.Connection(user, host=HOST, port=PORT, password=pw, database=database); c.run("SET TIME ZONE 'UTC'"); return c
def dsn(user, pw, database=None):
    return f"host={HOST} port={PORT} user={user} dbname={database or DB}" + (f" password={pw}" if pw else '')
adm = conn(ADM, APW, 'postgres'); adm.run(f'CREATE DATABASE {DB}')
db = conn(ADM, APW, DB)
def q(sql): return db.run(sql)
def q1(sql): return db.run(sql)[0][0]
REPO_DSN = dsn(ADM, APW); ENV0 = dict(os.environ, PGVIGIL_REPO_DSN=REPO_DSN, HOME='/tmp')
open(f'{W}/repo.yaml', 'w').write('repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n')
r = subprocess.run([BIN, 'migrate', '-config', f'{W}/repo.yaml'], capture_output=True, text=True, env=ENV0)
if r.returncode != 0: print('FAIL setup: migrate: ' + r.stderr[-300:]); sys.exit(1)
PW = 'p' + os.urandom(12).hex()
def login(tag, clause):   # a login of this proof: pqp_<tag>_<suffix>
    n = f'pqp_{tag}_{SUF}'; adm.run(f"CREATE ROLE {n} LOGIN PASSWORD '{PW}' {clause}"); return n
HAS_EXPORTER = q1("SELECT count(*) FROM pg_roles WHERE rolname = 'pgvigil_exporter'") == 1
RD = login('rd', 'IN ROLE pgvigil_reader'); EXP_DSN = dsn(RD, PW)

# ---- time ----------------------------------------------------------------------------------------------------
left = q1("SELECT extract(epoch FROM date_trunc('hour', now()) + interval '1 hour' - now())")
if not SEED_ONLY and left < 600:
    print(f'waiting {int(left) + 5} s for the hour to turn'); sys.stdout.flush(); time.sleep(float(left) + 5)
H0 = q1("SELECT date_trunc('hour', now())")
HR = dt.timedelta(hours=1); US = dt.timedelta(microseconds=1)
def Wk(k): return (H0 - k * HR, H0 - (k - 1) * HR)
D0 = q1("SELECT date_trunc('day', now() - interval '1 hour')"); WD = (D0, D0 + HR)
def stamp(t): return t.strftime('%Y%m%dT%H%MZ')
def iso(t): return t.strftime('%Y-%m-%dT%H:%M:%SZ')
def lit(t): return "'" + t.strftime('%Y-%m-%d %H:%M:%S.%f+00') + "'"
def WN():   # an hourly window that is not the day's first
    return Wk(2) if Wk(2)[0].hour != 0 else Wk(3)

# ---- configs and runs ------------------------------------------------------------------------------------------
def cfg(tag, dest=None, carry=(), **knobs):
    d = dict(settle_minutes=0, max_window_age_hours=6, max_windows_per_run=12, final_after_hours=24); d.update(knobs)
    dest = dest or {'type': 'folder', 'path': f'{W}/dest-{tag}'}
    state = knobs.pop('state', None) or f'{W}/state-{tag}'; d.pop('state', None)
    t = ('repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\nexport:\n'
         f'  name: {NAME}\n  dsn: env:PGVIGIL_EXPORT_DSN\n  state_dir: {state}\n'
         f'  destination: {json.dumps(dest)}\n  carry: {json.dumps(list(carry))}\n')
    t += ''.join(f'  {k}: {v}\n' for k, v in d.items())
    p = f'{W}/cfg-{tag}.yaml'; open(p, 'w').write(t); return p
def export(cfgp, *args, dsn_=None, env=None, timeout=900):
    e = dict(ENV0, PGVIGIL_EXPORT_DSN=dsn_ or EXP_DSN); e.update(env or {})
    p = subprocess.run([BIN, 'export', '-config', cfgp, *args], capture_output=True, text=True, env=e, timeout=timeout)
    return p.returncode, p.stdout, p.stderr
def window(cfgp, w, *args, **kw): return export(cfgp, '-from', iso(w[0]), '-to', iso(w[1]), *args, **kw)
def root(tag): return f'{W}/dest-{tag}/{NAME}'
def mname(w, sub=''): return f'{NAME}__{stamp(w[0])}__{stamp(w[1])}{sub}.json'
def man(tag, w, sub=''):
    p = f'{root(tag)}/_manifests/{mname(w, sub)}'
    return json.load(open(p)) if os.path.isfile(p) else None
def entry(m, table): return next((t for t in (m or {}).get('tables', []) if t['table'] == table), None)
def files(m, table): return [f['path'] for f in (entry(m, table) or {}).get('output_files', [])]
def rows(tag, m, table):
    out = []
    for p in files(m, table): out += pq.read_table(f'{root(tag)}/{p}').to_pylist()
    return out
def skipped(m, table): return next((s for s in (m or {}).get('skipped', []) if s['table'] == table), None)
def tree(path):
    return sorted(os.path.relpath(os.path.join(a, f), path) for a, _, fs in os.walk(path) for f in fs) if os.path.isdir(path) else []
def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''): h.update(b)
    return h.hexdigest()
def sums_hold(tag, m):   # every file of a manifest: sha256, byte_size, row_count are the file's own
    bad = []
    for t in m['tables']:
        n = 0
        for f in t.get('output_files', []):
            p = f'{root(tag)}/{f["path"]}'
            if not os.path.isfile(p): bad.append(f['path'] + ' missing'); continue
            if sha(p) != f['sha256']: bad.append(f['path'] + ' sha256')
            if os.path.getsize(p) != f['byte_size']: bad.append(f['path'] + ' byte_size')
            if pq.ParquetFile(p).metadata.num_rows != f['row_count']: bad.append(f['path'] + ' row_count')
            n += f['row_count']
        if n != t['row_count']: bad.append(t['table'] + ' sum')
    return bad
def part(table, t, kind='month'):
    fn = {'month': 'ensure_month_partition', 'day': 'mssql_ensure_day_partition', 'event': 'mssql_event_partition'}[kind]
    q(f"SELECT pgvigil.{fn}('{table}', CAST({lit(t)} AS timestamptz))")
def inst(tag, engine='postgres'):
    return q1("INSERT INTO pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine) "
              f"VALUES ('pq-{tag}-{SUF}', '{'sqlserver' if engine == 'sqlserver' else 'onprem'}', '{{}}', now(), now(), true, '{engine}') RETURNING instance_id")
def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p
def export_sessions(): return q("SELECT pid, query FROM pg_stat_activity WHERE datname = current_database() AND application_name = 'pgvigil-export'")
def wait_reading(table, secs=60):   # until an export session runs its read of the table
    for _ in range(secs * 10):
        if any(f'/* pgvigil-export:{table} */' in (s[1] or '') for s in export_sessions()): return True
        time.sleep(0.1)
    return False
def policy(table, expr, role):
    q(f'ALTER TABLE pgvigil.{table} ENABLE ROW LEVEL SECURITY')
    q(f'CREATE POLICY pqproof ON pgvigil.{table} FOR SELECT TO {role} USING ({expr})')
def unpolicy(table):
    q(f'DROP POLICY IF EXISTS pqproof ON pgvigil.{table}'); q(f'ALTER TABLE pgvigil.{table} DISABLE ROW LEVEL SECURITY')
q('CREATE SCHEMA pqproof'); q('GRANT USAGE ON SCHEMA pqproof TO public')
q("CREATE FUNCTION pqproof.slow(secs float8) RETURNS boolean LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(secs); RETURN true; END $$")

I1 = inst('i1'); I2 = inst('i2'); I3 = inst('i3'); I4 = inst('i4'); M1 = inst('m1', 'sqlserver')
for t in (H0, H0 - 31 * 24 * HR):
    for tb in ('host_sample', 'database_sizes', 'mssql_job_runs', 'mssql_qs_interval', 'mssql_cpu_sample', 'job_stats_hourly',
               'mssql_pool_minute', 'activity_sample', 'table_sizes'):
        part(tb, t)
for k in range(0, 8):
    part('mssql_requests', H0 - k * HR, 'day'); part('mssql_attentions', H0 - k * HR, 'event'); part('mssql_errorlog', H0 - k * HR, 'event')
part('mssql_requests', WD[0], 'day'); part('mssql_errorlog', WD[0], 'event'); part('host_sample', WD[0]); part('database_sizes', WD[0])

# ---- seeds: each row's own rows; all of them run before the first export (PROOF_SEED_ONLY stops after them) ------
def hs(i, t, source, extra_cols='', extra_vals=''):
    q(f"INSERT INTO pgvigil.host_sample (instance_id, snapshot_at, source{extra_cols}) VALUES ({i}, CAST({lit(t)} AS timestamptz), '{source}'{extra_vals})")
def seed_A(): pass
def seed_A2():
    for i in (I1, I2):
        q(f"INSERT INTO pgvigil.host_state (instance_id, snapshot_at, source, host_name) VALUES ({i}, now(), 'proof', 'a2-{i}')")
    wn = WN()
    q(f"INSERT INTO pgvigil.statement_text (instance_id, queryid, first_seen, last_seen, query) VALUES "
      f"({I1}, 9001, CAST({lit(wn[0] - 5 * HR)} AS timestamptz), now(), 'select a2 active'), "
      f"({I1}, 9002, CAST({lit(wn[0] - 30 * HR)} AS timestamptz), CAST({lit(wn[0] - HR)} AS timestamptz), 'select a2 old')")
    q(f"INSERT INTO pgvigil.hba_rules (instance_id, file_name, line_number, snapshot_at, type, auth_method) VALUES ({I1}, 'pg_hba.conf', 1, now(), 'host', 'scram-sha-256')")
def seed_B():
    a, b = Wk(2)
    hs(I1, a, 'in-a', ', cpu_pct, mem_total, connections', ', 12.5, 34359738368, 7')
    hs(I1, a + dt.timedelta(minutes=30), 'in-b', ', metrics_at', ", 'infinity'")
    hs(I1, b - US, 'in-c'); hs(I1, b, 'out-hi'); hs(I1, a - US, 'out-lo')
    w4 = Wk(4)
    q(f"INSERT INTO pgvigil.mssql_attentions (instance_id, event_at, event_key, snapshot_at, statement) VALUES ({M1}, CAST({lit(w4[0] + 10 * 60 * dt.timedelta(seconds=1))} AS timestamptz), 'late-b', now(), 'select late')")
    mid = a + dt.timedelta(minutes=20)
    q(f"INSERT INTO pgvigil.mssql_cpu_sample (instance_id, snapshot_at, record_id, sql_pct) VALUES ({M1}, CAST({lit(mid)} AS timestamptz), 1, 37)")
    q(f"INSERT INTO pgvigil.job_stats_hourly (instance_id, scheduler, job_id, step_id, snapshot_at, runs, succeeded, failed, retries, total_secs) VALUES ({I1}, 'pg_cron', 'j1', 0, CAST({lit(a)} AS timestamptz), 3, 2, 1, 0, 1.25)")
    q(f"INSERT INTO pgvigil.mssql_pool_minute (server, pool, snapshot_at, samples, instance_id, name_from, avg_cpu_percent) VALUES ('s-{SUF}', 'p1', CAST({lit(mid)} AS timestamptz), 4, {M1}, 'tag', 12.34)")
    q(f"INSERT INTO pgvigil.mssql_errorlog (instance_id, log_at, line_key, snapshot_at, logged_local, class, matched, custom, severity, message) VALUES "
      f"({M1}, CAST({lit(mid)} AS timestamptz), 'b-1', now(), TIMESTAMP '2026-01-02 03:04:05.678901', 'io', '{{\"one\",\"two words\"}}', true, 17, 'proof line')")
    q(f"INSERT INTO pgvigil.mssql_requests (instance_id, snapshot_at, session_id, wait_is_benign, in_cycle, plan_handle, session_waits) VALUES "
      f"({M1}, CAST({lit(mid)} AS timestamptz), 55, false, false, '\\x0600ff00', '{{\"LCK_M_S\": 12}}')")
    q(f"INSERT INTO pgvigil.activity_sample (instance_id, snapshot_at, pid, is_blocker, blocking_pids) VALUES ({I1}, CAST({lit(mid)} AS timestamptz), 4242, false, '{{11,12}}')")
    q(f"INSERT INTO pgvigil.mssql_identity_column (instance_id, database_name, schema_name, table_name, column_name, status, snapshot_at, last_value, max_value, anchor_value, pct_used, per_day, days_left) VALUES "
      f"({M1}, 'd', 's', 't', 'big', 'ok', now(), 9223372036854775807, 18446744073709551615, 18446744073709551615, 50.25, 1234.5, 'NaN'), "
      f"({M1}, 'd', 's', 't', 'nan', 'ok', now(), 1, 2, NULL, 'NaN', NULL, NULL)")
    q(f"INSERT INTO pgvigil.mssql_pool_thresholds (server, pool, warning, critical) VALUES ('s-{SUF}', 'p1', 0.8125, 0.9)")
    q(f"INSERT INTO pgvigil.mssql_build (instance_id, snapshot_at, known, exact, newer, status, release_date) VALUES ({M1}, now(), true, true, false, 'ok', DATE '2026-03-14')")
    q(f"INSERT INTO pgvigil.pg_wal_replay (instance_id, snapshot_at, is_present, replay_lsn) VALUES ({I1}, now(), true, '16/B374D848')")
def seed_B2():
    a, _ = Wk(4)
    q(f"INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, step_id, job_name) VALUES ({M1}, CAST({lit(a + dt.timedelta(minutes=5))} AS timestamptz), 1, 'J1', 0, 'b2 early')")
    q(f"INSERT INTO pgvigil.table_sizes (instance_id, snapshot_at, dbid, relid) VALUES ({I2}, CAST({lit(Wk(5)[0] + dt.timedelta(minutes=5))} AS timestamptz), 1, 77)")
    ds(I2, Wk(5)[0] + dt.timedelta(minutes=5), 300, 'b2-cut')
def seed_B2_late():
    a, _ = Wk(4)
    q(f"INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, step_id, job_name) VALUES ({M1}, CAST({lit(a + dt.timedelta(minutes=6))} AS timestamptz), 2, 'J1', 0, 'b2 late')")
    q(f"INSERT INTO pgvigil.mssql_qs_interval (instance_id, snapshot_at, database_name, interval_end, read_at) VALUES ({M1}, CAST({lit(a)} AS timestamptz), 'b2db', CAST({lit(a + HR)} AS timestamptz), now())")
def ds(i, t, dbid, name):
    q(f"INSERT INTO pgvigil.database_sizes (instance_id, snapshot_at, dbid, datname, size_bytes) VALUES ({i}, CAST({lit(t)} AS timestamptz), {dbid}, '{name}', {dbid * 1000})")
def seed_C():
    for n in range(3): ds(I3, Wk(3)[0] + dt.timedelta(minutes=10 * n + 1), 100 + n, f'c-{n}')
def seed_D():
    for k in (1, 2, 3, 4): hs(I2, Wk(k)[0] + dt.timedelta(minutes=7), f'd-{k}')
def seed_E():
    for n in range(4): ds(I1, Wk(2)[0] + dt.timedelta(minutes=5 * n + 2), 200 + n, f'e-{n}')
    q(f"INSERT INTO pgvigil.table_sizes (instance_id, snapshot_at, dbid, relid) VALUES ({I1}, CAST({lit(Wk(1)[0] + dt.timedelta(minutes=3))} AS timestamptz), 1, 88)")
    q("""CREATE FUNCTION pqproof.probe(tbl text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE want text[] := ARRAY['transaction_read_only', 'on', 'transaction_isolation', 'repeatable read', 'application_name', 'pgvigil-export',
                             'lock_timeout', '5s', 'work_mem', '16MB', 'max_parallel_workers_per_gather', '0', 'statement_timeout', '2min'];
BEGIN
  FOR i IN 1 .. array_length(want, 1) / 2 LOOP
    IF current_setting(want[2 * i - 1]) <> want[2 * i] THEN
      RAISE EXCEPTION 'probe: % is %, not %', want[2 * i - 1], current_setting(want[2 * i - 1]), want[2 * i];
    END IF;
  END LOOP;
  IF position('/* pgvigil-export:' || tbl || ' */' in current_query()) <> 1 THEN
    RAISE EXCEPTION 'probe: the statement does not start with the export''s comment: %', left(current_query(), 60);
  END IF;
  RETURN true;
END $$""")
def seed_F():
    w = Wk(2)
    q(f"INSERT INTO pgvigil.ui_users (username, password_hash, is_disabled, created_at, password_set_at) VALUES ('pq-{SUF}', '$argon2id$proof', true, now(), now())")
    q(f"INSERT INTO pgvigil.report_mail_sends (kind, name, route, requested_by, requested_at, channel, recipients, subject, html, xlsx) VALUES "
      f"('now', 'f-send', '#/summary', 'proof', CAST({lit(w[0] + dt.timedelta(minutes=9))} AS timestamptz), 'mail', '{{\"a@example.invalid\"}}', 'f subject', '<p>f body</p>', '\\x504b0304')")
    q(f"INSERT INTO pgvigil.mssql_errorlog (instance_id, log_at, line_key, snapshot_at, logged_local, class, matched, custom, message) VALUES "
      f"({M1}, CAST({lit(w[0] + dt.timedelta(minutes=40))} AS timestamptz), 'f-1', now(), TIMESTAMP '2026-01-02 03:04:05', 'general', '{{}}', false, 'f secret text')")
def seed_G():
    w = Wk(3)
    for n in range(5): hs(I3, w[0] + dt.timedelta(minutes=11 * n + 1), f'g-{n}')
    q(f"INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note) "
      f"SELECT {I3}, 'g-big', CAST({lit(w[0])} AS timestamptz) + g * interval '0.5 second', 'error', (SELECT string_agg(md5(random()::text || g::text || x::text), '') FROM generate_series(1, 1000) x) FROM generate_series(1, 5500) g")
def seed_H(): pass
def seed_J():
    w = Wk(5)
    q(f"INSERT INTO pgvigil.host_sample (instance_id, snapshot_at, source, connections) SELECT {I4}, CAST({lit(w[0])} AS timestamptz) + g * interval '3 milliseconds', 'j', g FROM generate_series(0, 1000000) g")
    hs(I4, Wk(6)[0] + dt.timedelta(minutes=3), 'j-start'); hs(I4, Wk(2)[0] + dt.timedelta(minutes=3), 'j-new')
SEEDS = [('A', seed_A), ('A2', seed_A2), ('B', seed_B), ('B2', seed_B2), ('B2', seed_B2_late), ('C', seed_C), ('D', seed_D), ('E', seed_E), ('F', seed_F), ('G', seed_G), ('H', seed_H), ('J', seed_J)]
seeded = set()
for row, fn in SEEDS:
    if row not in ROWS or (fn is seed_B2_late and not SEED_ONLY): continue
    try: fn(); seeded.add(row)
    except Exception as e: check(False, f'{row}: the seed {fn.__name__} raised: {str(e)[:300]}')
print(f'seeded rows: {" ".join(sorted(seeded))}; H0 {iso(H0)}, the day\'s first window {iso(WD[0])}'); sys.stdout.flush()
if SEED_ONLY:
    print(f'proof-parquet: seed only: {nfail} FAIL'); sys.exit(1 if nfail else 0)

# ---- the rows ----------------------------------------------------------------------------------------------------
def row_I():
    rc, out, err = export(f'{W}/repo.yaml')
    check(rc == 3 and 'export:' in err and len(err.strip().splitlines()) == 1, f'I: no export section: exit 3 and one line naming it (rc {rc}: {err.strip()[:160]})')
    c = cfg('i'); port = free_port()
    p = subprocess.Popen([BIN, 'serve', '-config', c, '-dsn', 'env:PGVIGIL_REPO_DSN', '-listen', f'127.0.0.1:{port}', '-no-login'],
                         env=dict(ENV0, PGVIGIL_EXPORT_DSN=EXP_DSN), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    seen = 0
    for _ in range(40):
        seen += len(export_sessions()); time.sleep(0.1)
    alive = p.poll() is None; p.kill(); p.wait()
    check(alive and seen == 0 and not tree(f'{W}/dest-i'), f'I: serve with an export section: alive {alive}, export sessions seen {seen}, files at the destination {len(tree(W + "/dest-i"))}')

def row_A():
    c = cfg('a')
    rc, out, err = export(c, '-tables-list', '-json')
    if not check(rc == 0, f'A: -tables-list -json exits 0 (rc {rc}: {err.strip()[:200]})'): return
    lst = json.loads(out); names = [t['table'] for t in lst]
    store = {r[0]: r[1] for r in q("SELECT c.relname, (SELECT array_agg(a.attname ORDER BY k.ord) FROM pg_index i CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY k(attnum, ord) "
             "JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum WHERE i.indrelid = c.oid AND i.indisprimary) "
             "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'pgvigil' AND c.relkind IN ('r', 'p') AND NOT c.relispartition")}
    parts = {r[0] for r in q("SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'pgvigil' AND c.relispartition")}
    check(len(parts) >= 20 and len({p[-6:] for p in parts if re.search(r'_\d{6}$', p)}) >= 2, f'A: the store holds partitions of two months ({len(parts)} partitions)')
    check(sorted(names) == sorted(store) and len(names) == len(set(names)), f'A: the list names every table that is not a partition, each once ({len(names)} listed, {len(store)} in the catalogs; only listed {sorted(set(names) - set(store))[:5]}, only in the catalogs {sorted(set(store) - set(names))[:5]})')
    check(not (set(names) & parts), f'A: no partition is listed ({sorted(set(names) & parts)[:5]})')
    cen = {r['table']: r for r in csv.DictReader(open(f'{W}/census.tsv'), delimiter='\t')}
    bad = []
    for t in lst:
        e = cen.get(t['table'])
        if e is None: bad.append(t['table'] + ': not in the census'); continue
        got = (t['class'], t.get('time_column') or '', t.get('carry') or '', ','.join(t.get('text_columns') or []), ','.join(t.get('dropped_columns') or []))
        want = (e['class'], e['time_column'], e['carry'], e['text_columns'], e['dropped_columns'])
        if got != want: bad.append(f"{t['table']}: {got} against the census {want}")
        if (t.get('key_columns') or []) != (store.get(t['table']) or []): bad.append(f"{t['table']}: key {t.get('key_columns')} against {store.get(t['table'])}")
    check(not bad, f'A: class, time column, carry, text and dropped columns equal the census, the key the primary key ({len(lst)} tables; {len(bad)} differ: {bad[:4]})')
    q(f'CREATE TABLE pgvigil.pq_new_{SUF} (instance_id int, snapshot_at timestamptz)')
    try:
        rc, out, err = window(c, Wk(2))
        check(rc == 1 and 'is not classed' in err and f'pq_new_{SUF}' in err and not tree(f'{W}/dest-a'), f'A: a table the map does not name stops the run before any read (rc {rc}, files {len(tree(W + "/dest-a"))}: {err.strip()[:160]})')
    finally:
        q(f'DROP TABLE pgvigil.pq_new_{SUF}')

def row_A2():
    c = cfg('a2', carry=['text']); wn = WN()
    r1 = window(c, wn); r2 = window(c, WD)
    if not check(r1[0] == 0 and r2[0] == 0, f'A2: the hourly window and the day\'s first window export (rc {r1[0]}, {r2[0]}: {(r1[2] + r2[2]).strip()[:200]})'): return
    mn = man('a2', wn); md = man('a2', WD)
    ninst = q1('SELECT count(*) FROM pgvigil.instances')
    check(entry(mn, 'host_state') is None and skipped(mn, 'host_state') is None, 'A2: a state table is absent from an hourly window')
    hsd = [r for r in rows('a2', md, 'host_state') if (r.get('host_name') or '').startswith('a2-')]
    check(entry(md, 'host_state') and entry(md, 'host_state')['kind'] == 'state' and len(hsd) == 2 and entry(md, 'host_state')['row_count'] == q1('SELECT count(*) FROM pgvigil.host_state'), f'A2: the state table whole in the day\'s first window ({len(hsd)} of the 2 seeded rows)')
    check(len(rows('a2', mn, 'instances')) == ninst and len(rows('a2', md, 'instances')) == ninst, f'A2: instances in both windows ({ninst} rows each)')
    tn = {r['queryid'] for r in rows('a2', mn, 'statement_text')}; td = {r['queryid'] for r in rows('a2', md, 'statement_text')}
    check(entry(mn, 'statement_text') and entry(mn, 'statement_text')['kind'] == 'dimension' and 9001 in tn and 9002 not in tn, f'A2: the dimension in an hourly window holds the text last seen in or after it only ({sorted(tn)})')
    check({9001, 9002} <= td, f'A2: the dimension whole in the day\'s first window ({sorted(td)})')
    c2 = cfg('a2n'); r3 = window(c2, wn); m3 = man('a2n', wn)
    s1 = skipped(m3, 'statement_text'); s2 = skipped(m3, 'hba_rules')
    check(r3[0] == 0 and entry(m3, 'statement_text') is None and s1 and 'text' in s1['reason'] and s2 and 'audit' in s2['reason'] and not os.path.isdir(f'{root("a2n")}/statement_text') and not os.path.isdir(f'{root("a2n")}/hba_rules'),
          f'A2: without carry the text and the audit table are skipped, each naming its carry ({s1}, {s2})')

def pcol(pf, name):   # (physical type, logical type, max definition level) of a top-level column, its first leaf
    sc = pf.schema
    for i in range(len(sc)):
        c = sc.column(i)
        if c.path.split('.')[0] == name: return c.physical_type, str(c.logical_type), c.max_definition_level
    return None
def row_B():
    c = cfg('b'); w2 = Wk(2); w4 = Wk(4)
    rs = [window(c, w) for w in (w2, w4, WD)]
    if not check(all(r[0] == 0 for r in rs), f'B: W2, W4 and the day\'s first window export (rc {[r[0] for r in rs]}: {"".join(r[2] for r in rs).strip()[:200]})'): return
    m2 = man('b', w2); m4 = man('b', w4); md = man('b', WD)
    got = sorted(r['source'] for r in rows('b', m2, 'host_sample') if r['instance_id'] == I1)
    check(got == ['in-a', 'in-b', 'in-c'], f'B: the window holds its start, its inside and its last microsecond and neither edge outside ({got})')
    a2 = [r['event_key'] for r in rows('b', m2, 'mssql_attentions')]; a4 = [r['event_key'] for r in rows('b', m4, 'mssql_attentions')]
    check('late-b' in a4 and 'late-b' not in a2, f'B: an event stored now with its own time in W4 is in W4\'s file, not W2\'s (W4 {a4}, W2 {a2})')
    def one(m, table, pred): return next((r for r in rows('b', m, table) if pred(r)), None)
    def pf(m, table): return pq.ParquetFile(f'{root("b")}/{files(m, table)[0]}')
    D = decimal.Decimal; UTC = dt.timezone.utc
    hsr = one(m2, 'host_sample', lambda r: r['source'] == 'in-a') or {}
    idc = one(md, 'mssql_identity_column', lambda r: r['column_name'] == 'big') or {}
    idn = one(md, 'mssql_identity_column', lambda r: r['column_name'] == 'nan') or {}
    erl = one(m2, 'mssql_errorlog', lambda r: r['line_key'] == 'b-1') or {}
    req = one(m2, 'mssql_requests', lambda r: r['session_id'] == 55) or {}
    types = [   # the schema's 19 column types: (pg type, manifest, table, column, physical, logical holds, the row, the value)
        ('integer', m2, 'host_sample', 'connections', 'INT32', '', hsr, 7),
        ('bigint', m2, 'host_sample', 'mem_total', 'INT64', '', hsr, 34359738368),
        ('real', m2, 'host_sample', 'cpu_pct', 'FLOAT', '', hsr, 12.5),
        ('text', m2, 'host_sample', 'source', 'BYTE_ARRAY', 'String', hsr, 'in-a'),
        ('timestamp with time zone', m2, 'host_sample', 'snapshot_at', 'INT64', 'isAdjustedToUTC=true, timeUnit=microseconds', hsr, w2[0]),
        ('smallint', m2, 'mssql_cpu_sample', 'sql_pct', 'INT32', '', one(m2, 'mssql_cpu_sample', lambda r: r['record_id'] == 1) or {}, 37),
        ('double precision', m2, 'job_stats_hourly', 'total_secs', 'DOUBLE', '', one(m2, 'job_stats_hourly', lambda r: r['job_id'] == 'j1') or {}, 1.25),
        ('numeric(5,2)', m2, 'mssql_pool_minute', 'avg_cpu_percent', None, 'Decimal(precision=5, scale=2)', one(m2, 'mssql_pool_minute', lambda r: r['pool'] == 'p1') or {}, D('12.34')),
        ('numeric(5,4)', md, 'mssql_pool_thresholds', 'warning', None, 'Decimal(precision=5, scale=4)', one(md, 'mssql_pool_thresholds', lambda r: r['server'] == f's-{SUF}') or {}, D('0.8125')),
        ('numeric(9,2)', md, 'mssql_identity_column', 'pct_used', None, 'Decimal(precision=9, scale=2)', idc, D('50.25')),
        ('numeric', md, 'mssql_identity_column', 'per_day', 'DOUBLE', '', idc, 1234.5),
        ('numeric as DECIMAL(38, 0)', md, 'mssql_identity_column', 'max_value', None, 'Decimal(precision=38, scale=0)', idc, D('18446744073709551615')),
        ('timestamp without time zone', m2, 'mssql_errorlog', 'logged_local', 'INT64', 'isAdjustedToUTC=false, timeUnit=microseconds', erl, dt.datetime(2026, 1, 2, 3, 4, 5, 678901)),
        ('text[]', m2, 'mssql_errorlog', 'matched', 'BYTE_ARRAY', 'String', erl, ['one', 'two words']),
        ('boolean', m2, 'mssql_errorlog', 'custom', 'BOOLEAN', '', erl, True),
        ('bytea', m2, 'mssql_requests', 'plan_handle', 'BYTE_ARRAY', 'None', req, bytes.fromhex('0600ff00')),
        ('jsonb', m2, 'mssql_requests', 'session_waits', 'BYTE_ARRAY', 'JSON', req, None),
        ('integer[]', m2, 'activity_sample', 'blocking_pids', 'INT32', '', one(m2, 'activity_sample', lambda r: r['pid'] == 4242) or {}, [11, 12]),
        ('date', md, 'mssql_build', 'release_date', 'INT32', 'Date', one(md, 'mssql_build', lambda r: r['instance_id'] == M1) or {}, dt.date(2026, 3, 14)),
        ('pg_lsn', md, 'pg_wal_replay', 'replay_lsn', 'BYTE_ARRAY', 'String', one(md, 'pg_wal_replay', lambda r: r['instance_id'] == I1) or {}, '16/B374D848'),
    ]
    for pgt, m, table, col, phys, logical, r, val in types:
        try:
            ph, lg, dl = pcol(pf(m, table), col); v = r.get(col)
            if pgt == 'jsonb': okv = json.loads(v) == {'LCK_M_S': 12}
            elif isinstance(val, dt.datetime) and val.tzinfo is not None: okv = v is not None and v.astimezone(UTC) == val
            else: okv = v == val
            check((phys is None or ph == phys) and logical.lower() in lg.lower() and dl >= 1 and okv, f'B: {pgt} -> {ph} {lg}, OPTIONAL, {table}.{col} = {v!r}')
        except Exception as e:
            check(False, f'B: {pgt} ({table}.{col}): {type(e).__name__}: {str(e)[:160]}')
    check(idc.get('last_value') == D('9223372036854775807') and idc.get('anchor_value') == D('18446744073709551615'), f'B: the identity figures exact past the bigint line ({idc.get("last_value")}, {idc.get("anchor_value")})')
    check(hsr.get('swap_total', 0) is None and idn.get('anchor_value', 0) is None and 'load1' in hsr, 'B: a NULL is a null and its column is still in the file')
    inb = one(m2, 'host_sample', lambda r: r['source'] == 'in-b') or {}
    note = lambda m, t, c: next((x.get('note') or '' for x in (entry(m, t) or {}).get('columns', []) if x['name'] == c), None)
    check(inb.get('metrics_at', 0) is None and 'infinite as null' in (note(m2, 'host_sample', 'metrics_at') or ''), f'B: a timestamp of infinity is null and the manifest says so ({inb.get("metrics_at", "absent")!r}, note {note(m2, "host_sample", "metrics_at")!r})')
    check(idn.get('pct_used', 0) is None and 'infinite as null' in (note(md, 'mssql_identity_column', 'pct_used') or ''), f'B: a NaN in a DECIMAL column is null and the manifest says so ({idn.get("pct_used", "absent")!r})')
    order = [x[0] for x in q("SELECT attname FROM pg_attribute WHERE attrelid = 'pgvigil.host_sample'::regclass AND attnum > 0 AND NOT attisdropped ORDER BY attnum")]
    f0 = pf(m2, 'host_sample')
    check(f0.schema_arrow.names == order and [x['name'] for x in entry(m2, 'host_sample')['columns']] == order, f'B: the columns in the table\'s own order ({f0.schema_arrow.names[:4]} ...)')
    check(f0.metadata.row_group(0).column(0).compression == 'ZSTD', f'B: pages ZSTD ({f0.metadata.row_group(0).column(0).compression})')
    check(entry(m2, 'host_sample')['time_column'] == 'snapshot_at' and entry(m2, 'host_sample')['kind'] == 'window' and entry(m4, 'mssql_attentions')['time_column'] == 'event_at', 'B: each window entry names its own time column')

def row_B2():
    state = f'{W}/state-b2'; dest = {'type': 'folder', 'path': f'{W}/dest-b2'}
    ca = cfg('b2', dest=dest, state=state); w4 = Wk(4); w5 = Wk(5); w1 = Wk(1)
    rc, out, err = export(ca); m = man('b2', w4)
    if not check(rc == 0 and m and m['pass'] == 1 and [r['job_name'] for r in rows('b2', m, 'mssql_job_runs')] == ['b2 early'], f'B2: pass 1 of W4 holds what was stored then (rc {rc}, pass {m and m["pass"]}: {err.strip()[:160]})'): return
    seed_B2_late()
    cb = cfg('b2f', dest=dest, state=state, final_after_hours=2)
    policy('table_sizes', 'pqproof.slow(45)', RD); t_cut = time.time()
    try:
        p = subprocess.Popen([BIN, 'export', '-config', cb], env=dict(ENV0, PGVIGIL_EXPORT_DSN=EXP_DSN), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        reading = wait_reading('table_sizes'); p.kill(); p.wait()
    finally:
        unpolicy('table_sizes')
        for s in export_sessions(): q(f'SELECT pg_terminate_backend({s[0]})')
    mk = lambda w: os.path.exists(f'{root("b2")}/_manifests/_final/{NAME}__{stamp(w[0])}__{stamp(w[1])}')
    rewritten = [f for f in glob.glob(f'{root("b2")}/database_sizes/*{stamp(w5[0])}*') if os.path.getmtime(f) >= t_cut - 1]
    check(reading and man('b2', w5) is None and not mk(w5) and rewritten, f'B2: a final pass killed while it reads leaves its files, no manifest and no marker for its window (reading seen {reading}, files written again {len(rewritten)}, manifest {man("b2", w5) is not None}, marker {mk(w5)})')
    rc, out, err = export(cb); m5 = man('b2', w5); m4 = man('b2', w4); m1 = man('b2', w1)
    check(rc == 0 and m5 and m5['pass'] == 'final' and mk(w5) and not sums_hold('b2', m5), f'B2: the next run does the cut window again (rc {rc}, pass {m5 and m5["pass"]}, marker {mk(w5)})')
    jr = sorted(r['job_name'] for r in rows('b2', m4, 'mssql_job_runs')); qs = [r['database_name'] for r in rows('b2', m4, 'mssql_qs_interval')]
    check(m4 and m4['pass'] == 'final' and jr == ['b2 early', 'b2 late'] and qs == ['b2db'] and mk(w4), f'B2: the final pass carries the rows stored after pass 1 under the same names (pass {m4 and m4["pass"]}, job runs {jr}, intervals {qs}, marker {mk(w4)})')
    check(m1 and m1['pass'] == 1 and not mk(w1), f'B2: a window younger than final_after_hours stays pass 1 with no marker (pass {m1 and m1["pass"]}, marker {mk(w1)})')

def row_C():
    c = cfg('c'); w3 = Wk(3)
    rc, out, err = window(c, w3); m = man('c', w3)
    if not check(rc == 0 and m is not None, f'C: W3 exports (rc {rc}: {err.strip()[:200]})'): return
    check(list(m)[0] == 'contract_version' and m['contract_version'] == 1 and m['repository'] == NAME and m['window'] == {'from_utc': iso(w3[0]), 'to_utc': iso(w3[1])},
          f'C: contract_version 1 first, the repository and the window ({list(m)[:3]}, {m.get("window")})')
    e = entry(m, 'database_sizes'); bad = sums_hold('c', m)
    check(e and e['row_count'] == 3 and len(e['output_files']) == 1 and e['key_columns'] == [] and not bad, f'C: sha256, byte_size and row_count are each file\'s own, the table\'s their sums ({bad[:3]})')
    z = entry(m, 'dbstats')
    check(z is not None and z['row_count'] == 0 and not z.get('output_files') and not os.path.isdir(f'{root("c")}/dbstats'), f'C: a table with no row has an entry, row_count 0, and no file ({z and z["row_count"]})')
    rc3, _, err3 = window(c, w3, '-tables', 'database_sizes')
    subs = [f for f in os.listdir(f'{root("c")}/_manifests') if re.fullmatch(re.escape(mname(w3)[:-5]) + r'__t[0-9a-f]{8}\.json', f)]
    ms = json.load(open(f'{root("c")}/_manifests/{subs[0]}')) if subs else None
    mark = subs[0][-15:-5] if subs else '?'
    check(rc3 == 0 and len(subs) == 1 and ms and [t['table'] for t in ms['tables']] == ['database_sizes'] and all(mark in p for p in files(ms, 'database_sizes')) and not sums_hold('c', ms),
          f'C: a subset run writes its own manifest and files marked {mark} (rc {rc3}, {subs}: {err3.strip()[:120]})')
    check(not sums_hold('c', man('c', w3)), 'C: the full manifest\'s sha256 still hold beside the subset\'s')

def row_D():
    c = cfg('d', max_window_age_hours=3, max_windows_per_run=2)
    have = lambda: [k for k in (4, 3, 2, 1) if man('d', Wk(k)) is not None]
    r1 = export(c); h1 = have(); r2 = export(c); h2 = have(); r3 = export(c); h3 = have()
    check(r1[0] == 0 and h1 == [3, 2] and '1' in (r1[1] + r1[2]) and 'due' in (r1[1] + r1[2]), f'D: the first run writes the two oldest due windows and says one more is due (rc {r1[0]}, W{h1}: {(r1[1] + r1[2]).strip()[-160:]})')
    t3 = os.path.getmtime(f'{root("d")}/_manifests/{mname(Wk(3))}'); t2 = os.path.getmtime(f'{root("d")}/_manifests/{mname(Wk(2))}')
    check(t3 <= t2, 'D: oldest first')
    check(r2[0] == 0 and h2 == [3, 2, 1], f'D: the second run writes the third (rc {r2[0]}, W{h2})')
    n = len(tree(root('d')))
    check(r3[0] == 0 and h3 == [3, 2, 1] and len(tree(root('d'))) == n, f'D: the third run writes nothing; the hour older than the age is never written (rc {r3[0]}, W{h3})')
    c2 = cfg('d2', max_window_age_hours=1)
    policy('host_sample', f'instance_id <> {I2} OR pqproof.slow(6)', RD)
    try:
        p = subprocess.Popen([BIN, 'export', '-config', c2], env=dict(ENV0, PGVIGIL_EXPORT_DSN=EXP_DSN), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        reading = wait_reading('host_sample'); rb = export(c2); o, e = p.communicate(timeout=300)
    finally:
        unpolicy('host_sample')
    check(reading and rb[0] == 0 and 'lock' in (rb[1] + rb[2]).lower() and p.returncode == 0 and man('d2', Wk(1)) is not None,
          f'D: two runs at once: one works (rc {p.returncode}), the other exits 0 saying it is locked (rc {rb[0]}: {(rb[1] + rb[2]).strip()[:120]})')

def row_E():
    c = cfg('e')
    owner = f'pqp_own_{SUF}'; adm.run(f'CREATE ROLE {owner} NOLOGIN')
    cases = [('col', 'IN ROLE pgvigil_reader, pgvigil_collector', 'pgvigil_collector', None),
             ('alr', 'IN ROLE pgvigil_reader, pgvigil_alerter', 'pgvigil_alerter', None),
             ('noi', f'NOINHERIT IN ROLE pgvigil_reader, {owner}', owner, None),
             ('sup', 'SUPERUSER IN ROLE pgvigil_reader', 'superuser', None),
             ('upd', 'IN ROLE pgvigil_reader', 'host_state', 'GRANT UPDATE ON pgvigil.host_state TO {}')]
    for tag, clause, word, grant in cases:
        n = login(tag, clause)
        if grant: q(grant.format(n))
        rc, out, err = window(c, Wk(2), dsn_=dsn(n, PW))
        check(rc == 3 and word in err and not tree(f'{W}/dest-e'), f'E: a login that could write is refused, exit 3, naming {word} (rc {rc}: {err.strip()[:140]})')
        if grant: q(f'REVOKE UPDATE ON pgvigil.host_state FROM {n}')
    q('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pqproof TO public')
    policy('database_sizes', "pqproof.probe('database_sizes')", RD)
    try:
        refused = ''
        try: conn(RD, PW, DB).run('SELECT count(*) FROM pgvigil.database_sizes')
        except Exception as e: refused = str(e)
        check('probe: transaction_read_only is off' in refused, f'E: the probe refuses the same login in a plain session ({refused[:110]})')
        rc, out, err = window(c, Wk(2)); m = man('e', Wk(2))
        got = sorted(r['datname'] for r in rows('e', m, 'database_sizes') if r['instance_id'] == I1)
        check(rc == 0 and got == ['e-0', 'e-1', 'e-2', 'e-3'], f'E: the export reads through the probe: READ ONLY, REPEATABLE READ, its name, its timeouts, its comment (rc {rc}, rows {got}: {err.strip()[:200]})')
    finally:
        unpolicy('database_sizes')
    c3 = cfg('e3', max_window_age_hours=1, statement_timeout='1s')
    policy('table_sizes', 'pqproof.slow(3)', RD)
    try:
        r = [export(c3) for _ in range(2)]; m12 = man('e3', Wk(1)); r3 = export(c3); m3 = man('e3', Wk(1))
    finally:
        unpolicy('table_sizes')
    f = (m3 or {}).get('failed') or []
    check([x[0] for x in r] == [1, 1] and m12 is None, f'E: a table over the timeout fails its window twice: exit 1, no manifest (rc {[x[0] for x in r]})')
    check(r3[0] == 1 and m3 is not None and [x['table'] for x in f] == ['table_sizes'] and entry(m3, 'host_sample') is not None and entry(m3, 'table_sizes') is None,
          f'E: on the third run the table is in failed[] and the window complete, exit 1 (rc {r3[0]}, failed {f})')

def row_F():
    w = Wk(2); c = cfg('f'); ct = cfg('ft', carry=['text'])
    r1 = window(c, w); r2 = window(ct, w); m = man('f', w); mt = man('ft', w)
    if not check(r1[0] == 0 and r2[0] == 0, f'F: W2 exports without and with carry text (rc {r1[0]}, {r2[0]}: {(r1[2] + r2[2]).strip()[:200]})'): return
    s = skipped(m, 'ui_users')
    check(s is not None and entry(m, 'ui_users') is None and not os.path.isdir(f'{root("f")}/ui_users'), f'F: ui_users has no file and is in skipped ({s})')
    dc = lambda mm, t: sorted(x['column'] for x in mm.get('dropped_columns', []) if x['table'] == t)
    sends = [r for r in rows('f', m, 'report_mail_sends') if r['name'] == 'f-send']
    check(len(sends) == 1 and not ({'html', 'xlsx', 'recipients', 'subject'} & set(sends[0])) and dc(m, 'report_mail_sends') == ['html', 'recipients', 'subject', 'xlsx'],
          f'F: report_mail_sends carried without its mail columns, the four named ({dc(m, "report_mail_sends")})')
    e1 = [r for r in rows('f', m, 'mssql_errorlog') if r['line_key'] == 'f-1']; e2 = [r for r in rows('ft', mt, 'mssql_errorlog') if r['line_key'] == 'f-1']
    reason = next((x.get('reason', '') for x in m.get('dropped_columns', []) if x['table'] == 'mssql_errorlog' and x['column'] == 'message'), '')
    check(len(e1) == 1 and 'message' not in e1[0] and 'text' in reason, f'F: the log\'s text column is dropped without carry text and named ({reason!r})')
    check(len(e2) == 1 and e2[0].get('message') == 'f secret text' and 'message' not in dc(mt, 'mssql_errorlog') and dc(mt, 'report_mail_sends') == ['html', 'recipients', 'subject', 'xlsx'],
          'F: with carry text the text column is carried; the mail columns stay dropped')

def row_G():
    import boto3, botocore
    from azure.storage.blob import BlobServiceClient
    w = Wk(3); s3url = os.environ['S3URL']; azconn = os.environ['AZCONN']
    ak = 'k' + os.urandom(8).hex(); sk = os.urandom(20).hex()
    s3 = boto3.client('s3', endpoint_url=s3url, aws_access_key_id=ak, aws_secret_access_key=sk, region_name='us-east-1',
                      config=botocore.config.Config(s3={'addressing_style': 'path'}))
    for _ in range(60):
        try: s3.create_bucket(Bucket='pq-proof'); break
        except Exception: time.sleep(1)
    az = BlobServiceClient.from_connection_string(azconn).get_container_client('pq-proof')
    for _ in range(60):
        try: az.create_container(); break
        except Exception: time.sleep(1)
    cf = cfg('g'); cs = cfg('gs', dest={'type': 's3', 'bucket': 'pq-proof', 'prefix': 'px', 'region': 'us-east-1', 'endpoint': s3url})
    ca = cfg('ga', dest={'type': 'azure_blob', 'container': 'pq-proof', 'prefix': 'px', 'connection_string': 'env:PQ_AZ_CONN'})
    env = {'AWS_ACCESS_KEY_ID': ak, 'AWS_SECRET_ACCESS_KEY': sk, 'PQ_AZ_CONN': azconn}
    rs = [window(c, w, env=env) for c in (cf, cs, ca)]
    if not check(all(r[0] == 0 for r in rs), f'G: the window exports to the folder, the S3-compatible server and Azurite (rc {[r[0] for r in rs]}: {"".join(r[2] for r in rs).strip()[:240]})'): return
    pre = f'px/{NAME}/'
    lf = {p: os.path.getmtime(f'{root("g")}/{p}') for p in tree(root('g'))}
    ls = {}
    for pg_ in s3.get_paginator('list_objects_v2').paginate(Bucket='pq-proof', Prefix=pre):
        for o in pg_.get('Contents', []): ls[o['Key'][len(pre):]] = o['LastModified'].timestamp()
    la = {b.name[len(pre):]: b.last_modified.timestamp() for b in az.list_blobs(name_starts_with=pre)}
    check(sorted(lf) == sorted(ls) == sorted(la) and len(lf) >= 3, f'G: the three listings hold the same names ({len(lf)} folder, {len(ls)} S3, {len(la)} Blob)')
    os.makedirs(f'{W}/dl-gs/{NAME}', exist_ok=True); os.makedirs(f'{W}/dl-ga/{NAME}', exist_ok=True)
    for k in ls:
        p = f'{W}/dl-gs/{NAME}/{k}'; os.makedirs(os.path.dirname(p), exist_ok=True); s3.download_file('pq-proof', pre + k, p)
    for k in la:
        p = f'{W}/dl-ga/{NAME}/{k}'; os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'wb') as fh: az.download_blob(pre + k).readinto(fh)
    os.symlink(f'{W}/dl-gs', f'{W}/dest-gsd'); os.symlink(f'{W}/dl-ga', f'{W}/dest-gad')
    ms = {t: man(t, w) for t in ('g', 'gsd', 'gad')}
    bad = {t: sums_hold(t, m) if m else ['no manifest'] for t, m in ms.items()}
    check(not any(bad.values()), f'G: every file\'s sha256, size and rows are the ones its own manifest gives, in all three ({ {t: b[:2] for t, b in bad.items() if b} })')
    key = lambda r: json.dumps(r, sort_keys=True, default=str)
    eq = all(sorted(map(key, rows('g', ms['g'], t))) == sorted(map(key, rows(o, ms[o], t))) for t in ('host_sample', 'instances') for o in ('gsd', 'gad')) if all(ms.values()) else False
    check(eq and len([r for r in rows('g', ms['g'], 'host_sample') if r['instance_id'] == I3]) == 5, 'G: each table\'s rows are equal across the three destinations')
    mn = f'_manifests/{mname(w)}'
    last = all(mn in l and l[mn] >= max(v for k, v in l.items() if not k.startswith('_manifests/')) for l in (lf, ls, la))
    check(last, 'G: each manifest is the newest object of its window')
    big = {t: entry(m, 'collection_log') for t, m in ms.items() if m}
    groups = pq.ParquetFile(f'{root("g")}/{files(ms["g"], "collection_log")[0]}').metadata.num_row_groups if ms['g'] and files(ms['g'], 'collection_log') else 0
    size = sum(f['byte_size'] for f in (big.get('g') or {}).get('output_files', []))
    check(len(big) == 3 and all(e and e['row_count'] == 5500 for e in big.values()) and size > 64 * 1024 * 1024 and groups > 1,
          f'G: a table over the 64 MB line reads back whole from all three, in more than one row group ({size} bytes, {groups} row groups)')

def row_H():
    import urllib.request
    if not check(HAS_EXPORTER, 'H: the role pgvigil_exporter exists'): return
    ex = login('exp', 'IN ROLE pgvigil_exporter'); xd = dsn(ex, PW)
    c = cfg('h', max_window_age_hours=2)
    rc, out, err = export(c, dsn_=xd)
    runs = q("SELECT window_from, outcome, files, rows, bytes FROM pgvigil.export_runs ORDER BY window_from")
    want = []
    for k in (2, 1):
        m = man('h', Wk(k)) or {'tables': []}
        want.append([Wk(k)[0], 'ok', sum(len(t.get('output_files', [])) for t in m['tables']), sum(t['row_count'] for t in m['tables']), sum(f['byte_size'] for t in m['tables'] for f in t.get('output_files', []))])
    check(rc == 0 and [list(r) for r in runs] == want, f'H: one export_runs row per window with the manifest\'s figures (rc {rc}, {len(runs)} rows: {err.strip()[:160]})')
    check(q("SELECT name FROM pgvigil.export_state") == [[NAME]], 'H: the export_state row')
    refused = ''
    try: conn(ex, PW, DB).run("INSERT INTO pgvigil.export_runs (window_from, window_to, started_at, outcome) VALUES (now(), now(), now(), 'ok')")
    except Exception as e: refused = str(e)
    check('permission denied' in refused, f'H: the login\'s own INSERT into export_runs is refused ({refused[:90]})')
    port = free_port()
    p = subprocess.Popen([BIN, 'serve', '-config', c, '-dsn', 'env:PGVIGIL_REPO_DSN', '-listen', f'127.0.0.1:{port}', '-no-login'], env=dict(ENV0, PGVIGIL_EXPORT_DSN=xd), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        api = None
        for _ in range(60):
            try: api = json.load(urllib.request.urlopen(f'http://127.0.0.1:{port}/api/export', timeout=5)); break
            except Exception: time.sleep(0.5)
        t = (api or {}).get('runs') or {}
        check(api is not None and 'outcome' in t.get('columns', []) and len(t.get('rows', [])) == 2, f'H: GET /api/export lists the runs ({len(t.get("rows", []))} rows)')
    finally:
        p.kill(); p.wait()
    svc = lambda: [r[0] for r in q('SELECT detail FROM pgvigil.export_service')]
    check(svc() == [], f'H: no service row while the export is current ({svc()})')
    open(f'{W}/notadir', 'w').write('x'); cb = cfg('hb', dest={'type': 'folder', 'path': f'{W}/notadir/x'}, state=f'{W}/state-h', max_window_age_hours=2)
    rcb, _, errb = window(cb, Wk(1), dsn_=xd)
    lastrun = q("SELECT outcome, error FROM pgvigil.export_runs ORDER BY started_at DESC, run_id DESC LIMIT 1")[0]
    check(rcb == 1 and lastrun[0] == 'failed' and lastrun[1] and any('the last run failed' in d for d in svc()), f'H: a failed run is a row with its error and the service row names it (rc {rcb}, {lastrun[0]}, {svc()})')
    rc2, _, _ = window(c, Wk(1), dsn_=xd)
    q("UPDATE pgvigil.export_runs SET window_from = window_from - interval '4 hours', window_to = window_to - interval '4 hours', started_at = started_at - interval '4 hours', finished_at = finished_at - interval '4 hours'")
    q("UPDATE pgvigil.export_state SET last_run_at = last_run_at - interval '4 hours', newest_window_to = newest_window_to - interval '4 hours'")
    check(rc2 == 0 and any('behind' in d for d in svc()), f'H: four hours behind is a service row ({svc()})')
    rco, _, erro = export(c, '-off', dsn_=xd)
    check(rco == 0 and q('SELECT count(*) FROM pgvigil.export_state')[0][0] == 0 and svc() == [], f'H: after -off no export_state row and no service row (rc {rco}: {erro.strip()[:120]})')

def row_J():
    c = cfg('j', max_window_age_hours=3)
    rc, out, err = export(c, '-plan', '-json')
    pl = json.loads(out) if rc == 0 and out.strip().startswith('{') else {}
    wins = [(x['from_utc'], x['to_utc']) for x in pl.get('windows', [])]
    kinds = {t['table']: t['kind'] for t in pl.get('tables', [])}
    check(rc == 0 and wins == [(iso(Wk(k)[0]), iso(Wk(k)[1])) for k in (3, 2, 1)] and kinds.get('host_sample') == 'window' and kinds.get('host_state') == 'state' and not tree(f'{W}/dest-j'),
          f'J: -plan lists the three due windows and each table\'s kind and writes nothing (rc {rc}, {wins}: {err.strip()[:120]})')
    rc, out, err = export(c, '-check')
    check(rc == 0 and not tree(f'{W}/dest-j'), f'J: -check exits 0 on a good folder and leaves it empty (rc {rc}: {err.strip()[:120]})')
    open(f'{W}/jfile', 'w').write('x'); cbad = cfg('jbad', dest={'type': 'folder', 'path': f'{W}/jfile/x'})
    rc, out, err = export(cbad, '-check')
    check(rc == 3 and err.strip(), f'J: -check exits 3 on a destination that cannot be written (rc {rc}: {err.strip()[:120]})')
    w6 = Wk(6); r6 = window(c, w6); r = export(c)
    holes = [Wk(5), Wk(4)]
    named = all(f'-from {iso(h[0])} -to {iso(h[1])}' in (r[1] + r[2]) for h in holes)
    check(r6[0] == 0 and r[0] == 1 and named and all(man('j', Wk(k)) is not None for k in (3, 2, 1)), f'J: a hole between the oldest manifest and the age line is named with its -from / -to line, exit 1 (rc {r[0]}: {(r[1] + r[2]).strip()[-200:]})')
    rs = export(c, '-status', '-json'); st = json.loads(rs[1]) if rs[0] in (0, 1) and rs[1].strip().startswith('{') else {}
    check([(x['from_utc'], x['to_utc']) for x in st.get('aged_out', [])] == [(iso(h[0]), iso(h[1])) for h in holes] and st.get('newest', {}).get('to_utc') == iso(Wk(1)[1]) and st.get('missing') == [],
          f'J: -status lists the aged-out hours and the newest window ({st.get("aged_out")}, {st.get("newest")})')
    rg = export(c, '-gap', iso(Wk(5)[0]), iso(Wk(4)[1])); g5 = man('j', Wk(5)); r2 = export(c)
    check(rg[0] == 0 and g5 and g5.get('gap') is True and g5.get('tables') == [] and r2[0] == 0, f'J: -gap writes gap manifests and the next run exits 0 (rc {rg[0]}, {r2[0]}: {rg[2].strip()[:120]})')
    w5 = Wk(5); cb = cfg('jbig'); rb = window(cb, w5); mb = man('jbig', w5); fs = files(mb, 'host_sample')
    counts = [pq.ParquetFile(f'{root("jbig")}/{p}').metadata for p in fs]
    check(rb[0] == 0 and len(fs) == 2 and fs[1].endswith('__p2.parquet') and not re.search(r'__p\d+\.parquet$', fs[0]) and [m.num_rows for m in counts] == [1000000, 1]
          and counts[0].num_row_groups == 20 and max(counts[0].row_group(i).num_rows for i in range(20)) == 50000 and entry(mb, 'host_sample')['row_count'] == 1000001,
          f'J: 1,000,001 rows come out as two files of 1,000,000 and 1 rows in row groups of at most 50,000 (rc {rb[0]}, {fs}, {[m.num_rows for m in counts]}, {[m.num_row_groups for m in counts]} row groups)')
    before = tree(f'{W}/dest-jbig'); ro = window(cb, Wk(2), '-out', f'{W}/out-j')
    check(ro[0] == 0 and os.path.isfile(f'{W}/out-j/{NAME}/_manifests/{mname(Wk(2))}') and tree(f'{W}/dest-jbig') == before, f'J: -out writes the window to another folder and leaves the destination as it was (rc {ro[0]}: {ro[2].strip()[:120]})')

ALL = [('I', row_I), ('A', row_A), ('A2', row_A2), ('B', row_B), ('B2', row_B2), ('C', row_C), ('D', row_D), ('E', row_E), ('F', row_F), ('G', row_G), ('H', row_H), ('J', row_J)]
for name, fn in ALL:
    if name not in ROWS: continue
    t0 = time.time()
    try: fn()
    except Exception as e:
        check(False, f'{name}: the row raised {type(e).__name__}: {str(e)[:300]}'); traceback.print_exc(limit=3, file=sys.stdout)
    print(f'-- row {name} in {time.time() - t0:.0f} s'); sys.stdout.flush()
print(f'proof-parquet: {nok} ok, {nfail} FAIL (rows {" ".join(ROWS)})')
sys.exit(1 if nfail else 0)
PY
docker run --rm --name "$PYC" --network host --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -e PGVIGIL_ADMIN_DSN -e PROOF_ROWS="$ROWS" -e PROOF_SEED_ONLY="${PROOF_SEED_ONLY:-}" -e SUF="$SUF" -e S3URL="$S3URL" -e AZCONN="$AZCONN" \
  -v "$WORK:/w" -v "$BIN:/pgvigil:ro" "$IMG_PY" \
  sh -c 'pip install -q --disable-pip-version-check --target /tmp/py pyarrow boto3 azure-storage-blob pg8000 2>&1 | tail -3; python /w/proof.py'
