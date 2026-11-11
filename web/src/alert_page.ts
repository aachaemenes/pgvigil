// The page of one alert (task 151, K07.02): #/alert?k=<finding key>[&t=<unix seconds>][&v=now|firing], the address
// every sent alert line carries (alerts_base_url in the configuration). It shows the alert's card (severity, instance,
// the finding now or the last value sent, its threshold or suggested value, this firing's first send, how many times
// it fired), the fix statement with Copy (pgvigil.finding_fix: none when the detail says what to do), every firing of
// the alert, every send attempt that carried it, and what people did with it (acknowledgements, notes, mutes,
// dismissals). The links to the instance's pages open pinned to the firing's window ('at the firing') or to the last
// hour ('now'); the export buttons keep the page as a workbook (the report). Data from /api/alerts?k= (q_alerts.go);
// the route is the shell's (a WIRING BLOCK: router.ts and main.ts).
import { get, post, Row, rowsOf, Table } from './api';
import { Ctx, href, MAX_RANGE_MS } from './router';
import { badge, Col, copyText, el, errorBox, fmtTime, grid, props } from './ui';
import { exportButtons } from './export';
import { loadAckSafe, AckData, writeButton } from './ack';
import { whatIsThis } from './sqlview';

interface AlertPageData { card: Table | null; occurrences: Table | null; sends: Table | null; notes: Table | null }

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const statusBadge = (v: unknown) => badge(String(v ?? ''), v === 'open' ? 'crit' : v === 'resolved' ? 'ok' : '');
const list = (v: unknown): string => Array.isArray(v) && v.length ? v.join(', ') : '';

// hashParam: one parameter of the page's own address
function hashParam(name: string): string | null {
  return new URLSearchParams(location.hash.split('?')[1] ?? '').get(name);
}

// alertHref: the address of an alert's page (the same form the sender writes into a message)
export function alertHref(key: unknown, at?: unknown): string {
  const q = new URLSearchParams({ k: String(key ?? '') });
  const t = at == null ? NaN : Date.parse(String(at));
  if (Number.isFinite(t)) q.set('t', String(Math.floor(t / 1000)));
  return `#/alert?${q}`;
}

// firingWindow: half an hour before the firing to half an hour after it cleared (open: to now), at most the server's
// longest window (the end is kept: the clearance is what a reader looks for)
export function firingWindow(firedAt: unknown, clearedAt: unknown, now = Date.now()): { from: string; to: string } {
  const f = Date.parse(String(firedAt ?? '')), c = clearedAt == null ? NaN : Date.parse(String(clearedAt));
  const to = Math.min(now, Number.isFinite(c) ? c + 1800e3 : now);
  const from = Math.max((Number.isFinite(f) ? f : now - 3600e3) - 1800e3, to - MAX_RANGE_MS);
  return { from: new Date(from).toISOString(), to: new Date(Math.max(to, from + 60e3)).toISOString() };
}

// pick: the firing the address names (the one whose period holds t), else the newest
function pick(occ: Row[], t: number | null): Row | undefined {
  if (t != null) {
    const hit = occ.find(o => {
      const f = Date.parse(String(o.fired_at)), c = o.cleared_at == null ? Infinity : Date.parse(String(o.cleared_at));
      return f - 120e3 <= t && t <= c;
    });
    if (hit) return hit;
  }
  return occ[0];
}

// instanceLinks: the instance's pages that explain an alert, opened on the window chosen
function instanceLinks(ctx: Ctx, instanceId: number, engine: unknown, win: { from: string; to: string } | null, firedAt: unknown, source: unknown): HTMLElement {
  const range = win ? { from: win.from, to: win.to } : { preset: '1h' };
  const mk = (tab: string, label: string, over: Partial<Ctx> = {}) => el('a', { href: href(ctx, { tab, instance: instanceId, range, ...over }) }, label);
  const links: HTMLElement[] = [mk('summary', 'Summary'), mk('findings', 'Findings'), mk('counters', 'Metrics'), mk('performance', 'Performance')];
  if (engine === 'sqlserver') links.push(mk('mssql_running', 'Running queries'), mk('mssql_waits', 'Waits'), mk('mssql_blocked', 'Blocked reports'));
  else {
    // the running queries at the firing: the activity snapshot nearest the first send
    const at = win && firedAt != null ? { at: new Date(Date.parse(String(firedAt))).toISOString() } : {};
    links.push(mk('activity', 'Running queries', at), mk('waits', 'Waits'), mk('logs', 'Logs'));
    if (String(source ?? '').includes('vacuum') || String(source ?? '') === 'pg_gather') links.push(mk('vacuum', 'Vacuum'), mk('config', 'Configuration'));
  }
  const out = el('p', { class: 'meta' }, win ? 'The instance at the firing: ' : 'The instance now: ');
  links.forEach((a, i) => { if (i) out.append(' · '); out.append(a); });
  return out;
}

