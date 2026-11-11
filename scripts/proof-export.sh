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
#              (DBA Dash's: ok FF006638, warn FFE49325, crit FFAB1F26, 'no sample' FFE0E1E9) and a cell of that sheet is
#              styled with it; each sheet's data rows = the grid's rows on screen
#   tables     sheets: Summary, Tables, Biggest tables (the screen's headings); Biggest tables sorted by 'total'
#              on screen first (the click changes the order), its sheet's 'table' column in the screen's order and
#              every 'total' and 'live rows' still a number
#              (a page model out of step with the sort turns them to text); a numeric cell (<v>, no t=) styled
#              with a number format (numFmtId 165 bytes, '#,##0" B"'), a time cell with 168 and a count with 3
#   roles      the instance's Roles tab: the privilege grids sit under h4 headings; every sheet's name follows the
#              heading above its grid (no 'Memberships (2)' for 'Database privileges')
#   activity   the instance's Running queries tab over 7 days: Per sample shows 500 rows; the Summary sheet's row for it
#              carries 'the newest 500 of N samples'; every workbook's Summary sheet has a Time zone row ('<zone> (UTC+hh:mm at export)')
#   slow       the fleet's Slow queries tab (24 h): the hand-built Per day table's statements column numeric, a
#              duration cell with numFmt 170 ('#,##0.###" ms"'); on EVERY page no 'x ms / x s / x min' text is left in
#              any sheet (each tab rounds its milliseconds its own way)
#   db         a database's drill page: its statements grid's millisecond column holds a value under 1 ms and one
#              at 1,000 ms or more, both numbers with numFmt 170
#   csv        the Summary's .csv: its data rows (python csv, header excluded) = the grid's rows; the Tables
#              .csv.zip: two CSVs, each with its grid's row count; a UTF-8 BOM first
#   libre      when soffice is on the machine, each .xlsx converts to CSV headless (the file opens); none = said
#   languages  all of the above twice: Chromium in en-US and in fr-FR (navigator.language says so; 1234567 shows
#              without a comma: the locale's grouping space), the numbers numeric in both
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
const page = async (hash, sortBy) => {
  await cmd('Page.navigate', { url: U + hash }); await sleep(300);
  if (!await settled()) throw new Error('page did not render: ' + hash);
  let order = null, before = null;
  if (sortBy) {
    // sort the page's last grid by a column (one click: ascending), so the export must follow the screen's order; the
    // order before the click is kept too: the check needs the click to have changed it
    const col = `(() => { const t = [...document.querySelectorAll('main table.grid')].pop(); const hs = [...t.querySelectorAll('thead th')];
      const j = hs.findIndex(h => h.textContent === ${JSON.stringify(sortBy[1])});
      return [...t.querySelectorAll('tbody tr')].map(tr => tr.children[j].textContent.trim()); })()`;
    before = await ev(col);
    await ev(`[...[...document.querySelectorAll('main table.grid')].pop().querySelectorAll('thead th')].find(h => h.textContent === ${JSON.stringify(sortBy[0])}).click()`);
    await sleep(200);
    order = await ev(col);
  }
  const grids = await ev(`[...document.querySelectorAll('main h2, main h3, main h4, main table.grid, main table.props')].map(e => e.tagName === 'TABLE' ? { rows: e.dataset.rows ? Number(e.dataset.rows) : e.querySelectorAll(e.classList.contains('grid') ? 'tbody tr' : 'tr').length, status: [...new Set([...e.querySelectorAll('td.status, td .badge, td .dot')].map(x => ['crit','warn','ok','none'].find(k => x.classList.contains(k))).filter(Boolean))] } : { h: (c => (c.querySelectorAll('.whatis').forEach(b => b.remove()), c.textContent.trim()))(e.cloneNode(true)) })`);   // a heading without its 'what is this' button, as the export names a sheet
  return { hash, grids, order, before, xlsx: await press('Export .xlsx', ['.xlsx']), csv: await press('Export CSV', ['.csv', '.csv.zip']) };
};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
const out = { instance: one.name, lang: await ev('navigator.language'), sample: await ev('(1234567).toLocaleString()') };
out.summary = await page('#/summary');
out.tables = await page(`#/tables?i=${one.instance_id}`, ['total', 'table']);
// the Roles tab: grids under h4 headings (the privilege grids)
out.roles = await page(`#/roles?i=${one.instance_id}`);
// the Running queries tab over 7 days: more than 500 samples, so the page says 'the newest 500 of N'
out.activity = await page(`#/activity?i=${one.instance_id}&w=7d`);
// the fleet's Slow queries tab over 24 h: the Per day table is hand-built (no page model), the durations are 'x ms / s / min'
out.slow = await page('#/slowqueries?w=24h');
// a database's drill page (the Database info tab's first database link): its statements grid rounds to 0.1 ms, with
// sub-millisecond, fractional and 1,000+ ms values in one column
await cmd('Page.navigate', { url: U + `#/dbinfo?i=${one.instance_id}` }); await sleep(300);
if (!await settled()) throw new Error('the Database info tab did not render');
const dbHref = await ev(`(document.querySelector('main a[href*="#/db?"]') || {}).getAttribute?.('href') ?? null`);
if (!dbHref) throw new Error('no database link on the Database info tab');
out.db = await page(dbHref);
console.log(JSON.stringify(out));
process.exit(0);
JS
cat > "$WORK/check.py" <<'PY'
import csv, io, json, re, sys, zipfile
d = json.load(open(sys.argv[1])); dl = sys.argv[2]; want = sys.argv[3]
bad = 0
def check(cond, msg):
    global bad
    print(('ok   ' if cond else 'FAIL ') + msg)
    if not cond: bad += 1
