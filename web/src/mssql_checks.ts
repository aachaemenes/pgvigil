// The day-one checks of a SQL Server instance (task 148; DBA Dash's Configuration and DB Options grids, coloured as
// DBA Dash colours them) and their fleet view. Data: /api/mssql/checks and /api/mssql/checks/fleet (migration 0090,
// collections mssql_checks hourly and mssql_identity every six hours).
//
// A value at its default or its best practice is green, a deviation yellow (a warning or an advice rule) or red (a
// critical rule); grey where no rule covers it. The colour never stands alone: every coloured cell carries its
// verdict as its title, and a column of words beside it says the same.
//
// The instance page's views ride its hash (cv=summary|options|databases|flags|build|alerts|identity|findings), and
// the databases view a risk filter (risk=<option key>): the fleet's risk counts link there.
import { get, Row, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid, props } from './ui';

// The tab key of the instance page and of the fleet page (the router's entries carry the same keys).
export const mssqlChecksTab = 'mssqlchecks';
export const mssqlChecksFleetTab = 'mssqlrisks';

type Parts = Record<'state' | 'areas' | 'findings' | 'options' | 'flags' | 'build' | 'databases' | 'columns' | 'suspect'
  | 'alerts' | 'operators' | 'alerting' | 'identity' | 'identity_scan', Table | null>;
type FleetParts = Record<'risks' | 'cells' | 'options', Table | null>;

const views: [string, string][] = [
  ['summary', 'Summary'], ['options', 'Server options'], ['databases', 'Database options'], ['flags', 'Trace flags'],
  ['build', 'Build'], ['alerts', 'Agent alerts'], ['identity', 'Identity columns'], ['findings', 'Findings'],
];
const areaNames: Record<string, string> = {
  config: 'Server options', traceflags: 'Trace flags', build: 'Build', dboptions: 'Database options', dbstate: 'Database state',
  logspace: 'Log space', checkdb: 'Last good CHECKDB', corruption: 'Suspect pages', alerts: 'Agent alerts', identity: 'Identity columns',
};
// the view that shows an area's rows
const areaView: Record<string, string> = {
  config: 'options', traceflags: 'flags', build: 'build', dboptions: 'databases', dbstate: 'databases', logspace: 'databases',
  checkdb: 'databases', corruption: 'build', alerts: 'alerts', identity: 'identity',
};

function hashQS(): URLSearchParams { return new URLSearchParams(location.hash.split('?')[1] ?? ''); }
function hrefWith(change: (q: URLSearchParams) => void): string {
  const [path, qs] = location.hash.split('?');
  const q = new URLSearchParams(qs ?? '');
  change(q);
  return `${path || '#/' + mssqlChecksTab}?${q}`;
}
const link = (text: string, change: (q: URLSearchParams) => void, cls = '') => el('a', { href: hrefWith(change), ...(cls ? { class: cls } : {}) }, text);

// a status as a cell class: ui.ts turns a 'status <level>' cell into the coloured one
const statusCls = (s: unknown): string => s === 'ok' || s === 'warn' || s === 'crit' ? 'status ' + String(s) : '';
const verdict = (status: unknown, severity: unknown): string => {
  switch (status) {
    case 'crit': return 'deviates: critical';
    case 'warn': return severity === 'info' ? 'deviates: advice' : 'deviates: warning';
    case 'ok': return 'meets the rule';
    default: return 'no rule';
  }
};
const sev = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : 'info');
const yn = (v: unknown) => v === true ? 'yes' : v === false ? 'no' : '';
const titled = (text: string, title: string): Node => title ? el('span', { title }, text) : document.createTextNode(text);

