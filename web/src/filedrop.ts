// Open a file in pgvigil's own viewers (task 172; DBA Dash's Tools > Open Deadlock Graph | *.xdl, Open Query Plan |
// *.sqlplan, Open Grid or Data Set, audit F413): the bar's Tools menu picks a file; a file dropped anywhere on the
// page, or a deadlock graph or showplan pasted outside a field, opens the same way.
//   - a deadlock graph (.xdl, or XML with <deadlock>): the graph SQL Server wrote, drawn as the Deadlocks tab draws it
//     (deadlock_graph.ts), with its sessions and its locked resources as grids
//   - a query plan (.sqlplan, or XML with <ShowPlanXML>): each statement with its cost, and its operators as an indented
//     tree in a grid: the operator, its object, its estimated and actual rows, its own share of the statement's cost, its
//     warnings; then the plan's missing indexes
//   - a grid or data set (.json: an array of rows or {columns, rows} as the API writes it; .csv: a header and rows; either
//     gzipped as .gz): the rows as a grid, with every grid's menu and its export
// A file is read in the browser only: nothing is sent to the server. Everything is set as text, never as markup.
import { Row } from './api';
import { DlGraph, deadlockSvg, graphFromXml, resourceKind, sessionName } from './deadlock_graph';
import { Col, el, fmtNum, grid } from './ui';
import { showTreeMenu } from './treemenu';

const MAX_BYTES = 64 * 1024 * 1024;

// ---- the viewer window ----------------------------------------------------------------------------------------

function viewer(title: string, back: HTMLElement | null, ...kids: (Node | string)[]): HTMLDialogElement {
  const close = el('button', { type: 'button' }, 'Close');
  const dlg = el('dialog', { class: 'act-dialog fd-viewer', 'aria-label': title, style: 'width:min(96vw,90rem);max-width:96vw;max-height:92vh' },
    el('h3', {}, title), el('div', { class: 'fd-body' }, ...kids), el('div', { style: 'margin-top:.6rem' }, close)) as HTMLDialogElement;
  close.addEventListener('click', () => dlg.close());
  dlg.addEventListener('close', () => { dlg.remove(); if (back?.isConnected) back.focus(); });
  document.body.append(dlg);
  dlg.showModal();
  close.focus();
  return dlg;
}
const note = (t: string) => el('p', { class: 'meta' }, t);

// ---- a deadlock graph -----------------------------------------------------------------------------------------

function deadlockView(g: DlGraph): HTMLElement[] {
  const victims = g.processes.filter(p => p.victim).map(sessionName);
  const pcols: Col[] = [
    { key: 'name', label: 'session' }, { key: 'victim', fmt: v => v === true ? 'victim' : '' }, { key: 'login' }, { key: 'host' }, { key: 'program' },
    { key: 'database' }, { key: 'waits_mode', label: 'waits for' }, { key: 'wait_ms', label: 'wait (ms)', num: true }, { key: 'isolation' },
    { key: 'trancount', label: 'open transactions', num: true }, { key: 'proc', label: 'procedure' }, { key: 'statement', wide: true },
  ];
  const rcols: Col[] = [
    { key: 'type', label: 'lock', fmt: v => resourceKind(String(v ?? '')) }, { key: 'object' }, { key: 'index' }, { key: 'mode', label: 'granted mode' },
    { key: 'owners', label: 'held by' }, { key: 'waiters', label: 'wanted by' },
  ];
  const prows = g.processes.map(p => ({ ...p, name: sessionName(p) }) as unknown as Row);
  const rrows = g.resources.map(r => ({ ...r, owners: r.owners.map(o => `${o.spid ?? o.process} (${o.mode ?? ''})`).join(', '), waiters: r.waiters.map(o => `${o.spid ?? o.process} (${o.mode ?? ''})`).join(', ') }) as unknown as Row);
  return [
    note(`${g.processes.length} sessions, ${g.resources.length} locked resources; the victim: ${victims.join(', ') || 'none named'}.`),
    el('div', { class: 'deadlock-graph-box grid-wrap', tabindex: '0', role: 'region', 'aria-label': 'the deadlock graph, scrolls' }, deadlockSvg(g)),
    el('h4', {}, 'Sessions'), grid(prows, pcols),
    el('h4', {}, 'Locked resources'), grid(rrows, rcols),
  ];
}

