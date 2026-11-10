#!/usr/bin/env bash
# Proof of the tab export (task 54): a demo fleet is seeded into a throwaway database and served on loopback, a
# headless Chromium opens the fleet Summary and one instance's Tables tab, presses the bar's 'Export .xlsx' and
# 'Export CSV' on each and saves what downloads; each file is read back with unzip and python3's zipfile and csv
# (no spreadsheet library) and graded against the page it came from. Needs go, psql, chromium, node, unzip and
# python3, the web bundle built with the export wired into the bar (internal/web/dist/app.js carries 'Export .xlsx':
# `cd web && npm run build` after the wiring in main.ts), and a PostgreSQL for the throwaway database:
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a login that may create a database
#   PGVIGIL_EXPORT_OUT a folder to keep the downloads in (default: removed with the proof's temporary folder)
# Expected:
#   names      fleet_Summary_<yyyymmdd-hhmm>_<yyyymmdd-hhmm>.xlsx and .csv; <instance>_Tables_<from>_<to>.xlsx and
#              .csv.zip (the Tables tab has two grids), the instance named as in the tree
#   summary    sheets: Summary first, then one per grid named by the heading above it ('Summary' repeated is
#              'Summary (2)'); every data sheet: a frozen pane (ySplit 1, state frozen) and an autoFilter over its
#              rows; styles.xml carries a solid fill in each status colour the Summary grid shows on screen
#              (ok FFE3F4E6, warn FFFFF1D6, crit FFFDE2E2, 'no sample' FFEEF1F5) and a cell of that sheet is
#              styled with it; each sheet's data rows = the grid's rows on screen
#   tables     sheets: Summary, Tables, Biggest tables (the screen's headings); a numeric cell (<v>, no t=) styled
#              with a number format (numFmtId 165 bytes, '#,##0" B"'), a time cell with 168 and a count with 3
#   csv        the Summary's .csv: its data rows (python csv, header excluded) = the grid's rows; the Tables
#              .csv.zip: two CSVs, each with its grid's row count; a UTF-8 BOM first
#   libre      when soffice is on the machine, each .xlsx converts to CSV headless (the file opens); none = said
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_export_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in go chromium node psql unzip python3 curl; do command -v $t >/dev/null || fail "$t is not on this machine"; done
grep -q 'Export .xlsx' internal/web/dist/app.js || fail "the web bundle has no export button: wire exportButtons into the bar (main.ts) and run 'npm run build' in web/"

echo "== build and seed the demo into $DB, serve on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
"$WORK/pgvigil" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 240); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { cat "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in 240 s"; }

echo "== a headless Chromium on CDP $CDP"
mkdir -p "$WORK/dl"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"

