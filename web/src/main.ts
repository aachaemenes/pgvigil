// The shell: a header (brand, where you are, the time range, refresh, theme, the user), the instance
// tree on the left, a tab strip (root tabs for the fleet or a tag, instance tabs for one instance)
// and the page under it.
import { get, LoginRequired, post, Row, Session } from './api';
import { destroyCharts } from './chart';
import { fleet, forget, tagsOf } from './fleet';
import { checks, config, Ctx, disks, dms, errorBox, extensions, findings, fleetSummary, instances, instanceSummary, jobsRoot, logs, replication, roles, slows, statements, counters, storage, backups, corruption, versions, indexes, growth, customRoot } from './pages';
import { tablesView } from './borrowed';
import { hostView } from './host';
import { capacitySection, loadView } from './pi';
import { storageView } from './storage';
import { backupsView } from './backups';
import { corruptionView } from './corruption';
import { dbadashView } from './dbadash';
import { alertsView } from './alerts';
import { vacuumView } from './vacuum';
import { extensionsView } from './extensions';
import { versionsView } from './versions';
import { ioView } from './io';
import { actionsLogView } from './actions';
import { jobsReportView } from './jobsreport';
import { rolesView } from './roles';
import { plansView } from './plan';
import { slowGroupsPanel, slowView } from './slow';
import { jobsTimelineView } from './jobs_timeline';
import { waitsView } from './waits';
import { compareView } from './compare';
import { memory } from './memory';
import { pooler, poolerKnown } from './pooler';
import { customView } from './custom';
import { indexesView } from './indexes';
import { schemaView } from './schema';
import { dbinfoView } from './dbinfo';
import { dbPage, indexPage, jobPage, tablePage } from './drill';
import { rangePicker } from './rangepicker';
import { groupOf, groupsFor, href, isLive, isMssql, parse, rangeLabel, rememberInstance, rootGroups, rootTabs, tabsFor, window_, drillHome } from './router';
import { mssqlRunningView } from './mssql_running';
import { runningView } from './running';
import { runningFleet } from './running_fleet';
import { perfSummaryView } from './perfsummary';
import { performanceView } from './performance';
import { mssqlSummary } from './mssql_summary';
import { mssqlWaitsView } from './mssql_waits';
import { mssqlBlocked, mssqlSlow, mssqlAgEvents } from './mssql_xe';
import { mssqlDeadlocksView } from './mssql_deadlocks';
import { hasAvailability, mssqlAvailability } from './mssql_hadr';
import { mssqlBackups } from './mssql_backups';
import { mssqlJobs } from './mssql_jobs';
import { jobsPgView } from './jobs_pg';
import { mssqlFilesView, mssqlStorageView } from './mssql_storage';
import { mssqlRowVersionsView } from './mssql_rowversions';
import { mssqlCpuView, mssqlFileIOView, mssqlMemoryView, mssqlTempdbView } from './mssql_perf';
import { mssqlConfigView } from './mssql_config';
import { mssqlPropertiesView } from './mssql_properties';
import { mssqlProcsView } from './mssql_procs';
import { mssqlIndexLocksView } from './mssql_indexlocks';
import { mssqlActionsLogView } from './mssql_actions';
import { mountTree, setTreeHidden, treeHiddenSaved, updateTree } from './tree';
import { dropMenu, el } from './ui';
import { exportButtons } from './export';
import { connectionsView } from './connections';
import { dbChangesView } from './dbchanges';

