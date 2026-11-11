// The Alerts tab at the root (task 60): the channels the configuration's alerts: list names (SMTP, a webhook, a file
// drop) with each one's last attempt and last send, the alerts open now (a finding sent and not yet cleared), and every
// send attempt of the time range with its outcome and error text. Nothing is sent unless a channel is configured: with
// none the page says so. alertCol is the Findings tab's sent / when / where column (it reads the alert_* columns
// pgvigil.findings_alerts adds to each finding). Data from /api/alerts and /api/ack (ack.ts); the route, the root tab
// and the Findings column's place are the shell's. The rules on charted metrics (task 131) have their own page
// (alert_rules.ts); a firing rule is an open alert here like any finding.
import { get, Row, rowsOf, Table } from './api';
import { Ctx, href, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtSecs, fmtTime, grid } from './ui';
import { AckData, ackDialog, endAck, endButton, liveRows, loadAckSafe, writeButton } from './ack';
import { fleet } from './fleet';
import { whatIsThis } from './sqlview';

interface AlertsData { channels: Table | null; open: Table | null; log: Table | null }

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');

const outcomeBadge = (v: unknown) =>
  v == null ? '' : badge(String(v), v === 'sent' ? 'ok' : v === 'failed' || v === 'refused' ? 'crit' : '');

const list = (v: unknown): string => Array.isArray(v) && v.length ? v.join(', ') : '';

// scopeText: what a channel covers, in words
export function scopeText(r: Row): string {
  const inst = list(r.instances), tags = list(r.tags);
  if (!inst && !tags) return 'every instance';
  return [inst && `instances ${inst}`, tags && `tags ${tags}`].filter(Boolean).join('; or ');
}

// repeatText: the repeat interval, 0 = once
export const repeatText = (secs: unknown): string => Number(secs) > 0 ? 'every ' + fmtSecs(secs) : 'once';

const channelCols: Col[] = [
  { key: 'name', label: 'channel', fmt: (v, r) => r.is_configured ? String(v ?? '') : el('span', {}, String(v ?? ''), ' ', badge('no longer configured', '')) },
  { key: 'kind' },
  { key: 'destination', wide: true },
  { key: 'min_severity', label: 'from severity', fmt: sevBadge },
  { key: 'scope', label: 'covers', fmt: (_, r) => scopeText(r) },
  { key: 'quiet_hours', label: 'quiet hours', fmt: (v, r) => v ? `${String(v)} ${String(r.timezone ?? 'UTC')}` : '' },
  { key: 'repeat_secs', label: 'repeat', fmt: repeatText },
  { key: 'recovery', label: 'recovery message', fmt: v => v ? 'yes' : 'no' },
  { key: 'open_alerts', label: 'open alerts', num: true, fmt: v => fmtNum(v) },
  { key: 'last_sent_at', label: 'last sent', fmt: fmtTime },
  { key: 'last_attempt_at', label: 'last attempt', fmt: fmtTime },
  { key: 'last_outcome', label: 'outcome', fmt: outcomeBadge },
  { key: 'last_error', label: 'error', wide: true },
];

const openCols: Col[] = [
  { key: 'severity', fmt: sevBadge },
  { key: 'channel' },
  { key: 'instance' },
  { key: 'source' },
  { key: 'setting' },
  { key: 'value', wide: true },
  { key: 'first_sent_at', label: 'first sent', fmt: fmtTime },
  { key: 'last_sent_at', label: 'last sent', fmt: fmtTime },
  { key: 'send_count', label: 'sends', num: true },
];

const logCols: Col[] = [
  { key: 'at', label: 'attempt', fmt: fmtTime },
  { key: 'channel', fmt: v => v == null ? '(none configured)' : String(v) },
  { key: 'kind' },
  { key: 'destination', wide: true },
  { key: 'outcome', fmt: outcomeBadge },
  { key: 'n_firing', label: 'new', num: true },
  { key: 'n_repeat', label: 'repeated', num: true },
  { key: 'n_resolved', label: 'resolved', num: true },
  { key: 'instance', label: 'instance (one)' },
  { key: 'error', wide: true },
];