# the driver: open a page, count each grid's rows and read the headings, press a button, wait for the download
cat > "$WORK/drive.mjs" <<'JS'
const [port, U, dl] = process.argv.slice(2);
const fs = await import('node:fs');
const inst = await (await fetch(U + 'api/instances')).json();
const rows = inst.rows.map(r => Object.fromEntries(inst.columns.map((c, i) => [c, r[i]])));
const one = rows.find(r => r.platform === 'onprem') ?? rows[0];
const ver = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
const bws = new WebSocket(ver.webSocketDebuggerUrl);
await new Promise(r => bws.addEventListener('open', r));
bws.send(JSON.stringify({ id: 1, method: 'Browser.setDownloadBehavior', params: { behavior: 'allow', downloadPath: dl } }));
await new Promise(r => bws.addEventListener('message', r));
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const settled = async () => {
  for (const t = Date.now(); Date.now() - t < 15000; await sleep(150)) {
    if (await ev(`(() => { const m = document.querySelector('main'); const e = m && m.querySelector('p.empty'); return !!m && m.children.length > 0 && !(e && /^Loading/.test(e.textContent)) && !!document.querySelector('#bar .export'); })()`)) { await sleep(400); return true; }
  }
  return false;
};
const fresh = (before, exts) => fs.readdirSync(dl).filter(f => exts.some(e => f.endsWith(e)) && !before.includes(f));
const press = async (label, exts) => {
  const before = fs.readdirSync(dl);
  const hit = await ev(`(() => { const b = [...document.querySelectorAll('#bar .export button')].find(x => x.textContent === ${JSON.stringify(label)}); if (!b) return false; b.click(); return true; })()`);
  if (!hit) throw new Error('no button ' + label);
  for (const t = Date.now(); Date.now() - t < 15000; await sleep(200)) {
    const f = fresh(before, exts);
    if (f.length && !fs.readdirSync(dl).some(x => x.endsWith('.crdownload'))) return f[0];
  }
  throw new Error(`no ${exts.join(' or ')} downloaded after ${label}: ` + await ev(`document.querySelector('#bar .export [role=status]').textContent`));
};
const page = async (hash) => {
  await cmd('Page.navigate', { url: U + hash }); await sleep(300);
  if (!await settled()) throw new Error('page did not render: ' + hash);
  const grids = await ev(`[...document.querySelectorAll('main h2, main h3, main table.grid, main table.props')].map(e => e.tagName === 'TABLE' ? { rows: e.querySelectorAll(e.classList.contains('grid') ? 'tbody tr' : 'tr').length, status: [...new Set([...e.querySelectorAll('td.status, td .badge, td .dot')].map(x => ['crit','warn','ok','none'].find(k => x.classList.contains(k))).filter(Boolean))] } : { h: e.textContent.trim() })`);
  return { hash, grids, xlsx: await press('Export .xlsx', ['.xlsx']), csv: await press('Export CSV', ['.csv', '.csv.zip']) };
};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
const out = { instance: one.name };
out.summary = await page('#/summary');
out.tables = await page(`#/tables?i=${one.instance_id}`);
console.log(JSON.stringify(out));
process.exit(0);
JS
echo "== the downloads"
node "$WORK/drive.mjs" "$CDP" "http://127.0.0.1:$PORT/" "$WORK/dl" > "$WORK/drive.json" || fail "the driver failed"
ls -1 "$WORK/dl"
ok "downloaded: $(cd "$WORK/dl" && ls | tr '\n' ' ')"

echo "== the files read back"
python3 -I - "$WORK/drive.json" "$WORK/dl" <<'PY' || fail "a file did not match its page"
import csv, io, json, re, sys, zipfile
d = json.load(open(sys.argv[1])); dl = sys.argv[2]
bad = 0
def check(cond, msg):
    global bad
    print(('ok   ' if cond else 'FAIL ') + msg)
    if not cond: bad += 1
fill = {'ok': 'FFE3F4E6', 'warn': 'FFFFF1D6', 'crit': 'FFFDE2E2', 'none': 'FFEEF1F5'}
def sheets_of(z):
    wb = z.read('xl/workbook.xml').decode()
    return [n.replace('&amp;', '&') for n in re.findall(r'<sheet name="([^"]*)"', wb)]
def xfs(z):
    st = z.read('xl/styles.xml').decode()
    fills = re.findall(r'<fill>(.*?)</fill>', re.search(r'<fills[^>]*>(.*?)</fills>', st).group(1))
    cx = re.findall(r'<xf ([^>]*)/>', re.search(r'<cellXfs[^>]*>(.*?)</cellXfs>', st).group(1))
    out = []
    for a in cx:
        g = lambda k: int(re.search(k + r'="(\d+)"', a).group(1))
        f = re.search(r'rgb="(\w+)"', fills[g('fillId')])
        out.append({'fmt': g('numFmtId'), 'fill': f.group(1) if f else None})
    return st, out
def grids(page):
    head, out = '', []
    for g in page['grids']:
        if 'h' in g: head = g['h']
        else: out.append(dict(g, name=head))
    return out
def sheet_rows(z, i):
    x = z.read(f'xl/worksheets/sheet{i}.xml').decode()
    return x, len(re.findall(r'<row r="', x)) - 1
def stamp(n, inst, tab, ext):
    return re.fullmatch(re.escape(inst) + '_' + re.escape(tab) + r'_\d{8}-\d{4}_\d{8}-\d{4}' + re.escape(ext), n) is not None

