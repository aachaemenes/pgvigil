#!/usr/bin/env node
// Unit rows of the View control for web/src/router.ts (the design's 'Unit: router parse / href' rows): the page keys a
// saved view stores ride the address and are read at href time; own=1 rides the links between the pages that hide
// pgvigil's own sessions. pgvigil has no web unit runner: this bundles router.ts with the web tree's own esbuild into a
// temporary file and runs it under Node with a minimal location / history / window. The gridtools layer needs a DOM and
// is covered by proof-view-control's browser cases (W1-W8).
//
// Run from the repository root after 'npm ci' in web/:  node scripts/view-control-unit.mjs
//
// Expected (written before the first run):
//   U1 parse: '#/slowqueries?w=24h&ms=500&g=text&top=all&fit=1&view=7' -> the fleet's slowqueries, ms 500, no instance
//   U2 href to the same page keeps g, top, fit, view (from the address) and ms, w
//   U3 href to another tab drops g, gdb, top, ev, fit and view
//   U4 an instance's mssql_slow keeps g, gdb, ev on its own links; another instance drops them
//   U5 noteAddress (a replaceState) then href: the link carries the noted top=1000, not the parsed 50; a key noted '' leaves
//   U6 own=1: parsed on activity; kept to waiting on the same instance; dropped to another instance, to a tab that does
//      not hide own sessions, and when the link says own undefined
//   U7 the Summary keeps focus, tests, tmax, sort and view=none on its own links
//   U8 pageKeyOf names root:<tab> and instance:<tab>; viewPageKeys lists the five pages
//   U9 own=1 on a tab that does not hide own sessions parses as unset
// Exit 0 when every row passes; 1 with each failing row printed.
import { createRequire } from 'node:module';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = resolve(process.cwd());
const req = createRequire(join(root, 'web', 'package.json'));
const esbuild = req('esbuild');
const dir = mkdtempSync(join(tmpdir(), 'view-control-unit-'));
const out = join(dir, 'router.mjs');
await esbuild.build({ entryPoints: [join(root, 'web', 'src', 'router.ts')], bundle: true, format: 'esm', platform: 'neutral', outfile: out, logLevel: 'error' });

// the browser's globals router.ts touches
globalThis.location = { hash: '', pathname: '/', search: '' };
globalThis.history = { replaceState: (_s, _t, url) => { const i = String(url).indexOf('#'); globalThis.location.hash = i >= 0 ? String(url).slice(i) : ''; } };
let addressEvents = 0;
globalThis.window = { dispatchEvent: () => { addressEvents++; return true; } };
if (typeof globalThis.CustomEvent === 'undefined') globalThis.CustomEvent = class { constructor(type) { this.type = type; } };

const r = await import(pathToFileURL(out).href);
rmSync(dir, { recursive: true, force: true });

let failed = 0;
const row = (name, ok, got) => { if (ok) console.log(`ok   ${name}`); else { failed++; console.log(`FAIL ${name}: ${got}`); } };
const at = h => { globalThis.location.hash = h; return r.parse(); };
const keys = link => new URLSearchParams(String(link).split('?')[1] ?? '');
const has = (q, pairs) => Object.entries(pairs).every(([k, v]) => q.get(k) === v);
const none = (q, ks) => ks.every(k => !q.has(k));

{
  const c = at('#/slowqueries?w=24h&ms=500&g=text&top=all&fit=1&view=7');
  row('U1 parse slowqueries', c.tab === 'slowqueries' && c.ms === 500 && c.instance === undefined, JSON.stringify({ tab: c.tab, ms: c.ms, i: c.instance }));
  const q = keys(r.href(c, { tab: 'slowqueries' }));
  row('U2 same page keeps its keys', has(q, { g: 'text', top: 'all', fit: '1', view: '7', ms: '500', w: '24h' }), q.toString());
  const o = keys(r.href(c, { tab: 'summary' }));
  row('U3 another tab drops them', none(o, ['g', 'gdb', 'top', 'ev', 'fit', 'view']), o.toString());
}
{
  const c = at('#/mssql_slow?i=3&g=database&gdb=sales&ev=all&view=4');
  const q = keys(r.href(c, { tab: 'mssql_slow' }));
  const o = keys(r.href(c, { tab: 'mssql_slow', instance: 4 }));
  row('U4 instance page keeps, another instance drops', c.instance === 3 && has(q, { i: '3', g: 'database', gdb: 'sales', ev: 'all', view: '4' }) && none(o, ['g', 'gdb', 'ev', 'view']) && o.get('i') === '4', `${q} | ${o}`);
}
{
  const c = at('#/slowqueries?w=1h&top=50&fit=1');
  const before = addressEvents;
  r.noteAddress({ top: '1000', fit: '' });
  const q = keys(r.href(c, { tab: 'slowqueries' }));
  row('U5 noteAddress then href', q.get('top') === '1000' && !q.has('fit') && addressEvents === before + 1 && globalThis.location.hash.startsWith('#/slowqueries?'), `${q} hash=${globalThis.location.hash} events=${addressEvents - before}`);
}
{
  const c = at('#/activity?i=2&own=1');
  const w = keys(r.href(c, { tab: 'waiting' }));
  const other = keys(r.href(c, { tab: 'waiting', instance: 5 }));
  const stm = keys(r.href(c, { tab: 'statements' }));
  const off = keys(r.href(c, { tab: 'activity', own: undefined }));
  row('U6 own rides the own pages of one instance', c.own === true && w.get('own') === '1' && !other.has('own') && !stm.has('own') && !off.has('own'), `parsed=${c.own} waiting=${w} other=${other} statements=${stm} off=${off}`);
}
{
  const c = at('#/summary?focus=1&tests=0&tmax=50&sort=name&view=none');
  const q = keys(r.href(c, { tab: 'summary' }));
  row('U7 the Summary keeps its keys and view=none', has(q, { focus: '1', tests: '0', tmax: '50', sort: 'name', view: 'none' }), q.toString());
}
{
  const want = ['root:summary', 'root:perfsummary', 'root:slowqueries', 'instance:slowqueries', 'instance:mssql_slow'];
  const got = Object.keys(r.viewPageKeys).sort().join(',');
  row('U8 pageKeyOf and the five view pages', r.pageKeyOf({ tab: 'slowqueries', instance: 3 }) === 'instance:slowqueries' && r.pageKeyOf({ tab: 'summary' }) === 'root:summary' && got === [...want].sort().join(','), got);
}
{
  const c = at('#/statements?i=2&own=1');
  row('U9 own on another tab parses unset', c.own === undefined, String(c.own));
}
console.log(failed ? `view-control-unit: ${failed} FAILED` : 'view-control-unit: PASS');
process.exit(failed ? 1 : 0);
