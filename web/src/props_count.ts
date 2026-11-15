// The Properties tab's 'N not read' count: a row is counted when the collection stored no value for it, except a row
// whose note starts 'not set' - a value the setting may leave absent (N5b: Force strict encryption on SQL Server 2022
// and later), an answer and not a read that failed. Checked offline by scripts/props-count-check.mjs (an esbuild
// bundle of this file).
export interface PropRow { value?: unknown; note?: unknown }

export function unreadCount(props: PropRow[]): number {
  return props.filter(r => r.value == null && !String(r.note ?? '').startsWith('not set')).length;
}
