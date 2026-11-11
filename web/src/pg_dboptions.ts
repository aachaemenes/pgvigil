// PostgreSQL database options and setting overrides in DBA Dash's colours (task 163; the database-options grid of DBA
// Dash for PostgreSQL) and the fleet's risk counts. Data: /api/pg/dboptions and /api/pg/dboptions/fleet (migration
// 0104; the collections databases, connections, versions, instance and dbsettings).
//
// Green: the value meets its rule. Yellow: a warning or an advice rule is broken. Red: a critical rule is broken. Grey:
// not judged here, or the version lacks it. The colour never stands alone: every coloured cell carries its verdict as
// its title, and a column of words in the same row says it too (the export carries both).
//
// The instance page's risk filter rides its hash (risk=<key>: the fleet's counts link there): the database grid shows
// only the databases behind that count, or, for risk=overrides, the overrides grid only the ones that break a rule.
import { get, Row, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';

// the tab keys of the instance page and of the fleet page (the router's entries carry the same keys)
export const pgDbOptionsTab = 'pgdboptions';
export const pgDbOptionsFleetTab = 'pgrisks';

type Parts = Record<'state' | 'databases' | 'overrides' | 'overrides_read' | 'findings', Table | null>;

const statusCls = (s: unknown): string => s === 'ok' || s === 'warn' || s === 'crit' || s === 'none' ? 'status ' + String(s) : '';
const verdict = (status: unknown, severity: unknown): string => {
  switch (status) {
    case 'crit': return 'deviates: critical';
    case 'warn': return severity === 'info' ? 'deviates: advice' : 'deviates: warning';
    case 'ok': return 'meets the rule';
    default: return 'not judged';
  }
};
const sev = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : 'info');
const titled = (text: string, title: string): Node => title ? el('span', { title }, text) : document.createTextNode(text);
const str = (v: unknown): string => v == null ? '' : String(v);

// the database cells: the key of the view's <key>_status / _severity / _note columns, the heading, the risk key of the
// fleet's count behind it and the statuses that count
interface Cell { key: string; label: string; value: (r: Row) => string; risk: string[] }
const cells: Cell[] = [
  { key: 'conn', label: 'connection limit', risk: ['at_limit', 'near_limit'],
    value: r => Number(r.conn_limit) < 0 ? `no limit${r.sessions != null ? ` (${fmtNum(r.sessions)} sessions)` : ''}`
      : `${r.sessions != null ? fmtNum(r.sessions) : '?'} of ${fmtNum(r.conn_limit)}` },
  { key: 'allow', label: 'allow connections', risk: ['no_connections'], value: r => r.allow_conn === true ? 'yes' : r.allow_conn === false ? 'no' : '' },
  { key: 'encoding', label: 'encoding', risk: ['not_utf8'], value: r => str(r.encoding) },
  { key: 'collation', label: 'collation version', risk: ['collation_mismatch'],
    value: r => r.recorded_version == null ? (Number(r.server_version_num) < 150000 ? 'PostgreSQL 15+' : r.collation_status === 'none' && r.collation_provider == null ? 'not read' : 'no version')
      : r.recorded_version === r.actual_version ? str(r.recorded_version) : `${str(r.recorded_version)}, library ${str(r.actual_version)}` },
  { key: 'checksums', label: 'data checksums', risk: ['checksums_off'], value: r => str(r.data_checksums) },
  { key: 'xid', label: 'xid age', risk: ['xid_past_freeze'], value: r => r.xid_age == null ? '' : fmtNum(r.xid_age) },
];
// the risk keys of the fleet's counts and the cell statuses each stands for
const riskOf: Record<string, [string, string[]]> = {
  at_limit: ['conn', ['crit']], near_limit: ['conn', ['warn']], no_connections: ['allow', ['warn']], not_utf8: ['encoding', ['warn']],
  collation_mismatch: ['collation', ['warn']], checksums_off: ['checksums', ['warn']], xid_past_freeze: ['xid', ['warn', 'crit']],
};
const riskLabel: Record<string, string> = {
  at_limit: 'at their connection limit or invalid', near_limit: 'near their connection limit or closed by a limit of 0', no_connections: 'not allowing connections',
  not_utf8: 'not UTF8', collation_mismatch: 'with a collation version mismatch', checksums_off: 'without data checksums',
  xid_past_freeze: 'past autovacuum_freeze_max_age', overrides: 'overrides that break a rule',
};