export async function mssqlChecksView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Checks'));
  let d: Parts;
  try { d = await get<Parts>('mssql/checks', { instance: ctx.instance }); } catch (e) { sec.append(errorBox(e)); return sec; }
  const q = hashQS();
  const view = views.some(v => v[0] === q.get('cv')) ? q.get('cv')! : 'summary';
  sec.append(el('p', { class: 'meta counts' }, ...views.flatMap(([k, label], i) => {
    const a = k === view ? el('b', {}, label) : link(label, x => { x.set('cv', k); x.delete('risk'); });
    return i ? [' | ', a] : [a];
  })));
  const state = rowsOf(d.state);
  const notOk = state.filter(s => s.status !== 'ok');
  if (notOk.length) sec.append(el('p', { class: 'meta' }, ...notOk.map(s => `The ${String(s.collection)} collection's last run: ${String(s.status)}${s.note ? ' (' + String(s.note) + ')' : ''}. `)));
  if (!state.length && !rowsOf(d.areas).length) {
    sec.append(el('p', { class: 'empty' }, 'No read yet: the mssql_checks collection reads the instance every hour, mssql_identity every six hours.'));
    return sec;
  }
  switch (view) {
    case 'options': sec.append(...optionsView(rowsOf(d.options))); break;
    case 'databases': sec.append(...databasesView(rowsOf(d.databases), rowsOf(d.columns), q.get('risk') ?? '')); break;
    case 'flags': sec.append(...flagsView(rowsOf(d.flags))); break;
    case 'build': sec.append(...buildView(rowsOf(d.build)[0], rowsOf(d.suspect))); break;
    case 'alerts': sec.append(...alertsView(rowsOf(d.alerts), rowsOf(d.operators), rowsOf(d.alerting)[0])); break;
    case 'identity': sec.append(...identityView(rowsOf(d.identity), rowsOf(d.identity_scan))); break;
    case 'findings': sec.append(findingsGrid(rowsOf(d.findings))); break;
    default: sec.append(...summaryView(rowsOf(d.areas), rowsOf(d.findings)));
  }
  return sec;
}

// the area cells, DBA Dash's Summary status cells for this instance, each a link to the view behind it
function summaryView(areas: Row[], findings: Row[]): HTMLElement[] {
  const cols: Col[] = [
    { key: 'area', fmt: v => link(areaNames[String(v)] ?? String(v), x => x.set('cv', areaView[String(v)] ?? 'summary')) },
    { key: 'value', label: 'state', cls: (_v, r) => r.sampled !== true ? '' : statusCls(Number(r.critical) ? 'crit' : Number(r.warning) ? 'warn' : 'ok'),
      fmt: (v, r) => r.sampled !== true ? el('span', { class: 'meta' }, 'not read') : titled(String(v ?? ''), Array.isArray(r.detail) ? r.detail.map(String).join('\n') : '') },
    { key: 'critical', num: true }, { key: 'warning', num: true },
    { key: 'note', label: 'not read because, or left out', wide: true },
    { key: 'read_at', label: 'read', fmt: fmtTime },
  ];
  const crit = findings.filter(f => f.severity === 'critical').length, warn = findings.filter(f => f.severity === 'warning').length;
  return [
    el('p', { class: 'meta' }, `${fmtNum(crit)} critical, ${fmtNum(warn)} warning and ${fmtNum(findings.length - crit - warn)} advice finding(s). `
      + 'Green: every rule of the area is met. Yellow: a warning. Red: a critical finding. A cell\'s title lists what it found.'),
    grid(areas, cols, 'No area read yet.'),
  ];
}

