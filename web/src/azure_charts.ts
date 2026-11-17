// The Azure resource charts' toolbar (P25 task 10, sweep L135: DBA Dash's Azure DB and Pool charts' Date Grouping and
// Columns per chart) on the instance's Azure tab (azuredb.ts) and its Elastic pool page (pools.ts). Date Grouping picks
// the read the charts and the grid draw: auto keeps the page's own rule (minutes up to a day, hours past it), minute,
// hour or day (/api/mssql/azuredb and /api/mssql/pool parts minutes / hours / days); Columns per chart lays the charts
// one, two or three a row. The page's range and its refresh stay the page's; Smooth lines and Points are chart.ts's
// options (its owner's file: a join line). The choice is this browser's (localStorage, kept per page).
import { Row } from './api';
import { lineChart } from './chart';
import { el, fmtNum } from './ui';

// a grouping: auto, minute, hour, day (the pages' own parts) or one of DBA Dash's other steps in minutes (part=grouped)
export type Grouping = string;
export interface ChartChoice { grouping: Grouping; columns: number; measures?: string[] }

// a chart measure: its column in the reads, DBA Dash's words, its axis, whether DBA Dash shows it by default, and why it
// is not offered yet (unread: a measure pgvigil does not store yet - its row named)
export interface Measure { key: string; label: string; axis: 'Percent' | 'DTU'; shown?: true; unread?: string }

// DBA Dash's Azure DB chart's measures in its order and words (AzureDBResourceStats.cs DBColumns L72-93; control audit A2)
export const dbMeasures: Measure[] = [
  { key: 'avg_cpu_percent', label: 'Avg CPU %', axis: 'Percent' }, { key: 'avg_data_io_percent', label: 'Avg Data %', axis: 'Percent' },
  { key: 'avg_log_write_percent', label: 'Avg Log Write %', axis: 'Percent' }, { key: 'avg_dtu_percent', label: 'Avg DTU %', axis: 'Percent' },
  { key: 'avg_memory_usage_percent', label: 'Avg Memory %', axis: 'Percent' }, { key: 'xtp_storage_percent', label: 'XTP Storage %', axis: 'Percent' },
  { key: 'avg_instance_cpu_percent', label: 'Avg CPU % (Instance)', axis: 'Percent' }, { key: 'avg_instance_memory_percent', label: 'Avg Memory % (Instance)', axis: 'Percent' },
  { key: 'max_worker_percent', label: 'Max Worker %', axis: 'Percent' }, { key: 'max_session_percent', label: 'Max Session %', axis: 'Percent' },
  { key: 'max_cpu_percent', label: 'Max CPU %', axis: 'Percent', shown: true }, { key: 'max_data_io_percent', label: 'Max Data %', axis: 'Percent', shown: true },
  { key: 'max_log_write_percent', label: 'Max Log Write %', axis: 'Percent', shown: true },
  { key: 'max_instance_cpu_percent', label: 'Max CPU % (Instance)', axis: 'Percent' }, { key: 'max_instance_memory_percent', label: 'Max Memory % (Instance)', axis: 'Percent' },
  { key: 'max_dtu_percent', label: 'Max DTU %', axis: 'Percent' },
  { key: 'avg_dtu', label: 'Avg DTU', axis: 'DTU' }, { key: 'max_dtu', label: 'Max DTU', axis: 'DTU' },
  { key: 'dtu_limit', label: 'DTU Limit', axis: 'DTU' }, { key: 'cpu_limit', label: 'CPU Limit', axis: 'DTU' },
];

// DBA Dash's Pool chart's measures (PoolColumns L96-110): the maxima stored by 0418, the DTUs and the limit from the
// pool's DTU limit of 0395's limit history (none without the dbmanager opt-in's read)
export const poolMeasures: Measure[] = [
  { key: 'avg_cpu_percent', label: 'Avg CPU %', axis: 'Percent' }, { key: 'avg_data_io_percent', label: 'Avg Data %', axis: 'Percent' },
  { key: 'avg_log_write_percent', label: 'Avg Log Write %', axis: 'Percent' }, { key: 'avg_edtu_percent', label: 'Avg DTU %', axis: 'Percent' },
  { key: 'max_worker_percent', label: 'Max Worker %', axis: 'Percent' }, { key: 'max_session_percent', label: 'Max Session %', axis: 'Percent' },
  { key: 'max_cpu_percent', label: 'Max CPU %', axis: 'Percent', shown: true }, { key: 'max_data_io_percent', label: 'Max Data %', axis: 'Percent', shown: true },
  { key: 'max_log_write_percent', label: 'Max Log Write %', axis: 'Percent', shown: true }, { key: 'max_edtu_percent', label: 'Max DTU %', axis: 'Percent' },
  { key: 'avg_dtu', label: 'Avg DTU', axis: 'DTU' }, { key: 'max_dtu', label: 'Max DTU', axis: 'DTU' },
  { key: 'dtu_limit', label: 'DTU Limit', axis: 'DTU' },
];

// chosenMeasures: the page's chosen measures, else DBA Dash's defaults (the unread ones never)
export function chosenMeasures(c: ChartChoice, list: Measure[]): Measure[] {
  const on = c.measures ? new Set(c.measures) : new Set(list.filter(m => m.shown).map(m => m.key));
  return list.filter(m => on.has(m.key) && !m.unread);
}

