#!/usr/bin/env bash
# Proof of the side tree's instance folders (task 65; DBADash's tree: instance > folders > database > objects): the demo
# fleet is seeded into a throwaway database and served on loopback from a build of this tree (the web bundle and the
# binary built in a temporary copy, so the committed bundle is not touched); a headless Chromium opens the folders and
# follows their links, counting the API reads each folder makes.
#   A. the tree: an instance's folders, the Databases / Tables / Jobs folders loading on first open with one read each,
#      the database, table and job nodes opening their pages with the time range kept, the search, the status dots.
#   B. the tab links (wired by the lead: the Tables, Jobs, Job report and Indexes tabs link each row to its page): "NOT
#      PROVEN (B)" when the build's /api/tables carries no dbid (the wiring is not in it).
#
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a login that may create a database (the throwaway one).
#   PGVIGIL_SRC        the source tree to build (default: this checkout); PGVIGIL_BIN a built binary instead (its bundle).
#
# Expected (written before the first run):
#  A. with w=7d: demo-onprem-erp01's caret shows, in order, Configuration, Checks, Replication, Storage, Databases, Jobs,
#     and no API read; Databases opens with exactly 1 /api/dbinfo read and lists the instance's present non-template
#     databases (the same names as that read); a database node opens "Database <name>" with w=7d and db= in the hash; its
#     Tables folder opens with exactly 1 /api/drill/db read and lists up to 15 tables; a table node opens "Table <s>.<t>"
#     with w=7d and rel=; demo-aurora-crm01's Jobs folder opens with exactly 1 /api/jobs read and lists its present jobs;
#     a job node opens "Job <name>" with w=7d. Closing and opening a folder again makes no read; no /api/tables read at
#     any point. A search for "rds" leaves only instances whose name holds rds, each with its status dot.
#  B. the Tables tab of demo-onprem-erp01: its table names link to #/table?..db=..&rel=.. and the first opens "Table";
#     the Jobs and Job report tabs of demo-aurora-crm01 and the root Jobs page link job names to #/job (the root page's
#     links carry each row's own instance); the Indexes tab of demo-onprem-erp01 links index names to #/index and the
#     first opens "Index". Every one of those links keeps w=7d.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
SRC=${PGVIGIL_SRC:-$PWD}
BIN=${PGVIGIL_BIN:-}
WORK=$(mktemp -d); DB="pgvigil_tree_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in chromium node npm psql; do command -v $t >/dev/null || fail "$t is not on this machine"; done
if [[ -z "$BIN" ]]; then
  echo "== build $SRC in a temporary copy (web bundle, then the binary)"
  rsync -a --exclude node_modules --exclude bin --exclude .git "$SRC/" "$WORK/src/"
  [[ -d "$SRC/web/node_modules" ]] || fail "no web/node_modules in $SRC: run npm ci in web/ first"
  ln -s "$SRC/web/node_modules" "$WORK/src/web/node_modules"
  (cd "$WORK/src/web" && npm run build >/dev/null 2>&1) || fail "the web build failed"
  (cd "$WORK/src" && CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil) || fail "the go build failed"
  BIN="$WORK/pgvigil"
fi
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
"$BIN" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 240); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { cat "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in 240 s"; }
U="http://127.0.0.1:$PORT"
WIRED=0
curl -fs "$U/api/tables?instance=1" | python3 -c 'import json,sys; sys.exit(0 if "dbid" in json.load(sys.stdin)["tables"]["columns"] else 1)' && WIRED=1
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"

