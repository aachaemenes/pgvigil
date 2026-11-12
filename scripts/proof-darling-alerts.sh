#!/usr/bin/env bash
# Proof of task 177 D30 (darling-open D30: PerformanceMonitor's alert pages in pgvigil's shape): the alert history's
# labelled detail per row, the evidence read and drawn on an alert's page per alert family (how to read it, the family's
# metrics charted around the firing, the sessions or requests at the first send), the one-sentence summary of the rules
# in force, the starter rules that pre-fill the rule dialog, and every link and button of the three alert pages clicked,
# each landing named in a click table. A demo fleet (its alerts, sends and rules seeded by `pgvigil demo`) is served on
# loopback and driven by a headless Chromium. Nothing leaves the machine.
#
#   PGVIGIL_ADMIN_DSN    keyword-form connection to a PostgreSQL cluster as a login that may create a database
#   PGVIGIL_DEMO_WAIT_S  seconds to wait for the seeded demo (default 240)
#   PGVIGIL_ALERTS_SHOTS a folder for the pages' pictures, light and dark (default: removed with the run)
#   PGVIGIL_CLICK_OUT    a file for the click table (JSON; default: removed with the run)
#   Needs: go, psql, chromium, node 22+, curl, python3; the web bundle built (internal/web/dist/app.js).
#
# Expected (written before the first run):
#  H. #/alerts: every row of the alert history grid has its detail as a disclosure (details.alert-detail) whose summary
#     is the value's first line; opened, it shows labelled lines, 'Value: <the whole value>' first and 'Alert: <source>:
#     <alert>' among them; the export keeps the value alone (data-full = the value).
#  E. for each alert family the demo's alerts hold (one alert page per family): #/alert?k=<key> draws a section
#     'Evidence: <family>' - the family by the proof's own table of words (blocking, CPU, memory, connections, vacuum,
#     replication, storage and IO, else 'The instance') -, a how-to-read paragraph, one chart per metric of the family
#     (each its canvas, or the chart's own 'Not enough snapshots' / 'Only one read' line, never an error box), and
#     'Sessions at the first send' (PostgreSQL) or 'Requests at the first send' (SQL Server) with a grid or its empty line.
#  S. #/alertrules: one sentence 'pgvigil will alert when ... .' naming every rule switched on (as many 'when' clauses
#     as /api/alertrules lists live enabled rules), each with its condition words.
#  T. the starter rules: 'Starter rules' on #/alertrules opens a menu of PerformanceMonitor's starter templates whose
#     measure pgvigil charts as a metric: 'PostgreSQL: connection count high' and 'SQL Server: sustained blocking'; the
#     first opens the New alert rule dialog filled: sessions.total, above, 200, 500, 15 minutes, its name (Save off on
#     the demo's read-only serve, the reason said).
#  C. the click table: every a[href] and button inside the page (main) of #/alerts, one #/alert page and #/alertrules:
#     every link's target read (a page of the UI); one of each kind clicked (a link kind: its tab, its parameters' names,
#     its words without figures; a button kind: its words), the kind's count in the table: a link lands on its own tab with no error box (its h2 named), a button opens a dialog (its title named), a
#     menu (its items), a toggle (aria-pressed; one already pressed stays on: 'already on'), an expansion (aria-expanded),
#     a download, a status line or a redraw of the page, or is disabled with
#     its reason (the demo serves read only); 0 FAIL.
#  A. #/admin (its route the WIRING BLOCK's): five tabs - Servers (a row per instance of /api/instances), Notification
#     routes, Alert settings (the sentence and the eight built-in thresholds of 0118), Threshold overrides, Server actions
#     (three switches per SQL Server instance) -, each its heading and a grid, no error box, the tab in the address
#     (atab=); its links and buttons in C.
#  P. shots of #/alerts, an alert page, #/alertrules and #/admin in the light and the dark theme.
#  F. migration 0118 (PerformanceMonitor's defaults as findings) on a fresh repository leaves pgvigil.findings alone;
#     scripts/proof-darling-alerts-findings.sql (proof only: the arm the release's join writes in its view) splices
#     darling_alert_findings in, on that repository and on the demo's database before the demo seeds (A-P); on a tree
#     with the release's join applied (0190_*) the arm is already there and no splice runs; F1 live on this cluster: a table of 1,200,000 deleted rows (autovacuum off for it) read by
#     `pgvigil collect -once tables` raises 'dead tuples piling up' (warning) on <db>.public.d30_dead, the alert sender's
#     pass sends it to a file drop; after VACUUM and a read the finding is gone, and a pass that misses it, a read and a
#     pass clear the alert (the sender's clear rule: a read newer than the pass that first missed it);
#     F2-F5 seeded at the collected rows (no standby, 10 GB slot, small volume or AG here: NOT PROVEN on a live engine):
#     replay lag 45 s warning / 400 s critical / 10 s none, slot WAL 12 GB warning / 60 GB critical / 9 GB none, a
#     volume of 20 GB with 4.5 GB free warning, one of 15 GB with 1.8 GB free critical (its drive threshold 5 % / 2 %,
#     so its percent rule raises nothing), 8 GB with 4 GB free none (10 GB or smaller), 500 GB with 3 GB free none (its
#     percent rule judges it), 40 GB with 8 GB free none; an AG database 400 s behind warning / 20 s none; the rows
#     recovered raise nothing.
#     F6 live: an instance reached through a loopback forwarder: the forwarder stopped, its next read fails to connect
#     (the collector records it through import_connect_failure: the WIRING BLOCK; its note 'connect: ...')
#     -> 'server unreachable' (critical) on it alone, sent to the file drop; the forwarder back, the next read connects
#     -> the finding is gone and the alert clears. F7 seeded: runnable tasks per scheduler over three reads in 5
#     minutes, 4 -> none, 10 -> warning, 20 -> critical. F8 seeded: SQL Server requests at the newest read: one of 45
#     minutes counted ('1 request(s) ... the longest 45 min: session 61'), a 20-minute one under the bar, a 2-hour BACKUP,
#     RESTORE and BACKUPIO wait, a system session (id 12), WAITFOR, BROKER_RECEIVE_WAITFOR, an NT AUTHORITY\SYSTEM login
#     and an Agent T-SQL job step left out; a newer read with no request, no finding.
#  G. a serve on that repository: GET /api/alerts?k=<the dead-tuple alert> holds its firing, fired and cleared; its page
#     draws 'Evidence: Vacuum' with a chart and 'Sessions at the first send'.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_d30_$RANDOM"; SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in go chromium node psql curl python3 ss; do command -v $t >/dev/null || fail "$t is not on this machine"; done
grep -q 'Evidence: ' internal/web/dist/app.js || fail "the web bundle is older than alert_page.ts (no evidence section): run 'npm run build' in web/"
freeport() { local p; for _ in $(seq 1 50); do p=$((21000 + RANDOM % 11000)); ss -Htan "sport = :$p" | grep -q . || { echo $p; return; }; done; echo 0; }
PORT=$(freeport); CDP=$(freeport)
echo "== build and seed the demo into $DB, serve on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
# the demo seeds its alert history from pgvigil.alert_findings before it serves (demo.go: Migrate, Seed, SeedAlerts):
# its database is migrated and given the findings arm of 0118's view first (a proof-only splice, as the release's join
# writes it), so the seeded history holds the darling alerts; the demo's own Migrate then finds nothing to apply
export D30_DEMO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
printf 'repository:\n  dsn: env:D30_DEMO_DSN\n' > "$WORK/demo-cfg.yaml"
"$WORK/pgvigil" migrate -config "$WORK/demo-cfg.yaml" > "$WORK/demo-migrate.log" 2>&1 || { tail -5 "$WORK/demo-migrate.log"; fail "the demo database's migrate"; }
psql "$D30_DEMO_DSN" -XAtq -v ON_ERROR_STOP=1 -f scripts/proof-darling-alerts-findings.sql >/dev/null || fail "the findings arm (scripts/proof-darling-alerts-findings.sql) on the demo"
"$WORK/pgvigil" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-240}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { tail -5 "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || fail "the demo did not come up"
U="http://127.0.0.1:$PORT/"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
mkdir -p "$WORK/dl" "${PGVIGIL_ALERTS_SHOTS:-$WORK/shots}"

cat > "$WORK/drive.mjs" <<'JS'
const [port, U, dl, shots] = process.argv.slice(2);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async expr => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }); if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400)); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dl }).catch(() => {});
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
const settled = async () => {
  for (const t = Date.now(); Date.now() - t < 20000; await sleep(200)) {
    const ok = await ev(`(() => { const m = document.querySelector('main'); return !!m && m.children.length > 0 && ![...m.querySelectorAll('p')].some(p => /^Loading|Reading the instance/.test(p.textContent)); })()`);
    if (ok) { await sleep(600); return true; }
  }
  return false;
};
const go = async hash => { await cmd('Page.navigate', { url: U + hash }); await sleep(300); if (!await settled()) throw new Error('did not settle: ' + hash); };
const out = {};
const shot = async name => { for (const th of ['light', 'dark']) { await ev(`document.documentElement.setAttribute('data-theme', '${th}')`); await sleep(250); const d = await cmd('Page.captureScreenshot', { format: 'png' }); if (d.result?.data) fs.writeFileSync(`${shots}/${name}-${th}.png`, Buffer.from(d.result.data, 'base64')); } await ev(`document.documentElement.removeAttribute('data-theme')`); };

