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
# than 25 minutes of it are left (its rows take about 4 minutes on the box), and a row that reads due windows says
# so, not FAIL, if the hour turned under it all the same.
#
# Expected (written before the first run):
#  I.  off by default: with no `export:` section `pgvigil export` exits 3 and its one line names the section; `pgvigil
#      serve` with an `export:` section opens no session named pgvigil-export and writes nothing at the destination.
#  A.  the catalogue: `-tables-list -json` names every table of the schema that is not a partition, each once, none a
#      partition (partitions of two months exist); class, time column, carry, text columns, dropped columns, audit
#      columns and audit rows equal scripts/proof-parquet-census.tsv line by line (that list was read from how each
#      import writes its table), the key columns equal the primary key in the catalogs; every text, JSON and bytes
#      column of an exported table is one the census names (a column a later migration adds fails here until it is
#      read and classed). A table the map does not name stops a run before any read:
#      exit 1, 'is not classed', nothing at the destination.
#  A2. classes: a state table (host_state) is absent from an hourly window's manifest and whole in Wd's; `instances`
#      is in both; with carry [text] a dimension (statement_text) carries in an hourly window the text last seen in
#      or after it and not the one last seen before it, and both in Wd; without carry it is in `skipped` with the
#      carry it needs, as an audit table (hba_rules) is. With snapshot_max_bytes 1 every state table is in `skipped`
#      naming that key, `instances` is carried all the same, and a dimension keeps its hourly read (its entry says its
#      whole copy is left out). A job run with no start time (a window table whose time column may be NULL) is in
#      the day's first window, and in no hourly one.
#  B.  a window and the types: of five host_sample rows (at the window's start, inside, 1 microsecond before its end,
#      at its end, 1 microsecond before its start) W2's file holds exactly the first three; an event stored now with
#      event_at in W4 is in W4's file and not in W2's. Read back by pyarrow: every column OPTIONAL and in the table's
#      own order, pages ZSTD, and one seeded value of each of the schema's 19 column types under its Parquet type
#      (the list is in the row), NULLs as nulls; a timestamp of infinity and a NaN in a DECIMAL column are null and
#      the manifest's column says 'infinite as null'; the identity figures are text holding their exact digits
#      (18446744073709551615, 9223372036854775807, -5: a 16-byte DECIMAL's statistics would misorder a negative).
#  B2. the final pass: after pass 1 of W4 (manifest pass 1) a job run and a Query Store interval are stored with
#      their time in W4; a run with final_after_hours 2 exports W4 again under the same names: the manifest says
#      final, both late rows are in the files, the marker _manifests/_final/<window> exists; a table whose only row
#      of W4 was deleted after pass 1 has row_count 0 and its pass-1 file is gone; W1 is still pass 1 with no marker. A final pass killed while it reads leaves the files it had written, no manifest for its window
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
#      grant on a table, on one column, on a sequence, CREATE on the schema, CREATEROLE, or EXECUTE granted to it on
#      an import function. The reading session: a row-security probe on database_sizes raises unless the transaction is READ ONLY
#      and REPEATABLE READ, application_name is pgvigil-export, lock_timeout 5s, work_mem 16MB, no parallel workers,
#      statement_timeout 2min and the statement starts with /* pgvigil-export:database_sizes */ - the export reads
#      the table (its rows are in the file) while the same login in a plain session is refused by the probe. A table
#      whose read outlasts statement_timeout fails its window twice (exit 1, no manifest) and on the third run is in
#      the manifest's failed[] with the window complete (exit 1); a table a FINAL pass gives up keeps its pass-1 file,
#      listed in the final manifest with a note. A FINAL pass that fails on a window which ended
#      before the reach leaves that window without its manifest - and the next run does it again (it is not called
#      aged out): final manifest, every sha256 its file's own, exit 0.
#  F.  left out and dropped: no ui_users file, the table in `skipped`; report_mail_sends is carried without html,
#      xlsx, recipients, subject and error (a mail server's reply) whatever is carried, and without requested_by and
#      client unless audit is carried, each named in dropped_columns; without audit a failed sign-in of the server
#      log is not carried and the manifest's filtered_rows says so, with it it is; under carry [audit] alone an audit
#      trail is carried WITHOUT its statement and parameters (text); mssql_errorlog is carried without message
#      (named in dropped_columns as text) and with it under carry [text], where a value of 9 MB reads back whole (a
#      page's header must not hold the page's largest value: readers refuse a header past 16 MB); a table named in tables.exclude is in
#      `skipped` naming that key, the others carried; a name there that is no table, and `instances`, are refused
#      (exit 3).
#  G.  destinations: one window written to a folder, to the S3-compatible server and to Azurite: the three listings
#      hold the same names, every file's sha256 is the one its own manifest gives, each table's rows are equal across
#      the three, each manifest is the newest object of its window; a table of about 175 MB of text (over the 64 MB
#      line, so in parts on S3 and in blocks on Blob) reads back with its row count in all three and in more than
#      one row group.
#  H.  the page door: a run by a login in the exporter role leaves one export_runs row per window (outcome ok, its
#      files / rows / bytes the manifest's) and the export_state row; the same login's own INSERT into export_runs is
#      refused; GET /api/export lists the runs, and answers nothing (not an error) where the repository has no
#      export record; a window whose last attempt failed keeps the service's line while other windows succeed, and
#      loses it when it is exported; a run whose destination does not answer (a path under a file) exits
#      1 and is a row with outcome failed and its error, and export_service names 'the last run failed'; the newest run moved 4 hours back makes it name the hours
#      behind; after `pgvigil export -off` export_state and export_runs are empty and export_service has no row. A
#      reader login that is no exporter is refused by both door functions (42501); the door refuses a row out of
#      bounds (22023).
#  J.  doors and caps: `-plan -json` lists the three due windows and each table's kind and writes nothing; `-check`
#      exits 0 on a good folder (left empty) and 3 on a destination that cannot be written; a hole between the
#      oldest manifest and the age line is named with its -from / -to line, exit 1, and `-status -json` lists it;
#      `-gap` writes gap manifests and the next run exits 0; a window that ended before the reach and has its first
#      pass still gets its final pass, and an accepted hole stays a hole; `-gap` over hours that are not aged out
#      (in reach, or not yet passed) is refused and writes nothing; 1,000,001 rows of one table and window come out as two
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
if not SEED_ONLY and left < 1500:   # the rows that read due windows must all run inside one clock hour
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
for t in sorted({Wk(k)[0].replace(day=1, hour=0) for k in range(0, 8)} | {(H0 - 31 * 24 * HR).replace(day=1, hour=0)}):
    for tb in ('host_sample', 'database_sizes', 'mssql_job_runs', 'mssql_qs_interval', 'mssql_cpu_sample', 'job_stats_hourly',
               'mssql_pool_minute', 'activity_sample', 'table_sizes', 'log_events', 'pgaudit_events'):
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
    q(f"INSERT INTO pgvigil.job_runs (instance_id, scheduler, job_id, run_id, snapshot_at, start_time, status) VALUES "
      f"({I1}, 'pg_cron', 7, 1, now(), NULL, 'failed'), ({I1}, 'pg_cron', 7, 2, now(), CAST({lit(wn[0] + dt.timedelta(minutes=4))} AS timestamptz), 'succeeded')")
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
      f"({M1}, 'd', 's', 't', 'nan', 'ok', now(), 1, 2, NULL, 'NaN', NULL, NULL), "
      f"({M1}, 'd', 's', 't', 'neg', 'ok', now(), -5, 2147483647, NULL, NULL, NULL, NULL)")
    q(f"INSERT INTO pgvigil.mssql_pool_thresholds (server, pool, warning, critical) VALUES ('s-{SUF}', 'p1', 0.8125, 0.9)")
    q(f"INSERT INTO pgvigil.mssql_build (instance_id, snapshot_at, known, exact, newer, status, release_date) VALUES ({M1}, now(), true, true, false, 'ok', DATE '2026-03-14')")
    q(f"INSERT INTO pgvigil.pg_wal_replay (instance_id, snapshot_at, is_present, replay_lsn) VALUES ({I1}, now(), true, '16/B374D848')")
