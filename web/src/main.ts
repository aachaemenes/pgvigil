import { get, rowsOf } from './api';
import { activity, counters, Ctx, dms, errorBox, instances, overview, statements } from './pages';
import { el } from './ui';
import { destroyCharts } from './chart';

const pages: Record<string, { label: string; render: (c: Ctx) => Promise<HTMLElement>; perInstance: boolean; windowed: boolean }> = {
  overview: { label: 'Overview', render: overview, perInstance: false, windowed: false },
  instances: { label: 'Instances', render: instances, perInstance: false, windowed: false },
  activity: { label: 'Running queries', render: activity, perInstance: true, windowed: false },
  statements: { label: 'Statements', render: statements, perInstance: true, windowed: true },
  counters: { label: 'Counters', render: counters, perInstance: true, windowed: true },
  dms: { label: 'DMS', render: dms, perInstance: false, windowed: false },
};

let timer: number | undefined;
let generation = 0;   // a render that finishes after a newer one started is dropped

function parse(): { page: string; ctx: Ctx } {
  const h = location.hash.replace(/^#\/?/, '');
  const [p, qs] = h.split('?');
  const q = new URLSearchParams(qs ?? '');
  const saved = Number(localStorageGet('pgvigil.instance')) || undefined;
  const i = Number(q.get('i')) || saved;
  return {
    page: pages[p] ? p : 'overview',
    ctx: { instance: i, window: q.get('w') ?? '1h', kind: q.get('kind') ?? 'db', at: q.get('at') ?? undefined, task: q.get('task') ?? undefined },
  };
}

function localStorageGet(k: string): string | null { try { return localStorage.getItem(k); } catch { return null; } }
function localStorageSet(k: string, v: string) { try { localStorage.setItem(k, v); } catch { /* private window */ } }

function href(page: string, ctx: Ctx, over: Partial<Ctx> = {}): string {
  const c = { ...ctx, ...over };
  const q = new URLSearchParams();
  if (c.instance) q.set('i', String(c.instance));
  if (page === 'counters') q.set('kind', c.kind);
  if (pages[page]?.windowed) q.set('w', c.window);
  return `#/${page}?${q}`;
}

async function render() {
  window.clearTimeout(timer);
  timer = undefined;
  const gen = ++generation;
  const { page, ctx } = parse();
  if (ctx.instance) localStorageSet('pgvigil.instance', String(ctx.instance));
  const nav = document.getElementById('nav')!;
  nav.replaceChildren(...Object.entries(pages).map(([k, v]) =>
    el('a', { href: href(k, ctx), class: k === page ? 'on' : '' }, v.label)));

  const bar = document.getElementById('bar')!;
  bar.replaceChildren();
  try {
    const inst = rowsOf(await get('instances'));
    if (gen !== generation) return;
    if (pages[page].perInstance) {
      const sel = el('select', { 'aria-label': 'instance' }, el('option', { value: '' }, 'instance...'),
        ...inst.map(r => { const o = el('option', { value: String(r.instance_id) }, String(r.name)); if (Number(r.instance_id) === ctx.instance) o.selected = true; return o; }));
      sel.addEventListener('change', () => { location.hash = href(page, ctx, { instance: Number(sel.value) || undefined }); });
      bar.append(sel);
    }
    if (pages[page].windowed) {
      const ws = el('select', { 'aria-label': 'window' }, ...['15m', '1h', '6h', '24h', '7d'].map(w => {
        const o = el('option', { value: w }, 'last ' + w); if (w === ctx.window) o.selected = true; return o; }));
      ws.addEventListener('change', () => { location.hash = href(page, ctx, { window: ws.value }); });
      bar.append(ws);
    }
  } catch (e) { bar.append(errorBox(e)); }
  const refresh = el('button', { type: 'button' }, 'Refresh');
  refresh.addEventListener('click', () => { void render(); });
  bar.append(refresh, el('span', { class: 'meta', id: 'stamp' }, 'loaded ' + new Date().toLocaleTimeString(undefined, { hour12: false })));

  const main = document.getElementById('main')!;
  let view: HTMLElement;
  try {
    view = await pages[page].render(ctx);
  } catch (e) {
    view = errorBox(e);
  }
  if (gen !== generation) return;
  destroyCharts();
  main.replaceChildren(view);
  // live pages refresh every 30 s while the tab is visible
  if ((page === 'overview' || page === 'activity' || page === 'dms') && !ctx.at) {
    timer = window.setTimeout(() => { if (!document.hidden) void render(); else timer = undefined; }, 30000);
  }
}

window.addEventListener('hashchange', () => { void render(); });
document.addEventListener('visibilitychange', () => { if (!document.hidden && timer === undefined) void render(); });
void render();