// measureCharts: one chart per axis of the chosen measures (DBA Dash's Percent and DTU axes), oldest first
export function measureCharts(rows: Row[], list: Measure[], c: ChartChoice, title: string): HTMLElement[] {
  const chosen = chosenMeasures(c, list);
  if (!chosen.length) return [el('p', { class: 'meta' }, 'No measure chosen: the toolbar\'s Columns picks them.')];
  return (['Percent', 'DTU'] as const).map(axis => chosen.filter(m => m.axis === axis)).filter(ms => ms.length)
    .map(ms => lineChart(ms[0].axis === 'Percent' ? `${title} (% of the limit)` : `${title} (DTU)`, rows,
      ms.map(m => ({ key: m.key, label: m.label })), v => fmtNum(v) + (ms[0].axis === 'Percent' ? ' %' : '')));
}

// DBA Dash's Date Grouping list in its order and words (DBADashGUI/DateHelper.cs DateGroups; control audit A1) after
// pgvigil's Auto; its None (the 15-second rows) is not offered - pgvigil stores minutes - and the toolbar says so
const groupings: [Grouping, string][] = [['auto', 'Auto'], ['minute', '1min'], ['2', '2min'], ['5', '5min'], ['10', '10min'], ['15', '15min'], ['30', '30min'],
  ['hour', '1hr'], ['120', '2hrs'], ['240', '4hrs'], ['360', '6hrs'], ['720', '12hrs'], ['day', '1 Day'], ['2880', '2 Days'], ['10080', '7 Days'], ['20160', '14 Days']];

// groupStep: a grouping that the pages read as part=grouped&step=<minutes> (null for auto, minute, hour and day)
export function groupStep(g: Grouping): number | null {
  return /^[0-9]+$/.test(g) ? Number(g) : null;
}

// groupLabel: a grouping's words
export function groupLabel(g: Grouping): string {
  return groupings.find(x => x[0] === g)?.[1] ?? g;
}
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
      measures: Array.isArray(v.measures) ? v.measures.filter((k: unknown): k is string => typeof k === 'string') : undefined,
    };
  } catch { return { grouping: 'auto', columns: 2 }; }
}

// pickRows: the rows a grouping draws (auto: hours past a day of minutes, else the minutes), and its words
export function pickRows(g: Grouping, parts: { minutes: Row[]; hours: Row[]; days: Row[] }, longWindow: boolean): { rows: Row[]; unit: 'minute' | 'hour' | 'day' } {
  const unit: 'minute' | 'hour' | 'day' = g === 'auto' ? (longWindow ? 'hour' : 'minute') : g === 'hour' || g === 'day' ? g : 'minute';
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
export function chartToolbar(page: string, redraw: (c: ChartChoice) => void, measures?: Measure[]): HTMLElement {
  const cur = chartChoice(page);
  const pick = (id: string, label: string, options: [string, string][], value: string, set: (v: string) => void) => {
    const sel = el('select', { id }, ...options.map(([v, t]) => el('option', { value: v, ...(v === value ? { selected: 'selected' } : {}) }, t))) as HTMLSelectElement;
    sel.addEventListener('change', () => set(sel.value));
    return el('label', { style: 'margin-right:1rem' }, `${label} `, sel);
  };
  const save = () => { lsSet(`pgvigil.azureCharts.${page}`, JSON.stringify(cur)); redraw({ ...cur }); };
  return el('div', { class: 'toolbar', role: 'group', 'aria-label': 'Chart options' },
    pick(`${page}-grouping`, 'Date Grouping', groupings, cur.grouping, v => { cur.grouping = v as Grouping; save(); }),
    el('span', { class: 'meta', style: 'margin-right:1rem' }, 'DBA Dash\'s None (its 15-second rows) is not offered: pgvigil stores minutes.'),
    pick(`${page}-columns`, 'Columns per chart', columnChoices.map(n => [String(n), String(n)] as [string, string]), String(cur.columns), v => { cur.columns = Number(v); save(); }),
    measures ? measurePicker(page, measures, cur, save) : '');
}

// measurePicker: DBA Dash's Columns menu - a box per measure, its defaults ticked; a measure not stored yet is off with why
function measurePicker(page: string, list: Measure[], cur: ChartChoice, save: () => void): HTMLElement {
  const on = new Set(chosenMeasures(cur, list).map(m => m.key));
  const boxes = list.map(m => {
    const box = el('input', { type: 'checkbox', id: `${page}-m-${m.key}`, ...(on.has(m.key) ? { checked: 'checked' } : {}), ...(m.unread ? { disabled: 'disabled' } : {}) }) as HTMLInputElement;
    box.addEventListener('change', () => {
      cur.measures = list.filter(x => !x.unread && (document.getElementById(`${page}-m-${x.key}`) as HTMLInputElement | null)?.checked).map(x => x.key);
      save();
    });
    return el('label', { style: 'display:block', ...(m.unread ? { title: m.unread } : {}) }, box, ` ${m.label}`, m.unread ? el('span', { class: 'meta' }, ` (${m.unread})`) : '');
  });
  return el('details', { style: 'display:inline-block' }, el('summary', {}, 'Columns'), ...boxes);
}