def seed_B2():
    a, _ = Wk(4)
    q(f"INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, step_id, job_name) VALUES ({M1}, CAST({lit(a + dt.timedelta(minutes=5))} AS timestamptz), 1, 'J1', 0, 'b2 early')")
    q(f"INSERT INTO pgvigil.table_sizes (instance_id, snapshot_at, dbid, relid) VALUES ({I2}, CAST({lit(Wk(5)[0] + dt.timedelta(minutes=5))} AS timestamptz), 1, 77)")
    ds(I2, Wk(5)[0] + dt.timedelta(minutes=5), 300, 'b2-cut')
    ds(I2, a + dt.timedelta(minutes=5), 301, 'b2-gone')
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
    q(f"INSERT INTO pgvigil.table_sizes (instance_id, snapshot_at, dbid, relid) VALUES ({I1}, CAST({lit(Wk(1)[0] + dt.timedelta(minutes=3))} AS timestamptz), 1, 88), "
      f"({I1}, CAST({lit(Wk(3)[0] + dt.timedelta(minutes=3))} AS timestamptz), 1, 89), ({I1}, CAST({lit(Wk(2)[0] + dt.timedelta(minutes=3))} AS timestamptz), 1, 90)")
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
      f"({M1}, CAST({lit(w[0] + dt.timedelta(minutes=40))} AS timestamptz), 'f-1', now(), TIMESTAMP '2026-01-02 03:04:05', 'general', '{{}}', false, 'f secret text'), "
      f"({M1}, CAST({lit(w[0] + dt.timedelta(minutes=41))} AS timestamptz), 'f-big', now(), TIMESTAMP '2026-01-02 03:04:06', 'general', '{{}}', false, repeat('m', 9000000))")
    q(f"INSERT INTO pgvigil.log_events (instance_id, snapshot_at, kind, source, event_key, usename, client, statement, message) VALUES "
      f"({I1}, CAST({lit(w[0] + dt.timedelta(minutes=12))} AS timestamptz), 'auth_fail', 'log', 'f-auth', 'intruder', '10.0.0.9', NULL, 'password authentication failed'), "
      f"({I1}, CAST({lit(w[0] + dt.timedelta(minutes=13))} AS timestamptz), 'slow', 'log', 'f-slow', 'app', '10.0.0.8', 'select f slow', NULL)")
    q(f"INSERT INTO pgvigil.pgaudit_events (instance_id, snapshot_at, audit_type, class, command, source, event_key, statement, parameters) VALUES "
      f"({I1}, CAST({lit(w[0] + dt.timedelta(minutes=14))} AS timestamptz), 'SESSION', 'READ', 'SELECT', 'log', 'f-aud', 'select f audited', '42')")
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
        got = (t['class'], t.get('time_column') or '', t.get('carry') or '', ','.join(t.get('text_columns') or []), ','.join(t.get('dropped_columns') or []),
               ','.join(t.get('audit_columns') or []), t.get('audit_rows') or '')
        want = (e['class'], e['time_column'], e['carry'], e['text_columns'], e['dropped_columns'], e['audit_columns'], e['audit_rows'])
        if got != want: bad.append(f"{t['table']}: {got} against the census {want}")
        if (t.get('key_columns') or []) != (store.get(t['table']) or []): bad.append(f"{t['table']}: key {t.get('key_columns')} against {store.get(t['table'])}")
    check(not bad, f'A: class, time column, carry, text, dropped and audit columns equal the census, the key the primary key ({len(lst)} tables; {len(bad)} differ: {bad[:4]})')
    live = {}
    for tn, cn in q("SELECT c.relname, a.attname FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace "
                    "WHERE n.nspname = 'pgvigil' AND c.relkind IN ('r', 'p') AND NOT c.relispartition AND a.attnum > 0 AND NOT a.attisdropped "
                    "AND format_type(a.atttypid, NULL) IN ('text', 'jsonb', 'json', 'bytea', 'text[]', 'character varying', 'xml') ORDER BY c.relname, a.attnum"):
        live.setdefault(tn, set()).add(cn)
    pin = {n: set(filter(None, e['string_columns'].split(','))) for n, e in cen.items() if e['class'] != 'left-out'}
    badpin = [f'{n}: {sorted(live.get(n, set()) ^ p)}' for n, p in pin.items() if live.get(n, set()) != p]
    check(len(pin) > 250 and not badpin, f'A: every text, JSON and bytes column of an exported table is one the census names ({sum(map(len, pin.values()))} columns of {len(pin)} tables; {len(badpin)} tables differ: {badpin[:3]})')
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
    c3 = cfg('a2m', carry=['text'], snapshot_max_bytes=1); r4 = window(c3, WD); m4 = man('a2m', WD); s3 = skipped(m4, 'host_state')
    check(r4[0] == 0 and s3 and 'snapshot_max_bytes' in s3['reason'] and entry(m4, 'host_state') is None and len(rows('a2m', m4, 'instances')) == ninst,
          f'A2: a state table over snapshot_max_bytes is skipped naming the key; instances is carried all the same ({s3})')
    ed = entry(m4, 'statement_text') or {}
    check(skipped(m4, 'statement_text') is None and 'snapshot_max_bytes' in (ed.get('note') or '') and 9001 in {r['queryid'] for r in rows('a2m', m4, 'statement_text')},
          f'A2: a dimension over snapshot_max_bytes keeps its hourly read and says its whole copy is left out (note {ed.get("note")!r})')
    jn = {r['run_id'] for r in rows('a2', mn, 'job_runs') if r['instance_id'] == I1 and r['job_id'] == 7}
    jd = {r['run_id'] for r in rows('a2', md, 'job_runs') if r['instance_id'] == I1 and r['job_id'] == 7}
    check(jn == {2} and jd == {1}, f'A2: a job run with no start time is in the day\'s first window and in no hourly one (hourly {sorted(jn)}, the day\'s first {sorted(jd)})')

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
        ('numeric whole figure as text', md, 'mssql_identity_column', 'max_value', 'BYTE_ARRAY', 'String', idc, '18446744073709551615'),
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
    idg = one(md, 'mssql_identity_column', lambda r: r['column_name'] == 'neg') or {}
    check(idc.get('last_value') == '9223372036854775807' and idc.get('anchor_value') == '18446744073709551615' and idg.get('last_value') == '-5' and idg.get('max_value') == '2147483647',
          f'B: the identity figures exact as text, past the bigint line and below zero ({idc.get("last_value")}, {idc.get("anchor_value")}, {idg.get("last_value")})')
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
    gone = glob.glob(f'{root("b2")}/database_sizes/*__{stamp(w4[0])}__{stamp(w4[1])}*')
    check(len(gone) == 1 and entry(m, 'database_sizes')['row_count'] == 1, f'B2: pass 1 wrote the file of a row that is deleted before the final pass ({len(gone)} file)')
    seed_B2_late(); q("DELETE FROM pgvigil.database_sizes WHERE datname = 'b2-gone'")
    cb = cfg('b2f', dest=dest, state=state, final_after_hours=2)
    policy('table_sizes', 'pqproof.slow(45)', RD); t_cut = time.time()
    try:
        p = subprocess.Popen([BIN, 'export', '-config', cb], env=dict(ENV0, PGVIGIL_EXPORT_DSN=EXP_DSN), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        reading = wait_reading('table_sizes'); p.kill(); p.wait()
    finally:
        unpolicy('table_sizes')
        for s in export_sessions(): q(f'SELECT pg_terminate_backend({s[0]})')
    mk = lambda w: os.path.exists(f'{root("b2")}/_manifests/_final/{NAME}__{stamp(w[0])}__{stamp(w[1])}')
    rewritten = [f for f in glob.glob(f'{root("b2")}/database_sizes/*__{stamp(w5[0])}__{stamp(w5[1])}*') if os.path.getmtime(f) >= t_cut - 1]
    check(reading and man('b2', w5) is None and not mk(w5) and rewritten, f'B2: a final pass killed while it reads leaves its files, no manifest and no marker for its window (reading seen {reading}, files written again {len(rewritten)}, manifest {man("b2", w5) is not None}, marker {mk(w5)})')
    rc, out, err = export(cb); m5 = man('b2', w5); m4 = man('b2', w4); m1 = man('b2', w1)
    check(rc == 0 and m5 and m5['pass'] == 'final' and mk(w5) and not sums_hold('b2', m5), f'B2: the next run does the cut window again (rc {rc}, pass {m5 and m5["pass"]}, marker {mk(w5)})')
    jr = sorted(r['job_name'] for r in rows('b2', m4, 'mssql_job_runs')); qs = [r['database_name'] for r in rows('b2', m4, 'mssql_qs_interval')]
    check(m4 and m4['pass'] == 'final' and jr == ['b2 early', 'b2 late'] and qs == ['b2db'] and mk(w4), f'B2: the final pass carries the rows stored after pass 1 under the same names (pass {m4 and m4["pass"]}, job runs {jr}, intervals {qs}, marker {mk(w4)})')
    e4 = entry(m4, 'database_sizes') or {}
    left = glob.glob(f'{root("b2")}/database_sizes/*__{stamp(w4[0])}__{stamp(w4[1])}*')
    check(e4.get('row_count') == 0 and not e4.get('output_files') and not left, f'B2: a table with no row any more has row_count 0 in the final manifest and its pass-1 file is gone (row_count {e4.get("row_count")}, files left {len(left)})')
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
    check(rc3 == 0 and len(subs) == 1 and ms and ms.get('subset') is True and 'subset' not in man('c', w3) and [t['table'] for t in ms['tables']] == ['database_sizes'] and all(mark in p for p in files(ms, 'database_sizes')) and not sums_hold('c', ms),
          f'C: a subset run writes its own manifest and files marked {mark} (rc {rc3}, {subs}: {err3.strip()[:120]})')
    check(not sums_hold('c', man('c', w3)), 'C: the full manifest\'s sha256 still hold beside the subset\'s')

def row_D():
    c = cfg('d', max_window_age_hours=3, max_windows_per_run=2)
    have = lambda: [k for k in (4, 3, 2, 1) if man('d', Wk(k)) is not None]
    r1 = export(c); h1 = have(); r2 = export(c); h2 = have(); r3 = export(c); h3 = have()
    check(r1[0] == 0 and h1 == [3, 2] and re.search(r'\b1 more window\(s\) due', r1[1] + r1[2]), f'D: the first run writes the two oldest due windows and says one more is due (rc {r1[0]}, W{h1}: {(r1[1] + r1[2]).strip()[-160:]})')
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
             ('upd', 'IN ROLE pgvigil_reader', 'host_state', 'GRANT UPDATE ON pgvigil.host_state TO {}'),
             ('ucol', 'IN ROLE pgvigil_reader', 'host_state', 'GRANT UPDATE (host_name) ON pgvigil.host_state TO {}'),
             ('seq', 'IN ROLE pgvigil_reader', 'instances_instance_id_seq', 'GRANT UPDATE ON SEQUENCE pgvigil.instances_instance_id_seq TO {}'),
             ('cre', 'IN ROLE pgvigil_reader', 'CREATE', 'GRANT CREATE ON SCHEMA pgvigil TO {}'),
             ('crr', 'CREATEROLE IN ROLE pgvigil_reader', 'CREATEROLE', None),
             ('fn', 'IN ROLE pgvigil_reader', 'import_dbstats', 'GRANT EXECUTE ON FUNCTION pgvigil.import_dbstats(int, timestamptz, jsonb) TO {}')]
    for tag, clause, word, grant in cases:
        n = login(tag, clause)
        if grant: q(grant.format(n))
        rc, out, err = window(cfg('e-' + tag), Wk(2), dsn_=dsn(n, PW))
        check(rc == 3 and word in err and not tree(f'{W}/dest-e-{tag}'), f'E: a login that could write is refused, exit 3, naming {word} (rc {rc}: {err.strip()[:140]})')
        if grant: q(grant.format(n).replace('GRANT ', 'REVOKE ', 1).replace(' TO ', ' FROM '))
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
    # (the window had no earlier pass: nothing to carry)
    check(r3[0] == 1 and m3 is not None and [x['table'] for x in f] == ['table_sizes'] and entry(m3, 'host_sample') is not None and entry(m3, 'table_sizes') is None,
          f'E: on the third run the table is in failed[] and the window complete, exit 1 (rc {r3[0]}, failed {f})')
    # a final pass that fails on a window which ended before the reach: done again by the next run, never 'aged out'
    d4 = {'type': 'folder', 'path': f'{W}/dest-e4'}
    c4 = cfg('e4', dest=d4, state=f'{W}/state-e4'); r41 = [window(c4, Wk(k)) for k in (3, 2)]
    c4f = cfg('e4f', dest=d4, state=f'{W}/state-e4', max_window_age_hours=1, final_after_hours=2, statement_timeout='1s')
    pass1 = files(man('e4', Wk(2)), 'table_sizes')
    policy('table_sizes', 'pqproof.slow(3)', RD)
    try: r42 = export(c4f)
    finally: unpolicy('table_sizes')
    gone = man('e4', Wk(3)) is None
    r43 = export(c4f); m43 = man('e4', Wk(3))
    check(all(r[0] == 0 for r in r41) and r42[0] == 1 and gone and r43[0] == 0 and m43 is not None and m43['pass'] == 'final' and not sums_hold('e4', m43)
          and entry(m43, 'table_sizes') is not None and '-from' not in r43[2],
          f'E: a final pass that failed on a window before the reach is done again by the next run, not called aged out (first passes rc {[r[0] for r in r41]}, the failing run rc {r42[0]}, no manifest then {gone}, the next run rc {r43[0]}, pass {m43 and m43["pass"]}: {r43[2].strip()[-160:]})')
    # W2's final pass gives table_sizes up on its third failed run: its pass-1 file stays, listed with a note
    c4g = cfg('e4g', dest=d4, state=f'{W}/state-e4', max_window_age_hours=1, final_after_hours=1, statement_timeout='1s')
    policy('table_sizes', 'pqproof.slow(3)', RD)
    try:
        for _ in range(3): r44 = export(c4g)
    finally: unpolicy('table_sizes')
    m44 = man('e4', Wk(2)); e44 = entry(m44, 'table_sizes') or {}
    check(m44 is not None and m44['pass'] == 'final' and [x['table'] for x in m44.get('failed') or []] == ['table_sizes'] and pass1
          and files(m44, 'table_sizes') == pass1 and 'earlier pass' in (e44.get('note') or '') and not sums_hold('e4', m44),
          f'E: a table a final pass gives up keeps its pass-1 file, listed with a note (pass1 {pass1}, now {files(m44, "table_sizes")}, note {e44.get("note")!r}, failed {m44 and m44.get("failed")})')

