// Collection Health (B6.2): DBA Dash 4.25.0's Checks > Collection Health - how often each collection succeeds, fails
// or ends partial over the picked range, what it costs, and its status by DBA Dash's rule (the failures in a row now
// and the failure rate over the range, judged by the repository: pgvigil.collection_health, 0166 - the Summary's
// Collection Health cell reads the same). At the root, a tag folder (its instances) or an instance. Show: a row per
// collection per instance (DBA Dash's default, at every level) or per collection over the instances. Status filter:
// DBA Dash's four. Landings as DBA Dash's: Instances -> that collection's per-instance rows; Failed and Errors -> the
// error list of the row over the range; Last Failure -> the error list around the last failure (from the last success
// while it fails now); an instance's name -> its own tab; Thresholds -> the row's thresholds dialog (B6g-2: DBA Dash's
// CollectionHealthThresholdsDialog, its four 'Apply to' levels). Data from GET /api/collectionhealth.
import { get, post, Row, rowsOf, Table } from './api';
import type { AckData } from './ack';
import { loadAckSafe, offBeside, seatWhy } from './ack';
import type { CHScope, CHSettingKey } from './chthresholds';
import { chFormat, chPayload, chScopes, chSettings, chValue, inheritedOf, ownRow } from './chthresholds';
import type { Ctx } from './router';
import { href, window_ } from './router';
import { fleet, inTagScope, tagWords } from './fleet';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';
import { lineChart } from './chart';
import { chartHours, costWords } from './chhealth';

const word: Record<string, string> = { critical: 'Critical', warning: 'Warning', 'n/a': 'N/A', ok: 'OK' };
const kind: Record<string, string> = { critical: 'crit', warning: 'warn', 'n/a': '', ok: 'ok' };
const statuses: [string, string][] = [['critical', 'Critical'], ['warning', 'Warning'], ['na', 'N/A'], ['ok', 'OK']];
const shows: [string, string][] = [['instance', 'Row per collection per instance'], ['collection', 'Row per collection']];
// the lead's words (23:2x 11-14) where DBA Dash shows its Import Lag chart
export const importLagWords = 'pgvigil writes into the repository inside the run that collected: no queue stands between the two, so there is no import lag (Avg Import is the write\'s own time)';
const pct = (v: unknown) => v == null ? '' : String(Number(v));
// ruleWords: the status rule above the grid in the numbers its rows are judged by (the design fold's #9; the review of
// B6g-2 #3) - DBA Dash's defaults where no row has a level of its own, the one set of numbers every listed row shares,
// or where they differ a pointer to each row's Thresholds cell
function ruleWords(rows: Row[]): string {
  const own = rows.filter(r => r.threshold_from != null && r.threshold_from !== '');
  const words = new Set(rows.map(r => String(r.threshold_words ?? '')));
  const tail = 'N/A when the collection is off, only skipped, or set Don\'t monitor. ';
  if (!own.length) return 'Status: critical at 3 or more failures in a row and 30 minutes or more from the last success to the latest failure, or 50 % or more of 5 or more runs failed with the last run failed; '
    + 'warning at 1 or more failures in a row and 10 minutes or more from the last success to the latest failure, or 10 % or more of 5 or more runs failed or ended partial (DBA Dash\'s defaults); ' + tail;
  if (words.size === 1) return `Status by the thresholds every row listed holds (${[...words][0]}: warning / critical): critical at the critical failures in a row and minutes from the last success to the latest failure, or the critical per cent of the runs failed with the last run failed; warning at the warning ones, the per cent counting partial runs too; ` + tail;
  return 'Status by each row\'s own thresholds - its Thresholds cell says where they come from and its title the numbers (DBA Dash\'s defaults: in a row 1 / 3, failing 10 / 30 min, failed 10 / 50 % of 5 runs or more); ' + tail;
}

// the write's noun in the seat's sentence (the server's CHThresholdWrite says the same)
const thNoun = 'Collection Health thresholds';

