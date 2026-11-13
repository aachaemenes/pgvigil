// The Storage folder in DBA Dash's shape (task 176; DBA Dash's Storage > Drives | DB Space | Files | TempDB | Table Size
// | Drive Performance), at the root, a tag folder and an instance, on both engines:
//   drivesView     one bar per drive (green, amber past the warning, red past the critical): '<free> GB free (<pct>%) of
//                  <size> GB', 'Updated <time> (<age> ago)', the Warning % / Critical % it is judged by with Configure
//                  (the root, a tag, an instance, a drive), Files and History per drive; a folder lists every
//                  instance's drives, Critical and Warning by default with All beside it (DBA Dash's filter); Toggle
//                  Metrics shows the same drives as a grid (copy, export, columns).
//   dbSpaceView    allocated and used per instance (a folder) or per database (an instance), a pie, and History.
//   dbFilesView    the files: SQL Server's data and log files, PostgreSQL's WAL directory and tablespaces.
//   drivePerfView  one instance's read / write latency and throughput per drive over the page's range.
// Data: /api/drives, /api/drives/history, /api/dbspace, /api/dbfiles, /api/driveperf (internal/web/q_drives.go).
import { get, post, Row, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { href, rangeLabel, window_ } from './router';
import { fleet, tagsOf } from './fleet';
import { donutChart, lineChart } from './chart';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtTime, grid } from './ui';
import { loadAckSafe, offBeside, onDoor, pageNote, seatWhy } from './ack';

type Parts<K extends string> = Record<K, Table | null>;
const lsGet = (k: string) => { try { return localStorage.getItem(k); } catch { return null; } };
const lsSet = (k: string, v: string) => { try { localStorage.setItem(k, v); } catch { /* private window */ } };

const GB = 1024 ** 3;
const gb = (v: unknown) => v == null ? '' : (Number(v) / GB).toFixed(1) + ' GB';
const pct = (v: unknown) => v == null ? '' : Number(v).toFixed(1) + '%';
// ago: an age in seconds by its two largest units (DBA Dash's '9min ago')
function ago(secs: unknown): string {
  const s = Math.max(0, Math.round(Number(secs ?? 0))), m = Math.floor(s / 60), h = Math.floor(m / 60), d = Math.floor(h / 24);
  return d ? `${d}d ${h % 24}h` : h ? `${h}h ${m % 60}min` : m ? `${m}min` : `${s}s`;
}
const statusWord: Record<string, string> = { critical: 'Critical', warning: 'Warning', ok: 'OK', unknown: 'Size not read' };
const statusKind: Record<string, string> = { critical: 'crit', warning: 'warn', ok: 'ok', unknown: '' };
const statusColor: Record<string, string> = { critical: 'var(--crit)', warning: 'var(--warn)', ok: 'var(--ok)', unknown: 'var(--muted)' };

// the folder's instances (a tag folder: its own; the root: every one) and each instance's engine
async function scope(ctx: Ctx): Promise<{ params: Record<string, string | number | undefined>; engineOf: Map<number, string>; folder: string }> {
  const f = await fleet();
  const engineOf = new Map(f.instances.map(r => [Number(r.instance_id), String(r.engine ?? 'postgres')]));
  if (ctx.instance) return { params: { instance: ctx.instance }, engineOf, folder: '' };
  if (!ctx.tag) return { params: {}, engineOf, folder: 'the fleet' };
  const ids = f.instances.filter(r => ctx.tag === 'untagged' ? tagsOf(r).length === 0 : tagsOf(r).includes(ctx.tag!)).map(r => Number(r.instance_id));
  return { params: { instances: ids.join(',') || '0' }, engineOf, folder: `the folder ${ctx.tag}` };
}
// a page of one instance, from a folder: the instance's own tab (the strip's names: drives, dbspace, dbfiles ...)
const instHref = (ctx: Ctx, id: unknown, tab: string) => href(ctx, { tab, instance: Number(id), tag: undefined });
// the Files tab of an instance: the same Files page at the instance; with a drive, only the files on that drive
// (DBA Dash's drive Files link; the page reads drive= from the address, the router keeps no such parameter)
const filesHref = (ctx: Ctx, id: unknown, drive?: unknown) => instHref(ctx, id, 'dbfiles') + (drive == null ? '' : '&drive=' + encodeURIComponent(String(drive)));
const hashParam = (k: string) => new URLSearchParams(location.hash.split('?')[1] ?? '').get(k);