def row_F():
    w = Wk(2); c = cfg('f'); ct = cfg('ft', carry=['text'])
    r1 = window(c, w); r2 = window(ct, w); m = man('f', w); mt = man('ft', w)
    if not check(r1[0] == 0 and r2[0] == 0, f'F: W2 exports without and with carry text (rc {r1[0]}, {r2[0]}: {(r1[2] + r2[2]).strip()[:200]})'): return
    s = skipped(m, 'ui_users')
    check(s is not None and entry(m, 'ui_users') is None and not os.path.isdir(f'{root("f")}/ui_users'), f'F: ui_users has no file and is in skipped ({s})')
    dc = lambda mm, t: sorted(x['column'] for x in mm.get('dropped_columns', []) if x['table'] == t)
    sends = [r for r in rows('f', m, 'report_mail_sends') if r['name'] == 'f-send']
    check(len(sends) == 1 and not ({'html', 'xlsx', 'recipients', 'subject', 'error', 'requested_by', 'client'} & set(sends[0]))
          and dc(m, 'report_mail_sends') == ['client', 'error', 'html', 'recipients', 'requested_by', 'subject', 'xlsx'],
          f'F: report_mail_sends carried without its mail columns, the server\'s reply, and who asked from where, each named ({dc(m, "report_mail_sends")})')
    ca = cfg('fa', carry=['audit']); ra = window(ca, w); ma = man('fa', w) or {}
    sa = [r for r in rows('fa', ma, 'report_mail_sends') if r['name'] == 'f-send']
    check(ra[0] == 0 and len(sa) == 1 and sa[0].get('requested_by') == 'proof' and 'error' not in sa[0] and dc(ma, 'report_mail_sends') == ['error', 'html', 'recipients', 'subject', 'xlsx'],
          f'F: with carry audit who asked is carried; the mail columns and the reply never ({dc(ma, "report_mail_sends") if ma else None}: {ra[2].strip()[:120]})')
    lf = {r['event_key']: r for r in rows('f', m, 'log_events') if r['instance_id'] == I1}; la = {r['event_key'] for r in rows('fa', ma, 'log_events') if r['instance_id'] == I1}
    fr = next((x for x in (m.get('filtered_rows') or []) if x['table'] == 'log_events'), None)
    check(set(lf) == {'f-slow'} and 'statement' not in lf['f-slow'] and fr is not None and 'audit' in fr['reason'] and la == {'f-auth', 'f-slow'} and not (ma.get('filtered_rows') or []),
          f'F: without audit a failed sign-in of the server log is not carried and the manifest says so; with it it is (no carry {sorted(lf)}, audit {sorted(la)}, {fr})')
    pa = [r for r in rows('fa', ma, 'pgaudit_events') if r['event_key'] == 'f-aud']
    check(skipped(m, 'pgaudit_events') is not None and len(pa) == 1 and 'statement' not in pa[0] and 'parameters' not in pa[0] and pa[0]['command'] == 'SELECT'
          and dc(ma, 'pgaudit_events') == ['parameters', 'statement'],
          f'F: under carry audit alone an audit trail is carried without its statement and parameters, both named ({dc(ma, "pgaudit_events") if ma else None})')
    e1 = [r for r in rows('f', m, 'mssql_errorlog') if r['line_key'] == 'f-1']
    try: el = rows('ft', mt, 'mssql_errorlog'); elerr = ''
    except Exception as e: el = []; elerr = f'{type(e).__name__}: {str(e)[:200]}'
    e2 = [r for r in el if r['line_key'] == 'f-1']; big = [r for r in el if r['line_key'] == 'f-big']
    reason = next((x.get('reason', '') for x in m.get('dropped_columns', []) if x['table'] == 'mssql_errorlog' and x['column'] == 'message'), '')
    check(len(e1) == 1 and 'message' not in e1[0] and 'text' in reason, f'F: the log\'s text column is dropped without carry text and named ({reason!r})')
    check(len(e2) == 1 and e2[0].get('message') == 'f secret text' and 'message' not in dc(mt, 'mssql_errorlog') and dc(mt, 'report_mail_sends') == ['client', 'error', 'html', 'recipients', 'requested_by', 'subject', 'xlsx'],
          f'F: with carry text the text column is carried; the mail columns stay dropped {elerr}')
    check(len(big) == 1 and len(big[0].get('message') or '') == 9000000, f'F: a text value of 9 MB reads back whole ({len(big)} row, {len((big[0].get("message") or "")) if big else 0} characters) {elerr}')
    cx = cfg('fx', tables={'exclude': ['host_sample']}); r3 = window(cx, w); mx = man('fx', w); sx = skipped(mx, 'host_sample')
    check(r3[0] == 0 and sx and 'exclude' in sx['reason'] and entry(mx, 'host_sample') is None and entry(mx, 'database_sizes') is not None,
          f'F: a table named in tables.exclude is skipped naming the key, the others carried ({sx})')
    rb = window(cfg('fbad', tables={'exclude': ['host_sampel']}), w); ri = window(cfg('finst', tables={'exclude': ['instances']}), w)
    check(rb[0] == 3 and 'host_sampel' in rb[2] and ri[0] == 3 and 'instances' in ri[2] and not tree(f'{W}/dest-fbad') and not tree(f'{W}/dest-finst'),
          f'F: a name in tables.exclude that is no table, and instances, are refused before anything is written (rc {rb[0]}, {ri[0]}: {rb[2].strip()[:100]})')

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
    cf = cfg('g', carry=['text']); cs = cfg('gs', carry=['text'], dest={'type': 's3', 'bucket': 'pq-proof', 'prefix': 'px', 'region': 'us-east-1', 'endpoint': s3url})
    ca = cfg('ga', carry=['text'], dest={'type': 'azure_blob', 'container': 'pq-proof', 'prefix': 'px', 'connection_string': 'env:PQ_AZ_CONN'})
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
    nrows = q('SELECT count(*) FROM pgvigil.export_runs')[0][0]; codes = []
    for sql in (f"SELECT pgvigil.export_run_record('{NAME}', 'x', now() - interval '2 hours', now() - interval '1 hour', '1', now(), 'ok', 0, 0, 0, 0, NULL)",
                f"SELECT pgvigil.export_off('{NAME}')"):
        try: conn(RD, PW, DB).run(sql); codes.append('ran')
        except Exception as e: codes.append((e.args[0] if e.args and isinstance(e.args[0], dict) else {}).get('C', str(e)[:40]))
    check(codes == ['42501', '42501'] and q('SELECT count(*) FROM pgvigil.export_runs')[0][0] == nrows and q('SELECT count(*) FROM pgvigil.export_state')[0][0] == 1,
          f'H: a reader login that is no exporter is refused by both doors (42501) and writes nothing ({codes})')
    try: conn(ex, PW, DB).run(f"SELECT pgvigil.export_run_record('{NAME}', 'x', now(), 'infinity', '1', now(), 'ok', 0, 0, 0, 0, NULL)"); oob = 'ran'
    except Exception as e: oob = (e.args[0] if e.args and isinstance(e.args[0], dict) else {}).get('C', str(e)[:40])
    check(oob == '22023', f'H: the door refuses a row out of bounds (a window that ends at infinity: {oob})')
    port = free_port()
    p = subprocess.Popen([BIN, 'serve', '-config', c, '-dsn', 'env:PGVIGIL_REPO_DSN', '-listen', f'127.0.0.1:{port}', '-no-login'], env=dict(ENV0, PGVIGIL_EXPORT_DSN=xd), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        api = None
        for _ in range(60):
            try: api = json.load(urllib.request.urlopen(f'http://127.0.0.1:{port}/api/export', timeout=5)); break
            except Exception: time.sleep(0.5)
        t = (api or {}).get('runs') or {}
        check(api is not None and 'outcome' in t.get('columns', []) and len(t.get('rows', [])) == 2, f'H: GET /api/export lists the runs ({len(t.get("rows", []))} rows)')
        # a repository that has no export record yet (an older schema): the page's read answers nothing, not an error
        q('ALTER TABLE pgvigil.export_runs RENAME TO export_runs_aside')
        try:
            old = None; code = 0
            try: old = json.load(urllib.request.urlopen(f'http://127.0.0.1:{port}/api/export', timeout=5)); code = 200
            except Exception as e: code = getattr(e, 'code', -1)
        finally:
            q('ALTER TABLE pgvigil.export_runs_aside RENAME TO export_runs')
        check(code == 200 and not (old or {}).get('runs'), f'H: on a repository without the export record GET /api/export answers 200 and no runs (status {code}, {old})')
    finally:
        p.kill(); p.wait()
    svc = lambda: [r[0] for r in q('SELECT detail FROM pgvigil.export_service')]
    check(svc() == [], f'H: no service row while the export is current ({svc()})')
    open(f'{W}/notadir', 'w').write('x'); cb = cfg('hb', dest={'type': 'folder', 'path': f'{W}/notadir/x'}, state=f'{W}/state-h', max_window_age_hours=2)
    rcb, _, errb = export(cb, dsn_=xd)
    lastrun = q("SELECT outcome, error FROM pgvigil.export_runs ORDER BY started_at DESC, run_id DESC LIMIT 1")[0]
    check(rcb == 1 and lastrun[0] == 'failed' and lastrun[1] and any('failed' in d for d in svc()), f'H: a run whose destination does not answer is a row with its error and the service row names it (rc {rcb}, {lastrun[0]}, {svc()})')
    rco2, _, _ = window(c, Wk(2), dsn_=xd); still = svc()
    rc2, _, _ = window(c, Wk(1), dsn_=xd); cleared = svc()
    check(rco2 == 0 and any('failed' in d for d in still) and rc2 == 0 and cleared == [],
          f'H: a window whose last attempt failed keeps the line while another window succeeds, and loses it when it is exported ({still}, then {cleared})')
    q("UPDATE pgvigil.export_runs SET window_from = window_from - interval '4 hours', window_to = window_to - interval '4 hours', started_at = started_at - interval '4 hours', finished_at = finished_at - interval '4 hours'")
    q("UPDATE pgvigil.export_state SET last_run_at = last_run_at - interval '4 hours', newest_window_to = newest_window_to - interval '4 hours'")
    check(rc2 == 0 and any('behind' in d for d in svc()), f'H: four hours behind is a service row ({svc()})')
    rco, _, erro = export(c, '-off', dsn_=xd)
    check(rco == 0 and q('SELECT count(*) FROM pgvigil.export_state')[0][0] == 0 and svc() == [] and q('SELECT count(*) FROM pgvigil.export_runs')[0][0] == 0,
          f'H: after -off no export_state row, no runs and no service row (rc {rco}: {erro.strip()[:120]})')

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
    # W6 has its first pass and ended before the reach: its final pass is still owed; the two accepted holes are final
    mkj = lambda w: os.path.exists(f'{root("j")}/_manifests/_final/{NAME}__{stamp(w[0])}__{stamp(w[1])}')
    cf = cfg('jf', dest={'type': 'folder', 'path': f'{W}/dest-j'}, state=f'{W}/state-j', max_window_age_hours=3, final_after_hours=4)
    rf = export(cf); m6 = man('j', w6); g5b = man('j', Wk(5))
    check(rf[0] == 0 and m6 and m6['pass'] == 'final' and mkj(w6) and (man('j', Wk(3)) or {}).get('pass') == 1 and g5b and g5b.get('gap') is True and mkj(Wk(5)),
          f'J: a window past the reach that has its first pass still gets its final pass; an accepted hole stays a hole (rc {rf[0]}, W6 pass {m6 and m6["pass"]}, marker {mkj(w6)}, the hole still a gap {bool(g5b and g5b.get("gap"))}: {rf[2].strip()[:120]})')
    before = tree(root('j')); rgf = export(c, '-gap', iso(H0 - HR), iso(H0 + 3 * HR))
    check(rgf[0] != 0 and 'aged out' in rgf[2] and tree(root('j')) == before, f'J: -gap over hours that are not aged out is refused and writes nothing (rc {rgf[0]}: {rgf[2].strip()[:140]})')
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
