// The chart kit (task 182, the visual pass): what every chart of the app shares - its look read from the design tokens
// (docs/design.md: the series palette --s1..--s8, the axes in the small size and the muted text, light grid lines), the
// chart a measure takes, the empty and loading states in one shape, and the way back from a zoom. chart.ts draws with it;
// a page asks chart.ts (lineChart, donutChart, ringChart, volumeBars) and never styles a chart itself.
import type uPlot from 'uplot';
import { el } from './ui';
import { parse, rangeLabel } from './router';

// The chart a measure takes: a rate or a level over time is a line (one series may fill as an area); a share of a whole
// over time is stacked areas, a share at one moment DBA Dash's pie or ring where Allen ordered one; a distribution is bars.
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
export function chartState(kind: 'empty' | 'loading', words?: string): HTMLElement {
  const text = words ?? (kind === 'loading' ? 'Loading the chart' : `No data in this window (${rangeLabel(parse())}).`);
  return el('p', { class: 'chart-state ' + kind, ...(kind === 'loading' ? { role: 'status' } : {}) }, text);
}
// A chart's box holding only its title and a state: the placeholder a page draws while its rows load
export function chartPlaceholder(title: string, kind: 'empty' | 'loading' = 'loading', words?: string): HTMLElement {
  return el('div', { class: 'chart' }, el('h3', {}, title), chartState(kind, words));
}

// The way back from a zoom: a drag across a chart sets the page's range (the address, as before); the address it left
// is kept for this tab, and while the page stands on the zoomed address each chart's heading offers 'Reset zoom' back
// to it. Another address (a new page, a preset picked) forgets it.
const BACK = 'pgvigil.zoomBack';
export function rememberZoom(to: string) {
  try { sessionStorage.setItem(BACK, JSON.stringify({ back: location.hash, to: to.startsWith('#') ? to : '#' + to })); } catch { /* storage off */ }
}
export function zoomBack(): string | undefined {
  try {
    const v = JSON.parse(sessionStorage.getItem(BACK) ?? 'null') as { back?: string; to?: string } | null;
    if (v?.back && v.to === location.hash) return v.back;
    if (v) sessionStorage.removeItem(BACK);
  } catch { /* storage off or a bad value */ }
  return undefined;
}
export function zoomReset(): HTMLElement | null {
  const back = zoomBack();
  return back ? el('a', { class: 'chart-reset', href: back, title: 'Back to the range before the drag' }, 'Reset zoom') : null;
}
