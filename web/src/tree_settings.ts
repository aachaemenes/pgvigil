// The tree's Pause/Resume Collections and Configure Schedule for an instance added in Admin > Instances (ST5b, the
// design's D1): each dialog keeps DBA Dash's columns and writes the instance's settings through Admin > Instances' own
// write (op 'settings', with the settings as read: a change made meanwhile elsewhere is refused, never undone) - it
// prints no pgvigil.yaml line, which for an instance added here would make the page's instance drop out. treemenu.ts
// draws an instance of pgvigil.yaml as before (the lines to copy) and hands a page instance to these two.
import { Row, rowsOf, Table } from './api';
import { badge, el, fmtNum, fmtSecs, fmtTime } from './ui';
import { checkEvery, everyWords, parseEvery, pausedOf, postAdmin, resumedOf, saveSettings, Stored, withSchedule } from './settings_model';

interface CatalogueEntry { name: string; default_s: number; builtin_s: number; box: boolean; never: string }
export interface PageCollections {
  instance: string; engine: string; collections: Table | null;
  source?: string; settings?: Stored; catalogue?: Record<string, CatalogueEntry>;
  settings_floor_s?: number; settings_ceiling_s?: number; writable?: boolean; why_not?: string;
}

const every = (s: unknown) => s == null ? 'not known to this server' : Number(s) === 0 ? 'disabled' : fmtSecs(s);
const statusCell = (r: Row) => r.status === 'error' ? badge('error', 'crit') : r.status === 'skipped' ? badge('skipped', 'warn') : String(r.status ?? '');

// the words under a dialog that cannot write here, with the way to the panel
function readOnlyNote(d: PageCollections): HTMLElement {
  return el('p', { class: 'meta', role: 'note' }, `Read only here: ${d.why_not ?? 'this server cannot write the instance\'s settings'}. `,
    el('a', { href: '#/admin_instances?' + new URLSearchParams({ settings: d.instance }).toString() }, `The Settings of ${d.instance}`), ' in Admin > Instances show the same values.');
}

// the Save of a dialog: the whole object as changed, with the read as its expect; its answer in the status line
function saveButton(d: PageCollections, status: HTMLElement, next: () => Stored | string): HTMLElement {
  const b = el('button', { type: 'button' }, 'Save') as HTMLButtonElement;
  b.addEventListener('click', async () => {
    const want = next();
    if (typeof want === 'string') { status.textContent = want; status.className = 'meta error'; return; }
    b.disabled = true;
    status.textContent = `Saving the settings of ${d.instance}...`; status.className = 'meta';
    const res = await saveSettings(postAdmin, d.instance, want, d.settings ?? {});
    b.disabled = false;
    if (res.ok) d.settings = want; // the next Save of this dialog names what it wrote as its read
    const why = String(res.body.detail ?? res.body.error ?? res.body.outcome ?? 'refused');
    status.textContent = res.ok ? `${why}. ${String(res.body.takes_effect ?? '')}` : `Not saved: ${why}`;
    status.className = res.ok ? 'meta' : 'meta error';
  });
  return b;
}

// pagePauseResume: DBA Dash's Runs / Collection / Every / Last read / Status / Errors (24 h); an unticked collection is
// off for this instance (its own interval kept for the resume), a ticked one runs again
export function pagePauseResume(body: HTMLElement, d: PageCollections): void {
  const rows = rowsOf(d.collections);
  const have = d.settings ?? {};
  const cat = d.catalogue ?? {};
  const optIn = (r: Row) => r.default_s != null && Number(r.default_s) === 0;
  const isOff = (r: Row) => r.interval_s != null && Number(r.interval_s) === 0;
  const runs = new Map<string, boolean>();
  const status = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const t = el('table', { class: 'grid' }, el('thead', {}, el('tr', {}, ...['Runs', 'Collection', 'Every', 'Last read', 'Status', 'Errors (24 h)'].map(h => el('th', { scope: 'col' }, h)))),
    el('tbody', {}, ...rows.map(r => {
      const c = String(r.collection);
      const tick = el('input', { type: 'checkbox', 'aria-label': `${c} runs` }) as HTMLInputElement;
      tick.checked = !isOff(r);
      let note = '';
      if (cat[c]?.box) {
        tick.disabled = true; note = 'the running plans box: ticked or cleared on the instance\'s row in Admin > Instances';
      } else if (cat[c]?.never) {
        tick.disabled = true; note = `never here: ${cat[c].never}`;
      } else if (optIn(r)) {
        tick.disabled = true; note = 'opt-in: Configure Schedule gives it an interval';
      } else if (isOff(r) && have.schedules?.[c] === undefined) {
        note = 'off for every instance in pgvigil.yaml: ticking it gives this instance its own interval ' + everyWords(Number(cat[c]?.builtin_s ?? r.default_s ?? 0));
      } else if (have.paused?.[c] !== undefined) {
        note = `paused here; resumes at its own ${everyWords(have.paused?.[c] ?? 0)}`;
      }
      if (!d.writable) tick.disabled = true;
      if (note) tick.setAttribute('aria-label', `${c} runs: ${note}`);
      tick.addEventListener('change', () => runs.set(c, tick.checked));
      return el('tr', {}, el('td', {}, tick), el('td', {}, c, note ? el('div', { class: 'meta' }, note) : ''), el('td', {}, every(r.interval_s)), el('td', {}, fmtTime(r.snapshot_at)),
        el('td', {}, statusCell(r)), el('td', { class: 'num' }, fmtNum(r.errors_24h)));
    })));
  const next = (): Stored => {
    let s: Stored = have;
    for (const r of rows) {
      const c = String(r.collection);
      const want = runs.get(c);
      if (want === undefined || want === !isOff(r)) continue;
      s = want ? resumedOf(s, c, have.schedules?.[c] === undefined && isOff(r), Number(cat[c]?.builtin_s ?? r.default_s ?? 0)) : pausedOf(s, c);
    }
    return s;
  };
  body.replaceChildren(el('p', {}, `The collections of ${d.instance} that have stored a read. ${d.instance} was added in Admin > Instances: an unticked collection is off for it, and a ticked one runs again (at the interval of its own it had, else its default). Save writes its settings; the collector takes them within 15 s.`),
    rows.length ? el('div', { class: 'grid-wrap', tabindex: '0' }, t) : el('p', { class: 'empty' }, 'No collection has stored a read for this instance yet.'),
    d.writable ? el('div', {}, saveButton(d, status, next)) : readOnlyNote(d), status);
}

