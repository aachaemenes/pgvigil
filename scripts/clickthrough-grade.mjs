// The click-through's grade (the pre-publish walk): the drivers' rows merged with the click map's (proof-clickmap's
// click-check.mjs JSON from the same build's run: its links are rows, not clicked again), written as JSON, as a table
// (TSV) and as a contact sheet (one HTML page: each page's shot with its rows beside it), and graded against
// scripts/clickthrough-expected.txt. Usage:
//   node scripts/clickthrough-grade.mjs <out dir> <list.json> <walk.json>... [--click <click.json>] [--shots <dir>]
//   node scripts/clickthrough-grade.mjs --self-test
// A row FAILS when its kind is one of FAIL_KINDS (a control that does NOTHING, an error box or a script error after
// it, a read answered 4xx / 5xx, a link that lands on an error or never settles, a dead link, a full reload, an off
// control with no words, a step the walk could not reach, the browser lost) or a page did not settle or drew an error
// box on load. Each FAIL is 'listed' when a row of the expected file matches it, else NEW; an expected row no FAIL
// matched is 'not seen'. Exit 0 only when no FAIL is NEW (said: 'click-through: OK (...)' / 'click-through: FAIL').
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const FAIL_KINDS = /^(NOTHING|error|js-error|api \d.*|link-error|link-stuck|dead link|reloads|off without words|not reached|browser lost|driver error|page not settled|page error|click map FAIL)$/;
// expected rows: kind | scope (root, pg, ms or *) | page (a regular expression over the page's tab, or 'tree') |
// control (a regular expression over the row's path, its steps joined by ' > ') | why, and the smallest fix and its file
export function loadExpected(text) {
  const rows = [];
  for (const [i, raw] of text.split(/\r?\n/).entries()) {
    const line = raw.trim(); if (!line || line.startsWith('#')) continue;
    const f = line.split(' | ').map(s => s.trim());
    if (f.length < 5) throw new Error(`clickthrough-expected.txt line ${i + 1}: five fields separated by ' | ' (kind | scope | page | control | why)`);
    const [kind, scope, page, control, ...why] = f;
    rows.push({ line: i + 1, kind, scope, page: new RegExp(page), control: new RegExp(control), why: why.join(' | '), pageText: page, controlText: control, hits: [] });
  }
  return rows;
}
const kindOK = (want, got) => want === got || (want === 'api' && /^api /.test(got)) || (want.endsWith('*') && got.startsWith(want.slice(0, -1)));
export function matches(e, r) { return kindOK(e.kind, r.kind) && (e.scope === '*' || e.scope === r.scope) && e.page.test(r.page) && e.control.test(r.path.join(' > ')); }
export function grade(rows, expected) {
  for (const e of expected) e.hits = [];
  const fails = rows.filter(r => FAIL_KINDS.test(r.kind));
  const outside = [];
  for (const r of fails) { const e = expected.find(x => matches(x, r)); if (e) e.hits.push(r); else outside.push(r); }
  return { fails, outside, notSeen: expected.filter(e => !e.hits.length) };
}
function selfTest() {
  const ex = loadExpected('# a comment\nNOTHING | ms | ^mssqlrisks$ | B Refresh | a button that redraws nothing | x.ts\napi | * | .* | ^A #/db | a drill read refused | y.go\nlink-error | root | ^tree$ | tree A #/rp_ | the tree | z.ts\n');
  const cases = [
    [{ kind: 'NOTHING', scope: 'ms', page: 'mssqlrisks', path: ['B Refresh'] }, true],
    [{ kind: 'NOTHING', scope: 'pg', page: 'mssqlrisks', path: ['B Refresh'] }, false],
    [{ kind: 'NOTHING', scope: 'ms', page: 'mssqlrisks2', path: ['B Refresh'] }, false],
    [{ kind: 'api 500', scope: 'pg', page: 'databases', path: ['A #/db?db&i cell #'] }, true],
    [{ kind: 'api 404', scope: 'root', page: 'summary', path: ['B Export'] }, false],
    [{ kind: 'link-error', scope: 'root', page: 'tree', path: ['tree A #/rp_finder?'] }, true],
    [{ kind: 'link', scope: 'root', page: 'tree', path: ['tree A #/rp_finder?'] }, false],
  ];
  let ok = 0;
  for (const [r, want] of cases) { const got = ex.some(e => matches(e, r)); if (got === want) ok++; else console.log(`FAIL self-test: ${JSON.stringify(r)} matched ${got}, wanted ${want}`); }
  const g = grade([{ kind: 'NOTHING', scope: 'ms', page: 'mssqlrisks', path: ['B Refresh'] }, { kind: 'dialog', scope: 'ms', page: 'x', path: ['B y'] }, { kind: 'reloads', scope: 'pg', page: 'x', path: ['B z'] }], ex);
  const gOK = g.fails.length === 2 && g.outside.length === 1 && g.notSeen.length === 2;
  if (gOK) ok++; else console.log('FAIL self-test: the grade of three rows');
  let bad = 0; try { loadExpected('NOTHING | ms | x'); } catch { bad = 1; } ok += bad; if (!bad) console.log('FAIL self-test: a short expected row was taken');
  console.log(`self-test: ${ok} of ${cases.length + 2} cases`);
  return ok === cases.length + 2;
}
const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const args = process.argv.slice(2);
  if (args[0] === '--self-test') process.exit(selfTest() ? 0 : 1);
  const take = flag => { const i = args.indexOf(flag); if (i < 0) return null; const v = args[i + 1]; args.splice(i, 2); return v; };
  const clickFile = take('--click'), shotsDir = take('--shots');
  const [outDir, listFile, ...walks] = args;
  if (!outDir || !listFile || !walks.length) { console.error('usage: node scripts/clickthrough-grade.mjs <out dir> <list.json> <walk.json>... [--click <click.json>] [--shots <dir>]'); process.exit(2); }
  const here = path.dirname(fileURLToPath(import.meta.url));
  const expected = loadExpected(fs.readFileSync(path.join(here, 'clickthrough-expected.txt'), 'utf8'));
  const list = JSON.parse(fs.readFileSync(listFile, 'utf8'));
  const pages = [], rows = [], tree = []; let seconds = 0, starts = 0;
  for (const w of walks) {
    if (!fs.existsSync(w)) { rows.push({ scope: '*', page: path.basename(w), path: ['the driver'], kind: 'driver error', why: 'its JSON was not written' }); continue; }
    const j = JSON.parse(fs.readFileSync(w, 'utf8'));
    pages.push(...j.pages); rows.push(...j.clicks.map(r => ({ ...r, source: 'walk' }))); tree.push(...j.tree.filter(r => r.kind).map(r => ({ ...r, source: 'tree' })));
    seconds = Math.max(seconds, j.seconds ?? 0); starts += j.chromeStarts ?? 0;
    if (j.seconds === undefined) rows.push({ scope: '*', page: path.basename(w), path: ['the driver'], kind: 'driver error', why: 'it did not finish (no end stamp in its JSON)' });
  }
  // a page that did not settle or drew an error box on load is a row of its own
  for (const p of pages) {
    if (!p.settled) rows.push({ scope: p.scope, page: p.tab, hash: p.hash, path: ['(the page)'], kind: 'page not settled', why: [...(p.busy || []).map(b => 'still: ' + b), ...(p.errors || [])].join(' | ') });
    else if ((p.errors || []).length || (p.api || []).length || (p.exc || []).length) rows.push({ scope: p.scope, page: p.tab, hash: p.hash, path: ['(the page)'], kind: 'page error', why: [...(p.errors || []), ...(p.api || []).map(a => a.status + ' ' + a.url), ...(p.exc || [])].join(' | ').slice(0, 300) });
  }
  const all = [...rows, ...tree];
  if (clickFile && fs.existsSync(clickFile)) {
    const c = JSON.parse(fs.readFileSync(clickFile, 'utf8'));
    for (const r of c.results ?? []) all.push({ source: 'click map', scope: /sql|ms/i.test(r.engine || '') ? 'ms' : r.engine ? 'pg' : 'root', page: 'click map ' + r.kind, path: [`${r.column || '-'} ${r.link ?? ''}`.trim()], kind: String(r.verdict).startsWith('FAIL') ? 'click map FAIL' : 'link (click map)', landing: { hash: r.href ?? '', h2: r.landed ?? '' }, why: r.verdict });
  } else if (clickFile) all.push({ source: 'click map', scope: '*', page: 'click map', path: ['click-check.mjs'], kind: 'driver error', why: 'its JSON was not written' });
  const g = grade(all, expected);
  // what happened, in words: landed where | opened what | off with which words | the write sent | NOTHING
  const said = r => r.kind === 'link' || r.kind === 'link (click map)' ? `landed ${r.landing?.hash ?? r.to ?? ''} '${r.landing?.h2 ?? r.h2 ?? ''}'`
    : r.kind === 'navigates' ? `to ${r.to ?? r.landing?.hash ?? ''} '${r.h2 ?? r.landing?.h2 ?? ''}'` : r.kind === 'dialog' ? `opened '${r.dialog}'` : r.kind === 'menu' ? `menu: ${(r.menu || []).slice(0, 8).join(', ')}`
    : r.kind === 'disabled' ? `off: ${[r.why, ...(r.off || [])].filter(Boolean).join(' | ')}` : r.kind === 'write held' ? `sent ${(r.held || []).join(', ')}` : r.kind === 'status' ? `said '${r.status}'`
    : r.kind === 'chooser' ? `file chooser (${(r.chooser || []).join(', ')})` : r.kind === 'outside' ? `outside link ${r.href}` : r.kind === 'js-dialog' ? (r.jsDialogs || []).join(' | ')
    : FAIL_KINDS.test(r.kind) ? [r.why, ...(r.errors || []), ...(r.exc || []), ...(r.api || []).map(a => a.status + ' ' + a.url), r.landing?.errors?.join(' | '), ...(r.landing?.busy || []).map(b => 'still: ' + b)].filter(Boolean).join(' | ').slice(0, 300) : '';
  fs.mkdirSync(outDir, { recursive: true });
  const tsvCell = s => String(s ?? '').replace(/[\t\r\n]+/g, ' ');
  const tsv = ['source\tscope\tpage\tcontrol\tkind\twhat happened\tgrade', ...all.map(r => [r.source, r.scope, r.page, r.path.join(' > '), r.kind, said(r), FAIL_KINDS.test(r.kind) ? (g.outside.includes(r) ? 'NEW' : 'listed') : ''].map(tsvCell).join('\t'))];
  fs.writeFileSync(path.join(outDir, 'clickthrough.tsv'), tsv.join('\n') + '\n');
  fs.writeFileSync(path.join(outDir, 'clickthrough.json'), JSON.stringify({ list: { pg: list.pg, ms: list.ms, pooler: list.pooler, notes: list.notes }, pages, rows: all.map(r => ({ ...r, said: said(r), grade: FAIL_KINDS.test(r.kind) ? (g.outside.includes(r) ? 'NEW' : 'listed') : 'ok' })), notSeen: g.notSeen.map(e => ({ line: e.line, kind: e.kind, scope: e.scope, page: e.pageText, control: e.controlText })) }, null, 1));
  // the contact sheet: each page's shot (light), its rows beside it; the FAIL rows first
  const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
  const sheet = [`<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Click-through contact sheet</title><style>body{font:13px system-ui,sans-serif;margin:16px;background:#fff;color:#111}section{display:grid;grid-template-columns:minmax(0,560px) 1fr;gap:12px;border-top:1px solid #ccc;padding:10px 0}img{width:100%;border:1px solid #ddd}table{border-collapse:collapse;width:100%}td{border-bottom:1px solid #eee;padding:2px 4px;vertical-align:top}tr.fail td{background:#fde8e8}h2{font-size:14px;margin:0 0 4px}</style></head><body>`,
    `<h1>Click-through: ${pages.length} pages, ${all.length} rows, ${g.fails.length} FAIL (${g.outside.length} NEW)</h1>`];
  for (const p of pages) {
    const mine = all.filter(r => r.hash === p.hash && r.scope === p.scope).sort((x, y) => Number(FAIL_KINDS.test(y.kind)) - Number(FAIL_KINDS.test(x.kind)));
    const img = p.shot && shotsDir ? `<img alt="${esc(p.hash)}" src="${esc(path.relative(outDir, path.join(shotsDir, p.shot + '.png')))}">` : '<p>(no shot)</p>';
    sheet.push(`<section><div><h2>${esc(p.scope)} ${esc(p.hash)}</h2>${img}</div><table>${mine.map(r => `<tr class="${FAIL_KINDS.test(r.kind) ? 'fail' : ''}"><td>${esc(r.path.join(' > '))}</td><td>${esc(r.kind)}</td><td>${esc(said(r))}</td></tr>`).join('')}</table></section>`);
  }
  const treeRows = all.filter(r => r.source === 'tree');
  sheet.push(`<section><div><h2>the tree</h2></div><table>${treeRows.map(r => `<tr class="${FAIL_KINDS.test(r.kind) ? 'fail' : ''}"><td>${esc(r.scope)} ${esc(r.path.join(' > '))}</td><td>${esc(r.kind)}</td><td>${esc(said(r))}</td></tr>`).join('')}</table></section></body></html>`);
  fs.writeFileSync(path.join(outDir, 'contact.html'), sheet.join('\n'));
  // the summary
  const count = s => pages.filter(p => p.scope === s).length;
  const kinds = new Map(); for (const r of all) kinds.set(r.kind, (kinds.get(r.kind) ?? 0) + 1);
  console.log(`picked: PostgreSQL ${list.pg}${list.pooler ? ' (the Pooler of ' + list.pooler + ')' : ''}, SQL Server ${list.ms}`);
  console.log(`pages: ${pages.length} (root ${count('root')}, pg ${count('pg')}, ms ${count('ms')}), ${pages.filter(p => !p.settled).length} not settled, ${pages.filter(p => p.capped).length} over the cap (${pages.reduce((a, p) => a + (p.capped ?? 0), 0)} controls not clicked); the longest driver ${seconds} s; chromium started ${starts} time(s)`);
  console.log(`rows: ${all.length} (walk ${rows.length}, tree ${tree.length}, click map ${all.filter(r => r.source === 'click map').length}); by kind: ${[...kinds.entries()].sort((a, b) => b[1] - a[1]).map(([k, n]) => `${k} ${n}`).join(', ')}`);
  const distinct = new Map();
  for (const r of g.outside) { const k = [r.scope, r.page, r.kind, r.path.join(' > ')].join('\u0001'); if (!distinct.has(k)) distinct.set(k, r); }
  for (const r of distinct.values()) console.log(`NEW ${r.kind} ${r.scope} ${r.page} ${JSON.stringify(r.path.join(' > ').slice(0, 160))}: ${said(r).slice(0, 200)}`);
  for (const e of expected) console.log(`${e.hits.length ? 'listed' : 'not seen'} ${e.kind} ${e.scope} ${e.pageText} ${e.controlText}: ${e.hits.length} row(s); ${e.why}`);
  for (const n of list.notes ?? []) console.log('note: ' + n);
  console.log('not clicked by design: the text boxes (a search, a form field); another instance\'s tree leaves (the same renderers as the picked instance\'s); the tag folders\' other copies of an instance');
  const bad = [distinct.size && `${distinct.size} FAIL row(s) outside the expected file`].filter(Boolean);
  console.log(bad.length ? `click-through: FAIL (${bad.join('; ')})` : `click-through: OK (${g.fails.length} FAIL row(s), each listed; ${g.notSeen.length} expected row(s) not seen)`);
  process.exit(bad.length ? 1 : 0);
}