// alertsView: the Alerts tab - the channels, the open alerts as a triage grid (acknowledge, notes, mute, close, the
// blackout flag, the known-noise label), the silenced servers and blackouts, the mute rules and known patterns, the
// sends they held (still logged) and the audit of every acknowledgement (task 118; DBA Dash 02, Darling 5 and 10)
export async function alertsView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Alerts'));
  let d: AlertsData;
  try {
    d = await get<AlertsData>('alerts', window_(ctx));
  } catch (e) {
    sec.append(errorBox(e));
    return sec;
  }
  const ad = await loadAckSafe(['acks', 'alerts', 'suppressed', 'log'], window_(ctx));
  const f = await fleet().catch(() => null);
  const chans = rowsOf(d.channels), open = rowsOf(d.open), log = rowsOf(d.log);
  const configured = chans.filter(r => r.is_configured);
  const failed = log.filter(r => r.outcome === 'failed' || r.outcome === 'refused').length;
  const redraw = () => window.dispatchEvent(new HashChangeEvent('hashchange'));
  const triage = rowsOf(ad.alerts);
  const nAcked = triage.filter(r => r.ack_id != null).length, nHeld = triage.filter(r => r.held_by != null).length;
  sec.append(el('p', { class: 'meta' }, configured.length === 0
    ? 'No alert channel is configured: pgvigil sends nothing. A channel is named in the configuration\'s alerts: list (SMTP, a webhook or a file drop); see docs/alerts.md.'
    : `${configured.length} channel(s) configured, ${open.length} alert(s) open (${nAcked} acknowledged, ${nHeld} held), ${log.length} send attempt(s) ${rangeLabel(ctx)}, ${failed} failed or refused.`,
    ' ', whatLink()));
  if (!ad.writable) sec.append(el('p', { class: 'meta' }, `Acknowledge, notes and mute are read only here: ${ad.reason ?? ''}`));
  // a metric threshold is an alert rule (task 131): its alerts are listed here with source 'alert rule'
  sec.append(el('p', { class: 'meta' }, 'An alert of source \'alert rule\' comes from a threshold on a charted metric: ',
    el('a', { href: href(ctx, { tab: 'alertrules' }) }, 'Alert rules'), ' lists the rules and what the sender last made of each.'));
  sec.append(el('h3', {}, 'Channels'),
    grid(chans, channelCols, 'No channel recorded: the alert sender has not run with a channel configured.'));
  sec.append(el('h3', {}, 'Open alerts'));
  if (ad.alerts == null) sec.append(grid(open, openCols, 'No open alert: nothing sent is still standing.'));
  else sec.append(triageView(ad, triage, redraw));
  sec.append(serversView(ad, f?.instances ?? [], redraw));
  sec.append(rulesView(ad, 'mute', redraw), rulesView(ad, 'noise', redraw));
  sec.append(el('h3', {}, `Held sends ${rangeLabel(ctx)} `, whatIsThis('What a mute, a silence or a blackout kept from a channel: the alert, the channel, the first and last pass of the sender that held it, and how many passes.', 'Held sends')),
    grid(rowsOf(ad.suppressed), heldCols, 'Nothing held in the time range.'));
  sec.append(el('h3', {}, `Send log ${rangeLabel(ctx)}`),
    grid(log, logCols, 'No send attempt in the time range.'));
  sec.append(el('h3', {}, `Acknowledge log ${rangeLabel(ctx)}`),
    grid(rowsOf(ad.log), ackLogCols, 'No acknowledgement, note or rule was made or ended in the time range.'));
  return sec;
}

const whatLink = () => whatIsThis('Acknowledge an alert: no repeat send while it stands (a rise in severity still sends). A note is kept on the alert. A mute rule, a silenced server or a blackout holds the sends it matches and logs them under Held sends. A known pattern labels a matching alert and holds nothing. Close takes a resolved alert off the list. Who and when are kept on every row; nothing is deleted (docs/acknowledge.md).', 'Acknowledge, mute and notes');

// oneLine: a cell's text on one line, clipped, the whole of it in the title
const oneLine = (v: unknown): HTMLElement | string => {
  const t = v == null ? '' : String(v);
  return t ? el('span', { title: t, style: 'display:inline-block;max-width:16rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;vertical-align:bottom' }, t) : '';
};