type Render = (c: Ctx) => Promise<HTMLElement>;
// a SQL Server instance's pages (router.ts mssqlInstanceTabs); the Availability page ends with AlwaysOn_health's events
const mssqlPages: Record<string, Render> = {
  summary: mssqlSummary, findings: c => findings(c), performance: performanceView,
  mssql_running: mssqlRunningView, mssql_waits: mssqlWaitsView, mssql_deadlocks: mssqlDeadlocksView, mssql_blocked: mssqlBlocked, mssql_slow: async c => { const s = await mssqlSlow(c); s.append(slowGroupsPanel(c)); return s; },
  jobstimeline: jobsTimelineView,
  availability: async c => { const s = await mssqlAvailability(c); s.append(await mssqlAgEvents(c)); return s; },
  mssqlbackups: mssqlBackups, mssqljobs: mssqlJobs, mssqlstorage: mssqlStorageView, mssqlfiles: mssqlFilesView,
  rowversions: mssqlRowVersionsView, mssqlconfig: mssqlConfigView, mssqlactions: mssqlActionsLogView,
  mssqlcpu: mssqlCpuView, mssqlmemory: mssqlMemoryView, mssqlfileio: mssqlFileIOView, mssqltempdb: mssqlTempdbView,
  mssqlprocs: mssqlProcsView, mssqlindexlocks: mssqlIndexLocksView, mssqlproperties: mssqlPropertiesView,
};
// a fleet page under a tag folder keeps that folder's instances (as the fleet Slow queries page does): the Jobs timeline, TempDB
const tagKeep = async (c: Ctx): Promise<((r: Row) => boolean) | undefined> => {
  if (!c.tag) return undefined;
  const ids = new Set((await fleet()).instances
    .filter(r => c.tag === 'untagged' ? tagsOf(r).length === 0 : tagsOf(r).includes(c.tag!)).map(r => Number(r.instance_id)));
  return r => ids.has(Number(r.instance_id));
};
const jobsTimelineFleet: Render = async c => jobsTimelineView(c, await tagKeep(c));
const tempdbFleet: Render = async c => mssqlTempdbView(c, await tagKeep(c));
const rootPages: Record<string, Render> = { summary: fleetSummary, checks, findings, instances, dms, disks, storage, backups, corruption, extensions, versions, roles, slowqueries: slows, jobs: jobsRoot, indexes, growth, dbadash: dbadashView, custom: customRoot, alerts: alertsView, perfsummary: perfSummaryView, running: runningFleet, jobstimeline: jobsTimelineFleet, mssqltempdb: tempdbFleet, dbchanges: async c => dbChangesView(c, await tagKeep(c)) };
const instancePages: Record<string, Render> = {
  summary: instanceSummary, performance: performanceView, activity: runningView, statements, counters, replication, jobs: jobsPgView, logs, dms, config,
  tables: c => tablesView(c.instance!, c), vacuum: vacuumView, findings, load: loadView,
  host: async c => { const s = await hostView(c); s.append(await capacitySection(c)); return s; },   // the Capacity section (Serverless v2) under the host's own
  storage: storageView, backups: backupsView, corruption: c => corruptionView(c.instance!),
  extensions: c => extensionsView(c.instance!), versions: c => versionsView(c.instance!),
  io: c => ioView(c.instance!, window_(c), rangeLabel(c)),
  actions: actionsLogView,
  jobsreport: jobsReportView,
  roles: c => rolesView(c.instance!),
  slowqueries: slowView,
  waits: waitsView,
  indexes: c => indexesView(c.instance!, c),
  schema: c => schemaView(c.instance!, c),
  plans: plansView,
  dbinfo: dbinfoView, db: dbPage, table: tablePage, job: jobPage, index: indexPage,
  compare: compareView,
  memory, pooler, custom: customView, jobstimeline: jobsTimelineView,
  connections: connectionsView, dbchanges: c => dbChangesView(c),
};
// pages that show the state now refresh every 30 s while the tab is visible and the range follows now
const liveRoot = new Set(['summary', 'checks', 'dms', 'jobs', 'running']);
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
// under 'auto' a change of the system's light / dark setting redraws the page, so the charts take the new colours
window.matchMedia?.('(prefers-color-scheme: dark)').addEventListener?.('change', () => { if ((lsGet('pgvigil.theme') ?? 'auto') === 'auto' && !loginShown) void render(); });
// ---- auto refresh: how often a live page reads again (Darling's interval select; Off pauses it), remembered per browser
const refreshChoices: [string, string][] = [['30', '30 s'], ['60', '1 min'], ['300', '5 min'], ['900', '15 min'], ['0', 'Off (paused)']];
function refreshSecs(): number { const v = Number(lsGet('pgvigil.refresh') ?? '30'); return refreshChoices.some(([k]) => Number(k) === v) ? v : 30; }
function refreshSelect(live: boolean): HTMLElement {
  // a page that never reads again by itself (history, a snapshot, a page without live state) shows the choice disabled
  const why = live ? 'Auto refresh of a live page' : 'This page does not refresh by itself (a past range, a snapshot, or not a live page)';
  const sel = el('select', { 'aria-label': why, title: why, ...(live ? {} : { disabled: '' }) }) as HTMLSelectElement;
  for (const [k, label] of refreshChoices) sel.append(el('option', { value: k, ...(Number(k) === refreshSecs() ? { selected: '' } : {}) }, 'Auto refresh: ' + label));
  sel.addEventListener('change', () => { lsSet('pgvigil.refresh', sel.value); void render(true); });
  return sel;
}
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