// H: the history's detail disclosures
await go('#/alerts?w=7d');
out.history = await ev(`(() => { const hist = (() => { let past = false; for (const e of document.querySelectorAll('main h3, main table.grid')) { if (e.tagName === 'H3') { past = e.textContent.startsWith('Alert history'); continue; } if (past) return e; } return null; })();
  const histRows = hist ? [...hist.querySelectorAll(':scope > tbody > tr')] : [];
  const histValued = histRows.filter(tr => [...tr.children].some(td => td.querySelector('details.alert-detail'))).length;
  const ds = [...document.querySelectorAll('main details.alert-detail')];
  const first = ds[0]; if (first) first.open = true;
  return { rows: histRows.length, details: ds.length, valued: histValued,
    sample: first ? { summary: first.querySelector('summary').textContent, full: first.dataset.full, lines: [...first.querySelectorAll(':scope > div > div')].map(x => x.textContent) } : null,
    keys: [...new Set([...document.querySelectorAll('main a[href*="#/alert?"]')].map(a => new URLSearchParams(a.getAttribute('href').split('?')[1]).get('k')))] }; })()`);
await shot('alerts');
// the alerts the history links to, with their source and setting (the API's card)
// the proof's own expectations: concrete (setting -> family) pairs read from the SQL that writes the findings (0118,
// 0021, 0006, 0024, 0067, 0074, 0085), not the page's rules; an alert rule's alert is 'Alert rule'; a setting outside the
// table is opened and its section required, its family printed, not graded
const WANT = { 'dead tuples piling up': 'Vacuum', 'database xid age': 'Vacuum', 'autovacuum is off': 'Vacuum', 'replay lag': 'Replication',
  'replication slot retaining WAL': 'Replication', 'inactive replication slot': 'Replication', 'AG secondary behind': 'Replication',
  'swap used': 'Memory', 'a volume under 5 GB free': 'Storage and IO', 'a volume under 10 % free': 'Storage and IO', 'runnable queue per scheduler': 'CPU',
  'scheduler pressure': 'CPU', 'server unreachable': 'The instance', 'the redo queue is over its threshold': 'Replication',
  'the log send queue is over its threshold': 'Replication', 'log shipping is behind its threshold': 'Replication', 'a database is suspended': 'Replication', 'lock_timeout': 'The instance', 'autovacuum_max_workers': 'The instance', 'work_mem': 'The instance' };
