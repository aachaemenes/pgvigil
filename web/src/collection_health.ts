// Collection Health (B6.2): DBA Dash 4.25.0's Checks > Collection Health - how often each collection succeeds, fails
// or ends partial over the picked range, what it costs, and its status by DBA Dash's rule (the failures in a row now
// and the failure rate over the range, judged by the repository: pgvigil.collection_health, 0166 - the Summary's
// Collection Health cell reads the same). At the root, a tag folder (its instances) or an instance. Show: a row per
// collection per instance (DBA Dash's default, at every level) or per collection over the instances. Status filter:
// DBA Dash's four. Landings as DBA Dash's: Instances -> that collection's per-instance rows; Failed and Errors -> the
// error list of the row over the range; Last Failure -> the error list around the last failure (from the last success
// while it fails now); an instance's name -> its own tab. Data from GET /api/collectionhealth.
import { get, Row, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { href, window_ } from './router';
import { fleet, inTagScope, tagWords } from './fleet';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';
import { lineChart } from './chart';

const word: Record<string, string> = { critical: 'Critical', warning: 'Warning', 'n/a': 'N/A', ok: 'OK' };
const kind: Record<string, string> = { critical: 'crit', warning: 'warn', 'n/a': '', ok: 'ok' };
const statuses: [string, string][] = [['critical', 'Critical'], ['warning', 'Warning'], ['na', 'N/A'], ['ok', 'OK']];
const shows: [string, string][] = [['instance', 'Row per collection per instance'], ['collection', 'Row per collection']];
// the lead's words (23:2x 11-14) where DBA Dash shows its Import Lag chart
export const importLagWords = 'pgvigil writes each collection in its own run: there is no import step to lag';
const pct = (v: unknown) => v == null ? '' : String(Number(v));

export async function collectionHealthView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Collection Health'));
  const own = new URLSearchParams(location.hash.split('?')[1] ?? '');
  const onlyColl = own.get('collection') ?? '';
  const errorsOf = own.get('errors') === '1';
  // Show: the address's own (a drill from Instances), else DBA Dash's default (each open, as DBA Dash's picker)
  const show = el('select', { id: 'ch-show', title: 'A row per collection per instance, or per collection over the instances shown' },
    ...shows.map(([v, l]) => el('option', { value: v }, l)));
  show.value = shows.some(s => s[0] === own.get('grain')) ? own.get('grain')! : 'instance';
  const boxes = statuses.map(([v, l]) => {
    const b = el('input', { type: 'checkbox', name: 'ch-status', value: v, id: `ch-status-${v}` });
    b.checked = true;
    return [b, el('label', { for: `ch-status-${v}` }, l)] as const;
  });
  const refresh = el('button', { type: 'button', title: 'Read the collection health again' }, 'Refresh');
  const errorsBox = el('div', { class: 'ch-errors' });
  const charts = el('div', { class: 'chart-row' });
  const body = el('div', { class: 'ch-grid' });
  let seq = 0;

  // the scope's parameters: an instance, a tag folder's instances, or the fleet
  const scope = async (): Promise<{ params: Record<string, string | number | undefined>; folder: string }> => {
    if (ctx.instance) return { params: { instance: ctx.instance }, folder: '' };
    if (ctx.tag) {
      const f = await fleet();
      return { params: { instances: f.instances.filter(r => inTagScope(ctx.tag!, r)).map(r => Number(r.instance_id)).join(',') || '0' }, folder: ` of ${tagWords(ctx.tag!)}` };
    }
    return { params: {}, folder: ' of the fleet' };
  };
  // a landing on this tab: the scope kept (or an instance's own), the range kept or set, the page's own words after it
  const land = (over: Partial<Ctx>, extra: Record<string, string>) => {
    const h = href(ctx, { tab: 'collectionhealth', ...over });
    const q = String(new URLSearchParams(extra));
    return q ? h + (h.includes('?') ? '&' : '?') + q : h;
  };
  const errorsLink = (r: Row, n: unknown, landing: string, range?: { from: string; to: string }) => {
    const id = r.instance_id != null ? Number(r.instance_id) : undefined;
    const over: Partial<Ctx> = id ? { instance: id, tag: undefined } : {};
    if (range) over.range = { from: range.from, to: range.to };
    const text = landing === 'lastfailure' ? fmtTime(n) : fmtNum(n);
    return el('a', { href: land(over, { errors: '1', collection: String(r.collection) }), 'data-land': landing }, text);
  };

  async function draw() {
    const mine = ++seq;
    const grain = show.value === 'collection' ? 'collection' : 'instance';
    const on = boxes.filter(([b]) => b.checked).map(([b]) => b.value);
    const drawn = `${on.join(',')}|${grain}`;
    let parts: Record<'collections' | 'runs' | 'cost', Table | null>;
    let folder = '';
    try {
      const sc = await scope();
      folder = sc.folder;
      const w = window_(ctx);
      const ask = { ...sc.params, ...w, grain, ...(onlyColl ? { collection: onlyColl } : {}) };
      // no status ticked: the grid lists nothing, the charts still read every collection - DBA Dash's charts read its
      // #Source, never the status-filtered rows (CollectionHealth_Get.sql L94-98; the review of B6.2, part b #9)
      parts = on.length === 0
        ? { collections: null, ...(await Promise.all(['runs', 'cost'].map(part => get<Record<'runs' | 'cost', Table | null>>('collectionhealth', { ...ask, part })))).reduce((a, b) => ({ ...a, ...b }), { runs: null, cost: null }) }
        : await get<Record<'collections' | 'runs' | 'cost', Table | null>>('collectionhealth', { ...ask, status: on.join(',') });
    } catch (e) { if (mine === seq) { body.replaceChildren(errorBox(e)); sec.dataset.drawn = drawn; } return; }
    if (mine !== seq) return;
    const rows = rowsOf(parts.collections);
    const n = (s: string) => rows.filter(r => r.status === s).length;
    const instCol: Col = { key: 'instance', label: 'Instance', fmt: (v, r) => el('a', { href: land({ instance: Number(r.instance_id), tag: undefined }, {}), 'data-land': 'instance' }, String(v ?? '')) };
    const statusCol: Col = { key: 'status', label: 'Status', fmt: v => badge(word[String(v)] ?? String(v), kind[String(v)] ?? '') };
    const tail: Col[] = [
      { key: 'runs', label: 'Runs', num: true, fmt: fmtNum },
      { key: 'succeeded_pct', label: 'Succeeded %', num: true, fmt: pct },
      { key: 'failed_pct', label: 'Failed %', num: true, fmt: pct },
      // DBA Dash's own words (CollectionHealthView.cs FailedPct24Hrs) without its 'since errors were acknowledged' (pgvigil's
      // summary rates a fixed 24 hours), and over which instances it is counted (the lead's 00:5x call on the review's #9a)
      { key: 'failed_pct_24h', label: 'Failed % 24hrs', num: true, fmt: pct,
        title: 'Runs that failed over the period the summary rates - the last 24hrs, from the start of the next hour.  The summary\'s status is from this '
          + 'rate and the failures in a row now, whatever period is selected here.  Over the instances of a collection (a row per collection), the runs '
          + 'are counted on the instances with a failed or a partial run in that period, as DBA Dash counts them.' },
      { key: 'succeeded', label: 'Succeeded', num: true, fmt: fmtNum },
      { key: 'partial', label: 'Partial', num: true, fmt: fmtNum },
      // Failed opens the window it counts (the hours from the one holding the range's start to the end of the one holding
      // its end: rate_from .. rate_to); Errors keeps the range (the review of B6.2, part b #1)
      { key: 'failed', label: 'Failed', num: true, fmt: (v, r) => Number(v ?? 0) > 0 ? errorsLink(r, v, 'failed', { from: String(r.rate_from), to: String(r.rate_to) }) : fmtNum(v) },
      { key: 'failures_in_a_row', label: 'Failures In A Row', num: true, fmt: fmtNum },
      { key: 'last_run_at', label: 'Last Run', fmt: fmtTime },
      { key: 'last_success', label: 'Last Success', fmt: fmtTime },
      { key: 'last_failure', label: 'Last Failure', fmt: (v, r) => v == null ? '' : errorsLink(r, v, 'lastfailure', { from: String(r.errors_from), to: String(r.errors_to) }) },
      { key: 'avg_duration_ms', label: 'Avg Duration (ms)', num: true, fmt: fmtNum },
      { key: 'max_duration_ms', label: 'Max Duration (ms)', num: true, fmt: fmtNum },
      { key: 'rows', label: 'Rows', num: true, fmt: fmtNum },
      { key: 'errors', label: 'Errors', num: true, fmt: (v, r) => Number(v ?? 0) > 0 ? errorsLink(r, v, 'errors') : fmtNum(v) },
      { key: 'thresholds', label: 'Thresholds' },
    ];
    const cols: Col[] = grain === 'collection'
      ? [{ key: 'collection', label: 'Collection' }, statusCol,
         { key: 'instances', label: 'Instances', num: true, fmt: (v, r) => el('a', { href: land({}, { grain: 'instance', collection: String(r.collection) }), 'data-land': 'instances' }, fmtNum(v)) },
         { key: 'failing_instances', label: 'Failing Instances', num: true, fmt: fmtNum }, ...tail]
      : [...(ctx.instance ? [] : [instCol]), { key: 'collection', label: 'Collection' }, statusCol, { key: 'status_reason', label: 'Status Reason', wide: true }, ...tail];
    // the charts: Runs by outcome (DBA Dash's colours), the time spent collecting, Import Lag in words
    const runs = rowsOf(parts.runs).map(r => {
      const f = Number(r.failed ?? 0), p = Number(r.partial ?? 0), s = Number(r.succeeded ?? 0);
      return { snapshot_at: r.at, failed: f, fp: f + p, all: f + p + s };
    });
    const cost = rowsOf(parts.cost).map(r => ({ snapshot_at: r.at, collecting_s: Number(r.collecting_s ?? 0) }));
    // the charts are hourly (the rows are): a range of under two whole hours has one bucket at most, said in each
    // chart's place rather than a chart's 'needs two reads' (the review of B6.2, part b #8)
    const hourMs = 3600000, wr = window_(ctx);
    const wholeHours = Math.round((Math.ceil(Date.parse(wr.to) / hourMs) - Math.floor(Date.parse(wr.from) / hourMs)));
    const hourly = (title: string) => el('div', { class: 'chart' }, el('h3', {}, title), el('p', { class: 'meta' }, 'The charts are hourly: pick a range of 2 hours or more.'));
    charts.replaceChildren(
      // Runs as stacked areas, not the design's stacked columns: the data are running totals (failed, failed + partial,
      // all) and uPlot's bars of running totals draw the tallest over the others (the review of B6.2, part b #14)
      wholeHours < 2 ? hourly('Runs') : lineChart('Runs', runs, [{ key: 'failed', label: 'Failed', color: '--crit' }, { key: 'fp', label: 'Partial', color: '--warn' }, { key: 'all', label: 'Succeeded', color: '--ok' }],
        v => v.toLocaleString(), { stacked: true, marks: false }),
      wholeHours < 2 ? hourly('Time spent collecting (sec)') : lineChart('Time spent collecting (sec)', cost, [{ key: 'collecting_s', label: 'collecting' }], v => v.toLocaleString(), { marks: false, unit: 's' }),
      el('div', { class: 'chart' }, el('h3', {}, 'Import Lag'), el('p', { class: 'meta' }, importLagWords)));
    body.replaceChildren(
      el('p', { class: 'meta' }, `${fmtNum(rows.length)} row(s)${folder}${onlyColl ? `, collection ${onlyColl}` : ''}: ${n('critical')} critical, ${n('warning')} warning, ${n('n/a')} N/A, ${n('ok')} OK. `
        // the rule in docs/collection-health.md's words (0166; the review of B6.2, part b #10)
        + 'Status: critical at 3 or more failures in a row and 30 minutes or more from the last success to the latest failure, or 50 % or more of 5 or more runs failed with the last run failed; '
        + 'warning at 1 or more failures in a row and 10 minutes or more since the last success, or 10 % or more of 5 or more runs failed or ended partial; N/A when the collection is off or only skipped (DBA Dash\'s defaults). '
        + 'Failed % 24hrs is the Summary\'s rate. Not shown, as pgvigil has no source for them: Warnings, Retried, Import Failed, No Status, CPU, Logical Reads, '
        + 'the import columns; no Steps (pgvigil has no run steps); Runs and Max Duration are not links (no Collection Performance report yet); '
        + 'the Status column shows the word as well as the colour.'),
      grid(rows, cols, on.length === 0 ? 'No status is picked: pick one or more to list the collections.' : 'No collection matches: show every status, or a wider range.'));
    sec.dataset.drawn = drawn;
  }

  async function drawErrors() {
    if (!errorsOf) return;
    const qBox = el('input', { type: 'search', id: 'ch-q', placeholder: 'Text in the message', 'aria-label': 'Text the error message holds' });
    const list = el('div');
    const back = el('a', { href: href(ctx, { tab: 'collectionhealth' }) }, 'Back to every collection');
    const read = async () => {
      try {
        const sc = await scope();
        const t = await get<Record<'errors', Table | null>>('collectionhealth', { ...sc.params, ...window_(ctx), part: 'errors', ...(onlyColl ? { collection: onlyColl } : {}), q: qBox.value });
        const rs = rowsOf(t.errors);
        // the window as the API reads it, on the page's clock: the reach (31 days) counts back from the end or now,
        // whichever is earlier (web.go paramsReach; the review of B6.2, part b #11)
        const wv = window_(ctx), end = Math.min(Date.parse(wv.to), Date.now()), fromMs = Math.max(Date.parse(wv.from), end - 31 * 86400000);
        const cut = fromMs > Date.parse(wv.from);
        list.replaceChildren(el('p', { class: 'meta' }, `${fmtNum(rs.length)} error(s)${onlyColl ? ` of ${onlyColl}` : ''} logged ${fmtTime(new Date(fromMs).toISOString())} to ${fmtTime(wv.to)}${cut ? ' (the last 31 days of the range: the hourly rows are kept 30)' : ''}${rs.length >= 500 ? ' (the newest 500)' : ''}.`),
          grid(rs, [{ key: 'instance', label: 'Instance' }, { key: 'collection', label: 'Collection' }, { key: 'at', label: 'Time', fmt: fmtTime },
            { key: 'duration_ms', label: 'Duration (ms)', num: true, fmt: fmtNum }, { key: 'message', label: 'Message', wide: true }], 'No error logged in this range.'));
      } catch (e) { list.replaceChildren(errorBox(e)); }
    };
    qBox.addEventListener('change', () => void read());
    errorsBox.replaceChildren(el('h3', {}, 'Errors'), el('div', { class: 'toolbar' }, back, ' ', el('label', { for: 'ch-q' }, 'Message ', qBox)), list);
    await read();
  }

  for (const [b] of boxes) b.addEventListener('change', () => void draw());
  show.addEventListener('change', () => void draw());
  refresh.addEventListener('click', () => void draw());
  sec.append(el('div', { class: 'toolbar' }, refresh, ' ', el('label', { for: 'ch-show' }, 'Show ', show), ' ',
    el('span', { role: 'group', 'aria-label': 'Status' }, 'Status ', ...boxes.flatMap(([b, l]) => [b, l, ' ']))), errorsBox, charts, body);
  await Promise.all([draw(), drawErrors()]);
  return sec;
}
