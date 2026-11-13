// The page's charts in the workbook (E2-8): each chart's picture on the page sheet, under its line, and its numbers on a
// sheet of their own. chart.ts gives a drawn chart's box a pgvPicture (a WIRING block of the export): the chart built
// again off the page under the theme in force (the export sets the light theme around its reads, E2-16) at twice its
// CSS size with every pixel measure doubled, painted as its own menu's picture is (title, plot, threshold and limit
// lines, legend), and the numbers its menu's Export Excel writes. A box without one (chart.ts without the WIRING, a
// chart not drawn yet) keeps its line and says so.
import type { Kind } from './export';

export interface ChartNumbers { cols: string[]; rows: (string | number | Date | null)[][]; kinds?: (Kind | undefined)[] }
export interface ChartPicture {
  title: string;
  first?: number; last?: number;   // the span drawn (ms)
  series(): string[];              // the series shown, in the legend's order
  numbers(): ChartNumbers;         // as the chart's own Export Excel writes them
  // draw: the picture at `scale` times its CSS size (w x h CSS px), a PNG data URL; null when it cannot be drawn
  draw(scale: number): { png: string; w: number; h: number } | null;
}
export type PictureBox = HTMLElement & { pgvPicture?: ChartPicture };
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
export interface Placed { row: number; col: number; w: number; h: number; png: Uint8Array; name: string; descr: string }

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