let shownPage = '';   // the page main shows or is loading: the whole hash (tab, instance, tag, range, filters)
async function render(force = false) {
  window.clearTimeout(timer);
  timer = undefined;
  const gen = ++generation;
  dropMenu();   // a grid's copy menu never outlives the page it was opened on (a 30 s refresh included)
  const ctx = parse();
  rememberInstance(ctx.instance);
  // another page or another range / filter of it: say so at once instead of leaving the old grids on screen while the
  // new ones read (an export in that gap took the old page); the same hash's refresh keeps its content (no flicker every
  // 30 s). The status node goes in empty and gets its text a frame later, so a screen reader announces it.
  const pageKey = location.hash;
  if (pageKey !== shownPage) {
    const note = el('p', { class: 'empty', role: 'status' });
    $('main').replaceChildren(note);
    requestAnimationFrame(() => { note.textContent = 'Loading...'; });
    shownPage = pageKey;
  }
  // the instance's engine chooses its tab set and pages (the fleet read is cached; unknown = PostgreSQL)
  const engine = ctx.instance ? (await fleet().catch(() => null))?.instances.find(r => Number(r.instance_id) === ctx.instance)?.engine : undefined;
  let tabs = ctx.instance ? tabsFor(engine) : rootTabs;
  if (ctx.instance && isMssql(engine)) {
    // the Availability tab only where one of its collections has stored a read
    if (!(await hasAvailability(ctx.instance).catch(() => false))) tabs = Object.fromEntries(Object.entries(tabs).filter(([k]) => k !== 'availability'));
  } else if (ctx.instance) {
    // the Pooler tab only where the instance has a pooler read (a pgbouncer: DSN); a failed check hides it
    if (!(await poolerKnown(ctx.instance))) tabs = Object.fromEntries(Object.entries(tabs).filter(([k]) => k !== 'pooler'));
  }
  const pages = ctx.instance ? (isMssql(engine) ? mssqlPages : instancePages) : rootPages;
  // a page of the other engine (an old link, a tree click from another instance) opens this instance's Summary
  if (ctx.instance && !pages[ctx.tab]) {
    ctx.tab = 'summary';
    history.replaceState(null, '', href(ctx, { tab: 'summary' }));   // the address says the page shown, so a reload does not repeat the fallback
  }

  // the strip: the tabs of the page's group only (the scope's main tabs, or a tree folder's), the folder named first
  const group = groupOf(ctx.instance ? groupsFor(engine) : rootGroups, ctx.tab);
  const strip = group.tabs.filter(k => tabs[k]);
  // a folder's strip starts with the way back to the scope's main tabs; the strip is named for a screen reader
  $('tabs').setAttribute('aria-label', group.name ? group.name + ' pages' : 'Main pages');
  $('tabs').replaceChildren(
    ...(group.name ? [el('a', { href: href(ctx, { tab: 'summary' }), class: 'tab-back' }, 'Summary'), el('span', { class: 'tab-group', 'aria-hidden': 'true' }, '/ ' + group.name + ':')] : []),
    ...strip.map(k => el('a', { href: href(ctx, { tab: k }), class: k === ctx.tab || k === drillHome[ctx.tab] ? 'on' : '', ...(k === ctx.tab || k === drillHome[ctx.tab] ? { 'aria-current': 'page' } : {}) }, tabs[k])));   // a drill page marks its home tab
  // every page of the scope, for a check that walks them all (scripts/a11y-check.mjs)
  $('tabs').dataset.all = JSON.stringify(Object.keys(tabs).map(k => href(ctx, { tab: k })));

  const bar = $('bar');
  const refresh = el('button', { type: 'button', title: 'Read everything again' }, 'Refresh');
  refresh.addEventListener('click', () => { void render(true); });
  const livePage = (ctx.instance ? liveInstance : liveRoot).has(ctx.tab) && isLive(ctx) && !ctx.at;
  bar.replaceChildren(rangePicker(ctx), refresh, refreshSelect(livePage), exportButtons(ctx),
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
      ...(ctx.instance ? [' / ', el('b', {}, inst ? String(inst.name) : 'instance ' + ctx.instance)] : []));
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
  if (live.has(ctx.tab) && isLive(ctx) && !ctx.at && refreshSecs() > 0) {
    timer = window.setTimeout(() => { if (!document.hidden) void render(true); else timer = undefined; }, refreshSecs() * 1000);
  }
}

mountTree($('tree'));
setTreeHidden(treeHiddenSaved());
$('show-tree').addEventListener('click', () => setTreeHidden(false));
window.addEventListener('hashchange', () => { if (!loginShown) void render(); });
// the tab row sticks under the header: the header's height and the tab row's (each wraps on a narrow window) are kept
// in --head-h and --tabs-h, so the row sits under the header and a focused control is scrolled clear of both
const headEl = document.querySelector('header'), tabsEl = document.getElementById('tabs');
const setBand = () => {
  if (headEl) document.documentElement.style.setProperty('--head-h', `${headEl.getBoundingClientRect().height}px`);
  if (tabsEl) document.documentElement.style.setProperty('--tabs-h', `${tabsEl.getBoundingClientRect().height}px`);
};
setBand();
if (typeof ResizeObserver !== 'undefined') { const ro = new ResizeObserver(setBand); if (headEl) ro.observe(headEl); if (tabsEl) ro.observe(tabsEl); }
document.addEventListener('visibilitychange', () => { if (!document.hidden && timer === undefined && !loginShown && refreshSecs() > 0) void render(true); });
// the first load asks who holds this session; a 401 shows the sign-in form before any page
(async () => {
  try { session = await get<Session>('session'); } catch (e) { if (e instanceof LoginRequired) { showLogin(); return; } }
  void render();
})();