for key, tab, inst in (('summary', 'Summary', 'fleet'), ('tables', 'Tables', re.sub(r'[^A-Za-z0-9._-]+', '-', d['instance']))):
    p = d[key]; gs = grids(p)
    check(stamp(p['xlsx'], inst, tab, '.xlsx'), f"{key}: the workbook's name {p['xlsx']}")
    z = zipfile.ZipFile(f"{dl}/{p['xlsx']}")
    names = sheets_of(z)
    check(names[0] == 'Summary' and len(names) == len(gs) + 1, f"{key}: sheets {names} = Summary + {len(gs)} grid(s)")
    st, cx = xfs(z)
    for i, g in enumerate(gs):
        x, n = sheet_rows(z, i + 2)
        check('state="frozen"' in x and 'ySplit="1"' in x and '<autoFilter ref="A1:' in x, f"{key}: sheet '{names[i + 1]}' frozen header and filter")
        check(n == g['rows'], f"{key}: sheet '{names[i + 1]}' {n} data rows = {g['rows']} on screen")
        for s in g.get('status', []):
            used = {int(v) for v in re.findall(r' s="(\d+)"', x)}
            check(any(cx[u]['fill'] == fill[s] for u in used if u < len(cx)), f"{key}: '{s}' cells filled {fill[s]} in '{names[i + 1]}'")
    if key == 'tables':
        check(names[1:] == [g['name'] for g in gs], f"tables: sheet names {names[1:]} = the screen's headings {[g['name'] for g in gs]}")
        x = ''.join(z.read(f'xl/worksheets/sheet{i + 2}.xml').decode() for i in range(len(gs)))
        nums = {int(s) for s in re.findall(r'<c r="[A-Z]+\d+" s="(\d+)"><v>', x)}
        for f, what in ((165, 'bytes'), (168, 'a time'), (3, 'a count')):
            check(any(cx[s]['fmt'] == f for s in nums), f"tables: a numeric cell with numFmt {f} ({what})")
        check('numFmtId="165" formatCode="#,##0&quot; B&quot;"' in st, "tables: numFmt 165 is '#,##0\" B\"'")
    if key == 'summary':
        check(any(cx[s]['fill'] in fill.values() for s in range(len(cx))), "summary: a status fill in styles.xml")
    # CSV
    if p['csv'].endswith('.csv.zip'):
        cz = zipfile.ZipFile(f"{dl}/{p['csv']}")
        parts = sorted(cz.namelist())
        check(len(parts) == len(gs), f"{key}: {len(parts)} CSV(s) in {p['csv']} = {len(gs)} grid(s)")
        blobs = [cz.read(n) for n in parts]
    else:
        check(len(gs) == 1, f"{key}: one grid, one .csv")
        blobs = [open(f"{dl}/{p['csv']}", 'rb').read()]
    check(stamp(p['csv'], inst, tab, '.csv.zip' if p['csv'].endswith('.zip') else '.csv'), f"{key}: the CSV's name {p['csv']}")
    for b, g in zip(blobs, gs):
        check(b.startswith(b'\xef\xbb\xbf'), f"{key}: CSV '{g['name']}' starts with a UTF-8 BOM")
        n = len(list(csv.reader(io.StringIO(b.decode('utf-8-sig'))))) - 1
        check(n == g['rows'], f"{key}: CSV '{g['name']}' {n} data rows = {g['rows']} on screen")
sys.exit(1 if bad else 0)
PY

if command -v soffice >/dev/null; then
  for f in "$WORK"/dl/*.xlsx; do
    (cd "$WORK" && timeout 120 soffice --headless -env:UserInstallation=file://$WORK/lo --convert-to csv --outdir "$WORK/lo-out" "$f" >/dev/null 2>&1) || fail "LibreOffice could not open $(basename "$f")"
    [[ -s "$WORK/lo-out/$(basename "${f%.xlsx}").csv" ]] || fail "LibreOffice wrote nothing for $(basename "$f")"
    ok "LibreOffice opens $(basename "$f")"
  done
else
  echo "not checked: soffice is not on this machine (the file opening in a spreadsheet program)"
fi
[[ -n "${PGVIGIL_EXPORT_OUT:-}" ]] && { mkdir -p "$PGVIGIL_EXPORT_OUT"; cp "$WORK"/dl/* "$PGVIGIL_EXPORT_OUT"/; echo "kept in $PGVIGIL_EXPORT_OUT"; }
echo "OK: the Summary and the Tables tab exported to .xlsx and CSV, each file matching its page"
