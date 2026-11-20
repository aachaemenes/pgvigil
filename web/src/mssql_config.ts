// The Configuration tab of a SQL Server instance: the values that changed between two reads on top, then every value
// of sys.configurations (a value set and not yet in use is marked: it waits for RECONFIGURE or a restart), then the
// services the server lists. Data from /api/mssql/config (mssql_instance, read hourly; mssql_services, every 5 minutes).
// On top of them the Checks (task 409): every configuration rule of the instance against its expected value, the facts
// those rules read (event sessions, the databases' rows, the linked servers and their connection test) and the
// Expected values editor. Data from /api/mssql/config_checks and /api/mssql/config_expect (migration 0160).
import { get, post, Row, rowsOf, Table } from './api';
import { Ctx } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';
import { changedText } from './diff';
import { loadAckSafe, offBeside, pageNote, seatWhy } from './ack';
import { needControl } from './needs';

// task 154: every change with valid from / to (/api/config/changes), the fleet pivot with the odd value marked
// (/api/mssql/config/fleet) and the trace flags with their history (/api/mssql/traceflags). Each part that its
// route does not answer (an older server) says so and the rest of the page stands.
async function safe<T>(f: () => Promise<T>): Promise<T | Error> { try { return await f(); } catch (e) { return e instanceof Error ? e : new Error(String(e)); } }

type Parts = Record<'values' | 'services', Table | null>;
const yn = (v: unknown) => v === true ? 'yes' : v === false ? 'no' : '';
const num = (v: unknown) => v == null ? '' : fmtNum(v);

