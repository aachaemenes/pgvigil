// The Memory tab of an instance (phase 3 wave F, task 62): the buffer cache by relation (pg_buffercache, where the
// server's DBA installed it: hourly, the 50 relations holding the most of shared_buffers with their dirty share and
// usage counts, and the used, dirty and largest-relation shares over the window), the temp-file spills by statement
// and by hour (pg_stat_statements' temp blocks and the log's temporary-file lines), and the temp files by database
// from the database statistics (the TempDB-shaped view: every temp file counts there, whatever log_temp_files says).
// Data from /api/memory; the lead wires the tab (router.ts, main.ts).
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtTime, grid, props, tile } from './ui';

type MemoryParts = 'buffer_state' | 'buffer_rels' | 'buffer_series' | 'temp_statements' | 'temp_hours' | 'temp_databases' | 'findings';

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const pct = (v: unknown) => v == null ? '' : fmtNum(v) + ' %';
const relkinds: Record<string, string> = { r: 'table', i: 'index', t: 'TOAST', m: 'materialized view', S: 'sequence', p: 'partitioned table', I: 'partitioned index' };

export const findingCols: Col[] = [
  { key: 'severity', fmt: sevBadge }, { key: 'setting', label: 'finding' }, { key: 'value' }, { key: 'suggested' },
  { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime },
];

// relName: schema.name, or the database and file node of a relation the connected database cannot name
function relName(_: unknown, r: Row): string {
  if (r.relname != null) return `${String(r.schemaname ?? '')}.${String(r.relname)}`;
  return `(file node ${String(r.relfilenode ?? '?')})`;
}

const relCols: Col[] = [
  { key: 'datname', label: 'database' },
  { key: 'relname', label: 'relation', fmt: relName },
  { key: 'relkind', label: 'kind', fmt: v => v == null ? '' : relkinds[String(v)] ?? String(v) },
  { key: 'buffers', num: true },
  { key: 'bytes', label: 'size in cache', num: true, fmt: fmtBytes },
  { key: 'share_pct', label: 'share of shared_buffers', num: true, fmt: pct },
  { key: 'dirty', label: 'dirty buffers', num: true },
  { key: 'dirty_pct', label: 'dirty share', num: true, fmt: pct },
  { key: 'usage_avg', label: 'mean usage count (0-5)', num: true },
  { key: 'usage_hot', label: 'buffers at usage 3+', num: true },
];

const stmtCols: Col[] = [
  { key: 'temp_written_bytes', label: 'temp written', num: true, fmt: fmtBytes },
  { key: 'temp_read_bytes', label: 'temp read', num: true, fmt: fmtBytes },
  { key: 'worst_hour_bytes', label: 'worst hour', num: true, fmt: fmtBytes },
  { key: 'hours', label: 'hours spilling', num: true },
  { key: 'datname', label: 'database' },
  { key: 'usename', label: 'role' },
  { key: 'queryid' },
  { key: 'query', label: 'statement text', wide: true },
];

const hourCols: Col[] = [
  { key: 'snapshot_at', label: 'hour', fmt: fmtTime },
  { key: 'temp_written_bytes', label: 'written by statements', num: true, fmt: fmtBytes },
  { key: 'log_files', label: 'temp files logged', num: true },
  { key: 'log_bytes', label: 'logged bytes', num: true, fmt: fmtBytes },
  { key: 'log_max_file_bytes', label: 'largest file', num: true, fmt: fmtBytes },
  { key: 'data_bytes', label: 'data size', num: true, fmt: fmtBytes },
  { key: 'data_pct', label: 'share of the data', num: true, fmt: pct },
];

const dbCols: Col[] = [
  { key: 'datname', label: 'database' },
  { key: 'temp_files', label: 'temp files', num: true },
  { key: 'temp_bytes', label: 'temp bytes', num: true, fmt: fmtBytes },
  { key: 'peak_bytes_s', label: 'peak bytes / s', num: true, fmt: fmtBytes },
];

