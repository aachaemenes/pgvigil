// A reader of SQL Server's STATISTICS IO / TIME messages (task 406; DBA Dash 4.25.0's Visualizer Statistics, rows N62-N67):
// the Messages text of a query run with SET STATISTICS IO, TIME ON, pasted or dropped on any page or opened from Tools
// (Open STATISTICS IO / TIME messages), read in the browser only. It shows each run's totals with how far they can be
// trusted, the I/O per table and per statement with each table's share of the logical reads, the statements' times,
// and the first run against the last; a run is the text between two PRINT 'DBADash-Compare' (or 'DBADash-Compare:
// <label>') lines. A run is also compared with a run of another file opened since the page loaded, and the messages are
// saved as a pgvigil file that Tools > Open reads again (the messages are parsed again, never the saved figures).
//
// The parser has no import of its own (the unit tests run it in Node: web/src/mssql_statsio.test.mjs); the view loads
// the page's helpers when it is drawn. Every name from the text is set as text, never as markup.

// ---- the parser --------------------------------------------------------------------------------------------------

export type TableIO = { table: string; counters: Record<string, number> };
export type Statement = {
  io: TableIO[];
  rows: number | null;        // '(n rows affected)'
  cpuMs: number | null;       // the statement's ' SQL Server Execution Times' block
  elapsedMs: number | null;
  compileCpuMs: number | null;   // the 'parse and compile time' block before it
  compileElapsedMs: number | null;
};
export type Run = { label: string; statements: Statement[]; off: boolean };
export type Parsed = { runs: Run[]; lines: number; read: number; notes: string[] };

export const MAX_TEXT = 64 * 1024 * 1024;   // as the file drop's cap