// statusIcon: DBA Dash's drive icon with its status mark (a green tick, an amber '!', a red 'x'; grey '?' where the
// size is not read); the word is its accessible name (and the grid and the export keep the word)
function statusIcon(st: string): SVGSVGElement {
  const ns = 'http://www.w3.org/2000/svg';
  const mk = <K extends keyof SVGElementTagNameMap>(t: K, a: Record<string, string>) => { const e = document.createElementNS(ns, t); for (const [k, v] of Object.entries(a)) e.setAttribute(k, v); return e; };
  const svg = mk('svg', { viewBox: '0 0 36 30', width: '36', height: '30', role: 'img', 'aria-label': statusWord[st] ?? st, class: 'drive-icon ' + (statusKind[st] || 'none') });
  const t = mk('title', {}); t.textContent = statusWord[st] ?? st; svg.append(t);
  // the drive: a grey box with its light
  svg.append(mk('rect', { x: '1', y: '4', width: '30', height: '13', rx: '2', fill: 'var(--muted, #8a8f98)', stroke: 'var(--line, #666)' }));
  svg.append(mk('rect', { x: '4', y: '12', width: '5', height: '2', fill: 'var(--card, #fff)' }));
  // the mark
  svg.append(mk('circle', { cx: '25', cy: '21', r: '8', fill: statusColor[st] ?? 'var(--muted)', stroke: 'var(--card, #fff)', 'stroke-width': '1.5' }));
  const ink = { stroke: '#fff', 'stroke-width': '2.2', fill: 'none', 'stroke-linecap': 'round', 'stroke-linejoin': 'round' };
  if (st === 'ok') svg.append(mk('path', { d: 'M21 21.5l3 3 5-6', ...ink }));
  else if (st === 'warning') { svg.append(mk('path', { d: 'M25 16.5v5.5', ...ink })); svg.append(mk('circle', { cx: '25', cy: '25.3', r: '1.3', fill: '#fff' })); }
  else if (st === 'critical') svg.append(mk('path', { d: 'M21.5 17.5l7 7M28.5 17.5l-7 7', ...ink }));
  else { svg.append(mk('path', { d: 'M22.8 18.8a2.4 2.4 0 1 1 3.2 2.3c-.7.3-1 .8-1 1.5', ...ink })); svg.append(mk('circle', { cx: '25', cy: '25.6', r: '1.2', fill: '#fff' })); }
  return svg;
}

// a status filter (DBA Dash's 'Critical,Warning' button): the choice is kept per scope kind (folder / instance)
function statusSelect(id: string, key: string, dflt: string): HTMLSelectElement {
  const opts: [string, string][] = [['critical,warning', 'Critical, Warning'], ['all', 'All'], ['critical', 'Critical'], ['warning', 'Warning'], ['ok', 'OK']];
  const s = el('select', { id }, ...opts.map(([v, l]) => el('option', { value: v }, l)));
  const saved = lsGet(key);
  s.value = saved && opts.some(o => o[0] === saved) ? saved : dflt;
  return s;
}

// ---- Configure: a drive threshold at one place (DBA Dash's Configure: the root, a tag, an instance, a drive)
interface Place { level: 'root' | 'tag' | 'instance' | 'drive'; instance_id?: number; tag?: string; drive?: string; where: string }
function ownRow(rows: Row[], p: Place): Row | undefined {
  return rows.find(t => t.level === p.level && (p.instance_id == null || Number(t.instance_id) === p.instance_id)
    && (p.tag == null || t.tag === p.tag) && (p.drive == null || t.drive === p.drive));
}
function configureDialog(p: Place, inForce: string, own: Row | undefined, after: () => void) {
  const inp = (lab: string, v: unknown) => el('input', { type: 'number', min: '0', max: '100', step: 'any', 'aria-label': lab, value: v == null ? '' : String(v), style: 'width:7rem' });
  const warn = inp('Warning, per cent free', own ? own.warn_pct : ''), crit = inp('Critical, per cent free', own ? own.crit_pct : '');
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const save = el('button', { type: 'submit' }, 'Set'), inherit = el('button', { type: 'button' }, 'Inherit'), back = el('button', { type: 'button' }, 'Back');
  // nothing of this level's own to end: Inherit is off with that reason beside it (it already inherits)
  if (!own) offBeside(inherit, 'this level has no threshold of its own: it already inherits the level above');
  const form = el('form', { method: 'dialog' }, el('h3', {}, `Drive space thresholds: ${p.where}`),
    el('p', {}, 'A drive with less free space than the warning per cent is a warning, less than the critical per cent a critical. '
      + 'The drive\'s own threshold wins, then its instance\'s, a tag\'s (when two of the instance\'s tags carry one, the tag first by name), the root\'s; the default is warning under 20 %, critical under 10 %. '
      + 'Inherit ends this level\'s own threshold, so the level above applies. Who set it and when is kept.'),
    el('p', { class: 'meta' }, `In force now: ${inForce}.`),
    el('div', { style: 'margin:.3rem 0' }, el('label', {}, 'Warning under (% free) ', warn)),
    el('div', { style: 'margin:.3rem 0' }, el('label', {}, 'Critical under (% free) ', crit)),
    msg, el('div', { style: 'margin-top:.6rem' }, save, ' ', inherit, ' ', back));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:36rem', 'aria-label': `Drive space thresholds: ${p.where}` }, form);
  let done = false;
  const close = () => { dlg.close(); dlg.remove(); if (done) after(); };
  back.addEventListener('click', close);
  dlg.addEventListener('cancel', () => { dlg.remove(); if (done) after(); });
  const send = async (op: 'set' | 'inherit') => {
    save.disabled = inherit.disabled = true;
    msg.textContent = 'Saving...';
    const body: Record<string, unknown> = { op, level: p.level, instance_id: p.instance_id, tag: p.tag, drive: p.drive };
    if (op === 'set') { body.warn = warn.value; body.crit = crit.value; }
    try {
      const r = await post<{ outcome: string; detail: string }>('drives/thresholds', body);
      done = true;
      msg.replaceChildren(badge(r.outcome, 'ok'), ' ', r.detail);
    } catch (e) {
      msg.replaceChildren(badge('not saved', 'crit'), ' ', e instanceof Error ? e.message : String(e));
      save.disabled = false; inherit.disabled = false;   // an Inherit that is off stays off the B7 way
    }
    back.textContent = 'Close';
  };
  form.addEventListener('submit', ev => { ev.preventDefault(); void send('set'); });
  inherit.addEventListener('click', () => void send('inherit'));
  document.body.append(dlg);
  dlg.showModal();
  warn.focus();
}
const levelWords = (r: Row) => r.threshold_level === 'default' ? 'the default' : r.threshold_level === 'tag' ? `set on the tag ${String(r.threshold_tag)}` : `set on the ${String(r.threshold_level)}`;