function hashQS(): URLSearchParams { return new URLSearchParams(location.hash.split('?')[1] ?? ''); }
function hrefWith(change: (q: URLSearchParams) => void): string {
  const [path, qs] = location.hash.split('?');
  const q = new URLSearchParams(qs ?? '');
  change(q);
  return `${path || '#/' + pgDbOptionsTab}?${q}`;
}

export async function pgDbOptionsView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Database options'));
  let d: Parts;
  try { d = await get<Parts>('pg/dboptions', { instance: ctx.instance }); } catch (e) { sec.append(errorBox(e)); return sec; }
  // a risk key this page knows, else none (an unknown or an inherited name such as 'constructor' shows everything)
  const asked = hashQS().get('risk') ?? '';
  const risk = asked === 'overrides' || Object.prototype.hasOwnProperty.call(riskOf, asked) ? asked : '';
  const dbs = rowsOf(d.databases), ovs = rowsOf(d.overrides), finds = rowsOf(d.findings);
  const read = rowsOf(d.overrides_read)[0];
  const state = rowsOf(d.state);
  const failing = state.filter(s => s.status !== 'ok');
  sec.append(el('p', { class: 'meta' },
    'Each database\'s options and every ALTER DATABASE / ALTER ROLE ... SET override, coloured as DBA Dash colours its database options: green '
    + 'where the value meets its rule, yellow where a warning or an advice rule is broken, red where a critical one is, grey where it is not '
    + 'judged here or the version lacks it. An override is held to the same rule as the server\'s own value (the Configuration page\'s Best '
    + 'practice grid); every broken rule is also a finding.'
    + (failing.length ? ` Not read in full: ${failing.map(s => `${str(s.collection)} (${str(s.status)}${s.note ? ': ' + str(s.note) : ''})`).join(', ')}.` : '')));
  if (risk) sec.append(el('p', { class: 'meta' }, `Shown: ${risk === 'overrides' ? 'the' : 'the databases'} ${riskLabel[risk] ?? risk}. `,
    el('a', { href: hrefWith(q => q.delete('risk')) }, 'Show everything')));
  if (risk !== 'overrides') sec.append(...databasesGrid(dbs, risk));
  if (!risk || risk === 'overrides') sec.append(...overridesGrid(ovs, read, risk === 'overrides'));
  if (!risk) sec.append(el('h3', {}, 'Findings'),
    el('p', { class: 'meta' }, 'The findings of the overrides and of the connection limit, allow connections and encoding cells. The collation, '
      + 'checksums and xid age cells raise theirs on the Findings page (collation version, data_checksums, database xid age).'),
    grid(finds, [
      { key: 'severity', fmt: sev }, { key: 'kind', label: 'of' }, { key: 'setting' }, { key: 'value' }, { key: 'detail', wide: true },
    ], d.overrides_read == null && !dbs.length ? 'Nothing read yet.' : 'No finding: every override and every connection limit, allow connections and encoding cell meets its rule.'));
  return sec;
}

function databasesGrid(all: Row[], risk: string): HTMLElement[] {
  const want = riskOf[risk];
  const rows = want ? all.filter(r => want[1].includes(str(r[want[0] + '_status']))) : all;
  const cols: Col[] = [{ key: 'datname', label: 'database', fmt: (v, r) => r.is_template === true ? `${str(v)} (template)` : str(v) }];
  for (const c of cells) {
    cols.push({
      key: c.key === 'xid' ? 'xid_age' : c.key + '_text', label: c.label, num: c.key === 'xid',
      cls: (_v, r) => statusCls(r[c.key + '_status']),
      fmt: (_v, r) => titled(c.value(r), `${verdict(r[c.key + '_status'], r[c.key + '_severity'])}: ${str(r[c.key + '_note'])}`),
    });
  }
  // the colours in words: every deviating cell of the row with its verdict
  cols.push({ key: 'deviation_text', label: 'deviates', wide: true });
  const shown = rows.map(r => {
    const out: Row = { ...r };
    for (const c of cells) if (c.key !== 'xid') out[c.key + '_text'] = c.value(r);
    out.deviation_text = cells.filter(c => r[c.key + '_status'] === 'warn' || r[c.key + '_status'] === 'crit')
      .map(c => `${c.label}: ${verdict(r[c.key + '_status'], r[c.key + '_severity']).replace('deviates: ', '')}`).join('; ') || 'none';
    return out;
  });
  const n = (s: string) => all.filter(r => r.worst === s).length;
  return [
    el('h3', {}, 'Databases'),
    el('p', { class: 'meta' }, `${fmtNum(all.length)} databases: ${fmtNum(n('crit'))} with a critical deviation, ${fmtNum(n('warn'))} with a warning `
      + 'or an advice. Connection limit: the sessions of the newest connections read (every minute; the collector\'s own left out) against '
      + 'CONNECTION LIMIT - red reached (a login that is not a superuser is refused) or an invalid database (an interrupted DROP DATABASE), '
      + 'yellow at 80 % or more, or a limit of 0; grey where the read folded its smallest sources (the count is then a floor). Allow '
      + 'connections: off on a database that is not a template is yellow. Encoding: other than UTF8 is advice (template0 not judged). '
      + 'Collation version: the version recorded against the library\'s now (PostgreSQL 15+). Data checksums: the cluster\'s, on every row. '
      + 'xid age: age(datfrozenxid) - yellow at or past autovacuum_freeze_max_age, red at 1 billion or more. A cell\'s title says the rule and why.'),
    grid(shown, cols, risk ? 'No database behind this count now.' : 'No database read yet.'),
  ];
}

