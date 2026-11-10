// Performance Insights and the Serverless v2 capacity (phase 3 wave E, task 56). loadView(ctx) is an instance's Load
// tab: the DB load by wait event per hour as a stacked chart (each hour a link that opens that hour), the top SQL by
// load with its text as the query_text policy stored it (the digest, cut at 500 bytes by PI, and the whole text when
// it was fetched), and the cache finding; a PI-off instance says so. capacitySection(ctx) is the Capacity section of
// the Host tab: the ACU against the cluster's floor and ceiling, the buffer cache hit ratio, the reads against the
// CPU. Data from /api/pi and /api/capacity; the lead wires the tab and the section.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, href, rangeLabel, window_ } from './router';
import { badge, Col, el, fmtNum, fmtTime, grid, props, tile } from './ui';

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const palette = ['#2f6fdf', '#d9480f', '#2b8a3e', '#ae3ec9', '#e8590c', '#1098ad', '#5c940d', '#e64980', '#868e96'];
const SVG = 'http://www.w3.org/2000/svg';

function svgEl(tag: string, attrs: Record<string, string | number>, ...kids: Node[]): SVGElement {
  const e = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, String(v));
  e.append(...kids);
  return e;
}

// stackedHours draws one bar per hour, its segments the waits stacked; every bar is a link to that hour (Tab reaches
// each, its label reads the hour, the total and the heaviest wait) and the legend names the colours.
function stackedHours(ctx: Ctx, rows: Row[]): HTMLElement {
  const box = el('div', { class: 'chart' }, el('h3', {}, 'DB load by wait (average active sessions per hour)'));
  if (!rows.length) { box.append(el('p', { class: 'empty' }, 'No Performance Insights hour in this window.')); return box; }
  const waits = [...new Set(rows.map(r => String(r.wait)))].sort((a, b) => a === 'other' ? 1 : b === 'other' ? -1 : 0);
  const order = new Map<string, number>();
  for (const r of rows) order.set(String(r.wait), (order.get(String(r.wait)) ?? 0) + Number(r.load_avg ?? 0));
  waits.sort((a, b) => a === 'other' ? 1 : b === 'other' ? -1 : (order.get(b)! - order.get(a)!));
  const colour = (w: string) => w === 'other' ? palette[8] : palette[waits.indexOf(w) % 8];
  const hours = [...new Set(rows.map(r => String(r.snapshot_at)))].sort((a, b) => Date.parse(a) - Date.parse(b));
  // bars sit on a time axis (an hour missing from the read leaves its gap), one slot per hour of the span
  const t0 = Date.parse(hours[0]), span = Math.round((Date.parse(hours[hours.length - 1]) - t0) / 3600_000) + 1;
  const by = new Map<string, Map<string, number>>();
  for (const r of rows) {
    const h = String(r.snapshot_at);
    if (!by.has(h)) by.set(h, new Map());
    by.get(h)!.set(String(r.wait), Number(r.load_avg ?? 0));
  }
  const totals = hours.map(h => [...by.get(h)!.values()].reduce((a, b) => a + b, 0));
  const peak = Math.max(...totals, 0.001);
  const W = 640, H = 220, left = 48, bottom = 24, top = 8;
  const plotW = W - left - 8, plotH = H - bottom - top;
  const step = plotW / span, barW = Math.max(0.5, step * 0.8);   // never wider than its slot: no bar covers the next
  const css = getComputedStyle(document.documentElement);
  const fg = css.getPropertyValue('--muted').trim() || '#5d6676', line = css.getPropertyValue('--line').trim() || '#dde1e8';
  const svg = svgEl('svg', { viewBox: `0 0 ${W} ${H}`, width: '100%', role: 'group', 'aria-label': 'DB load by wait per hour; each bar opens its hour' });
  for (const f of [0, 0.5, 1]) {
    const y = top + plotH - f * plotH;
    svg.append(svgEl('line', { x1: left, x2: W - 8, y1: y, y2: y, stroke: line, 'stroke-width': 1 }),
      svgEl('text', { x: left - 4, y: y + 4, 'text-anchor': 'end', 'font-size': 10, fill: fg }, document.createTextNode(fmtNum(Math.round(peak * f * 100) / 100))));
  }
  hours.forEach((h, i) => {
    const slot = Math.round((Date.parse(h) - t0) / 3600_000);
    const x = left + slot * step + (step - barW) / 2;
    const segs = by.get(h)!;
    const heaviest = [...segs.entries()].sort((a, b) => b[1] - a[1])[0];
    const start = new Date(h), end = new Date(start.getTime() + 3600_000);
    const label = `${fmtTime(h)}: ${fmtNum(Math.round(totals[i] * 100) / 100)} sessions` + (heaviest ? `, most ${heaviest[0]} (${fmtNum(Math.round(heaviest[1] * 100) / 100)})` : '');
    const a = svgEl('a', { href: href(ctx, { tab: ctx.tab, range: { from: start.toISOString(), to: end.toISOString() } }), 'aria-label': label });
    a.append(svgEl('title', {}, document.createTextNode(label + ' - open this hour')));
    let y = top + plotH;
    for (const w of waits) {
      const v = segs.get(w) ?? 0;
      if (v <= 0) continue;
      const hgt = v / peak * plotH;
      y -= hgt;
      a.append(svgEl('rect', { x, y, width: barW, height: Math.max(hgt, 0.5), fill: colour(w) }));
    }
    svg.append(a);
    if (hours.length <= 12 || i % Math.ceil(hours.length / 12) === 0) {
      svg.append(svgEl('text', { x: x + barW / 2, y: H - 6, 'text-anchor': 'middle', 'font-size': 10, fill: fg },
        document.createTextNode(start.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', hour12: false }))));
    }
  });
  const legend = el('ul', { class: 'legend', 'aria-label': 'waits', style: 'list-style:none;display:flex;flex-wrap:wrap;gap:4px 14px;padding:0;margin:4px 0 0' },
    ...waits.map(w => el('li', {}, el('span', { style: `display:inline-block;width:10px;height:10px;margin-right:4px;background:${colour(w)}`, 'aria-hidden': 'true' }), w)));
  box.append(svg, legend);
  return box;
}

// textCell: the digest in the grid; the whole text (or the digest when PI's text was not cut) behind a disclosure.
function textCell(_v: unknown, r: Row): Node {
  const digest = r.digest == null ? '' : String(r.digest);
  const whole = r.full_text == null ? '' : String(r.full_text);
  if (!digest && !whole) return document.createTextNode('(no text: the query_text policy is none, or PI returned none)');
  const head = digest.length > 120 ? digest.slice(0, 120) + '...' : digest;
  const body = whole || digest;
  return el('details', {}, el('summary', {}, head || '(whole text)'), el('pre', { class: 'sql', style: 'white-space:pre-wrap' }, body));
}

const textStatus: Record<string, string> = {
  whole: 'whole (under the 500-byte cut)', AVAILABLE: 'whole (fetched)', PROCESSING: 'cut (PI still processing)',
  UNAVAILABLE: 'cut (PI has no whole text)', 'no statement id': 'cut (no statement of it in the read)', error: 'cut (the fetch failed)',
  'not asked (call cap)': 'cut (not asked yet: the hourly call cap)', 'not asked (query_text none)': 'cut (query_text is none)',
};

const sqlCols: Col[] = [
  { key: 'share_pct', label: 'share of load', num: true, fmt: v => v == null ? '' : fmtNum(v) + ' %' },
  { key: 'avg_sessions', label: 'avg sessions', num: true },
  { key: 'load_hours', label: 'session-hours', num: true },
  { key: 'hours', label: 'hours seen', num: true },
  { key: 'digest', label: 'statement', fmt: textCell },
  { key: 'text_status', label: 'text', fmt: v => textStatus[String(v ?? '')] ?? String(v ?? '') },
  { key: 'db_id', label: 'queryid' },
  { key: 'tokenized_id', label: 'PI digest id' },
];

const findingCols: Col[] = [
  { key: 'severity', fmt: sevBadge }, { key: 'setting', label: 'finding' }, { key: 'value' }, { key: 'suggested' },
  { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime },
];

export async function loadView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Record<'state' | 'total' | 'waits' | 'sql' | 'findings', Table | null>>('pi', { instance: ctx.instance, ...window_(ctx) });
  const sec = el('section', {}, el('h2', {}, `Load (${rangeLabel(ctx)})`));
  const st = rowsOf(d.state)[0];
  if (!st) {
    sec.append(el('p', { class: 'empty' }, 'No Performance Insights read yet. The pi collection runs hourly on an RDS or Aurora instance with an aws: block '
      + 'and needs pi:GetResourceMetrics and pi:GetDimensionKeyDetails beside the rds: reads (Configuration shows a skip and its reason).'));
    return sec;
  }
  const total = rowsOf(d.total);
  if (st.enabled === false) {
    sec.append(el('p', { class: 'empty' }, `Performance Insights is off on ${String(st.db_instance ?? 'this instance')}: no new DB load is read. `
      + 'Turn it on in the instance\'s settings (the free tier keeps 7 days; pgvigil keeps the hourly load for its own retention).'));
    if (st.kept_from) sec.append(el('p', { class: 'meta' }, `Hours kept from before: ${fmtTime(st.kept_from)} to ${fmtTime(st.kept_to)}.`));
    if (!total.length) return sec;   // the kept hours of this window still show below
  }
  const peak = total.reduce((m, r) => Math.max(m, Number(r.load_avg ?? 0)), 0);
  const mean = total.length ? total.reduce((s, r) => s + Number(r.load_avg ?? 0), 0) / total.length : null;
  sec.append(el('div', { class: 'tiles' },
    tile('average load', mean == null ? '-' : fmtNum(Math.round(mean * 100) / 100) + ' sessions'),
    tile('peak hour', total.length ? fmtNum(Math.round(peak * 100) / 100) + ' sessions' : '-'),
    tile('hours in window', fmtNum(total.length)),
  ));
  sec.append(props([
    ['DB instance', String(st.db_instance ?? '')],
    ['PI retention', st.retention_days == null ? '' : `${fmtNum(st.retention_days)} days (pgvigil keeps the hours for its own retention)`],
    ['kept', st.kept_from ? `${fmtTime(st.kept_from)} to ${fmtTime(st.kept_to)}` : 'nothing yet'],
    ['last read', fmtTime(st.snapshot_at) + (st.note ? ` (${String(st.note)})` : '')],
  ]));
  const findings = rowsOf(d.findings);
  if (findings.length) sec.append(el('h3', {}, 'Findings'), grid(findings, findingCols));
  sec.append(stackedHours(ctx, rowsOf(d.waits)));
  sec.append(el('h3', {}, 'Top SQL by load'),
    el('p', { class: 'meta' }, 'PI cuts a statement at 500 bytes; the whole text of a cut digest is fetched once (GetDimensionKeyDetails). '
      + 'The text is stored under the instance\'s query_text policy (normalized: no literals; none: no text).'),
    grid(rowsOf(d.sql), sqlCols, 'No SQL digest in this window.'));
  return sec;
}

// capacitySection: the Host tab's Capacity section (Aurora; an empty hidden section when the instance has no serverless rows).
export async function capacitySection(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Record<'scaling' | 'series' | 'latest' | 'findings', Table | null>>('capacity', { instance: ctx.instance, ...window_(ctx) });
  const sec = el('section', {}, el('h3', {}, 'Capacity'));
  const sc = rowsOf(d.scaling)[0];
  const series = rowsOf(d.series);
  // not Aurora, never read, or a provisioned Aurora instance: the Host tab stays as it was
  if ((!sc && !series.length) || (sc && sc.class !== 'db.serverless')) return el('section', { hidden: '' });
  const latest = new Map(rowsOf(d.latest).map(r => [String(r.metric), r]));
  const v = (m: string) => latest.get(m)?.value;
  const floor = sc?.min_acu, ceil = sc?.max_acu;
  const acu = v('ServerlessDatabaseCapacity'), hit = v('BufferCacheHitRatio');
  // on the running floor (0.5 ACU is the least an awake instance runs at: a 0 minimum only adds the pause); a paused
  // instance (capacity 0) is not "on the floor"
  const onFloor = acu != null && floor != null && Number(acu) > 0 && Number(acu) <= Math.max(Number(floor), 0.5) + 0.01;
  sec.append(el('div', { class: 'tiles' },
    tile('capacity', acu == null ? '-' : fmtNum(acu) + ' ACU', onFloor ? 'warn' : ''),
    tile('floor / ceiling', floor == null ? '-' : `${fmtNum(floor)} / ${ceil == null ? '?' : fmtNum(ceil)} ACU`),
    tile('buffer cache hit ratio', hit == null ? '-' : fmtNum(Math.round(Number(hit) * 10) / 10) + ' %', hit != null && Number(hit) < 95 ? 'warn' : ''),
    tile('ACU utilization', v('ACUUtilization') == null ? '-' : fmtNum(Math.round(Number(v('ACUUtilization')))) + ' %'),
  ));
  if (sc) {
    sec.append(props([
      ['cluster', String(sc.cluster ?? '')], ['class', String(sc.class ?? '')],
      ['range read', fmtTime(sc.snapshot_at) + (sc.note ? ` (${String(sc.note)})` : '')],
    ]));
  }
  const findings = rowsOf(d.findings);
  if (findings.length) sec.append(grid(findings, findingCols));
  const withRange = series.map(r => ({ ...r, floor: floor ?? null, ceiling: ceil ?? null }));
  sec.append(el('div', { class: 'charts' },
    lineChart('Capacity (ACU) against the floor and the ceiling', withRange, [{ key: 'acu', label: 'capacity' }, { key: 'floor', label: 'floor' }, { key: 'ceiling', label: 'ceiling' }]),
    lineChart('Buffer cache hit ratio %', series, [{ key: 'hit_pct', label: 'hit ratio' }]),
    lineChart('Storage reads / s', series, [{ key: 'read_iops', label: 'reads / s' }]),
    lineChart('CPU %', series, [{ key: 'cpu_pct', label: 'CPU' }]),
  ));
  return sec;
}
