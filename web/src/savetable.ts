// Save Table's From items (task 7b, DBA Dash's From Data Table / From Grid): the rules the grid menu and its dialog
// follow, with no page and no fetch of their own (web/src/savetable.test.mjs runs them in node). The menu and the
// dialog are gridtools.ts's; the server's gates are internal/savetable's.

// FLEET_OFF: a fleet page's grid holds many instances' rows - written into one instance, its logins would read the
// others' outside pgvigil (review-29 S8; the lead 11-17 02:17): both From items stay in the menu, off with these words.
export const FLEET_OFF = "off: a fleet page's rows come from many instances; save from the instance's own page";

// saveKeys: what From Data Table writes - every row the page gave the grid with the page's DRAWN columns plus the ones
// the user ADDED in the chooser, in that order, each once; never a key the chooser merely offers, a '_' key (a page's
// own working value) or one the page holds back (data-gt-never: a masked text's raw form, an internal id)
export function saveKeys(own: string[], added: string[], never: string[]): string[] {
  const out: string[] = [], held = new Set(never);
  for (const k of [...own, ...added]) if (!k.startsWith('_') && !held.has(k) && !out.includes(k)) out.push(k);
  return out;
}

// fromOff: the From items' off words - a fleet page's first, then the server's (the first switch that is off); '' = on
export function fromOff(fleet: boolean, serverOff: string): string {
  if (fleet) return FLEET_OFF;
  return serverOff;
}

// confirmWord: what the user types to save - the target's instance and database, never the table's own new name
// (review-29 S7)
export function confirmWord(instance: string, database: string): string {
  return `${instance}/${database}`;
}

// defaultTable: DBA Dash's default name, the local time as yyyyMMddHHmmss
export function defaultTable(d: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

// SaveState: GET actions/save_table's answer for one instance
export interface SaveState { on: boolean; off: string; instance: string; engine: string; databases: string[]; schema?: string }
