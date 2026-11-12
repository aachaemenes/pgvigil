// Reports by e-mail (task 171; DBA Dash's report subscriptions): any page mailed now or on a schedule, the mail the
// page itself. buildMail reads the grids on the screen as the export does (export.ts sections: the same cells, the same
// hidden columns left out, the same colours carried) and writes each with the grid tools' HTML copy (gridtools.ts
// toHtml: every colour in the cell's own style), under the export's header lines (the instance, the page, the window,
// the time zone), and the same page's workbook (export.ts workbook) as the attachment: one renderer, so the mail
// equals the window. The bar's 'Mail...' (mailButton) sends the page now (POST /api/reportmail/send) or opens a schedule
// for it; the root page 'Report mail' (reportMailView) lists the schedules with their last send, the sends of the
// window and every attempt, and holds the schedule form. A schedule's turn is drawn by the server in a headless
// browser: the page opens with its render key (mailRenderBoot, before the shell's first render), waits until it has
// drawn, builds the same mail and posts it back (POST /api/reportmail/rendered). The mail is sent by the alert sender
// (pgvigil run) through an smtp channel of the alerts: block; this page shows each send's answer.
import { get, post, Row, rowsOf, Table } from './api';
import { Meta, Section, exportName, sections, timeZone, workbook, zip } from './export';
import { fleet } from './fleet';
import { toHtml } from './gridtools';
import { Ctx, drillTabs, instanceTabs, mssqlInstanceTabs, parse, rangeLabel, rootTabs, window_ } from './router';
import { browserZone, stamp, zoneName, zones } from './tz';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtTime, grid } from './ui';

interface Door {
  writable: boolean; reason?: string; user: string; browser: boolean; browser_reason?: string;
  max_html: number; max_xlsx: number; max_recipients: number; min_gap_secs: number;
}
interface MailData { door: Door; schedules?: Table | null; sends?: Table | null; channels?: Table | null; log?: Table | null; send?: Table | null }
interface WriteResult { outcome: string; detail: string; send_id?: number | null; schedule_id?: number | null }

// MailBody: what a page's mail is, as the server takes it
export interface MailBody {
  name: string; route: string; subject: string; window: string; html: string; xlsx: string; xlsx_name: string; grids: number; rows: number;
}

const KEY = /([?&])mailrender=([0-9a-f]{48})(&|$)/;

// ---- the mail -------------------------------------------------------------------------------------------------

const esc = (v: string) => v.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const FONT = 'font-family:Calibri,Arial,sans-serif';

async function metaOf(ctx: Ctx): Promise<Meta> {
  let instance = ctx.tag ? 'tag ' + ctx.tag : 'fleet';
  if (ctx.instance) {
    instance = 'instance ' + ctx.instance;
    try { const r = (await fleet()).instances.find(x => Number(x.instance_id) === ctx.instance); if (r) instance = String(r.name); } catch { /* the id stands */ }
  }
  const w = window_(ctx);
  const tab = (ctx.instance ? instanceTabs[ctx.tab] ?? mssqlInstanceTabs[ctx.tab] ?? drillTabs[ctx.tab] : rootTabs[ctx.tab]) ?? ctx.tab;
  return { instance, tab, from: new Date(w.from), to: new Date(w.to), window: rangeLabel(ctx), at: new Date() };
}

// numbers: per grid of root, in sections()' order, which of its shown columns are number columns (right-aligned in
// the mail as on the screen); a property card has none
function numbers(root: ParentNode): boolean[][] {
  return [...root.querySelectorAll<HTMLTableElement>('h2, h3, h4, table.grid, table.props')].filter(e => e.tagName === 'TABLE').map(t => {
    if (!t.classList.contains('grid')) return [false, false];
    return [...t.querySelectorAll(':scope > thead > tr:first-child > th')].filter(h => !h.hasAttribute('data-gt-hidden')).map(h => h.classList.contains('num'));
  });
}