const tableRE = /^\s*Table '((?:[^']|'')+)'\.\s*(.*)$/;
const counterRE = /([A-Za-z][A-Za-z -]*?)\s+(\d+)(?=\s*[,.]|\s*$)/g;
const timesRE = /CPU time\s*=\s*(\d+)\s*ms,\s*elapsed time\s*=\s*(\d+)\s*ms/i;
const rowsRE = /^\s*\((\d+) rows? affected\)\s*$/i;
const markerRE = /^\s*DBADash-Compare(?:\s*:\s*(.*?))?\s*$/i;
const tempRE = /^(#[^#].*?)_{6,}[0-9A-F]{12}$/i;     // a temporary table's per-session suffix
// lines SSMS and Azure Data Studio add around the messages: read, not statistics
const noiseRE = /^\s*(Completion time:|Started executing query at|Total execution time:|Commands completed successfully\.?|Warning: Null value is eliminated)/i;

// tableKey: a temporary table's name without its per-session suffix, so two runs' #t compare
export function tableKey(name: string): string {
  const m = tempRE.exec(name);
  return m ? m[1] : name;
}

function newStatement(): Statement {
  return { io: [], rows: null, cpuMs: null, elapsedMs: null, compileCpuMs: null, compileElapsedMs: null };
}

const empty = (s: Statement) => !s.io.length && s.rows == null && s.cpuMs == null && s.compileCpuMs == null;

// parseMessages reads the messages into runs of statements. A statement ends at its ' SQL Server Execution Times'
// block; I/O lines and a rows-affected line before that belong to it; a 'parse and compile time' block belongs to the
// statement after it. The block that follows a DBADash-Compare line is the PRINT's own time and is left out.
export function parseMessages(text: string): Parsed {
  const lines = text.replace(/\r\n?/g, '\n').split('\n');
  const runs: Run[] = [];
  const notes: string[] = [];
  let run: Run = { label: 'run 1', statements: [], off: true };
  let cur = newStatement();
  let pending: 'compile' | 'exec' | null = null;   // a times header whose numbers are on the next line
  let skipPrint = false;
  let read = 0;
  const close = () => { if (!empty(cur)) { run.statements.push(cur); run.off = false; } cur = newStatement(); };
  const times = (cpu: number, elapsed: number, what: 'compile' | 'exec') => {
    read++;
    if (what === 'compile') { cur.compileCpuMs = (cur.compileCpuMs ?? 0) + cpu; cur.compileElapsedMs = (cur.compileElapsedMs ?? 0) + elapsed; run.off = false; return; }
    if (skipPrint) { skipPrint = false; return; }
    cur.cpuMs = cpu; cur.elapsedMs = elapsed;
    close();
  };
  for (const raw of lines) {
    const line = raw.trimEnd();
    if (!line.trim()) continue;
    const mk = markerRE.exec(line);
    if (mk) {
      close();
      if (runs.length || run.statements.length || !run.off) runs.push(run);
      run = { label: mk[1] ? mk[1] : `run ${runs.length + 1}`, statements: [], off: true };
      skipPrint = true;
      read++;
      continue;
    }
    if (/SQL Server parse and compile time/i.test(line)) { pending = 'compile'; const t = timesRE.exec(line); if (t) { times(+t[1], +t[2], 'compile'); pending = null; } continue; }
    if (/SQL Server Execution Times/i.test(line)) { pending = 'exec'; const t = timesRE.exec(line); if (t) { times(+t[1], +t[2], 'exec'); pending = null; } continue; }
    const t = timesRE.exec(line);
    if (t && pending) { times(+t[1], +t[2], pending); pending = null; continue; }
    const tb = tableRE.exec(line);
    if (tb) {
      const counters: Record<string, number> = {};
      for (const m of tb[2].matchAll(counterRE)) counters[m[1].trim().toLowerCase()] = Number(m[2]);
      cur.io.push({ table: tb[1].replace(/''/g, "'"), counters });
      run.off = false;
      read++;
      continue;
    }
    const rw = rowsRE.exec(line);
    if (rw) { cur.rows = (cur.rows ?? 0) + Number(rw[1]); read++; continue; }
    if (noiseRE.test(line)) continue;
    if (/^\s*Msg \d+, Level \d+/.test(line)) notes.push(line.trim());
  }
  close();
  runs.push(run);
  // a leading empty run (the text began with a marker) is no run
  const kept = runs.filter((r, i) => !(i === 0 && r.off && !r.statements.length && runs.length > 1));
  kept.forEach((r, i) => { if (/^run \d+$/.test(r.label)) r.label = `run ${i + 1}`; });
  const nonEmpty = lines.filter(l => l.trim()).length;
  if (nonEmpty > 0 && read === 0) notes.push('No line was read as STATISTICS IO or TIME output. SQL Server writes these messages in the login\'s language: this reader knows the English ones.');
  return { runs: kept, lines: nonEmpty, read, notes };
}

// ---- totals: how far they can be trusted (N64) --------------------------------------------------------------------

export type Totals = {
  statements: number;
  cpuMs: { low: number; high: number } | null;       // null: STATISTICS TIME was off in the run
  elapsedMs: { low: number; high: number } | null;
  logicalReads: number | null;                         // null: STATISTICS IO was off
  physicalReads: number | null;
  rows: number | null;
  exact: boolean;
  warnings: string[];
};

// topStatements counts a query text's statements at the top level (the optional box): EXEC, sp_executesql, EXEC('...'),
// SELECT, INSERT, UPDATE, DELETE, MERGE starting a statement outside strings and comments. dml says one of them
// modifies (a trigger's statements then report their own times too).
export function topStatements(sql: string): { count: number; dml: boolean } {
  const bare = sql.replace(/--[^\n]*/g, ' ').replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/N?'(?:[^']|'')*'/g, "''");
  let count = 0, dml = false, depth = 0;
  for (const tok of bare.match(/\(|\)|;|\b[A-Za-z_]+\b/g) ?? []) {
    if (tok === '(') { depth++; continue; }
    if (tok === ')') { depth = Math.max(0, depth - 1); continue; }
    if (depth > 0) continue;
    const u = tok.toUpperCase();
    if (['EXEC', 'EXECUTE', 'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'MERGE'].includes(u)) {
      count++;
      if (['INSERT', 'UPDATE', 'DELETE', 'MERGE'].includes(u)) dml = true;
    }
  }
  // an INSERT ... SELECT or a CTE's inner SELECT is one statement: a SELECT right after INSERT ... is not counted again
  const ins = (bare.match(/\bINSERT\b[^;]*?\bSELECT\b/gi) ?? []).length;
  return { count: Math.max(count - ins, 0), dml };
}