// ---- Drives
export async function drivesView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', { class: 'drives' }, el('h2', {}, 'Drives'));
  const folder = !ctx.instance;
  const fkey = folder ? 'pgvigil.drivesStatus.folder' : 'pgvigil.drivesStatus.instance';
  const statusSel = statusSelect('drv-status', fkey, folder ? 'critical,warning' : 'all');
  let metrics = lsGet('pgvigil.drivesMetrics') === '1';
  const refresh = el('button', { type: 'button', title: 'Read the drives again' }, 'Refresh');
  const configure = el('button', { type: 'button' }, 'Configure');
  const toggle = el('button', { type: 'button', 'aria-pressed': String(metrics) }, 'Toggle Metrics');
  // who may set a threshold here (the acknowledgement seat: the threshold writes ask the same one). A server that
  // writes nothing: the page's one sentence, which every Configure points at; where a door stands a Configure that
  // is off says its own reason (a real instance's drive, a level wider than one instance)
  const ad = await loadAckSafe(['acks']);
  if (!ad.writable && !ad.door) ad.note = el('p', { class: 'meta' }, `Thresholds are read only here: ${seatWhy(ad, 'thresholds') ?? ''}`);
  // on a demo serve the drives of an instance that is not the demo's share one reason: ONE sentence on the page that
  // every such Configure points at (beside each drive it stood once per drive). An instance's own page names the
  // instance; a folder says it of every such instance. Shown only while a control points at it (realUsed)
  const instName = onDoor(ad) && ctx.instance
    ? await fleet().then(f => String(f.instances.find(i => Number(i.instance_id) === ctx.instance)?.name ?? 'this instance'), () => 'this instance') : undefined;
  const realNote = onDoor(ad) ? el('p', { class: 'meta', hidden: '' }, ctx.instance
    ? `Thresholds are read only here: ${seatWhy(ad, 'thresholds', ctx.instance, instName) ?? ''}`
    : "Thresholds of an instance that is not one of this demo's instances are read only here: changing them needs pgvigil serve with a signed-in user") : undefined;
  let realUsed = false;
  const offNote = (instanceId: number | undefined): HTMLElement | undefined => {
    if (pageNote(ad)) return pageNote(ad);
    if (!realNote || instanceId == null || ad.door!.instances.includes(instanceId)) return undefined;   // its own reason, beside it
    realUsed = true; realNote.hidden = false;
    return realNote;
  };
  const body = el('div');
  let seq = 0;
  let thresholds: Row[] = [];
  let sc: Awaited<ReturnType<typeof scope>>;
  async function draw() {
    const mine = ++seq;
    let d: Parts<'drives' | 'counts' | 'thresholds'>;
    try {
      sc = await scope(ctx);
      d = await get<Parts<'drives' | 'counts' | 'thresholds'>>('drives', { ...sc.params, status: statusSel.value });
    } catch (e) { if (mine === seq) body.replaceChildren(errorBox(e)); return; }
    if (mine !== seq) return;
    // a new draw: the sentence for other instances' drives shows again only if one of them is drawn
    if (realNote && !(ctx.instance && realUsed)) { realUsed = false; realNote.hidden = true; }
    const rows = rowsOf(d.drives), c = rowsOf(d.counts)[0] ?? {};
    thresholds = rowsOf(d.thresholds);
    const total = Number(c.drives ?? 0);
    const line = el('p', { class: 'meta' }, `${fmtNum(total)} drive(s)${folder ? ` of ${fmtNum(c.instances ?? 0)} instance(s) in ${sc.folder}` : ''}: `,
      badge(`${fmtNum(c.critical ?? 0)} critical`, Number(c.critical) ? 'crit' : ''), ' ', badge(`${fmtNum(c.warning ?? 0)} warning`, Number(c.warning) ? 'warn' : ''), ' ',
      `${fmtNum(c.ok ?? 0)} OK`, Number(c.unknown) ? `, ${fmtNum(c.unknown)} with no size read` : '', `; newest read ${fmtTime(c.newest_at) || 'none'}.`);
    if (!rows.length) {
      const all = el('button', { type: 'button', class: 'link' }, 'Show all drives');
      all.addEventListener('click', () => { statusSel.value = 'all'; lsSet(fkey, 'all'); void draw(); });
      body.replaceChildren(line, el('p', { class: 'empty' }, total
        ? `No drive matches the filter (${statusSel.options[statusSel.selectedIndex].text}): every drive here is in another state. `
        : 'No drive read yet: the host collection (system_stats or CloudWatch) reads a PostgreSQL server\'s volumes, mssql_storage a SQL Server\'s. ',
        total ? all : ''));
      return;
    }
    body.replaceChildren(line, metrics ? drivesGrid(ctx, rows, folder) : el('div', { class: 'drive-list' }, ...rows.map(r => driveCard(ctx, r, folder))));
  }
  function driveCard(ctxIn: Ctx, r: Row, folderView: boolean): HTMLElement {
    const st = String(r.status ?? 'unknown');
    const total = Number(r.total_bytes ?? 0), used = Number(r.used_bytes ?? (total - Number(r.free_bytes ?? 0)));
    const usedPct = total > 0 ? Math.min(100, Math.max(0, 100 * used / total)) : 0;
    const name = String(r.drive) + (r.label ? ` (${String(r.label)})` : '');
    // a meter only where the size is read: an unknown size draws no bar (Aurora's local storage)
    const bar = total > 0 ? el('div', { role: 'meter', 'aria-valuemin': '0', 'aria-valuemax': '100', 'aria-valuenow': usedPct.toFixed(1),
      'aria-label': `${name} on ${String(r.instance)}: ${usedPct.toFixed(1)}% used, ${statusWord[st]}`, style: 'height:1.1rem;border:1px solid var(--line, #8888);border-radius:3px;background:var(--card, transparent);overflow:hidden' },
    el('div', { style: `height:100%;width:${usedPct.toFixed(1)}%;background:${statusColor[st]}` })) : '';
    const own: Place = { level: 'drive', instance_id: Number(r.instance_id), drive: String(r.drive), where: `the drive ${String(r.drive)} of ${String(r.instance)}` };
    const cfg = el('button', { type: 'button', class: 'link', 'aria-label': `Configure the thresholds of ${String(r.drive)} on ${String(r.instance)}` }, 'Configure');
    const cfgWhy = seatWhy(ad, 'thresholds', Number(r.instance_id), String(r.instance));
    if (cfgWhy) offBeside(cfg, cfgWhy, offNote(Number(r.instance_id)));
    else cfg.addEventListener('click', () => configureDialog(own, `warning under ${pct(r.warn_pct)}, critical under ${pct(r.crit_pct)} (${levelWords(r)})`, ownRow(thresholds, own), () => void draw()));
    const hist = el('button', { type: 'button', class: 'link', 'aria-expanded': 'false', 'aria-label': `History of ${String(r.drive)} on ${String(r.instance)}` }, 'History');
    const histBox = el('div');
    hist.addEventListener('click', () => {
      const open = hist.getAttribute('aria-expanded') === 'true';
      hist.setAttribute('aria-expanded', String(!open));
      if (open) { histBox.replaceChildren(); return; }
      void driveHistory(Number(r.instance_id), String(r.drive), String(r.instance), !folderView, histBox);
    });
    const free = `${gb(r.free_bytes)} free (${pct(r.free_pct)}) of ${gb(r.total_bytes)}`;
    return el('div', { class: 'drive', style: 'margin:.2rem 0 1rem;max-width:72rem;display:flex;gap:.6rem;align-items:flex-start', 'data-status': st },
      el('div', { style: 'flex:0 0 auto;padding-top:.9rem' }, statusIcon(st)),
      el('div', { style: 'flex:1 1 auto;min-width:0' },
      el('div', { style: 'display:flex;justify-content:space-between;gap:1rem;flex-wrap:wrap' },
        el('div', {}, el('strong', {}, name),
          folderView ? el('span', {}, ' on ', el('a', { href: instHref(ctxIn, r.instance_id, 'drives') }, String(r.instance))) : ''),
        el('div', { class: 'meta' }, `Warning: ${pct(r.warn_pct)}, Critical: ${pct(r.crit_pct)} (${levelWords(r)}) `, cfg)),
      bar,
      el('div', { style: 'display:flex;justify-content:space-between;gap:1rem;flex-wrap:wrap' },
        el('div', {}, el('div', {}, total > 0 ? free : 'The size of this volume is not read (Aurora\'s local storage: no total).'),
          el('div', { class: 'meta' }, `Updated ${fmtTime(r.snapshot_at)} (${ago(r.age_secs)} ago)`)),
        el('div', {}, el('a', { href: filesHref(ctxIn, r.instance_id, r.drive), 'aria-label': `Files on ${String(r.drive)} of ${String(r.instance)}` }, 'Files'), ' ', hist)),
      histBox));
  }
  refresh.addEventListener('click', () => void draw());
  statusSel.addEventListener('change', () => { lsSet(fkey, statusSel.value); void draw(); });
  toggle.addEventListener('click', () => { metrics = !metrics; toggle.setAttribute('aria-pressed', String(metrics)); lsSet('pgvigil.drivesMetrics', metrics ? '1' : '0'); void draw(); });
  configure.addEventListener('click', () => {
    const p: Place = ctx.instance ? { level: 'instance', instance_id: ctx.instance, where: 'this instance (every drive without its own)' }
      : ctx.tag && ctx.tag !== 'untagged' ? { level: 'tag', tag: ctx.tag, where: `the tag ${ctx.tag} (every instance carrying it)` }
        : { level: 'root', where: 'the root (every drive of the fleet)' };
    const own = ownRow(thresholds, p);
    configureDialog(p, own ? `warning under ${pct(own.warn_pct)}, critical under ${pct(own.crit_pct)} (set at this level)` : 'the level above (or the default: warning under 20 %, critical under 10 %)', own, () => void draw());
  });
  sec.append(el('div', { class: 'toolbar' }, refresh, ' ', el('label', { for: 'drv-status' }, 'Status ', statusSel), ' ', configure, ' ', toggle), ...(ad.note ? [ad.note] : []), ...(realNote ? [realNote] : []), body);
  // the toolbar's Configure sets the scope's own level: this instance, the tag folder, or the root - an instance that
  // is not the demo's points at the page's one sentence; a level wider than one instance says its own reason beside it
  const scopeWhy = seatWhy(ad, 'thresholds', ctx.instance ?? undefined, instName);
  if (scopeWhy) offBeside(configure, scopeWhy, offNote(ctx.instance ?? undefined));
  await draw();
  return sec;
}