// fixLine: the statement with its Copy button; a setting's note on reload and restart
function fixLine(fix: unknown): HTMLElement {
  const text = String(fix ?? '');
  const said = el('span', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const copy = el('button', { type: 'button', 'aria-label': 'Copy the fix statement' }, 'Copy');
  copy.addEventListener('click', async () => { said.textContent = (await copyText(text)) ? ' Copied.' : ' The browser refused the copy: select the text instead.'; });
  const box = el('div', { class: 'fix-line' }, el('h3', {}, 'Fix'),
    el('pre', { class: 'sql', style: 'white-space:pre-wrap;margin:.2rem 0' }, el('code', {}, text)), copy, said);
  if (text.startsWith('ALTER SYSTEM')) box.append(el('p', { class: 'meta' }, 'Run it as a superuser (on Aurora / RDS the parameter group holds the setting instead). A setting whose pg_settings.context is postmaster takes a restart besides the reload. pgvigil runs nothing: the statement is advice.'));
  else box.append(el('p', { class: 'meta' }, 'pgvigil runs nothing: the statement is advice, read it before you run it.'));
  return box;
}

// alertPageView: the page
export async function alertPageView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', { class: 'alert-page' });
  const key = hashParam('k') ?? '';
  if (!/^[0-9a-f]{32}$/.test(key)) {
    sec.append(el('h2', {}, 'Alert'), el('p', {}, 'This address names no alert: it is opened from a sent alert\'s link or from a row of the Alerts page.'),
      el('p', {}, el('a', { href: href(ctx, { tab: 'alerts', instance: undefined }) }, 'Alerts')));
    return sec;
  }
  const tq = Number(hashParam('t'));
  const t = Number.isFinite(tq) && tq > 0 ? tq * 1000 : null;
  let d: AlertPageData;
  try { d = await get<AlertPageData>('alerts', { k: key }); } catch (e) { sec.append(el('h2', {}, 'Alert'), errorBox(e)); return sec; }
  const card = rowsOf(d.card)[0], occ = rowsOf(d.occurrences), sends = rowsOf(d.sends), notes = rowsOf(d.notes);
  const o = pick(occ, t);
  if (!o && !card) {
    sec.append(el('h2', {}, 'Alert'), el('p', {}, 'No alert with this key is in the store: it was never sent, or its rows were purged (the purge window). The finding itself is not standing now either.'),
      el('p', {}, el('a', { href: href(ctx, { tab: 'alerts', instance: undefined }) }, 'Alerts')));
    return sec;
  }
  const head = o ?? card!;
  const instanceId = Number(head.instance_id) || 0;
  const name = [head.source, head.setting].filter(x => x != null && x !== '').map(String).join(': ');
  sec.append(el('h2', {}, `Alert - ${name}`),
    el('p', { class: 'meta' }, `${String(head.instance ?? '')}${o ? `, fired ${fmtTime(o.fired_at)}` : ', not sent yet'}. `,
      whatIsThis('One alert: a finding the sender sent on one or more channels. Its firings are grouped over the channels (a firing ends when every channel\'s alert of it has cleared). The value is the finding\'s now when it still stands, else the last value sent. The links open the instance pinned to the firing\'s window, or to the last hour with the now switch. Export keeps the page as a workbook.', 'Alert page')));

  // the now / at-firing switch: where the links point (the address keeps it: v=now)
  let view: 'firing' | 'now' = hashParam('v') === 'now' || !o ? 'now' : 'firing';
  const linksBox = el('div', {});
  const seg = el('div', { class: 'seg', role: 'group', 'aria-label': 'Read the instance at' });
  const bFiring = el('button', { type: 'button', class: 'toggle' }, 'at the firing'), bNow = el('button', { type: 'button', class: 'toggle' }, 'now');
  if (!o) bFiring.disabled = true;
  seg.append(bFiring, bNow);
  const win = o ? firingWindow(o.fired_at, o.cleared_at) : null;
  const drawLinks = () => {
    bFiring.setAttribute('aria-pressed', String(view === 'firing')); bNow.setAttribute('aria-pressed', String(view === 'now'));
    linksBox.replaceChildren(instanceId ? instanceLinks(ctx, instanceId, head.engine ?? card?.engine, view === 'firing' ? win : null, o?.fired_at, head.source)
      : el('p', { class: 'meta' }, 'The instance is no longer in the repository.'));
  };
  bFiring.addEventListener('click', () => { view = 'firing'; drawLinks(); });
  bNow.addEventListener('click', () => { view = 'now'; drawLinks(); });
  drawLinks();

  const door = await loadAckSafe(['log'], {});
  const dismissed = notes.find(n => n.kind === 'dismiss' && n.ended_at == null);
  const pairs: [string, string | Node][] = [
    ['Severity', sevBadge(card?.severity ?? head.severity)],
    ['Instance', instanceId ? el('a', { href: href(ctx, { tab: 'summary', instance: instanceId, range: win ? { from: win.from, to: win.to } : { preset: '1h' } }) }, String(head.instance ?? '')) : String(head.instance ?? '')],
    ['Alert', name],
    ['Value', card ? `${String(card.value ?? '')} (now)` : `${String(o?.value ?? '')} (last sent; the finding is gone now)`],
    ['Threshold', String(card?.threshold ?? o?.threshold ?? '') || 'none stated (a built-in check: its rule is in the detail)'],
    ['This firing', o ? `first sent ${fmtTime(o.fired_at)}, last sent ${fmtTime(o.last_sent_at)}, ${String(o.sends)} send(s) to ${list(o.channels)}` : 'not sent'],
    ['State', o ? el('span', {}, statusBadge(o.status), ' ', o.cleared_at != null ? `cleared ${fmtTime(o.cleared_at)}` : o.missing_since != null ? `the finding is gone since ${fmtTime(o.missing_since)} (waiting for the clear delay and a fresh read)` : 'standing') : 'not sent'],
    ['Firings', `${occ.length} in the store` + (occ.length > 1 ? `, the first ${fmtTime(occ[occ.length - 1].fired_at)}` : '')],
  ];
  if (card?.detail) pairs.push(['Detail', String(card.detail)]);
  if (card?.suggested) pairs.push(['Suggested', String(card.suggested)]);
  if (dismissed) pairs.push(['Dismissed', `by ${String(dismissed.by)} ${fmtTime(dismissed.at)}: ${String(dismissed.note ?? '')}`]);
  sec.append(el('div', { class: 'toolbar' }, seg, el('span', { class: 'meta' }, ' '), exportButtons(ctx, () => sec), copyLinkButton()), linksBox, props(pairs));
  if (card?.fix) sec.append(fixLine(card.fix));
  else if (card) sec.append(el('p', { class: 'meta' }, 'No fix statement: the detail says what to do (a fix statement is given for a PostgreSQL setting with a one-word suggested value, and for a maintenance statement the detail spells out).'));
  sec.append(dismissBar(door, key, dismissed));

  const occCols: Col[] = [
    { key: 'fired_at', label: 'fired', fmt: (v, r) => el('a', { href: alertHref(key, v), 'aria-label': `open firing ${String(r.occurrence)}` }, fmtTime(v)) },
    { key: 'cleared_at', label: 'cleared', fmt: fmtTime },
    { key: 'status', fmt: statusBadge },
    { key: 'severity', fmt: sevBadge },
    { key: 'value', wide: true },
    { key: 'threshold' },
    { key: 'channels', fmt: v => list(v) },
    { key: 'sends', num: true },
    { key: '_window', label: 'instance', fmt: (_v, r) => instanceId ? el('a', { href: href(ctx, { tab: 'summary', instance: instanceId, range: firingWindow(r.fired_at, r.cleared_at) }) }, 'open its window') : '' },
  ];
  sec.append(el('h3', {}, 'Firings of this alert'), grid(occ, occCols, 'Not sent yet: the finding stands, and no channel has sent it.'));
  const sendCols: Col[] = [
    { key: 'at', label: 'attempt', fmt: fmtTime },
    { key: 'channel' },
    { key: 'kind' },
    { key: 'destination', wide: true },
    { key: 'outcome', fmt: v => badge(String(v ?? ''), v === 'sent' ? 'ok' : v === 'failed' || v === 'refused' ? 'crit' : v === 'capped' ? 'warn' : '') },
    { key: 'n_firing', label: 'new', num: true },
    { key: 'n_repeat', label: 'repeated', num: true },
    { key: 'n_resolved', label: 'resolved', num: true },
    { key: 'error', wide: true },
  ];
  sec.append(el('h3', {}, 'Every send that carried it'), grid(sends, sendCols, 'No send attempt carried this alert.'));
  const noteCols: Col[] = [
    { key: 'at', label: 'when', fmt: fmtTime },
    { key: 'kind', fmt: v => ({ alert_ack: 'acknowledged', note: 'note', close: 'closed', mute: 'muted', noise: 'known pattern', dismiss: 'dismissed' } as Record<string, string>)[String(v)] ?? String(v ?? '') },
    { key: 'by' },
    { key: 'note', wide: true },
    { key: 'until', fmt: v => v == null ? '' : fmtTime(v) },
    { key: 'ended_at', label: 'ended', fmt: (v, r) => v == null ? (r.paused_at != null ? `paused ${fmtTime(r.paused_at)}` : '') : `${fmtTime(v)} by ${String(r.ended_by ?? '')}` },
  ];
  sec.append(el('h3', {}, 'What was done with it'), grid(notes, noteCols, 'Nobody acknowledged, noted, muted or dismissed this alert.'));
  return sec;
}

