// Saved page views (VIEWS slice B; DBA Dash's View drop-down, P10 D16 / D23 and P09 D26): a named state of one page -
// its own address keys (router.ts viewPageKeys) and the layouts of its grids (gridtools.ts) - kept in the repository
// (slice A's /api/views: personal or shared, one default per page each), on the Summary, the Performance Summary and
// the Slow Queries pages.
//
// The address is the only source: main.ts render() calls resolveView before the page draws. view=<id> loads that
// view's layouts (its keys are already in the address); view=none is {None}; no view= and none of the page's keys on
// entering the page (another page, instance or tag before it, or a reload) loads the user's default for the page, else
// the shared one - once, written into the address; a mail render (reportmail.ts) takes no view at all. A view's
// layouts are a layer over the browser's own grid choices: {None} or another page gives those back.
//
// viewControl is the page's 'View: <name>' button and its lines: the page's own items, {None}, the shared views and
// the user's own, the loaded one ticked; Save, Save as..., Rename..., Delete... - each off with the server's reason
// when this user may not (saving off: demo, -no-login, no audit login; a shared view below the admin role: B24f).
import { Table, rowsOf } from './api';
import { Layout, layerState, layoutsOf, setLayer } from './gridtools';
import { Ctx, hashKeys, href, noteAddress, pageKeyOf, viewPageKeys } from './router';
import { el, showMenu } from './ui';

interface ViewState { params?: Record<string, string>; layouts?: Layout[]; range?: { w?: string; from?: string; to?: string } }
interface ViewRow {
  view_id: number; name: string; page: string; folder?: string | null; description?: string | null; shared: boolean; mine: boolean;
  is_default: boolean; loads_by_default: boolean; owner?: string | null; version: number; state?: ViewState;
}
interface ListReply { views: Table | null; writable: boolean; shared_writable: boolean; off: string; shared_off: string; user: string }
export interface ViewHooks {
  read(): Record<string, string>;                 // the effective value of every page key, as text (V2)
  items?: () => [string, () => void][];          // the page's own items, first in the menu (the Summary's toggles, Auto Size)
}

let mailRender = false;
export const setMailRender = (on: boolean) => { mailRender = on; };
let loaded: ViewRow | null = null;   // the view on screen
let controlAbort: AbortController | null = null;   // the window listeners of the control on screen (one per page)
let lines: string[] = [];            // this render's words under the toolbar (a view not opened, of another page)
const lists = new Map<string, Promise<ListReply | null>>();   // per page key for the tab's life; dropped on any write
const toRow = (r: Record<string, unknown>): ViewRow => ({ ...r, view_id: Number(r.view_id), version: Number(r.version) } as unknown as ViewRow);