// triageView: one row per open alert; a box per row and DBA Dash's four actions on the rows ticked
function triageView(ad: AckData, all: Row[], redraw: () => void): HTMLElement {
  let showClosed = false;
  const picked = new Set<string>();
  const wrap = el('div', {});
  const said = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const pickedRows = () => all.filter(r => picked.has(String(r.finding_key)));
  const act = (label: string, run: () => void) => writeButton(ad, label, label + ' (the ticked alerts)', () => {
    if (!picked.size) { said.textContent = 'Tick one or more alerts first.'; return; }
    run();
  });
  const ackSel = act('Acknowledge alerts', () => ackDialog({
    title: `Acknowledge ${picked.size} alert(s)`,
    what: 'An acknowledged alert is not sent again on its repeat interval; a rise in its severity is still sent. Who and when are kept.',
    body: pickedRows().filter(r => r.ack_id == null).map(r => ({ kind: 'alert_ack', instance_id: Number(r.instance_id) || undefined, finding_key: String(r.finding_key) })),
    expiry: true, after: redraw }));
  const clearSel = act('Clear acknowledgement', () => endMany(pickedRows().filter(r => r.ack_id != null).map(r => Number(r.ack_id)), said, redraw));
  const noteSel = act('Add notes to selected alerts', () => ackDialog({
    title: `A note on ${picked.size} alert(s)`, what: 'The note is kept on each alert with who and when.',
    body: pickedRows().map(r => ({ kind: 'note', instance_id: Number(r.instance_id) || undefined, finding_key: String(r.finding_key) })),
    expiry: false, noteField: 'required', after: redraw }));
  const closeSel = act('Close resolved alerts', () => {
    const res = pickedRows().filter(r => r.resolved && r.close_id == null);
    if (!res.length) { said.textContent = 'None of the ticked alerts is resolved: an alert is closed once its finding is gone.'; return; }
    ackDialog({ title: `Close ${res.length} resolved alert(s)`, what: 'A closed alert leaves this list (Show closed brings it back); its channels still send the recovery when it clears.',
      body: res.map(r => ({ kind: 'close', instance_id: Number(r.instance_id) || undefined, finding_key: String(r.finding_key) })), expiry: false, after: redraw });
  });
  const closedBtn = el('button', { type: 'button', class: 'toggle', 'aria-pressed': 'false' }, 'Show closed');
  const draw = () => {
    const rows = all.filter(r => showClosed || r.close_id == null);
    const cols: Col[] = [
      { key: '_pick', label: 'select', fmt: (_v, r) => {
        const b = el('input', { type: 'checkbox', 'aria-label': `select ${String(r.instance)} ${String(r.setting ?? r.source ?? '')}` });
        b.checked = picked.has(String(r.finding_key));
        b.addEventListener('change', () => { if (b.checked) picked.add(String(r.finding_key)); else picked.delete(String(r.finding_key)); said.textContent = `${picked.size} ticked.`; });
        return b;
      } },
      { key: 'severity', fmt: sevBadge },
      { key: 'instance' },
      { key: 'setting', label: 'alert', fmt: (v, r) => oneLine([r.source, v].filter(x => x != null && x !== '').map(String).join(': ')) },
      // one line per row: the value clipped, whole in its title
      { key: 'value', fmt: v => oneLine(v) },
      { key: 'first_sent_at', label: 'first sent', fmt: fmtTime },
      { key: 'sends', label: 'sends', num: true, fmt: (v, r) => el('span', { title: `last sent ${fmtTime(r.last_sent_at)} to ${list(r.channels)}` }, String(v ?? '')) },
      { key: '_state', label: 'state', fmt: (_v, r) => oneLine([
        r.ack_id != null ? `acknowledged by ${String(r.acked_by)} ${fmtTime(r.acked_at)}` : '',
        r.held_by != null ? `held by ${String(r.held_by)}` : '',
        r.is_blackout ? 'blackout' : '',
        r.resolved ? `resolved ${fmtTime(r.resolved_at)}` + (r.close_id != null ? `, closed by ${String(r.closed_by)}` : '') : '',
        r.known_noise != null ? `known: ${String(r.known_noise)}` : '',
      ].filter(Boolean).join(' \u00b7 ')) },
      { key: 'notes', label: 'notes', num: true, fmt: (v, r) => Number(v) ? oneLine(`${String(v)}: ${String(r.last_note ?? '')}`) : '' },
      { key: '_mute', label: 'mute', fmt: (_v, r) => el('span', { style: 'white-space:nowrap' },
        writeButton(ad, 'Mute this alert', `Mute this alert: ${String(r.instance)} ${String(r.setting ?? '')}`, () => ackDialog({
          title: 'Mute this alert', what: `${String(r.instance)}: ${String(r.source ?? '')} ${String(r.setting ?? '')}. Its sends are held while the mute stands and logged under Held sends.`,
          body: { kind: 'mute', instance_id: Number(r.instance_id) || undefined, finding_key: String(r.finding_key) }, expiry: true, noteField: 'optional', after: redraw })),
        ' · ',
        writeButton(ad, 'Mute similar', `Mute similar: ${String(r.setting ?? r.source ?? '')} on every instance`, () => ackDialog({
          title: 'Mute similar alerts', what: 'Every alert matching the fields below is held while the rule stands (every instance unless one is named), and logged under Held sends.',
          body: { kind: 'mute', check_key: String(r.setting ?? r.source ?? '') }, expiry: true, matchFields: true, noteField: 'optional', after: redraw }))) },
    ];
    wrap.replaceChildren(grid(rows, cols, all.length ? 'Every open alert is closed: Show closed lists them.' : 'No open alert: nothing sent is still standing.'));
  };
  closedBtn.addEventListener('click', () => { showClosed = !showClosed; closedBtn.setAttribute('aria-pressed', String(showClosed)); draw(); });
  draw();
  return el('div', {}, el('div', { class: 'toolbar' }, el('div', { class: 'seg', role: 'group', 'aria-label': 'Actions' }, ackSel, clearSel, noteSel, closeSel), el('div', { class: 'seg' }, closedBtn)), said, wrap);
}

