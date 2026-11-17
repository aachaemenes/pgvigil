// The Azure resource charts' toolbar (P25 task 10, sweep L135: DBA Dash's Azure DB and Pool charts' Date Grouping and
// Columns per chart) on the instance's Azure tab (azuredb.ts) and its Elastic pool page (pools.ts). Date Grouping picks
// the read the charts and the grid draw: auto keeps the page's own rule (minutes up to a day, hours past it), minute,
// hour or day (/api/mssql/azuredb and /api/mssql/pool parts minutes / hours / days); Columns per chart lays the charts
// one, two or three a row. The page's range and its refresh stay the page's; Smooth lines and Points are chart.ts's
// options (its owner's file: a join line). The choice is this browser's (localStorage, kept per page).
import { Row } from './api';
import { el } from './ui';

export type Grouping = 'auto' | 'minute' | 'hour' | 'day';
export interface ChartChoice { grouping: Grouping; columns: number }

const groupings: [Grouping, string][] = [['auto', 'Auto'], ['minute', 'Minute'], ['hour', 'Hour'], ['day', 'Day']];
const columnChoices = [1, 2, 3];

function lsGet(k: string): string | null { try { return localStorage.getItem(k); } catch { return null; } }
function lsSet(k: string, v: string) { try { localStorage.setItem(k, v); } catch { /* private window */ } }

// chartChoice: the page's saved choice, else auto and two charts a row
export function chartChoice(page: string): ChartChoice {
  try {
    const v = JSON.parse(lsGet(`pgvigil.azureCharts.${page}`) ?? '{}') as Partial<ChartChoice>;
    return {
      grouping: groupings.some(g => g[0] === v.grouping) ? v.grouping as Grouping : 'auto',
      columns: columnChoices.includes(Number(v.columns)) ? Number(v.columns) : 2,
    };
  } catch { return { grouping: 'auto', columns: 2 }; }
}

// pickRows: the rows a grouping draws (auto: hours past a day of minutes, else the minutes), and its words
export function pickRows(g: Grouping, parts: { minutes: Row[]; hours: Row[]; days: Row[] }, longWindow: boolean): { rows: Row[]; unit: 'minute' | 'hour' | 'day' } {
  const unit = g === 'auto' ? (longWindow ? 'hour' : 'minute') : g;
  return { rows: unit === 'day' ? parts.days : unit === 'hour' ? parts.hours : parts.minutes, unit };
}

// layout: the charts' box, at most the chosen number of charts a row - each track is a row's share of the box and
// never under 320px (the whole box when it is narrower), so a narrow page wraps to fewer a row instead of squeezing
// them (review t11-3 SHOULD 3); the gap is the house token
export function layout(box: HTMLElement, columns: number): HTMLElement {
  box.style.display = 'grid';
  box.style.gap = 'var(--sp-4)';
  box.style.gridTemplateColumns = `repeat(auto-fill, minmax(min(100%, max(320px, calc((100% - ${columns - 1} * var(--sp-4)) / ${columns}))), 1fr))`;
  return box;
}

// chartToolbar: the two pickers, labelled; a change is saved for the page and handed to redraw
export function chartToolbar(page: string, redraw: (c: ChartChoice) => void): HTMLElement {
  const cur = chartChoice(page);
  const pick = (id: string, label: string, options: [string, string][], value: string, set: (v: string) => void) => {
    const sel = el('select', { id }, ...options.map(([v, t]) => el('option', { value: v, ...(v === value ? { selected: 'selected' } : {}) }, t))) as HTMLSelectElement;
    sel.addEventListener('change', () => set(sel.value));
    return el('label', { style: 'margin-right:1rem' }, `${label} `, sel);
  };
  const save = () => { lsSet(`pgvigil.azureCharts.${page}`, JSON.stringify(cur)); redraw({ ...cur }); };
  return el('div', { class: 'toolbar', role: 'group', 'aria-label': 'Chart options' },
    pick(`${page}-grouping`, 'Date Grouping', groupings, cur.grouping, v => { cur.grouping = v as Grouping; save(); }),
    pick(`${page}-columns`, 'Columns per chart', columnChoices.map(n => [String(n), String(n)] as [string, string]), String(cur.columns), v => { cur.columns = Number(v); save(); }));
}
