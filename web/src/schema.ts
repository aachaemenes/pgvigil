// The Schema tab (task 59; DBADash's DDL change tracking): the hourly schema snapshot of every database the monitoring
// login can connect to (schemas, tables and their columns, indexes, constraints, triggers, functions and procedures,
// views, materialized views, sequences, with their owner and ACL), the changes found between two reads (added,
// dropped, changed, with the before and after text of the changed attribute), and, where the server's DBA installed the
// opt-in event trigger, the statement text beside the change. The database page's Schema section (schemaDbSection)
// is the same for one database. Data from /api/schema; the tab's and the section's calls are the shell's.
import { get, Row, rowsOf, Table } from './api';
import { dbLink } from './dbinfo';
import { textDiffView } from './diff';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid, tile } from './ui';

type SchemaData = Record<'state' | 'databases' | 'changes' | 'ddl' | 'findings', Table | null>
  & { objects?: Table | null; mssql_dbs?: Table | null; trace?: Table | null; change?: Table | null };

// isMssqlReply: a SQL Server instance's reply carries the default trace's part (q_schema.go)
const isMssqlReply = (d: SchemaData) => d.trace !== undefined;

const changesCap = 2000, ddlCap = 1000;   // the API's limits (q_schema.go, 0058's schema_changes_window)

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const changeBadge = (v: unknown) => badge(String(v ?? ''), v === 'dropped' ? 'warn' : v === 'added' ? 'ok' : '');
// longText: a short text as it is; a long one as a disclosure (keyboard-reachable) whose summary is the start and whose
// body is the whole text, so a change past the start can be read
function longText(v: unknown, n = 400): string | Node {
  const s = v == null ? '' : String(v);
  if (s.length <= n) return s;
  return el('details', {}, el('summary', {}, s.slice(0, n) + '...'), el('pre', { class: 'sql' }, s));
}

// ddlState: the event trigger's state of a database, in words
const ddlText: Record<string, string> = {
  installed: 'installed',
  'not installed': 'not installed',
  'no event trigger': 'table present, event triggers missing or disabled',
  'not readable': 'not readable by the monitoring login',
};
function ddlBadge(v: unknown): HTMLElement | string {
  const s = String(v ?? '');
  if (s === 'installed') return badge(ddlText[s], 'ok');
  if (s === 'not installed' || s === '') return ddlText['not installed'];
  return badge(ddlText[s] ?? s, 'warn');
}

// the statement cell: the captured statement, or why there is none
function statementCell(_: unknown, r: Row): string | Node {
  if (r.statement != null) {
    const who = r.statement_role ? ` (${String(r.statement_role)}, ${fmtTime(r.statement_at)})` : '';
    return el('span', {}, longText(r.statement, 300), who);
  }
  if (r.ddl_log === 'installed') return '(no statement captured between the two reads)';
  if (r.ddl_log === 'no event trigger' || r.ddl_log === 'not readable') return `(event trigger: ${ddlText[String(r.ddl_log)]})`;
  return '(event trigger not installed)';
}

// whoCell (SQL Server): the default trace's login, host and program when one row fits the change; every candidate
// when more than one does (the trace keeps no schema); why there is none
function whoCell(_: unknown, r: Row): string | Node {
  if (Number(r.who_n ?? 0) === 1) {
    return el('span', {}, `${String(r.who_login ?? '?')} from ${String(r.who_host ?? '?')} (${String(r.who_program ?? '?')}), ${fmtTime(r.who_at)}`);
  }
  const list = Array.isArray(r.who_list) ? r.who_list as Record<string, unknown>[] : [];
  if (list.length > 1) {
    return el('details', {}, el('summary', {}, `${list.length} candidates: ${String(r.who_note ?? '')}`),
      el('ul', {}, ...list.map(x => el('li', {}, `${String(x.login ?? '?')} from ${String(x.host ?? '?')} (${String(x.program ?? '?')}), ${fmtTime(x.at)}`))));
  }
  return String(r.who_note ?? '');
}