// every sys.configurations option, worst first: the value in use coloured by its verdict (DBA Dash's Configuration grid)
function optionsView(rows: Row[]): HTMLElement[] {
  const n = (s: string) => rows.filter(r => r.is_present !== false && r.status === s).length;
  const cols: Col[] = [
    { key: 'name', label: 'option' },
    { key: 'value_in_use', label: 'in use', num: true, cls: (_v, r) => statusCls(r.status),
      fmt: (v, r) => titled(fmtNum(v), 'best practice: ' + verdict(r.status, r.severity)) },
    { key: 'default_value', label: 'default', num: true, fmt: fmtNum },
    { key: 'advised', label: 'advised', fmt: (v, r) => r.status === 'warn' || r.status === 'crit' ? String(v ?? '') : '' },
    { key: 'status', label: 'verdict', fmt: (v, r) => verdict(v, r.severity) },
    { key: 'value_set', label: 'set', num: true, fmt: (v, r) => r.pending === true ? el('span', {}, fmtNum(v), ' ', badge('not in use yet', 'warn')) : fmtNum(v) },
    { key: 'detail', label: 'why', wide: true },
    { key: 'rule' },
  ];
  return [
    el('p', { class: 'meta' }, `${fmtNum(rows.length)} options: ${fmtNum(n('crit'))} critical, ${fmtNum(n('warn'))} deviate, ${fmtNum(n('ok'))} at their `
      + `default or best practice, ${fmtNum(n('none'))} without a known default. Green: at the default or the best practice. Yellow: a `
      + 'warning or an advice rule is broken (a value only off its default is advice). Red: a critical rule is broken. The defaults '
      + 'are sp_Blitz\'s table; the rules sp_Blitz\'s, sp_PerfCheck\'s, dbachecks\' and Glenn Berry\'s, each named in its row.'),
    grid(rows, cols, 'No option read yet.'),
  ];
}

// one row per database, one column per option: a deviating cell coloured and titled with its rule (DBA Dash's DB Options)
function databasesView(dbs: Row[], columns: Row[], risk: string): HTMLElement[] {
  const shown = risk ? dbs.filter(d => d.is_present !== false && dev(d)[risk]) : dbs;
  const cols: Col[] = [{ key: 'database_name', label: 'database', fmt: (v, r) => r.is_present === false ? `${String(v)} (gone)` : String(v ?? '') }];
  for (const c of columns) {
    const key = String(c.key);
    cols.push({
      key: 'opt_' + key, label: String(c.label),
      cls: (_v, r) => { const x = dev(r)[key]; return x ? statusCls(x.status) : opts(r)[key] != null && c.best ? 'status ok' : ''; },
      fmt: (_v, r) => {
        const v = opts(r)[key], x = dev(r)[key];
        const text = v == null ? '' : key === 'last_good_checkdb' && v !== 'never' ? fmtTime(v) : typeof v === 'number' ? fmtNum(v) : String(v);
        return titled(text, x ? `${verdict(x.status, x.severity)} (${String(x.rule ?? '')}): ${String(x.explain ?? '')}` : c.best ? `held to: ${String(c.best)}` : '');
      },
    });
  }
  cols.push({ key: 'deviation_count', label: 'deviations', num: true, fmt: (_v, r) => String(Object.keys(dev(r)).length) });
  const label = columns.find(c => c.key === risk)?.label;
  return [
    el('p', { class: 'meta' }, risk
      ? el('span', {}, `${fmtNum(shown.length)} database(s) whose ${String(label ?? risk)} deviates. `, link('All databases', x => x.delete('risk')))
      : `${fmtNum(dbs.length)} databases. Green: the value meets its rule. Yellow: a warning or an advice rule is broken. Red: a critical `
        + 'rule is broken. Uncoloured: a column shown, not judged. A cell\'s title says the rule and why; hover a heading-less value for what '
        + 'it is held to.'),
    grid(shown.map(flatten), cols, risk ? 'No database deviates on this option.' : 'No database read yet.'),
  ];
}
const opts = (r: Row): Record<string, unknown> => (r.options && typeof r.options === 'object' ? r.options : {}) as Record<string, unknown>;
const dev = (r: Row): Record<string, Record<string, unknown>> => (r.deviations && typeof r.deviations === 'object' ? r.deviations : {}) as Record<string, Record<string, unknown>>;
// a database row with each option as a field of its own, so the grid sorts, filters and exports it
const flatten = (r: Row): Row => {
  const out: Row = { ...r };
  for (const [k, v] of Object.entries(opts(r))) out['opt_' + k] = v;
  out.deviation_count = Object.keys(dev(r)).length;
  return out;
};

