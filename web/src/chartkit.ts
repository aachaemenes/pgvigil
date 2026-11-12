// The chart kit (task 182, the visual pass): what every chart of the app shares - its look read from the design tokens
// (docs/design.md: the series palette --s1..--s8, the axes in the small size and the muted text, light grid lines), the
// chart a measure takes, the empty and loading states in one shape, and the way back from a zoom. chart.ts draws with it;
// a page asks chart.ts (lineChart, donutChart, ringChart, volumeBars) and never styles a chart itself.
import type uPlot from 'uplot';
import { el } from './ui';
import { parse, rangeLabel } from './router';

// The chart a measure takes (lineChart's o.measure): a rate or a level over time is a line; a share of a whole over time
// is stacked areas, a share at one moment DBA Dash's pie or ring where Allen ordered one; a distribution over time (a
// count per step: events, runs, failures) is bars.
export type Measure = 'rate' | 'level' | 'share' | 'distribution';
export type ChartKind = 'line' | 'stacked' | 'bars';
export const chartKind = (m: Measure): ChartKind => m === 'share' ? 'stacked' : m === 'distribution' ? 'bars' : 'line';

// The look of a chart, read from the tokens at the moment it is drawn (a change of theme draws the page again)
export interface ChartLook { text: string; muted: string; grid: string; panel: string; font: string; fontSm: string }
export function chartLook(): ChartLook {
  const css = getComputedStyle(document.documentElement);
  const tok = (name: string, fallback: string) => css.getPropertyValue(name).trim() || fallback;
  const sans = tok('--font-sans', 'system-ui, sans-serif');
  return {
    text: tok('--text', '#1b2230'), muted: tok('--text-muted', '#545d6d'), grid: tok('--line', '#e0e3e9'), panel: tok('--surface-panel', '#ffffff'),
    font: `${tok('--fs-xs', '11px')} ${sans}`, fontSm: `${tok('--fs-sm', '12px')} ${sans}`,
  };
}

// An axis on the tokens: its values in the small size and the muted text, light grid lines, short ticks, and room
// between two values (space, px) so a 220 px tall chart carries about five values up its side and a 560 px wide one
// about seven along its time
export function axisLook(look: ChartLook, time = false): uPlot.Axis {
  return { stroke: look.muted, font: look.font, labelFont: look.fontSm, gap: 4, space: time ? 80 : 40,
           grid: { stroke: look.grid, width: 1 }, ticks: { stroke: look.grid, width: 1, size: 4 } };
}

// The empty and the loading state, one shape everywhere a chart stands: a box of the chart's height in the panel with
// its words in the middle. Empty says the window it looked at; loading is a status for a screen reader.
// Both carry the class 'empty' too: the proofs' settle checks wait while a p.empty says 'Loading'.
export function chartState(kind: 'empty' | 'loading', words?: string): HTMLElement {
  const text = words ?? (kind === 'loading' ? 'Loading the chart' : `No data in this window (${rangeLabel(parse())}).`);
  return el('p', { class: `chart-state ${kind} empty`, ...(kind === 'loading' ? { role: 'status' } : {}) }, text);
}
// A chart's box holding only its title and a state: the placeholder a page draws while its rows load (the screen tasks
// 185-189 adopt it)
export function chartPlaceholder(title: string, kind: 'empty' | 'loading' = 'loading', words?: string): HTMLElement {
  return el('div', { class: 'chart' }, el('h3', {}, title), chartState(kind, words));
}

// The way back from a zoom: a drag across a chart sets the page's range (the address, as before). The address before
// the first drag is kept for this tab with every address a drag led to from it (a second drag on a zoomed page keeps the
// first one's way back; the browser's Back and Forward among them keep it too), and while the page stands on one of those
// each chart's heading offers 'Reset zoom' back to the range before the first drag. A drag from any other address starts
// a new chain.
const BACK = 'pgvigil.zoomBack';
interface ZoomChain { back: string; zoomed: string[] }
function readChain(): ZoomChain | null {
  try {
    const v = JSON.parse(sessionStorage.getItem(BACK) ?? 'null') as ZoomChain | null;
    return v && typeof v.back === 'string' && Array.isArray(v.zoomed) ? v : null;
  } catch { return null; }   // storage off or a bad value
}
export function rememberZoom(to: string) {
  const dest = to.startsWith('#') ? to : '#' + to, here = location.hash || '#/';
  if (dest === here) return;   // a drag that rounds to the range already shown
  const c = readChain();
  const chain: ZoomChain = c && c.zoomed.includes(here) ? { back: c.back, zoomed: [...c.zoomed, dest].slice(-20) } : { back: here, zoomed: [dest] };
  try { sessionStorage.setItem(BACK, JSON.stringify(chain)); } catch { /* storage off: the drag still moves the range */ }
}
export function zoomBack(): string | undefined {
  const c = readChain(), here = location.hash || '#/';
  return c && c.zoomed.includes(here) && c.back !== here ? c.back : undefined;
}
export function zoomReset(): HTMLElement | null {
  const back = zoomBack();
  return back ? el('a', { class: 'chart-reset', href: back, title: 'Back to the range before the drag' }, 'Reset zoom') : null;
}
