// The Properties tab's rule for a row without a value: 'not set' where its note starts so - a value the setting may
// leave absent (N5b: Force strict encryption on SQL Server 2022 and later), an answer and not a read that failed -
// else 'not read'. The tab's value cell and its 'N not read' count both follow it. Checked offline by
// scripts/props-count-check.mjs (an esbuild bundle of this file), which scripts/proof-mssql-properties-network.sh runs.
export interface PropRow { value?: unknown; note?: unknown }

// notSet: a row whose value is absent by the setting's own answer
export function notSet(r: PropRow): boolean {
  return r.value == null && String(r.note ?? '').startsWith('not set');
}

// valueWord: the value cell's word for a row without a value ('' = it has one)
export function valueWord(r: PropRow): string {
  return r.value != null ? '' : notSet(r) ? 'not set' : 'not read';
}

export function unreadCount(props: PropRow[]): number {
  return props.filter(r => valueWord(r) === 'not read').length;
}