// compareCell: the change's before and after side by side, read whole on the click (the list holds them cut)
function compareCell(ctx: Ctx): (v: unknown, r: Row) => Node {
  return (_, r) => {
    const box = el('div');
    const btn = el('button', { type: 'button', 'aria-label': `compare the before and after of ${String(r.identity ?? '')}` }, 'compare') as HTMLButtonElement;
    btn.addEventListener('click', async () => {
      btn.disabled = true;
      box.replaceChildren(el('p', { class: 'meta' }, 'Loading...'));
      try {
        const q: Record<string, string | number> = { instance: ctx.instance ?? 0, db: String(r.dbid), change_at: String(r.snapshot_at),
          kind: String(r.kind), identity: String(r.identity), part: 'change' };
        if (r.attribute != null) q.attribute = String(r.attribute);
        const d = await get<SchemaData>('schema', q);
        const c = rowsOf(d.change)[0];
        if (!c) { box.replaceChildren(el('p', { class: 'empty' }, 'The change is no longer held (past the retention).')); return; }
        const before = c.before == null ? undefined : String(c.before), after = c.after == null ? '' : String(c.after);
        const hashed = /\nbody sha256:[0-9a-f]{16}$/.test(before ?? '') || /\nbody sha256:[0-9a-f]{16}$/.test(after);
        box.replaceChildren(
          hashed ? el('p', { class: 'meta' }, 'A body kept as its SHA-256 shows only that its text changed: its text is kept where the instance\'s query_text is full.') : '',
          textDiffView(before, after, `before (read ${fmtTime(c.prev_at)})`, `after (read ${fmtTime(c.snapshot_at)})`));
      } catch (e) {
        box.replaceChildren(errorBox(e));
      } finally {
        btn.disabled = false;
      }
    });
    return el('div', {}, btn, box);
  };
}

function changeCols(ctx: Ctx, withDb: boolean, mssql = false): Col[] {
  const cols: Col[] = [
    { key: 'snapshot_at', label: 'found', fmt: (v, r) => el('span', { title: `between the read of ${fmtTime(r.prev_at)} and this one` }, fmtTime(v)) },
  ];
  if (withDb) cols.push({ key: 'datname', label: 'database', fmt: (v, r) => dbLink(ctx, v, r.dbid) });
  cols.push(
    { key: 'kind' },
    { key: 'identity', label: 'object', wide: true },
    { key: 'change', fmt: changeBadge },
    { key: 'attribute', label: 'what changed', fmt: (v, r) => r.change === 'changed' ? String(v ?? '') : '' },
    { key: 'before', wide: true, fmt: (v, r) => r.cut ? el('span', {}, longText(v), ' ...') : longText(v) },
    { key: 'after', wide: true, fmt: (v, r) => r.cut ? el('span', {}, longText(v), ' ...') : longText(v) },
    mssql ? { key: 'who_login', label: 'who (the default trace)', wide: true, fmt: whoCell } : { key: 'statement', wide: true, fmt: statementCell },
    { key: 'compare', label: 'before / after', fmt: compareCell(ctx) },
  );
  return cols;
}

const objectCols: Col[] = [
  { key: 'schema_name', label: 'schema' },
  { key: 'kind' },
  { key: 'identity', label: 'object', wide: true },
  { key: 'definition', wide: true, fmt: (v, r) => r.def_cut ? el('span', {}, longText(v), ' ... (cut at 1,000 characters; a change\'s before / after holds it whole)') : longText(v) },
  { key: 'owner' },
  { key: 'acl', label: 'ACL', wide: true },
  { key: 'last_changed', label: 'last changed', fmt: v => v ? fmtTime(v) : '' },
  { key: 'first_seen', label: 'first seen', fmt: fmtTime },
];

const ddlCols: Col[] = [
  { key: 'logged_at', label: 'logged', fmt: fmtTime },
  { key: 'datname', label: 'database' },
  { key: 'command_tag', label: 'command' },
  { key: 'object_type', label: 'object type' },
  { key: 'object_identity', label: 'object', wide: true },
  { key: 'role_name', label: 'role' },
  { key: 'statement', wide: true, fmt: v => longText(v, 600) },
];

// changesBlock: the changes grid with a kind-of-change picker and an object filter (both keyboard-reachable, labelled)
function changesBlock(ctx: Ctx, rows: Row[], withDb: boolean, countsAbove = true, mssql = false): HTMLElement {
  const pick = el('select', { 'aria-label': 'kind of change' },
    el('option', { value: '' }, 'every change'), el('option', { value: 'dropped' }, 'dropped'),
    el('option', { value: 'changed' }, 'changed'), el('option', { value: 'added' }, 'added')) as HTMLSelectElement;
  const filter = el('input', { type: 'search', placeholder: 'object name', 'aria-label': 'filter the changes by object name' }) as HTMLInputElement;
  const out = el('div');
  const draw = () => {
    const f = filter.value.trim().toLowerCase(), k = pick.value;
    const shown = rows.filter(r => (!k || r.change === k) && (!f || String(r.identity ?? '').toLowerCase().includes(f)));
    out.replaceChildren(
      rows.length >= changesCap ? el('p', { class: 'meta' }, `The newest ${fmtNum(changesCap)} changes of the range are listed${countsAbove ? '; the counts above are whole' : ''}. Narrow the range for older ones.`) : '',
      grid(shown, changeCols(ctx, withDb, mssql), rows.length ? 'No change matches.' : `No schema change found in the range (${rangeLabel(ctx)}).`));
  };
  pick.addEventListener('change', draw);
  filter.addEventListener('input', draw);
  draw();
  return el('div', {}, el('p', {}, 'Show ', pick, ' filter ', filter), out);
}