// cost: an optimizer cost with four significant digits (an OLTP plan's 0.0032831 is not 0)
const cost = (n: number) => !Number.isFinite(n) ? '' : n === 0 ? '0' : n.toLocaleString(undefined, { maximumSignificantDigits: 4 });

// ---- a showplan ---------------------------------------------------------------------------------------------------

interface Op { depth: number; node: string; parent: string; physical: string; logical: string; object: string; estRows: number | null; estExecs: number | null; estAll: number | null;
  actRows: number | null; execs: number | null; subtree: number | null; own: number | null; share: number | null; warnings: string; parallel: boolean }
const kids = (e: Element, name?: string) => [...e.children].filter(c => !name || c.localName === name);
const numAttr = (e: Element, a: string) => { const v = e.getAttribute(a); return v == null || v === '' || isNaN(Number(v)) ? null : Number(v); };
const unq = (s: string | null) => (s ?? '').replace(/^\[|\]$/g, '');

// the RelOps directly under an element (each operator's own element holds its children's RelOps, one level down)
function childOps(op: Element): Element[] {
  const out: Element[] = [];
  const walk = (e: Element) => { for (const c of kids(e)) { if (c.localName === 'RelOp') out.push(c); else walk(c); } };
  for (const c of kids(op)) if (c.localName !== 'RelOp') walk(c);
  return out;
}
function objectOf(op: Element): string {
  // the operator's own Object (an index seek's, a scan's), not one of a child's
  const own = (e: Element): Element | undefined => {
    for (const c of kids(e)) { if (c.localName === 'RelOp') continue; if (c.localName === 'Object') return c; const x = own(c); if (x) return x; }
    return undefined;
  };
  const o = own(op);
  if (!o) return '';
  return [unq(o.getAttribute('Database')), unq(o.getAttribute('Schema')), unq(o.getAttribute('Table'))].filter(Boolean).join('.') + (o.getAttribute('Index') ? ` (${unq(o.getAttribute('Index'))})` : '');
}
// warningsOf: the Warnings of an operator (RelOp) or of a statement (QueryPlan) in words
function warningsOf(op: Element): string {
  const w: string[] = [];
  for (const c of kids(op)) {
    if (c.localName !== 'Warnings') continue;
    if (c.getAttribute('UnmatchedIndexes') === 'true') w.push('unmatched indexes (a filtered index the parameters could not use)');
    for (const x of kids(c)) {
      if (x.localName === 'SpillToTempDb') w.push(`spill to tempdb (level ${x.getAttribute('SpillLevel') ?? '?'}${x.getAttribute('SpilledThreadCount') ? ', ' + x.getAttribute('SpilledThreadCount') + ' threads' : ''})`);
      else if (x.localName === 'SortSpillDetails' || x.localName === 'HashSpillDetails' || x.localName === 'ExchangeSpillDetails') {
        const what = x.localName === 'SortSpillDetails' ? 'sort' : x.localName === 'HashSpillDetails' ? 'hash' : 'exchange';
        const kb = (a: string) => x.getAttribute(a) != null ? `${fmtNum(Number(x.getAttribute(a)))} KB` : '';
        w.push(`${what} spill: ${[kb('GrantedMemoryKb') && 'granted ' + kb('GrantedMemoryKb'), kb('UsedMemoryKb') && 'used ' + kb('UsedMemoryKb'),
          x.getAttribute('WritesToTempDb') ? fmtNum(Number(x.getAttribute('WritesToTempDb'))) + ' pages written to tempdb' : ''].filter(Boolean).join(', ') || 'details not given'}`);
      } else if (x.localName === 'Wait') w.push(`wait: ${x.getAttribute('WaitType') ?? ''} ${x.getAttribute('WaitTime') ? x.getAttribute('WaitTime') + ' ms' : ''}`.trim());
      else if (x.localName === 'NoJoinPredicate') w.push('no join predicate');
      else if (x.localName === 'ColumnsWithNoStatistics') w.push('columns with no statistics');
      else if (x.localName === 'PlanAffectingConvert') w.push(`convert affects the plan (${x.getAttribute('ConvertIssue') ?? ''}): ${x.getAttribute('Expression') ?? ''}`);
      else if (x.localName === 'MemoryGrantWarning') w.push(`memory grant: ${x.getAttribute('GrantWarningKind') ?? ''}${x.getAttribute('GrantedMemory') ? ', granted ' + fmtNum(Number(x.getAttribute('GrantedMemory'))) + ' KB' : ''}${x.getAttribute('MaxUsedMemory') ? ', used ' + fmtNum(Number(x.getAttribute('MaxUsedMemory'))) + ' KB' : ''}`);
      else w.push(x.localName);
    }
    if (c.getAttribute('NoJoinPredicate') === 'true') w.push('no join predicate');
  }
  return w.join('; ');
}
function opsOf(root: Element, total: number | null): Op[] {
  const out: Op[] = [];
  const walk = (op: Element, depth: number, parent: string) => {
    const ch = childOps(op);
    const subtree = numAttr(op, 'EstimatedTotalSubtreeCost');
    const childCost = ch.reduce((a, c) => a + (numAttr(c, 'EstimatedTotalSubtreeCost') ?? 0), 0);
    const own = subtree == null ? null : Math.max(0, subtree - childCost);
    let act: number | null = null, execs: number | null = null;
    for (const rt of kids(op, 'RunTimeInformation')) for (const t of kids(rt, 'RunTimeCountersPerThread')) {
      act = (act ?? 0) + (numAttr(t, 'ActualRows') ?? 0); execs = (execs ?? 0) + (numAttr(t, 'ActualExecutions') ?? 0);
    }
    // EstimateRows is for one execution; the operator is expected to run 1 + rebinds + rewinds times (a nested loop's
    // inner side many), so the rows over all of them are what its actual rows (summed over executions and threads) meet
    const estRows = numAttr(op, 'EstimateRows'), estExecs = 1 + (numAttr(op, 'EstimateRebinds') ?? 0) + (numAttr(op, 'EstimateRewinds') ?? 0);
    const node = op.getAttribute('NodeId') ?? '';
    out.push({ depth, node, parent, physical: op.getAttribute('PhysicalOp') ?? '', logical: op.getAttribute('LogicalOp') ?? '', object: objectOf(op),
      estRows, estExecs, estAll: estRows == null ? null : estRows * estExecs, actRows: act, execs, subtree, own, share: own != null && total ? own / total * 100 : null,
      warnings: warningsOf(op), parallel: op.getAttribute('Parallel') === 'true' || op.getAttribute('Parallel') === '1' });
    for (const c of ch) walk(c, depth + 1, node);
  };
  walk(root, 0, '');
  return out;
}

