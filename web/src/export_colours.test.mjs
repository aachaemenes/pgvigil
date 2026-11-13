// Unit tests of export_colours.ts (the colours the eye sees on an element). Node, no DOM: the module is compiled by
// esbuild (web's own) and its path given as the argument; paintOf gets stand-in elements and a stand-in style.
//   web/node_modules/.bin/esbuild web/src/export_colours.ts --format=esm --outfile=<tmp>/export_colours.mjs
//   node web/src/export_colours.test.mjs <tmp>/export_colours.mjs
// scripts/proof-export.sh runs both first. Every row prints 'ok' or 'FAIL'; the exit is 1 when any failed.
const m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
const { parseColour, over, hex, paintOf, readRows } = m;
let bad = 0, n = 0;
const eq = (what, got, want) => {
  n++;
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${g}, want ${w}`); }
};
const round = c => c && c.map((v, i) => i < 3 ? Math.round(v) : Math.round(v * 1000) / 1000);

// parseColour: what getComputedStyle writes, and hex for the tests
eq('parse rgb()', parseColour('rgb(0, 79, 131)'), [0, 79, 131, 1]);
eq('parse rgba() with a comma', parseColour('rgba(34, 89, 200, 0.14)'), [34, 89, 200, 0.14]);
eq('parse rgb() with a slash and a percent alpha', parseColour('rgb(34 89 200 / 14%)'), [34, 89, 200, 0.14]);
eq('parse a color-mix as color(srgb ...)', round(parseColour('color(srgb 0.105882 0.133333 0.188235 / 0.5)')), [27, 34, 48, 0.5]);
eq('parse color(srgb ...) without an alpha', round(parseColour('color(srgb 1 0 0.5)')), [255, 0, 128, 1]);
eq('parse transparent', parseColour('transparent'), [0, 0, 0, 0]);
eq('parse rgba(0, 0, 0, 0) (an unpainted element)', parseColour('rgba(0, 0, 0, 0)'), [0, 0, 0, 0]);
eq('parse #rgb', parseColour('#abc'), [170, 187, 204, 1]);
eq('parse #rrggbb', parseColour('#004F83'), [0, 79, 131, 1]);
eq('parse #rrggbbaa', round(parseColour('#00000080')), [0, 0, 0, 0.502]);
eq('parse an unknown space: undefined', parseColour('oklch(0.5 0.1 200)'), undefined);
eq('parse empty: undefined', parseColour(''), undefined);

// over and hex
eq('over: a solid top wins', hex(over([171, 31, 38, 1], [255, 255, 255, 1])), 'AB1F26');
eq('over: a clear top leaves what is under', hex(over([0, 0, 0, 0], [24, 27, 33, 1])), '181B21');
eq("over: the page's --select-fill rgba(34, 89, 200, .14) on white", hex(over([34, 89, 200, 0.14], [255, 255, 255, 1])), 'E0E8F7');
eq("over: the page's --hover-overlay rgba(127, 127, 127, .09) on white", hex(over([127, 127, 127, 0.09], [255, 255, 255, 1])), 'F3F3F3');
eq('over: two translucent layers', hex(over([255, 0, 0, 0.5], over([0, 0, 255, 0.5], [255, 255, 255, 1]))), 'BF4080');
eq('hex rounds and clamps', hex([255.6, -3, 127.5, 1]), 'FF0080');

// paintOf on stand-in elements: tag, class, own style, parent
const node = (tag, bg, color, parent = null, extra = {}) => ({ tagName: tag.toUpperCase(), bg, color, parentElement: parent, extra,
  closest(sel) { for (let x = this; x; x = x.parentElement) if (x.tagName === sel.toUpperCase()) return x; return null; },
  contains(o) { for (let x = o; x; x = x.parentElement) if (x === this) return true; return false; } });
const style = e => ({ backgroundColor: e.bg, color: e.color, ...e.extra });
const CLEAR = 'rgba(0, 0, 0, 0)';
const tree = (panelBg, textColour) => {
  const panel = node('div', panelBg, textColour);
  const table = node('table', CLEAR, textColour, node('div', CLEAR, textColour, panel));
  const tbody = node('tbody', CLEAR, textColour, table);
  return { panel, table, tr: node('tr', CLEAR, textColour, tbody) };
};
const L = tree('rgb(255, 255, 255)', 'rgb(27, 34, 48)');
eq('a plain cell on the light panel: no fill, the text 1B2230',
  paintOf(node('td', CLEAR, 'rgb(27, 34, 48)', L.tr), undefined, style), { text: '1B2230', under: 'FFFFFF' });
eq('a solid status cell: its fill and text',
  paintOf(node('td', 'rgb(171, 31, 38)', 'rgb(255, 255, 255)', L.tr), undefined, style), { fill: 'AB1F26', text: 'FFFFFF', under: 'FFFFFF' });
const thead = node('thead', CLEAR, 'rgb(27, 34, 48)', L.table);
eq('a header cell (base: its table)',
  paintOf(node('th', 'rgb(0, 79, 131)', 'rgb(255, 255, 255)', node('tr', CLEAR, 'rgb(27, 34, 48)', thead)), undefined, style), { fill: '004F83', text: 'FFFFFF', under: 'FFFFFF' });
const td = node('td', CLEAR, 'rgb(27, 34, 48)', L.tr);
eq("a badge in a cell: the badge's tint and text (base: the table)",
  paintOf(node('span', 'rgb(255, 241, 214)', 'rgb(154, 90, 0)', td), undefined, style), { fill: 'FFF1D6', text: '9A5A00', under: 'FFFFFF' });
eq('a link in a cell: no fill, the link colour',
  paintOf(node('a', CLEAR, 'rgb(34, 89, 200)', td), undefined, style), { text: '2259C8', under: 'FFFFFF' });
const hover = node('tr', 'rgba(127, 127, 127, 0.09)', 'rgb(27, 34, 48)', node('tbody', CLEAR, 'rgb(27, 34, 48)', L.table));
eq("a clear cell in a translucent row: the row's tint blended over the panel",
  paintOf(node('td', CLEAR, 'rgb(27, 34, 48)', hover), undefined, style), { fill: 'F3F3F3', text: '1B2230', under: 'FFFFFF' });
eq('a translucent cell text: blended over its fill',
  paintOf(node('td', 'rgb(0, 102, 56)', 'rgba(255, 255, 255, 0.5)', L.tr), undefined, style), { fill: '006638', text: '80B39C', under: 'FFFFFF' });
const D = tree('rgb(24, 27, 33)', 'rgb(227, 230, 235)');
eq('a plain cell on the dark panel: no fill, the light text',
  paintOf(node('td', CLEAR, 'rgb(227, 230, 235)', D.tr), undefined, style), { text: 'E3E6EB', under: '181B21' });
eq('a cell the colour of its section: no fill (it paints nothing of its own)',
  paintOf(node('td', 'rgb(255, 255, 255)', 'rgb(27, 34, 48)', L.tr), undefined, style), { text: '1B2230', under: 'FFFFFF' });
const tiles = node('div', CLEAR, 'rgb(27, 34, 48)', L.panel);
eq("a tile (base: its parent, the tile row): the card's fill",
  paintOf(node('div', 'rgb(246, 247, 249)', 'rgb(27, 34, 48)', tiles), undefined, style), { fill: 'F6F7F9', text: '1B2230', under: 'FFFFFF' });
eq('no painted ancestor at all: the canvas white under it',
  paintOf(node('td', CLEAR, 'rgb(0, 0, 0)', node('tr', CLEAR, 'rgb(0, 0, 0)', node('table', CLEAR, 'rgb(0, 0, 0)'))), undefined, style), { text: '000000', under: 'FFFFFF' });
eq('an explicit base of null: the canvas white is the base',
  paintOf(node('td', 'rgb(240, 241, 246)', 'rgb(0, 79, 131)', L.tr), null, style), { fill: 'F0F1F6', text: '004F83', under: 'FFFFFF' });
eq('an unreadable text colour: black',
  paintOf(node('td', CLEAR, 'oklch(0.5 0.1 200)', L.tr), undefined, style), { text: '000000', under: 'FFFFFF' });

// an ancestor's opacity: a stale part (app.css greys it at .5) blended over the group's backdrop
const { borderLeftOf, textLook } = m;
const SP = tree('rgb(255, 255, 255)', 'rgb(27, 34, 48)');
const stale = node('div', CLEAR, 'rgb(27, 34, 48)', SP.panel, { opacity: '0.5' });
const sTable = node('table', CLEAR, 'rgb(27, 34, 48)', stale), sTr = node('tr', CLEAR, 'rgb(27, 34, 48)', node('tbody', CLEAR, 'rgb(27, 34, 48)', sTable));
eq('opacity .5 on a group: a plain cell\'s text blended halfway to the backdrop, no fill (its table is faded too)',
  paintOf(node('td', CLEAR, 'rgb(27, 34, 48)', sTr), undefined, style), { text: '8D9198', under: 'FFFFFF' });
eq('opacity .5 on a group: a crit cell AB1F26 / white seen as D58F93 / FFFFFF',
  paintOf(node('td', 'rgb(171, 31, 38)', 'rgb(255, 255, 255)', sTr), undefined, style), { fill: 'D58F93', text: 'FFFFFF', under: 'FFFFFF' });
eq('opacity on the cell alone (its table not faded): the fill blended, the colour under the table as it is',
  paintOf(node('td', 'rgb(0, 102, 56)', 'rgb(255, 255, 255)', SP.tr, { opacity: '0.5' }), undefined, style), { fill: '80B39C', text: 'FFFFFF', under: 'FFFFFF' });
eq('opacity 1 everywhere: as without it',
  paintOf(node('td', 'rgb(0, 102, 56)', 'rgb(255, 255, 255)', SP.tr, { opacity: '1' }), undefined, style), { fill: '006638', text: 'FFFFFF', under: 'FFFFFF' });
// a tile's state stripe
const card = (extra) => node('div', 'rgb(246, 247, 249)', 'rgb(27, 34, 48)', SP.panel, extra);
eq("borderLeftOf: a tile's 4px solid stripe AB1F26", borderLeftOf(card({ borderLeftColor: 'rgb(171, 31, 38)', borderLeftWidth: '4px', borderLeftStyle: 'solid' }), style), 'AB1F26');
eq('borderLeftOf: no border (width 0)', borderLeftOf(card({ borderLeftColor: 'rgb(171, 31, 38)', borderLeftWidth: '0px', borderLeftStyle: 'solid' }), style), undefined);
eq('borderLeftOf: style none', borderLeftOf(card({ borderLeftColor: 'rgb(171, 31, 38)', borderLeftWidth: '4px', borderLeftStyle: 'none' }), style), undefined);
eq('borderLeftOf: a translucent stripe over the card', borderLeftOf(card({ borderLeftColor: 'rgba(0, 0, 0, 0.5)', borderLeftWidth: '3px', borderLeftStyle: 'solid' }), style), '7B7C7D');
eq('borderLeftOf: a stand-in without border properties', borderLeftOf(card({}), style), undefined);
// the text's look
const lk = (extra, parent = SP.tr) => textLook(node('span', CLEAR, 'rgb(0, 0, 0)', parent, extra), null, style);
eq('textLook: weight 700, 16px: bold, 12 pt', lk({ fontWeight: '700', fontSize: '16px' }), { bold: true, pt: 12, italic: false, underline: false });
eq('textLook: weight 600 is bold, 500 is not', [lk({ fontWeight: '600' }).bold, lk({ fontWeight: '500' }).bold], [true, false]);
eq('textLook: 13px is 10 pt (to the half point), italic', lk({ fontSize: '13px', fontStyle: 'italic' }), { bold: false, pt: 10, italic: true, underline: false });
const aLink = node('a', CLEAR, 'rgb(34, 89, 200)', SP.tr, { textDecorationLine: 'underline' });
eq("textLook: a span inside an underlined link is underlined (the link's decoration)", textLook(node('span', CLEAR, 'rgb(34, 89, 200)', aLink), null, style).underline, true);
eq('textLook: upTo itself counts (the link as upTo, two levels up)', textLook(node('span', CLEAR, 'rgb(0, 0, 0)', node('b', CLEAR, 'rgb(0, 0, 0)', aLink)), aLink, style).underline, true);
const stop = node('td', CLEAR, 'rgb(0, 0, 0)', aLink);
eq('textLook: an ancestor above upTo does not count', textLook(node('span', CLEAR, 'rgb(0, 0, 0)', stop), stop, style).underline, false);

// readRows on a stand-in DOM: a row not in the page is read inside a hidden shell set right after the grid's table in
// the grid's own parent, a batch at a time; a drawn row where it is; nothing left behind, also after a throw
class El {
  constructor(tag, attrs = {}) { this.tagName = tag.toUpperCase(); this.attrs = { ...attrs }; this.children = []; this.parentElement = null; this.props = {}; this.root = false;
    this.style = { setProperty: (k, v, p) => { this.props[k] = v + (p ? ' !' + p : ''); } }; this.ownerDocument = { createElement: t => new El(t) }; }
  get isConnected() { let x = this; while (x.parentElement) x = x.parentElement; return x.root; }
  get nextSibling() { const p = this.parentElement; return p ? p.children[p.children.indexOf(this) + 1] ?? null : null; }
  append(...ns) { for (const c of ns) { c.remove(); c.parentElement = this; this.children.push(c); } }
  insertBefore(c, ref) { c.remove(); c.parentElement = this; const i = ref ? this.children.indexOf(ref) : -1; if (i < 0) this.children.push(c); else this.children.splice(i, 0, c); }
  remove() { const p = this.parentElement; if (p) { p.children.splice(p.children.indexOf(this), 1); this.parentElement = null; } }
  cloneNode(deep) { if (deep) throw new Error('deep clone not expected'); return new El(this.tagName, this.attrs); }
  setAttribute(k, v) { this.attrs[k] = v; } removeAttribute(k) { delete this.attrs[k]; }
  querySelector(sel) { return sel === ':scope > tbody' ? this.children.find(c => c.tagName === 'TBODY') ?? null : null; }
}
const page = () => {
  const doc = new El('html'); doc.root = true;
  const wrap = new El('div', { class: 'grid-wrap' }); doc.append(wrap);
  const table = new El('table', { class: 'grid', id: 'g1', 'data-rows': '5' }), tb = new El('tbody', { class: 'b' });
  table.append(tb); wrap.append(table, new El('p', { class: 'after' }));
  const drawn = [new El('tr', { n: 'd0' }), new El('tr', { n: 'd1' })]; tb.append(...drawn);
  return { wrap, table, tb, drawn };
};
const P1 = page();
const loose = ['x0', 'x1', 'x2', 'x3', 'x4'].map(n => new El('tr', { n }));
const seen = [];
const got = readRows(P1.table, [P1.drawn[0], loose[0], P1.drawn[1], ...loose.slice(1)], tr => {
  const body = tr.parentElement, shell = body?.parentElement;
  seen.push({ n: tr.attrs.n, connected: tr.isConnected, inShell: shell !== P1.table, batch: body.children.length, shell: shell === P1.table ? null
    : { cls: shell.attrs.class, id: shell.attrs.id ?? null, hidden: shell.attrs['aria-hidden'], body: body.attrs.class, after: P1.wrap.children.indexOf(shell) === P1.wrap.children.indexOf(P1.table) + 1, props: shell.props } });
  return tr.attrs.n;
}, 2);
eq('readRows: one result per row, in the rows\' order', got, ['d0', 'x0', 'd1', 'x1', 'x2', 'x3', 'x4']);
eq('readRows: every row is in the page when it is read', seen.every(s => s.connected), true);
eq('readRows: a drawn row is read where it is (not in a shell)', seen.filter(s => !s.inShell).map(s => s.n), ['d0', 'd1']);
const sh = seen.find(s => s.inShell)?.shell;
eq("readRows: the shell is the table's own classes and attributes (no id), its tbody's class, aria-hidden, right after the table",
  sh && { cls: sh.cls, id: sh.id, hidden: sh.hidden, body: sh.body, after: sh.after }, { cls: 'grid', id: null, hidden: 'true', body: 'b', after: true });
eq('readRows: the shell is hidden and fixed out of the view (visibility changes no colour)', sh?.props,
  { visibility: 'hidden !important', position: 'fixed !important', left: '-100000px !important', top: '0 !important' });
eq('readRows: batch 2 - at most two rows in the shell at a read (2, 2, 1)', seen.filter(s => s.inShell).map(s => s.batch), [2, 2, 2, 2, 1]);
eq('readRows: after - the shell removed, the page as before (table, p.after), the drawn rows in place',
  [P1.wrap.children.map(c => c.tagName), P1.tb.children.map(c => c.attrs.n)], [['TABLE', 'P'], ['d0', 'd1']]);
eq('readRows: after - the undrawn rows detached again', loose.every(r => r.parentElement === null), true);
const P2 = page();
let threw = '';
try { readRows(P2.table, [new El('tr', { n: 'y0' })], () => { throw new Error('read failed'); }); } catch (e) { threw = e.message; }
eq('readRows: a read that throws - the error passes on, the shell is removed', [threw, P2.wrap.children.map(c => c.tagName)], ['read failed', ['TABLE', 'P']]);
const off = new El('table', { class: 'grid' }); off.append(new El('tbody'));
const offSeen = [];
eq('readRows: a table not in the page - every row read as it is, no shell', readRows(off, [new El('tr', { n: 'z0' })], tr => { offSeen.push(tr.parentElement); return tr.attrs.n; }), ['z0']);
eq('readRows: no shell was made for it', [offSeen[0], off.children.length], [null, 1]);

console.log(`${n - bad} of ${n} unit tests passed`);
process.exit(bad ? 1 : 0);