function flagsView(rows: Row[]): HTMLElement[] {
  const cols: Col[] = [
    { key: 'flag', num: true },
    { key: 'is_on', label: 'state', cls: (_v, r) => statusCls(r.status), fmt: (v, r) => r.is_present === false ? 'no longer on' : v === true ? 'on' : 'off' },
    { key: 'status', label: 'verdict', fmt: (v, r) => verdict(v, r.severity) },
    { key: 'detail', label: 'what it does', wide: true }, { key: 'rule' },
    { key: 'first_seen', label: 'in this state since', fmt: fmtTime },
  ];
  return [el('p', { class: 'meta' }, 'The trace flags on globally (DBCC TRACESTATUS(-1)), the ones advised on and off, and the ones that were on and are gone.'),
    grid(rows, cols, 'No trace flag is on globally.')];
}

function buildView(b: Row | undefined, suspect: Row[]): HTMLElement[] {
  const out: HTMLElement[] = [el('h3', {}, 'Build')];
  if (!b) out.push(el('p', { class: 'empty' }, 'No read yet.'));
  else {
    const st = el('span', { class: statusCls(b.status) }, b.known !== true ? 'not weighed' : b.newer === true ? 'newer than the catalogue' : Number(b.behind) === 0 ? 'the newest build' : `${String(b.behind)} build(s) behind, ${String(b.cus_behind)} cumulative update(s)`);
    out.push(props([
      ['version', String(b.product_version ?? '')], ['state', st],
      ['update', [b.branch, b.update_name ? `(${String(b.update_name)})` : ''].filter(Boolean).map(String).join(' ')],
      ['released', String(b.release_date ?? '')],
      ['newest of the major', b.newest_build == null ? '' : `${String(b.newest_branch)}, build ${String(b.newest_build)}, released ${String(b.newest_release_date)}`],
      ['mainstream support ends', String(b.mainstream_end ?? '')], ['extended support ends', String(b.extended_end ?? '')],
      ['note', String(b.note ?? '')], ['catalogue', String(b.catalogue ?? '')], ['read', fmtTime(b.snapshot_at)],
    ]));
  }
  out.push(el('h3', {}, `Suspect pages (${suspect.length})`), el('p', { class: 'meta' }, 'msdb.dbo.suspect_pages: a page SQL Server could not read. '
    + 'The table keeps 1,000 rows; an 823 / 824 error, a bad checksum or a torn page is a finding.'),
  grid(suspect, [
    { key: 'database_name', label: 'database' }, { key: 'file_id', label: 'file', num: true }, { key: 'page_id', label: 'page', num: true },
    { key: 'event', cls: (_v, r) => Number(r.event_type) <= 3 ? 'status crit' : 'status ok' },
    { key: 'error_count', label: 'errors', num: true }, { key: 'last_update_at', label: 'last update', fmt: fmtTime },
  ], 'No suspect page: msdb holds no damaged page.'));
  return out;
}

function alertsView(alerts: Row[], ops: Row[], g: Row | undefined): HTMLElement[] {
  return [
    el('h3', {}, 'Alerts'),
    grid(alerts, [
      { key: 'name' }, { key: 'severity', num: true }, { key: 'message_id', label: 'error', num: true },
      { key: 'enabled', cls: v => v === true ? 'status ok' : 'status warn', fmt: yn },
      { key: 'notifies', label: 'operators notified', num: true, cls: (v, r) => r.enabled === true && Number(v) === 0 && r.has_job !== true ? 'status warn' : '' },
      { key: 'has_job', label: 'starts a job', fmt: yn }, { key: 'include_event_description', label: 'error text in the message', fmt: yn },
      { key: 'occurrence_count', label: 'raised', num: true }, { key: 'last_occurrence_at', label: 'last raised', fmt: fmtTime },
    ], 'No alert is defined: a severe error is written to the log and nobody is told.'),
    el('h3', {}, 'Operators'),
    el('p', { class: 'meta' }, g ? (g.failsafe_read !== true ? 'The fail-safe operator was not readable with the login\'s rights.'
      : g.failsafe_operator ? `Fail-safe operator: ${String(g.failsafe_operator)}.` : 'No fail-safe operator is set.') : ''),
    grid(ops, [
      { key: 'name' }, { key: 'enabled', cls: v => v === true ? 'status ok' : 'status warn', fmt: yn },
      { key: 'has_email', label: 'e-mail set', fmt: yn }, { key: 'last_email_at', label: 'last e-mail', fmt: fmtTime },
    ], 'No operator is defined.'),
  ];
}