// mailHtml: the whole mail body. Tables and inline styles only (a mail client takes no stylesheet and runs nothing):
// the header lines as the workbook's Summary sheet has them, then each grid under its heading as toHtml writes it.
export function mailHtml(m: Meta, secs: Section[], nums: boolean[][], title: string): string {
  const cell = 'border:1px solid #c8ccd4;padding:3px 8px;font-size:11pt;' + FONT + ';white-space:nowrap';
  const line = (k: string, v: string) => `<tr><th style="${cell};background:#0063a3;color:#ffffff;font-weight:bold;text-align:left">${esc(k)}</th><td style="${cell};color:#1d1d1f">${esc(v)}</td></tr>`;
  const head = '<table role="presentation" style="border-collapse:collapse;margin:0 0 10px 0">'
    + line('Instance', m.instance) + line('Page', m.tab) + line('Window', m.window)
    + line('Window from', stamp(m.from)) + line('Window to', stamp(m.to)) + line('Made at', stamp(m.at))
    + line('Time zone', timeZone(m.at)) + '</table>';
  const parts = secs.map((s, i) => {
    const h = `<h3 style="margin:16px 0 4px 0;font-size:13pt;font-weight:bold;${FONT};color:#0063a3">${esc(s.name)}</h3>`;
    const note = s.note ? `<p style="margin:2px 0 4px 0;font-size:9pt;${FONT};color:#5f6368">${esc(s.note)}</p>` : '';
    const empty = s.rows.length ? '' : `<p style="margin:2px 0 4px 0;font-size:10pt;${FONT};color:#5f6368">No rows.</p>`;
    return h + note + toHtml({ cols: s.cols, rows: s.rows, num: nums[i] }) + empty;
  }).join('');
  return '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
    + `<title>${esc(title)}</title></head>`
    + `<body style="margin:0;padding:12px;background:#ffffff;color:#1d1d1f;font-size:11pt;${FONT}">`
    + `<h2 style="margin:0 0 8px 0;font-size:15pt;font-weight:bold;${FONT};color:#1d1d1f">${esc(title)}</h2>`
    + head + parts
    + `<p style="margin:16px 0 0 0;font-size:9pt;${FONT};color:#5f6368">Sent by pgvigil: the page as it showed at ${esc(stamp(m.at))} (${esc(zoneName())}). The workbook attached holds the same rows.</p>`
    + '</body></html>';
}

function b64(b: Uint8Array): string {
  let s = '';
  for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000));
  return btoa(s);
}

// routeOf: the page's address as a schedule keeps it (the render key never part of it)
export function routeOf(hash = location.hash): string {
  const h = hash.replace(KEY, (_, a: string, _k: string, b: string) => (b ? a : '')).replace(/[?&]$/, '');
  return h.startsWith('#/') ? h : '#/summary';
}

// buildMail: the page under root as a mail: the HTML body and the workbook, its name, the window's words
export async function buildMail(ctx: Ctx, root: HTMLElement | null): Promise<MailBody> {
  const m = await metaOf(ctx);
  const secs = root ? sections(root, m.tab) : [];
  if (!secs.length) throw new Error('nothing to mail: no grid on this page');
  const nums = numbers(root!);
  const win = `${m.window} (${stamp(m.from)} to ${stamp(m.to)}, ${zoneName()})`;
  const title = `${m.tab} - ${m.instance}`;
  const z = await zip(workbook(m, secs), m.at);
  const xlsx = b64(new Uint8Array(await z.arrayBuffer()));
  return {
    name: title, route: routeOf(), subject: `pgvigil: ${title} - ${win}`, window: win,
    html: mailHtml(m, secs, nums, title), xlsx, xlsx_name: exportName(m, 'xlsx'),
    grids: secs.length, rows: secs.reduce((n, s) => n + s.rows.length, 0),
  };
}

// ---- the headless render ----------------------------------------------------------------------------------------

const sleep = (ms: number) => new Promise(r => window.setTimeout(r, ms));