// thresholdsDialog: DBA Dash's Collection Health Thresholds dialog (CollectionHealthThresholdsDialog.cs, 4.25.0) for one
// row of the grid - 'Apply to' its levels (this instance and collection, this instance, this collection on every
// instance, everything; the collection grain the two without an instance), each setting ticked to set it at that level
// or unticked to inherit it ('Inherited: n', and from where), Save, Inherit All (unticks every value; Save then ends the
// level's own row), Close. Where the write cannot be made the dialog still reads, its Save off with the reason in words
// (the seat's: a server that writes nothing; on a demo serve an instance not the demo's, or a level over every instance).
function thresholdsDialog(ad: AckData, r: Row, after: () => void) {
  const id = r.instance_id != null && Number(r.instance_id) > 0 ? Number(r.instance_id) : null;
  const name = String(r.instance ?? '');
  const coll = String(r.collection ?? '');
  const scopes = chScopes(id, name, coll);
  let live: Row[] = [], cur: CHScope = scopes[0], done = false, readOk = false;
  const pick = el('select', { id: 'ch-th-scope' }, ...scopes.map((x, i) => el('option', { value: String(i) }, x.words)));
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const levelLine = el('p', { class: 'meta', id: 'ch-th-level' });
  const offNote = el('p', { class: 'meta', hidden: '' });
  const ctl = new Map<CHSettingKey, { tick: HTMLInputElement; val: HTMLInputElement; inh: HTMLElement; inherited: number | boolean }>();
  const tbody = el('tbody');
  let group = '';
  for (const st of chSettings) {
    if (st.group !== group) {
      group = st.group;
      tbody.append(el('tr', {}, el('th', { colspan: '3', scope: 'colgroup', style: 'text-align:left;padding-top:.6rem' }, group)));
    }
    const tick = el('input', { type: 'checkbox', 'aria-label': `Set '${st.label}' (${st.group}) at this level` });
    const val = st.kind === 'bool'
      ? el('input', { type: 'checkbox', 'aria-label': st.label })
      : el('input', { type: 'number', min: String(st.min), max: String(st.max), step: st.kind === 'pct' ? '0.01' : '1', 'aria-label': `${st.label} (${st.group})`, style: 'width:7rem' });
    const inh = el('span', { class: 'meta' });
    const c = { tick, val, inh, inherited: st.def };
    ctl.set(st.key, c);
    // unticked shows the inherited value, read only (DBA Dash's ShowOverride)
    tick.addEventListener('change', () => { if (!tick.checked) put(st.key, c.inherited); val.disabled = !tick.checked || !!whyOf(); });
    tbody.append(el('tr', {}, el('td', {}, el('label', {}, tick, ' ', st.label)), el('td', {}, val), el('td', {}, inh)));
  }
  const put = (k: CHSettingKey, v: number | boolean) => {
    const c = ctl.get(k)!;
    if (c.val.type === 'checkbox') c.val.checked = v === true; else c.val.value = String(v);
  };
  const whyOf = () => seatWhy(ad, thNoun, cur.instance_id ?? undefined, cur.instance_id != null ? name : undefined);
  const btns = el('div', { style: 'margin-top:.6rem' });
  // the buttons of the level picked (DBA Dash's order: Close, Save, Inherit All): Save and Inherit All off with the
  // level's reason where it cannot be written
  const drawButtons = () => {
    const close = el('button', { type: 'button' }, 'Close'), save = el('button', { type: 'submit' }, 'Save'), all = el('button', { type: 'button' }, 'Inherit All');
    close.addEventListener('click', shut);
    const why = !readOk ? 'the thresholds could not be read' : whyOf();
    offNote.hidden = !why;
    offNote.textContent = why ? `Not written here: ${why}.` : '';
    if (why) { offBeside(save, why, offNote); offBeside(all, why, offNote); }
    else all.addEventListener('click', () => { for (const [k, c] of ctl) { c.tick.checked = false; put(k, c.inherited); c.val.disabled = true; } msg.textContent = 'Every value inherits: Save ends this level\'s own thresholds.'; });
    btns.replaceChildren(close, ' ', save, ' ', all);
    for (const c of ctl.values()) { c.tick.disabled = !!why; c.val.disabled = !!why || !c.tick.checked; }
  };
  // the level picked: its own values ticked, every value's inherited one beside it
  const fill = () => {
    // a read that failed shows no number as if read (the review of B6g-2 #5: the defaults read as inherited)
    if (!readOk) {
      levelLine.textContent = 'The thresholds of this level could not be read.';
      for (const c of ctl.values()) { c.tick.checked = false; c.inh.textContent = 'Inherited: not read'; if (c.val.type === 'checkbox') c.val.checked = false; else c.val.value = ''; }
      drawButtons();
      return;
    }
    const own = ownRow(live, cur);
    levelLine.textContent = own
      ? `${cur.words}: set by ${String(own.created_by ?? '?')} ${fmtTime(own.created_at)}.`
      : `${cur.words} has no thresholds of its own: every value inherits.`;
    for (const st of chSettings) {
      const c = ctl.get(st.key)!, v = chValue(own, st.key), inh = inheritedOf(live, scopes, cur, st.key);
      c.inherited = inh.value;
      c.inh.textContent = `Inherited: ${chFormat(inh.value)} (${inh.from})`;
      c.tick.checked = v != null;
      put(st.key, v ?? inh.value);
    }
    drawButtons();
  };
  const load = async () => {
    try {
      const d = await get<Record<'thresholds', Table | null>>('collectionhealth', { instance: id ?? undefined, collection: coll, part: 'thresholds' });
      live = rowsOf(d.thresholds);
      readOk = true;
    } catch (e) {
      readOk = false;
      msg.replaceChildren(badge('not read', 'crit'), ' ', `The thresholds could not be read: ${e instanceof Error ? e.message : String(e)}`);
    }
    fill();
  };
  const form = el('form', { method: 'dialog' }, el('h3', { id: 'ch-th-title' }, 'Collection Health Thresholds'),
    el('p', {}, 'A run of failures counts once it is long enough in runs and has gone on long enough since the collection last succeeded - so a collection that runs every minute has to fail for a while before it shows, while one that runs daily shows on its first failure.  '
      + 'The failure rate is over the page\'s range (the Summary\'s over the last 24hrs), once there are enough runs.  It is only critical while the latest run failed.  '
      + 'Untick a value to inherit it from the level above.  Who set a level and when is kept.'),
    el('div', {}, el('label', { for: 'ch-th-scope' }, 'Apply to: '), pick), levelLine,
    el('table', { class: 'ch-th' }, tbody), offNote, msg, btns);
  // named by its heading, described by the level picked (the review of B6g-2 #10: a fixed label never followed the level)
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:44rem', 'aria-labelledby': 'ch-th-title', 'aria-describedby': 'ch-th-level' }, form);
  function shut() { dlg.close(); dlg.remove(); if (done) after(); }
  dlg.addEventListener('cancel', () => { dlg.remove(); if (done) after(); });
  pick.addEventListener('change', () => { cur = scopes[Number(pick.value)] ?? scopes[0]; msg.textContent = ''; fill(); });
  form.addEventListener('submit', ev => {
    ev.preventDefault();
    if (whyOf() || !readOk) return;
    const values: Partial<Record<CHSettingKey, number | boolean | null>> = {};
    for (const st of chSettings) {
      const c = ctl.get(st.key)!;
      if (!c.tick.checked) { values[st.key] = null; continue; }
      if (st.kind === 'bool') { values[st.key] = c.val.checked; continue; }
      const n = Number(c.val.value);
      if (c.val.value.trim() === '' || !Number.isFinite(n) || n < st.min || n > st.max || (st.kind === 'int' && !Number.isInteger(n))) {
        msg.replaceChildren(badge('not saved', 'crit'), ' ', `${st.label} (${st.group}): ${st.kind === 'int' ? 'a whole number' : 'a number'} from ${st.min} to ${st.max}, or untick it to inherit.`);
        c.val.focus();
        return;
      }
      values[st.key] = n;
    }
    const pay = chPayload(cur, values, ownRow(live, cur));
    if (!pay) { msg.textContent = 'Nothing to save: every value inherits already.'; return; }
    msg.textContent = 'Saving...';
    void post<{ outcome: string; detail: string }>('collectionhealth/thresholds', pay).then(async res => {
      done = true;
      // closed by Escape while the save was out: the page reads it again now (the review of B6g-2 #10)
      if (!dlg.isConnected) { after(); return; }
      await load();
      msg.replaceChildren(badge(res.outcome, 'ok'), ' ', `Saved for ${cur.words}.  The page picks it up when it next reads (Close reads it again).`);
    }, (e: unknown) => {
      msg.replaceChildren(badge('not saved', 'crit'), ' ', e instanceof Error ? e.message : String(e));
    });
  });
  document.body.append(dlg);
  dlg.showModal();
  drawButtons();
  void load();
}

