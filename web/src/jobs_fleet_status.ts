// The fleet Jobs page's 'Job status' grid (FLEET MSSQL DONE-2; DBA Dash's root Jobs, AgentJobsReport_Get): every job of
// every instance in view, SQL Agent, pg_cron and pgAgent alike, judged by one judge - job_status_view (0137: DBA Dash's
// default rule when no threshold row is set) - the judge the Summary's Agent Jobs / Jobs cells use too. Data from
// /api/jobsreport?part=status&ids=<the view's instances> and, after the grid is drawn, ?part=stats (the four columns
// that need every run of 7 days: succeeded 24 h / 7 days, longest and average over 7 days); a stats read that fails
// leaves those cells 'not read: <why>' and the grid stands. The picked job's history opens UNDER the grid as DBA Dash's
// child panel ('<instance> | <job>'); 'judged at' opens the thresholds dialog in place; Acknowledge is the tab's cell.
// jobsReportFleetView (jobsreport.ts) draws it above PostgreSQL's schedule checks.
import { AckData, jobAckCell, jobAcks, loadAckSafe } from './ack';
import { get, Row, rowsOf, Table } from './api';
import { hrefWith } from './dbinfo';
import { fleet, tagsOf } from './fleet';
import { loadThresholds, oneLine, thresholdsDialog } from './mssql_jobs';
import { Ctx } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtSecs, fmtTime, grid, tile } from './ui';

const dur = (v: unknown) => v == null ? '' : Number(v) < 60 ? fmtNum(Math.round(Number(v) * 10) / 10) + ' s' : fmtSecs(v);
const since = (v: unknown) => v == null || v === '' ? '' : fmtSecs(Math.max(0, Math.round((Date.now() - Date.parse(String(v))) / 1000)));
const statusWords: Record<string, string> = { crit: 'critical', warn: 'warning', ok: 'ok', none: 'not judged', excluded: 'excluded' };
const statusCls = (v: unknown) => v === 'crit' ? 'status crit' : v === 'warn' ? 'status warn' : v === 'ok' ? 'status ok' : '';
const scheduler = (v: unknown) => v === 'sqlagent' ? 'SQL Agent' : String(v ?? '');
const days = (min: unknown) => `${fmtNum(Math.round(Number(min) / 1440))} days`;
// no last failure / success inside the horizon: said as such, never 'never' (0137 looks no further back)
const noneIn = (r: Row) => `none in the last ${days(r.horizon_min)}`;
const key = (r: Row) => `${String(r.instance_id)}|${String(r.scheduler)}|${String(r.job_id)}`;