function copyLinkButton(): HTMLElement {
  const b = el('button', { type: 'button', title: 'Copy the address of this page' }, 'Copy link');
  b.addEventListener('click', async () => { b.textContent = (await copyText(location.href)) ? 'Link copied' : 'Copy refused'; });
  return b;
}

// dismissBar: dismiss the alert with a reason, or end its dismissal
function dismissBar(door: AckData, key: string, dismissed: Row | undefined): HTMLElement {
  const redraw = () => window.dispatchEvent(new HashChangeEvent('hashchange'));
  const bar = el('div', { class: 'seg' });
  if (dismissed) bar.append(writeButton(door, 'Undismiss', 'Undismiss this alert', () => { void dismissEnd(key, redraw); }));
  else bar.append(writeButton(door, 'Dismiss', 'Dismiss this alert with a reason', () => dismissDialog([key], redraw)));
  return bar;
}

async function dismissEnd(key: string, after: () => void) {
  const d = await get<{ dismissed: Table | null }>('alerts', { part: 'dismissed' });
  const row = rowsOf(d.dismissed).find(r => r.finding_key === key && r.live);
  if (!row) { after(); return; }
  if (!window.confirm('Undismiss this alert? It shows on the open-alerts grid again; the dismissal stays in the store with who ended it.')) return;
  try { await post('alerts/dismiss', { op: 'end', dismiss_id: Number(row.dismiss_id) }); } catch (e) { window.alert(e instanceof Error ? e.message : String(e)); }
  after();
}