async function endMany(ids: number[], said: HTMLElement, after: () => void) {
  if (!ids.length) { said.textContent = 'None of the ticked alerts is acknowledged.'; return; }
  if (!window.confirm(`Clear ${ids.length} acknowledgement(s)? The rows stay with who cleared them and when.`)) return;
  const out: string[] = [];
  for (const id of ids) { try { out.push((await endAck(id)).outcome); } catch (e) { out.push(e instanceof Error ? e.message : String(e)); } }
  said.textContent = `Cleared: ${out.join(', ')}`;
  after();
}

const whenCols: Col[] = [
  { key: 'created_at', label: 'made', fmt: (v, r) => `${fmtTime(v)} by ${String(r.created_by)}` },
  { key: 'until', label: 'until', fmt: v => v == null ? 'no expiry' : fmtTime(v) },
];

// serversView: the servers silenced (Darling's Silence: every alert of the server held, still logged) and the
// blackouts (a window on one instance: its alerts are held and flagged blackout)
function serversView(ad: AckData, insts: Row[], redraw: () => void): HTMLElement {
  const rows = liveRows(ad).filter(r => r.kind === 'silence' || r.kind === 'blackout').concat(rowsOf(ad.acks).filter(r => r.kind === 'blackout' && !r.live && !r.ended_at && r.starts_at && Date.parse(String(r.starts_at)) > Date.now()));
  const sel = el('select', { 'aria-label': 'instance' }, ...insts.map(i => el('option', { value: String(i.instance_id) }, String(i.name))));
  const pick = () => insts.find(i => String(i.instance_id) === sel.value);
  const silence = writeButton(ad, 'Silence', 'Silence the instance picked', () => ackDialog({
    title: `Silence all alerts for '${String(pick()?.name ?? '')}'?`,
    what: 'This holds every alert of the server; the held alerts are still logged (Held sends). Unsilence removes it.',
    body: { kind: 'silence', instance_id: Number(sel.value) }, expiry: true, noteField: 'optional', after: redraw }));
  const blackout = writeButton(ad, 'Blackout', 'A blackout window for the instance picked', () => ackDialog({
    title: `Blackout '${String(pick()?.name ?? '')}'`,
    what: 'From the start to the end the server\'s alerts are held (still logged) and flagged blackout.',
    body: { kind: 'blackout', instance_id: Number(sel.value) }, expiry: false, blackout: true, noteField: 'optional', after: redraw }));
  const cols: Col[] = [
    { key: 'kind', fmt: v => v === 'silence' ? 'silenced' : 'blackout' },
    { key: 'instance' },
    { key: 'starts_at', label: 'from', fmt: fmtTime },
    ...whenCols,
    { key: 'note', wide: true },
    { key: 'held_alerts', label: 'alerts held', num: true },
    { key: 'held_last', label: 'last held', fmt: fmtTime },
    { key: '_end', label: '', fmt: (_v, r) => ad.writable ? endButton(Number(r.ack_id), `${r.kind === 'silence' ? 'Unsilence' : 'End the blackout of'} ${String(r.instance)}`, redraw, r.kind === 'silence' ? 'Unsilence' : 'End') : '' },
  ];
  return el('div', {}, el('h3', {}, 'Silenced servers and blackouts'),
    el('div', { class: 'toolbar' }, el('label', {}, 'Instance ', sel), el('div', { class: 'seg' }, silence, blackout)),
    grid(rows, cols, 'No server is silenced and no blackout is set.'));
}