function overridesGrid(all: Row[], read: Row | undefined, brokenOnly: boolean): HTMLElement[] {
  const rows = brokenOnly ? all.filter(r => r.status === 'warn' || r.status === 'crit') : all;
  const shownVerdict = (r: Row): string => r.value_read !== true && Number(r.server_rules) > 0 ? 'value not read: not judged'
    : r.status === 'none' && Number(r.rules) === 0 ? 'no rule' : verdict(r.status, r.severity);
  const unitOf = (r: Row) => r.unit ? ` ${str(r.unit)}` : '';
  // the value as written, and as the rules read it where that differs (256MB = 262144 kB)
  const valueText = (r: Row): string => str(r.raw_value) + (r.value_read === true && str(r.value) !== str(r.raw_value) ? ` = ${str(r.value)}${unitOf(r)}` : '');
  // the server's value: uncoloured where the instance read takes this very override as the server's (ALTER ROLE ALL SET,
  // an override of the database the collector connects to)
  const serverStatus = (r: Row): unknown => r.server_from_override === true ? null : r.server_status;
  const serverText = (r: Row): string => r.server_value == null ? '' : str(r.server_value) + unitOf(r) + (r.server_is_set === true ? '' : ' (default)');
  const serverVerdict = (r: Row): string => r.server_from_override === true ? 'the server: read under this override'
    : r.server_status ? 'the server: ' + verdict(r.server_status, r.server_severity) : '';
  const cols: Col[] = [
    { key: 'setting' },
    { key: 'statement', label: 'set by' },
    { key: 'value_text', label: 'value', cls: (_v, r) => statusCls(r.status),
      fmt: (_v, r) => titled(valueText(r), `${shownVerdict(r)}${r.detail && (r.status === 'warn' || r.status === 'crit') ? ': ' + str(r.detail) : ''}`) },
    { key: 'server_text', label: 'the server\'s value', cls: (_v, r) => statusCls(serverStatus(r)),
      fmt: (_v, r) => titled(serverText(r), serverVerdict(r)) },
    { key: 'suggested', fmt: (v, r) => r.status === 'warn' || r.status === 'crit' ? str(v) : '' },
    // the colours in words: the override's verdict and the server's
    { key: 'verdict_text', label: 'verdict', fmt: (v) => str(v) },
    { key: 'detail', label: 'what the rule guards against', wide: true, fmt: (v, r) => Number(r.rules) > 0 ? str(v) : '' },
    { key: 'first_seen', label: 'set since', fmt: v => v == null ? '' : fmtTime(v) },
  ];
  const shown = rows.map(r => ({ ...r, value_text: valueText(r), server_text: serverText(r),
    verdict_text: [shownVerdict(r), serverVerdict(r)].filter(Boolean).join('; ') }));
  const n = (s: string) => all.filter(r => r.status === s).length;
  return [
    el('h3', {}, 'Setting overrides'),
    el('p', { class: 'meta' }, read
      ? `${fmtNum(all.length)} override(s) read ${fmtTime(read.snapshot_at)}: ${fmtNum(n('crit'))} break a critical rule, ${fmtNum(n('warn'))} a `
        + `warning or an advice rule, ${fmtNum(n('ok'))} meet theirs, ${fmtNum(n('none'))} carry no rule here. The value as ALTER ... SET wrote `
        + 'it, read in the setting\'s base unit as the rules compare it; the server\'s value beside it in the colour the Best practice grid gives it. '
        + 'ALTER ROLE ALL IN DATABASE ... SET is stored as ALTER DATABASE ... SET and is shown so. A setting a session cannot set '
        + '(autovacuum, the checkpoint settings: a reload setting) cannot be overridden: PostgreSQL refuses the ALTER.'
      : 'The overrides have not been read yet (the dbsettings collection runs every hour).'),
    grid(shown, cols, !read ? 'Not read yet.' : brokenOnly ? 'No override breaks a rule now.' : 'No ALTER DATABASE / ALTER ROLE ... SET override on this server.'),
  ];
}

