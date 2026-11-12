// The shell: a header (brand, where you are, the time range, refresh, theme, the user), the instance
// tree on the left, a tab strip (root tabs for the fleet or a tag, instance tabs for one instance)
// and the page under it.
import { get, LoginRequired, post, Row, rowsOf, Session, Table } from './api';
import { destroyCharts } from './chart';
import { fleet, forget, tagsOf } from './fleet';
import { checks, config, Ctx, disks, dms, errorBox, extensions, findings, fleetSummary, instances, instanceSummary, jobsRoot, logs, replication, roles, slows, statements, storage, backups, corruption, versions, indexes, growth, customRoot } from './pages';
import { tablesView } from './borrowed';
import { hostView } from './host';
import { capacitySection, loadView } from './pi';
import { storageView } from './storage';
import { backupsView } from './backups';
import { corruptionView } from './corruption';
import { pgBackupsView, pgBaseBackupsFleetSection, pgReplicationFleetView, pgStateView, pgThresholdsView } from './pg_backups';
import { dbadashView, importedPage, isImported } from './dbadash';
import { mssqlWaitingView, pgWaitingView } from './darling_waiting';
import { adminView, alertsView } from './alerts';
import { alertRulesView } from './alert_rules';
import { alertPageView } from './alert_page';
import { metricsView } from './metrics';
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
import { pgauditView } from './pgaudit';
import { customView } from './custom';
import { indexesView } from './indexes';
import { schemaView } from './schema';
import { dbinfoView } from './dbinfo';
import { dbPage, indexPage, jobPage, tablePage } from './drill';
import { closeRange, rangePicker } from './rangepicker';
import { fmtClock } from './tz';
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
import { pgDeadlocksView } from './pg_deadlocks';
import { mssqlFilesView, mssqlStorageView } from './mssql_storage';
import { mssqlRowVersionsView } from './mssql_rowversions';
import { mssqlCpuView, mssqlFileIOView, mssqlMemoryView, mssqlTempdbView } from './mssql_perf';
import { mssqlQueryStoreView } from './mssql_querystore';
import { mssqlConfigView } from './mssql_config';
import { mssqlPropertiesView } from './mssql_properties';
import { mssqlAuditView } from './mssql_audit';
import { mssqlChecksFleetView, mssqlChecksView } from './mssql_checks';
import { pgDbOptionsFleetView, pgDbOptionsView } from './pg_dboptions';
import { mssqlErrorLogView, mssqlDefaultTraceView, mssqlSysHealthView } from './mssql_errorlog';
import { mssqlProcsView } from './mssql_procs';
import { mssqlPlanCacheView } from './mssql_plancache';
import { mssqlIndexesView } from './mssql_indexes';
import { mssqlIndexLocksView } from './mssql_indexlocks';
import { mssqlActionsLogView } from './mssql_actions';
import { mountTree, setTreeHidden, treeHiddenSaved, updateTree } from './tree';
import { tabMark, watchHiddenTab } from './tabmark';
import { installTreeMenu } from './treemenu';
import { installFileDrop, toolsButton } from './filedrop';
import { retentionView } from './retention';
import { dropMenu, el, fmtBytes } from './ui';
import { exportButtons } from './export';
import { mailButton, mailRenderBoot, reportMailView } from './reportmail';
import { connectionsView } from './connections';
import { dbChangesView } from './dbchanges';
import { diffView } from './diff';
import { tableSizeView } from './tablesize';
import { dbFilesView, dbSpaceView, drivePerfView, drivesView, pgTempView } from './drives';
import { collectionDatesView } from './collectiondates';
import { aboutLink, aboutView } from './about';
import { adminInstancesView } from './admin_instances';
import { reportPages } from './reports';
import { customReportsView } from './customreports';
import { communityView } from './community';
import { instanceFrame } from './instheader';