function drivesGrid(ctx: Ctx, rows: Row[], folder: boolean): HTMLElement {
  const cols: Col[] = [
    ...(folder ? [{ key: 'instance', fmt: (v: unknown, r: Row) => el('a', { href: instHref(ctx, r.instance_id, 'drives') }, String(v ?? '')) } as Col] : []),
    { key: 'drive' }, { key: 'label', label: 'volume' },
    { key: 'status', fmt: v => badge(statusWord[String(v)] ?? String(v), statusKind[String(v)] ?? '') },
    { key: 'total_bytes', label: 'size', num: true, fmt: fmtBytes }, { key: 'used_bytes', label: 'used', num: true, fmt: fmtBytes },
    { key: 'free_bytes', label: 'free', num: true, fmt: fmtBytes }, { key: 'free_pct', label: 'free %', num: true },
    { key: 'warn_pct', label: 'warning under %', num: true }, { key: 'crit_pct', label: 'critical under %', num: true },
    { key: 'threshold_level', label: 'threshold set on', fmt: (v, r) => v === 'tag' ? `tag ${String(r.threshold_tag)}` : String(v ?? '') },
    { key: 'engine' }, { key: 'source', label: 'read from' }, { key: 'snapshot_at', label: 'updated', fmt: fmtTime },
  ];
  return grid(rows, cols, 'No drive.');
}