function planView(doc: Document): HTMLElement[] {
  const stmts = [...doc.getElementsByTagName('StmtSimple')];
  // an IF's condition (StmtCond) holds its branches' StmtSimple, read above; a cursor's plan (StmtCursor) is not read
  const cursors = doc.getElementsByTagName('StmtCursor').length;
  const cursorWords = cursors ? `; ${cursors} cursor plan${cursors === 1 ? '' : 's'} (StmtCursor) not read` : '';
  if (!stmts.length) return [el('p', { class: 'empty' }, `The plan holds no statement this viewer reads (StmtSimple)${cursorWords}.`)];
  const out: HTMLElement[] = [note(`${stmts.length} statement${stmts.length === 1 ? '' : 's'}${doc.documentElement.getAttribute('Version') ? ', showplan version ' + doc.documentElement.getAttribute('Version') : ''}${cursorWords}.`)];
  // a misestimate: the actual rows over all executions ten times off the estimate for all of them, by more than 100 rows
  const off = (r: Record<string, unknown>) => r.actRows != null && r.estAll != null && Number(r.estAll) > 0 && Math.abs(Number(r.actRows) - Number(r.estAll)) > 100
    && (Number(r.actRows) / Number(r.estAll) > 10 || Number(r.actRows) / Number(r.estAll) < 0.1);
  const cols: Col[] = [
    { key: 'node', label: 'node', num: true },
    { key: 'parent', label: 'parent node', num: true },
    // the tree's shape in words too: a screen reader hears the level, a sorted grid keeps the parent column
    { key: 'op', label: 'operator', fmt: (_v, r) => el('span', { style: `padding-left:${Number(r.depth) * 1.1}rem;white-space:pre` },
      el('span', { class: 'sr-only', style: 'position:absolute;left:-10000px;width:1px;height:1px;overflow:hidden' }, `level ${Number(r.depth) + 1}: `),
      `${Number(r.depth) ? '└ ' : ''}${String(r.physical)}${r.logical && r.logical !== r.physical ? ' (' + String(r.logical) + ')' : ''}${r.parallel ? ' ⇉' : ''}`) },
    { key: 'object' },
    { key: 'estRows', label: 'estimated rows (per execution)', num: true },
    { key: 'estExecs', label: 'estimated executions', num: true },
    { key: 'actRows', label: 'actual rows (all executions)', num: true, fmt: (v, r) => v == null ? '' : off(r) ? `${fmtNum(v)} (estimate ${cost(Number(r.estAll))})` : fmtNum(v), cls: (_v, r) => off(r) ? 'warn' : '' },
    { key: 'execs', label: 'actual executions', num: true },
    { key: 'share', label: 'cost %', num: true, fmt: v => v == null ? '' : `${fmtNum(Math.round(Number(v) * 10) / 10)} %`, cls: v => v != null && Number(v) >= 50 ? 'warn' : '' },
    { key: 'subtree', label: 'subtree cost', num: true, fmt: v => v == null ? '' : cost(Number(v)) },
    { key: 'warnings', wide: true, cls: v => v ? 'warn' : '' },
  ];
  stmts.forEach((s, i) => {
    const total = numAttr(s, 'StatementSubTreeCost');
    const qp = kids(s, 'QueryPlan')[0];
    const top = qp ? kids(qp, 'RelOp')[0] : undefined;
    const text = (s.getAttribute('StatementText') ?? '').trim();
    out.push(el('h4', {}, `Statement ${i + 1}${s.getAttribute('StatementType') ? ' (' + s.getAttribute('StatementType') + ')' : ''}: cost ${total == null ? '?' : cost(total)}`),
      el('pre', { class: 'sql', style: 'white-space:pre-wrap;max-height:10rem;overflow:auto;margin:.2rem 0' }, text || '(no statement text in the plan)'));
    if (qp) {
      const facts = [qp.getAttribute('DegreeOfParallelism') ? `DOP ${qp.getAttribute('DegreeOfParallelism')}` : '',
        kids(qp, 'MemoryGrantInfo')[0]?.getAttribute('GrantedMemory') ? `memory granted ${fmtNum(Number(kids(qp, 'MemoryGrantInfo')[0].getAttribute('GrantedMemory')))} KB` : '',
        qp.getAttribute('CompileTime') ? `compiled in ${qp.getAttribute('CompileTime')} ms` : ''].filter(Boolean);
      if (facts.length) out.push(note(facts.join(', ') + '.'));
      // the statement's own warnings (an implicit convert, an excessive grant, a wait) sit on its QueryPlan, not an operator
      const sw = warningsOf(qp);
      if (sw) out.push(el('p', { class: 'meta' }, el('span', { class: 'badge warn' }, 'warning'), ' ', sw));
    }
    if (top) out.push(grid(opsOf(top, total) as unknown as Row[], cols));
    else out.push(el('p', { class: 'empty' }, 'No operator in this statement\'s plan.'));
    const missing = qp ? [...qp.getElementsByTagName('MissingIndexGroup')] : [];
    if (missing.length) {
      const rows = missing.map(g => {
        const mi = g.getElementsByTagName('MissingIndex')[0];
        const cg = (usage: string) => [...(mi?.getElementsByTagName('ColumnGroup') ?? [])].filter(c => c.getAttribute('Usage') === usage)
          .flatMap(c => [...c.getElementsByTagName('Column')].map(x => unq(x.getAttribute('Name')))).join(', ');
        return { impact: numAttr(g, 'Impact'), table: mi ? [unq(mi.getAttribute('Database')), unq(mi.getAttribute('Schema')), unq(mi.getAttribute('Table'))].join('.') : '',
          equality: cg('EQUALITY'), inequality: cg('INEQUALITY'), include: cg('INCLUDE') } as Row;
      });
      out.push(el('h4', {}, 'Missing indexes the optimizer named'), note('A hint from the optimizer for this one statement, not a design: check it against the table\'s other indexes and its writes first.'),
        grid(rows, [{ key: 'impact', label: 'impact %', num: true }, { key: 'table' }, { key: 'equality' }, { key: 'inequality' }, { key: 'include' }]));
    }
  });
  return out;
}

