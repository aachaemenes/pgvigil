// Admin > Applications, task 312: the inventory's file round trip (migration 0146, internal/web/q_app_import.go).
// The Inventory: every active server and its databases, assigned or not, as one grid; its own export writes that grid
// alone - every row whatever the grid's filter - as the house .xlsx (a sheet named Inventory), never the page workbook
// (which carries the Changes grid's user names and client addresses, and the contacts while they are shown); the CSV
// is the server's (/api/applications/inventory.csv). Import: a CSV, JSON or .xlsx file is previewed first - adds,
// changes, conflicts with a person's entries (each taken only when ticked), unknown servers and databases, refused
// lines - and applied as previewed (the preview's digest: a change in between refuses the apply whole). Contacts are
// never in the file either way.
import { get, Row, rowsOf, Table } from './api';
import { Section, exportSection } from './export';
import { Col, el, fmtTime, grid } from './ui';
import { markNeed } from './needs';

interface Item { id: string; kind: string; line: number; level?: string; instance?: string; database?: string; application?: string; outcome: string; words: string }
interface Answer {
  outcome?: string; detail?: string; error?: string; digest?: string; source?: string;
  counts?: Record<string, number>; items?: Item[]; file?: { kind: string; lines: number; columns_not_read: string[] };
}

const str = (v: unknown) => (v == null ? '' : String(v));

const invCols: Col[] = [
  { key: 'level' }, { key: 'instance' }, { key: 'engine' }, { key: 'database' }, { key: 'application' },
  { key: 'environment' }, { key: 'tier' }, { key: 'description', wide: true }, { key: 'cmdb_url', label: 'cmdb_url' },
  { key: 'not_an_application', label: 'not_an_application' }, { key: 'inherited_from', label: 'inherited_from' },
  { key: 'absent_since', label: 'absent_since', fmt: v => (v ? fmtTime(str(v)) : '') },
  { key: 'source' }, { key: 'set_at', label: 'set_at', fmt: v => (v ? fmtTime(str(v)) : '') },
];

const COUNTS: [string, string][] = [['applications_added', 'application(s) added'], ['applications_changed', 'changed'],
  ['targets_changed', 'server(s) / database(s) changed'], ['conflicts', 'conflict(s) with a person\'s entries'],
  ['unknown_servers', 'unknown server(s)'], ['unknown_databases', 'unknown database(s)'], ['refused', 'refused line(s)'],
  ['unchanged', 'unchanged line(s)'], ['servers_whose_tag_moves', 'server(s) whose application: tag moves']];

// the inventory's own workbook says what it holds on its About sheet (the lead's call h: on the button and in the file)
const INV_NOTE = 'every line of the inventory, whatever the grid on the page was filtered to; contacts are never in it';

// the import's request: the file's own bytes as the body (no base64), its kind read by the server from what it holds;
// lost: no answer could be read (a proxy's page, a cut connection) - the server may have done the work all the same
async function sendFile(bytes: ArrayBuffer, params: Record<string, string>): Promise<{ ok: boolean; body: Answer; lost: boolean }> {
  const res = await fetch('/api/admin/applications/import?' + new URLSearchParams(params), {
    method: 'POST', credentials: 'same-origin',
    headers: { Accept: 'application/json', 'Content-Type': 'application/octet-stream', 'X-Pgvigil': '1' },
    body: bytes,
  });
  try { return { ok: res.ok, body: await res.json() as Answer, lost: false }; } catch { return { ok: false, body: { error: `the server answered ${res.status}` }, lost: true }; }
}