// driveHistory: one drive's used and free space as a chart over a window the reader picks, 5 minutes to one year (the
// windows /api/drives/history takes, in minutes); the pick is kept for every drive's History. A line over the chart
// says how much history the window really holds; a window too short for the drive's read interval (a PostgreSQL
// host's volume is stored every 15 minutes at most, a SQL Server's at each storage collection) says so in words.
const historyWindows: [number, string][] = [[5, '5 minutes'], [15, '15 minutes'], [30, '30 minutes'], [60, '1 hour'], [360, '6 hours'], [1440, '24 hours'],
  [2880, '2 days'], [10080, '7 days'], [43200, '30 days'], [129600, '90 days'], [259200, '180 days'], [525600, '1 year']];
// lengthWords: a length in the unit that reads best (minutes under 90 minutes, hours under 2 days, days after)
function lengthWords(ms: number): string {
  const m = ms / 60e3, one = (n: number, unit: string) => `${fmtNum(n)} ${unit}${n === 1 ? '' : 's'}`;
  return m < 90 ? one(Math.max(1, Math.round(m)), 'minute') : m < 2880 ? one(Math.round(m / 6) / 10, 'hour') : one(Math.round(m / 144) / 10, 'day');
}
// historyLine: what the window holds. rows: the window's reads, oldest first, each under its own time; newest: the
// drive's newest reads whatever the window (five at most); marked: the chart marks restarts, failovers and setting
// changes (an instance's page)
function historyLine(rows: Row[], newest: Row[], minutes: number, words: string, marked: boolean): string {
  const at = (r: Row | undefined) => r ? Date.parse(String(r.snapshot_at)) : NaN;
  // the drive's read interval: the upper median of the gaps between its newest reads. One read off the cycle (a
  // collection runs once at each collector start) splits one interval into two short gaps: of four gaps the upper
  // median is still the interval (16:00, 16:17, 17:00, 18:00, 19:00 -> 17, 43, 60, 60 minutes -> 60)
  const gaps = newest.slice(1).map((r, i) => at(newest[i]) - at(r)).filter(g => Number.isFinite(g) && g > 0).sort((x, y) => x - y);
  const gap = gaps.length ? gaps[Math.floor(gaps.length / 2)] : NaN;
  const last = newest[0], now = Date.now(), age = now - at(last);
  // reads that stopped: none for over two intervals (an hour's interval taken where one read is all there is)
  const stopped = Number.isFinite(age) && age > Math.max(2 * (Number.isFinite(gap) ? gap : 3600e3), 30 * 60e3);
  const stoppedNote = stopped ? ` No read for ${lengthWords(age)}: this drive's collection has stopped.` : '';
  if (rows.length < 2) {
    return `This window holds ${rows.length ? 'one read' : 'no read'}, so no line is drawn.`
      + (Number.isFinite(gap) ? ` This drive ${stopped ? 'was' : 'is'} read about every ${lengthWords(gap)}` : last ? ' This drive has been read once' : ' No history is stored for this drive yet')
      + (last ? `; its newest read, ${fmtTime(last.snapshot_at)}: ${fmtBytes(last.used_bytes)} used, ${fmtBytes(last.free_bytes)} free.` : '.')
      + stoppedNote + (Number.isFinite(gap) ? ' Pick a longer window.' : '');
  }
  const first = at(rows[0]), end = at(rows[rows.length - 1]), win = minutes * 60e3;
  const step = Math.max(Number.isFinite(gap) ? gap : 0, (end - first) / (rows.length - 1));
  return `${fmtNum(rows.length)} reads over ${lengthWords(end - first)} of history`
    + (first - (now - win) > Math.max(2 * step, 0.05 * win) ? ` (the ${words} window holds no more yet)` : '') + '.' + stoppedNote
    + (marked && minutes > 31 * 1440 ? ' Restarts, failovers and setting changes are marked for the last 31 days only.' : '');
}
async function driveHistory(id: number, drive: string, inst: string, marked: boolean, box: HTMLElement) {
  let win = Number(lsGet('pgvigil.driveHistoryMinutes')); if (!historyWindows.some(w => w[0] === win)) win = 43200;
  const sel = el('select', { 'aria-label': `History window of ${drive} on ${inst}` }, ...historyWindows.map(([m, words]) => el('option', { value: String(m) }, words)));
  sel.value = String(win);
  const chart = el('div');
  let seq = 0;
  async function draw() {
    const mine = ++seq, want = win, words = historyWindows.find(w => w[0] === want)![1];
    chart.replaceChildren(el('p', { class: 'meta' }, 'Reading the history...'));
    try {
      const d = await get<Parts<'history' | 'newest'>>('drives/history', { instance: id, drive, minutes: want });
      if (mine !== seq) return;
      const rows = rowsOf(d.history), title = `${drive} on ${inst}: used and free over ${words}`;
      // under two reads the line above says why no chart is drawn: the title alone stands under it (no second sentence)
      chart.replaceChildren(el('p', { class: 'meta', role: 'status' }, historyLine(rows, rowsOf(d.newest), want, words, marked)),
        rows.length < 2 ? el('div', { class: 'chart' }, el('h3', {}, title))
          : lineChart(title, rows, [{ key: 'used_bytes', label: 'used' }, { key: 'free_bytes', label: 'free' }], v => fmtBytes(v), { ownSpan: true }));
    } catch (e) { if (mine === seq) chart.replaceChildren(errorBox(e)); }
  }
  sel.addEventListener('change', () => { win = Number(sel.value); lsSet('pgvigil.driveHistoryMinutes', String(win)); void draw(); });
  box.replaceChildren(el('div', { class: 'toolbar' }, el('label', {}, 'History ', sel)), chart);
  await draw();
}