export async function jobStatusFleetSection(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', { id: 'job-status-fleet' });
  try {
    const inView = (await fleet()).instances.filter(r => !ctx.tag || (ctx.tag === 'untagged' ? tagsOf(r).length === 0 : tagsOf(r).includes(ctx.tag)));
    const ids = inView.map(r => Number(r.instance_id));
    const names = new Map(inView.map(r => [Number(r.instance_id), String(r.name)]));
    const d = await get<Record<'status', Table | null>>('jobsreport', { part: 'status', ids: ids.join(',') || '0' });
    const rows = rowsOf(d.status);
    const ad: AckData = await loadAckSafe(['acks']);
    const acked = (r: Row) => { const a = jobAcks(ad).get(`${String(r.instance_id)}|${String(r.job_name)}`); return !!a && r.last_failed_at != null && String(a.seen_state) === String(r.last_failed_at); };
    const redraw = () => window.dispatchEvent(new HashChangeEvent('hashchange'));
    const crit = rows.filter(r => r.status === 'crit').length, warn = rows.filter(r => r.status === 'warn').length, ackN = rows.filter(acked).length;
    sec.append(el('div', { class: 'tiles' },
      tile('jobs in the fleet', `${fmtNum(rows.length)} on ${fmtNum(new Set(rows.map(r => r.instance_id)).size)} instances`),
      tile('critical', fmtNum(crit), crit ? 'crit' : 'ok'),
      tile('warning', fmtNum(warn), warn ? 'warn' : 'ok'),
      tile('acknowledged', fmtNum(ackN))));

    // the picked job's history: a panel under the grid, DBA Dash's '<instance> | <job>'
    const hist = el('div', { id: 'job-status-history' });
    let pickSeq = 0;
    const pick = async (r: Row) => {
      const mine = ++pickSeq;
      const title = `${String(r.instance)} | ${String(r.job_name)}`;
      hist.replaceChildren(el('h3', { tabindex: '-1' }, title), el('p', { class: 'meta' }, 'Reading...'));
      const to = new Date(), from = new Date(to.getTime() - 7 * 24 * 3600 * 1000);
      try {
        const x = await get<Record<'runs' | 'counts', Table | null>>('jobs/history', { engine: r.scheduler === 'sqlagent' ? 'mssql' : 'pg', instance: Number(r.instance_id),
          from: from.toISOString(), to: to.toISOString(), scheduler: String(r.scheduler), job: String(r.job_id) });
        if (mine !== pickSeq) return;
        const runs = rowsOf(x.runs), c = rowsOf(x.counts)[0] ?? {};
        const h = el('h3', { tabindex: '-1' }, title);
        hist.replaceChildren(h,
          el('p', { class: 'meta' }, 'The last 7 days. ', el('a', { href: r.scheduler === 'sqlagent' ? hrefWith(ctx, 'mssqljobs', {}, Number(r.instance_id))
            : hrefWith(ctx, 'job', { scheduler: String(r.scheduler), job: String(r.job_id) }, Number(r.instance_id)) }, 'Open the job on its instance')),
          el('div', { class: 'tiles' }, tile('succeeded', fmtNum(c.succeeded ?? 0)), tile('failed', fmtNum(c.failed ?? 0), Number(c.failed) > 0 ? 'crit' : ''),
            tile('cancelled', fmtNum(c.cancelled ?? 0), Number(c.cancelled) > 0 ? 'warn' : '')),
          grid(runs, [
            { key: 'start_time', label: 'start', fmt: fmtTime }, { key: 'duration_s', label: 'took', num: true, fmt: dur },
            { key: 'outcome', cls: v => v === 'failed' ? 'status crit' : v === 'succeeded' ? 'status ok' : '' },
            { key: 'failed_step', label: 'step that failed' }, { key: 'message', fmt: oneLine },
          ], 'No run of this job in the last 7 days.'));
        requestAnimationFrame(() => { if (h.isConnected) h.focus(); });
      } catch (e) { if (mine === pickSeq) hist.replaceChildren(el('h3', {}, title), errorBox(e)); }
    };

    // the four columns of the stats part: filled IN PLACE when it answers (the grid is not drawn again, so a sort, a
    // filter or a hidden column the reader set stays); the values go into the rows too, for the sort and the export
    let stats: Map<string, Row> | null = null, statsWhy = '';
    const statFmt: Record<string, (v: unknown) => string> = {};
    const statText = (k: string, r: Row) => statsWhy ? `not read: ${statsWhy}` : !stats ? 'reading...' : statFmt[k](r[k]);
    const statCol = (k: string, label: string, fmt: (v: unknown) => string): Col => {
      statFmt[k] = fmt;
      return { key: k, label, num: true, fmt: (_v, r) => el('span', { 'data-stat': k, 'data-row': key(r) }, statText(k, r)) };
    };
    const instHref = (r: Row) => r.engine === 'sqlserver' ? hrefWith(ctx, 'mssqljobs', {}, Number(r.instance_id)) : hrefWith(ctx, 'jobsreport', {}, Number(r.instance_id));
    const cols: Col[] = [
      { key: 'instance', fmt: (v, r) => el('a', { href: instHref(r) }, String(v ?? '')) },
      { key: 'platform' },
      { key: 'scheduler', fmt: scheduler },
      { key: 'job_name', label: 'job', fmt: (v, r) => { const b = el('button', { type: 'button', class: 'link', 'aria-label': `History of ${String(v)} on ${String(r.instance)}` }, String(v ?? '')); b.addEventListener('click', () => { void pick(r); }); return b; } },
      { key: 'enabled', fmt: v => v == null ? '' : v ? 'yes' : badge('no', 'warn') },
      { key: 'category' },
      { key: 'description', wide: true },
      { key: 'status', cls: v => statusCls(v), fmt: (v, r) => el('span', {}, badge(statusWords[String(v)] ?? String(v ?? ''), v === 'crit' ? 'crit' : v === 'warn' ? 'warn' : v === 'ok' ? 'ok' : ''),
        r.reason ? ` ${String(r.reason)}` : '', acked(r) ? ' (acknowledged)' : '') },
      { key: 'last_failed_at', label: 'last failure', fmt: (v, r) => v == null ? noneIn(r) : fmtTime(v) },
      { key: 'last_run_failed', label: 'last run failed', fmt: v => v ? badge('yes', 'crit') : 'no', cls: v => v ? 'status crit' : '' },
      { key: '_since_fail', label: 'since last failure', fmt: (_v, r) => r.last_failed_at == null ? '' : since(r.last_failed_at) },
      { key: 'failed_step', label: 'failed step', fmt: (v, r) => v == null ? '' : `${String(r.failed_step_id)} ${String(v)}` },
      { key: 'last_succeeded_at', label: 'last success', fmt: (v, r) => v == null ? noneIn(r) : fmtTime(v) },
      { key: '_since_ok', label: 'since last success', fmt: (_v, r) => r.last_succeeded_at == null ? '' : since(r.last_succeeded_at) },
      { key: '_ack', label: 'acknowledged', fmt: (_v, r) => jobAckCell(ad, Number(r.instance_id), String(r.job_name), r.last_failed_at, redraw, undefined, names.get(Number(r.instance_id))) },
      { key: 'fail_24h', label: 'failed 24 h', num: true, cls: v => Number(v) > 0 ? 'status warn' : '' },
      statCol('ok_24h', 'succeeded 24 h', v => v == null ? '' : fmtNum(v)),
      { key: 'fail_7d', label: 'failed 7 days', num: true, cls: v => Number(v) > 0 ? 'status warn' : '' },
      statCol('ok_7d', 'succeeded 7 days', v => v == null ? '' : fmtNum(v)),
      { key: 'step_fail_24h', label: 'failed steps 24 h', num: true },
      { key: 'step_fail_7d', label: 'failed steps 7 days', num: true },
      statCol('max_secs_7d', 'longest 7 days', dur),
      statCol('avg_secs_7d', 'average 7 days', dur),
      { key: 'level', label: 'judged at', fmt: (v, r) => {
        const b = el('button', { type: 'button', class: 'link', 'aria-label': `Thresholds of ${String(r.job_name)} on ${String(r.instance)}` }, v === 'default' ? 'default (DBA Dash\'s)' : String(v ?? ''));
        b.addEventListener('click', () => { void loadThresholds(Number(r.instance_id)).then(t => { if (t) thresholdsDialog(Number(r.instance_id), String(r.job_name), t, redraw, ad, names.get(Number(r.instance_id))); }); });
        return b;
      } },
    ];
    // DBA Dash's default (CustomReportView.cs ResetStatusFilter): a view of one instance lists every job; more, the
    // critical, the warning and the acknowledged
    const pickSel = el('select', { id: 'job-status-filter' }, el('option', { value: 'problems' }, 'Critical, warning and acknowledged'), el('option', { value: 'all' }, 'All')) as HTMLSelectElement;
    pickSel.value = new Set(ids).size > 1 ? 'problems' : 'all';
    const said = el('span', { id: 'job-status-count', role: 'status' });
    const box = el('div', { id: 'job-status-grid' });
    const draw = () => {
      const shown = pickSel.value === 'all' ? rows : rows.filter(r => r.status === 'crit' || r.status === 'warn' || acked(r));
      said.textContent = `${fmtNum(shown.length)} of ${fmtNum(rows.length)} jobs`;
      box.replaceChildren(grid(shown, cols, pickSel.value === 'all' ? 'No job on the instances in view.' : 'No critical, warning or acknowledged job on the instances in view.'));
    };
    pickSel.addEventListener('change', draw);
    sec.append(el('h3', {}, 'Job status'),
      el('p', { class: 'meta' }, el('label', { for: 'job-status-filter' }, 'Show '), pickSel, ' ', said),
      el('p', { class: 'meta' }, 'Every job of the instances in view, SQL Agent, pg_cron and pgAgent, judged by its thresholds (the job, its instance or the root); with none set, '
        + 'DBA Dash\'s default: critical when the last run failed or a run failed in the last 60 minutes, warning when a run failed in the last 7 days. The 24-hour and 7-day '
        + 'counts are fixed windows, not the page\'s range. The last failure and success are looked for back as far as the longest threshold in force (7 days at least). '
        + 'Pick a job for its history below.'),
      box, hist);
    draw();
    const byKey = new Map(rows.map(r => [key(r), r]));
    get<Record<'stats', Table | null>>('jobsreport', { part: 'stats', ids: ids.join(',') || '0' })
      .then(x => {
        stats = new Map(rowsOf(x.stats).map(r => [key(r), r]));
        for (const [k, r] of byKey) { const t = stats.get(k); for (const c of Object.keys(statFmt)) r[c] = t?.[c] ?? null; }
      }, e => { statsWhy = e instanceof Error ? e.message : String(e); })
      .finally(() => {
        for (const sp of box.querySelectorAll<HTMLElement>('[data-stat]')) {
          const r = byKey.get(sp.dataset.row ?? '');
          if (r) sp.textContent = statText(sp.dataset.stat ?? '', r);
        }
      });
  } catch (e) {
    sec.append(el('h3', {}, 'Job status'), errorBox(e));
  }
  return sec;
}