// objectsBlock: one database's current snapshot, a kind picker and a name filter, 500 rows shown at most
function objectsBlock(rows: Row[]): HTMLElement {
  const total = Number(rows[0]?.total ?? 0);
  const kinds = [...new Set(rows.map(r => String(r.kind ?? '')))].sort();
  const pick = el('select', { 'aria-label': 'kind of object' }, el('option', { value: '' }, 'every kind'),
    ...kinds.map(k => el('option', { value: k }, k))) as HTMLSelectElement;
  const filter = el('input', { type: 'search', placeholder: 'object name', 'aria-label': 'filter the objects by name' }) as HTMLInputElement;
  const out = el('div');
  const draw = () => {
    const f = filter.value.trim().toLowerCase(), k = pick.value;
    const all = rows.filter(r => (!k || r.kind === k) && (!f || String(r.identity ?? '').toLowerCase().includes(f)));
    const shown = all.slice(0, 500);
    const note = shown.length < all.length || rows.length < total
      ? `${shown.length} of ${total} objects shown${all.length > shown.length ? ': narrow the filter' : ' (the first 5,000 by schema, kind and name were read)'}.`
      : `${all.length} of ${total} objects.`;
    out.replaceChildren(el('p', { class: 'meta' }, note), grid(shown, objectCols, 'No object matches.'));
  };
  pick.addEventListener('change', draw);
  filter.addEventListener('input', draw);
  draw();
  return el('div', {}, el('p', {}, 'Kind ', pick, ' filter ', filter), out);
}

// objectsSection: the database picker; each pick reads that database's objects
function objectsSection(ctx: Ctx, instance: number, dbs: Row[]): HTMLElement {
  const sec = el('div', {}, el('h3', {}, 'Objects'),
    el('p', { class: 'meta' }, 'The current snapshot of one database: every object with its definition (a function\'s body as its SHA-256), '
      + 'its owner and its ACL (empty: the built-in default). A column, index, constraint or trigger belongs to its table; its owner is the table\'s.'));
  const pick = el('select', { 'aria-label': 'database of the objects' }, ...dbs.map(d => el('option', { value: String(d.dbid) }, String(d.datname)))) as HTMLSelectElement;
  const out = el('div');
  let seq = 0;   // a reply to an earlier pick that arrives late is dropped
  const load = async () => {
    const mine = ++seq;
    out.replaceChildren(el('p', { class: 'meta' }, 'Loading...'));
    try {
      const d = await get<SchemaData>('schema', { instance, db: pick.value, part: 'objects', ...window_(ctx) });
      if (mine === seq) out.replaceChildren(objectsBlock(rowsOf(d.objects)));
    } catch (e) {
      if (mine === seq) out.replaceChildren(errorBox(e));
    }
  };
  pick.addEventListener('change', () => { void load(); });
  sec.append(el('p', {}, 'Database ', pick), out);
  void load();
  return sec;
}

const aboutText = 'Read hourly on every database the monitoring login can connect to (pg_monitor: the catalogs alone). '
  + 'A database\'s first read is its baseline; each later read is compared with the one before: an object added, dropped, or '
  + 'changed in its definition, owner or ACL, with the text before and after. A column, index, constraint or trigger added '
  + 'or dropped with its table is shown as the table\'s one row. The schemas of extensions and the catalogs are left out. '
  + 'The statement text needs the opt-in event trigger (pgvigil roles prints it; a superuser installs it per database): '
  + 'where it is installed the client\'s query text (every statement sent together) and its role stand beside the change; '
  + 'elsewhere the change is still found, without them. A text that may carry a password is not kept.';

const mssqlAboutText = 'Read on the databases of the instance\'s mssql_schema.databases (pgvigil.yaml; none = the collection is off): '
  + 'schemas, tables with each column, index, constraint and DML trigger, views, procedures, functions, synonyms, sequences and user types. '
  + 'A database\'s first read is its baseline; it is read whole again when the default trace shows a CREATE, ALTER or DROP in it, '
  + 'after a restore, and once a day. A procedure\'s, function\'s or trigger\'s body is kept as text where the instance\'s query_text is full '
  + '(a password in it masked), as its SHA-256 otherwise; a view\'s text is kept always. Who made a change is the default trace\'s login, host '
  + 'and program for the object\'s name between the two reads; the trace keeps no schema, so a name two schemas share lists every candidate.';