// ---- DB Space
export async function dbSpaceView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'DB Space'));
  const body = el('div');
  const days = [7, 30, 90, 180, 365];
  let day = Number(lsGet('pgvigil.dbspaceDays')); if (!days.includes(day)) day = 30;
  const daySel = el('select', { id: 'dbs-days' }, ...days.map(n => el('option', { value: String(n) }, `${n} days`)));
  daySel.value = String(day);
  const refresh = el('button', { type: 'button' }, 'Refresh');
  async function draw() {
    let d: Parts<'instances' | 'databases' | 'history'>;
    let sc: Awaited<ReturnType<typeof scope>>;
    try {
      sc = await scope(ctx);
      d = await get<Parts<'instances' | 'databases' | 'history'>>('dbspace', { ...sc.params, days: day });
    } catch (e) { body.replaceChildren(errorBox(e)); return; }
    if (!ctx.instance) {
      // the GB columns hold the GB figure itself (rounded to 0.1) and show it with fmtNum, so the export writes a number
      const toGB = (v: unknown) => v == null ? null : Math.round(Number(v) / GB * 10) / 10;
      const rows: Row[] = rowsOf(d.instances).map((r): Row => ({ ...r, allocated_gb: toGB(r.allocated_bytes), used_gb: toGB(r.used_bytes) }));
      const cols: Col[] = [
        { key: 'instance', label: 'name', fmt: (v, r) => el('a', { href: instHref(ctx, r.instance_id, 'dbspace') }, String(v ?? '')) },
        { key: 'allocated_gb', label: 'allocated (GB)', num: true, fmt: v => fmtNum(v) },
        { key: 'used_gb', label: 'used (GB)', num: true, fmt: (v, r) => v == null ? (r.engine === 'postgres' ? 'not read' : '') : fmtNum(v) },
        { key: 'databases', num: true }, { key: 'engine' },
        { key: 'history', label: 'history', fmt: (_v, r) => el('a', { href: instHref(ctx, r.instance_id, 'dbspace'), 'aria-label': `View the history of ${String(r.instance)}` }, 'View') },
      ];
      body.replaceChildren(
        el('p', { class: 'meta' }, `The space the databases hold now, per instance of ${sc.folder}. Allocated: a SQL Server instance's data and log files, a PostgreSQL instance's databases (pg_database_size). `
          + 'Used: the space used inside SQL Server\'s files where every file\'s was read; a PostgreSQL file holds no unallocated space to read, so it is not given there.'),
        el('div', { class: 'cards', style: 'display:flex;flex-wrap:wrap;gap:1.5rem;align-items:flex-start' },
          grid(rows, cols, 'No database size read yet.'),
          donutChart('DB Space (allocated)', rows.map(r => ({ label: String(r.instance), value: Number(r.allocated_bytes ?? 0), href: instHref(ctx, r.instance_id, 'dbspace') })), v => fmtBytes(v), 10)));
      return;
    }
    const dbs = rowsOf(d.databases), hist = rowsOf(d.history);
    const cols: Col[] = [
      { key: 'database' },
      { key: 'allocated_bytes', label: 'allocated', num: true, fmt: fmtBytes }, { key: 'used_bytes', label: 'used', num: true, fmt: fmtBytes },
      { key: 'data_bytes', label: 'data files', num: true, fmt: fmtBytes }, { key: 'log_bytes', label: 'log files', num: true, fmt: fmtBytes },
      { key: 'snapshot_at', label: 'read', fmt: fmtTime },
    ];
    body.replaceChildren(
      el('div', { style: 'display:flex;flex-wrap:wrap;gap:1.5rem;align-items:flex-start' },
        grid(dbs, cols, 'No database size read yet.'),
        donutChart('DB Space by database', dbs.map(r => ({ label: String(r.database), value: Number(r.allocated_bytes ?? 0) })), v => fmtBytes(v), 10)),
      lineChart(`History: the databases' space over ${day} days`, hist, [{ key: 'allocated_bytes', label: 'allocated' }, { key: 'used_bytes', label: 'used' }], v => fmtBytes(v)));
  }
  daySel.addEventListener('change', () => { day = Number(daySel.value); lsSet('pgvigil.dbspaceDays', String(day)); void draw(); });
  refresh.addEventListener('click', () => void draw());
  sec.append(el('div', { class: 'toolbar' }, refresh, ' ', ctx.instance ? el('label', { for: 'dbs-days' }, 'History ', daySel) : ''), body);
  await draw();
  return sec;
}

