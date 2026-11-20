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
// withMark: an id cell with the mark after it; data-own-id names the row's session (a page's checks find a session's
// row by it, never by a blocker column that holds the same number)
export const withMark = (text: string | HTMLElement, r: Record<string, unknown>): HTMLElement => {
  const m = ownMark(r);
  return el('span', { 'data-own-id': String(r.session_id ?? r.pid ?? '') }, text, ...(m ? [' ', m] : []));
};

// ownBar: the switch with '(n hidden)', the words for the one figure counted from the server's summary that n belongs to
// ('n of the sessions above are pgvigil's own', where includes is given) and, for a read stored before since, that
// nothing in it is hidden. o.at: the snapshot on screen when the page moved to it without a navigation (a slider):
// ticking the switch keeps it. o.hiddenWhere: words after 'n hidden' when the grid shows a cut of
// the read (a wait filter: ' in this snapshot'). set(): the same bar for a newer reply.
// The switch navigates; the focus comes back to it after the page draws again (WCAG 2.4.3).
let refocusOwn = false;
export function ownBar(ctx: Ctx, o: { hidden: number; includes?: number; includesWhat?: string; snapshotAt?: unknown; since?: unknown; at?: string; hiddenWhere?: string }): { bar: HTMLElement; set: (n: typeof o) => void } {
  const box = el('input', { type: 'checkbox', 'data-own-switch': '' }) as HTMLInputElement;
  box.checked = !!ctx.own;
  let cur = o;
  box.addEventListener('change', () => {
    let h = href(ctx, { tab: ctx.tab, own: box.checked ? true : undefined });
    if (cur.at) { const [path, qs] = h.split('?'); const q = new URLSearchParams(qs); q.set('at', cur.at); h = `${path}?${q}`; }
    refocusOwn = true;
    location.hash = h;
  });
  if (refocusOwn) {
    refocusOwn = false;
    let tries = 0;
    const back = () => { if (box.isConnected) box.focus(); else if (++tries < 60) requestAnimationFrame(back); };
    requestAnimationFrame(back);
  }
  const label = el('label', { class: 'own-switch' });
  const words = el('span', { class: 'meta' });
  // the note is the page's own text for that read (no role=status: nothing changes under the reader)
  const note = el('p', { class: 'meta own-note' });
  const bar = el('div', { class: 'own-bar' }, label, ' ', words, note);
  const set = (n: typeof o) => {
    cur = n;
    label.replaceChildren(box, ` Show pgvigil's own sessions${ctx.own ? '' : ` (${n.hidden} hidden${n.hiddenWhere ?? ''})`}`);
    words.textContent = n.includes ? `${n.includes} of ${n.includesWhat ?? 'the sessions above'} ${n.includes === 1 ? 'is' : 'are'} pgvigil's own` : '';
    const before = n.snapshotAt != null && (n.since == null || Date.parse(String(n.snapshotAt)) < Date.parse(String(n.since)));
    note.textContent = before ? 'this read is from before pgvigil marked its own sessions: nothing in it is hidden' : '';
    note.hidden = !before;
  };
  set(o);
  return { bar, set };
}
