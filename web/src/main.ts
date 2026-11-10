// The shell: a header (brand, where you are, the time range, refresh, theme, the user), the instance
// tree on the left, a tab strip (root tabs for the fleet or a tag, instance tabs for one instance)
// and the page under it.
import { get, LoginRequired, post, Session } from './api';
import { destroyCharts } from './chart';
import { fleet, forget } from './fleet';
import { checks, config, Ctx, disks, dms, errorBox, extensions, findings, fleetSummary, instances, instanceSummary, jobs, jobsRoot, logs, replication, roles, slows, statements, counters, activity, storage, backups, corruption, versions } from './pages';
import { tablesView } from './borrowed';
import { hostView } from './host';
import { storageView } from './storage';
import { backupsView } from './backups';
import { corruptionView } from './corruption';
import { vacuumView } from './vacuum';
import { extensionsView } from './extensions';
import { versionsView } from './versions';
import { ioView } from './io';
import { actionsLogView } from './actions';
import { jobsReportView } from './jobsreport';
import { rolesView } from './roles';
import { plansView } from './plan';
import { slowView } from './slow';
import { rangePicker } from './rangepicker';
import { href, instanceTabs, isLive, parse, rangeLabel, rememberInstance, rootTabs, window_ } from './router';
import { mountTree, setTreeHidden, tagChips, treeHiddenSaved, updateTree } from './tree';
import { el } from './ui';

type Render = (c: Ctx) => Promise<HTMLElement>;
const rootPages: Record<string, Render> = { summary: fleetSummary, checks, findings, instances, dms, disks, storage, backups, corruption, extensions, versions, roles, slowqueries: slows, jobs: jobsRoot };
const instancePages: Record<string, Render> = {
  summary: instanceSummary, activity, statements, counters, replication, jobs, logs, dms, config,
  tables: c => tablesView(c.instance!), vacuum: vacuumView, findings, host: hostView, storage: storageView, backups: backupsView, corruption: c => corruptionView(c.instance!),
  extensions: c => extensionsView(c.instance!), versions: c => versionsView(c.instance!),
  io: c => ioView(c.instance!, window_(c), rangeLabel(c)),
  actions: actionsLogView,
  jobsreport: jobsReportView,
  roles: c => rolesView(c.instance!),
  slowqueries: slowView,
  plans: plansView,
};
// pages that show the state now refresh every 30 s while the tab is visible and the range follows now
const liveRoot = new Set(['summary', 'checks', 'dms', 'jobs']);
const liveInstance = new Set(['summary', 'activity', 'dms', 'host', 'vacuum', 'io']);

let timer: number | undefined;
let generation = 0;   // a render that finishes after a newer one started is dropped
let session: Session = { login: false };
let loginShown = false;   // the sign-in form is up: a tab switch or a hash change must not rebuild it

const $ = (id: string) => document.getElementById(id)!;

// ---- theme: auto (the system's), light or dark, remembered per browser
function lsGet(k: string): string | null { try { return localStorage.getItem(k); } catch { return null; } }
function lsSet(k: string, v: string) { try { localStorage.setItem(k, v); } catch { /* private window */ } }
const themes = ['auto', 'light', 'dark'];
function applyTheme(t: string) {
  if (t === 'auto') document.documentElement.removeAttribute('data-theme');
  else document.documentElement.setAttribute('data-theme', t);
}
applyTheme(lsGet('pgvigil.theme') ?? 'auto');
function themeButton(): HTMLElement {
  const cur = lsGet('pgvigil.theme') ?? 'auto';
  const b = el('button', { type: 'button', title: 'Theme: auto follows the system' }, 'Theme: ' + cur);
  b.addEventListener('click', () => {
    const next = themes[(themes.indexOf(lsGet('pgvigil.theme') ?? 'auto') + 1) % themes.length];
    lsSet('pgvigil.theme', next); applyTheme(next);
    void render();   // charts read the theme's colours when drawn
  });
  return b;
}