export async function mssqlConfigView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Parts>('mssql/config', { instance: ctx.instance });
  const values = rowsOf(d.values), services = rowsOf(d.services);
  const sec = el('section', {}, el('h2', {}, 'Configuration'));
  sec.append(await configChecksBox(ctx));
  if (values.length === 0) {
    sec.append(el('p', { class: 'empty' }, 'No read yet: the mssql_instance collection reads sys.configurations every hour.'));
    return sec;
  }
  const changed = values.filter(r => r.changed_at != null).sort((a, b) => String(b.changed_at).localeCompare(String(a.changed_at)));
  const pending = values.filter(r => r.pending === true && r.is_present !== false);
  // the newest read: a value no longer listed keeps the time of the last read that saw it
  const lastRead = values.map(r => String(r.snapshot_at ?? '')).reduce((a, b) => b > a ? b : a, '');
  sec.append(el('p', { class: 'meta counts' }, `${values.filter(r => r.is_present !== false).length} values, read ${fmtTime(lastRead)}; `,
    `${changed.length} changed since pgvigil first read them; `,
    pending.length ? el('span', { class: 'warn' }, `${pending.length} set and not in use yet`) : 'none waiting to take effect', '.'));
  const changeCols: Col[] = [
    { key: 'name' }, { key: 'previous_in_use', label: 'was', fmt: num }, { key: 'value_in_use', label: 'now in use', fmt: num },
    { key: 'changed_at', label: 'seen changed', fmt: fmtTime },
  ];
  sec.append(el('h3', {}, 'Changes'), el('p', { class: 'meta' }, 'A value whose value in use differed from the read before. The time is the read that saw it, within the hour of the change; the last change of each value is kept.'),
    grid(changed, changeCols, 'No value has changed between two reads.'));
  const valueCols: Col[] = [
    { key: 'name' },
    { key: 'value_in_use', label: 'in use', fmt: num },
    // a dynamic option waits for RECONFIGURE, any other for a restart of the service; a value no longer listed waits for nothing
    { key: 'value', label: 'set', fmt: (v, r) => r.pending === true && r.is_present !== false
      ? el('span', {}, num(v), ' ', badge(r.is_dynamic === true ? 'needs RECONFIGURE' : r.is_dynamic === false ? 'needs a restart' : 'not in use yet', 'warn')) : num(v), cls: (v, r) => (r.pending === true && r.is_present !== false) || v == null ? '' : 'status ok' },
    { key: 'minimum', fmt: num }, { key: 'maximum', fmt: num },
    { key: 'is_dynamic', label: 'dynamic', fmt: yn }, { key: 'is_advanced', label: 'advanced', fmt: yn },
    { key: 'is_present', label: 'listed', fmt: v => v === false ? 'no longer' : 'yes' },
  ];
  sec.append(el('h3', {}, 'Values'), grid(values, valueCols));
  const [log, fleet, tf] = await Promise.all([
    safe(() => get<Record<'changes', Table | null>>('config/changes', { instance: ctx.instance })),
    safe(() => get<Record<'pivot', Table | null>>('mssql/config/fleet')),
    safe(() => get<Record<'flags' | 'history' | 'read', Table | null>>('mssql/traceflags', { instance: ctx.instance }))]);
  sec.append(el('h3', {}, 'Configuration change log'), el('p', { class: 'meta' }, 'Every value that was replaced, with the time it was in force: valid from the read that first saw it to the read that saw the next one. "first read": the value was there when pgvigil first read the server, so it began earlier.'));
  sec.append(log instanceof Error ? errorBox(log) : grid(rowsOf(log.changes), [
    { key: 'name' },
    { key: 'value_in_use', label: 'value in use', fmt: (v, r) => changedText(String(v ?? ''), r.removed ? '(no longer listed)' : String(r.new_value_in_use ?? '')) },
    { key: 'value', label: 'value set', fmt: num }, { key: 'new_value', label: 'new value set', fmt: num },
    { key: 'valid_from', label: 'valid from', fmt: (v, r) => v == null ? '(before pgvigil kept it)' : fmtTime(v) + (r.first_read ? ' (first read)' : '') },
    { key: 'valid_to', label: 'valid to', fmt: fmtTime },
    { key: 'is_dynamic', label: 'dynamic', fmt: yn }, { key: 'is_advanced', label: 'advanced', fmt: yn },
    { key: 'minimum', fmt: num }, { key: 'maximum', fmt: num },
  ], 'No value has changed since pgvigil first read it.'));
  sec.append(el('h3', {}, 'The fleet'));
  if (fleet instanceof Error) sec.append(errorBox(fleet)); else sec.append(...fleetPivot(rowsOf(fleet.pivot), Number(ctx.instance)));
  sec.append(el('h3', {}, 'Trace flags'));
  if (tf instanceof Error) sec.append(errorBox(tf));
  else if (!rowsOf(tf.read).length) sec.append(el('p', { class: 'empty' }, 'Not read yet: the mssql_traceflags collection reads DBCC TRACESTATUS(-1) every hour.'));
  else sec.append(grid(rowsOf(tf.flags), [
      { key: 'trace_flag', label: 'trace flag', num: true },
      { key: 'is_global', label: 'scope', fmt: v => v ? 'global' : 'the collector\'s session only' },
      { key: 'first_seen', label: 'on since', fmt: (v, r) => r.first_read ? `on at the first read (${fmtTime(v)})` : fmtTime(v) },
    ], `No trace flag is on (read ${fmtTime(rowsOf(tf.read)[0].snapshot_at)}).`),
    el('h4', {}, 'History'),
    grid(rowsOf(tf.history), [{ key: 'changed_at', label: 'change date', fmt: fmtTime }, { key: 'trace_flag', label: 'trace flag', num: true },
      { key: 'change', fmt: v => v === 'removed' ? badge('removed', 'warn') : 'added', cls: v => v === 'removed' ? '' : 'status ok' }], 'No flag was added or removed since the first read.'));
  const svcCols: Col[] = [
    { key: 'service_name', label: 'service' },
    { key: 'status', fmt: (v, r) => r.is_present === false ? 'no longer listed' : v === 'Running' ? String(v) : badge(String(v ?? ''), 'warn'), cls: (v, r) => r.is_present === false ? 'status none' : v === 'Running' ? 'status ok' : '' },
    { key: 'startup_type', label: 'start mode' }, { key: 'service_account', label: 'account' },
    { key: 'last_startup_at', label: 'started', fmt: fmtTime },
    { key: 'ifi_enabled', label: 'instant file initialization', fmt: yn }, { key: 'is_clustered', label: 'clustered', fmt: yn },
  ];
  sec.append(el('h3', {}, 'Services'), grid(services, svcCols, 'No service listed: an Azure SQL Database or a managed instance lists none, a login without the right to read sys.dm_server_services sees none (see Collection on the Summary), or the mssql_services collection has not run yet.'));
  return sec;
}