// the reasons offered first (any text is taken)
export const dismissReasons = ['tolerable for this server', 'controlled elsewhere (a policy, another tool)', 'a known pattern of this system', 'a test or lab instance'];

// dismissDialog: one reason for the alerts named; one post each, the answer in place
export function dismissDialog(keys: string[], after: () => void) {
  const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  const sel = el('select', { 'aria-label': 'reason' }, ...dismissReasons.map(r => el('option', { value: r }, r)), el('option', { value: '' }, 'another reason ...'));
  const other = el('input', { type: 'text', maxlength: '500', 'aria-label': 'another reason', style: 'width:100%' });
  const ok = el('button', { type: 'submit' }, 'Dismiss'), no = el('button', { type: 'button' }, 'Back');
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const reason = () => (sel.value || other.value).trim();
  const check = () => { ok.disabled = reason() === ''; };
  sel.addEventListener('change', check); other.addEventListener('input', check);
  const form = el('form', { method: 'dialog' }, el('h3', {}, `Dismiss ${keys.length} alert(s)`),
    el('p', {}, 'A dismissed alert leaves the open-alerts grid (Show dismissed brings it back) and keeps its reason, who and when. It changes what the grid shows, not what is sent: a mute or an acknowledgement holds the sends.'),
    el('label', {}, 'Reason ', sel), el('div', { style: 'margin:.3rem 0' }, other), msg, el('div', { style: 'margin-top:.6rem' }, ok, ' ', no));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:36rem', 'aria-label': 'Dismiss alerts' }, form);
  let done = false;
  const leave = () => { dlg.remove(); if (done) after(); else if (opener?.isConnected) opener.focus(); };
  no.addEventListener('click', () => { dlg.close(); leave(); });
  dlg.addEventListener('cancel', leave);
  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    if (done) return;
    ok.disabled = true; msg.textContent = 'Saving...';
    let n = 0;
    const refused: string[] = [];
    for (const k of keys) {
      try { await post('alerts/dismiss', { op: 'add', finding_key: k, reason: reason() }); n++; } catch (e) { refused.push(e instanceof Error ? e.message : String(e)); }
    }
    done = n > 0;
    msg.replaceChildren(badge(refused.length ? (n ? 'partly done' : 'not saved') : 'done', refused.length ? 'warn' : 'ok'), ` ${n} of ${keys.length} dismissed` + (refused.length ? `; refused: ${refused.join('; ')}` : ''));
    no.textContent = 'Close';
    if (!done) ok.disabled = false;
  });
  check();
  document.body.append(dlg);
  dlg.showModal();
  sel.focus();
}