const familyOf = (src, set) => src === 'alert rule' ? 'Alert rule' : (WANT[set] ?? null);
out.evidence = []; const seen = new Set();
for (const k of out.history.keys.slice(0, 60)) {
  const d = await (await fetch(U + 'api/alerts?k=' + k)).json().catch(() => null);
  const card = d?.card?.rows?.length ? Object.fromEntries(d.card.columns.map((c, i) => [c, d.card.rows[0][i]])) : null;
  const occ = d?.occurrences?.rows?.length ? Object.fromEntries(d.occurrences.columns.map((c, i) => [c, d.occurrences.rows[0][i]])) : null;
  const head = occ ?? card; if (!head) continue;
  const fam = familyOf(head.source, head.setting), eng = head.engine ?? card?.engine;
  const tag = `${head.source}|${head.setting}|${eng}`;
  if (seen.has(tag) || out.evidence.length >= 14) continue; seen.add(tag);
  await go(`#/alert?k=${k}`); await sleep(1500);
  const e = await ev(`(() => { const s = document.querySelector('main section.evidence'); if (!s) return null;
    return { h3: s.querySelector('h3').childNodes[0].textContent.trim(), read: s.querySelector('p.how-to-read')?.textContent ?? '',
      charts: [...s.querySelectorAll('.charts > div')].map(c => ({ title: c.querySelector('h3')?.childNodes[0]?.textContent?.trim() ?? '', canvas: !!c.querySelector('canvas'), empty: c.querySelector('p.empty')?.textContent ?? '', error: !!c.querySelector('.error') })),
      live: [...s.querySelectorAll(':scope > div:last-child > h3')].map(h => h.textContent)[0] ?? '', liveGrid: !!s.querySelector(':scope > div:last-child table.grid, :scope > div:last-child p.empty'), liveError: !!s.querySelector(':scope > div:last-child .error') }; })()`);
  out.evidence.push({ key: k, source: head.source, setting: head.setting, engine: eng, want: fam, got: e });
  if (out.evidence.length === 1) await shot('alert');
}
// S, T: the rules page
await go('#/alertrules?w=7d');
const rules = await (await fetch(U + 'api/alertrules')).json();
const rrows = rules.rules?.rows?.map(r => Object.fromEntries(rules.rules.columns.map((c, i) => [c, r[i]]))) ?? [];
out.rules = { enabled: rrows.filter(r => r.live && r.enabled).map(r => r.name ?? `${r.family_label}: ${r.label ?? r.metric}`),
  sentence: await ev(`document.querySelector('main p.will-alert')?.textContent ?? null`) };
await shot('alertrules');
out.starters = await ev(`(async () => { const b = [...document.querySelectorAll('main button')].find(x => x.textContent.startsWith('Starter rules')); if (!b) return null;
  b.click(); await new Promise(r => setTimeout(r, 300)); const items = [...document.querySelectorAll('.menu button')].map(x => x.textContent);
  const first = document.querySelector('.menu button'); if (!first) return { items };
  first.click(); await new Promise(r => setTimeout(r, 500)); const d = document.querySelector('dialog[open]');
  const form = d ? [...d.querySelectorAll('input, select, textarea')].map(x => x.value) : null;
  const title = d?.querySelector('h3, h2')?.textContent ?? null; const save = d?.querySelector('button[type=submit]');
  const need = d ? [...d.querySelectorAll('p.meta')].map(p => p.textContent).find(t => /^Save needs/.test(t)) ?? '' : '';
  const res = { items, title, form, saveOff: !!save?.disabled, need }; if (d) d.close(); return res; })()`);
// A: the Admin page, every tab opened (the route is the WIRING BLOCK's: the box run applies it)
out.admin = { tabs: [] };
await go('#/admin'); await sleep(800);
const atabs = await ev(`[...document.querySelectorAll('main .seg[aria-label="Admin tabs"] button')].map(b => b.textContent)`);
for (const [i, label] of (atabs || []).entries()) {
  await ev(`document.querySelectorAll('main .seg[aria-label="Admin tabs"] button')[${i}].click()`); await sleep(1500);
  out.admin.tabs.push(await ev(`(() => { const b = document.querySelector('main .admin-body'); return { label: ${JSON.stringify(label)}, h3: b?.querySelector('h3')?.textContent ?? '', error: !!b?.querySelector('.error'),
    rows: b ? [...b.querySelectorAll('table.grid')].map(t => Number(t.dataset.rows ?? t.querySelectorAll(':scope > tbody > tr').length)) : [], sentence: b?.querySelector('p.will-alert')?.textContent ?? null, hash: location.hash }; })()`));
  if (i === 0) await shot('admin');
}
const instsAll = await (await fetch(U + 'api/instances')).json();
out.admin.instances = instsAll.rows.length;
out.admin.sqlservers = instsAll.rows.filter(r => r[instsAll.columns.indexOf('engine')] === 'sqlserver').length;
// C: every link and button of the three pages: every link's target read and checked; one of each kind clicked (a link
// kind: its tab, its parameters' names and its words with the figures out; a button kind: its words the same way)
const pages = ['#/alerts?w=7d', out.evidence[0] ? `#/alert?k=${out.evidence[0].key}` : null, '#/alertrules?w=7d', '#/admin?atab=settings'].filter(Boolean);
const KIND = `(el => { const w = (el.getAttribute('aria-label') || el.textContent || el.title || '').replace(/\\s+/g, ' ').trim().replace(/[0-9][0-9:.,\\- ]*/g, '#').slice(0, 60);
  if (el.tagName === 'A') { const h = el.getAttribute('href') || ''; const [path, qs] = h.split('?'); return 'A ' + path + '?' + [...new URLSearchParams(qs || '').keys()].sort().join('&') + ' ' + w; }
  return 'B ' + w; })`;
