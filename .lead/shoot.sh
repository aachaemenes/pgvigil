#!/usr/bin/env bash
# One-off (not part of the repository): serve the demo, open one PostgreSQL instance's Configuration page in both
# themes with a headless Chromium and save the two pictures under .lead/out/.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_shot_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""
cleanup() {
  [[ -n "$CHR" ]] && kill -- -"$CHR" 2>/dev/null || true
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p .lead/out
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
"$WORK/pgvigil" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 900); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { cat "$WORK/demo.log"; exit 1; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { echo "FAIL: the demo did not come up"; exit 1; }
# the instance with the most deviating settings, so both colours are in the picture
ID=$(psql "$PGVIGIL_ADMIN_DSN dbname=$DB" -XAtq -c "SELECT i.instance_id FROM (SELECT DISTINCT instance_id FROM pgvigil.setting_rules) i, pgvigil.pg_setting_rules(i.instance_id) r GROUP BY 1 ORDER BY count(*) FILTER (WHERE r.status = 'crit') DESC, count(*) FILTER (WHERE r.status = 'warn') DESC, 1 LIMIT 1")
psql "$PGVIGIL_ADMIN_DSN dbname=$DB" -XAtq -c "SELECT status, count(*) FROM pgvigil.pg_setting_rules($ID) GROUP BY 1 ORDER BY 1" | tr '\n' ' '; echo " <- instance $ID"
setsid chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu --window-size=1600,1400 about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null && break; sleep 0.5; done
cat > "$WORK/shoot.mjs" <<'JS'
const [cdp, base, id, out] = process.argv.slice(2);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${cdp}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let n = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++n; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => (await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true })).result?.result?.value;
const sleep = ms => new Promise(r => setTimeout(r, ms));
for (const theme of ['light', 'dark']) {
  await cmd('Page.navigate', { url: `${base}#/config?i=${id}` }); await sleep(1500);
  await ev(`localStorage.setItem('pgvigil.theme', '${theme}'); document.documentElement.setAttribute('data-theme', '${theme}')`);
  for (let t = 0; t < 40 && !(await ev(`[...document.querySelectorAll('main h3')].some(h => h.textContent === 'Best practice')`)); t++) await sleep(250);
  const info = await ev(`(() => { const h = [...document.querySelectorAll('main h3')].find(x => x.textContent === 'Best practice'); if (!h) return 'NO Best practice heading; h3s: ' + [...document.querySelectorAll('main h3')].map(x => x.textContent).join(' | ');
    h.scrollIntoView(); const t = h.parentElement.querySelector('table.grid'); const c = k => t.querySelectorAll('td.status.' + k).length;
    const bg = k => { const e = t.querySelector('td.status.' + k); return e ? getComputedStyle(e).backgroundColor : '-'; };
    return 'rows ' + t.querySelectorAll('tbody tr').length + '; cells ok ' + c('ok') + ' ' + bg('ok') + ', warn ' + c('warn') + ' ' + bg('warn') + ', crit ' + c('crit') + ' ' + bg('crit') + ', none ' + c('none') + ' ' + bg('none') + '; meta: ' + h.nextElementSibling.textContent.slice(0, 120); })()`);
  console.log(theme + ': ' + info);
  await sleep(400);
  const shot = await cmd('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(`${out}/pgbest-config-${theme}.png`, Buffer.from(shot.result.data, 'base64'));
}
ws.close();
JS
node "$WORK/shoot.mjs" "$CDP" "http://127.0.0.1:$PORT/" "$ID" .lead/out
ls -la .lead/out