// ---- a grid or data set -------------------------------------------------------------------------------------------

function csvRows(text: string): string[][] {
  const rows: string[][] = []; let row: string[] = [], f = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"') { if (text[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; continue; }
    if (c === '"' && f === '') q = true;   // a quote elsewhere in an unquoted field is a character of it
    else if (c === ',') { row.push(f); f = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(f); rows.push(row); row = []; f = ''; }
    else f += c;
  }
  if (f !== '' || row.length) { row.push(f); rows.push(row); }
  return rows.filter(r => r.length > 1 || r[0] !== '');
}
// unique: column names a grid can key on: a blank one 'column n', a repeat numbered ('name', 'name (2)')
function unique(cols: string[]): string[] {
  const seen = new Map<string, number>();
  return cols.map((c, i) => { const b = c.trim() || `column ${i + 1}`, n = (seen.get(b) ?? 0) + 1; seen.set(b, n); return n > 1 ? `${b} (${n})` : b; });
}
// a CSV value read as a number only when it is one exactly as written: no leading zero to lose ('00123'), no integer past
// JavaScript's safe range (a bigint id)
const numText = (v: string) => /^-?(0|[1-9]\d*)(\.\d+)?$/.test(v) && (v.includes('.') || Number.isSafeInteger(Number(v)));
function dataSetView(name: string, text: string): HTMLElement[] {
  let cols: string[] = [], rows: Row[] = [];
  // a stored sample's CSV (export.ts csv()) starts with its mark on a line of its own: taken off the rows, said in the note
  let mark = '';
  if (/\.csv$/i.test(name)) {
    const all = csvRows(text.replace(/^\ufeff/, ''));
    if (all.length > 1 && all[0].length === 1 && /^stored sample of /.test(all[0][0])) mark = all.shift()![0];
    cols = unique(all[0] ?? []);
    rows = all.slice(1).map(r => Object.fromEntries(cols.map((c, i) => [c, r[i] ?? ''])));
  } else {
    const v = JSON.parse(text) as unknown;
    const tables: { name: string; cols: string[]; rows: Row[] }[] = [];
    const take = (n: string, x: unknown) => {
      if (Array.isArray(x) && x.every(r => r && typeof r === 'object' && !Array.isArray(r))) {
        const cs = [...new Set((x as Row[]).flatMap(r => Object.keys(r)))];
        tables.push({ name: n, cols: cs, rows: x as Row[] });
      } else if (x && typeof x === 'object' && Array.isArray((x as { columns?: unknown }).columns) && Array.isArray((x as { rows?: unknown }).rows)) {
        const t = x as { columns: string[]; rows: unknown[][] };
        const u = unique(t.columns.map(String));
        tables.push({ name: n, cols: u, rows: t.rows.map(r => Object.fromEntries(u.map((c, i) => [c, r[i]]))) });
      } else if (x && typeof x === 'object' && !Array.isArray(x)) {
        for (const [k, y] of Object.entries(x as Record<string, unknown>)) if (typeof y === 'object' && y) take(k, y);
      }
    };
    take(name, v);
    if (!tables.length) return [el('p', { class: 'error' }, 'The file holds no grid: an array of rows, {columns, rows}, or an object of those.')];
    const numCol = (t: { rows: Row[] }, c: string) => t.rows.length > 0 && t.rows.every(r => r[c] == null || typeof r[c] === 'number');
    return tables.flatMap(t => [el('h4', {}, `${t.name}: ${fmtNum(t.rows.length)} rows`),
      grid(t.rows, t.cols.map(c => ({ key: c, num: numCol(t, c) })), 'No rows.')]);
  }
  // each column judged once (a test per cell scanned the whole column again: 16,000 rows took 26 s)
  const numCols = new Set(cols.filter(c => rows.length > 0 && rows.some(r => r[c] !== '') && rows.every(r => r[c] === '' || numText(String(r[c])))));
  return [note(`${mark ? mark + '. ' : ''}${fmtNum(rows.length)} rows, ${cols.length} columns.`), grid(rows.map(r => Object.fromEntries(cols.map(c => [c, numCols.has(c) && r[c] !== '' ? Number(r[c]) : r[c]]))), cols.map(c => ({ key: c, num: numCols.has(c) })), 'No rows.')];
}