out.clicks = []; out.links = [];
for (const p of pages) {
  await go(p);
  const all = await ev(`[...document.querySelectorAll('main a[href], main button')].map(el => ({ kind: (${KIND})(el), tag: el.tagName, href: el.getAttribute('href') }))`);
  out.links.push(...all.filter(x => x.tag === 'A').map(x => ({ page: p, href: x.href })));
  const groups = new Map();
  all.forEach((x, i) => { if (!groups.has(x.kind)) groups.set(x.kind, { i, n: 0 }); groups.get(x.kind).n++; });
  for (const [kind, g] of groups) {
    await cmd('Page.navigate', { url: 'about:blank' }); await sleep(150);
    await go(p); await sleep(1200);   // the alert page's charts and live grid arrive after the page: a quiet page first
    const files = fs.readdirSync(dl).length;
    const r = await ev(`(async () => { const KIND = ${KIND}; const el = [...document.querySelectorAll('main a[href], main button')].find(x => KIND(x) === ${JSON.stringify(kind)}); if (!el) return { gone: true };
      const what = (el.getAttribute('aria-label') || el.textContent || el.title || '').replace(/\\s+/g, ' ').trim().slice(0, 80), tag = el.tagName;
      if (tag === 'A') { const h = el.getAttribute('href'); return { tag, what, href: h, kind: h.startsWith('#/') ? 'link' : 'outside' }; }
      if (el.disabled) return { tag, what, kind: 'disabled', why: el.title || '' };
      const statText = () => [...document.querySelectorAll('main [role=status]')].map(s => s.textContent.trim()).join(' | ');
      const pressed = el.getAttribute('aria-pressed'), expanded = el.getAttribute('aria-expanded'), before = location.hash, size = document.querySelector('main').innerHTML.length, stat0 = statText();
      await new Promise(r => setTimeout(r, 400));
      const quiet = document.querySelector('main').innerHTML.length === size && statText() === stat0;   // nothing moves by itself
      el.click(); await new Promise(r => setTimeout(r, 600));
      const dlg = document.querySelector('dialog[open]'), menu = document.querySelector('.menu'), stat = statText();
      const res = { tag, what, quiet, kind: dlg ? 'dialog' : menu ? 'menu' : el.getAttribute('aria-pressed') !== pressed ? 'toggle' : el.getAttribute('aria-expanded') !== expanded ? 'expands'
          : location.hash !== before ? 'navigates' : stat !== stat0 ? 'status' : quiet && document.querySelector('main').innerHTML.length !== size ? 'redraws'
          : pressed === 'true' && el.getAttribute('aria-pressed') === 'true' ? 'already on' : 'none',
        dialog: dlg?.querySelector('h3, h2')?.textContent ?? null, menu: menu ? [...menu.querySelectorAll('button')].map(b => b.textContent).slice(0, 12) : null, status: stat.slice(0, 200), to: location.hash };
      if (dlg) dlg.close(); document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); return res; })()`);
    if (r.gone) { out.clicks.push({ page: p, i: g.i, group: g.n, pattern: kind, kind: 'gone', tag: '', what: kind }); continue; }
    if (r.kind === 'none') { await sleep(800); if (fs.readdirSync(dl).length > files) r.kind = 'download'; }
    if (r.kind === 'link') {
      await cmd('Page.navigate', { url: 'about:blank' }); await sleep(150);
      await cmd('Page.navigate', { url: U + r.href }); await sleep(300); await settled();
      const land = await ev(`({ hash: location.hash, h2: document.querySelector('main h2')?.textContent ?? '', error: !!document.querySelector('main .error') })`);
      r.landing = land; r.kind = land.error ? 'link-error' : 'link';
    }
    out.clicks.push({ page: p, i: g.i, group: g.n, pattern: kind, ...r });
  }
}
await go('#/alerts?w=7d');
console.log(JSON.stringify(out));
process.exit(0);
JS

echo "== the pages driven"
node "$WORK/drive.mjs" "$CDP" "$U" "$WORK/dl" "${PGVIGIL_ALERTS_SHOTS:-$WORK/shots}" > "$WORK/drive.json" || { tail -5 "$WORK/drive.json"; fail "the driver failed"; }
[[ -n "${PGVIGIL_CLICK_OUT:-}" ]] && cp "$WORK/drive.json" "$PGVIGIL_CLICK_OUT"

python3 -I - "$WORK/drive.json" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1])); bad = 0
def check(c, m):
    global bad
    print(('ok   ' if c else 'FAIL ') + m)
    if not c: bad += 1
h = d['history']; s = h.get('sample') or {}
check(h['rows'] > 0 and h['valued'] == h['rows'] and s.get('lines') and s['lines'][0] == 'Value: ' + (s.get('full') or '') and any(x.startswith('Alert: ') for x in s['lines']) and (s.get('full') or '').startswith(s.get('summary', '\0')),
      f"H: the alert history grid: {h['valued']} of its {h['rows']} rows hold their detail as a disclosure: summary the value's first line, opened 'Value: <the value>' first and an 'Alert:' line ({s.get('lines', [])[:4]})")
ev = d['evidence']
graded = [e for e in ev if e['want']]
check(len(ev) >= 2 and len(graded) >= 2 and any(e['engine'] == 'sqlserver' for e in ev), f"E: {len(ev)} alerts opened, {len(graded)} of them in the proof's own table, at least one SQL Server ({[(e['setting'], e['engine']) for e in ev]})")
for e in ev:
    g = e['got'] or {}
    charts = g.get('charts') or []
    fam_ok = e['want'] is None or g.get('h3') == 'Evidence: ' + e['want']
    good = g and fam_ok and len(g.get('read', '')) > 40 and charts and all((c['canvas'] or c['empty']) and not c['error'] for c in charts) \
        and g.get('live') == ('Requests at the first send' if e['engine'] == 'sqlserver' else 'Sessions at the first send') and g.get('liveGrid') and not g.get('liveError')
    check(bool(good), f"E: {e['source']}: {e['setting']} ({e['engine']}) - '{g.get('h3')}' (want {repr('Evidence: ' + e['want']) if e['want'] else 'any family: not in the table'}), {len(charts)} chart(s) {[(c['title'], 'drawn' if c['canvas'] else c['empty']) for c in charts]}, '{g.get('live')}'")
r = d['rules']; sent = r.get('sentence') or ''
check(bool(r['enabled']) and re.match(r'^pgvigil (will alert|would alert \(no alert channel is configured, so nothing is sent\)) when ', sent) is not None and sent.endswith('.') and sent.count('; or when ') == len(r['enabled']) - 1 and all(n in sent for n in r['enabled']),
      f"S: one sentence over the {len(r['enabled'])} rule(s) switched on: {sent[:160]}...")
t = d.get('starters')
vals = list((t or {}).get('form') or [])
vals = list((t or {}).get('form') or [])
check(bool(t) and (t.get('items') or [])[:2] == ['PostgreSQL: connection count high', 'SQL Server: sustained blocking'] and (t.get('title') or '') == 'New alert rule'
      and all(v in vals for v in ('200', '500', '3', 'above', 'PostgreSQL: connection count high', 'sessions.total')) and t.get('saveOff') and (t.get('need') or '').startswith('Save needs a server where alert rules can be written'),
      f"T: 'Starter rules' lists PerformanceMonitor's two starters pgvigil has a metric for ({(t or {}).get('items')}); the first opens '{(t or {}).get('title')}' filled with sessions.total above 200 / 500 for 3 min, Save off: {(t or {}).get('need')!r} ({vals[:12]})")