// fleetPivot: sys.configurations across the fleet, an instance a row and an option a column (DBA Dash's
// Configuration grid). The odd value out (not the one most instances run) is amber and says so in its title and
// with a '*'; only the options whose values differ are columns unless every option is asked for.
function fleetPivot(rows: Row[], here: number): HTMLElement[] {
  if (!rows.length) return [el('p', { class: 'empty' }, 'No SQL Server instance has been read yet.')];
  const insts = [...new Map(rows.map(r => [Number(r.instance_id), String(r.instance)])).entries()].sort((a, b) => a[1].localeCompare(b[1]));
  const byKey = new Map(rows.map(r => [`${String(r.instance_id)}|${String(r.name)}`, r]));
  const all = [...new Set(rows.map(r => String(r.name)))].sort();
  const differ = all.filter(n => rows.some(r => r.name === n && Number(r.distinct_values) > 1));
  const box = el('div');
  const draw = (showAll: boolean) => {
    const names = showAll ? all : differ;
    const cols: Col[] = [{ key: 'instance', fmt: (v, r) => Number(r.id) === here ? el('b', {}, String(v)) : String(v) },
      ...names.map(n => ({ key: n, num: true,
        cls: (_v: unknown, r: Row) => byKey.get(`${String(r.id)}|${n}`)?.is_odd ? 'status warn' : '',
        fmt: (v: unknown, r: Row) => { const x = byKey.get(`${String(r.id)}|${n}`); if (!x) return '(not listed)';
          return x.is_odd ? el('span', { title: `differs from the fleet: most instances run ${x.common_in_use ?? '(no single value: a tie)'}` }, `${fmtNum(v)} *`) : fmtNum(v); } }))];
    const data = insts.map(([id, name]) => Object.fromEntries([['id', id], ['instance', name], ...names.map(n => [n, byKey.get(`${id}|${n}`)?.value_in_use ?? null])]));
    box.replaceChildren(grid(data, cols, 'Every instance runs the same values.'));
  };
  const cb = el('input', { type: 'checkbox', id: 'cfg-pivot-all' });
  cb.addEventListener('change', () => draw(cb.checked));
  draw(false);
  return [el('p', { class: 'meta' }, `${insts.length} instance(s); ${differ.length} of ${all.length} options differ across them. A value marked * (amber) is not the one most instances run; where two values tie, every value is marked.`),
    el('label', { for: 'cfg-pivot-all' }, cb, ' Show every option'), box];
}

// ---- task 409: the Checks grid, the facts behind it and the Expected values editor ---------------------------------
type CheckParts = Record<'checks' | 'parts' | 'facts' | 'xe' | 'databases' | 'linked' | 'runs', Table | null>;
type ExpectParts = Record<'keys' | 'in_force' | 'tags', Table | null>;

// The status word carries the meaning, the colour repeats it: green met; amber 'info' (a deviation shown, no
// finding) and 'warning'; red 'critical'; off, not read and not applicable stay grey - never green.
const checkCls = (s: unknown): string => s === 'ok' ? 'status ok' : s === 'info' || s === 'warning' ? 'status warn' : s === 'critical' ? 'status crit' : '';
const listText = (v: unknown): string => Array.isArray(v) ? v.map(String).join(', ') : v == null ? '' : String(v);
const onOff = (v: unknown) => v === true ? 'on' : v === false ? 'off' : '';