// settled: the page has drawn (#main holds something that is not a Loading line) and has not changed for 1.5 s
async function settled(limitMs = 60000): Promise<void> {
  const t0 = Date.now();
  let last = '', since = Date.now();
  while (Date.now() - t0 < limitMs) {
    await sleep(250);
    const m = document.getElementById('main');
    const busy = !m || m.children.length === 0 || [...m.querySelectorAll('p.empty')].some(p => /^Loading/.test(p.textContent ?? ''));
    const now = m ? `${m.innerHTML.length}:${m.querySelectorAll('table.grid > tbody > tr').length}` : '';
    if (now !== last || busy) { last = now; since = Date.now(); continue; }
    if (Date.now() - since >= 1500) return;
  }
  throw new Error(`the page did not settle in ${limitMs / 1000} s`);
}

// mailRenderBoot: called once before the shell's first render. With a render key in the address (the server opened
// this page headless for a schedule's turn) the key leaves the address, and once the page has drawn its mail is
// built and posted back. true = this is a render.
export function mailRenderBoot(): boolean {
  const k = KEY.exec(location.hash);
  if (!k) return false;
  const key = k[2];
  history.replaceState(null, '', location.pathname + location.search + routeOf());
  void (async () => {
    try {
      await settled();
      const main = document.getElementById('main');
      if (!main?.querySelector('table.grid, table.props')) throw new Error('the page drew no grid: ' + (main?.textContent ?? '').replace(/\s+/g, ' ').trim().slice(0, 300));
      const body = await buildMail(parse(), main);
      await post('reportmail/rendered', { key, ...body });
    } catch (e) {
      try { await post('reportmail/rendered', { key, error: e instanceof Error ? e.message : String(e) }); } catch { /* the server's wait ends the render */ }
    }
  })();
  return true;
}

// ---- the forms ----------------------------------------------------------------------------------------------------

let doorCache: { at: number; d: MailData } | undefined;
async function door(force = false): Promise<MailData> {
  if (!force && doorCache && Date.now() - doorCache.at < 30000) return doorCache.d;
  const d = await get<MailData>('reportmail', { part: 'channels' });
  doorCache = { at: Date.now(), d };
  return d;
}

// gridPrefs: the grid tools' choices kept in this browser for the page's tab (gridtools.ts keys them
// 'pgvigil.grid.<tab>.<grid>'): a schedule of the page takes them, so its render hides, freezes and bars the same columns
export function gridPrefs(hash = location.hash): Record<string, string> {
  const tab = /^#\/([A-Za-z_]+)/.exec(hash)?.[1] ?? 'summary', out: Record<string, string> = {};
  try {
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (k && k.startsWith(`pgvigil.grid.${tab}.`)) out[k] = localStorage.getItem(k) ?? '';
    }
  } catch { /* a browser that keeps nothing: no choices to carry */ }
  return out;
}

const addrList = (v: string) => v.split(/[\s,;]+/).map(x => x.trim()).filter(Boolean);
const message = (e: unknown) => e instanceof Error ? e.message : String(e);

// dialog: one modal form; run answers with the server's words or throws its refusal. invalid: what is missing.
function dialog(title: string, what: string | Node, go: string, fields: HTMLElement[], run: () => Promise<string>, invalid: () => string = () => '',
  extra: HTMLElement[] = [], after: () => void = () => { /* nothing to redraw */ }) {
  const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  const ok = el('button', { type: 'submit' }, go);
  const no = el('button', { type: 'button' }, 'Back');
  const need = el('p', { class: 'meta' });
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  let busy = false, done = false;
  const check = () => { const w = done ? '' : invalid(); need.textContent = w ? `${go} needs ${w}.` : ''; ok.disabled = busy || done || w !== ''; };
  const form = el('form', { method: 'dialog' }, el('h3', {}, title), el('p', {}, what),
    ...fields.map(f => el('div', { style: 'margin:.3rem 0' }, f)), need, msg, el('div', { style: 'margin-top:.6rem' }, ok, ' ', ...extra.flatMap(x => [x, ' ']), no));
  form.addEventListener('input', check);
  form.addEventListener('change', check);
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:46rem', 'aria-label': title }, form);
  const leave = () => { dlg.remove(); if (done) after(); else if (opener?.isConnected) opener.focus(); };
  no.addEventListener('click', () => { dlg.close(); leave(); });
  dlg.addEventListener('cancel', leave);
  form.addEventListener('submit', ev => {
    ev.preventDefault();
    if (busy || done) return;
    busy = true; check();
    msg.textContent = 'Working...';
    void run().then(words => {
      done = true;
      msg.replaceChildren(badge('done', 'ok'), ' ', words);
      no.textContent = 'Close';
    }, e => {
      msg.replaceChildren(badge('not done', 'crit'), ' ', message(e));
    }).finally(() => { busy = false; check(); });
  });
  document.body.append(dlg);
  check();
  dlg.showModal();
  (dlg.querySelector('input,select,textarea,button') as HTMLElement | null)?.focus();
  return { msg, close: () => { dlg.close(); leave(); } };
}