// traceWords (SQL Server): how changes are found on this instance, in words - never silence when the trace cannot help
function traceWords(t: Row | undefined): HTMLElement {
  const oldest = t?.oldest_read_at ? ` The oldest read is now ${fmtNum(Math.round((Date.now() - new Date(String(t.oldest_read_at)).getTime()) / 3600000))} h old.` : '';
  if (t?.trusted) return el('p', { class: 'meta' }, badge('default trace', 'ok'),
    ' a database with a CREATE, ALTER or DROP in the default trace is read again within the next pass (15 minutes); every database is read whole once a day.' + oldest);
  const why = t?.platform === 'azuresqldb' ? 'Azure SQL Database has no default trace'
    : t?.reader_state == null ? 'the default trace has not been read on this instance (the collection mssql_defaulttrace)'
    : t.reader_state === 'no right' ? 'the default trace cannot be read: the login lacks ALTER TRACE'
    : t.reader_state === 'off' ? 'the default trace is switched off on this server'
    : t.reader_state === 'failed' ? `the default trace's last read failed${t.reader_note ? ': ' + String(t.reader_note) : ''}`
    : `the default trace was last read ${fmtTime(t.reader_at)}`;
  return el('p', { class: 'meta' }, badge('daily read only', 'warn'),
    ` changes are found at the daily read (every 24 hours): ${why}; who made a change is not known.` + oldest);
}

const mssqlStateWords: Record<string, string> = {
  read: 'read', hashes: 'read, bodies as hashes', seen: 'kept', secondary: 'a secondary replica', offline: 'offline', restoring: 'restoring',
  'not readable': 'not readable', 'no access': 'no access', torn: 'read again next pass', partial: 'not snapshotted',
};
function mssqlStateCell(_: unknown, r: Row): string | Node {
  const st = String(r.mssql_state ?? '');
  if (!st) return '';
  const word = mssqlStateWords[st] ?? st;
  const b = st === 'read' || st === 'seen' ? word : badge(word, 'warn');
  return r.mssql_note ? el('span', {}, b, ` (${String(r.mssql_note)})`) : b;
}