export function totals(run: Run, sql?: string): Totals {
  const st = run.statements;
  const timed = st.filter(s => s.cpuMs != null);
  const withIO = st.filter(s => s.io.length);
  const sum = (f: (s: Statement) => number | null) => st.reduce((a, s) => a + (f(s) ?? 0), 0);
  const warnings: string[] = [];
  let cpu: Totals['cpuMs'] = null, el: Totals['elapsedMs'] = null, exact = true;
  if (timed.length) {
    const hiC = sum(s => s.cpuMs), hiE = sum(s => s.elapsedMs);
    const loC = Math.max(...timed.map(s => s.cpuMs ?? 0)), loE = Math.max(...timed.map(s => s.elapsedMs ?? 0));
    const top = sql && sql.trim() ? topStatements(sql) : null;
    if (timed.length === 1) {
      cpu = { low: hiC, high: hiC }; el = { low: hiE, high: hiE };
    } else if (top && top.count === 1) {
      // one statement at the top: its own time block comes last and holds the nested ones
      const last = timed[timed.length - 1];
      cpu = { low: last.cpuMs ?? 0, high: last.cpuMs ?? 0 }; el = { low: last.elapsedMs ?? 0, high: last.elapsedMs ?? 0 };
      warnings.push('One statement at the top of the query: its own time (the last block) is the total; the blocks before it are the statements it called.');
    } else {
      cpu = { low: loC, high: hiC }; el = { low: loE, high: hiE };
      exact = false;
      warnings.push(top
        ? `The query holds ${top.count} statements at the top and the messages ${timed.length} time blocks: a statement that calls others reports its own time over theirs, so the total lies between the longest single block and all of them summed.`
        : 'Without the query\'s text the messages cannot tell a statement that called others from the ones it called: the total lies between the longest single block and all of them summed. Paste the query to narrow it.');
    }
    if (top?.dml) warnings.push('The query modifies data: a trigger\'s statements report their own times and I/O, which may count them twice.');
    if (top && top.count > 0 && timed.length < top.count) warnings.push(`The text holds ${top.count} statements and the messages only ${timed.length} time blocks: the text may not be the one that ran; ${timed.length > 1 ? 'the total is the range above' : 'the one block is the total'}.`);
  }
  const io = withIO.length ? st.flatMap(s => s.io) : null;
  return {
    statements: st.length, cpuMs: cpu, elapsedMs: el,
    logicalReads: io ? io.reduce((a, t) => a + (t.counters['logical reads'] ?? 0), 0) : null,
    physicalReads: io ? io.reduce((a, t) => a + (t.counters['physical reads'] ?? 0), 0) : null,
    rows: st.some(s => s.rows != null) ? sum(s => s.rows) : null,
    exact, warnings,
  };
}

// byTable sums each table's counters over a run (temporary tables by their name without the session's suffix); the
// counters are read by name, so a counter a newer server writes becomes a column of its own.
export function byTable(run: Run): { table: string; counters: Record<string, number>; share: number | null }[] {
  const m = new Map<string, Record<string, number>>();
  for (const s of run.statements) for (const t of s.io) {
    const k = tableKey(t.table), c = m.get(k) ?? {};
    for (const [n, v] of Object.entries(t.counters)) c[n] = (c[n] ?? 0) + v;
    m.set(k, c);
  }
  const all = [...m.values()].reduce((a, c) => a + (c['logical reads'] ?? 0), 0);
  return [...m.entries()].map(([table, counters]) => ({ table, counters, share: all ? Math.round(1000 * (counters['logical reads'] ?? 0) / all) / 10 : null }))
    .sort((a, b) => (b.counters['logical reads'] ?? 0) - (a.counters['logical reads'] ?? 0));
}