function channelSelect(d: MailData, value = ''): HTMLSelectElement {
  const chs = rowsOf(d.channels);
  const s = el('select', { required: '' });
  if (!chs.length) s.append(el('option', { value: '' }, 'no smtp channel in the alerts: block'));
  for (const c of chs) s.append(el('option', { value: String(c.name) }, `${String(c.name)} (${String(c.destination)})`));
  if (value) { if (!chs.some(c => c.name === value)) s.append(el('option', { value }, `${value} (not configured now)`)); s.value = value; }
  return s;
}

// watchSend: one queued mail's answer, read every 3 s for up to 3 minutes into the line given
async function watchSend(id: number, line: HTMLElement) {
  for (let i = 0; i < 60; i++) {
    await sleep(3000);
    if (!line.isConnected) return;
    let r: Row | undefined;
    try { r = rowsOf((await get<MailData>('reportmail', { part: 'send', id })).send)[0]; } catch { continue; }
    if (!r) return;
    const out = String(r.outcome);
    if (out === 'queued') continue;
    line.replaceChildren(outcomeBadge(out), ' ', out === 'sent'
      ? `mail ${id} sent to ${String(r.recipients)}: ${fmtNum(r.rows)} rows, ${fmtBytes(r.mail_bytes)}`
      : `mail ${id}: ${String(r.error ?? out)}`);
    return;
  }
  line.append(' (no answer yet: is pgvigil run up with this smtp channel? The Report mail page shows the send when it is answered)');
}

function outcomeBadge(out: string): HTMLElement {
  return badge(out, out === 'sent' ? 'ok' : out === 'failed' ? 'crit' : out === 'queued' ? 'none' : 'warn');
}

// mailButton: the bar's 'Mail...' for the page under it: send it now, or schedule it
export function mailButton(ctx: Ctx, root: () => HTMLElement | null = () => document.getElementById('main')): HTMLElement {
  const b = el('button', { type: 'button', title: 'Mail this page as it shows now (its grids in their colours and the workbook), or send it on a schedule' }, 'Mail...');
  b.addEventListener('click', () => { void openMail(ctx, root); });
  return el('span', { class: 'mail' }, b);
}