// schemaView: one instance's Schema tab.
export async function schemaView(instance: number, ctx: Ctx): Promise<HTMLElement> {
  const d = await get<SchemaData>('schema', { instance, ...window_(ctx) });
  const mssql = isMssqlReply(d);
  const dbs = rowsOf(d.databases), changes = rowsOf(d.changes), st = rowsOf(d.state)[0];
  const sec = el('section', {}, el('h2', {}, 'Schema'), el('p', { class: 'meta' }, mssql ? mssqlAboutText : aboutText));
  if (mssql) {
    sec.append(traceWords(rowsOf(d.trace)[0]));
    // the collection's own state per database, the never-read ones too
    const ms = rowsOf(d.mssql_dbs), byId = new Map(ms.map(m => [String(m.dbid), m]));
    for (const r of dbs) { const m = byId.get(String(r.dbid)); if (m) { r.mssql_state = m.state; r.mssql_note = m.note; byId.delete(String(r.dbid)); } }
    for (const m of byId.values()) dbs.push({ dbid: m.dbid, datname: m.datname, objects: null, changes: 0, dropped: 0, mssql_state: m.state, mssql_note: m.note, is_present: false });
  }
  if (dbs.length === 0) {
    sec.append(el('p', { class: 'empty' }, st?.status === 'error' ? `The schema collection failed: ${String(st.note ?? '')}.`
      : st?.status === 'skipped' ? `The schema collection is off on this instance: ${String(st.note ?? '')}.`
      : mssql ? 'No schema read yet: the collection mssql_schema reads the databases of mssql_schema.databases every 15 minutes.'
      : 'No schema read yet: the schema collection runs hourly, on every database the monitoring login can connect to.'));
    return sec;
  }
  if (st?.status === 'partial') sec.append(el('p', { class: 'meta' }, badge('partial', 'warn'), ` the last read left a database out: ${String(st.note ?? '')}`));
  if (st?.status === 'error') sec.append(el('p', { class: 'meta' }, badge('error', 'crit'), ` the last read failed (${fmtTime(st.snapshot_at)}): ${String(st.note ?? '')}; the rows below are from earlier reads.`));
  const sum = (k: string) => dbs.reduce((a, r) => a + Number(r[k] ?? 0), 0);
  const objects = sum('objects'), nChanges = sum('changes'), dropped = sum('dropped');
  const installed = dbs.filter(r => r.ddl_log === 'installed').length;
  sec.append(el('div', { class: 'tiles' },
    tile('databases', fmtNum(dbs.length)),
    tile('objects', fmtNum(objects)),
    tile(`changes (${rangeLabel(ctx)})`, fmtNum(nChanges), nChanges ? 'warn' : 'ok'),
    tile('dropped (not partitions)', fmtNum(dropped), dropped ? 'warn' : 'ok'),
    mssql ? tile('not read', fmtNum(dbs.filter(r => ['not readable', 'no access', 'partial'].includes(String(r.mssql_state ?? ''))).length))
      : tile('event trigger', `${installed} of ${dbs.length}`)));
  const findings = rowsOf(d.findings);
  if (findings.length) {
    sec.append(el('h3', {}, 'Findings'), grid(findings, [
      { key: 'severity', fmt: sevBadge }, { key: 'setting', label: 'finding' }, { key: 'value', label: 'database' },
      { key: 'suggested' }, { key: 'detail', wide: true },
    ]));
  }
  sec.append(el('h3', {}, 'Databases'), grid(dbs, [
    { key: 'datname', label: 'database', fmt: (v, r) => dbLink(ctx, v, r.dbid, instance) },
    { key: 'objects', num: true },
    { key: 'changes', label: 'changes in the range', num: true },
    { key: 'dropped', label: 'dropped (not partitions)', num: true },
    mssql ? { key: 'mssql_state', label: 'last pass', wide: true, fmt: mssqlStateCell }
      : { key: 'ddl_log', label: 'event trigger', fmt: (v, r) => r.ddl_log_note ? el('span', {}, ddlBadge(v), ` (${String(r.ddl_log_note)})`) : ddlBadge(v) },
    { key: 'first_read', label: 'compared since', fmt: fmtTime },
    { key: 'snapshot_at', label: 'read', fmt: fmtTime },
  ]));
  sec.append(el('h3', {}, `Changes (${rangeLabel(ctx)})`), changesBlock(ctx, changes, true, true, mssql));
  const ddl = rowsOf(d.ddl);
  if (ddl.length) {
    sec.append(el('h3', {}, `Event trigger log (${rangeLabel(ctx)})`),
      el('p', { class: 'meta' }, 'Every DDL command the event trigger logged in the range, with the client\'s query text, the ones the hourly diff cannot see (an object created and dropped between two reads) too.'
        + (ddl.length >= ddlCap ? ` The newest ${fmtNum(ddlCap)} are listed.` : '')),
      grid(ddl, ddlCols));
  }
  sec.append(objectsSection(ctx, instance, dbs.filter(r => r.objects != null)));
  return sec;
}

// schemaDbSection: the database page's Schema section (one database: its changes of the range, its objects).
export async function schemaDbSection(ctx: Ctx, dbid: string | number): Promise<HTMLElement> {
  const sec = el('section', {}, el('h3', {}, `Schema (${rangeLabel(ctx)})`));
  try {
    const d = await get<SchemaData>('schema', { instance: ctx.instance, db: dbid, ...window_(ctx) });
    const mssql = isMssqlReply(d);
    const db = rowsOf(d.databases)[0];
    if (!db) {
      sec.append(el('p', { class: 'empty' }, 'No schema read of this database yet (the schema collection runs hourly).'));
      return sec;
    }
    sec.append(el('p', { class: 'meta' }, db.is_present === false ? badge('no longer read', 'warn') : '',
      db.is_present === false ? ` the database is gone or the login can no longer connect (last read ${fmtTime(db.snapshot_at)}); its earlier changes are below. ` : '',
      `${fmtNum(db.objects)} objects, read ${fmtTime(db.snapshot_at)}, compared since ${fmtTime(db.first_read)}`,
      mssql ? '' : '; event trigger: ', mssql ? '' : ddlBadge(db.ddl_log), !mssql && db.ddl_log_note ? ` (${String(db.ddl_log_note)})` : ''));
    if (mssql) sec.append(traceWords(rowsOf(d.trace)[0]));
    sec.append(changesBlock(ctx, rowsOf(d.changes), false, false, mssql));
    const ddl = rowsOf(d.ddl);
    if (ddl.length) {
      sec.append(el('h4', {}, 'Event trigger log'),
        ddl.length >= ddlCap ? el('p', { class: 'meta' }, `The newest ${fmtNum(ddlCap)} are listed.`) : '',
        grid(ddl, ddlCols.filter(c => c.key !== 'datname')));
    }
    sec.append(el('h4', {}, 'Objects'), objectsBlock(rowsOf(d.objects)));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