// The fleet: per PostgreSQL instance the databases behind each risk and the overrides that break a rule, each count a
// link to them (the PostgreSQL twin of the SQL Server options page).
const riskCols: [string, string, string][] = [   // the column, its heading, the colour of a count above 0
  ['at_limit', 'At connection limit or invalid', 'crit'], ['near_limit', 'Near connection limit', 'warn'], ['no_connections', 'Connections not allowed', 'warn'],
  ['not_utf8', 'Not UTF8', 'warn'], ['collation_mismatch', 'Collation mismatch', 'warn'], ['checksums_off', 'Checksums off', 'warn'],
  ['xid_past_freeze', 'xid age past freeze age', 'warn'],
];

export async function pgDbOptionsFleetView(_ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'PostgreSQL options'));
  let d: Record<'risks', Table | null>;
  try { d = await get<Record<'risks', Table | null>>('pg/dboptions/fleet'); } catch (e) { sec.append(errorBox(e)); return sec; }
  const to = (iid: unknown, risk = '') => `#/${pgDbOptionsTab}?i=${str(iid)}${risk ? '&risk=' + encodeURIComponent(risk) : ''}`;
  // a count's title says what it counts; its colour is the column's (red where any of them is critical)
  const count = (key: string, label: string, colour: string, readKey: string): Col => {
    const rk = key === 'overrides_broken' ? 'overrides' : key;
    return {
      key, label, num: true,
      cls: (v, r) => r[readKey] == null ? '' : Number(v) > 0 ? 'status ' + colour : 'status ok',
      fmt: (v, r) => r[readKey] == null ? 'not read' : Number(v) > 0
        ? el('a', { href: to(r.instance_id, rk), title: `${fmtNum(v)} ${rk === 'overrides' ? '' : 'databases '}${riskLabel[rk]}: open them` }, fmtNum(v))
        : el('span', { title: `no ${rk === 'overrides' ? '' : 'database '}${riskLabel[rk]}` }, '0'),
    };
  };
  const cols: Col[] = [
    { key: 'instance_name', label: 'instance', fmt: (v, r) => el('a', { href: to(r.instance_id) }, str(v)) },
    { key: 'user_databases', label: 'user databases', num: true },
    ...riskCols.map(([k, label, colour]) => k === 'xid_past_freeze'
      ? { ...count(k, label, colour, 'databases_read_at'), cls: (v: unknown, r: Row) => r.databases_read_at == null ? '' : Number(r.xid_critical) > 0 ? 'status crit' : Number(v) > 0 ? 'status warn' : 'status ok' }
      : count(k, label, colour, 'databases_read_at')),
    { ...count('overrides_broken', 'Overrides breaking a rule', 'warn', 'overrides_read_at'),
      cls: (v, r) => r.overrides_read_at == null ? '' : Number(r.overrides_critical) > 0 ? 'status crit' : Number(v) > 0 ? 'status warn' : 'status ok' },
    { key: 'overrides', label: 'overrides', num: true, fmt: (v, r) => r.overrides_read_at == null ? '' : fmtNum(v) },
    { key: 'databases_read_at', label: 'read', fmt: v => v == null ? 'not yet' : fmtTime(v) },
  ];
  sec.append(el('p', { class: 'meta' }, 'Per PostgreSQL instance, the databases behind each risk and the ALTER DATABASE / ALTER ROLE ... SET overrides '
    + 'that break the rule the server\'s own value is held to; each count opens them. Green: none. Yellow: some. Red: a database at its '
    + 'connection limit or invalid, an xid age of 1 billion or more, or an override that breaks a critical rule.'), grid(rowsOf(d.risks), cols, 'No PostgreSQL instance read yet.'));
  return sec;
}
