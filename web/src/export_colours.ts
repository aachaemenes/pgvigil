// The colours the eye sees on an element, read from the page itself (getComputedStyle), for the export: a cell of the
// workbook takes the fill and the text colour its element shows on the screen, as DBA Dash's export copies each cell's
// own screen fore and back colour (CommonShared.cs). No import: the unit tests load this module alone
// (export_colours.test.mjs).
//
// paintOf(e, base): e's fill and text colour as hex 'RRGGBB'.
//   - the backgrounds of e and of its ancestors are laid one over the other (source-over), from the nearest one that
//     paints solid (alpha 1) down to e; with none, the canvas's white is under them all. A translucent layer (an rgba
//     hover tint, a color-mix) is so blended over what lies under it, as the screen blends it;
//   - fill: that colour, or undefined when it equals the colour under `base` (the element's section: a grid's table,
//     a tile row): the element paints nothing of its own over its section, so the file leaves its cell unfilled;
//   - text: e's text colour blended over the fill (or over the colour under base when it has none);
//   - under: the colour under base (what an unfilled cell shows).
// base defaults to the nearest table above e, else e's parent.

export type Rgba = [number, number, number, number];   // red, green, blue 0..255; alpha 0..1

// parseColour: a CSS colour as getComputedStyle writes it - 'rgb(r, g, b)', 'rgba(r, g, b, a)', a color-mix's or a
// color()'s 'color(srgb r g b / a)' (0..1 each), 'transparent' - and '#rgb', '#rrggbb', '#rrggbbaa' for the tests;
// anything else undefined (a colour space the page does not use: oklch, display-p3)
export function parseColour(s: string | null | undefined): Rgba | undefined {
  const t = (s ?? '').trim().toLowerCase();
  if (t === '') return undefined;
  if (t === 'transparent') return [0, 0, 0, 0];
  let m = /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)\s*(?:[,/]\s*([\d.]+)(%)?\s*)?\)$/.exec(t);
  if (m) return [Number(m[1]), Number(m[2]), Number(m[3]), m[4] === undefined ? 1 : Number(m[4]) / (m[5] ? 100 : 1)];
  m = /^color\(\s*srgb\s+([\d.e+-]+)\s+([\d.e+-]+)\s+([\d.e+-]+)\s*(?:\/\s*([\d.]+)(%)?\s*)?\)$/.exec(t);
  if (m) return [Number(m[1]) * 255, Number(m[2]) * 255, Number(m[3]) * 255, m[4] === undefined ? 1 : Number(m[4]) / (m[5] ? 100 : 1)];
  m = /^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/.exec(t);
  if (m) {
    const h = m[1].length === 3 ? [...m[1]].map(c => c + c).join('') : m[1];
    return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16), h.length === 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1];
  }
  return undefined;
}

// over: the colour `top` shows laid over `under` (source-over compositing)
export function over(top: Rgba, under: Rgba): Rgba {
  const a = top[3] + under[3] * (1 - top[3]);
  if (a === 0) return [0, 0, 0, 0];
  const ch = (i: number) => (top[i] * top[3] + under[i] * under[3] * (1 - top[3])) / a;
  return [ch(0), ch(1), ch(2), a];
}