tabs = {'admin', 'mssqlactions', 'alerts', 'alert', 'alertrules', 'summary', 'findings', 'counters', 'performance', 'mssql_running', 'mssql_waits', 'mssql_blocked', 'activity', 'waits', 'logs', 'vacuum', 'config', 'metrics', 'drives', 'mssqlactions'}
links = d['links']; odd = [x for x in links if not re.match(r'^#/[a-z_]+(\?|$)', x['href'] or '') or re.match(r'^#/([a-z_]+)', x['href']).group(1) not in tabs]
check(len(links) > 0 and not odd, f"C: every link's target read: {len(links)} links on the three pages, each a page of the UI ({len(odd)} not: {odd[:3]})")
a = d.get('admin') or {}; tabsA = {t['label']: t for t in a.get('tabs', [])}
want_tabs = ['Servers', 'Notification routes', 'Alert settings', 'Threshold overrides', 'Server actions']
check(list(tabsA) == want_tabs and all(t['h3'] == t['label'] and not t['error'] and t['rows'] for t in tabsA.values())
      and tabsA['Servers']['rows'][0] == a.get('instances') and tabsA['Alert settings']['rows'][0] == 8 and (tabsA['Alert settings'].get('sentence') or '').startswith('pgvigil ')
      and tabsA['Server actions']['rows'][0] == 3 * a.get('sqlservers', -1) and all('atab=' in t['hash'] for t in tabsA.values()),
      f"A: #/admin's tabs {list(tabsA)}: each its heading and grid, no error box; Servers {tabsA.get('Servers', {}).get('rows')} = {a.get('instances')} instances, the built-in thresholds 8 rows and the sentence, Server actions {tabsA.get('Server actions', {}).get('rows')} = 3 x {a.get('sqlservers')} SQL Server instances, the tab in the address")
cl = d['clicks']; kinds = {}
for c in cl: kinds[c['kind']] = kinds.get(c['kind'], 0) + 1
badc = [c for c in cl if c['kind'] in ('link-error', 'none', 'gone') or (c['kind'] == 'disabled' and not c.get('why')) or (c['kind'] == 'link' and not c.get('landing', {}).get('h2'))]
print('     click table: page | # | element (its kind: how many) | kind | landing / result')
for c in cl:
    res = c.get('landing', {}).get('h2') if c['kind'].startswith('link') else c.get('dialog') or (c.get('menu') and ' / '.join(c['menu'][:4])) or c.get('status') or c.get('why') or c.get('to') or ''
    print(f"     {c['page'].split('?')[0]} | {c['i']} | {c['tag']} '{c['what']}' ({c['group']}) | {c['kind']} | {c.get('landing', {}).get('hash', '') if c['kind'].startswith('link') else ''} {res}"[:300])
check(len(cl) > 10 and not badc, f"C: {len(cl)} links and buttons clicked on {len(set(c['page'] for c in cl))} pages ({kinds}); {len(badc)} with an error landing or no visible result {[(c['page'], c['what'], c['kind']) for c in badc[:5]]}")
sys.exit(1 if bad else 0)
PY
ok "the checks above (H E S T C P)"

# ---- F, G: PerformanceMonitor's defaults as findings (migration 0118), firing and recovery --------------------------------
REPO2="pgvigil_d30r_$RANDOM"; TGT="pgvigil_d30t_$RANDOM"; ALR="pgvigil_d30a_$RANDOM"; PW=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
SRV2=""
cleanup2() {
  [[ -n "$SRV2" ]] && kill "$SRV2" 2>/dev/null || true
  [[ -n "${FWDPID:-}" ]] && kill "$FWDPID" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO2 with (force)" -c "drop database if exists $TGT with (force)" -c "drop role if exists $ALR" >/dev/null 2>&1 || true
  cleanup
}
trap cleanup2 EXIT
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO2" -c "create database $TGT" >/dev/null
export D30_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO2" D30_TGT_DSN="$PGVIGIL_ADMIN_DSN dbname=$TGT"
# d30down reaches the same server through a loopback forwarder this script starts and stops (the 'server' going away)
FWD=$(freeport); FWDPID=""
FWD_HOST=$(sed -nE 's/.*host=([^ ]+).*/\1/p' <<<"$PGVIGIL_ADMIN_DSN"); FWD_PORT=$(sed -nE 's/.*port=([0-9]+).*/\1/p' <<<"$PGVIGIL_ADMIN_DSN")
export D30_DOWN_DSN="$PGVIGIL_ADMIN_DSN dbname=$TGT host=127.0.0.1 port=$FWD connect_timeout=3"
cat > "$WORK/fwd.py" <<'PYF'
import socket, sys, threading
lp, th, tp = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', lp)); s.listen(16)
def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d: break
            b.sendall(d)
    except OSError: pass
    finally:
        for x in (a, b):
            try: x.close()
            except OSError: pass
while True:
    c, _ = s.accept()
    try: u = socket.create_connection((th, tp))
    except OSError:
        c.close(); continue
    threading.Thread(target=pipe, args=(c, u), daemon=True).start(); threading.Thread(target=pipe, args=(u, c), daemon=True).start()
PYF
fwd_up() { python3 -I "$WORK/fwd.py" "$FWD" "${FWD_HOST:-127.0.0.1}" "${FWD_PORT:-5432}" & FWDPID=$!; sleep 1; }
fwd_down() { [[ -n "$FWDPID" ]] && kill "$FWDPID" 2>/dev/null; wait "$FWDPID" 2>/dev/null || true; FWDPID=""; sleep 1; }
mkdir -p "$WORK/drop"
cat > "$WORK/cfg.yaml" <<EOF
repository:
  dsn: env:D30_REPO_DSN
alerts_dsn: env:D30_ALERTS_DSN
alerts:
  - {name: drop, kind: file, min_severity: warning, clear_after: 0, file: {dir: $WORK/drop}}
instances:
  - name: d30pg
    dsn: env:D30_TGT_DSN
  - name: d30down
    dsn: env:D30_DOWN_DSN