cat > "$WORK/tree.mjs" <<'JS'
const [port, U, wired] = process.argv.slice(2);
const tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map(); const reqs = [];
ws.addEventListener('message', m => {
  const d = JSON.parse(m.data);
  if (d.method === 'Network.requestWillBeSent' && d.params.request.url.includes('/api/')) reqs.push(d.params.request.url.replace(U, ''));
  if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); }
});
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => { const d = await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true }); if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300)); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
let failed = 0;
const check = (ok, what) => { if (!ok) failed++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`); };
const until = async (expr, ms = 12000) => { const t = Date.now(); while (Date.now() - t < ms) { const v = await ev(expr); if (v) return v; await sleep(150); } return null; };
const get = async p => { const j = await (await fetch(U + '/api/' + p)).json(); return j; };
const rows = t => t ? t.rows.map(r => Object.fromEntries(t.columns.map((c, i) => [c, r[i]]))) : [];
// the reads a tree folder may make (the Summary's own 30-second refresh is not one of them)
const since = n => reqs.slice(n).filter(u => /^\/api\/(dbinfo|drill|jobs|tables)/.test(u));
// the tree's helpers in the page: the instance row by name, a caret under a node, the node texts under it
const H = `
  window.__inst = n => [...document.querySelectorAll('#tree .tree-inst')].find(r => r.querySelector('a.inst')?.textContent === n);
  window.__under = (row) => { const out = []; let e = row.nextElementSibling; while (e && !e.classList.contains('tree-inst')) { out.push(e); e = e.nextElementSibling; } return out; };
  window.__folder = (row, name) => window.__under(row).find(b => b.querySelector(':scope > .tree-node')?.textContent.endsWith(name));
  // a child is a node box (its link or name inside) or a state line itself (Loading..., an error): match the child too
  window.__texts = box => [...box.children].slice(1).map(c => (c.matches('p') ? c : c.querySelector('a.inst, .folder-name'))?.textContent ?? '');
  'ok'`;
await cmd('Page.enable'); await cmd('Runtime.enable'); await cmd('Network.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
const go = async hash => { await cmd('Page.navigate', { url: `${U}/${hash}` }); await sleep(300); await until(`!!document.querySelector('#tree .tree-inst') && !!document.querySelector('main section, main p')`); await ev(H); };
const insts = rows((await get('instances')).instances ?? (await get('instances')));
const byName = n => insts.find(r => r.name === n);
const erp = byName('demo-onprem-erp01'), crm = byName('demo-aurora-crm01');
if (!erp || !crm) { console.log('FAIL the demo lacks demo-onprem-erp01 or demo-aurora-crm01'); process.exit(1); }

// ---- A. the tree
await go('#/summary?w=7d');
let n0 = reqs.length;
await ev(`__inst('demo-onprem-erp01').querySelector('button.caret').click(), 'ok'`);
await sleep(300);
const folders = await ev(`__under(__inst('demo-onprem-erp01')).map(b => b.querySelector(':scope > .tree-node')?.textContent.slice(1))`);
check(JSON.stringify(folders) === JSON.stringify(['Configuration', 'Checks', 'Replication', 'Storage', 'Databases', 'Jobs']), `instance folders: ${JSON.stringify(folders)}`);
check(since(n0).length === 0, `opening an instance reads nothing (${since(n0).join(' ')})`);
n0 = reqs.length;
await ev(`__folder(__inst('demo-onprem-erp01'), 'Databases').querySelector('button.caret').click(), 'ok'`);
const dbNames = await until(`(() => { const t = __texts(__folder(__inst('demo-onprem-erp01'), 'Databases')); return t.length && !t.includes('Loading...') ? t : null; })()`);
const want = rows((await get(`dbinfo?instance=${erp.instance_id}`)).databases).filter(r => r.is_present && !r.is_template).map(r => r.datname);
const dbOk = JSON.stringify(dbNames) === JSON.stringify(want);
check(dbOk, `databases: ${JSON.stringify(dbNames)} = ${JSON.stringify(want)}`);
if (!dbOk) console.log(String(await ev(`__folder(__inst('demo-onprem-erp01'), 'Databases').outerHTML`)).slice(0, 1500));
const r1 = since(n0).filter(u => u.startsWith('/api/dbinfo'));
check(r1.length === 1 && since(n0).length === 1, `Databases: one read (${since(n0).join(' ')})`);
// a database node opens its page
const firstDb = want[0];
await ev(`[...__folder(__inst('demo-onprem-erp01'), 'Databases').querySelectorAll('a.inst')].find(a => a.textContent === ${JSON.stringify(firstDb)}).click(), 'ok'`);
let page = await until(`(() => { const h = document.querySelector('main h2')?.textContent ?? ''; return h.startsWith('Database ') ? JSON.stringify({ h, hash: location.hash }) : null; })()`);
page = page && JSON.parse(page);
check(page && page.h === `Database ${firstDb}` && /w=7d/.test(page.hash) && /[?&]db=\d+/.test(page.hash), `database node -> ${page ? page.h + ' ' + page.hash : 'no page'}`);
// its Tables folder, then a table node
await ev(H);
n0 = reqs.length;
const dbBox = `[...__folder(__inst('demo-onprem-erp01'), 'Databases').children].find(c => c.querySelector(':scope > .tree-node a')?.textContent === ${JSON.stringify(firstDb)})`;
const dbOpen = await ev(`${dbBox}.querySelector(':scope > .tree-node button.caret').getAttribute('aria-expanded')`);
if (dbOpen !== 'true') await ev(`${dbBox}.querySelector(':scope > .tree-node button.caret').click(), 'ok'`);
await sleep(200);
await ev(`${dbBox}.children[1].querySelector('button.caret').click(), 'ok'`);
const tabNames = await until(`(() => { const t = [...${dbBox}.children[1].querySelectorAll('a.inst')].slice(1).map(a => a.textContent); return t.length ? t : null; })()`);
const tr = since(n0);
check(tr.filter(u => u.startsWith('/api/drill/db')).length === 1 && tr.length === 1 && tabNames && tabNames.length >= 1 && tabNames.length <= 16, `Tables: one read, ${tabNames ? tabNames.length : 0} nodes (${tr.join(' ')})`);
await ev(`[...${dbBox}.children[1].querySelectorAll('a.inst')][1].click(), 'ok'`);
page = await until(`(() => { const h = document.querySelector('main h2')?.textContent ?? ''; return h.startsWith('Table ') ? JSON.stringify({ h, hash: location.hash }) : null; })()`);
page = page && JSON.parse(page);
check(page && page.h === `Table ${tabNames[0]}` && /w=7d/.test(page.hash) && /[?&]rel=\d+/.test(page.hash), `table node -> ${page ? page.h + ' ' + page.hash : 'no page'}`);
// close and open the Databases folder again: no read
await ev(H);
n0 = reqs.length;
await ev(`__folder(__inst('demo-onprem-erp01'), 'Databases').querySelector('button.caret').click(), 'ok'`); await sleep(200);
await ev(`__folder(__inst('demo-onprem-erp01'), 'Databases').querySelector('button.caret').click(), 'ok'`); await sleep(400);
check(since(n0).filter(u => u.startsWith('/api/dbinfo')).length === 0, `reopening Databases reads nothing (${since(n0).join(' ')})`);
// the jobs of crm01
n0 = reqs.length;
await ev(`__inst('demo-aurora-crm01').querySelector('button.caret').click(), 'ok'`); await sleep(300);
await ev(`__folder(__inst('demo-aurora-crm01'), 'Jobs').querySelector('button.caret').click(), 'ok'`);
const jobNames = await until(`(() => { const t = [...__folder(__inst('demo-aurora-crm01'), 'Jobs').querySelectorAll('a.inst')].slice(1).map(a => a.textContent); return t.length ? t : null; })()`);
const wantJobs = rows((await get(`jobs?instance=${crm.instance_id}`)).jobs).filter(r => r.is_present).map(r => String(r.job_name ?? r.job_id));
const jr = since(n0);
check(jr.filter(u => u.startsWith('/api/jobs')).length === 1 && JSON.stringify(jobNames) === JSON.stringify(wantJobs), `Jobs: ${JSON.stringify(jobNames)} = ${JSON.stringify(wantJobs)}, reads ${jr.join(' ')}`);
await ev(`[...__folder(__inst('demo-aurora-crm01'), 'Jobs').querySelectorAll('a.inst')][1].click(), 'ok'`);
page = await until(`(() => { const h = document.querySelector('main h2')?.textContent ?? ''; return h.startsWith('Job ') ? JSON.stringify({ h, hash: location.hash }) : null; })()`);
page = page && JSON.parse(page);
check(page && page.h.startsWith(`Job ${jobNames[0]} `) && /w=7d/.test(page.hash) && /[?&]job=\d+/.test(page.hash), `job node -> ${page ? page.h + ' ' + page.hash : 'no page'}`);
check(!reqs.some(u => u.startsWith('/api/tables')), 'no /api/tables read from the tree');
// the search
await ev(`(() => { const s = document.querySelector('#tree input[type=search]'); s.value = 'rds'; s.dispatchEvent(new Event('input')); return 1; })()`);
await sleep(300);
const found = await ev(`[...document.querySelectorAll('#tree .tree-inst')].map(r => ({ n: r.querySelector('a.inst').textContent, dot: !!r.querySelector('.dot') }))`);
check(found.length > 0 && found.every(x => x.n.includes('rds') && x.dot), `search rds: ${found.map(x => x.n).join(', ')}`);
await ev(`(() => { const s = document.querySelector('#tree input[type=search]'); s.value = ''; s.dispatchEvent(new Event('input')); return 1; })()`);

// ---- B. the tab links
if (wired !== '1') {
  console.log('NOT PROVEN (B): this build has no dbid in /api/tables (the lead applies the tab wiring at the join)');
} else {
  const linkCheck = async (hash, sel, want, what) => {
    await go(hash);
    const links = await until(`(() => { const a = [...document.querySelectorAll('main ${sel}')].map(x => x.getAttribute('href')); return a.length ? a : null; })()`);
    const keeps = links && links.every(h => /w=7d/.test(h));
    check(!!links && keeps, `${what}: ${links ? links.length : 0} links${keeps ? ', all keep w=7d' : ''}`);
    if (links && want) {
      const before = await ev(`document.querySelector('main h2')?.textContent ?? ''`);
      await ev(`document.querySelector('main ${sel}').click(), 'ok'`);
      // the page the link names: its hash is the link's and a new heading is drawn (the tab's own "Job report" is not it)
      const h = await until(`(() => { const h = document.querySelector('main h2')?.textContent ?? ''; return location.hash === ${JSON.stringify(links[0])} && h !== ${JSON.stringify(before)} && h.startsWith(${JSON.stringify(want)}) ? h : null; })()`);
      check(!!h, `${what}: the first opens ${h ?? 'nothing'}`);
    }
    return links;
  };
  await linkCheck(`#/tables?i=${erp.instance_id}&w=7d`, 'a[href^="#/table?"]', 'Table ', 'Tables tab');
  await linkCheck(`#/jobs?i=${crm.instance_id}&w=7d`, 'a[href^="#/job?"]', 'Job ', 'Jobs tab');
  await linkCheck(`#/jobsreport?i=${crm.instance_id}&w=7d`, 'a[href^="#/job?"]', 'Job ', 'Job report tab');
  const root = await linkCheck(`#/jobs?w=7d`, 'a[href^="#/job?"]', null, 'root Jobs page');
  if (root) check(root.every(h => /[?&]i=\d+/.test(h)), 'root Jobs links name their instance');
  await linkCheck(`#/indexes?i=${erp.instance_id}&w=7d`, 'a[href^="#/index?"]', 'Index ', 'Indexes tab');
}
ws.close();
process.exit(failed ? 1 : 0);
JS
echo "--- the tree$([[ $WIRED = 1 ]] && echo ' and the tab links')"
node "$WORK/tree.mjs" "$CDP" "$U" "$WIRED" || fail "a check failed"
if [[ $WIRED = 1 ]]; then echo "proof-tree: PASS"; else echo "proof-tree: PASS (A only; B not proven)"; fi