// pageConfigureSchedule: DBA Dash's Collection / Every now / Last read / Took / New interval; a new interval is the
// instance's own (5m, 1h, 2d; from the floor to 30 days), 'default' takes its own away
export function pageConfigureSchedule(body: HTMLElement, d: PageCollections): void {
  const have = d.settings ?? {};
  const cat = d.catalogue ?? {};
  const floor = Number(d.settings_floor_s ?? 60), ceiling = Number(d.settings_ceiling_s ?? 2592000);
  const rows = rowsOf(d.collections).filter(r => r.interval_s == null || Number(r.interval_s) > 0 || (r.default_s != null && Number(r.default_s) === 0));
  const inputs = new Map<string, HTMLInputElement>();
  const status = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const t = el('table', { class: 'grid' }, el('thead', {}, el('tr', {}, ...['Collection', 'Every now', 'Last read', 'Took', 'New interval'].map(h => el('th', { scope: 'col' }, h)))),
    el('tbody', {}, ...rows.map(r => {
      const c = String(r.collection);
      let cell: HTMLElement;
      if (cat[c]?.box) cell = el('span', { class: 'meta' }, 'the running plans box\'s (Admin > Instances)');
      else if (cat[c]?.never) cell = el('span', { class: 'meta' }, `never here: ${cat[c].never}`);
      else {
        const inp = el('input', { type: 'text', size: '7', placeholder: 'unchanged', 'aria-label': `new interval of ${c} (5m, 1h, 2d, or default)` }) as HTMLInputElement;
        if (!d.writable) inp.disabled = true;
        inputs.set(c, inp);
        cell = inp;
      }
      const optOff = r.default_s != null && Number(r.default_s) === 0 && !(Number(r.interval_s ?? 0) > 0);
      return el('tr', {}, el('td', {}, c), el('td', {}, optOff ? 'opt-in: off' : every(r.interval_s)), el('td', {}, fmtTime(r.snapshot_at)),
        el('td', { class: 'num' }, r.duration_ms != null ? `${fmtNum(r.duration_ms)} ms` : ''), el('td', {}, cell));
    })));
  const next = (): Stored | string => {
    let s: Stored = have;
    for (const [c, inp] of inputs) {
      const v = inp.value.trim();
      if (v === '') continue;
      if (v.toLowerCase() === 'default') { s = withSchedule(s, c, undefined); continue; }
      const secs = parseEvery(v);
      if (secs === null || secs === '' || secs === 0) return `${c}: '${v}' is not an interval (5m, 1h, 2d; off is Pause/Resume's)`;
      const why = checkEvery(secs, floor, ceiling);
      if (why) return `${c}: ${why}`;
      s = withSchedule(s, c, secs);
    }
    return s;
  };
  body.replaceChildren(el('p', {}, `How often each collection of ${d.instance} runs. ${d.instance} was added in Admin > Instances: a new interval is its own (${everyWords(floor)} or more, 30 days at most), 'default' takes its own away. Save writes its settings; the collector takes them within 15 s.`),
    rows.length ? el('div', { class: 'grid-wrap', tabindex: '0' }, t) : el('p', { class: 'empty' }, 'No running collection has stored a read for this instance yet.'),
    d.writable ? el('div', {}, saveButton(d, status, next)) : readOnlyNote(d), status);
}