async function configChecksBox(ctx: Ctx): Promise<HTMLElement> {
  const box = el('div', { class: 'config-checks' });
  const ad = await loadAckSafe(['acks']);
  const why = seatWhy(ad, 'expected values', ctx.instance ?? undefined);
  // the reason the editor is off, once for the page (each Configure points to it)
  if (why && !pageNote(ad)) ad.note = el('p', { class: 'meta' }, `Expected values are read only here: ${why}`);
  const draw = async (): Promise<void> => {
    const [d, ex] = await Promise.all([
      safe(() => get<CheckParts>('mssql/config_checks', { instance: ctx.instance })),
      safe(() => get<ExpectParts>('mssql/config_expect', { instance: ctx.instance }))]);
    const head = el('h3', { tabindex: '-1' }, 'Checks');
    if (d instanceof Error) { box.replaceChildren(head, errorBox(d)); return; }
    const checks = rowsOf(d.checks), keys = ex instanceof Error ? [] : rowsOf(ex.keys);
    const keyOf = (r: Row): Row | undefined => r.check_name === 'server option'
      ? { kind: 'config', key: String(r.object), vtype: 'number', label: `server option ${String(r.object)}`, takes_exclusions: false, source: 'dbachecks policy' }
      : keys.find(k => k.label === r.check_name);
    const count = (st: string) => checks.filter(r => r.status === st).length;
    const configure = (label: string, aria: string, preset?: Row): HTMLElement => {
      const b = el('button', { type: 'button', class: 'link', 'aria-label': aria }, label);
      if (why) offBeside(b, why, pageNote(ad));
      else if (ex instanceof Error) offBeside(b, `the expected values were not read: ${ex.message}`);
      else b.addEventListener('click', () => expectDialog(ctx, keys, rowsOf(ex.tags), rowsOf(ex.in_force), preset,
        () => void draw().then(() => box.querySelector<HTMLElement>('h3')?.focus())));
      // the role: an expected value needs admin - after the seat's own reason above
      return needControl(b, 'mssql/config_expect');
    };
    const cols: Col[] = [
      { key: 'check_name', label: 'check' }, { key: 'object', label: 'on' }, { key: 'value' }, { key: 'expected' },
      { key: 'set_at', label: 'set at', fmt: v => v == null ? '' : String(v) }, { key: 'source' },
      { key: 'status', cls: v => checkCls(v) },
      { key: 'detail', wide: true }, { key: 'at', label: 'read', fmt: fmtTime },
      { key: 'rule', label: 'expected value', fmt: (_v, r) => { const k = keyOf(r);
        return k ? configure('Configure', `Configure the expected value of ${String(r.check_name)}${r.object ? ' ' + String(r.object) : ''}`, k) : ''; } },
    ];
    const out: (HTMLElement | string)[] = [head,
      el('p', { class: 'meta' }, 'Every configuration rule of this instance, met or not: its value, the expected value, where that expectation is set (default, the root, a tag, the instance) and its source. '
        + 'A rule whose source is a site\'s policy (dbachecks policy) is off until an expected value is set; a rule from Microsoft\'s guidance or a dbatools formula judges by its default and can be set off.'),
      el('p', { class: 'meta' }, badge('ok', 'ok'), ' met; ', badge('info', 'warn'), ' a deviation, shown and never raised as a finding; ', badge('warning', 'warn'), ' and ', badge('critical', 'crit'),
        ' a finding; ', badge('off', ''), ' no expected value is set, a scope switched the rule off, or (linked servers) the instance lacks the tag; ', badge('not read', ''), ' and ', badge('not applicable', ''), ' with the reason beside them, never green.'),
      el('p', { class: 'meta counts' }, `${checks.length} rows: ${count('critical')} critical, ${count('warning')} warning, ${count('info')} info, ${count('ok')} ok, ${count('off')} off, `
        + `${count('not read')} not read, ${count('not applicable')} not applicable.`),
      ...(pageNote(ad) ? [pageNote(ad) as HTMLElement] : []),
      grid(checks, cols, 'No rule to show: this is not a SQL Server instance pgvigil reads (an Azure SQL Database instance has no configuration checks).')];
    // the expected values in force here, with where each is set
    out.push(el('h4', {}, 'Expected values in force'));
    if (ex instanceof Error) out.push(errorBox(ex));
    else {
      const label = (r: Row) => r.kind === 'config' ? `server option ${String(r.key)}` : String(keys.find(k => k.kind === r.kind && k.key === r.key)?.label ?? `${String(r.kind)} ${String(r.key)}`);
      out.push(el('div', { class: 'toolbar' }, configure('Set an expected value', 'Set an expected value for this instance, a tag or the root')),
        grid(rowsOf(ex.in_force).map(r => ({ ...r, rule: label(r) })), [
          { key: 'rule', label: 'check' }, { key: 'value', label: 'expected', fmt: listText }, { key: 'exclusions', label: 'databases left out', fmt: listText },
          { key: 'set_at', label: 'set at' }, { key: 'set_by', label: 'set by' }, { key: 'set_when', label: 'set', fmt: fmtTime },
        ], 'No expected value is set for this instance, its tags or the root: the policy rules above are off.'));
    }
    // what the rules read
    const parts = rowsOf(d.parts), unread = parts.filter(p => p.is_read === false), left = parts.filter(p => p.is_read === true && p.note);
    out.push(el('h4', {}, 'What the checks read'));
    if (!parts.length) out.push(el('p', { class: 'empty' }, 'Not read yet: the mssql_confcheck collection reads the instance\'s names, event sessions, error log files, startup procedures, databases and linked servers every hour.'));
    out.push(...unread.map(p => el('p', { class: 'empty' }, `${String(p.part)}: ${String(p.note ?? 'not read')}`)), ...left.map(p => el('p', { class: 'meta' }, `${String(p.part)}: ${String(p.note)}`)));
    out.push(grid(rowsOf(d.runs), [{ key: 'collection' }, { key: 'status', fmt: v => v == null ? 'no run yet' : String(v) }, { key: 'snapshot_at', label: 'last run', fmt: fmtTime }, { key: 'note', wide: true }]));
    // the facts the rules judge (the names, the machine, the error log files, the startup procedures, the advised MAXDOP)
    const factWords: Record<string, string> = { server_name: '@@SERVERNAME', property_server_name: 'the server\'s own name', machine_name: 'machine', netbios: 'the machine\'s NetBIOS name',
      host_platform: 'host platform', num_errorlogs: 'error log files kept (NumErrorLogs)', errorlog_files: 'error log files present', startup_procs: 'startup procedures',
      advised_maxdop: 'advised MAXDOP', cpu_count: 'CPUs', linked_list_complete: 'every linked server visible to the collector', secondary_roles_unread: 'secondaries not told apart' };
    const facts = rowsOf(d.facts).map(f => ({ ...f, what: factWords[String(f.key)] ?? String(f.key) }));
    out.push(el('h4', {}, 'Facts the checks judge'), grid(facts, [
      { key: 'what', label: 'fact' }, { key: 'value', fmt: (v, r) => r.key === 'linked_list_complete' ? (Number(v) === 1 ? 'yes' : 'no') : r.key === 'startup_procs' && Array.isArray(v) && !v.length ? 'none' : listText(v) },
      { key: 'snapshot_at', label: 'read', fmt: fmtTime }], 'No fact was read yet.'));
    out.push(el('h4', {}, 'Event sessions'), grid(rowsOf(d.xe), [
      { key: 'session_name', label: 'session' }, { key: 'running', fmt: v => v === true ? 'running' : 'stopped' },
      { key: 'autostart', label: 'starts with the server', fmt: yn }, { key: 'snapshot_at', label: 'read', fmt: fmtTime }], 'No event session was read.'));
    out.push(el('h4', {}, 'Databases'), grid(rowsOf(d.databases), [
      { key: 'database_name', label: 'database' }, { key: 'state' }, { key: 'read_only', label: 'read only', fmt: yn }, { key: 'in_standby', label: 'standby', fmt: yn },
      { key: 'recovery_model', label: 'recovery model' }, { key: 'query_store', label: 'Query Store', fmt: onOff },
      { key: 'secondary_role', label: 'a secondary', fmt: v => v == null ? '' : String(v) },
      { key: 'scoped_maxdop', label: 'database-scoped MAXDOP', fmt: (v, r) => v == null ? badge(String(r.scoped_note ?? 'not read'), '') : fmtNum(v) }], 'No database was read.'));
    const testOff = checks.some(r => r.check_name === 'linked server connection test' && r.status === 'off');
    const shortList = rowsOf(d.facts).some(f => f.key === 'linked_list_complete' && Number(f.value) === 0);
    const lastTest = (v: unknown, r: Row): string => {
      const what = v == null ? 'not tested' : v === 'unmapped' ? (Number(r.error_number) === 7416 ? 'not tested: no mapping for the collector\'s login'
        : 'not tested: the login mapped for the collector was refused there') : String(v);
      return testOff && v != null ? `the test is off; last test ${fmtTime(r.tested_at)}: ${what}` : what;
    };
    out.push(el('h4', {}, 'Linked servers'),
      el('p', { class: 'meta' }, 'The connection test runs only on an instance that carries the tag pgvigil:linkedserver-test. It connects FROM the monitored server to each linked server, as the collector\'s own login maps there: '
        + 'a failure can be that login\'s mapping, not the link. Two are tested a run, each in its turn. The list shows who is mapped at each server, never a remote login\'s name.'),
      grid(rowsOf(d.linked), [
        { key: 'name', label: 'linked server' }, { key: 'provider' }, { key: 'data_source', label: 'data source' }, { key: 'product' }, { key: 'catalog' },
        { key: 'rpc_out', label: 'RPC out', fmt: yn }, { key: 'data_access', label: 'data access', fmt: yn },
        { key: 'logins', label: 'who is mapped', fmt: (v, r) => r.logins_read !== true ? badge('not read', '')
          : (Array.isArray(v) ? v : []).map(l => { const m = l as Record<string, unknown>; return `${String(m.local)}: ${m.self === true ? 'its own credential' : m.remote === true ? 'a remote login' : 'no remote login'}`; }).join('; ') },
        { key: 'outcome', label: 'last test', cls: v => testOff ? '' : v === 'ok' ? 'status ok' : v === 'failed' ? 'status warn' : '', fmt: lastTest },
        { key: 'tested_at', label: 'tested', fmt: fmtTime }, { key: 'seconds', label: 'seconds', fmt: num },
        { key: 'error_message', label: 'error', wide: true, fmt: (v, r) => v == null ? String(r.test_note ?? '') : `${String(r.error_number ?? '')}: ${String(v)}` },
        { key: 'first_failed_at', label: 'failing since', fmt: fmtTime }], shortList
        ? 'No linked server is visible to the collector\'s login: ALTER ANY LINKED SERVER, ALTER ANY LOGIN, VIEW ANY DEFINITION, setupadmin or sysadmin shows them all.'
        : 'The instance has no linked server.'));
    box.replaceChildren(...out);
  };
  await draw();
  return box;
}

