// Unit tests of export_colours.ts (the colours the eye sees on an element). Node, no DOM: the module is compiled by
// esbuild (web's own) and its path given as the argument; paintOf gets stand-in elements and a stand-in style.
//   web/node_modules/.bin/esbuild web/src/export_colours.ts --format=esm --outfile=<tmp>/export_colours.mjs
//   node web/src/export_colours.test.mjs <tmp>/export_colours.mjs
// scripts/proof-export.sh runs both first. Every row prints 'ok' or 'FAIL'; the exit is 1 when any failed.
const m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
const { parseColour, over, hex, paintOf } = m;
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
const node = (tag, bg, color, parent = null) => ({ tagName: tag.toUpperCase(), bg, color, parentElement: parent,
  closest(sel) { for (let x = this; x; x = x.parentElement) if (x.tagName === sel.toUpperCase()) return x; return null; } });
const style = e => ({ backgroundColor: e.bg, color: e.color });
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

console.log(`${n - bad} of ${n} unit tests passed`);
process.exit(bad ? 1 : 0);