async function openMail(ctx: Ctx, root: () => HTMLElement | null) {
  let d: MailData;
  try { d = await door(); } catch (e) { window.alert('Report mail could not load: ' + message(e)); return; }
  const m = await metaOf(ctx);
  const title = `${m.tab} - ${m.instance}`;
  const to = el('textarea', { rows: '2', style: 'width:100%', placeholder: 'dba@example.org, oncall@example.org' });
  const chan = channelSelect(d);
  const subj = el('input', { type: 'text', maxlength: '200', style: 'width:100%', value: `pgvigil: ${title} - ${m.window}` });
  const attach = el('input', { type: 'checkbox' });
  attach.checked = true;
  const fields = [el('label', {}, 'To (one or more addresses) ', to), el('label', {}, 'Channel (the alerts: smtp relay) ', chan),
    el('label', {}, 'Subject ', subj), el('label', {}, attach, ' attach the workbook (.xlsx)')];
  const sched = el('button', { type: 'button' }, 'Schedule this page...');
  const w = d.door;
  const what = w.writable
    ? `The grids of this page as they show now, in their colours, with the workbook attached; at most ${fmtBytes(w.max_html)} of body and ${fmtBytes(w.max_xlsx)} of workbook. The alert sender (pgvigil run) mails it within a minute.`
    : `Report mail is off here: ${w.reason ?? ''}`;
  const invalid = () => !w.writable ? 'report mail on' : !addrList(to.value).length ? 'an address' : !chan.value ? 'an smtp channel' : '';
  const { msg } = dialog('Mail this page', what, 'Send now', fields, async () => {
    const body = await buildMail(ctx, root());
    const res = await post<WriteResult>('reportmail/send', { ...body, subject: subj.value.trim() || body.subject, recipients: addrList(to.value), channel: chan.value,
      xlsx: attach.checked ? body.xlsx : '' });
    if (res.send_id) void watchSend(Number(res.send_id), msg);
    return `${res.detail} (${fmtNum(body.rows)} rows in ${fmtNum(body.grids)} grid${body.grids === 1 ? '' : 's'})`;
  }, invalid, [sched]);
  sched.disabled = !w.writable;
  sched.addEventListener('click', () => {
    (sched.closest('dialog') as HTMLDialogElement | null)?.close();
    sched.closest('dialog')?.remove();
    void scheduleDialog({ route: routeOf(), page: title, name: title, recipients: addrList(to.value).join(', '), channel: chan.value, fixed: !ctx.range.preset, prefs: gridPrefs() });
  });
}

const dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

// cadenceOf: a stored cron line back as the form's cadence, time and days
function cadenceOf(cadence: string, cron: string): { cadence: string; at: string; days: number[] } {
  const f = cron.trim().split(/\s+/);
  const two = (v: string) => v.padStart(2, '0');
  if (f.length === 5 && /^\d+$/.test(f[0]) && /^\d+$/.test(f[1]) && f[2] === '*' && f[3] === '*') {
    if (cadence === 'daily' && f[4] === '*') return { cadence, at: `${two(f[1])}:${two(f[0])}`, days: [] };
    if (cadence === 'weekly' && /^[0-6](,[0-6])*$/.test(f[4])) return { cadence, at: `${two(f[1])}:${two(f[0])}`, days: f[4].split(',').map(Number) };
  }
  return { cadence: 'cron', at: '07:00', days: [] };
}

export function cadenceWords(cadence: unknown, cron: unknown): string {
  const c = cadenceOf(String(cadence ?? ''), String(cron ?? ''));
  if (c.cadence === 'daily') return `daily at ${c.at}`;
  if (c.cadence === 'weekly') return `weekly on ${c.days.map(d => dayNames[d]).join(', ')} at ${c.at}`;
  return `cron ${String(cron ?? '')}`;
}

interface SchedulePrefill { schedule?: Row; route?: string; page?: string; name?: string; recipients?: string; channel?: string; fixed?: boolean; prefs?: Record<string, string> }