// expectDialog: one attempt of the Expected values editor - a level (this instance, one of the tags, the root), a
// check, its expected value (a number, a name, a choice, or a list with commas) and, for the database rules, the
// databases left out. Inherit ends this level's own value, so the level above applies.
function expectDialog(ctx: Ctx, keys: Row[], tags: Row[], inForce: Row[], preset: Row | undefined, after: () => void) {
  const level = el('select', { 'aria-label': 'Level' },
    el('option', { value: 'instance' }, 'this instance'),
    ...tags.map(t => el('option', { value: `tag:${String(t.tag)}` }, `the tag ${String(t.tag)}`)),
    el('option', { value: 'root' }, 'the root (every SQL Server instance)'));
  const rule = el('select', { 'aria-label': 'Check' },
    ...keys.map(k => el('option', { value: `${String(k.kind)}|${String(k.key)}` }, `${String(k.label)} (${String(k.source)})`)),
    el('option', { value: 'config|' }, 'a server option (sys.configurations) by its name'));
  const option = el('input', { type: 'text', 'aria-label': 'Server option name', placeholder: 'the option\'s name, as sys.configurations lists it', style: 'width:22rem' });
  const hint = el('p', { class: 'meta', id: 'cfg-exp-hint' }), now = el('p', { class: 'meta', id: 'cfg-exp-now' }), exclHint = el('p', { class: 'meta', id: 'cfg-exp-excl' });
  const value = el('input', { type: 'text', 'aria-label': 'Expected value', 'aria-describedby': 'cfg-exp-hint cfg-exp-now', style: 'width:22rem' });
  const choice = el('select', { 'aria-label': 'Expected value', 'aria-describedby': 'cfg-exp-hint cfg-exp-now' });
  const excl = el('input', { type: 'text', 'aria-label': 'Databases left out', 'aria-describedby': 'cfg-exp-excl', style: 'width:22rem' });
  const optRow = el('div', { style: 'margin:.3rem 0' }, el('label', {}, 'Option ', option));
  const exclRow = el('div', { style: 'margin:.3rem 0' }, el('label', {}, 'Databases left out ', excl), exclHint);
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const save = el('button', { type: 'submit' }, 'Set'), inherit = el('button', { type: 'button' }, 'Inherit'), back = el('button', { type: 'button' }, 'Back');
  const chosen = (): Row => {
    const [kind, key] = rule.value.split('|');
    return kind === 'config' ? { kind, key: option.value.trim().toLowerCase(), vtype: 'number', takes_exclusions: false } : keys.find(k => k.kind === kind && k.key === key) ?? { kind, key };
  };
  // the level as mssql_config_expect_in_force names it: 'instance', 'tag:<name>' or 'root'
  const levelName = (): string => level.value;
  const sync = () => {
    const k = chosen();
    const isChoice = k.vtype === 'choice';
    optRow.hidden = k.kind !== 'config';
    exclRow.hidden = k.takes_exclusions !== true;
    value.hidden = isChoice; choice.hidden = !isChoice;
    if (isChoice) choice.replaceChildren(...(Array.isArray(k.choices) ? k.choices : []).map(c => el('option', { value: String(c) }, String(c))));
    hint.textContent = k.vtype === 'number'
      ? `A whole number${k.vmin != null ? ` from ${String(k.vmin)} to ${String(k.vmax)}` : ''}.`
      : isChoice ? `One of the choices.${k.default_on === true ? ' The rule judges by its default until a value is set; off switches it off.' : ''}`
      : k.kind === 'network' && k.key === 'protocols' ? 'A list of the protocols as SQL Server names them, apart by commas: Tcp, Np, Sm.'
      : k.vtype === 'joblist' ? `A list of the maintenance solution's job names, apart by commas: ${listText(k.choices)}.`
      : k.vtype === 'list' || k.vtype === 'numlist' ? 'A list, its items apart by commas.'
      : k.kind === 'agent' ? 'A name. An operator\'s e-mail address is never stored.' : 'A name.';
    const f = inForce.find(r => r.kind === k.kind && r.key === k.key);
    // the databases left out: this level's own list when it holds the value in force, else the key's default; what the
    // field holds is what is sent (empty = none left out)
    excl.value = listText(f && f.set_at === levelName() ? f.exclusions : k.default_exclusions);
    exclHint.textContent = 'Names apart by commas, matched without case. What this field holds is sent; empty leaves no database out.';
    now.textContent = f ? `In force for this instance now: ${listText(f.value)}${k.takes_exclusions === true ? `, leaving out ${listText(f.exclusions) || 'no database'}` : ''} (set at ${String(f.set_at)} by ${String(f.set_by)}).`
      : k.default_on === true ? 'In force for this instance now: the rule\'s default.' : 'In force for this instance now: nothing set, the rule is off.';
  };
  if (preset) {
    if (preset.kind === 'config') { rule.value = 'config|'; option.value = String(preset.key ?? ''); }
    else rule.value = `${String(preset.kind)}|${String(preset.key)}`;
  }
  rule.addEventListener('change', sync); option.addEventListener('input', sync); level.addEventListener('change', sync);
  const form = el('form', { method: 'dialog' }, el('h3', {}, 'Expected value'),
    el('p', {}, 'The instance\'s own expected value wins, then a tag\'s (when two of the instance\'s tags carry one, the tag first by name), then the root\'s. '
      + 'Inherit ends this level\'s own value, so the level above applies. Who set it and when is kept.'),
    el('div', { style: 'margin:.3rem 0' }, el('label', {}, 'Level ', level)),
    el('div', { style: 'margin:.3rem 0' }, el('label', {}, 'Check ', rule)), optRow,
    el('div', { style: 'margin:.3rem 0' }, el('label', {}, 'Expected value ', value, choice)), hint, exclRow, now,
    msg, el('div', { style: 'margin-top:.6rem' }, save, ' ', inherit, ' ', back));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:40rem', 'aria-label': 'Expected value' }, form);
  let done = false;
  const close = () => { dlg.close(); dlg.remove(); if (done) after(); };
  back.addEventListener('click', close);
  dlg.addEventListener('cancel', () => { dlg.remove(); if (done) after(); });
  const items = (t: string) => t.split(',').map(x => x.trim()).filter(x => x !== '');
  const send = async (op: 'set' | 'inherit') => {
    const k = chosen();
    save.disabled = inherit.disabled = true;
    msg.textContent = 'Saving...';
    const body: Record<string, unknown> = { op, kind: k.kind, key: k.key };
    if (level.value === 'instance') { body.level = 'instance'; body.instance_id = ctx.instance; }
    else if (level.value === 'root') body.level = 'root';
    else { body.level = 'tag'; body.tag = level.value.slice(4); }
    if (op === 'set') {
      body.value = k.vtype === 'choice' ? choice.value : k.vtype === 'list' || k.vtype === 'numlist' || k.vtype === 'joblist' ? items(value.value) : value.value.trim();
      if (k.takes_exclusions === true) body.exclusions = items(excl.value);
    }
    try {
      const r = await post<{ outcome: string; detail: string }>('mssql/config_expect', body);
      done = true;
      msg.replaceChildren(badge(r.outcome, 'ok'), ' ', r.detail);
    } catch (e) {
      msg.replaceChildren(badge('not saved', 'crit'), ' ', e instanceof Error ? e.message : String(e));
    }
    save.disabled = false; inherit.disabled = false;
    back.textContent = 'Close';
  };
  form.addEventListener('submit', ev => { ev.preventDefault(); void send('set'); });
  // Inherit ends this level's own value: a second press confirms it
  let armed = false;
  inherit.addEventListener('click', () => {
    if (!armed) {
      armed = true; inherit.textContent = 'Inherit: press again to end it';
      msg.textContent = 'Inherit ends this level\'s own expected value (the row stays with who ended it); the level above then applies.';
      return;
    }
    armed = false; inherit.textContent = 'Inherit';
    void send('inherit');
  });
  document.body.append(dlg);
  sync();
  dlg.showModal();
  (choice.hidden ? value : choice).focus();
}