function identityView(cols: Row[], scans: Row[]): HTMLElement[] {
  const unscanned = scans.filter(s => s.scanned !== true);
  return [
    el('p', { class: 'meta' }, `${fmtNum(scans.length - unscanned.length)} database(s) scanned, ${fmtNum(unscanned.length)} not (each says why below). `
      + 'Listed: the identity columns at 10 % of their type\'s range or more. Yellow from 75 %, red from 90 %: at the limit every insert fails. '
      + 'The rate is taken against a read up to seven days back.'),
    grid(cols, [
      { key: 'database_name', label: 'database' }, { key: 'schema_name', label: 'schema' }, { key: 'table_name', label: 'table' },
      { key: 'column_name', label: 'column' }, { key: 'type_name', label: 'type' },
      { key: 'pct_used', label: '% used', num: true, cls: (_v, r) => statusCls(r.status), fmt: fmtNum },
      { key: 'last_value', label: 'last value', num: true, fmt: fmtNum }, { key: 'max_value', label: 'limit', num: true, fmt: fmtNum },
      { key: 'per_day', label: 'per day', num: true, fmt: fmtNum }, { key: 'days_left', label: 'days left', num: true, fmt: fmtNum },
    ], 'No identity column at 10 % of its range or more.'),
    el('h3', {}, 'Scan state'),
    grid(scans, [
      { key: 'database_name', label: 'database' },
      { key: 'scanned', label: 'state', cls: v => v === true ? 'status ok' : 'status warn',
        fmt: (v, r) => v === true ? `scanned, ${String(r.listed ?? 0)} of ${String(r.columns_total ?? 0)} columns listed` : String(r.note ?? 'not scanned') },
      { key: 'scanned_at', label: 'last scanned', fmt: fmtTime },
    ], 'No database scanned yet.'),
  ];
}

function findingsGrid(rows: Row[]): HTMLElement {
  return grid(rows, [
    { key: 'severity', fmt: sev }, { key: 'area', fmt: v => areaNames[String(v)] ?? String(v) }, { key: 'check_name', label: 'check' },
    { key: 'object' }, { key: 'value', label: 'number' }, { key: 'rule' }, { key: 'detail', wide: true },
    { key: 'first_seen', label: 'raised since', fmt: fmtTime },
  ], 'No finding: every rule is met.');
}

// The fleet: per instance the count of databases with each risky option (DBA Dash's DB Options summary), each count
// a link to those databases, and the server options that deviate; under it the server-option pivot, one column per
// instance, the odd value coloured by its verdict.
const risks: [string, string, string][] = [   // the column, its heading, the database grid's option key behind it
  ['page_verify', 'Page verify not optimal', 'page_verify'], ['auto_close', 'Auto close', 'auto_close'], ['auto_shrink', 'Auto shrink', 'auto_shrink'],
  ['stats_off', 'Stats off', 'auto_update_stats'], ['old_compat', 'Old compat level', 'compatibility_level'], ['trustworthy', 'Trustworthy', 'trustworthy'],
  ['no_indirect_checkpoint', 'No indirect checkpoints', 'target_recovery_secs'], ['delayed_durability', 'Delayed durability', 'delayed_durability'],
  ['not_online', 'Not online', 'state'], ['not_multi_user', 'Not multi user', 'user_access'], ['vlf_high', 'VLF count high', 'vlf_count'],
];