// appFileSection: one section kept across the page's redraws (a preview survives an Open or a write elsewhere);
// refresh() reads the inventory again. whyNot: why this server takes no write ('' = it does) - the page's readOnly()
// turns this section's form controls off with that reason too.
export function appFileSection(opts: { whyNot: () => string; changed: () => Promise<void> }): { el: HTMLElement; refresh: () => Promise<void> } {
  const sec = el('section', { class: 'app-file', 'aria-label': 'The inventory file' });
  const invBox = el('div', {});
  const status = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const say = (text: string, bad = false) => { status.textContent = text; status.className = bad ? 'meta error' : 'meta'; };
  const previewBox = el('div', { 'data-part': 'import-preview' });
  let rows: Row[] = [];
  let pending: { bytes: ArrayBuffer; source: string; digest: string; name: string } | null = null;
  let busy = false;   // a preview or an apply in flight: a second click does nothing (review C, 4)

  // the inventory's own export: every row whatever the grid's filter, each value the text the repository holds (review
  // B M5 / C 2: the page's typed export wrote 1.50 as a number and Yes as a boolean and folded a two-line description,
  // so its file read back changed), one sheet named Inventory; a read, on in a read-only page (review C, 3)
  const exportBtn = el('button', { type: 'button', title: 'The whole inventory, whatever the grid below is filtered to; contacts are never in it' }, 'Export the inventory (.xlsx)');
  exportBtn.addEventListener('click', () => {
    if (!rows.length) { say('The inventory is empty: nothing to export.', true); return; }
    const keys = invCols.map(c => c.key);
    const text = (v: unknown) => (v == null ? '' : String(v));
    const book: Section = { name: 'Inventory', cols: keys, note: INV_NOTE, rows: rows.map(r => keys.map(k => ({ v: text(r[k]), kind: 'text' as const, text: text(r[k]) }))) };
    exportSection(book).then(name => say(`Exported ${rows.length} line(s) of the inventory as ${name}.`),
      (e: unknown) => say(`The export failed: ${(e as Error).message}`, true));
  });
  const csvLink = el('a', { href: '/api/applications/inventory.csv', download: '' }, 'Download the inventory (CSV)');

  const fileIn = el('input', { type: 'file', name: 'file', accept: '.csv,.json,.xlsx,text/csv,application/json', id: 'app-import-file' }) as HTMLInputElement;
  // the pattern compiles under the v flag the browser uses (an unescaped - in a class is an error there: review C, 5)
  const srcIn = el('input', { type: 'text', name: 'source', value: 'file', maxlength: '40', pattern: '[a-z0-9_.\\-]{1,40}', id: 'app-import-source' }) as HTMLInputElement;
  // the import's route needs admin (B24f): the page's read-only sentence carries the role's words below it (whyNot)
  const previewBtn = markNeed(el('button', { type: 'submit' }, 'Preview the import'), 'admin/applications/import');
  const form = el('form', { 'aria-label': 'Import a file' },
    el('label', { for: 'app-import-file' }, 'A file (CSV, JSON or .xlsx, 5 MB at most) '), fileIn, ' ',
    el('label', { for: 'app-import-source' }, 'its source name (every field it sets says import:<name>) '), srcIn, ' ',
    previewBtn) as HTMLFormElement;

  function showPreview(a: Answer, applied = false): void {
    const c = a.counts ?? {};
    const items = a.items ?? [];
    const conflicts = items.filter(i => i.outcome === 'conflict');
    // a tick is kept by its item's id, never by its checkbox: a grid draws its rows again (Copy all, the export, a
    // sort) and a redrawn row's checkbox is a new one (review C, BLOCKER 1)
    const ticks = new Map<string, boolean>();
    const itemCols: Col[] = [
      { key: 'line', num: true }, { key: 'kind' }, { key: 'instance' }, { key: 'database' }, { key: 'application' },
      { key: 'outcome', cls: v => (v === 'refused' ? 'crit' : v === 'conflict' || v === 'unknown' ? 'warn' : '') },
      { key: 'words', label: 'what it does', wide: true },
      ...(applied ? [] : [{ key: 'id', label: 'take it', fmt: (_v: unknown, r: Record<string, unknown>) => {
        if (r.outcome !== 'conflict') return '';
        const t = el('input', { type: 'checkbox', 'aria-label': r.kind === 'application' ? `Take the change of application ${str(r.application)} (line ${str(r.line)})` : `Take line ${str(r.line)}'s change` }) as HTMLInputElement;
        const id = str(r.id);
        t.checked = ticks.get(id) ?? false;
        t.addEventListener('change', () => ticks.set(id, t.checked));
        return t;
      } } as Col]),
    ];
    const notRead = a.file?.columns_not_read ?? [];
    const parts: (Node | string)[] = [
      el('h4', { tabindex: '-1' }, applied ? 'Imported' : `Preview of ${pending?.name ?? 'the file'} (${a.file?.kind ?? ''}, ${a.file?.lines ?? 0} line(s))`),
      el('p', { class: 'meta', 'data-part': 'import-counts' }, COUNTS.map(([k, w]) => `${c[k] ?? 0} ${w}`).join('; ') + '.'),
      notRead.length ? el('p', { class: 'meta', role: 'note' }, `Columns not read: ${notRead.join(', ')} (contacts are never imported; an unknown column is left out).`) : '',
      grid(items as unknown as Row[], itemCols, applied ? 'Nothing else to say.' : 'Nothing to change: the file says what the repository holds.'),
    ];
    if (!applied && pending) {
      const apply = markNeed(el('button', { type: 'button' }, conflicts.length ? 'Apply the import (ticked conflicts taken, the rest kept)' : 'Apply the import'), 'admin/applications/import');
      apply.addEventListener('click', () => void doApply([...ticks.entries()].filter(([, on]) => on).map(([id]) => id)));
      if (opts.whyNot()) { apply.setAttribute('aria-disabled', 'true'); apply.title = opts.whyNot(); }
      parts.push(el('div', { class: 'actions' }, apply));
    }
    previewBox.replaceChildren(...parts);
  }

  async function doPreview(): Promise<void> {
    const f = fileIn.files?.[0];
    if (!f) { say('Choose a file first.', true); return; }
    if (busy) return;
    busy = true;
    try {
      say('Working: reading the file and matching it...');
      const bytes = await f.arrayBuffer();
      const source = srcIn.value.trim().toLowerCase() || 'file';
      const { ok, body } = await sendFile(bytes, { source, dry: '1' });
      if (!ok || body.outcome !== 'preview') { pending = null; previewBox.replaceChildren(); say(`Not previewed: ${body.detail ?? body.error ?? 'refused'}.`, true); return; }
      pending = { bytes, source, digest: str(body.digest), name: f.name };
      showPreview(body);
      say('Previewed: nothing is written until Apply.');
    } finally { busy = false; }
  }

  // one apply at a time; an answer that cannot be read says the import may have been applied (the server finishes its
  // work whatever happens to the connection: review C, 4); the result keeps the focus after the page's redraw (C, 9)
  async function doApply(force: string[]): Promise<void> {
    if (busy || !pending || opts.whyNot()) return;
    busy = true;
    const lostWords = (why: string) => `The answer was lost (${why}): the import may have been applied - read Changes below, then preview the file again.`;
    try {
      say('Working: applying the import...');
      const { ok, body, lost } = await sendFile(pending.bytes, { source: pending.source, dry: '0', digest: pending.digest, force: force.join(',') });
      if (lost) { pending = null; say(lostWords(str(body.error)), true); return; }
      if (!ok || body.outcome !== 'done') { say(`Not applied: ${body.detail ?? body.error ?? 'refused'}.`, true); return; }
      showPreview({ ...body, items: [] }, true);
      pending = null;
      say(`Applied: ${str(body.detail)}.`);
      await opts.changed();
      await refresh();
      previewBox.querySelector<HTMLElement>('h4')?.focus();
    } catch (e) {
      pending = null;
      say(lostWords((e as Error).message), true);
    } finally { busy = false; }
  }

  form.addEventListener('submit', ev => { ev.preventDefault(); void doPreview().catch((e: unknown) => say(`Not previewed: ${(e as Error).message}`, true)); });

  async function refresh(): Promise<void> {
    try {
      rows = rowsOf(await get<Table>('applications/inventory'));
      invBox.replaceChildren(grid(rows, invCols, 'No server is monitored yet.'));
    } catch (e) {
      rows = [];
      invBox.replaceChildren(el('p', { class: 'error' }, `The inventory could not be read: ${(e as Error).message}`));
    }
  }

  sec.append(
    el('h3', {}, 'Inventory'),
    el('p', { class: 'meta' }, 'Every monitored server and its databases, assigned or not - the file a CMDB or a spreadsheet takes and gives back. ',
      'A database that inherits its server\'s application has a blank application and says inherited_from; level, instance and database are its keys; ',
      'absent_since, inherited_from, source and set_at are written for reading and never imported. The export holds every line whatever the grid is filtered to; contacts are never in it.'),
    el('p', {}, exportBtn, ' ', csvLink),
    invBox,
    el('h3', {}, 'Import a file'),
    el('p', { class: 'meta' }, 'A blank cell changes nothing; (none) removes a server\'s or a database\'s own application; not_an_application yes / no marks or unmarks a database. ',
      'A value a person entered on this page is never changed unless you tick it in the preview; a server pgvigil does not monitor is never made.'),
    form, status, previewBox,
  );
  return { el: sec, refresh };
}