// hex: 'RRGGBB' of a colour (its channels rounded; the alpha is dropped: callers blend onto a solid colour first)
export function hex(c: Rgba): string {
  return c.slice(0, 3).map(v => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0')).join('').toUpperCase();
}

export interface Painted { fill?: string; text: string; under: string }
// the properties read from a computed style (getComputedStyle's own; a test passes a stand-in, which may leave out all
// but the two colours: a missing opacity is 1, a missing border none, a missing weight normal)
export interface Computed {
  backgroundColor: string; color: string; opacity?: string;
  borderLeftColor?: string; borderLeftWidth?: string; borderLeftStyle?: string;
  fontWeight?: string; fontSize?: string; fontStyle?: string; textDecorationLine?: string;
}
export type StyleOf = (e: Element) => Computed;
const WHITE: Rgba = [255, 255, 255, 1];
const computed: StyleOf = e => getComputedStyle(e);

// stacked: the colour shown at e: its background and its ancestors' laid over each other, from the nearest solid one
function stacked(e: Element | null, style: StyleOf): Rgba {
  const layers: Rgba[] = [];
  for (let x = e; x; x = x.parentElement) {
    const c = parseColour(style(x).backgroundColor);
    if (!c || c[3] === 0) continue;
    layers.push(c);
    if (c[3] >= 1) break;
  }
  return layers.reduceRight((under, top) => over(top, under), WHITE);
}

// faded: the group an element is painted in at an opacity under 1 (a stale part: app.css greys it): the product of the
// opacities of the element and its ancestors, and the outermost ancestor so faded (the group's backdrop is what lies
// under it). None faded: undefined.
function faded(e: Element, style: StyleOf): { op: number; top: Element } | undefined {
  let op = 1, top: Element | undefined;
  for (let x: Element | null = e; x; x = x.parentElement) {
    const o = Number(style(x).opacity ?? '1');
    if (isFinite(o) && o < 1) { op *= o; top = x; }
  }
  return top ? { op, top } : undefined;
}

// paintOf: e's fill and text colour as the page's own CSS paints them (see the head of this file); an element inside a
// faded group (an ancestor's opacity under 1) is blended at that opacity over the group's backdrop, its fill, its text
// and, when its base is in the group too, the colour under the base
export function paintOf(e: Element, base?: Element | null, style: StyleOf = computed): Painted {
  const b = base === undefined ? (e.parentElement?.closest('table') ?? e.parentElement) : base;
  let at = stacked(e, style), under = b ? stacked(b, style) : WHITE;
  const t0 = parseColour(style(e).color) ?? [0, 0, 0, 1];
  let text = over(t0, at);
  const f = faded(e, style);
  if (f) {
    const back = stacked(f.top.parentElement, style);
    const seen = (c: Rgba): Rgba => over([c[0], c[1], c[2], f.op], back);
    at = seen(at); text = seen(text);
    if (b && (f.top === b || f.top.contains(b))) under = seen(under);
  }
  const fill = hex(at) === hex(under) ? undefined : hex(at);
  return { fill, text: hex(text), under: hex(under) };
}

// borderLeftOf: e's left border colour as painted (a tile's state stripe), over e's own colour; none drawn = undefined
export function borderLeftOf(e: Element, style: StyleOf = computed): string | undefined {
  const s = style(e);
  const w = parseFloat(s.borderLeftWidth ?? '0'), kind = s.borderLeftStyle ?? 'none';
  if (!(w > 0) || kind === 'none' || kind === 'hidden') return undefined;
  const c = parseColour(s.borderLeftColor);
  if (!c || c[3] === 0) return undefined;
  return hex(over(c, stacked(e, style)));
}

// textLook: the weight, size (points), slant and underline of e's text as the page draws it. The underline is the
// element's own text-decoration or an ancestor's up to `upTo` (a decoration is drawn through the descendants' text)
export function textLook(e: Element, upTo: Element | null = null, style: StyleOf = computed): { bold: boolean; pt?: number; italic: boolean; underline: boolean } {
  const s = style(e);
  const w = s.fontWeight === 'bold' ? 700 : Number(s.fontWeight ?? '400');
  const px = parseFloat(s.fontSize ?? '');
  let underline = false;
  for (let x: Element | null = e; x; x = x.parentElement) {
    if ((style(x).textDecorationLine ?? '').includes('underline')) { underline = true; break; }
    if (x === upTo) break;
  }
  return { bold: w >= 600, pt: isFinite(px) && px > 0 ? Math.round(px * 0.75 * 2) / 2 : undefined, italic: s.fontStyle === 'italic', underline };
}

// readRows: what `read` gives for each row of a grid, the rows the screen does not draw included. Past its page a grid
// draws no row (ui.ts GRID_PAGE), and ui.ts's allRows() builds those rows detached (the same classes and content as a
// drawn row); a detached element has no computed style. A row not in the page is so read in a shell: an empty copy of
// the grid's table (its own classes and attributes) set right after the table in the grid's own parent - the same
// ancestors, so every rule that colours a drawn cell applies to it - hidden (visibility hidden changes no colour) and
// fixed out of the view (no scroll, no shift of the page), `batch` rows at a time, each batch taken out after its read;
// the shell is removed at the end, also when `read` throws. A row in the page (a drawn row) is read where it is. All in
// one task: nothing is painted with the shell in the page. A table with no parent (itself not in the page) reads
// every row as it is.
export function readRows<T>(table: Element, rows: Element[], read: (tr: Element) => T, batch = 200): T[] {
  const parent = table.parentElement;
  if (!parent || !table.isConnected) return rows.map(read);
  let shell: HTMLElement | null = null, body: Element | null = null;
  const out: T[] = new Array(rows.length);
  try {
    const away: number[] = [];
    rows.forEach((tr, i) => { if (tr.isConnected) out[i] = read(tr); else away.push(i); });
    for (let k = 0; k < away.length; k += Math.max(1, batch)) {
      if (!shell) {
        shell = table.cloneNode(false) as HTMLElement;
        shell.removeAttribute('id');
        shell.setAttribute('aria-hidden', 'true');
        shell.style.setProperty('visibility', 'hidden', 'important');
        shell.style.setProperty('position', 'fixed', 'important');
        shell.style.setProperty('left', '-100000px', 'important');
        shell.style.setProperty('top', '0', 'important');
        body = (table.querySelector(':scope > tbody')?.cloneNode(false) as Element | undefined) ?? table.ownerDocument.createElement('tbody');
        shell.append(body);
        parent.insertBefore(shell, table.nextSibling);
      }
      const part = away.slice(k, k + Math.max(1, batch));
      body!.append(...part.map(i => rows[i]));
      try { for (const i of part) out[i] = read(rows[i]); } finally { for (const i of part) rows[i].remove(); }
    }
  } finally {
    (shell as HTMLElement | null)?.remove();
  }
  return out;
}