// ---- Files
export async function dbFilesView(ctx: Ctx): Promise<HTMLElement> {
  // a drive's Files link: only the files on that drive (an instance's page)
  const drive = ctx.instance ? hashParam('drive') ?? '' : '';
  const sec = el('section', {}, el('h2', {}, drive ? `Files on ${drive}` : 'Files'));
  const folder = !ctx.instance;
  const fkey = folder ? 'pgvigil.filesStatus.folder' : 'pgvigil.filesStatus.instance';
  const statusSel = statusSelect('files-status', fkey, folder ? 'critical,warning' : 'all');
  const refresh = el('button', { type: 'button' }, 'Refresh');
  const body = el('div');
  async function draw() {
    let d: Parts<'files' | 'counts'>;
    let sc: Awaited<ReturnType<typeof scope>>;
    try {
      sc = await scope(ctx);
      d = await get<Parts<'files' | 'counts'>>('dbfiles', { ...sc.params, status: statusSel.value, drive: drive || undefined });
    } catch (e) { body.replaceChildren(errorBox(e)); return; }
    const rows = rowsOf(d.files), c = rowsOf(d.counts)[0] ?? {};
    const cols: Col[] = [
      ...(folder ? [{ key: 'instance', fmt: (v: unknown, r: Row) => el('a', { href: instHref(ctx, r.instance_id, 'dbfiles') }, String(v ?? '')) } as Col] : []),
      { key: 'database' }, { key: 'file', label: 'file name' }, { key: 'type' }, { key: 'filegroup' },
      { key: 'location', label: 'physical name', wide: true },
      { key: 'size_bytes', label: 'size', num: true, fmt: fmtBytes }, { key: 'used_bytes', label: 'used', num: true, fmt: fmtBytes },
      { key: 'free_bytes', label: 'free', num: true, fmt: fmtBytes }, { key: 'free_pct', label: 'free %', num: true },
      { key: 'max_size_bytes', label: 'max size', num: true, fmt: (v, r) => v == null ? (r.engine === 'sqlserver' ? 'unlimited' : '') : fmtBytes(v) },
      { key: 'growth' }, { key: 'drive' },
      { key: 'status', fmt: v => badge(statusWord[String(v)] ?? String(v), statusKind[String(v)] ?? '') },
      { key: 'snapshot_at', label: 'read', fmt: fmtTime },
    ];
    body.replaceChildren(
      el('p', { class: 'meta' }, `File count ${fmtNum(c.files ?? 0)}, total size ${fmtBytes(c.size_bytes ?? 0)}${folder ? ` in ${sc.folder}` : ''}${drive ? ` on ${drive}` : ''}. `
        + 'SQL Server: every data and log file; critical at its maximum size, warning within one growth of it. PostgreSQL: the WAL directory and each tablespace, each on the drive that holds it (pg_wal, pg_default and pg_global on the data directory\'s drive; no maximum to judge).',
        drive ? el('span', {}, ' ', el('a', { href: instHref(ctx, ctx.instance, 'dbfiles') }, 'All the files of the instance')) : ''),
      grid(rows, cols, statusSel.value === 'all' ? 'No file read yet.' : 'No file matches the filter: show All to list every file.'));
  }
  statusSel.addEventListener('change', () => { lsSet(fkey, statusSel.value); void draw(); });
  refresh.addEventListener('click', () => void draw());
  sec.append(el('div', { class: 'toolbar' }, refresh, ' ', el('label', { for: 'files-status' }, 'Status ', statusSel)), body);
  await draw();
  return sec;
}