// ---- opening ----------------------------------------------------------------------------------------------------

type What = 'xdl' | 'sqlplan' | 'grid';
// openText: the text of a file (or a paste) in the viewer its contents or its name call for
export function openText(name: string, text: string, back: HTMLElement | null = null, want?: What): HTMLDialogElement {
  const head = text.slice(0, 4000);
  // the extension decides first (a CSV of system_health rows holds deadlock XML); the contents only when it says nothing
  const kind: What | undefined = want ?? (/\.xdl$/i.test(name) ? 'xdl' : /\.sqlplan$/i.test(name) ? 'sqlplan' : /\.(json|csv)$/i.test(name) ? 'grid'
    : /<deadlock[\s>]/.test(head) ? 'xdl' : /<ShowPlanXML[\s>]/.test(head) ? 'sqlplan' : /^\s*[[{]/.test(head) ? 'grid' : undefined);
  try {
    if (kind === 'xdl') {
      const g = graphFromXml(text);
      // a Profiler / trace flag 1222 file (<deadlock-list><deadlock victim="...">) names its victim on the deadlock itself
      const all = new DOMParser().parseFromString(text, 'application/xml').getElementsByTagName('deadlock');
      const v = all[0]?.getAttribute('victim');
      if (g && v && !g.processes.some(p => p.victim)) for (const p of g.processes) if (p.process === v) p.victim = true;
      const more = all.length > 1 ? [note(`${all.length} deadlocks in this file: the first is shown.`)] : [];
      return viewer(`Deadlock graph: ${name}`, back, ...(g ? [...more, ...deadlockView(g)] : [el('p', { class: 'error' }, 'This is not a deadlock graph pgvigil can read: no <deadlock> with processes.')]));
    }
    if (kind === 'sqlplan') {
      const doc = new DOMParser().parseFromString(text, 'application/xml');
      if (doc.getElementsByTagName('parsererror').length || doc.documentElement.localName !== 'ShowPlanXML') return viewer(`Query plan: ${name}`, back, el('p', { class: 'error' }, 'This is not a showplan pgvigil can read: no <ShowPlanXML> document.'));
      return viewer(`Query plan: ${name}`, back, ...planView(doc));
    }
    if (kind === 'grid') return viewer(`Grid: ${name}`, back, ...dataSetView(name, text));
  } catch (e) {
    return viewer(name, back, el('p', { class: 'error' }, 'Could not read the file: ' + (e instanceof Error ? e.message : String(e))));
  }
  return viewer(name, back, el('p', { class: 'error' }, 'Not a file pgvigil opens: a deadlock graph (.xdl), a query plan (.sqlplan), or a grid (.json, .csv, either .gz).'));
}

async function readFile(f: File): Promise<string> {
  if (f.size > MAX_BYTES) throw new Error(`${f.name} is ${fmtNum(Math.round(f.size / 1048576))} MB: the viewers open files up to ${MAX_BYTES / 1048576} MB`);
  if (/\.gz$/i.test(f.name)) {
    if (typeof DecompressionStream === 'undefined') throw new Error('this browser cannot unpack .gz files');
    // unpacked within the same limit: a small .gz can hold gigabytes
    const parts: Uint8Array[] = []; let n = 0;
    const rd = f.stream().pipeThrough(new DecompressionStream('gzip')).getReader();
    for (;;) {
      const { done, value } = await rd.read();
      if (done) break;
      n += value.length;
      if (n > MAX_BYTES) { await rd.cancel(); throw new Error(`${f.name} unpacks to more than ${MAX_BYTES / 1048576} MB: the viewers open files up to that size`); }
      parts.push(value);
    }
    const b = new Uint8Array(n); let at = 0;
    for (const x of parts) { b.set(x, at); at += x.length; }
    return decode(b);
  }
  return decode(new Uint8Array(await f.arrayBuffer()));
}
// decode: a file's text by its byte-order mark (SSMS saves a .sqlplan as UTF-16 LE), else UTF-16 LE when its first
// character is '<' followed by a zero byte, else UTF-8
function decode(b: Uint8Array): string {
  if (b[0] === 0xff && b[1] === 0xfe) return new TextDecoder('utf-16le').decode(b.subarray(2));
  if (b[0] === 0xfe && b[1] === 0xff) return new TextDecoder('utf-16be').decode(b.subarray(2));
  if (b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf) return new TextDecoder('utf-8').decode(b.subarray(3));
  if (b[0] === 0x3c && b[1] === 0x00) return new TextDecoder('utf-16le').decode(b);
  return new TextDecoder('utf-8').decode(b);
}
export async function openFile(f: File, back: HTMLElement | null = null, want?: What) {
  try { openText(f.name.replace(/\.gz$/i, ''), await readFile(f), back, want); } catch (e) {
    viewer(f.name, back, el('p', { class: 'error' }, e instanceof Error ? e.message : String(e)));
  }
}

// pick: the browser's file chooser for one kind
function pick(want: What, back: HTMLElement | null) {
  const accept = want === 'xdl' ? '.xdl,.xml' : want === 'sqlplan' ? '.sqlplan,.xml' : '.json,.csv,.gz';
  const input = el('input', { type: 'file', accept, hidden: '', 'aria-hidden': 'true' }) as HTMLInputElement;
  input.addEventListener('change', () => { const f = input.files?.[0]; input.remove(); if (f) void openFile(f, back, want); });
  input.addEventListener('cancel', () => { input.remove(); back?.focus(); });
  document.body.append(input);
  input.click();
}

// toolsButton: the bar's Tools menu (main.ts puts it in the bar)
export function toolsButton(): HTMLElement {
  const b = el('button', { type: 'button', 'aria-haspopup': 'menu', title: 'Open a deadlock graph, a query plan or a saved grid' }, 'Tools');
  const items = () => [
    { label: 'Open Deadlock Graph | *.xdl', act: () => pick('xdl', b) },
    { label: 'Open Query Plan | *.sqlplan', act: () => pick('sqlplan', b) },
    { label: 'Open Grid or Data Set | *.json;*.csv;*.gz', act: () => pick('grid', b) },
  ];
  b.setAttribute('aria-expanded', 'false');
  b.addEventListener('click', () => {
    const r = b.getBoundingClientRect();
    showTreeMenu(r.left, r.bottom + 2, items(), b, 'Tools');
    b.setAttribute('aria-expanded', 'true');
    // the menu closes by a choice, Escape, a click or the focus elsewhere: the button says so once it is gone
    const watch = window.setInterval(() => { if (!document.querySelector('.tm-menu')) { b.setAttribute('aria-expanded', 'false'); window.clearInterval(watch); } }, 250);
  });
  b.addEventListener('keydown', e => { if (e.key === 'ArrowDown') { e.preventDefault(); b.click(); } });
  return b;
}

const inField = (t: EventTarget | null) => t instanceof Element && !!t.closest('input, textarea, select, [contenteditable=""], [contenteditable="true"]');
let installed = false;
// installFileDrop: once per page load (main.ts). A file dropped on the page opens in its viewer; a deadlock graph or a
// showplan pasted outside a field too. The drop marks the page while a file is over it.
export function installFileDrop() {
  if (installed || typeof document === 'undefined') return;
  installed = true;
  document.head.append(el('style', { id: 'fd-style' }, 'body.fd-over{outline:3px dashed var(--accent);outline-offset:-6px}.fd-viewer .fd-body{max-height:calc(92vh - 7rem);overflow:auto}'));
  const hasFile = (e: DragEvent) => [...(e.dataTransfer?.types ?? [])].includes('Files');
  let depth = 0;
  document.addEventListener('dragenter', e => { if (hasFile(e)) { depth++; document.body.classList.add('fd-over'); } });
  document.addEventListener('dragleave', e => { if (hasFile(e) && --depth <= 0) { depth = 0; document.body.classList.remove('fd-over'); } });
  document.addEventListener('dragover', e => { if (hasFile(e)) { e.preventDefault(); if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy'; } });
  document.addEventListener('drop', e => {
    if (!hasFile(e)) return;
    e.preventDefault();
    depth = 0; document.body.classList.remove('fd-over');
    const f = e.dataTransfer?.files?.[0];
    if (f) void openFile(f, document.activeElement as HTMLElement | null);
  });
  document.addEventListener('paste', e => {
    if (inField(e.target) || document.querySelector('dialog[open]')) return;
    const t = e.clipboardData?.getData('text/plain') ?? '';
    const head = t.slice(0, 4000);
    if (!/<deadlock[\s>]/.test(head) && !/<ShowPlanXML[\s>]/.test(head)) return;
    e.preventDefault();
    openText(/<deadlock[\s>]/.test(head) ? 'pasted deadlock graph' : 'pasted query plan', t, document.activeElement as HTMLElement | null);
  });
}
