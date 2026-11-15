// pgvigil's own sessions on the pages that list sessions (B24 OWN; PerformanceMonitor's Fixed 12): hidden by default,
// with a switch. The collector marks a session its own on the monitored server (0265: the program and the login
// together); the server hides one unless a reason shows it (blocked or blocking, a request or a transaction over 60 s, a
// grant or tempdb over 100 MB) and answers own_hidden: how many it hid, the read's own in all, and since - when this
// repository began to mark them. The switch rides the address (own=1, router.ts ownTabs), so a link, Earlier / Later /
// Latest and a reload keep it; a page that reads without a link (a slider) passes ctx.own on each read.
import { Table, rowsOf } from './api';
import { Ctx, href } from './router';
import { el } from './ui';

export interface OwnHidden { rows?: number; sessions?: number; tasks?: number; pg?: number; own_sessions?: number; own_tasks?: number; since?: string | null }
export const ownOf = (t: Table | null | undefined): OwnHidden => (rowsOf(t)[0] ?? {}) as OwnHidden;
// ownParam: what a read sends (absent = the server's default: hidden)
export const ownParam = (ctx: Ctx): 1 | undefined => ctx.own ? 1 : undefined;

const why = "pgvigil's own session: shown because it blocks or is blocked, runs or holds a transaction over 60 s, holds over 100 MB of memory grant or tempdb - or because the switch is on";
// ownMark: the word 'pgvigil' beside a shown row's id when the row is pgvigil's own (words, never colour alone)
export function ownMark(r: Record<string, unknown>): HTMLElement | null {
  return r.is_own === true ? el('span', { class: 'badge own-mark', title: why }, 'pgvigil') : null;
}
// withMark: an id cell with the mark after it
export const withMark = (text: string | HTMLElement, r: Record<string, unknown>): HTMLElement => {
  const m = ownMark(r);
  return el('span', {}, text, ...(m ? [' ', m] : []));
};

// ownBar: the switch with '(n hidden)', the words for the figures counted from the server's summary ('includes n of
// pgvigil's own', where includes is given) and, for a read stored before since, that nothing in it is hidden.
// set(): the same bar for a newer reply (a page that reads without a navigation).
export function ownBar(ctx: Ctx, o: { hidden: number; includes?: number; includesWhat?: string; snapshotAt?: unknown; since?: unknown }): { bar: HTMLElement; set: (n: typeof o) => void } {
  const box = el('input', { type: 'checkbox', 'data-own-switch': '' }) as HTMLInputElement;
  box.checked = !!ctx.own;
  box.addEventListener('change', () => { location.hash = href(ctx, { tab: ctx.tab, own: box.checked ? true : undefined }); });
  const label = el('label', { class: 'own-switch' });
  const words = el('span', { class: 'meta' });
  const note = el('p', { class: 'meta own-note', role: 'status' });
  const bar = el('div', { class: 'own-bar' }, label, ' ', words, note);
  const set = (n: typeof o) => {
    label.replaceChildren(box, ` Show pgvigil's own sessions${ctx.own ? '' : ` (${n.hidden} hidden)`}`);
    words.textContent = n.includes ? `${n.includesWhat ?? 'the counts above'} include ${n.includes} of pgvigil's own` : '';
    const before = n.snapshotAt != null && (n.since == null || Date.parse(String(n.snapshotAt)) < Date.parse(String(n.since)));
    note.textContent = before ? 'this read is from before pgvigil marked its own sessions: nothing in it is hidden' : '';
    note.hidden = !before;
  };
  set(o);
  return { bar, set };
}
