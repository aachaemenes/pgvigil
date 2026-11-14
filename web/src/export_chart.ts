// The page's charts in the workbook (E2-8): each chart's picture on the page sheet, under its line, and its numbers on a
// sheet of their own. chart.ts gives a drawn chart's box a pgvPicture (a WIRING block of the export): the chart built
// again off the page under the theme in force (the export sets the light theme around its reads, E2-16) at twice its
// CSS size with every pixel measure doubled, painted as its own menu's picture is (title, plot, threshold and limit
// lines, legend), and the numbers its menu's Export Excel writes. A box without one (chart.ts without the WIRING, a
// chart not drawn yet) keeps its line and says so.
import type { Kind } from './export';

// fmts: each column's formatter as the chart draws its values (its axis: fmtBytes, fmtSecs, a millisecond one): the
// workbook writes the column in the unit the axis shows, named in its header (export.ts chartSection)
export interface ChartNumbers { cols: string[]; rows: (string | number | Date | null)[][]; kinds?: (Kind | undefined)[]; fmts?: (((v: number) => string) | undefined)[] }
export interface ChartPicture {
  title: string;
  first?: number; last?: number;   // the span drawn (ms)
  series(): string[];              // the series shown, in the legend's order
  numbers(): ChartNumbers;         // as the chart's own Export Excel writes them
  // draw: the picture at `scale` times its CSS size (w x h CSS px), a PNG data URL; null when it cannot be drawn
  draw(scale: number): { png: string; w: number; h: number } | null;
}
// pgvNumbers: an SVG chart's numbers as its own menu's Export Excel writes them (the rings: every slice), for a chart whose
// page shows no 'numbers as a table' of its own
export type PictureBox = HTMLElement & { pgvPicture?: ChartPicture; pgvNumbers?: () => ChartNumbers };
export const pictureOf = (e: Element): ChartPicture | undefined => (e as PictureBox).pgvPicture;

// SCALE: a picture's pixels per CSS pixel (the lead 19:22, C2 (A): 2x on any screen; it cannot be redrawn by Excel)
export const SCALE = 2;
// EMU: the sheet's drawing units per CSS pixel (914,400 an inch, 96 px an inch)
export const EMU = 9525;

export function pngBytes(url: string): Uint8Array {
  const b = atob(url.slice(url.indexOf(',') + 1));
  const out = new Uint8Array(b.length);
  for (let i = 0; i < b.length; i++) out[i] = b.charCodeAt(i);
  return out;
}

// Placed: a picture on the page sheet - its anchor (the row and column of its top left corner, 0-based), its size in CSS
// px (the anchor's extent), its PNG, its name and alt text ('{sheet:k}' in it: sheet k's name, resolved by the writer)
// svg: an SVG chart's picture, its source and its background, rasterized after the page's reads (png empty until then)
export interface Placed { row: number; col: number; w: number; h: number; png: Uint8Array; name: string; descr: string; svg?: { src: string; bg: string } }

// the custom properties a chart's own SVG takes its colours from (mssql_waits.ts paletteNow: the series palette, the
// neutral), read under the screen's theme and under the light one: an SVG drawn dark is mapped colour for colour
export const THEME_COLOURS = ['--s1', '--s2', '--s3', '--s4', '--s5', '--s6', '--s7', '--s8', '--muted'];
export const themeColours = (): string[] => {
  const css = getComputedStyle(document.documentElement);
  return THEME_COLOURS.map(n => css.getPropertyValue(n).trim().toLowerCase());
};
// svgSource: an SVG chart (a page's own builder: SQL Server Waits, the rings) as a standalone picture - its CSS size,
// its words in the page's font and the light theme's text colour ('currentColor' resolved), each palette colour of the
// screen's theme as the light theme's, its hover titles left out
export function svgSource(svg: SVGSVGElement, screen: string[], light: string[]): { src: string; w: number; h: number } {
  const r = svg.getBoundingClientRect(), cs = getComputedStyle(svg);
  const c = svg.cloneNode(true) as SVGSVGElement;
  c.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
  c.setAttribute('width', String(r.width)); c.setAttribute('height', String(r.height));
  c.setAttribute('style', `font-family:${cs.fontFamily};color:${cs.color}`);
  c.querySelectorAll('title').forEach(t => t.remove());
  let s = new XMLSerializer().serializeToString(c).replace(/currentColor/g, cs.color);
  const map = new Map(screen.map((col, i) => [col, light[i]] as [string, string]).filter(([a, b]) => a && b && a !== b));
  if (map.size) s = s.replace(new RegExp([...map.keys()].map(k => k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'), 'gi'), m => map.get(m.toLowerCase()) ?? m);
  return { src: s, w: r.width, h: r.height };
}
// rasterize: an SVG source drawn at `scale` on its background, a PNG
export function rasterize(src: string, w: number, h: number, scale: number, bg: string): Promise<Uint8Array | null> {
  return new Promise(res => {
    const img = new Image();
    img.onload = () => {
      const c = document.createElement('canvas'); c.width = Math.round(w * scale); c.height = Math.round(h * scale);
      const g = c.getContext('2d');
      if (!g) { res(null); return; }
      g.fillStyle = bg; g.fillRect(0, 0, c.width, c.height); g.drawImage(img, 0, 0, c.width, c.height);
      res(pngBytes(c.toDataURL('image/png')));
    };
    img.onerror = () => res(null);
    img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(src);
  });
}

const esc = (s: string) => s.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/g, '')
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

// drawingXml: one oneCellAnchor per picture (its size in EMU whatever the column widths, E2-2), the alt text in descr
export function drawingXml(ps: Placed[]): string {
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    + '<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    + ps.map((p, i) => {
      const cx = Math.round(p.w * EMU), cy = Math.round(p.h * EMU);
      return '<xdr:oneCellAnchor>'
        + `<xdr:from><xdr:col>${p.col}</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>${p.row}</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>`
        + `<xdr:ext cx="${cx}" cy="${cy}"/>`
        + `<xdr:pic><xdr:nvPicPr><xdr:cNvPr id="${i + 2}" name="${esc(p.name)}" descr="${esc(p.descr)}"/><xdr:cNvPicPr><a:picLocks noChangeAspect="1"/></xdr:cNvPicPr></xdr:nvPicPr>`
        + `<xdr:blipFill><a:blip r:embed="rId${i + 1}"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>`
        + `<xdr:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="${cx}" cy="${cy}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic>`
        + '<xdr:clientData/></xdr:oneCellAnchor>';
    }).join('')
    + '</xdr:wsDr>';
}
// drawingRels: the drawing's pictures, image<first + i>.png in xl/media
export function drawingRels(ps: Placed[], first: number): string {
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    + ps.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image${first + i}.png"/>`).join('')
    + '</Relationships>';
}