// scheduleDialog: the one form a schedule is made or changed through
export async function scheduleDialog(p: SchedulePrefill, after: () => void = redraw) {
  let d: MailData;
  try { d = await door(true); } catch (e) { window.alert('Report mail could not load: ' + message(e)); return; }
  const s = p.schedule;
  const name = el('input', { type: 'text', maxlength: '120', style: 'width:100%', value: String(s?.name ?? p.name ?? '') });
  const route = el('input', { type: 'text', maxlength: '500', style: 'width:100%', spellcheck: 'false', value: String(s?.route ?? p.route ?? '#/summary') });
  const to = el('textarea', { rows: '2', style: 'width:100%' });
  to.value = s ? (s.recipient_list as string[] | null ?? []).join(', ') : p.recipients ?? '';
  const chan = channelSelect(d, String(s?.channel ?? p.channel ?? ''));
  const c0 = cadenceOf(String(s?.cadence ?? 'daily'), String(s?.cron ?? '0 7 * * *'));
  const cad = el('select', {}, el('option', { value: 'daily' }, 'daily'), el('option', { value: 'weekly' }, 'weekly'), el('option', { value: 'cron' }, 'a cron line'));
  cad.value = c0.cadence;
  const at = el('input', { type: 'time', value: c0.at, step: '60' });
  const days = dayNames.map((n, i) => { const x = el('input', { type: 'checkbox', value: String(i) }); x.checked = c0.days.includes(i); return { x, l: el('label', { style: 'margin-right:.6rem' }, x, ' ' + n) }; });
  const cron = el('input', { type: 'text', maxlength: '100', spellcheck: 'false', value: c0.cadence === 'cron' ? String(s?.cron ?? '') : '', placeholder: '0 7 * * 1-5' });
  const tz = el('select', {});
  const zs = zones(), want = String(s?.timezone ?? browserZone());
  if (!zs.includes(want)) zs.unshift(want);
  for (const z of zs) tz.append(el('option', { value: z }, z));
  tz.value = want;
  const attach = el('input', { type: 'checkbox' });
  attach.checked = s ? s.attach_xlsx !== false : true;
  const on = el('input', { type: 'checkbox' });
  on.checked = s ? s.enabled !== false : true;
  const atBox = el('label', {}, 'At ', at), daysBox = el('fieldset', { style: 'border:0;padding:0;margin:0' }, el('legend', {}, 'On'), ...days.map(x => x.l)), cronBox = el('label', {}, 'Cron line (minute hour day month weekday, pg_cron\'s grammar) ', cron);
  const sync = () => { atBox.hidden = cad.value === 'cron'; daysBox.hidden = cad.value !== 'weekly'; cronBox.hidden = cad.value !== 'cron'; };
  cad.addEventListener('change', sync);
  sync();
  const fixedNote = el('p', { class: 'meta' });
  const noteFixed = () => { fixedNote.textContent = /[?&]from=/.test(route.value) && /[?&]to=/.test(route.value) ? 'This page has a fixed window (from / to): every send shows the same hours. A preset window (w=24h, w=today ...) follows each send.' : ''; };
  route.addEventListener('input', noteFixed);
  noteFixed();
  const w = d.door;
  const nPrefs = Object.keys(p.prefs ?? {}).length;
  const prefsNote = el('p', { class: 'meta' }, nPrefs ? `The page's grid choices in this browser (${nPrefs} grid${nPrefs === 1 ? '' : 's'}: hidden, frozen and barred columns) are kept with the schedule: its mail leaves out what your window leaves out.`
    : s ? 'The grid choices kept with the schedule stay as they are.' : 'No grid choice of this browser is kept: the mail shows every column of the page.');
  const fields = [el('label', {}, 'Name (the subject starts with it) ', name), el('label', {}, 'Page (its address in this UI, as the bar\'s Mail... takes it) ', route), fixedNote, prefsNote,
    el('label', {}, `To (one or more addresses, at most ${w.max_recipients}) `, to), el('label', {}, 'Channel (the alerts: smtp relay) ', chan),
    el('label', {}, 'Cadence ', cad), atBox, daysBox, cronBox, el('label', {}, 'Time zone ', tz),
    el('label', {}, attach, ' attach the workbook (.xlsx)'), el('label', {}, on, ' on')];
  const invalid = () => !w.writable ? 'report mail on' : !name.value.trim() ? 'a name' : !/^#\/[A-Za-z0-9_]+/.test(route.value.trim()) ? 'the page\'s address (#/...)'
    : !addrList(to.value).length ? 'an address' : !chan.value ? 'an smtp channel' : cad.value === 'weekly' && !days.some(x => x.x.checked) ? 'a day'
      : cad.value === 'cron' && cron.value.trim().split(/\s+/).length !== 5 && !cron.value.trim().startsWith('@') ? 'a cron line of five fields' : '';
  const what = w.writable
    ? `The page is drawn on the server in a headless browser as you (${w.user}) at each send, so the mail is that page then: its grids in their colours and its workbook. At most one send every ${Math.round(w.min_gap_secs / 60)} minutes.${w.browser ? '' : ' ' + (w.browser_reason ?? '')}`
    : `Report mail is off here: ${w.reason ?? ''}`;
  dialog(s ? `Change schedule ${String(s.schedule_id)}` : 'New report mail schedule', what, s ? 'Save' : 'Add', fields, async () => {
    const res = await post<WriteResult>('reportmail', {
      op: s ? 'edit' : 'add', schedule_id: s ? Number(s.schedule_id) : undefined, name: name.value.trim(), route: route.value.trim(), page: p.page ?? String(s?.page ?? ''),
      recipients: addrList(to.value), channel: chan.value, cadence: cad.value, at: at.value, days: days.filter(x => x.x.checked).map(x => Number(x.x.value)),
      cron: cron.value.trim(), timezone: tz.value, attach_xlsx: attach.checked, enabled: on.checked,
      ...(p.prefs ? { grid_prefs: p.prefs } : {}),
    });
    return res.detail;
  }, invalid, [], after);
}

