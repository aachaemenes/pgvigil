// The Collection Health rules the Imported servers page (dbadash.ts) and the tab (collection_health.ts) share, pure and
// unit-tested (chhealth.test.mjs; the review B6f3 #9, #11): which DBA Dash repositories have collection health (0138's
// dbadash_health_version), each Summary header's tooltip by its label, each row's landing by its own repository, and
// the charts' whole hours up to now.
import type { Row } from './api';

// DBA Dash 4.24.1's tooltip of its errors column (Checks/Summary.Designer.cs L433), word for word
export const collectionErrorsTip241 = 'Count of errors encountered by the DBA Dash service during data collection or import for the instance.  Retries are highlighted as warning, failures are critical.';
// B6.3: DBA Dash 4.25.0's own tooltip for its Summary's Collection Health column, quoted from its GUI
// (DBADashGUI/Checks/Summary.Designer.cs L433, CollectionErrorStatus.ToolTipText) - the lead's 23:4x call B6.3-c
export const collectionHealthTip = 'Collections at warning or critical: failing in a row for long enough, or a high failure rate since errors were acknowledged (24hrs at most) - thresholds configured in the Collection Health tab.  For an instance whose DBA Dash service predates collection health, the count of collection and import errors in the last 24hrs.  Click to see collection health.';

// a repository version at 4.25.0 or later: 0138's dbadash_health_version, word for word in its rule
export function healthVersion(v: unknown): boolean {
  const s = String(v ?? '');
  if (!/^[0-9]{1,9}(\.[0-9]{1,9})*$/.test(s)) return false;
  const p = s.split('.').map(Number);
  return p[0] > 4 || (p[0] === 4 && (p[1] ?? 0) >= 25);
}

// errColTips: the errors column header's tooltip(s) by its label - 4.25.0's for 'Collection Health', 4.24.1's for
// 'Collection errors (24hrs)', both (4.25.0's first) on a mixed fleet's 'Collection Health / Collection errors (24hrs)'
export function errColTips(label: string): string[] {
  return [label.startsWith('Collection Health') ? collectionHealthTip : '', /Collection errors/.test(label) ? collectionErrorsTip241 : ''].filter(Boolean);
}

// repoHealthOf: each repository's 'has collection health' (a row's errors cell lands on Collection Health when its
// own repository has it, whatever the others are)
export function repoHealthOf(repositories: Row[]): Map<string, boolean> {
  return new Map(repositories.map(r => [String(r.repository), healthVersion(r.version)]));
}

// chartHours: the whole hours a range touches up to now - the API has no hourly row past now, so a range ending in the
// future counts none past it (the review B6f3 #9)
export function chartHours(from: string, to: string, now = Date.now()): number {
  const hourMs = 3600000;
  return Math.round(Math.ceil(Math.min(Date.parse(to), now) / hourMs) - Math.floor(Date.parse(from) / hourMs));
}

// costWords (B6g-1; N25, N26): what a cost cell - CPU, logical reads - says when it holds no number. pgvigil reads a
// run's own session cost on SQL Server only, so a PostgreSQL row says 'not read by pgvigil' (no more is said of why);
// any other empty cell (a SQL Server row none of whose runs reached its end read, a row per collection whose instances
// do not share one engine) says 'not read'. null = the cell holds a number, zero too
export function costWords(v: unknown, engine: unknown): string | null {
  if (v != null && v !== '') return null;
  return engine === 'postgres' ? 'not read by pgvigil' : 'not read';
}

// perfCell (B6g-3, N42): what a Collection Performance cell says when it is not its row's number - a Run row (a failed
// or partial run of collection_log, the one pgvigil keeps one by one) holds its duration alone, so its CPU, logical
// reads and import say 'hourly only'; the import's own CPU, logical reads and lag have no source in pgvigil (it writes
// inside the run that collected: no queue, no lag) - 'not read' on every row; an hour's CPU and reads as costWords
// (a PostgreSQL row 'not read by pgvigil'). null = the cell shows its number
export function perfCell(key: string, v: unknown, r: Row): string | null {
  if (key === 'import_cpu_ms' || key === 'import_logical_reads' || key === 'import_lag_s') return 'not read';
  if (r.period === 'Run' && (key === 'cpu_ms' || key === 'logical_reads' || key === 'import_ms')) return 'hourly only';
  if (key === 'cpu_ms' || key === 'logical_reads') return costWords(v, r.engine);
  return null;
}

// perfCutWords: a range that starts before the hourly rows still kept (hours_retention: 8 days by default, 30 at most)
// says where the report's hours start; '' when the range is inside them. fmt: the page's time format
export function perfCutWords(from: string, keptFrom: string, days: number, fmt: (v: string) => string): string {
  if (!(Date.parse(from) < Date.parse(keptFrom))) return '';
  return `The hourly rows are kept ${days} days: the hours before ${fmt(keptFrom)} are gone, so the report starts there (a failed or partial run kept longer is still listed).`;
}

// perfCapWords: DBA Dash's row cap (CollectionPerformance_Get @MaxRows 5000): the read asks one row more, so a range
// with more rows than the cap says so; '' under it
export function perfCapWords(read: number, cap: number): string {
  return read > cap ? `The latest ${cap} rows are listed: the range holds more (pick a shorter range for the rest).` : '';
}