type Render = (c: Ctx) => Promise<HTMLElement>;
// a SQL Server instance's pages (router.ts mssqlInstanceTabs); the Availability page ends with AlwaysOn_health's events
const mssqlPages: Record<string, Render> = {
  summary: mssqlSummary, findings: c => findings(c), performance: performanceView,
  mssql_running: mssqlRunningView, mssql_waits: mssqlWaitsView, mssql_waiting: mssqlWaitingView, mssql_deadlocks: mssqlDeadlocksView, mssql_blocked: mssqlBlocked, mssql_slow: async c => { const s = await mssqlSlow(c); s.append(slowGroupsPanel(c)); return s; },
  jobstimeline: jobsTimelineView,
  availability: async c => { const s = await mssqlAvailability(c); s.append(await mssqlAgEvents(c)); return s; },
  mssqlbackups: mssqlBackups, mssqljobs: mssqlJobs, mssqlstorage: mssqlStorageView, mssqlfiles: mssqlFilesView,
  drives: drivesView, dbspace: dbSpaceView, dbfiles: dbFilesView, driveperf: drivePerfView, collectiondates: collectionDatesView,
  rowversions: mssqlRowVersionsView, mssqlconfig: mssqlConfigView, mssqlactions: mssqlActionsLogView,
  mssqlcpu: mssqlCpuView, mssqlmemory: mssqlMemoryView, mssqlfileio: mssqlFileIOView, mssqltempdb: mssqlTempdbView,
  mssqlqs: mssqlQueryStoreView,
  counters: metricsView,
  mssqlprocs: mssqlProcsView, mssqlplancache: mssqlPlanCacheView, mssqlindexes: mssqlIndexesView, mssqlindexlocks: mssqlIndexLocksView, mssqlproperties: mssqlPropertiesView, mssqlaudit: mssqlAuditView, mssqlchecks: mssqlChecksView,
  mssqlerrorlog: mssqlErrorLogView, mssqltrace: mssqlDefaultTraceView, mssqlhealth: mssqlSysHealthView,
  customreports: customReportsView, community: communityView,
  ...reportPages,
};
// the SQL Server tabs whose own read says nothing when their collection was skipped on the instance (a platform rule
// such as Azure SQL Database's, a missing right): the page opens with the collector's own reason (GET /api/mssql/state)
const mssqlTabRuns: Record<string, string[]> = {
  mssqlstorage: ['mssql_storage'], mssqlfiles: ['mssql_storage'], rowversions: ['mssql_versionstore'], jobstimeline: ['mssql_jobs'],
  mssqlcpu: ['mssql_cpu'], mssqlmemory: ['mssql_memory'], mssqlfileio: ['mssql_fileio'], mssqltempdb: ['mssql_tempdb'], mssqlqs: ['mssql_querystore'],
  drives: ['mssql_storage'], dbspace: ['mssql_storage'], dbfiles: ['mssql_storage'], driveperf: ['mssql_fileio'],
  rp_props: ['mssql_reports'], rp_failed: ['mssql_reports'], rp_roles: ['mssql_reports'], rp_services: ['mssql_reports'], rp_pwage: ['mssql_reports'], rp_tables: ['mssql_reports'],
};
for (const [tab, cols] of Object.entries(mssqlTabRuns)) {
  const page = mssqlPages[tab];
  mssqlPages[tab] = async c => {
    const [s, st] = await Promise.all([page(c), get<{ state: Table | null }>('mssql/state', { instance: c.instance, collections: cols.join(',') }).catch(() => null)]);
    const runs = rowsOf(st?.state);
    if (runs.length === cols.length && runs.every(r => r.status === 'skipped')) {
      const p = el('p', { class: 'meta' }, runs.map(r => `Not read on this instance: ${String(r.collection)} is skipped (${String(r.note ?? '')}).`).join(' '));
      const h = s.querySelector('h2');
      if (h) h.after(p); else s.prepend(p);
    }
    return s;
  };
}
// a fleet page under a tag folder keeps that folder's instances (as the fleet Slow queries page does): the Jobs timeline, TempDB
const tagKeep = async (c: Ctx): Promise<((r: Row) => boolean) | undefined> => {
  if (!c.tag) return undefined;
  const ids = new Set((await fleet()).instances
    .filter(r => c.tag === 'untagged' ? tagsOf(r).length === 0 : tagsOf(r).includes(c.tag!)).map(r => Number(r.instance_id)));
  return r => ids.has(Number(r.instance_id));
};
const jobsTimelineFleet: Render = async c => jobsTimelineView(c, await tagKeep(c));
const tempdbFleet: Render = async c => mssqlTempdbView(c, await tagKeep(c));
const rootPages: Record<string, Render> = { summary: fleetSummary, checks, findings, instances, dms, disks, storage, backups: async c => { const v = await backups(c); v.append(await pgBaseBackupsFleetSection(c)); return v; }, pgreplication: pgReplicationFleetView, pgthresholds: pgThresholdsView, corruption, extensions, versions, roles, slowqueries: slows, jobs: jobsRoot, indexes, growth, dbadash: dbadashView, custom: customRoot, alerts: alertsView, alertrules: alertRulesView, alert: alertPageView, perfsummary: perfSummaryView, running: runningFleet, jobstimeline: jobsTimelineFleet, mssqltempdb: tempdbFleet, dbchanges: async c => dbChangesView(c, await tagKeep(c)), diff: diffView, tablesize: async c => tableSizeView(c, await tagKeep(c)), mssqlrisks: mssqlChecksFleetView, pgrisks: pgDbOptionsFleetView, reportmail: reportMailView, customreports: customReportsView, community: communityView, retention: retentionView, collectiondates: collectionDatesView, drives: drivesView, dbspace: dbSpaceView, dbfiles: dbFilesView, about: aboutView, admin_instances: adminInstancesView, ...reportPages, admin: adminView };
const instancePages: Record<string, Render> = {
  summary: instanceSummary, performance: performanceView, activity: runningView, statements, counters: metricsView, replication, jobs: jobsPgView, pg_deadlocks: pgDeadlocksView, logs, dms, config, pgdboptions: pgDbOptionsView,
  tables: c => tablesView(c.instance!, c), vacuum: vacuumView, findings, load: loadView,
  host: async c => { const s = await hostView(c); s.append(await capacitySection(c)); return s; },   // the Capacity section (Serverless v2) under the host's own
  storage: storageView, backups: backupsView, pgbackups: pgBackupsView, pgstate: pgStateView, corruption: c => corruptionView(c.instance!),
  extensions: c => extensionsView(c.instance!), versions: c => versionsView(c.instance!),
  io: c => ioView(c.instance!, window_(c), rangeLabel(c)),
  actions: actionsLogView,
  jobsreport: jobsReportView,
  roles: c => rolesView(c.instance!),
  slowqueries: slowView,
  waits: waitsView,
  waiting: pgWaitingView,
  indexes: c => indexesView(c.instance!, c),
  schema: c => schemaView(c.instance!, c),
  plans: plansView,
  dbinfo: dbinfoView, db: dbPage, table: tablePage, job: jobPage, index: indexPage,
  compare: compareView,
  memory, pooler, audit: pgauditView, custom: customView, jobstimeline: jobsTimelineView,
  connections: connectionsView, dbchanges: c => dbChangesView(c),
  customreports: customReportsView, community: communityView,
  ...reportPages,
  drives: drivesView, dbspace: dbSpaceView, dbfiles: dbFilesView, driveperf: drivePerfView, pgtemp: pgTempView, collectiondates: collectionDatesView,
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
// ---- status colours: 'solid' (DBA Dash's grids: every status cell a fill, a blue header) or 'quiet' (a tint on what is
// outside the normal range only); remembered per browser, solid unless chosen otherwise
const statusStyles = ['solid', 'quiet'];
function applyStatusStyle(s: string) {
  if (s === 'quiet') document.documentElement.setAttribute('data-status', 'quiet');
  else document.documentElement.removeAttribute('data-status');
}
applyStatusStyle(lsGet('pgvigil.status') ?? 'solid');
function statusStyleButton(): HTMLElement {
  const cur = lsGet('pgvigil.status') ?? 'solid';
  const b = el('button', { type: 'button', title: 'Status colours: solid fills every status cell; quiet tints only warning and critical' }, 'Colours: ' + cur);
  b.addEventListener('click', () => {
    const next = statusStyles[(statusStyles.indexOf(lsGet('pgvigil.status') ?? 'solid') + 1) % statusStyles.length];
    lsSet('pgvigil.status', next); applyStatusStyle(next);
    b.textContent = 'Colours: ' + next;
  });
  return b;
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

// ---- the footer's status line on every page (task 152, K09.01; Darling's status bar): the instances by engine, the
// collections' last runs (healthy, failing, stale, not collected, and those without a permission counted apart), the
// repository's size, whether this server may write (the repository login) and its actions door, the newest healthy
// read, and the auto refresh as this page has it. Read at most every 15 s (internal/web/q_frame.go); a failed read says so.
let statusAt = 0, statusRow: Row | null = null, statusErr = '';
async function statusLine(ctx: Ctx, live: boolean) {
  let foot = document.getElementById('status-line');
  if (!foot) {
    foot = el('footer', { id: 'status-line', class: 'meta status-line', style: 'margin:1.5rem 0 .5rem;padding-top:.4rem;border-top:1px solid var(--line)' });
    $('content').append(foot);
  }
  if (Date.now() - statusAt > 15000) {
    try { statusRow = rowsOf(await get('frame/status'))[0] ?? null; statusErr = ''; }
    catch (e) { if (e instanceof LoginRequired) return; statusRow = null; statusErr = e instanceof Error ? e.message : String(e); }
    statusAt = Date.now();
  }
  if (loginShown) return;
  const n = (k: string) => Number(statusRow?.[k] ?? 0);
  const refresh = live ? (refreshSecs() > 0 ? 'every ' + (refreshChoices.find(([k]) => Number(k) === refreshSecs())?.[1] ?? refreshSecs() + ' s') : 'paused') : 'not on this page';
  const items: (Node | string)[] = statusRow ? [
    el('span', { 'data-part': 'instances' }, `${n('instances')} instances (${n('postgres')} PostgreSQL, ${n('sqlserver')} SQL Server)`),
    el('span', { 'data-part': 'collections' }, 'collections: ', `${n('healthy')} healthy, `,
      n('failing') ? el('a', { href: href(ctx, { tab: 'checks', instance: undefined, tag: undefined }) }, `${n('failing')} failing`) : '0 failing',
      `, ${n('stale')} stale, ${n('not_collected')} not collected`, n('no_permission') ? `; ${n('no_permission')} without a permission` : ''),
    el('span', { 'data-part': 'repository' }, `repository ${fmtBytes(statusRow.repository_bytes)}`),
    el('span', { 'data-part': 'seat' }, `${statusRow.repository_writes ? 'read-write' : 'read only'}, actions ${String(statusRow.actions ?? 'off')}`),
    el('span', { 'data-part': 'newest' }, statusRow.newest_read ? `newest read ${fmtClock(new Date(String(statusRow.newest_read)))}` : 'no read yet'),
    el('span', { 'data-part': 'refresh' }, `auto refresh ${refresh}`),
  ] : [el('span', { 'data-part': 'error' }, 'Status not read: ' + statusErr)];
  foot.replaceChildren(...items.flatMap((x, i) => i ? [' \u00b7 ', x] : [x]));
}

// showLogin replaces the page with the sign-in form; a successful sign-in renders the page asked for.
function showLogin(message = '') {
  window.clearTimeout(timer);
  timer = undefined;
  ++generation;
  loginShown = true;
  tabMark(null);   // the sign-in form: no state is known
  document.body.classList.add('signin');
  closeRange();   // the bar is emptied: an open range panel must not come back open after the sign-in
  $('tabs').replaceChildren();
  $('bar').replaceChildren();
  $('crumb').replaceChildren();
  document.getElementById('status-line')?.replaceChildren();
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
let shownPath = '';   // its tab, instance and tag alone: another of them opens at the page's top (a range or a filter keeps the place)
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
  const same = pageKey === shownPage;   // a refresh of the page on screen: its header and dot stay until the new read
  if (pageKey !== shownPage) {
    const note = el('p', { class: 'empty', role: 'status' });
    $('main').replaceChildren(note);
    requestAnimationFrame(() => { note.textContent = 'Loading...'; });
    shownPage = pageKey;
  }
  // the instance's engine chooses its tab set and pages (the fleet read is cached; unknown = PostgreSQL)
  const engine = ctx.instance ? (await fleet().catch(() => null))?.instances.find(r => Number(r.instance_id) === ctx.instance)?.engine : undefined;
  let tabs = ctx.instance ? tabsFor(engine) : rootTabs;
  // an imported server (pgvigil import dbadash, not collected by pgvigil): every SQL Server tab, each from dbadash.ts
  const imported = ctx.instance !== undefined && isMssql(engine) && await isImported(ctx.instance);
  if (ctx.instance && isMssql(engine)) {
    // the Availability tab only where one of its collections has stored a read (an imported server keeps it: its line says why it is not read)
    if (!imported && !(await hasAvailability(ctx.instance).catch(() => false))) tabs = Object.fromEntries(Object.entries(tabs).filter(([k]) => k !== 'availability'));
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
  // the range control is one node for the life of the page: a refresh while its panel is open must not close it or
  // take the focus out of it, so only what follows it in the bar is rebuilt
  const range = rangePicker(ctx, () => { void render(); });
  if (bar.firstChild !== range) bar.replaceChildren(range);
  while (range.nextSibling) range.nextSibling.remove();
  bar.append(refresh, refreshSelect(livePage), exportButtons(ctx), mailButton(ctx), toolsButton(),
    el('span', { class: 'meta', id: 'stamp' }, 'loaded ' + fmtClock(new Date())),
    statusStyleButton(), themeButton(), aboutLink(ctx));
  if (session.login && session.user) {
    const out = el('button', { type: 'button', class: 'link' }, 'Sign out');
    out.addEventListener('click', () => { void signOut(); });
    bar.append(el('span', { class: 'meta' }, session.user), out);
  }

  // the instance's header and its band's dot (task 177 D29), read beside the page; a failure there leaves them out
  // one fleet read for the tree, the breadcrumb and the header (a Refresh forces it for all three)
  const fleetRead = fleet(force);
  fleetRead.catch(() => undefined);   // its failure is the tree's to show (below), never an unhandled rejection
  const frame = ctx.instance ? instanceFrame(ctx, fleetRead).catch(() => null) : Promise.resolve(null);
  // the tree and the breadcrumb come from the fleet read; a failure there still shows the page
  const crumb = $('crumb');
  try {
    const f = await fleetRead;
    if (gen !== generation) return;
    updateTree(f, ctx);
    tabMark(f);
    const inst = ctx.instance ? f.instances.find(r => Number(r.instance_id) === ctx.instance) : undefined;
    const oldDot = same ? crumb.querySelector('.band-dot') : null;
    crumb.replaceChildren(
      el('a', { href: href(ctx, { tab: ctx.instance ? 'summary' : ctx.tab, instance: undefined, tag: undefined }) }, 'All instances'),
      ...(ctx.tag && !ctx.instance ? [' / ', el('span', {}, 'tag ' + ctx.tag)] : []),
      ...(ctx.instance ? [' / ', el('b', { id: 'crumb-inst' }, inst ? String(inst.name) : 'instance ' + ctx.instance)] : []));
    if (oldDot) $('crumb-inst')?.before(oldDot, ' ');
    // the band's dot as soon as its read ends (it does not wait for the page); a failed read takes the old one away
    void frame.then(fr => {
      if (gen !== generation) return;
      const d = $('crumb').querySelector('.band-dot');
      if (fr && d) d.replaceWith(fr.dot);
      else if (fr) $('crumb-inst')?.before(fr.dot, ' ');
      else if (d) { const sp = d.nextSibling; if (sp && sp.nodeType === Node.TEXT_NODE) sp.remove(); d.remove(); }
    });
  } catch (e) {
    if (e instanceof LoginRequired) { showLogin(); return; }
    if (gen === generation) tabMark(null);
    crumb.replaceChildren(errorBox(e));
  }

  let view: HTMLElement;
  try {
    view = (imported ? await importedPage(ctx, mssqlPages) : null) ?? await pages[ctx.tab](ctx);
  } catch (e) {
    if (e instanceof LoginRequired) { showLogin(); return; }
    view = errorBox(e);
  }
  if (gen !== generation) return;
  destroyCharts();
  // the page is placed the moment it is built and the header follows when its read ends (before the first paint when
  // it ended first; a refresh of the same page keeps the old header until then), never on a page the reader has left;
  // a header read that hangs holds nothing up
  const oldHeader = same ? $('main').querySelector(':scope > .inst-header') : null;
  $('main').replaceChildren(...(oldHeader ? [oldHeader] : []), view);
  void frame.then(fr => {
    if (gen !== generation) return;
    const cur = $('main').querySelector(':scope > .inst-header');
    if (fr && cur) cur.replaceWith(fr.header);
    else if (fr) $('main').prepend(fr.header);
    else cur?.remove();
  });
  // another page (a link, the tree, a tab) opens at its top, wherever the reader stood on the page before (Allen
  // 2026-11-11: 'when I click on something it takes me down to the page'); a range, a filter or a refresh of the same
  // page keeps the place
  const path = `${ctx.tab}|${ctx.instance ?? ''}|${ctx.tag ?? ''}`;
  if (path !== shownPath) { shownPath = path; window.scrollTo(0, 0); }
  void statusLine(ctx, livePage);
  const live = ctx.instance ? liveInstance : liveRoot;
  if (live.has(ctx.tab) && isLive(ctx) && !ctx.at && refreshSecs() > 0) {
    timer = window.setTimeout(() => { if (!document.hidden) void render(true); else timer = undefined; }, refreshSecs() * 1000);
  }
}

mountTree($('tree'));
installTreeMenu();
installFileDrop();
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
// a hidden tab's mark: the fleet's status every 60 s (task 191); none on the sign-in form or with auto refresh Off
watchHiddenTab(() => loginShown || refreshSecs() === 0);
// a schedule's headless render (task 171): the render key leaves the address before the first render
mailRenderBoot();
// the first load asks who holds this session; a 401 shows the sign-in form before any page
(async () => {
  try { session = await get<Session>('session'); } catch (e) { if (e instanceof LoginRequired) { showLogin(); return; } }
  void render();
})();