// showLogin replaces the page with the sign-in form; a successful sign-in renders the page asked for.
function showLogin(message = '') {
  window.clearTimeout(timer);
  timer = undefined;
  ++generation;
  loginShown = true;
  document.body.classList.add('signin');
  $('tabs').replaceChildren();
  $('bar').replaceChildren();
  $('crumb').replaceChildren();
  const user = el('input', { name: 'username', autocomplete: 'username', required: '', autofocus: '', maxlength: '64' });
  const pass = el('input', { name: 'password', type: 'password', autocomplete: 'current-password', required: '' });
  const err = el('p', { class: 'error' }, message);
  if (!message) err.hidden = true;
  const btn = el('button', { type: 'submit' }, 'Sign in');
  const form = el('form', { class: 'login' }, el('h2', {}, 'Sign in to pgvigil'),
    el('label', {}, 'User name', user), el('label', {}, 'Password', pass), btn, err);
  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    btn.disabled = true; err.hidden = true;
    try {
      session = await post<Session>('login', { username: user.value.trim(), password: pass.value });
      pass.value = '';
      loginShown = false;
      document.body.classList.remove('signin');
      forget();
      void render();
    } catch (e) {
      err.textContent = e instanceof Error ? e.message : String(e);
      err.hidden = false; btn.disabled = false; pass.value = ''; pass.focus();
    }
  });
  $('main').replaceChildren(form);
  user.focus();
}

async function signOut() {
  try { await post('logout'); } catch { /* the session is gone either way */ }
  session = { login: true };
  forget();
  showLogin('Signed out.');
}

async function render(force = false) {
  window.clearTimeout(timer);
  timer = undefined;
  const gen = ++generation;
  const ctx = parse();
  rememberInstance(ctx.instance);
  const tabs = ctx.instance ? instanceTabs : rootTabs;
  const pages = ctx.instance ? instancePages : rootPages;

  $('tabs').replaceChildren(...Object.entries(tabs).map(([k, label]) =>
    el('a', { href: href(ctx, { tab: k }), class: k === ctx.tab ? 'on' : '' }, label)));

  const bar = $('bar');
  const refresh = el('button', { type: 'button', title: 'Read everything again' }, 'Refresh');
  refresh.addEventListener('click', () => { void render(true); });
  bar.replaceChildren(rangePicker(ctx), refresh,
    el('span', { class: 'meta', id: 'stamp' }, 'loaded ' + new Date().toLocaleTimeString(undefined, { hour12: false })),
    themeButton());
  if (session.login && session.user) {
    const out = el('button', { type: 'button', class: 'link' }, 'Sign out');
    out.addEventListener('click', () => { void signOut(); });
    bar.append(el('span', { class: 'meta' }, session.user), out);
  }

  // the tree and the breadcrumb come from the fleet read; a failure there still shows the page
  const crumb = $('crumb');
  try {
    const f = await fleet(force);
    if (gen !== generation) return;
    updateTree(f, ctx);
    const inst = ctx.instance ? f.instances.find(r => Number(r.instance_id) === ctx.instance) : undefined;
    crumb.replaceChildren(
      el('a', { href: href(ctx, { tab: ctx.instance ? 'summary' : ctx.tab, instance: undefined, tag: undefined }) }, 'All instances'),
      ...(ctx.tag && !ctx.instance ? [' / ', el('span', {}, 'tag ' + ctx.tag)] : []),
      ...(ctx.instance ? [' / ', el('b', {}, inst ? String(inst.name) : 'instance ' + ctx.instance)] : []),
      ...(inst ? [tagChips(ctx, inst)] : []));
  } catch (e) {
    if (e instanceof LoginRequired) { showLogin(); return; }
    crumb.replaceChildren(errorBox(e));
  }

  let view: HTMLElement;
  try {
    view = await pages[ctx.tab](ctx);
  } catch (e) {
    if (e instanceof LoginRequired) { showLogin(); return; }
    view = errorBox(e);
  }
  if (gen !== generation) return;
  destroyCharts();
  $('main').replaceChildren(view);
  const live = ctx.instance ? liveInstance : liveRoot;
  if (live.has(ctx.tab) && isLive(ctx) && !ctx.at) {
    timer = window.setTimeout(() => { if (!document.hidden) void render(true); else timer = undefined; }, 30000);
  }
}

mountTree($('tree'));
setTreeHidden(treeHiddenSaved());
$('show-tree').addEventListener('click', () => setTreeHidden(false));
window.addEventListener('hashchange', () => { if (!loginShown) void render(); });
document.addEventListener('visibilitychange', () => { if (!document.hidden && timer === undefined && !loginShown) void render(true); });
// the first load asks who holds this session; a 401 shows the sign-in form before any page
(async () => {
  try { session = await get<Session>('session'); } catch (e) { if (e instanceof LoginRequired) { showLogin(); return; } }
  void render();
})();