const redraw = () => window.dispatchEvent(new HashChangeEvent('hashchange'));

async function act(op: string, id: unknown, words: string): Promise<string> {
  const res = await post<WriteResult>('reportmail', { op, schedule_id: Number(id) });
  return res.detail || words;
}

// ---- the page --------------------------------------------------------------------------------------------------

const whenCol = (key: string, label: string): Col => ({ key, label, fmt: v => v == null ? '' : fmtTime(v) });

// reportMailView: the root page 'Report mail'
export async function reportMailView(ctx: Ctx): Promise<HTMLElement> {
  const w = window_(ctx);
  let d: MailData;
  try { d = await get<MailData>('reportmail', { from: w.from, to: w.to }); } catch (e) { return errorBox(e); }
  doorCache = { at: Date.now(), d };
  const door0 = d.door;
  const box = el('section', { 'aria-label': 'Report mail' });
  box.append(el('h2', {}, 'Report mail'),
    el('p', { class: 'meta' }, 'Any page mailed now (the bar\'s Mail... on the page) or on a schedule (below): the mail body is the page\'s grids in the colours, numbers and dates the screen shows, and the page\'s workbook is attached. The alert sender (pgvigil run) mails it through an smtp channel of the alerts: block.'),
    el('p', {}, door0.writable ? badge('on', 'ok') : badge('off', 'warn'), ' ', door0.writable ? `signed in as ${door0.user}` : door0.reason ?? '',
      door0.writable && !door0.browser ? ' ' : '', door0.writable && !door0.browser ? badge('no browser', 'warn') : '', door0.writable && !door0.browser ? ' ' + (door0.browser_reason ?? '') : ''));
  const add = el('button', { type: 'button' }, 'New schedule...');
  add.disabled = !door0.writable;
  if (!door0.writable) add.title = door0.reason ?? '';
  add.addEventListener('click', () => { void scheduleDialog({}); });
  box.append(el('p', {}, add));

  const button = (label: string, aria: string, run: () => void) => {
    const b = el('button', { type: 'button', class: 'link', 'aria-label': aria }, label);
    if (!door0.writable) b.disabled = true; else b.addEventListener('click', run);
    return b;
  };
  const confirmAct = (title: string, what: string, go: string, op: string, id: unknown) => dialog(title, what, go, [], () => act(op, id, go), () => '', [], redraw);
  const sched: Col[] = [
    { key: 'name', label: 'name' },
    { key: 'page', label: 'page', fmt: (v, r) => el('a', { href: String(r.route) }, String(v || r.route)) },
    { key: 'recipients', label: 'to', wide: true },
    { key: 'channel', label: 'channel' },
    { key: 'cron', label: 'when', fmt: (v, r) => cadenceWords(r.cadence, v) },
    { key: 'timezone', label: 'time zone' },
    { key: 'attach_xlsx', label: 'workbook', fmt: v => v ? 'yes' : 'no' },
    { key: 'enabled', label: 'on', fmt: v => v ? badge('on', 'ok') : badge('off', 'none') },
    whenCol('next_at', 'next send'),
    whenCol('last_at', 'last send'),
    { key: 'last_outcome', label: 'last outcome', fmt: v => v == null ? '' : outcomeBadge(String(v)) },
    { key: 'last_error', label: 'last error', wide: true },
    { key: 'schedule_id', label: 'actions', fmt: (v, r) => el('span', {},
      button('Edit', `Change schedule ${String(r.name)}`, () => { void scheduleDialog({ schedule: r }); }), ' ',
      button('Send test', `Send a test of schedule ${String(r.name)} now`, () => {
        dialog(`Send a test of ${String(r.name)}`, `The page is drawn now on the server as you and mailed to ${String(r.recipients)} with [test] in its subject.`, 'Send test', [],
          async () => (await post<WriteResult>('reportmail/test', { schedule_id: Number(v) })).detail, () => '', [], redraw);
      }), ' ',
      button(r.enabled ? 'Turn off' : 'Turn on', `${r.enabled ? 'Turn off' : 'Turn on'} schedule ${String(r.name)}`, () => {
        confirmAct(`${r.enabled ? 'Turn off' : 'Turn on'} ${String(r.name)}`, r.enabled ? 'No mail goes out until it is turned on again.' : 'The next send is the cron line\'s next time.', r.enabled ? 'Turn off' : 'Turn on', r.enabled ? 'disable' : 'enable', v);
      }), ' ',
      button('End', `End schedule ${String(r.name)}`, () => { confirmAct(`End ${String(r.name)}`, 'The schedule ends for good; its sends stay in the log.', 'End', 'end', v); })) },
  ];
  box.append(el('h3', {}, 'Schedules'), grid(rowsOf(d.schedules), sched, 'No schedule yet: open a page, press Mail... and Schedule this page, or New schedule above.'));

  const sends: Col[] = [
    whenCol('requested_at', 'asked'),
    { key: 'kind', label: 'kind' },
    { key: 'name', label: 'report' },
    { key: 'requested_by', label: 'by' },
    { key: 'recipients', label: 'to', wide: true },
    { key: 'channel', label: 'channel' },
    { key: 'subject', label: 'subject', wide: true },
    { key: 'grids', label: 'grids', num: true, fmt: v => v == null ? '' : fmtNum(v) },
    { key: 'rows', label: 'rows', num: true, fmt: v => v == null ? '' : fmtNum(v) },
    { key: 'mail_bytes', label: 'size', num: true, fmt: (v, r) => v != null ? fmtBytes(v) : r.html_bytes != null ? fmtBytes(Number(r.html_bytes) + Number(r.xlsx_bytes ?? 0)) : '' },
    whenCol('done_at', 'answered'),
    { key: 'outcome', label: 'outcome', fmt: v => outcomeBadge(String(v)) },
    { key: 'error', label: 'error', wide: true },
  ];
  box.append(el('h3', {}, `Sends (${rangeLabel(ctx)})`), grid(rowsOf(d.sends), sends, 'No mail in this window.'));

  const log: Col[] = [
    whenCol('at', 'at'), { key: 'ui_user', label: 'user' }, { key: 'client', label: 'from' }, { key: 'op', label: 'op' },
    { key: 'schedule_id', label: 'schedule', num: true }, { key: 'send_id', label: 'send', num: true },
    { key: 'outcome', label: 'outcome', fmt: v => badge(String(v), v === 'done' ? 'ok' : 'warn') }, { key: 'detail', label: 'detail', wide: true },
  ];
  box.append(el('h3', {}, `Attempts (${rangeLabel(ctx)})`), grid(rowsOf(d.log), log, 'No attempt in this window.'));
  return box;
}