function bufferSection(state: Row | undefined, rels: Row[], series: Row[]): HTMLElement {
  const sec = el('section', {}, el('h3', {}, 'Buffer cache (shared_buffers by relation)'));
  if (!state) {
    sec.append(el('p', { class: 'empty' }, 'The buffercache collection has not read this instance yet (hourly).'));
    return sec;
  }
  if (state.status !== 'ok') {
    sec.append(el('p', { class: 'meta' }, badge('not available', 'warn'), ` ${String(state.reason ?? '')} (read ${fmtTime(state.snapshot_at)}).`));
    return sec;
  }
  const total = Number(state.total_buffers ?? 0);
  const share = (n: unknown) => total > 0 ? fmtNum(Math.round(1000 * Number(n ?? 0) / total) / 10) + ' %' : '-';
  sec.append(el('div', { class: 'tiles' },
    tile('shared_buffers', fmtBytes(state.total_bytes)),
    tile('used', share(state.used_buffers)),
    tile('dirty', share(state.dirty_buffers)),
    tile('largest relation', rels.length ? pct(rels[0].share_pct) : '-'),
  ));
  sec.append(props([
    ['buffers', `${fmtNum(state.total_buffers)} of ${fmtNum(state.block_size)} bytes`],
    ['last read', fmtTime(state.snapshot_at)],
  ]));
  sec.append(el('p', { class: 'meta' }, 'The 50 relations holding the most buffers at the last read. A relation of another database '
    + 'than the one pgvigil connects to keeps its database and file node (the server names a file node only in its own database).'));
  sec.append(grid(rels, relCols, 'No relation in the cache at the last read.'));
  sec.append(lineChart('Share of shared_buffers (%)', series, [
    { key: 'used_pct', label: 'used' }, { key: 'dirty_pct', label: 'dirty' }, { key: 'top_rel_pct', label: 'largest relation' },
  ], v => fmtNum(v) + ' %'));
  return sec;
}

export async function memory(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Memory (${rangeLabel(ctx)})`));
  try {
    const d = await get<Record<MemoryParts, Table | null>>('memory', { instance: ctx.instance, ...window_(ctx) });
    const findings = rowsOf(d.findings);
    if (findings.length) sec.append(el('h3', {}, 'Findings'), grid(findings, findingCols));
    sec.append(bufferSection(rowsOf(d.buffer_state)[0], rowsOf(d.buffer_rels), rowsOf(d.buffer_series)));

    const hours = rowsOf(d.temp_hours);
    const temp = el('section', {}, el('h3', {}, 'Temp-file spills'),
      el('p', { class: 'meta' }, 'A sort or hash that does not fit work_mem writes temp files. By statement: pg_stat_statements\' '
        + 'temp blocks per hour (the statements collection). By hour: those summed, beside the log\'s temporary-file lines '
        + '(only files at or above log_temp_files are logged; -1 logs none) and the data size. A statement writing more than '
        + '1 GB in an hour, and an hour whose temp files exceed 10 % of the data, are findings.'));
    temp.append(el('h4', {}, 'By statement'), grid(rowsOf(d.temp_statements), stmtCols, 'No statement spilled to temp files in this window.'));
    temp.append(el('h4', {}, 'By hour'), lineChart('Temp bytes per hour', hours, [
      { key: 'temp_written_bytes', label: 'written by statements' }, { key: 'log_bytes', label: 'logged' },
    ], fmtBytes), grid(hours, hourCols, 'No hour rolled up in this window (the temp_files collection runs hourly).'));
    sec.append(temp);

    sec.append(el('section', {}, el('h3', {}, 'Temp files by database'),
      el('p', { class: 'meta' }, 'pg_stat_database\'s temp_files and temp_bytes over the window: every temp file, logged or not.'),
      grid(rowsOf(d.temp_databases), dbCols, 'No database statistics in this window.')));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