// counterNames: every counter name of a run's tables, the common ones first
export function counterNames(runs: Run[]): string[] {
  const order = ['scan count', 'logical reads', 'physical reads', 'page server reads', 'read-ahead reads', 'page server read-ahead reads',
    'lob logical reads', 'lob physical reads', 'lob page server reads', 'lob read-ahead reads', 'lob page server read-ahead reads', 'segment reads', 'segment skipped'];
  const seen = new Set<string>();
  for (const r of runs) for (const s of r.statements) for (const t of s.io) for (const k of Object.keys(t.counters)) seen.add(k);
  return [...order.filter(k => seen.has(k)), ...[...seen].filter(k => !order.includes(k)).sort()];
}

// change: the percent change from a to b; null when either side is blank
export function change(a: number | null | undefined, b: number | null | undefined): number | null {
  if (a == null || b == null) return null;
  if (a === 0) return b === 0 ? 0 : null;
  return Math.round(1000 * (b - a) / a) / 10;
}

// ---- the saved file (N67): the messages, read again when the file is opened ---------------------------------------

export const SAVE_KIND = 'pgvigil-statistics';

export function saveText(name: string, messages: string, query: string): string {
  return JSON.stringify({ kind: SAVE_KIND, version: 1, name, saved: new Date().toISOString(), messages, query }, null, 1);
}

// readSaved: the messages and the query of a saved file, or null when the text is not one (the figures in it, if any,
// are not read: the messages are parsed again)
export function readSaved(text: string): { name: string; messages: string; query: string } | null {
  try {
    const d = JSON.parse(text) as { kind?: string; messages?: unknown; query?: unknown; name?: unknown };
    if (d?.kind !== SAVE_KIND || typeof d.messages !== 'string') return null;
    return { name: typeof d.name === 'string' ? d.name : '', messages: d.messages, query: typeof d.query === 'string' ? d.query : '' };
  } catch {
    return null;
  }
}

// looksLikeStatistics: a pasted text that is STATISTICS output (the file drop's paste detector)
export function looksLikeStatistics(text: string): boolean {
  return /Table '[^']+'\. Scan count \d+/.test(text) || /SQL Server Execution Times:/.test(text) || /SQL Server parse and compile time:/.test(text);
}

// ---- the documents opened since the page loaded (N66: compare with another file's run) --------------------------

type Doc = { id: number; name: string; parsed: Parsed };
const docs: Doc[] = [];
let nextDoc = 1;

// ---- the view ----------------------------------------------------------------------------------------------------

const fmtMs = (v: { low: number; high: number } | null) => v == null ? '' : v.low === v.high ? `${v.low.toLocaleString()} ms` : `${v.low.toLocaleString()} - ${v.high.toLocaleString()} ms`;