async function call(method: 'GET' | 'POST', path: string, body?: unknown): Promise<{ code: number; body: Record<string, unknown> | null }> {
  const res = await fetch('/api/' + path, {
    method, credentials: 'same-origin',
    headers: { Accept: 'application/json', 'X-Pgvigil': '1', ...(body ? { 'Content-Type': 'application/json' } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  return { code: res.status, body: await res.json().catch(() => null) as Record<string, unknown> | null };
}
function list(page: string): Promise<ListReply | null> {
  let p = lists.get(page);
  if (!p) {
    // a failed read (a 5xx, a 401, the network) is not kept: the next render asks again (review L2)
    const forget = (): null => { if (lists.get(page) === p) lists.delete(page); return null; };
    p = call('GET', 'views?page=' + encodeURIComponent(page)).then(r => r.code === 200 ? r.body as unknown as ListReply : forget()).catch(forget);
    lists.set(page, p);
  }
  return p;
}
async function fetchView(id: number): Promise<{ code: number; row?: ViewRow; error?: string }> {
  const r = await call('GET', 'views?id=' + id).catch(e => ({ code: 0, body: { error: String(e) } as Record<string, unknown> }));
  const t = r.body?.view as Table | undefined;
  const row = t ? rowsOf(t)[0] : undefined;
  return row ? { code: r.code, row: toRow(row) } : { code: r.code, error: String(r.body?.error ?? 'no answer') };
}
function drop() { if (loaded || layerState().on) { loaded = null; setLayer(null); } }
const pageKeysOf = (page: string) => (viewPageKeys[page] ?? []);

// addressOf: this page's address with a view's keys (every page key replaced) and view=<id>; its range only when asked
function addressOf(ctx: Ctx, v: ViewRow, withRange: boolean): string {
  const [path, qs] = href(ctx, { tab: ctx.tab }).split('?');
  const q = new URLSearchParams(qs);
  for (const k of [...pageKeysOf(v.page), 'view']) q.delete(k);
  for (const [k, val] of Object.entries(v.state?.params ?? {})) if (pageKeysOf(v.page).includes(k) && val !== '') q.set(k, val);
  q.set('view', String(v.view_id));
  const r = v.state?.range;
  if (withRange && r) {
    q.delete('w'); q.delete('from'); q.delete('to');
    if (r.w) q.set('w', r.w); else if (r.from && r.to) { q.set('from', r.from); q.set('to', r.to); }
  }
  return `${path}?${q}`;
}

// resolveView (V1): before the page draws. true = the address was written (a default, or a view's keys the address
// lacked): the caller parses it again. current() false = the reader moved on while a read was out (another render
// started): nothing is written - never a left page's keys, view or layer into the page on screen (review B1).
export async function resolveView(ctx: Ctx, entering: boolean, current: () => boolean = () => true): Promise<boolean> {
  lines = [];
  const page = pageKeyOf(ctx), keys = viewPageKeys[page];
  if (!keys || mailRender) { drop(); return false; }
  const q = hashKeys(), v = q.get('view');
  if (v === 'none') { drop(); return false; }
  if (v && /^\d+$/.test(v)) {
    const id = Number(v);
    if (loaded && loaded.view_id === id && loaded.page === page) return false;   // the same view: its layer and its edits kept
    const r = await fetchView(id);
    if (!current()) return false;
    if (r.code === 404) { drop(); lines.push(`view ${id} is not yours to open: its address applied, its layouts not`); return false; }
    if (!r.row) { drop(); lines.push(`view ${id} could not be read: ${r.error ?? ''}`); return false; }
    if (r.row.page !== page) { drop(); lines.push(`view ${id} belongs to another page (${r.row.page}): not applied`); return false; }
    loaded = r.row; setLayer(r.row.state?.layouts ?? []);
    // a link of a view (view=N) brings its page keys: each one the address lacks is the view's (the address first, A;
    // review H1)
    const set: Record<string, string> = {};
    for (const k of keys) { const val = r.row.state?.params?.[k]; if (!q.has(k) && val) set[k] = val; }
    if (Object.keys(set).length) { noteAddress(set); return true; }
    return false;
  }
  if (!v && entering && !keys.some(k => q.has(k))) {
    const l = await list(page);
    if (!current()) return false;
    const d = rowsOf(l?.views).map(toRow).find(x => x.loads_by_default);
    if (d) {
      const r = await fetchView(d.view_id);
      if (!current()) return false;
      if (r.row && r.row.page === page) {
        const want = new URLSearchParams(addressOf(ctx, r.row, false).split('?')[1]);
        const set: Record<string, string | undefined> = {};
        for (const k of [...keys, 'view']) set[k] = want.get(k) ?? undefined;
        noteAddress(set);
        loaded = r.row; setLayer(r.row.state?.layouts ?? []);
        return true;
      }
    }
  }
  drop();
  return false;
}

// viewControl: the page's View button and the lines under its toolbar
export function viewControl(ctx: Ctx, hooks: ViewHooks): { button: HTMLElement; notes: HTMLElement } {
  const page = pageKeyOf(ctx);
  const button = el('button', { type: 'button', class: 'tb-btn', 'data-view-control': '', 'aria-haspopup': 'menu' }, '');
  const notes = el('div', { class: 'view-notes' });
  const changed = () => {
    if (!loaded) return false;
    if (layerState().edited) return true;
    // the page's effective values against the view's (a key the page removed or never wrote counts too: review M2)
    const eff = hooks.read(), p = loaded.state?.params ?? {};
    return pageKeysOf(page).some(k => (eff[k] ?? '') !== (p[k] ?? ''));
  };
  const label = () => { button.textContent = `View: ${loaded ? loaded.name : 'None'}${changed() ? ' (changed)' : ''}`; };
  const note = (text: string, extra?: HTMLElement) => { notes.append(el('p', { class: 'view-note', role: 'status' }, text, ...(extra ? [' ', extra] : []))); };
  const drawNotes = () => {
    notes.replaceChildren();
    for (const l of lines) note(l);
    const m = layerState().missing;
    if (m.length) note(`${m.length} grid layout${m.length === 1 ? '' : 's'} of this view no longer match${m.length === 1 ? 'es' : ''}: skipped (${m.join(', ')})`);
  };
  label(); drawNotes();
  // the previous control's listeners go when this one is built (the live Summary builds one every 30 s); a button the
  // page detached for a moment (Slow queries' 'Reading...') keeps its listeners and its label (review M3)
  controlAbort?.abort();
  controlAbort = new AbortController();
  const signal = controlAbort.signal;
  const onChange = () => { label(); };
  let settle = 0;
  const onDrawn = () => { window.clearTimeout(settle); settle = window.setTimeout(drawNotes, 300); };
  window.addEventListener('pgvigil:address', onChange, { signal });
  window.addEventListener('pgvigil:layer', onChange, { signal });
  window.addEventListener('pgvigil:drawn', onDrawn, { signal });

  const params = (): Record<string, string> => {
    const p = { ...hooks.read() }, cur = hashKeys();
    for (const k of ['w', 'from', 'to']) { const v = cur.get(k); if (v) p[k] = v; }   // the server keeps them only with keep_range
    return p;
  };
  const open = (v: ViewRow, withRange: boolean) => {
    loaded = v; setLayer(v.state?.layouts ?? []);
    const h = addressOf(ctx, v, withRange);
    if (location.hash !== h) location.hash = h; else { label(); drawNotes(); }
  };
  const loadId = async (id: number, withRange: boolean) => {
    const r = await fetchView(id);
    if (r.row) open(r.row, withRange); else note(`view ${id} could not be read: ${r.error ?? ''}`);
  };
  const save = async (body: Record<string, unknown>): Promise<{ ok: boolean; id?: number; words: string; code: number }> => {
    const r = await call('POST', 'views', body).catch(e => ({ code: 0, body: { error: String(e) } as Record<string, unknown> }));
    lists.delete(page);
    if (r.code === 200) return { ok: true, id: Number(r.body?.view_id), words: String(r.body?.detail ?? 'saved'), code: 200 };
    return { ok: false, words: String(r.body?.error ?? `HTTP ${r.code}`), code: r.code };
  };
  // stale: the store's 409 for a version read before another save (a taken name is a 409 too: reloading does not help)
  const stale = (words: string) => /changed elsewhere: version \d+ is stored/.test(words);
  const conflict = (words: string, id: number) => {
    const b = el('button', { type: 'button', class: 'link' }, 'Load the stored one');
    b.addEventListener('click', () => { void loadId(id, false); });
    note(words, b);
  };

  button.addEventListener('click', () => { void (async () => {
    const l = await list(page);
    const views = rowsOf(l?.views).map(toRow);
    const items: [string, () => void][] = [...(hooks.items?.() ?? [])];
    const off = new Map<number, string>();
    items.push([`${loaded ? '' : '✓ '}{None}`, () => { drop(); noteAddress({ view: 'none' }); label(); drawNotes(); }]);
    if (!l || !l.views) {
      off.set(items.length, l?.off || 'the saved views could not be read');
      items.push([`Saved views: ${l?.off || 'the saved views could not be read'}`, () => undefined]);
    }
    const shared = views.filter(v => v.shared).sort((a, b) => a.name.localeCompare(b.name));
    const mine = views.filter(v => !v.shared).sort((a, b) => a.name.localeCompare(b.name));
    for (const v of [...shared, ...mine]) {
      items.push([`${loaded?.view_id === v.view_id ? '✓ ' : ''}${v.name} (${v.shared ? 'shared' : 'mine'})${v.loads_by_default ? ' - default' : ''}`, () => { void loadId(v.view_id, true); }]);
    }
    const writeOff = !l ? 'the saved views could not be read' : l.off;
    const thisOff = !loaded ? 'no view is loaded: Save as... names one' : loaded.page !== page ? 'the loaded view belongs to another page' : writeOff || (loaded.shared ? l?.shared_off ?? '' : (!loaded.mine ? 'only its owner changes a personal view' : ''));
    const first = items.length;
    items.push(['Save', () => { void doSave(); }], ['Save as...', () => saveAsDialog(l)], ['Rename...', () => renameDialog()], ['Delete...', () => deleteDialog()]);
    [thisOff, writeOff, thisOff, thisOff].forEach((why, k) => { if (why) off.set(first + k, why); });
    const r = button.getBoundingClientRect();
    showMenu(r.left, r.bottom, items.map(([t, f], k) => [t, off.has(k) ? () => note(`${t.replace(/\.\.\.$/, '')}: ${off.get(k)}`) : f] as [string, () => void]), button);
    const menu = [...document.querySelectorAll<HTMLElement>('div.menu[role=menu]')].pop();
    menu?.querySelectorAll<HTMLButtonElement>('[role=menuitem]').forEach((b, k) => {
      if (off.has(k)) { b.setAttribute('aria-disabled', 'true'); b.title = off.get(k)!; }
    });
  })(); });

  const doSave = async () => {
    if (!loaded || loaded.page !== page) return;
    const v = loaded;
    const r = await save({ view_id: v.view_id, version: v.version, kind: 'page', page, name: v.name, description: v.description ?? undefined,
      folder: v.folder ?? undefined, shared: v.shared, is_default: v.is_default, keep_range: !!v.state?.range,
      state: { params: params(), layouts: layoutsOf() } });
    if (r.ok) { const f = await fetchView(v.view_id); if (f.row) { loaded = f.row; setLayer(f.row.state?.layouts ?? []); } label(); drawNotes(); note(`Saved '${v.name}'.`); }
    else if (r.code === 409 && stale(r.words)) { drawNotes(); conflict(r.words, v.view_id); }
    else { drawNotes(); note(r.words); }
  };

  const dialog = (title: string, body: HTMLElement[], act: string, run: (d: HTMLDialogElement, err: HTMLElement) => Promise<boolean>) => {
    const err = el('p', { class: 'error', role: 'alert' });
    const go = el('button', { type: 'button' }, act), cancel = el('button', { type: 'button' }, 'Cancel');
    const d = el('dialog', { class: 'act-dialog', 'aria-label': title }, el('h3', {}, title), ...body, err, el('div', { class: 'dialog-buttons' }, go, cancel)) as HTMLDialogElement;
    cancel.addEventListener('click', () => d.close());
    d.addEventListener('close', () => d.remove());
    // the act button is off while its request is out: a double click sends one write (review L3)
    go.addEventListener('click', () => {
      if (go.disabled) return;
      go.disabled = true;
      void run(d, err).then(done => { if (done) d.close(); }).finally(() => { go.disabled = false; });
    });
    document.body.append(d);
    d.showModal();
    (d.querySelector('input') as HTMLInputElement | null)?.focus();
  };
  const field = (lab: string, input: HTMLElement) => el('label', { class: 'dialog-field' }, lab + ' ', input);

  const saveAsDialog = (l: ListReply | null) => {
    const name = el('input', { type: 'text', name: 'name', maxlength: '100', required: '' }) as HTMLInputElement;
    const def = el('input', { type: 'checkbox', name: 'default' }) as HTMLInputElement;
    const me = el('input', { type: 'radio', name: 'visibility', value: 'me' }) as HTMLInputElement;
    const all = el('input', { type: 'radio', name: 'visibility', value: 'everyone' }) as HTMLInputElement;
    me.checked = true;
    if (l?.shared_off) { all.disabled = true; all.title = l.shared_off; }
    const folder = el('input', { type: 'text', name: 'folder', maxlength: '100' }) as HTMLInputElement;
    const range = el('input', { type: 'checkbox', name: 'range' }) as HTMLInputElement;
    const vis = el('fieldset', {}, el('legend', {}, 'Visible to'), el('label', {}, me, ' Only me'), ' ',
      el('label', {}, all, ' Everyone', ...(l?.shared_off ? [el('span', { class: 'off-reason' }, ` (${l.shared_off})`)] : [])));
    dialog('Save view', [field('Name', name), el('label', {}, def, ' Load by default on this page'), vis, field('Folder', folder),
      el('label', {}, range, ' Save the time range')], 'Save', async (_d, err) => {
      if (!name.value.trim()) { err.textContent = 'A view needs a name.'; return false; }
      const r = await save({ kind: 'page', page, name: name.value.trim(), folder: folder.value.trim() || undefined, shared: all.checked,
        is_default: def.checked, keep_range: range.checked, state: { params: params(), layouts: layoutsOf() } });
      if (!r.ok || !r.id) { err.textContent = r.words; return false; }
      const f = await fetchView(r.id);
      if (f.row) { loaded = f.row; setLayer(f.row.state?.layouts ?? []); }
      // the saved keys go into the address with view=, so a link copied now draws what was saved (review H1)
      const saved: Record<string, string> = {};
      for (const [k, v] of Object.entries(params())) if (pageKeysOf(page).includes(k) && v !== '') saved[k] = v;
      noteAddress({ ...saved, view: String(r.id) });
      label(); drawNotes();
      return true;
    });
  };
  const renameDialog = () => {
    if (!loaded || loaded.page !== page) return;
    const v = loaded;
    const name = el('input', { type: 'text', name: 'name', maxlength: '100', value: v.name }) as HTMLInputElement;
    dialog('Rename view', [field('Name', name)], 'Rename', async (_d, err) => {
      const r = await save({ view_id: v.view_id, version: v.version, kind: 'page', page, name: name.value.trim(), description: v.description ?? undefined,
        folder: v.folder ?? undefined, shared: v.shared, is_default: v.is_default, keep_range: !!v.state?.range,
        // the server keeps a range only from the params' w / from / to (q_views.go viewPayload): the stored one goes back
        // there, or a rename drops it (review H2)
        state: { params: { ...(v.state?.params ?? {}), ...(v.state?.range ?? {}) }, layouts: v.state?.layouts ?? [] } });
      if (r.code === 409) { err.textContent = r.words; if (stale(r.words)) conflict(r.words, v.view_id); return false; }
      if (!r.ok) { err.textContent = r.words; return false; }
      const f = await fetchView(v.view_id); if (f.row) loaded = f.row;
      label();
      return true;
    });
  };
  const deleteDialog = () => {
    if (!loaded || loaded.page !== page) return;
    const v = loaded;
    dialog('Delete view', [el('p', {}, `Delete the ${v.shared ? 'shared' : 'personal'} view '${v.name}'? This cannot be undone.`)], 'Delete', async (_d, err) => {
      const r = await call('POST', 'views/delete', { view_id: v.view_id, version: v.version }).catch(e => ({ code: 0, body: { error: String(e) } as Record<string, unknown> }));
      lists.delete(page);
      if (r.code !== 200) { err.textContent = String(r.body?.error ?? `HTTP ${r.code}`); return false; }
      drop(); noteAddress({ view: 'none' }); label(); drawNotes(); note(`Deleted '${v.name}'.`);
      return true;
    });
  };
  return { button, notes };
}