fill = {'ok': 'FF006638', 'warn': 'FFE49325', 'crit': 'FFAB1F26', 'none': 'FFE0E1E9'}
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

print(f"     browser language {d['lang']}, 1234567 shown as {d['sample']!r}")
check(d['lang'].lower().startswith(want[:2].lower()), f"the browser runs in {want}")
if want.startswith('fr'):
    check(',' not in d['sample'], "the fr-FR grouping is not a comma (the locale took)")
iname = re.sub(r'[^A-Za-z0-9._-]+', '-', d['instance'])
for key, tab, inst in (('summary', 'Summary', 'fleet'), ('tables', 'Tables', iname), ('roles', 'Roles', iname), ('activity', 'Running-queries', iname), ('slow', 'Slow-queries', 'fleet'), ('db', 'Database', iname)):
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
    # each sheet named by the heading above its grid (h2, h3 or h4): the name starts with the heading's first words
    # (cut at 31 characters, a repeat numbered; the Summary grid's heading meets the export's own Summary sheet)
    hs = [re.sub(r'[\\/?*\[\]:]', ' ', g['name']).strip()[:24].rstrip() for g in gs]
    check(all(n.startswith(h) for n, h in zip(names[1:], hs)), f"{key}: sheet names {names[1:]} follow the screen's headings {[g['name'] for g in gs]}")
    if key == 'roles':
        check(any(g['name'].endswith('privileges') or 'privileges' in g['name'] for g in gs), "roles: a grid under a privileges (h4) heading on screen")
    if key == 'tables':
        check(names[1:] == [g['name'] for g in gs], f"tables: sheet names {names[1:]} = the screen's headings {[g['name'] for g in gs]}")
        x = ''.join(z.read(f'xl/worksheets/sheet{i + 2}.xml').decode() for i in range(len(gs)))
        nums = {int(s) for s in re.findall(r'<c r="[A-Z]+\d+" s="(\d+)"><v>', x)}
        for f, what in ((165, 'bytes'), (168, 'a time'), (3, 'a count')):
            check(any(cx[s]['fmt'] == f for s in nums), f"tables: a numeric cell with numFmt {f} ({what})")
        check('numFmtId="165" formatCode="#,##0&quot; B&quot;"' in st, "tables: numFmt 165 is '#,##0\" B\"'")
        last = z.read(f'xl/worksheets/sheet{len(gs) + 1}.xml').decode()
        col = re.findall(r'<c r="D(\d+)"[^>]*t="inlineStr"><is><t xml:space="preserve">([^<]*)</t>', last)
        got = [t.replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>').replace('&quot;', '"') for r, t in col if r != '1']
        check(p['order'] != p['before'], "tables: the click changed the grid's order on screen")
        check(p['order'] and got == p['order'], f"tables: 'Biggest tables' sorted by total on screen, the sheet's table column in the same order ({len(got)} rows)")
        # the raw values must follow the sort too: a model out of step pairs a row's text with another row's value,
        # and the cell falls back to text; every 'total' (E, bytes) and 'live rows' (I, counts in the millions: the
        # locale's grouping) of the sorted sheet stays a number
        for c, what in (('E', 'total'), ('I', 'live rows')):
            cells = re.findall(r'<c r="' + c + r'(\d+)"[^>]*?(/>|><v>|t="inlineStr")', last)
            numeric = [r for r, k in cells if r != '1' and k == '><v>']
            check(len(got) > 1 and len(numeric) == len(got), f"tables: the sorted sheet's {what} column: {len(numeric)} of {len(got)} rows numeric")
    if key == 'summary':
        check(any(cx[s]['fill'] in fill.values() for s in range(len(cx))), "summary: a status fill in styles.xml")
    first = z.read('xl/worksheets/sheet1.xml').decode()
    check('>Time zone<' in first and re.search(r'\(UTC[-+]\d\d:\d\d at export\)', first) is not None, f"{key}: the Summary sheet has a Time zone row with the offset at export")
    if key == 'activity':
        i = next((i for i, g in enumerate(gs) if g['name'] == 'Per sample'), None)
        check(i is not None and gs[i]['rows'] == 500, f"activity: the Per sample grid shows 500 rows on screen ({gs[i]['rows'] if i is not None else 'no grid'})")
        row = re.search(r'<row r="\d+"><c [^>]*><is><t[^>]*>Per sample</t></is></c><c [^>]*><v>(\d+)</v></c><c [^>]*><is><t[^>]*>([^<]*)</t>', first)
        check(row is not None and row.group(1) == '500' and re.search(r'newest 500 of [\d,.\s\u202f\u00a0]*\d', row.group(2)) is not None, f"activity: the Summary's Per sample row carries the 'newest 500 of N' note ({row.group(2)[:60] if row else 'none'})")
    if key == 'slow':
        i = next((i for i, g in enumerate(gs) if g['name'].startswith('Per day')), None)
        check(i is not None and gs[i]['rows'] >= 1, f"slow: a Per day table with rows on screen ({gs[i]['rows'] if i is not None else 'no grid'})")
        if i is not None:
            x = z.read(f'xl/worksheets/sheet{i + 2}.xml').decode()
            cnt = re.findall(r'<c r="C(\d+)"[^>]*?(/>|><v>|t="inlineStr")', x)
            numeric = [r for r, k in cnt if r != '1' and k == '><v>']
            check(len(numeric) == gs[i]['rows'], f"slow: Per day's statements column (no page model): {len(numeric)} of {gs[i]['rows']} rows numeric")
    # every page: a duration ('x ms', 'x s', 'x min') is never left as text in any sheet, whichever tab's formatter wrote it
    allx = ''.join(z.read(f'xl/worksheets/sheet{j + 2}.xml').decode() for j in range(len(gs)))
    texts = [t for t in re.findall(r't="inlineStr"><is><t[^>]*>([^<]*)</t>', allx) if re.fullmatch(r'[\d\s,.\u202f\u00a0]+ (ms|s|min)', t)]
    check(not texts, f"{key}: no duration left as text ({texts[:3]})")
    if key in ('slow', 'db'):
        nums = {int(s) for s in re.findall(r'<c r="[A-Z]+\d+" s="(\d+)"><v>', allx)}
        check(any(cx[s]['fmt'] == 170 for s in nums), f"{key}: a duration cell with numFmt 170 (ms)")
        check('numFmtId="170" formatCode="#,##0.###&quot; ms&quot;"' in st, f"{key}: numFmt 170 is '#,##0.###\" ms\"'")
    if key == 'db':
        # the statements grid: a column whose cells carry numFmt 170 holds a value under 1 ms and one at 1,000 ms or more
        vals = [float(v) for sid, v in re.findall(r'<c r="[A-Z]+\d+" s="(\d+)"><v>([^<]*)</v>', allx) if cx[int(sid)]['fmt'] == 170]
        check(any(v < 1 for v in vals) and any(v >= 1000 for v in vals), f"db: millisecond values under 1 ms and from 1,000 ms up are both numbers ({len(vals)} cells, min {min(vals) if vals else '-'}, max {max(vals) if vals else '-'})")
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

# each language: its own Chromium (the page's locale is the browser's), its own downloads, the same checks
for L in en-US fr-FR; do
  echo "== a headless Chromium in $L on CDP $CDP"
  [[ -n "$CHR" ]] && { kill "$CHR" 2>/dev/null || true; wait "$CHR" 2>/dev/null || true; CHR=""; }
  DL="$WORK/dl-$L"; mkdir -p "$DL"
  LANGUAGE=${L/-/_} LC_ALL=${L/-/_}.UTF-8 chromium --headless=new --lang=$L --accept-lang=$L --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome-$L" --no-first-run --disable-gpu about:blank > "$WORK/chrome-$L.log" 2>&1 &
  CHR=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
  curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
  echo "== the downloads ($L)"
  node "$WORK/drive.mjs" "$CDP" "http://127.0.0.1:$PORT/" "$DL" > "$WORK/drive-$L.json" || fail "the driver failed ($L)"
  ok "downloaded ($L): $(cd "$DL" && ls | tr '\n' ' ')"
  echo "== the files read back ($L)"
  python3 -I "$WORK/check.py" "$WORK/drive-$L.json" "$DL" "$L" || fail "a file did not match its page ($L)"
  if command -v soffice >/dev/null; then
    for f in "$DL"/*.xlsx; do
      (cd "$WORK" && timeout 120 soffice --headless -env:UserInstallation=file://$WORK/lo --convert-to csv --outdir "$WORK/lo-out-$L" "$f" >/dev/null 2>&1) || fail "LibreOffice could not open $(basename "$f")"
      [[ -s "$WORK/lo-out-$L/$(basename "${f%.xlsx}").csv" ]] || fail "LibreOffice wrote nothing for $(basename "$f")"
      ok "LibreOffice opens $(basename "$f") ($L)"
    done
  else
    echo "not checked: soffice is not on this machine (the file opening in a spreadsheet program)"
  fi
  [[ -n "${PGVIGIL_EXPORT_OUT:-}" ]] && { mkdir -p "$PGVIGIL_EXPORT_OUT/$L"; cp "$DL"/* "$PGVIGIL_EXPORT_OUT/$L"/; echo "kept in $PGVIGIL_EXPORT_OUT/$L"; }
done
echo "OK: the Summary and the Tables tab exported to .xlsx and CSV, each file matching its page"
