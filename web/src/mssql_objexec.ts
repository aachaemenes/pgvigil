// DBA Dash's Object Execution (P25 F102 / F505; Performance/ObjectExecutionSummary.cs): the procedures, the scalar
// functions and the triggers of an instance - or of one database (the database page's tab) - in ONE grid, with the
// Type filter (procedures, functions, triggers), a Search over the schema and the name, each row's Period Time (the
// seconds its kind's reads cover) and its Query Stats and Query Store links (the database page's tabs). Data from
// /api/mssql/procs part=objects (types=, search=, db=<database id>); over a node's databases (P25 (i): an Azure
// logical server's or elastic pool's tab, DBA Dash's one grid with an instance column) part=objects with instances=.
import { get, Row, rowsOf, Table } from './api';
import { Ctx, window_ } from './router';
import { mssqlDbLink } from './mssql_db';
import { hashParam } from './dbinfo';
import { Col, el, errorBox, fmtNum, grid } from './ui';

const kinds: [string, string][] = [['procedure', 'Procedures'], ['function', 'Functions'], ['trigger', 'Triggers']];
const secs = (v: unknown) => v == null ? '' : fmtNum(Number(v) / 1000);
const num3 = (v: unknown) => v == null ? '' : fmtNum(v);

// objectExecutionSection: dbName given = that database alone (its id read from the page's databases part first); ids
// given = those instances' objects in one list (a node's databases), the instance column first
export function objectExecutionSection(ctx: Ctx, dbName?: string, ids?: number[]): HTMLElement {
  // no database and no node: every database of the instance (the Procedures page: its filter narrows the grids below)
  const sec = el('div', { class: 'objexec' }, el('h3', {}, dbName || ids ? 'Object Execution' : 'Object Execution (every database)'));
  const on = new Set(kinds.map(([k]) => k));
  const boxes = kinds.map(([k, label]) => {
    const c = el('input', { type: 'checkbox' });
    c.checked = true;
    c.addEventListener('change', () => { if (c.checked) on.add(k); else on.delete(k); void draw(); });
    return el('label', {}, c, ` ${label}`);
  });
  // 128 characters at most, as the server takes (a longer search would be refused)
  const search = el('input', { type: 'search', 'aria-label': 'Search objects (schema or name)', placeholder: 'Search', size: '24', maxlength: '128' });
  // oesearch= presets it: an object node of the tree opens its database's tab searched by its name (join line 3); a
  // typed search is written back, so a range change (the router keeps oesearch: pageKeys) and a reload keep it
  search.value = hashParam('oesearch')?.slice(0, 128) ?? '';
  let timer = 0;
  search.addEventListener('input', () => {
    clearTimeout(timer);
    timer = window.setTimeout(() => {
      const [path, qs] = location.hash.split('?'), hq = new URLSearchParams(qs ?? ''), v = search.value.trim();
      if (v) hq.set('oesearch', v); else hq.delete('oesearch');
      history.replaceState(null, '', `${location.pathname}${location.search}${path}?${hq}`);
      void draw();
    }, 300);
  });
  const body = el('div');
  sec.append(el('div', { class: 'toolbar', role: 'group', 'aria-label': 'Object Execution filters' }, el('span', { class: 'meta' }, 'Type:'), ...boxes, search), body);
  let seq = 0, dbId: string | undefined, stale: AbortController | undefined;

  async function draw() {
    const mine = ++seq;
    // a newer draw ends the older read on the server too (each keystroke's read is the three-kind union)
    stale?.abort();
    const ac = new AbortController();
    stale = ac;
    if (!on.size) { body.replaceChildren(el('p', { class: 'empty' }, 'No type picked.')); return; }
    body.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    try {
      if (dbName && dbId === undefined) {
        const d = await get<{ databases: Table | null }>('mssql/procs', { instance: ctx.instance, ...window_(ctx), part: 'databases' }, ac.signal);
        const hit = rowsOf(d.databases).find(r => String(r.database) === dbName || String(r.database_name) === dbName);
        if (!hit) { if (mine === seq) body.replaceChildren(el('p', { class: 'empty' }, `No procedure, function or trigger of ${dbName} ran in this range.`)); return; }
        dbId = String(hit.database_id);
      }
      const types = on.size === kinds.length ? undefined : [...on].join(','), q = search.value.trim() || undefined;
      const d = await get<{ objects: Table | null }>('mssql/procs', ids
        ? { instances: ids.join(',') || '0', ...window_(ctx), part: 'objects', types, search: q }
        : { instance: ctx.instance, ...window_(ctx), part: 'objects', types, search: q, db: dbId }, ac.signal);
      if (mine !== seq) return;
      // a row's database page: on a node's list, the row's own instance
      const link = (r: Row, tab: string, text: string, why: string) =>
        el('a', { href: mssqlDbLink(ctx, String(r.database), tab, ids ? Number(r.instance_id) : ctx.instance), title: why }, text);
      const cols: Col[] = [
        ...(ids ? [{ key: 'instance', label: 'database (instance)' }] : []),
        { key: 'kind', label: 'type' }, { key: 'database' }, { key: 'schema_name', label: 'schema' }, { key: 'object_name', label: 'name' },
        { key: 'period_secs', label: 'Period Time (sec)', num: true, fmt: v => v == null ? '' : fmtNum(v) },
        { key: 'duration_ms', label: 'total duration (sec)', num: true, fmt: secs },
        { key: 'duration_ms_sec', label: 'duration (ms/sec)', num: true, fmt: num3 },
        { key: 'avg_duration_ms', label: 'avg duration (ms)', num: true, fmt: num3 },
        { key: 'executions', num: true }, { key: 'executions_min', label: 'executions /min', num: true },
        { key: 'max_executions_min', label: 'max executions /min', num: true },
        { key: 'cpu_ms', label: 'total CPU (sec)', num: true, fmt: secs }, { key: 'avg_cpu_ms', label: 'avg CPU (ms)', num: true, fmt: num3 },
        { key: 'logical_reads', label: 'logical reads', num: true }, { key: 'physical_reads', label: 'physical reads', num: true },
        { key: 'logical_writes', label: 'writes', num: true },
        { key: 'qs_link', label: 'Query Stats', fmt: (_, r) => link(r, 'querystats', 'Query Stats', `the plan cache's statements of ${String(r.database)}`) },
        { key: 'qstore_link', label: 'Query Store', fmt: (_, r) => link(r, 'topqueries', 'Query Store', `the Query Store's top queries of ${String(r.database)}`) },
      ];
      const rows = rowsOf(d.objects);
      body.replaceChildren(...(rows.length >= 2000 ? [el('p', { class: 'meta' }, 'The first 2,000 by total duration: a type or a search narrows the list.')] : []),
        grid(rows, cols, ids
          ? 'No procedure, function or trigger of these types ran in these databases in this range.'
          : 'No procedure, function or trigger of these types ran in this range.'));
    } catch (e) {
      if (mine === seq) body.replaceChildren(errorBox(e));
    }
  }
  void draw();
  return sec;
}