// statsioView draws a messages text: the parts a viewer dialog holds (filedrop's Tools > Open and paste call it).
export async function statsioView(name: string, text: string): Promise<HTMLElement[]> {
  const { el, grid, badge, offControl } = await import('./ui');
  if (text.length > MAX_TEXT) return [el('p', { class: 'error' }, `The text is over ${MAX_TEXT / 1024 / 1024} MB: not read.`)];
  const saved = readSaved(text);
  const messages = saved ? saved.messages : text;
  let query = saved ? saved.query : '';
  const doc: Doc = { id: nextDoc++, name: saved?.name || name, parsed: parseMessages(messages) };
  docs.push(doc);
  const out = el('div');
  const qbox = el('textarea', { rows: '4', cols: '80', 'aria-label': 'The query that ran (optional: it narrows the totals)', placeholder: 'the query that ran (optional)' }) as HTMLTextAreaElement;
  qbox.value = query;
  const bar = (v: number, max: number) => {
    const w = max > 0 ? Math.round(100 * v / max) : 0;
    return el('span', { class: 'meta', title: `${v.toLocaleString()} of ${max.toLocaleString()}` },
      el('span', { style: `display:inline-block;height:.6em;width:${w}px;max-width:100px;background:currentColor;opacity:.45;margin-right:.3em`, 'aria-hidden': 'true' }), v.toLocaleString());
  };
  const draw = () => {
    const p = doc.parsed, names = counterNames(p.runs);
    const kids: (Node | string)[] = [el('p', { class: 'meta' }, `${p.runs.length} run${p.runs.length === 1 ? '' : 's'}, ${p.read} of ${p.lines} lines read as statistics. Read in the browser only.`)];
    for (const n of p.notes) kids.push(el('p', { class: 'meta' }, n));
    p.runs.forEach(run => {
      const t = totals(run, query);
      kids.push(el('h4', {}, run.label));
      if (run.off) { kids.push(el('p', { class: 'meta' }, 'STATISTICS IO and TIME were off in this run: nothing to read (left blank, not 0).')); return; }
      kids.push(el('div', { class: 'tiles' },
        ...[['statements', String(t.statements)], ['CPU', fmtMs(t.cpuMs) || 'TIME off'], ['elapsed', fmtMs(t.elapsedMs) || 'TIME off'],
          ['logical reads', t.logicalReads == null ? 'IO off' : t.logicalReads.toLocaleString()],
          ['physical reads', t.physicalReads == null ? 'IO off' : t.physicalReads.toLocaleString()],
          ['rows', t.rows == null ? '' : t.rows.toLocaleString()]].map(([k, v]) => el('div', { class: 'tile' }, el('div', { class: 'tile-v' }, v), el('div', { class: 'tile-k' }, k)))));
      kids.push(el('p', { class: 'meta' }, t.exact ? 'The totals are exact for this run.' : 'The totals are a range: see why below.'));
      for (const w of t.warnings) kids.push(el('p', { class: 'meta' }, badge(t.exact ? 'note' : 'range', t.exact ? 'info' : 'warn'), ' ', w));
      const tabs = byTable(run), maxLR = Math.max(0, ...tabs.map(x => x.counters['logical reads'] ?? 0));
      kids.push(el('h5', {}, 'I/O by table'), grid(tabs.map(x => ({ table: x.table, share: x.share, ...x.counters })), [
        { key: 'table' }, { key: 'share', label: '% logical reads', num: true },
        ...names.map(n => ({ key: n, num: true, fmt: n === 'logical reads' ? (v: unknown) => bar(Number(v ?? 0), maxLR) : undefined })),
      ], 'No table I/O in this run (STATISTICS IO off).'));
      const maxMs = Math.max(0, ...run.statements.map(s => s.elapsedMs ?? 0));
      kids.push(el('h5', {}, 'Statements'), grid(run.statements.map((s, i) => ({
        n: i + 1, rows: s.rows, cpu: s.cpuMs, elapsed: s.elapsedMs, ccpu: s.compileCpuMs, cel: s.compileElapsedMs,
        tables: s.io.map(x => tableKey(x.table)).join(', '), reads: s.io.length ? s.io.reduce((a, x) => a + (x.counters['logical reads'] ?? 0), 0) : null,
        share: t.logicalReads ? Math.round(1000 * s.io.reduce((a, x) => a + (x.counters['logical reads'] ?? 0), 0) / t.logicalReads) / 10 : null,
      })), [
        { key: 'n', label: '#', num: true }, { key: 'rows', label: 'rows affected', num: true },
        { key: 'cpu', label: 'CPU ms', num: true, fmt: v => v == null ? '' : String(v) },
        { key: 'elapsed', label: 'elapsed ms', num: true, fmt: v => v == null ? '' : bar(Number(v), maxMs) },
        { key: 'ccpu', label: 'compile CPU ms', num: true }, { key: 'cel', label: 'compile elapsed ms', num: true },
        { key: 'tables' }, { key: 'reads', label: 'logical reads', num: true }, { key: 'share', label: '% logical reads', num: true },
      ]));
    });
    // the first run against the last (N65), and a run against another file's (N66)
    const cmp = (a: Run, b: Run, la: string, lb: string): HTMLElement[] => {
      const ta = a.off ? null : totals(a, query), tb = b.off ? null : totals(b, query);
      const rowsT = [
        ['CPU ms (high)', ta?.cpuMs?.high, tb?.cpuMs?.high], ['elapsed ms (high)', ta?.elapsedMs?.high, tb?.elapsedMs?.high],
        ['logical reads', ta?.logicalReads, tb?.logicalReads], ['physical reads', ta?.physicalReads, tb?.physicalReads], ['rows', ta?.rows, tb?.rows],
      ].map(([what, x, y]) => ({ what, a: x ?? null, b: y ?? null, change: change(x as number, y as number) }));
      const ma = new Map(byTable(a).map(x => [x.table, x.counters['logical reads'] ?? 0]));
      const mb = new Map(byTable(b).map(x => [x.table, x.counters['logical reads'] ?? 0]));
      const tabs = [...new Set([...ma.keys(), ...mb.keys()])].map(tb2 => ({ table: tb2, a: ma.get(tb2) ?? null, b: mb.get(tb2) ?? null, change: change(ma.get(tb2), mb.get(tb2)) }));
      const ch = { key: 'change', label: 'change %', num: true, fmt: (v: unknown) => v == null ? '' : badge(`${Number(v) > 0 ? '+' : ''}${v} %`, Number(v) > 0 ? 'warn' : Number(v) < 0 ? 'ok' : 'info') };
      return [grid(rowsT, [{ key: 'what', label: 'total' }, { key: 'a', label: la, num: true }, { key: 'b', label: lb, num: true }, ch]),
        grid(tabs, [{ key: 'table' }, { key: 'a', label: `${la} logical reads`, num: true }, { key: 'b', label: `${lb} logical reads`, num: true }, ch], 'No table I/O on either side.')];
    };
    if (p.runs.length > 1) {
      const a = p.runs[0], b = p.runs[p.runs.length - 1];
      kids.push(el('h4', {}, `Comparison: ${a.label} against ${b.label}`), el('p', { class: 'meta' }, 'Red is more, green is less; a run with STATISTICS off is blank, not 0.'), ...cmp(a, b, a.label, b.label));
    }
    const others = docs.filter(d => d.id !== doc.id).flatMap(d => d.parsed.runs.map((r, i) => ({ d, r, i })));
    const sel = el('select', { 'aria-label': 'Compare the last run with a run of another opened file' }) as HTMLSelectElement;
    const cmpOut = el('div', { 'aria-live': 'polite' });
    const offNote = el('p', { class: 'meta' }, others.length ? '' : 'No other file has statistics to compare with: open another one first.');
    if (!others.length) {
      sel.append(el('option', {}, 'No other file has statistics to compare with'));
      offControl(sel, 'No other file has statistics to compare with: open another one first', offNote);
    } else {
      sel.append(el('option', { value: '' }, 'pick a run'), ...others.map((o, k) => el('option', { value: String(k) }, `${o.d.name}: ${o.r.label}`)));
      sel.addEventListener('change', () => {
        const o = others[Number(sel.value)];
        const mine = p.runs[p.runs.length - 1];
        cmpOut.replaceChildren(...(sel.value === '' || !o ? [] : cmp(mine, o.r, `${doc.name}: ${mine.label}`, `${o.d.name}: ${o.r.label}`)));
      });
    }
    kids.push(el('h4', {}, 'Compare with another file'), el('label', {}, 'Run ', sel), others.length ? '' : offNote, cmpOut);
    out.replaceChildren(...kids);
  };
  const save = el('button', { type: 'button' }, 'Save messages');
  save.addEventListener('click', () => {
    const url = URL.createObjectURL(new Blob([saveText(doc.name, messages, qbox.value)], { type: 'application/json' }));
    const a = el('a', { href: url, download: `${(doc.name || 'statistics').replace(/[^A-Za-z0-9._-]+/g, '_').replace(/\.(txt|json)$/i, '')}.statistics.json` }) as HTMLAnchorElement;
    document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 60_000);
  });
  qbox.addEventListener('change', () => { query = qbox.value; draw(); });
  draw();
  return [el('div', { class: 'toolbar' }, el('label', {}, 'Query ', qbox), save), out];
}