// ---- Drive Performance (an instance)
export async function drivePerfView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Drive Performance (${rangeLabel(ctx)})`));
  let d: Parts<'series' | 'meta'>;
  try { d = await get<Parts<'series' | 'meta'>>('driveperf', { instance: ctx.instance, ...window_(ctx) }); } catch (e) { sec.append(errorBox(e)); return sec; }
  const rows = rowsOf(d.series), m = rowsOf(d.meta)[0] ?? {};
  const drives = [...new Set(rows.map(r => String(r.drive)))].sort();
  // one row per step with a column per drive and figure, for the charts
  const byAt = new Map<string, Row>();
  for (const r of rows) {
    const k = String(r.snapshot_at);
    const o = byAt.get(k) ?? { snapshot_at: r.snapshot_at };
    for (const f of ['read_ms', 'write_ms', 'read_mb_s', 'write_mb_s', 'iops']) o[`${String(r.drive)}|${f}`] = r[f];
    byAt.set(k, o);
  }
  const wide = [...byAt.values()].sort((a, b) => String(a.snapshot_at).localeCompare(String(b.snapshot_at)));
  const ser = (f: string, w: string) => drives.map(dr => ({ key: `${dr}|${f}`, label: `${dr} ${w}` }));
  const src = m.engine === 'sqlserver' ? 'the database files\' virtual file stats, each file on the drive mssql_files names'
    : 'system_stats\' device counters (an on-prem host with system_stats; RDS and Aurora have no device read: the IO page has CloudWatch\'s volume figures)';
  // the drive's averages over the range
  const sum = drives.map(dr => {
    const mine = rows.filter(r => String(r.drive) === dr);
    const avg = (f: string) => { const v = mine.map(r => r[f]).filter(x => x != null).map(Number); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : null; };
    return { drive: dr, read_ms: avg('read_ms'), write_ms: avg('write_ms'), read_mb_s: avg('read_mb_s'), write_mb_s: avg('write_mb_s'), iops: avg('iops'), steps: mine.length };
  });
  const n2 = (v: unknown) => v == null ? '' : Number(v).toFixed(2);
  sec.append(el('p', { class: 'meta' }, `Per drive, from ${src}; ${fmtNum(m.step_secs ?? 0)}-second steps.`),
    grid(sum, [{ key: 'drive' }, { key: 'read_ms', label: 'read latency (ms)', num: true, fmt: n2 }, { key: 'write_ms', label: 'write latency (ms)', num: true, fmt: n2 },
      { key: 'read_mb_s', label: 'read MB/s', num: true, fmt: n2 }, { key: 'write_mb_s', label: 'write MB/s', num: true, fmt: n2 },
      { key: 'iops', label: 'IOPS', num: true, fmt: n2 }, { key: 'steps', num: true }], 'No drive IO read in this range.'),
    lineChart('Read latency (ms)', wide, ser('read_ms', 'read'), v => v.toFixed(1)),
    lineChart('Write latency (ms)', wide, ser('write_ms', 'write'), v => v.toFixed(1)),
    lineChart('Throughput (MB/s)', wide, [...ser('read_mb_s', 'read'), ...ser('write_mb_s', 'write')], v => v.toFixed(2)));
  return sec;
}

// ---- Temp (a PostgreSQL instance): TempDB's place in the strip (task 176b). The temp files the server wrote over the
// page's range, from the Memory page's reads (GET /api/memory): by database (pg_stat_database's temp_files and
// temp_bytes: every temp file, logged or not), by statement (pg_stat_statements' temp blocks per hour) and by hour
// (those summed beside the log's temporary-file lines and the data size).
export async function pgTempView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Temp (${rangeLabel(ctx)})`));
  type TempParts = 'temp_statements' | 'temp_hours' | 'temp_databases';
  try {
    const d = await get<Parts<TempParts>>('memory', { instance: ctx.instance, ...window_(ctx) });
    const dbCols: Col[] = [
      { key: 'datname', label: 'database' }, { key: 'temp_files', label: 'temp files', num: true, fmt: fmtNum },
      { key: 'temp_bytes', label: 'temp bytes', num: true, fmt: fmtBytes },
      { key: 'peak_bytes_s', label: 'peak per second', num: true, fmt: v => v == null ? '' : fmtBytes(v) + '/s' },
    ];
    const stmtCols: Col[] = [
      { key: 'queryid', label: 'query id' }, { key: 'datname', label: 'database' }, { key: 'usename', label: 'user' },
      { key: 'temp_written_bytes', label: 'written', num: true, fmt: fmtBytes }, { key: 'temp_read_bytes', label: 'read', num: true, fmt: fmtBytes },
      { key: 'worst_hour_bytes', label: 'worst hour', num: true, fmt: fmtBytes }, { key: 'hours', num: true },
      { key: 'query', wide: true },
    ];
    const hours = rowsOf(d.temp_hours);
    const hourCols: Col[] = [
      { key: 'snapshot_at', label: 'hour', fmt: fmtTime }, { key: 'temp_written_bytes', label: 'written by statements', num: true, fmt: fmtBytes },
      { key: 'log_files', label: 'files logged', num: true, fmt: fmtNum }, { key: 'log_bytes', label: 'bytes logged', num: true, fmt: fmtBytes },
      { key: 'log_max_file_bytes', label: 'largest file', num: true, fmt: fmtBytes }, { key: 'data_bytes', label: 'data size', num: true, fmt: fmtBytes },
      { key: 'data_pct', label: '% of the data', num: true },
    ];
    sec.append(
      el('p', { class: 'meta' }, 'A sort or hash that does not fit work_mem writes temp files: PostgreSQL\'s TempDB. By database: every temp file over the range '
        + '(pg_stat_database); by statement: pg_stat_statements\' temp blocks per hour; by hour: those summed beside the log\'s temporary-file lines '
        + '(only files at or above log_temp_files are logged).'),
      el('h3', {}, 'Temp files by database'), grid(rowsOf(d.temp_databases), dbCols, 'No database statistics in this range.'),
      el('h3', {}, 'By statement'), grid(rowsOf(d.temp_statements), stmtCols, 'No statement spilled to temp files in this range.'),
      el('h3', {}, 'By hour'),
      lineChart('Temp bytes per hour', hours, [{ key: 'temp_written_bytes', label: 'written by statements' }, { key: 'log_bytes', label: 'logged' }], v => fmtBytes(v)),
      grid(hours, hourCols, 'No hour rolled up in this range (the temp_files collection runs hourly).'));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