export async function mssqlChecksFleetView(_ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'SQL Server options'));
  let d: FleetParts;
  try { d = await get<FleetParts>('mssql/checks/fleet'); } catch (e) { sec.append(errorBox(e)); return sec; }
  const rs = rowsOf(d.risks);
  const to = (iid: unknown, view: string, risk = '') => `#/${mssqlChecksTab}?i=${String(iid)}&cv=${view}${risk ? '&risk=' + risk : ''}`;
  const count = (key: string, risk: string): Col => ({
    key, label: risks.find(x => x[0] === key)?.[1] ?? key, num: true,
    cls: (v, r) => r.databases_read_at == null ? '' : Number(v) > 0 ? 'status warn' : 'status ok',
    fmt: (v, r) => r.databases_read_at == null ? '' : Number(v) > 0 ? el('a', { href: to(r.instance_id, 'databases', risk) }, fmtNum(v)) : '0',
  });
  const cols: Col[] = [
    { key: 'instance_name', label: 'instance', fmt: (v, r) => el('a', { href: to(r.instance_id, 'summary') }, String(v ?? '')) },
    { key: 'user_databases', label: 'user databases', num: true },
    ...risks.map(([k, , risk]) => count(k, risk)),
    { key: 'max_vlf', label: 'max VLF count', num: true, fmt: fmtNum },
    { key: 'option_critical', label: 'options critical', num: true, cls: v => Number(v) > 0 ? 'status crit' : 'status ok',
      fmt: (v, r) => Number(v) > 0 ? el('a', { href: to(r.instance_id, 'options') }, fmtNum(v)) : '0' },
    { key: 'option_warning', label: 'options warning', num: true, cls: v => Number(v) > 0 ? 'status warn' : 'status ok',
      fmt: (v, r) => Number(v) > 0 ? el('a', { href: to(r.instance_id, 'options') }, fmtNum(v)) : '0' },
    { key: 'option_advice', label: 'options off their default', num: true, fmt: fmtNum },
    { key: 'databases_read_at', label: 'read', fmt: v => v == null ? 'not yet' : fmtTime(v) },
  ];
  sec.append(el('p', { class: 'meta' }, 'Per SQL Server instance, the databases with each risky option; each count opens those databases. '
    + 'Green: none. Yellow: some.'), grid(rs, cols, 'No SQL Server instance read yet.'));

  // the pivot: one row per option, one column per instance
  const ops = rowsOf(d.options);
  const names = [...new Set(ops.map(o => String(o.name)))];
  const insts = rs.map(r => [Number(r.instance_id), String(r.instance_name)] as [number, string]);
  const by = new Map(ops.map(o => [`${String(o.name)}|${String(o.instance_id)}`, o]));
  const pivot: Row[] = names.map(n => {
    const row: Row = { name: n };
    for (const [id] of insts) row['i' + id] = by.get(`${n}|${id}`)?.value_in_use ?? null;
    const vals = insts.map(([id]) => row['i' + id]).filter(v => v != null).map(String);
    row.differs = new Set(vals).size > 1;
    return row;
  });
  const pcols: Col[] = [{ key: 'name', label: 'option' }, ...insts.map(([id, name]): Col => ({
    key: 'i' + id, label: name, num: true,
    cls: (_v, r) => statusCls(by.get(`${String(r.name)}|${id}`)?.status),
    fmt: (v, r) => { const o = by.get(`${String(r.name)}|${id}`); return o ? titled(fmtNum(v), `${verdict(o.status, o.severity)}${o.detail ? ': ' + String(o.detail) : ''}`) : ''; },
  })), { key: 'differs', label: 'differs across the fleet', fmt: yn }];
  sec.append(el('h3', {}, 'Server options across the fleet'),
    el('p', { class: 'meta' }, 'Every option a column per instance, the value in use coloured by its verdict on that instance (green at the default '
      + 'or best practice, yellow a deviation, red a critical rule broken).'),
    grid(pivot, pcols, 'No option read yet.'));
  return sec;
}