// rulesView: the mute rules (held sends still logged) or the known patterns (a label beside the alert, nothing held)
function rulesView(ad: AckData, kind: 'mute' | 'noise', redraw: () => void): HTMLElement {
  const rows = liveRows(ad, kind);
  const mk = writeButton(ad, kind === 'mute' ? 'New mute rule' : 'New known pattern', kind === 'mute' ? 'New mute rule' : 'New known pattern', () => ackDialog({
    title: kind === 'mute' ? 'New mute rule' : 'New known pattern',
    what: kind === 'mute' ? 'Alerts matching every field filled are held while the rule stands; the held sends are logged.' : 'Alerts matching every field filled carry the label; nothing is held.',
    body: { kind }, expiry: true, matchFields: true, noteField: kind === 'noise' ? 'label' : 'optional', after: redraw }));
  const cols: Col[] = [
    { key: 'check_key', label: 'check' },
    { key: 'instance' },
    { key: 'tag' },
    { key: 'match_text', label: 'text' },
    { key: 'finding_key', label: 'one alert', fmt: v => v == null ? '' : 'yes' },
    { key: 'note', label: kind === 'noise' ? 'label' : 'note', wide: true },
    ...whenCols,
    ...(kind === 'mute' ? [{ key: 'held_alerts', label: 'alerts held', num: true }, { key: 'held_last', label: 'last held', fmt: fmtTime }] as Col[] : []),
    { key: '_end', label: '', fmt: (_v, r) => ad.writable ? endButton(Number(r.ack_id), `Remove the ${kind === 'mute' ? 'mute rule' : 'known pattern'} ${String(r.ack_id)}`, redraw, 'Remove') : '' },
  ];
  return el('div', {}, el('h3', {}, kind === 'mute' ? 'Mute rules' : 'Known patterns'),
    el('div', { class: 'seg' }, mk),
    grid(rows, cols, kind === 'mute' ? 'No mute rule: a quiet send log is genuine, not muted.' : 'No known pattern.'));
}

const heldCols: Col[] = [
  { key: 'last_at', label: 'last held', fmt: fmtTime },
  { key: 'first_at', label: 'first held', fmt: fmtTime },
  { key: 'passes', label: 'passes', num: true },
  { key: 'channel' },
  { key: 'instance' },
  { key: 'severity', fmt: sevBadge },
  { key: 'source' },
  { key: 'setting' },
  { key: 'value', fmt: v => oneLine(v) },
  { key: 'held_by', label: 'held by', fmt: (v, r) => `${String(v)} ${String(r.rule ?? '')} (${String(r.created_by)})` },
];

const ackLogCols: Col[] = [
  { key: 'at', label: 'when', fmt: fmtTime },
  { key: 'ui_user', label: 'by' },
  { key: 'client', label: 'from' },
  { key: 'op', fmt: v => v === 'end' ? 'ended' : 'made' },
  { key: 'kind' },
  { key: 'instance' },
  { key: 'outcome', fmt: v => badge(String(v ?? ''), v === 'done' ? 'ok' : 'warn') },
  { key: 'detail', wide: true },
];

// alertCol: the Findings tab's column - sent, when (the last send) and where (the channels); empty when not sent
export const alertCol: Col = {
  key: 'alert_last_sent', label: 'alerted',
  // the whole text in the cell (no title-only detail: a keyboard or screen-reader user reads what is shown)
  fmt: (v, r) => v == null ? '' :
    `sent ${fmtTime(v)} to ${list(r.alert_channels)} (first ${fmtTime(r.alert_first_sent)}, ${fmtNum(r.alert_sends)} send(s))`,
};