EOF
"$WORK/pgvigil" migrate -config "$WORK/cfg.yaml" > "$WORK/migrate.log" 2>&1 || { tail -5 "$WORK/migrate.log"; fail "F: migrate"; }
rq() { psql "$D30_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
tq() { psql "$D30_TGT_DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
[[ $(rq "select count(*) from pgvigil.schema_version where version = '0118_darling_alerts.sql'") == 1 ]] || fail "F: 0118 not applied"
JOINED=$(rq "select count(*) from pgvigil.schema_version where version like '0190%'")
if [[ $JOINED == 0 ]]; then
  [[ $(rq "select pg_get_viewdef('pgvigil.findings'::regclass) like '%darling_alert_findings%'") == f ]] || fail "F: 0118 itself changed pgvigil.findings (its arm is the release join's)"
  psql "$D30_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 -f scripts/proof-darling-alerts-findings.sql >/dev/null || fail "F: the findings arm (scripts/proof-darling-alerts-findings.sql)"
fi
[[ $(rq "select pg_get_viewdef('pgvigil.findings'::regclass) like '%darling_alert_findings%'") == t ]] || fail "F: pgvigil.findings does not read darling_alert_findings after the splice"
psql "$D30_REPO_DSN" -XAtq -c "create role $ALR login password '$PW' in role pgvigil_alerter" >/dev/null
export D30_ALERTS_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO2 user=$ALR password=$PW"
ok "F: 0118 applied; $([[ $JOINED == 0 ]] && echo "pgvigil.findings left alone, the proof-only splice gives it the darling_alert_findings arm (the join's line)" || echo "the release's join (0190) holds the darling_alert_findings arm in pgvigil.findings")"
collect() { "$WORK/pgvigil" collect -config "$WORK/cfg.yaml" -once "$1" > "$WORK/collect.$1.log" 2>&1 || { tail -5 "$WORK/collect.$1.log"; fail "F: collect -once $1"; }; }
pass() { "$WORK/pgvigil" alerts -config "$WORK/cfg.yaml" > "$WORK/pass.$1.out" 2> "$WORK/pass.$1.err" || true; }
# the sender clears a gone finding only on a pass after a read newer than the pass that first missed it (alert_pick,
# 0073_ack.sql: missing_since, clear_after, an ok collection_dates row with snapshot_at > missing_since): miss, read, clear
clear_passes() { pass "$2.miss"; collect "$1"; pass "$2"; }
fwd_up
collect databases; collect tables
IID=$(rq "select instance_id from pgvigil.instances where name = 'd30pg'")
# F1 live: a table of 1,200,000 deleted rows with autovacuum off for it; then VACUUM
tq "create table d30_dead (id int, pad text) with (autovacuum_enabled = false)"
tq "insert into d30_dead select g, repeat('x', 20) from generate_series(1, 1200000) g"
tq "delete from d30_dead"
tq "select pg_stat_force_next_flush()" 2>/dev/null || true; sleep 2
DEAD=$(tq "select n_dead_tup from pg_stat_user_tables where relname = 'd30_dead'")
collect tables
F1=$(rq "select severity || '|' || value from pgvigil.findings where setting = 'dead tuples piling up' and value like '%.public.d30_dead' and instance_id = $IID")
[[ $F1 == "warning|$TGT.public.d30_dead" ]] || fail "F1: the dead-tuple finding: '$F1' (pg_stat_user_tables says $DEAD dead tuples)"
pass fire
grep -rl "dead tuples piling up" "$WORK/drop" >/dev/null 2>&1 || fail "F1: the file drop holds no 'dead tuples piling up' alert: $(cat "$WORK/pass.fire.err" | tail -3)"
KEY=$(rq "select finding_key from pgvigil.alert_findings where setting = 'dead tuples piling up' and value like '%.public.d30_dead' and instance_id = $IID")
ok "F1: $DEAD dead tuples in d30_dead (pg_stat_user_tables) -> 'dead tuples piling up' warning on $TGT.public.d30_dead, sent to the file drop (alert $KEY)"
tq "vacuum d30_dead"; tq "select pg_stat_force_next_flush()" 2>/dev/null || true; sleep 2
collect tables
[[ $(rq "select count(*) from pgvigil.findings where setting = 'dead tuples piling up' and value like '%.public.d30_dead' and instance_id = $IID") == 0 ]] || fail "F1: the finding still stands after VACUUM ($(tq "select n_dead_tup from pg_stat_user_tables where relname = 'd30_dead'") dead)"
clear_passes tables clear
[[ $(rq "select count(*) from pgvigil.alert_state where finding_key = '$KEY' and cleared_at is not null") -ge 1 ]] || fail "F1: the alert did not clear: $(rq "select channel, cleared_at from pgvigil.alert_state where finding_key = '$KEY'")"
ok "F1: after VACUUM ($(tq "select n_dead_tup from pg_stat_user_tables where relname = 'd30_dead'") dead) the finding is gone and the alert cleared (a pass that missed it, a read, a pass)"
# F2-F5 seeded at the collected rows (no standby, slot of 10 GB, 5 GB volume or AG on the box): the tiers and the clear
seed() { rq "$1" >/dev/null; }
# the seeded tables are partitioned (by month, mssql_requests by day): their partitions made first, as an import does
rq "select pgvigil.ensure_month_partition('replication_sample', now()), pgvigil.ensure_month_partition('mssql_sched_sample', now() - interval '5 minutes'), pgvigil.ensure_month_partition('mssql_sched_sample', now()), pgvigil.mssql_ensure_day_partition('mssql_requests', now())" >/dev/null
tiers() { rq "select string_agg(severity || ':' || value, ',' order by value) from pgvigil.findings where setting = '$1' and instance_id = $IID"; }
seed "insert into pgvigil.replication_sample (instance_id, snapshot_at, kind, key, lag_bytes, lag_secs, active, detail) values
  ($IID, now(), 'sender', 'd30_s_warn', 0, 45, true, '{}'), ($IID, now(), 'sender', 'd30_s_crit', 0, 400, true, '{}'), ($IID, now(), 'sender', 'd30_s_ok', 0, 10, true, '{}'),
  ($IID, now(), 'slot', 'd30_slot_warn', 12 * 1073741824::bigint, null, false, '{}'), ($IID, now(), 'slot', 'd30_slot_crit', 60 * 1073741824::bigint, null, true, '{}'), ($IID, now(), 'slot', 'd30_slot_ok', 9 * 1073741824::bigint, null, true, '{}')"
# the volume rule judges only where the drive's own percent threshold raises nothing (drives_now, default 20 % / 10 %):
# D30C: carries a drive threshold of 5 % / 2 % so its 1.8 GB of 15 GB (12 %) is 'ok' by percent and critical by the floor
G=1073741824
seed "insert into pgvigil.mssql_volumes (instance_id, volume, total_bytes, free_bytes, files, snapshot_at) values
  ($IID, 'D30W:', 20 * $G::bigint, 4.5 * $G::bigint, 2, now()), ($IID, 'D30C:', 15 * $G::bigint, 1.8 * $G::bigint, 1, now()), ($IID, 'D30S:', 8 * $G::bigint, 4 * $G::bigint, 1, now()),
  ($IID, 'D30P:', 500 * $G::bigint, 3 * $G::bigint, 1, now()), ($IID, 'D30O:', 40 * $G::bigint, 8 * $G::bigint, 1, now())"
seed "insert into pgvigil.drive_thresholds (level, instance_id, drive, warn_pct, crit_pct, created_by, created_at) values ('drive', $IID, 'D30C:', 5, 2, 'proof-darling-alerts', now())"
seed "insert into pgvigil.mssql_ag_database_state (instance_id, group_id, replica_server, database_name, snapshot_at, group_name, secondary_lag_s) values
  ($IID, 'g1', 'r2', 'd30db_behind', now(), 'd30ag', 400), ($IID, 'g1', 'r2', 'd30db_ok', now(), 'd30ag', 20)"
L=$(tiers 'replay lag'); S=$(tiers 'replication slot retaining WAL'); V=$(tiers 'a volume under 5 GB free'); A=$(tiers 'AG secondary behind')
[[ $L == "critical:d30_s_crit,warning:d30_s_warn" ]] || fail "F2: replay lag tiers '$L' (want 400 s critical, 45 s warning, 10 s none)"
[[ $S == "critical:d30_slot_crit,warning:d30_slot_warn" ]] || fail "F3: slot WAL tiers '$S' (want 60 GB critical, 12 GB warning, 9 GB none)"
[[ $V == "critical:D30C:,warning:D30W:" ]] || fail "F4: volume tiers '$V' (want D30C: 1.8 of 15 GB critical, D30W: 4.5 of 20 GB warning; D30S: 8 GB, D30P: 0.6 % and D30O: 8 GB free none): drives_now $(rq "select string_agg(drive || ' ' || free_pct || '% ' || status, ', ' order by drive) from pgvigil.drives_now where instance_id = $IID and drive like 'D30%'")"
[[ $A == "warning:d30ag: d30db_behind on r2" ]] || fail "F5: AG lag '$A' (want 400 s warning, 20 s none)"
ok "F2-F5: replay lag ($L), slot WAL ($S), volume free GB ($V), AG secondary ($A): PerformanceMonitor's tiers, each below-threshold row raising nothing"
seed "delete from pgvigil.replication_sample where instance_id = $IID and key like 'd30_%'"
seed "update pgvigil.mssql_volumes set free_bytes = total_bytes where instance_id = $IID"
seed "update pgvigil.mssql_ag_database_state set secondary_lag_s = 0 where instance_id = $IID"
[[ $(rq "select count(*) from pgvigil.findings where instance_id = $IID and setting in ('replay lag', 'replication slot retaining WAL', 'a volume under 5 GB free', 'AG secondary behind')") == 0 ]] || fail "F2-F5: findings still stand after the rows recovered"
ok "F2-F5: the rows recovered (lag gone, every volume free, caught up): no finding stands"
# F6 live: d30down's server goes away (the forwarder stopped): its next read cannot connect -> 'server unreachable'
# (critical), sent; the forwarder back: the next read connects -> the finding is gone, the alert clears
DID=$(rq "select instance_id from pgvigil.instances where name = 'd30down'")
[[ $(rq "select count(*) from pgvigil.collection_dates where instance_id = $DID and status = 'ok'") -ge 1 ]] || fail "F6: d30down was never read through the forwarder"
fwd_down
"$WORK/pgvigil" collect -config "$WORK/cfg.yaml" -once databases > "$WORK/collect.down.log" 2>&1 || true
F6=$(rq "select severity || '|' || value || '|' || detail from pgvigil.findings where setting = 'server unreachable' and instance_id = $DID")
[[ $F6 == critical\|d30down\|*"could not connect: "* && $(rq "select count(*) from pgvigil.collection_dates where instance_id = $DID and status = 'error' and note like 'connect: %'") -ge 1 ]] || fail "F6: no 'server unreachable' after the server went away: '$F6'; collection_dates: $(rq "select collection, status, note from pgvigil.collection_dates where instance_id = $DID order by snapshot_at desc limit 2")"
[[ $(rq "select count(*) from pgvigil.findings where setting = 'server unreachable' and instance_id = $IID") == 0 ]] || fail "F6: d30pg (reachable) is said unreachable"
pass down
grep -rl "server unreachable" "$WORK/drop" >/dev/null 2>&1 || fail "F6: the file drop holds no 'server unreachable' alert: $(tail -3 "$WORK/pass.down.err")"
DKEY=$(rq "select finding_key from pgvigil.alert_findings where setting = 'server unreachable' and instance_id = $DID")
fwd_up
collect databases
[[ $(rq "select count(*) from pgvigil.findings where setting = 'server unreachable' and instance_id = $DID") == 0 ]] || fail "F6: still unreachable after the server came back"
clear_passes databases up
[[ $(rq "select count(*) from pgvigil.alert_state where finding_key = '$DKEY' and cleared_at is not null") -ge 1 ]] || fail "F6: the unreachable alert did not clear"
ok "F6: d30down unreachable ('${F6:0:160}') -> critical, sent; reachable again -> gone, the alert cleared"
# F7 seeded: the runnable queue per scheduler over the last 5 minutes (three reads), 4 none / 10 warning / 20 critical
R7=""
for rq_ in 4 10 20; do
  seed "delete from pgvigil.mssql_sched_sample where instance_id = $IID"
  seed "insert into pgvigil.mssql_sched_sample (instance_id, snapshot_at, schedulers, runnable_tasks) select $IID, now() - make_interval(mins => g), 4, 4 * $rq_ from generate_series(0, 2) g"
  R7="$R7 $rq_:$(rq "select coalesce(max(severity), 'none') from pgvigil.findings where setting = 'runnable queue per scheduler' and instance_id = $IID")"
done
seed "delete from pgvigil.mssql_sched_sample where instance_id = $IID"
[[ $R7 == " 4:none 10:warning 20:critical" ]] || fail "F7: runnable per scheduler tiers '$R7' (want 4 none, 10 warning, 20 critical)"
ok "F7: runnable tasks per scheduler $R7 (PerformanceMonitor's 8 / 16)"
# F8 seeded: long-running requests at the newest read: 45 min (counted), 20 min (under), a 2-hour BACKUP and a 2-hour
# RESTORE (left out by command), a 2-hour request waiting BACKUPIO (left out by wait), a system session (left out)
# one read: its summary row and its requests in one statement (one now()); the newest read is the summary's
seed "insert into pgvigil.mssql_requests_summary (instance_id, snapshot_at, source) values ($IID, now(), 'dmv');
  insert into pgvigil.mssql_requests (instance_id, snapshot_at, session_id, request_id, command, wait_type, elapsed_ms, login_name, program_name) values
  ($IID, now(), 61, 0, 'SELECT', 'CXPACKET', 45 * 60000, 'app', 'erp'), ($IID, now(), 62, 0, 'UPDATE', null, 20 * 60000, 'app', 'erp'),
  ($IID, now(), 63, 0, 'BACKUP DATABASE', 'BACKUPTHREAD', 120 * 60000, 'sa', 'agent'), ($IID, now(), 64, 0, 'RESTORE LOG', null, 120 * 60000, 'sa', 'ssms'),
  ($IID, now(), 65, 0, 'DBCC', 'BACKUPIO', 120 * 60000, 'sa', 'agent'), ($IID, now(), 12, 0, 'TASK MANAGER', null, 300 * 60000, 'sa', ''),
  ($IID, now(), 66, 0, 'WAITFOR', 'WAITFOR', 120 * 60000, 'app', 'erp'), ($IID, now(), 67, 0, 'RECEIVE', 'BROKER_RECEIVE_WAITFOR', 120 * 60000, 'app', 'queue'),
  ($IID, now(), 68, 0, 'SELECT', 'PAGEIOLATCH_SH', 120 * 60000, 'NT AUTHORITY\SYSTEM', 'monitor'),
  ($IID, now(), 69, 0, 'SELECT', 'LCK_M_S', 120 * 60000, 'svc_agent', 'SQLAgent - TSQL JobStep (Job 0x1 : Step 1)')"
F8=$(rq "select severity || '|' || detail from pgvigil.findings where setting = 'long-running requests' and instance_id = $IID")
[[ $F8 == "warning|1 request(s) running 30 minutes or more, the longest 45 min: session 61 "* ]] || fail "F8: long-running requests '$F8' (want 1 request, 45 min, session 61: BACKUP, RESTORE, BACKUPIO, a system session, WAITFOR, Service Broker, a system login, an Agent job step and 20 min left out)"
sleep 1; seed "insert into pgvigil.mssql_requests_summary (instance_id, snapshot_at, source) values ($IID, now(), 'dmv')"
[[ $(rq "select count(*) from pgvigil.findings where setting = 'long-running requests' and instance_id = $IID") == 0 ]] || fail "F8: the finding stands after a newer read with no request"
seed "delete from pgvigil.mssql_requests where instance_id = $IID"; seed "delete from pgvigil.mssql_requests_summary where instance_id = $IID"
ok "F8: long-running requests: '${F8:0:120}' (2-hour BACKUP, RESTORE, BACKUPIO, WAITFOR, BROKER_RECEIVE_WAITFOR, a system session, NT AUTHORITY\\SYSTEM and an Agent job step left out, a 20-minute request under the bar); gone at a newer read with no request"

# G: the live alert's history and evidence read back through the API and the page of a serve on this repository
PORT2=$(freeport)
"$WORK/pgvigil" serve -config "$WORK/cfg.yaml" -no-login -listen "127.0.0.1:$PORT2" > "$WORK/serve2.log" 2>&1 &
SRV2=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$PORT2/api/health" >/dev/null 2>&1 && break; sleep 0.5; done
U2="http://127.0.0.1:$PORT2/"
curl -fs "${U2}api/alerts?k=$KEY" > "$WORK/alert.json" || fail "G: GET /api/alerts?k=$KEY: $(tail -3 "$WORK/serve2.log")"
python3 -I - "$WORK/alert.json" <<'PY' || fail "G: the alert's history through the API (above)"
import json, sys
d = json.load(open(sys.argv[1]))
occ = [dict(zip(d['occurrences']['columns'], r)) for r in (d.get('occurrences') or {}).get('rows', [])]
ok = len(occ) >= 1 and occ[0].get('setting') == 'dead tuples piling up' and occ[0].get('cleared_at') and occ[0].get('status') in ('resolved', 'cleared')
print(('ok   ' if ok else 'FAIL ') + f"G: /api/alerts?k= holds the firing: {[(o.get('setting'), o.get('status'), o.get('fired_at'), o.get('cleared_at')) for o in occ][:2]}")
sys.exit(0 if ok else 1)
PY
cat > "$WORK/page2.mjs" <<'JS'
const [port, U, key] = process.argv.slice(2);
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => (await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true })).result?.result?.value;
await cmd('Page.navigate', { url: U + '#/alert?k=' + key });
let r = null;
for (let n = 0; n < 60 && !(r && r.charts && r.live); n++) {
  await new Promise(x => setTimeout(x, 500));
  r = await ev(`(() => { const s = document.querySelector('main section.evidence'); if (!s) return null; return { h3: s.querySelector('h3').childNodes[0].textContent.trim(), charts: s.querySelectorAll('.charts > div canvas, .charts > div p.empty').length, live: [...s.querySelectorAll(':scope > div:last-child > h3')].map(h => h.textContent)[0] ?? '', h2: document.querySelector('main h2')?.textContent ?? '' }; })()`);
}
console.log(JSON.stringify(r)); process.exit(0);
JS
G=$(node "$WORK/page2.mjs" "$CDP" "$U2" "$KEY")
[[ $(python3 -c 'import json,sys; d=json.loads(sys.argv[1]) or {}; print(d.get("h3") == "Evidence: Vacuum" and d.get("charts", 0) >= 1 and d.get("live") == "Sessions at the first send" and "dead tuples piling up" in d.get("h2", ""))' "$G") == True ]] || fail "G: the alert's page: $G"
ok "G: #/alert?k=$KEY draws 'Evidence: Vacuum' with its charts and the sessions at the first send ($G)"
echo "PROOF OK: darling alerts (H E S T A C P F G)"