export async function collectionHealthView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Collection Health'));
  // who may set a threshold here (the acknowledgement seat: the server's thresholds write asks the same one)
  const ad = await loadAckSafe(['acks']);
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
  // B6g-3 (N42): the Collection Performance report of the row's collection - its instance on a row per collection per
  // instance, the page's scope on a row per collection - over the range this grid was read with (DBA Dash's
  // PerformanceLink on Collection, Runs, Avg / Max Duration and Total CPU)
  const perfLink = (r: Row, content: string | Node, landing: string, perInstance: boolean) => {
    const wr = window_(ctx), id = perInstance && r.instance_id != null ? Number(r.instance_id) : undefined;
    const h = href(ctx, { tab: 'collectionperf', range: { from: wr.from, to: wr.to }, ...(id ? { instance: id, tag: undefined } : {}) });
    return el('a', { href: h + (h.includes('?') ? '&' : '?') + 'collection=' + encodeURIComponent(String(r.collection)), 'data-land': landing,
      title: 'The collection\'s performance over this range: Collection Performance' }, content);
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
      { key: 'runs', label: 'Runs', num: true, fmt: (v, r) => perfLink(r, fmtNum(v), 'perf-runs', grain === 'instance') },
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
      { key: 'failed', label: 'Failed', num: true, fmt: (v, r) => Number(v ?? 0) > 0 ? errorsLink(r, v, 'failed', { from: String(r.rate_from), to: String(r.rate_to) }) : fmtNum(v),
        title: 'Runs that failed, but for those under Import Failed.  Failed % is over both, and the link lists the errors of both kinds.' },
      // B6g-1 (N27): DBA Dash's Import Failed, its own count, a link to the same list as Failed's (as DBA Dash links both)
      { key: 'import_failed', label: 'Import Failed', num: true,
        fmt: (v, r) => Number(v ?? 0) > 0 ? errorsLink(r, v, 'importfailed', { from: String(r.rate_from), to: String(r.rate_to) }) : fmtNum(v),
        title: 'Runs whose write of collected rows into the repository failed.  A collection written in parts whose part was refused while the run went on is Partial, not here.  The link lists the errors of both kinds, as Failed\'s.' },
      { key: 'failures_in_a_row', label: 'Failures In A Row', num: true, fmt: fmtNum },
      { key: 'last_run_at', label: 'Last Run', fmt: fmtTime },
      { key: 'last_success', label: 'Last Success', fmt: fmtTime },
      { key: 'last_failure', label: 'Last Failure', fmt: (v, r) => v == null ? '' : errorsLink(r, v, 'lastfailure', { from: String(r.errors_from), to: String(r.errors_to) }) },
      { key: 'avg_duration_ms', label: 'Avg Duration (ms)', num: true, fmt: (v, r) => v == null ? '' : perfLink(r, fmtNum(v), 'perf-avg', grain === 'instance') },
      { key: 'max_duration_ms', label: 'Max Duration (ms)', num: true, fmt: (v, r) => v == null ? '' : perfLink(r, fmtNum(v), 'perf-max', grain === 'instance') },
      // B6g-1 (N25 / N26): the run's own session's cost, read at the run's end on SQL Server; a PostgreSQL row says so.
      // DBA Dash's order and words after Max Duration (CollectionHealthView.cs: Avg CPU, Max CPU, Total CPU, Avg Logical
      // Reads, Total Logical Reads, Avg Import, Max Import; the review of B6g-1 part b #5)
      ...([['avg_cpu_ms', 'Avg CPU (ms)'], ['max_cpu_ms', 'Max CPU (ms)'], ['total_cpu_ms', 'Total CPU (ms)'], ['avg_logical_reads', 'Avg Logical Reads'], ['logical_reads', 'Total Logical Reads']] as const)
        .map(([key, label]): Col => ({ key, label, num: true, fmt: (v, r) => key === 'total_cpu_ms'
          ? perfLink(r, costWords(v, r.engine) ?? fmtNum(v), 'perf-cpu', grain === 'instance') : costWords(v, r.engine) ?? fmtNum(v),
          title: 'Of the run\'s own session on SQL Server (cpu_time, logical_reads of sys.dm_exec_sessions), read at the run\'s end, over the runs that read it.  A run cut by its own timeout is not read: the driver drops its connection.' })),
      // B6g-1 (N27): the write into the repository alone, over the runs that wrote or tried to (the durations hold it too)
      { key: 'avg_import_ms', label: 'Avg Import (ms)', num: true, fmt: fmtNum, title: 'The time of the writes into the repository alone, over the runs that wrote into it or tried to (a failed write too).  Avg Duration includes it.' },
      { key: 'max_import_ms', label: 'Max Import (ms)', num: true, fmt: fmtNum },
      { key: 'rows', label: 'Rows', num: true, fmt: fmtNum },
      { key: 'errors', label: 'Errors', num: true, fmt: (v, r) => Number(v ?? 0) > 0 ? errorsLink(r, v, 'errors') : fmtNum(v) },
      // B6g-2: where the row's numbers come from, the numbers themselves in the title; a link to the row's thresholds
      // dialog (DBA Dash's Thresholds link: 'Click to configure them'), which reads wherever it cannot write
      { key: 'thresholds', label: 'Thresholds', fmt: (v, r) => {
        const b = el('button', { type: 'button', class: 'link', title: String(r.threshold_words ?? ''),
          'aria-label': `Collection Health thresholds of ${String(r.collection)}${r.instance_id != null ? ` on ${String(r.instance ?? '')}` : ''}: ${String(v ?? '')}` }, String(v ?? ''));
        // after a save the grid is drawn again and the focus goes back to this row's cell (the review of B6g-2 #10)
        const label = b.getAttribute('aria-label')!.replace(/: [^:]*$/, ':');
        b.addEventListener('click', () => thresholdsDialog(ad, r, () => void draw().then(() =>
          ([...document.querySelectorAll<HTMLButtonElement>('main .ch-grid button.link')].find(x => (x.getAttribute('aria-label') ?? '').startsWith(label)))?.focus())));
        return b;
      } },
    ];
    const cols: Col[] = grain === 'collection'
      ? [{ key: 'collection', label: 'Collection', fmt: (v, r) => perfLink(r, String(v ?? ''), 'perf-collection', false) }, statusCol,
         { key: 'instances', label: 'Instances', num: true, fmt: (v, r) => el('a', { href: land({}, { grain: 'instance', collection: String(r.collection) }), 'data-land': 'instances' }, fmtNum(v)) },
         { key: 'failing_instances', label: 'Failing Instances', num: true, fmt: fmtNum }, ...tail]
      : [...(ctx.instance ? [] : [instCol]), { key: 'collection', label: 'Collection', fmt: (v, r) => perfLink(r, String(v ?? ''), 'perf-collection', true) }, statusCol, { key: 'status_reason', label: 'Status Reason', wide: true }, ...tail];
    // the charts: Runs by outcome (DBA Dash's colours), the time spent collecting, Import Lag in words
    const runs = rowsOf(parts.runs).map(r => {
      const f = Number(r.failed ?? 0), p = Number(r.partial ?? 0), s = Number(r.succeeded ?? 0);
      return { snapshot_at: r.at, failed: f, fp: f + p, all: f + p + s };
    });
    // the Cost chart's three lines (DBA Dash's but its Import CPU): collecting, its CPU where read (SQL Server; a gap
    // where none was), importing
    const cost = rowsOf(parts.cost).map(r => ({ snapshot_at: r.at, collecting_s: Number(r.collecting_s ?? 0),
      cpu_s: r.cpu_s == null ? null : Number(r.cpu_s), importing_s: Number(r.importing_s ?? 0) }));
    // the charts are hourly (the rows are): a range of under two whole hours has one bucket at most, said in each
    // chart's place rather than a chart's 'needs two reads' (the review of B6.2, part b #8)
    // the whole hours up to now: a range ending in the future has no hourly row past now (chhealth.ts, B6f3 #9)
    const wr = window_(ctx), wholeHours = chartHours(wr.from, wr.to);
    const hourly = (title: string) => el('div', { class: 'chart' }, el('h3', {}, title), el('p', { class: 'meta' }, 'The charts are hourly: pick a range of 2 hours or more.'));
    charts.replaceChildren(
      // Runs as stacked areas, not the design's stacked columns: the data are running totals (failed, failed + partial,
      // all) and uPlot's bars of running totals draw the tallest over the others (the review of B6.2, part b #14)
      wholeHours < 2 ? hourly('Runs') : lineChart('Runs', runs, [{ key: 'failed', label: 'Failed', color: '--crit' }, { key: 'fp', label: 'Partial', color: '--warn' }, { key: 'all', label: 'Succeeded', color: '--ok' }],
        v => v.toLocaleString(), { stacked: true, marks: false }),
      wholeHours < 2 ? hourly('Time spent collecting and importing (sec)') : lineChart('Time spent collecting and importing (sec)', cost, [{ key: 'collecting_s', label: 'collecting' }, { key: 'cpu_s', label: 'collecting CPU' }, { key: 'importing_s', label: 'importing' }], v => v.toLocaleString(), { marks: false, unit: 's' }),
      el('div', { class: 'chart' }, el('h3', {}, 'Import Lag'), el('p', { class: 'meta' }, importLagWords)));
    body.replaceChildren(
      el('p', { class: 'meta' }, `${fmtNum(rows.length)} row(s)${folder}${onlyColl ? `, collection ${onlyColl}` : ''}: ${n('critical')} critical, ${n('warning')} warning, ${n('n/a')} N/A, ${n('ok')} OK. `
        // the rule in docs/collection-health.md's words (0166; the review of B6.2, part b #10)
        + ruleWords(rows)
        + 'Failed % 24hrs is the Summary\'s rate. Avg Duration includes the import; Avg and Max Import are the write into the repository alone. '
        + 'CPU and Logical Reads are the run\'s own session\'s on SQL Server, read at the run\'s end (a run cut by its own timeout is not read); a PostgreSQL row says not read by pgvigil. '
        + 'Not shown, as pgvigil has no source for them: Warnings, Retried, No Status, the import\'s own CPU and reads (and the Cost chart\'s Import CPU line), the highest logical reads of one run; '
        + 'no Steps (pgvigil has no run steps). Collection, Runs, Avg and Max Duration and Total CPU open the Collection Performance report over this range; '
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
