// The Alerts tab at the root (task 60): the channels the configuration's alerts: list names (SMTP, a webhook, a file
// drop) with each one's last attempt and last send, the alerts open now (a finding sent and not yet cleared), and every
// send attempt of the time range with its outcome and error text. Nothing is sent unless a channel is configured: with
// none the page says so. alertCol is the Findings tab's sent / when / where column (it reads the alert_* columns
// pgvigil.findings_alerts adds to each finding). Data from /api/alerts and /api/ack (ack.ts); the route, the root tab
// and the Findings column's place are the shell's. The rules on charted metrics (task 131) have their own page
// (alert_rules.ts); a firing rule is an open alert here like any finding.
//
// Task 151 (K07): each channel's Send test (the sender's next pass answers it), its send cap and templates; the
// open alerts with a tick-all box, a link to each alert's page (alert_page.ts), the fix statement with Copy, and
// dismiss with a reason behind Show dismissed; the alert history of the range (every firing and its clearance); the
// mute rules with a start time, an instance field, edit (end + successor) and pause / resume.
import { get, post, Row, rowsOf, Table } from './api';
import { Ctx, href, rangeLabel, window_ } from './router';
import { badge, Col, copyText, el, errorBox, fmtNum, fmtSecs, fmtTime, grid } from './ui';
import { AckData, ackDialog, ackOn, addAck, endAck, endButton, liveRows, loadAckSafe, writeButton } from './ack';
import { fleet, tagsOf } from './fleet';
import { whatIsThis } from './sqlview';
import { alertHref, dismissDialog } from './alert_page';
import { fromInput, toInput } from './tz';
import { conditionWords, scopeWords, willAlert } from './alert_rules';
import { mssqlActionsState } from './mssql_actions';

interface AlertsData {
  channels: Table | null; open: Table | null; log: Table | null;
  history?: Table | null; tests?: Table | null; dismissed?: Table | null; mutes?: Table | null; fixes?: Table | null;
}

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');

const outcomeBadge = (v: unknown) =>
  v == null ? '' : badge(String(v), v === 'sent' || v === 'test' ? 'ok' : v === 'failed' || v === 'refused' || v === 'no answer' ? 'crit' : v === 'capped' || v === 'waiting' ? 'warn' : '');

const list = (v: unknown): string => Array.isArray(v) && v.length ? v.join(', ') : '';

// scopeText: what a channel covers, in words
export function scopeText(r: Row): string {
  const inst = list(r.instances), tags = list(r.tags);
  if (!inst && !tags) return 'every instance';
  return [inst && `instances ${inst}`, tags && `tags ${tags}`].filter(Boolean).join('; or ');
}

// repeatText: the repeat interval, 0 = once
export const repeatText = (secs: unknown): string => Number(secs) > 0 ? 'every ' + fmtSecs(secs) : 'once';

// capText: a channel's send cap and what the last hour used of it
export const capText = (r: Row): string => Number(r.max_per_hour) > 0
  ? `${fmtNum(r.sent_last_hour)} of ${fmtNum(r.max_per_hour)} an hour` + (Number(r.capped_passes_last_hour) > 0 ? `, held in ${fmtNum(r.capped_passes_last_hour)} pass(es)` : '')
  : 'no cap';

// testCell: a channel's Send test button and its last answer
function testCell(ad: AckData, r: Row, redraw: () => void): HTMLElement {
  const said = el('span', { role: 'status', 'aria-live': 'polite' });
  const b = writeButton(ad, 'Send test', `Send test message on channel ${String(r.name)}`, async () => {
    b.disabled = true; said.textContent = ' asking ...';
    try {
      const res = await post<{ detail: string }>('alerts/test', { channel: String(r.name) });
      said.textContent = ' ' + res.detail;
      window.setTimeout(redraw, 2000);
    } catch (e) { said.textContent = ' not asked: ' + (e instanceof Error ? e.message : String(e)); b.disabled = false; }
  }, { why: ad.door ? 'Send test asks the alert sender to send a message; pgvigil demo -serve runs no sender and sends nothing here' : undefined });
  if (!r.is_configured) { b.disabled = true; if (ad.writable) b.title = 'the configuration no longer names this channel'; }
  const last = r.last_test_at == null ? '' : ` last: ${String(r.last_test_outcome)} ${fmtTime(r.last_test_done ?? r.last_test_at)} (${String(r.last_test_by ?? '')})` + (r.last_test_error ? `: ${String(r.last_test_error)}` : '');
  return el('span', { style: 'white-space:nowrap' }, b, last ? el('span', { class: 'meta' }, last) : '', said);
}

const channelCols = (ad: AckData, redraw: () => void): Col[] => [
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
  { key: 'max_per_hour', label: 'send cap', fmt: (_v, r) => capText(r) },
  { key: 'templates', fmt: v => v ? String(v) : 'built in' },
  { key: '_test', label: 'test', fmt: (_v, r) => testCell(ad, r, redraw) },
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
  // the channels, open alerts and send log are the page; the parts task 151 added are read on their own, so a slow or
  // failing one (an older server, a timeout) leaves its section saying so and the rest of the page standing
  const optional = ['history', 'tests', 'dismissed', 'mutes', 'fixes'] as const;
  const missing: Record<string, string> = {};
  try {
    const [core, ...opt] = await Promise.all([
      get<AlertsData>('alerts', { ...window_(ctx), part: 'channels' }).then(async c => ({ ...c,
        ...await get<AlertsData>('alerts', { ...window_(ctx), part: 'open' }),
        ...await get<AlertsData>('alerts', { ...window_(ctx), part: 'log' }) })),
      ...optional.map(p => get<AlertsData>('alerts', { ...window_(ctx), part: p }).catch((e: unknown) => {
        missing[p] = e instanceof Error ? e.message : String(e);
        return {} as Partial<AlertsData>;
      })),
    ]);
    d = Object.assign({}, core, ...opt) as AlertsData;
  } catch (e) {
    sec.append(errorBox(e));
    return sec;
  }
  const notRead = (p: string) => missing[p] ? el('p', { class: 'meta' }, `Not read: ${missing[p]}`) : '';
  const ad = await loadAckSafe(['acks', 'alerts', 'suppressed', 'log'], window_(ctx));
  // the page's one sentence where its writes are off: on a server that writes nothing every off control of the page
  // points at it (ad.note); on a demo serve it says whose door this is, and a control that is off says its own reason
  const offP = ad.writable ? null : el('p', { class: 'meta' }, ad.door
    ? `Demo: an acknowledgement, a note, a mute, a silence or a dismissal here is saved as user ${ad.door.user}, on the demo's own instances only. A change that reaches past one instance, and Send test, stay off: they need pgvigil serve with a signed-in user.`
    : `Acknowledge, notes, mute, dismiss and Send test are read only here: ${ad.reason ?? ''}`);
  if (offP && !ad.door) ad.note = offP;
  const f = await fleet().catch(() => null);
  const chans = rowsOf(d.channels), open = rowsOf(d.open), log = rowsOf(d.log);
  const fixes = new Map(rowsOf(d.fixes).filter(r => r.fix != null).map(r => [String(r.finding_key), String(r.fix)]));
  // a finding's suggested value is its threshold in the history while the finding stands
  const suggested = new Map(rowsOf(d.fixes).filter(r => r.suggested != null).map(r => [String(r.finding_key), String(r.suggested)]));
  const dismissed = new Map(rowsOf(d.dismissed).filter(r => r.live).map(r => [String(r.finding_key), r]));
  const base = chans.find(r => r.is_configured && r.link_base)?.link_base;
  const configured = chans.filter(r => r.is_configured);
  const failed = log.filter(r => r.outcome === 'failed' || r.outcome === 'refused').length;
  const redraw = () => window.dispatchEvent(new HashChangeEvent('hashchange'));
  const triage = rowsOf(ad.alerts);
  const nAcked = triage.filter(r => r.ack_id != null).length, nHeld = triage.filter(r => r.held_by != null).length;
  sec.append(el('p', { class: 'meta' }, configured.length === 0
    ? 'No alert channel is configured: pgvigil sends nothing. A channel is named in the configuration\'s alerts: list (SMTP, a webhook or a file drop); see docs/alerts.md.'
    : `${configured.length} channel(s) configured, ${open.length} alert(s) open (${nAcked} acknowledged, ${nHeld} held), ${log.length} send attempt(s) ${rangeLabel(ctx)}, ${failed} failed or refused.`,
    ' ', whatLink()));
  if (configured.length) sec.append(el('p', { class: 'meta' }, base
    ? `Every sent alert carries the address of its own page: ${String(base)}/#/alert?k=...`
    : 'The sent alerts carry no link to their page: alerts_base_url (the UI\'s address as a reader opens it) is not set in the configuration.'));
  if (offP) sec.append(offP);
  // a metric threshold is an alert rule (task 131): its alerts are listed here with source 'alert rule'
  sec.append(el('p', { class: 'meta' }, 'An alert of source \'alert rule\' comes from a threshold on a charted metric: ',
    el('a', { href: href(ctx, { tab: 'alertrules' }) }, 'Alert rules'), ' lists the rules and what the sender last made of each.'));
  sec.append(el('h3', {}, 'Channels'),
    grid(chans, channelCols(ad, redraw), 'No channel recorded: the alert sender has not run with a channel configured.'));
  sec.append(el('h3', {}, 'Open alerts'));
  if (ad.alerts == null) sec.append(grid(open, openCols, 'No open alert: nothing sent is still standing.'));
  else sec.append(triageView(ctx, ad, triage, redraw, fixes, dismissed));
  if (missing.dismissed || missing.fixes) sec.append(notRead('dismissed'), notRead('fixes'));
  sec.append(historyView(ctx, rowsOf(d.history).map(r => r.threshold == null && suggested.has(String(r.finding_key)) ? { ...r, threshold: suggested.get(String(r.finding_key)) } : r)), notRead('history'));
  sec.append(serversView(ad, f?.instances ?? [], redraw));
  if (d.mutes != null) sec.append(mutesView(ctx, ad, rowsOf(d.mutes), 'mute', f?.instances ?? [], redraw), mutesView(ctx, ad, rowsOf(d.mutes), 'noise', f?.instances ?? [], redraw));
  else sec.append(rulesView(ad, 'mute', redraw), rulesView(ad, 'noise', redraw));
  sec.append(el('h3', {}, `Send tests ${rangeLabel(ctx)} `, whatIsThis('A Send test asks the alert sender for a test message on one channel: its next pass (within a minute while pgvigil run is up) sends it, whatever the quiet hours, back-off or cap, and records the destination\'s answer here and in the send log. PagerDuty and Opsgenie get the test and its resolve at once. A request no sender answered within the hour reads no answer: no sender holds that channel.', 'Send test')),
    missing.tests ? notRead('tests') : grid(rowsOf(d.tests), testCols, 'No test was asked in the time range.'));
  sec.append(el('h3', {}, `Held sends ${rangeLabel(ctx)} `, whatIsThis('What a mute, a silence or a blackout kept from a channel: the alert, the channel, the first and last pass of the sender that held it, and how many passes.', 'Held sends')),
    grid(rowsOf(ad.suppressed), heldCols, 'Nothing held in the time range.'));
  sec.append(el('h3', {}, `Send log ${rangeLabel(ctx)}`),
    grid(log, logCols, 'No send attempt in the time range.'));
  sec.append(el('h3', {}, `Acknowledge log ${rangeLabel(ctx)}`),
    grid(rowsOf(ad.log), ackLogCols, 'No acknowledgement, note or rule was made or ended in the time range.'));
  return sec;
}

const whatLink = () => whatIsThis('Acknowledge an alert: no repeat send while it stands (a rise in severity still sends). A note is kept on the alert. A mute rule, a silenced server or a blackout holds the sends it matches and logs them under Held sends; a mute rule can start later, be edited (it ends and a successor is written) and be paused. A known pattern labels a matching alert and holds nothing. Close takes a resolved alert off the list. Dismiss hides an alert from the grid with a reason (Show dismissed brings it back) and changes nothing that is sent. Who and when are kept on every row; nothing is deleted (docs/acknowledge.md, docs/alerts.md).', 'Acknowledge, mute and notes');

const testCols: Col[] = [
  { key: 'requested_at', label: 'asked', fmt: fmtTime },
  { key: 'channel' },
  { key: 'requested_by', label: 'by' },
  { key: 'client', label: 'from' },
  { key: 'outcome', fmt: outcomeBadge },
  { key: 'done_at', label: 'answered', fmt: fmtTime },
  { key: 'error', wide: true },
];

// historyView: every firing open at some point of the range and how it ended (K07.01)
function historyView(ctx: Ctx, rows: Row[]): HTMLElement {
  const cols: Col[] = [
    { key: 'fired_at', label: 'fired', fmt: fmtTime },
    { key: 'cleared_at', label: 'cleared', fmt: (v, r) => v == null ? (r.missing_since != null ? `gone since ${fmtTime(r.missing_since)}` : '') : fmtTime(v) },
    { key: 'status', fmt: v => badge(String(v ?? ''), v === 'open' ? 'crit' : v === 'resolved' ? 'ok' : '') },
    { key: 'severity', fmt: sevBadge },
    { key: 'instance' },
    { key: 'setting', label: 'alert', fmt: (v, r) => el('a', { href: alertHref(r.finding_key, r.fired_at, ctx) }, [r.source, v].filter(x => x != null && x !== '').map(String).join(': ')) },
    { key: 'value', label: 'detail', fmt: (v, r) => detailCell(v, r) },
    { key: 'threshold', fmt: v => String(v ?? '') },
    { key: 'channels', fmt: v => list(v) },
    { key: 'sends', num: true },
    { key: 'occurrence', label: 'firing', num: true },
    { key: 'dismissed', fmt: v => v ? 'dismissed' : '' },
  ];
  return el('div', {}, el('h3', {}, `Alert history ${rangeLabel(ctx)} `, whatIsThis('Every firing of an alert that was open at some time in the range: when it was first sent, when it cleared (on every channel), how it ended (resolved: a recovery was sent; cleared without a fix: its instance retired, the channel no longer covers it, or recovery is off - PagerDuty and Opsgenie closed their incident, the other kinds sent nothing), the value last sent and the threshold (an alert rule\'s value, a finding\'s suggested value while it stands). A firing is the channels\' alerts of one finding grouped while their periods overlap. The history is as long as the purge window keeps the cleared alerts.', 'Alert history')),
    grid(rows, cols, 'No alert was open in the time range.'));
}

// detailCell: the alert's value on one line, clipped, opening in the row to its labelled detail (PerformanceMonitor's
// Alert History Detail column: a disclosure per row); the export and the copies take the value alone (data-full)
function detailCell(v: unknown, r: Row): HTMLElement | string {
  const t = v == null ? '' : String(v);
  if (!t) return '';
  const line = (k: string, x: unknown) => x == null || x === '' ? null : el('div', {}, el('b', {}, k + ': '), String(x));
  const chans = Array.isArray(r.channels) ? r.channels.join(', ') : r.channels;
  return el('details', { class: 'alert-detail', 'data-full': t },
    el('summary', { title: t, style: 'max-width:18rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis' }, t.split('\n')[0]),
    el('div', { style: 'white-space:normal;max-width:40rem;padding:.2rem 0' },
      ...[line('Value', t), line('Threshold', r.threshold), line('Alert', [r.source, r.setting].filter(x => x != null && x !== '').map(String).join(': ')),
        line('Instance', r.instance), line('First sent', (r.fired_at ?? r.first_sent_at) == null ? null : fmtTime(r.fired_at ?? r.first_sent_at)),
        line('Cleared', r.cleared_at == null ? null : fmtTime(r.cleared_at)), line('Channels', chans),
        line('Sends', r.sends), line('Firing', r.occurrence)].filter((x): x is HTMLDivElement => !!x)));
}

// oneLine: a cell's text on one line, clipped, the whole of it in the title
const oneLine = (v: unknown): HTMLElement | string => {
  const t = v == null ? '' : String(v);
  return t ? el('span', { title: t, style: 'display:inline-block;max-width:16rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;vertical-align:bottom' }, t) : '';
};

// triageView: one row per open alert; a box per row and DBA Dash's four actions on the rows ticked
function triageView(ctx: Ctx, ad: AckData, all: Row[], redraw: () => void, fixes: Map<string, string> = new Map(), dismissed: Map<string, Row> = new Map()): HTMLElement {
  let showClosed = false, showDismissed = false;
  const picked = new Set<string>();
  const shown = () => all.filter(r => (showClosed || r.close_id == null) && (showDismissed || !dismissed.has(String(r.finding_key))));
  // the rows the grid draws now: its own column filters drop rows from the drawing, the Show toggles from shown()
  const boxes = (): HTMLInputElement[] => Array.from(wrap.querySelectorAll<HTMLInputElement>('input[type=checkbox][data-key]'));
  const drawnKeys = () => new Set(boxes().map(b => String(b.dataset.key)));
  const wrap = el('div', {});
  const said = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  // on a demo serve the list's one sentence for 'Mute similar' (a rule on every instance: off in every row for the
  // same reason); a button off for its own reason says it beside itself. A server that writes nothing has the page's
  // one sentence (ad.note), and every off button points at that.
  const muteOff = !ad.writable && ad.door
    ? el('p', { class: 'meta' }, "Mute similar is off here: a rule on every instance would reach past the demo's instances (use Mute this alert, or pgvigil serve with a signed-in user).")
    : undefined;
  // an action takes the ticked rows still drawn: a row hidden since by a filter or a Show toggle is left alone
  const pickedRows = () => { const on = drawnKeys(); return all.filter(r => picked.has(String(r.finding_key)) && on.has(String(r.finding_key))); };
  const act = (label: string, run: () => void) => writeButton(ad, label, label + ' (the ticked alerts)', () => {
    if (!pickedRows().length) { said.textContent = 'Tick one or more alerts first.'; return; }
    run();
  }, { instance: 'any' });
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
  const dismissSel = act('Dismiss with a reason', () => {
    const keys = pickedRows().map(r => String(r.finding_key)).filter(k => !dismissed.has(k));
    if (!keys.length) { said.textContent = 'Every ticked alert is already dismissed.'; return; }
    dismissDialog(keys, redraw);
  });
  const closedBtn = el('button', { type: 'button', class: 'toggle', 'aria-pressed': 'false' }, 'Show closed');
  const dismissedBtn = el('button', { type: 'button', class: 'toggle', 'aria-pressed': 'false' }, `Show dismissed (${all.filter(r => dismissed.has(String(r.finding_key))).length})`);
  // tick all: every row the grid draws now (its filters and the Show toggles respected; nothing redrawn)
  const allBox = el('input', { type: 'checkbox', 'aria-label': 'tick every alert shown' });
  const syncAll = () => {
    const bs = boxes();
    allBox.checked = bs.length > 0 && bs.every(b => b.checked);
    allBox.indeterminate = !allBox.checked && bs.some(b => b.checked);
  };
  allBox.addEventListener('change', () => {
    picked.clear();
    for (const b of boxes()) { b.checked = allBox.checked; if (b.checked) picked.add(String(b.dataset.key)); }
    said.textContent = `${pickedRows().length} ticked.`;
  });
  const draw = () => {
    const rows = shown();
    const cols: Col[] = [
      { key: '_pick', label: 'select', fmt: (_v, r) => {
        const b = el('input', { type: 'checkbox', 'data-key': String(r.finding_key), 'aria-label': `select ${String(r.instance)} ${String(r.setting ?? r.source ?? '')}` });
        b.checked = picked.has(String(r.finding_key));
        b.addEventListener('change', () => {
          if (b.checked) picked.add(String(r.finding_key)); else picked.delete(String(r.finding_key));
          said.textContent = `${pickedRows().length} ticked.`;
          syncAll();
        });
        return b;
      } },
      { key: 'severity', fmt: sevBadge },
      { key: 'instance' },
      { key: 'setting', label: 'alert', fmt: (v, r) => el('a', { href: alertHref(r.finding_key, r.first_sent_at, ctx), title: 'open the alert\'s page' },
        oneLine([r.source, v].filter(x => x != null && x !== '').map(String).join(': '))) },
      // one line per row: the value clipped, whole in its title
      { key: 'value', label: 'detail', fmt: (v, r) => detailCell(v, r) },
      { key: 'first_sent_at', label: 'first sent', fmt: fmtTime },
      { key: 'sends', label: 'sends', num: true, fmt: (v, r) => el('span', { title: `last sent ${fmtTime(r.last_sent_at)} to ${list(r.channels)}` }, String(v ?? '')) },
      { key: '_state', label: 'state', fmt: (_v, r) => oneLine([
        r.ack_id != null ? `acknowledged by ${String(r.acked_by)} ${fmtTime(r.acked_at)}` : '',
        r.held_by != null ? `held by ${String(r.held_by)}` : '',
        r.is_blackout ? 'blackout' : '',
        r.resolved ? `resolved ${fmtTime(r.resolved_at)}` + (r.close_id != null ? `, closed by ${String(r.closed_by)}` : '') : '',
        r.known_noise != null ? `known: ${String(r.known_noise)}` : '',
        dismissed.has(String(r.finding_key)) ? `dismissed by ${String(dismissed.get(String(r.finding_key))?.created_by)}: ${String(dismissed.get(String(r.finding_key))?.reason ?? '')}` : '',
      ].filter(Boolean).join(' \u00b7 ')) },
      { key: '_fix', label: 'fix', fmt: (_v, r) => fixCell(fixes.get(String(r.finding_key))) },
      { key: 'notes', label: 'notes', num: true, fmt: (v, r) => Number(v) ? oneLine(`${String(v)}: ${String(r.last_note ?? '')}`) : '' },
      { key: '_mute', label: 'mute', fmt: (_v, r) => el('span', { style: 'white-space:nowrap' },
        writeButton(ad, 'Mute this alert', `Mute this alert: ${String(r.instance)} ${String(r.setting ?? '')}`, () => ackDialog({
          title: 'Mute this alert', what: `${String(r.instance)}: ${String(r.source ?? '')} ${String(r.setting ?? '')}. Its sends are held while the mute stands and logged under Held sends.`,
          body: { kind: 'mute', instance_id: Number(r.instance_id) || undefined, finding_key: String(r.finding_key) }, expiry: true, noteField: 'optional', after: redraw }),
          { instance: Number(r.instance_id) || null, name: String(r.instance ?? '') }),
        ' · ',
        writeButton(ad, 'Mute similar', `Mute similar: ${String(r.setting ?? r.source ?? '')} on every instance`, () => ackDialog({
          title: 'Mute similar alerts', what: 'Every alert matching the fields below is held while the rule stands (every instance unless one is named), and logged under Held sends.',
          body: { kind: 'mute', check_key: String(r.setting ?? r.source ?? '') }, expiry: true, matchFields: true, noteField: 'optional', after: redraw }), { note: muteOff })) },
    ];
    wrap.replaceChildren(...(muteOff ? [muteOff] : []), grid(rows, cols, all.length ? 'Every open alert is closed or dismissed: Show closed and Show dismissed list them.' : 'No open alert: nothing sent is still standing.'));
    syncAll();
  };
  // a filter or sort of the grid redraws its rows: the box follows what is drawn
  wrap.addEventListener('input', () => queueMicrotask(syncAll));
  wrap.addEventListener('click', () => queueMicrotask(syncAll));
  closedBtn.addEventListener('click', () => { showClosed = !showClosed; closedBtn.setAttribute('aria-pressed', String(showClosed)); draw(); });
  dismissedBtn.addEventListener('click', () => { showDismissed = !showDismissed; dismissedBtn.setAttribute('aria-pressed', String(showDismissed)); draw(); });
  draw();
  return el('div', {}, el('div', { class: 'toolbar' }, el('label', { class: 'tick-all' }, allBox, ' all shown'),
    el('div', { class: 'seg', role: 'group', 'aria-label': 'Actions' }, ackSel, clearSel, noteSel, closeSel, dismissSel), el('div', { class: 'seg' }, closedBtn, dismissedBtn)), said, wrap);
}

// fixCell: a finding's fix statement, clipped, with a Copy button (the whole statement in the title)
function fixCell(fix: string | undefined): HTMLElement | string {
  if (!fix) return '';
  const said = el('span', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const b = el('button', { type: 'button', class: 'link', 'aria-label': `Copy the fix statement: ${fix}` }, 'Copy');
  b.addEventListener('click', async () => { said.textContent = (await copyText(fix)) ? ' copied' : ' copy refused'; });
  return el('span', { style: 'white-space:nowrap' }, el('code', { title: fix, style: 'display:inline-block;max-width:14rem;overflow:hidden;text-overflow:ellipsis;vertical-align:bottom' }, fix), ' ', b, said);
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
    body: { kind: 'silence', instance_id: Number(sel.value) }, expiry: true, noteField: 'optional', after: redraw }), { instance: 'any' });
  const blackout = writeButton(ad, 'Blackout', 'A blackout window for the instance picked', () => ackDialog({
    title: `Blackout '${String(pick()?.name ?? '')}'`,
    what: 'From the start to the end the server\'s alerts are held (still logged) and flagged blackout.',
    body: { kind: 'blackout', instance_id: Number(sel.value) }, expiry: false, blackout: true, noteField: 'optional', after: redraw }), { instance: 'any' });
  const cols: Col[] = [
    { key: 'kind', fmt: v => v === 'silence' ? 'silenced' : 'blackout' },
    { key: 'instance' },
    { key: 'starts_at', label: 'from', fmt: fmtTime },
    ...whenCols,
    { key: 'note', wide: true },
    { key: 'held_alerts', label: 'alerts held', num: true },
    { key: 'held_last', label: 'last held', fmt: fmtTime },
    { key: '_end', label: '', fmt: (_v, r) => ackOn(ad, Number(r.instance_id) || null) ? endButton(Number(r.ack_id), `${r.kind === 'silence' ? 'Unsilence' : 'End the blackout of'} ${String(r.instance)}`, redraw, r.kind === 'silence' ? 'Unsilence' : 'End') : '' },
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
    body: { kind }, expiry: true, matchFields: true, noteField: kind === 'noise' ? 'label' : 'optional', after: redraw }), { instance: 'any' });
  const cols: Col[] = [
    { key: 'check_key', label: 'check' },
    { key: 'instance' },
    { key: 'tag' },
    { key: 'match_text', label: 'text' },
    { key: 'finding_key', label: 'one alert', fmt: v => v == null ? '' : 'yes' },
    { key: 'note', label: kind === 'noise' ? 'label' : 'note', wide: true },
    ...whenCols,
    ...(kind === 'mute' ? [{ key: 'held_alerts', label: 'alerts held', num: true }, { key: 'held_last', label: 'last held', fmt: fmtTime }] as Col[] : []),
    { key: '_end', label: '', fmt: (_v, r) => ackOn(ad, Number(r.instance_id) || null) ? endButton(Number(r.ack_id), `Remove the ${kind === 'mute' ? 'mute rule' : 'known pattern'} ${String(r.ack_id)}`, redraw, 'Remove') : '' },
  ];
  return el('div', {}, el('h3', {}, kind === 'mute' ? 'Mute rules' : 'Known patterns'),
    el('div', { class: 'seg' }, mk),
    grid(rows, cols, kind === 'mute' ? 'No mute rule: a quiet send log is genuine, not muted.' : 'No known pattern.'));
}

// mutesView: the mute rules (held sends still logged) or the known patterns (a label beside the alert, nothing held),
// with the rules that start later, the paused ones and the successor of an edit (K07.09)
function mutesView(ctx: Ctx, ad: AckData, all: Row[], kind: 'mute' | 'noise', insts: Row[], redraw: () => void): HTMLElement {
  const rows = all.filter(r => r.kind === kind);
  let showEnded = false;
  const word = kind === 'mute' ? 'mute rule' : 'known pattern';
  const mk = writeButton(ad, kind === 'mute' ? 'New mute rule' : 'New known pattern', `New ${word}`, () => muteDialog({ kind, insts, after: redraw }), { instance: 'any' });
  const endedBtn = el('button', { type: 'button', class: 'toggle', 'aria-pressed': 'false' }, 'Show ended (7 days)');
  const wrap = el('div', {});
  const change = (r: Row, op: 'pause' | 'resume') => async () => {
    if (!window.confirm(op === 'pause' ? `Pause mute rule ${String(r.ack_id)}? It holds nothing until it is resumed; the row stays.` : `Resume mute rule ${String(r.ack_id)}? It holds its matches again from the sender's next pass.`)) return;
    try { await post('alerts/mute', { op, ack_id: Number(r.ack_id) }); } catch (e) { window.alert(e instanceof Error ? e.message : String(e)); }
    redraw();
  };
  const draw = () => {
    const vis = rows.filter(r => showEnded || r.state !== 'ended' && r.state !== 'expired');
    const cols: Col[] = [
      { key: 'state', fmt: (v, r) => badge(String(v ?? '') + (v === 'paused' ? ` by ${String(r.paused_by ?? '')}` : ''), v === 'in force' ? 'ok' : v === 'upcoming' || v === 'paused' ? 'warn' : '') },
      { key: 'check_key', label: 'check' },
      { key: 'instance' },
      { key: 'tag' },
      { key: 'match_text', label: 'text' },
      { key: 'finding_key', label: 'one alert', fmt: v => v == null ? '' : el('a', { href: alertHref(v, undefined, ctx) }, 'yes') },
      { key: 'note', label: kind === 'noise' ? 'label' : 'note', wide: true },
      { key: 'starts_at', label: 'starts', fmt: (v, r) => v == null ? `at once (${fmtTime(r.created_at)})` : fmtTime(v) },
      { key: 'until', fmt: v => v == null ? 'no expiry' : fmtTime(v) },
      { key: 'created_at', label: 'made', fmt: (v, r) => `${fmtTime(v)} by ${String(r.created_by)}` + (r.replaces != null ? ` (replaces ${String(r.replaces)})` : '') },
      ...(kind === 'mute' ? [{ key: 'held_alerts', label: 'alerts held', num: true }, { key: 'held_last', label: 'last held', fmt: fmtTime }] as Col[] : []),
      { key: 'ended_at', label: 'ended', fmt: (v, r) => v == null ? '' : `${fmtTime(v)} by ${String(r.ended_by ?? '')}` + (r.replaced_by != null ? ` (edited: rule ${String(r.replaced_by)})` : '') },
      { key: '_act', label: '', fmt: (_v, r) => r.state === 'ended' || r.state === 'expired' || !ackOn(ad, Number(r.instance_id) || null) ? '' : el('span', { style: 'white-space:nowrap' },
        writeButton(ad, 'Edit', `Edit the ${word} ${String(r.ack_id)}`, () => muteDialog({ kind, insts, rule: r, after: redraw }), { instance: Number(r.instance_id) || null }), ' \u00b7 ',
        ...(kind === 'mute' ? [r.paused_at != null
          ? writeButton(ad, 'Resume', `Resume the mute rule ${String(r.ack_id)}`, change(r, 'resume'), { instance: Number(r.instance_id) || null })
          : writeButton(ad, 'Pause', `Pause the mute rule ${String(r.ack_id)}`, change(r, 'pause'), { instance: Number(r.instance_id) || null }), ' \u00b7 '] : []),
        endButton(Number(r.ack_id), `Remove the ${word} ${String(r.ack_id)}`, redraw, 'Remove')) },
    ];
    wrap.replaceChildren(grid(vis, cols, kind === 'mute' ? 'No mute rule: a quiet send log is genuine, not muted.' : 'No known pattern.'));
  };
  endedBtn.addEventListener('click', () => { showEnded = !showEnded; endedBtn.setAttribute('aria-pressed', String(showEnded)); draw(); });
  draw();
  return el('div', {}, el('h3', {}, kind === 'mute' ? 'Mute rules' : 'Known patterns'), el('div', { class: 'seg' }, mk, endedBtn), wrap);
}

interface MuteDialog { kind: 'mute' | 'noise'; insts: Row[]; rule?: Row; after: () => void }

const untilHours: [string, number][] = [['no expiry', 0], ['1 hour after the start', 1], ['4 hours after the start', 4], ['1 day after the start', 24], ['7 days after the start', 168], ['a time ...', -1]];

// muteDialog: a new mute rule or known pattern, or the edit of one (its successor: the server ends the old rule in the
// same call); every field filled must match, a start time sets the rule ahead of planned work
function muteDialog(o: MuteDialog) {
  const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  const r = o.rule;
  const word = o.kind === 'mute' ? 'mute rule' : 'known pattern';
  const text = (v: unknown, label: string) => el('input', { type: 'text', maxlength: '200', 'aria-label': label, value: v == null ? '' : String(v) });
  const check = text(r?.check_key, 'check'), tag = text(r?.tag, 'tag'), match = text(r?.match_text, 'text');
  const inst = el('select', { 'aria-label': 'instance' }, el('option', { value: '' }, 'any instance'),
    ...o.insts.map(i => el('option', { value: String(i.instance_id) }, String(i.name))));
  // the rule's own instance stays picked even when the instance list lacks it (removed since, or the list not read):
  // an edit never widens a rule to every instance unless 'any instance' is picked by hand
  const KEEP = 'keep';
  if (r?.instance != null && r.instance !== '') {
    if (r.instance_id != null && o.insts.some(i => String(i.instance_id) === String(r.instance_id))) inst.value = String(r.instance_id);
    else { inst.append(el('option', { value: KEEP }, `${String(r.instance)} (kept: not in the instance list now)`)); inst.value = KEEP; }
  }
  const tagList = el('datalist', { id: 'mute-tags' }, ...[...new Set(o.insts.flatMap(tagsOf))].sort().map(t => el('option', { value: t })));
  tag.setAttribute('list', 'mute-tags');
  const note = el('textarea', { rows: '2', maxlength: '2000', style: 'width:100%', 'aria-label': o.kind === 'noise' ? 'label' : 'note' });
  note.value = String(r?.note ?? '');
  const startNow = el('input', { type: 'checkbox', 'aria-label': 'start at once' });
  const starts = el('input', { type: 'datetime-local', 'aria-label': 'starts' });
  const future = r?.starts_at != null && Date.parse(String(r.starts_at)) > Date.now();
  startNow.checked = !future;
  starts.value = toInput(future ? new Date(String(r!.starts_at)) : new Date(Date.now() + 3600e3));
  starts.disabled = startNow.checked;
  const untilSel = el('select', { 'aria-label': 'until' }, ...untilHours.map(([t, h]) => el('option', { value: String(h) }, t)));
  const untilAt = el('input', { type: 'datetime-local', 'aria-label': 'until time' });
  if (r?.until != null) { untilSel.value = '-1'; untilAt.value = toInput(new Date(String(r.until))); } else { untilSel.value = o.kind === 'mute' && !r ? '24' : '0'; untilAt.value = toInput(new Date(Date.now() + 86400e3)); }
  const widen = el('input', { type: 'checkbox', 'aria-label': 'match every instance' });
  const widenBox = el('label', { hidden: '' }, widen, ' match every instance (the rule names one now)');
  widen.addEventListener('change', () => checkOk());
  const sync = () => {
    starts.disabled = startNow.checked; untilAt.hidden = untilSel.value !== '-1';
    widenBox.hidden = !(r && r.instance != null && r.instance !== '' && inst.value === '');
    checkOk();
  };
  const ok = el('button', { type: 'submit' }, r ? 'Save the edit' : 'Save'), no = el('button', { type: 'button' }, 'Back');
  const need = el('p', { class: 'meta' });
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const startAt = (): Date => startNow.checked ? new Date() : fromInput(starts.value);
  const untilOf = (): Date | null => {
    const h = Number(untilSel.value);
    if (h === 0) return null;
    if (h < 0) return fromInput(untilAt.value);
    return new Date(startAt().getTime() + h * 3600e3);
  };
  const invalid = (): string => {
    if (!check.value.trim() && !tag.value.trim() && !match.value.trim() && !inst.value && r?.finding_key == null) return 'a check, an instance, a tag or a text (a rule matching every alert is refused)';
    if (r && r.instance != null && r.instance !== '' && inst.value === '' && !widen.checked) return 'the box "match every instance" ticked (the rule names an instance now; Any instance widens it to the whole fleet)';
    if (o.kind === 'noise' && !note.value.trim()) return 'a label';
    if (!startNow.checked && isNaN(startAt().getTime())) return 'a start time';
    const u = untilOf();
    if (u && (isNaN(u.getTime()) || u.getTime() <= Math.max(Date.now(), startAt().getTime()))) return 'an end after the start and after now';
    return '';
  };
  let done = false, busy = false;
  function checkOk() { const w = done ? '' : invalid(); need.textContent = w ? `Saving needs ${w}.` : ''; ok.disabled = busy || done || w !== ''; }
  for (const x of [check, tag, match, note, starts, untilAt]) x.addEventListener('input', checkOk);
  for (const x of [inst, untilSel, startNow]) x.addEventListener('change', sync);
  const fields: HTMLElement[] = [
    el('p', { class: 'meta' }, 'An alert matches when every field filled matches (check: its source or setting; text: in its source, setting or value).' + (r?.finding_key != null ? ' This rule names one alert: that stays.' : '')),
    el('span', {}, el('label', {}, 'Check ', check), ' ', el('label', {}, 'Instance ', inst), ' ', widenBox),
    el('span', {}, el('label', {}, 'Tag ', tag), tagList, ' ', el('label', {}, 'Text ', match)),
    el('label', {}, o.kind === 'noise' ? 'Label (shown beside matching alerts)' : 'Note (optional)', el('br'), note),
    el('span', {}, el('label', {}, startNow, ' start at once'), ' ', el('label', {}, 'or at ', starts)),
    el('span', {}, el('label', {}, 'Until ', untilSel), ' ', untilAt),
  ];
  const what = r
    ? `The edit ends ${word} ${String(r.ack_id)} and writes its successor in one step (a paused rule stays paused); the old row stays with who ended it.`
    : o.kind === 'mute' ? 'Alerts matching the rule are held while it stands (from its start to its end) and logged under Held sends.' : 'Alerts matching the pattern carry its label; nothing is held.';
  const form = el('form', { method: 'dialog' }, el('h3', {}, r ? `Edit the ${word} ${String(r.ack_id)}` : `New ${word}`), el('p', {}, what),
    ...fields.map(f => el('div', { style: 'margin:.3rem 0' }, f)), need, msg, el('div', { style: 'margin-top:.6rem' }, ok, ' ', no));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:40rem', 'aria-label': r ? `Edit the ${word}` : `New ${word}` }, form);
  const leave = () => { dlg.remove(); if (done) o.after(); else if (opener?.isConnected) opener.focus(); };
  no.addEventListener('click', () => { dlg.close(); leave(); });
  dlg.addEventListener('cancel', leave);
  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    if (busy || done || invalid()) return;
    busy = true; checkOk(); msg.textContent = 'Saving...';
    const u = untilOf();
    const body: Record<string, unknown> = {
      instance_id: inst.value && inst.value !== KEEP ? Number(inst.value) : undefined,
      any_instance: r && inst.value === '' ? true : undefined,
      check_key: check.value.trim() || undefined, tag: tag.value.trim() || undefined,
      match_text: match.value.trim() || undefined, note: note.value.trim() || undefined,
      starts_at: startNow.checked ? undefined : startAt().toISOString(), until: u ? u.toISOString() : undefined,
    };
    try {
      const res = r
        ? await post<{ outcome: string; detail: string }>('alerts/mute', { op: 'edit', ack_id: Number(r.ack_id), ...body })
        : await addAck({ kind: o.kind, ...body, any_instance: undefined } as Parameters<typeof addAck>[0]);
      done = true;
      msg.replaceChildren(badge(res.outcome, 'ok'), ' ', res.detail);
      no.textContent = 'Close';
    } catch (e) {
      msg.replaceChildren(badge('not saved', 'crit'), ' ', e instanceof Error ? e.message : String(e));
    } finally { busy = false; checkOk(); }
  });
  sync();
  document.body.append(dlg);
  dlg.showModal();
  check.focus();
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
  { key: 'value', label: 'detail', fmt: (v, r) => detailCell(v, r) },
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

// ---- Admin (task 177 D30: PerformanceMonitor's Admin page - its Servers, Notification Routes, Alert Settings, Threshold
// Overrides and Server actions tabs) -------------------------------------------------------------------------------------
// What this pgvigil runs with, in one place and read only: the configuration file (pgvigil.yaml) and Admin > Instances are
// the sources of the instances; the file is the source of the channels and the action switches, and the alert rules are written on Alert rules (each tab says where a
// change is made). The tab rides in the address (atab=). The route and the tab are the shell's (a WIRING BLOCK).
// builtIn: PerformanceMonitor's defaults pgvigil judges as findings (migration 0118; MIT, Erik Darling, Darling Data, LLC)
const builtIn: Row[] = [
  { finding: 'dead tuples piling up', engine: 'PostgreSQL', warning: '1,000,000 dead tuples in a table', critical: '10,000,000', from: 'template pg-autovacuum-dead-tuples' },
  { finding: 'replay lag', engine: 'PostgreSQL', warning: '30 s', critical: '5 min', from: 'template pg-replication-lag' },
  { finding: 'replication slot retaining WAL', engine: 'PostgreSQL', warning: '10 GB', critical: '50 GB', from: 'template pg-replication-slot-wal' },
  { finding: 'a volume under 5 GB free', engine: 'SQL Server', warning: 'under 5 GB free, on a volume over 10 GB whose percent threshold (Drives) raises nothing', critical: '2 GB or less (the same volumes: needs a percent threshold under 20 %)', from: 'LowDiskThresholdGb, DiskCriticalFreeGb' },
  { finding: 'AG secondary behind', engine: 'SQL Server', warning: '300 s behind the primary', critical: '', from: 'agLagAlertSeconds' },
  { finding: 'runnable queue per scheduler', engine: 'SQL Server', warning: '8 per scheduler (5 min)', critical: '16', from: 'RunnableQueueWarning / CriticalPerScheduler' },
  { finding: 'long-running requests', engine: 'SQL Server', warning: '30 min (BACKUP, RESTORE, WAITFOR, Service Broker waits and system sessions left out)', critical: '', from: 'LongRunningQueryThresholdMinutes, LongRunningQueryExcludeBackups' },
  { finding: 'server unreachable', engine: 'both', warning: '', critical: 'the newest read could not connect or log in', from: 'Server Unreachable (ConnectionAlertPolicy)' },
];
export async function adminView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', { class: 'admin' }, el('h2', {}, 'Admin'),
    el('p', { class: 'meta' }, 'What this pgvigil runs with, read only: the configuration file (pgvigil.yaml) and ', el('a', { href: href(ctx, { tab: 'admin_instances', instance: undefined }) }, 'Admin > Instances'), ' are the sources of the servers (a page change applies within 15 seconds, a file change takes a reload of the service); the configuration file is the source of the notification channels and the action switches; the alert rules and their overrides are written on ',
      el('a', { href: href(ctx, { tab: 'alertrules', instance: undefined }) }, 'Alert rules'), '; acknowledgements, mutes and channel tests on ', el('a', { href: href(ctx, { tab: 'alerts', instance: undefined }) }, 'Alerts'), '.'));
  const tabs: [string, string, () => Promise<HTMLElement>][] = [
    ['servers', 'Servers', async () => {
      const insts = (await fleet()).instances;
      const want = ['name', 'engine', 'platform', 'server_version', 'is_replica', 'tags', 'last_seen', 'collections_failing'];
      const keys = want.filter(k => insts.some(r => k in r));
      return el('div', {}, el('p', { class: 'meta' }, `${insts.length} server(s) in the repository: each named in pgvigil.yaml (instances:) or on Admin > Instances, and read by the collector at least once (a server never reached is listed after its first read); last seen and the collections failing now.`),
        grid(insts, keys.map(k => ({ key: k, ...(k === 'name' ? { fmt: (v: unknown, r: Row) => el('a', { href: href(ctx, { tab: 'summary', instance: Number(r.instance_id) }) }, String(v)) } : {}),
          ...(k === 'last_seen' ? { label: 'last seen', fmt: fmtTime } : {}), ...(k === 'collections_failing' ? { label: 'collections failing', num: true } : {}),
          ...(k === 'is_replica' ? { label: 'replica', fmt: (v: unknown) => v ? 'yes' : '' } : {}),
          ...(k === 'tags' ? { fmt: (v: unknown) => Array.isArray(v) ? v.join(', ') : String(v ?? '') } : {}) })), 'No server in the repository yet.'));
    }],
    ['routes', 'Notification routes', async () => {
      const d = await get<AlertsData>('alerts', { ...window_(ctx), part: 'channels' });
      const all = rowsOf(d.channels);
      const rows = all.filter(r => r.is_configured !== false);
      const gone = all.length - rows.length;
      const cols = ['name', 'kind', 'destination', 'min_severity', 'instances', 'tags', 'quiet_hours', 'repeat_secs', 'recovery', 'open_alerts', 'last_outcome', 'last_error'];
      return el('div', {}, el('p', { class: 'meta' }, `${rows.length} channel(s) (the configuration's alerts:): where each alert goes, from which severity, and for which instances.${gone ? ` ${gone} channel(s) no longer in the configuration are left out (Alerts lists them).` : ''}`),
        grid(rows, cols.map(k => ({ key: k, ...(/destination|instances|tags|last_error/.test(k) ? { wide: true } : {}), ...(k === 'min_severity' ? { label: 'from severity' } : {}),
          ...(k === 'repeat_secs' ? { label: 'repeat (s)', num: true } : {}), ...(k === 'open_alerts' ? { label: 'open alerts', num: true } : {}),
          ...(k === 'recovery' ? { fmt: (v: unknown) => v ? 'on' : 'off' } : {}), ...(/instances|tags/.test(k) ? { fmt: (v: unknown) => Array.isArray(v) ? (v.length ? v.join(', ') : 'all') : String(v ?? '') } : {}) })),
          'No channel in the configuration: the alert sender has not run with a channel configured.'));
    }],
    ['settings', 'Alert settings', async () => {
      const d = await get<{ rules?: Table | null; inforce?: Table | null; sender?: Table | null }>('alertrules', window_(ctx));
      const on = rowsOf(d.rules).filter(r => r.live && r.enabled);
      const noChannel = Number(rowsOf(d.sender)[0]?.channels ?? 0) === 0;
      return el('div', {},
        on.length ? el('p', { class: 'will-alert' }, willAlert(on, r => String(r.name ?? `${String(r.family_label ?? '')}: ${String(r.label ?? r.metric)}`), noChannel)) : el('p', { class: 'meta' }, 'No alert rule is switched on.'),
        el('h3', {}, 'Built-in thresholds (PerformanceMonitor\'s defaults)'),
        grid(builtIn, [{ key: 'finding' }, { key: 'engine' }, { key: 'warning' }, { key: 'critical' }, { key: 'from', label: 'PerformanceMonitor\'s setting', wide: true }]),
        el('h3', {}, 'Thresholds in force per instance'),
        rowsOf(d.inforce).length > 500 ? el('p', { class: 'meta' }, `The first 500 of ${rowsOf(d.inforce).length} rows; Alert rules lists them all.`) : '',
        grid(rowsOf(d.inforce).slice(0, 500), Object.keys(rowsOf(d.inforce)[0] ?? {}).filter(k => !k.startsWith('_') && k !== 'tags').slice(0, 9).map(k => ({ key: k })), 'No threshold in force.'));
    }],
    ['overrides', 'Threshold overrides', async () => {
      const d = await get<{ rules?: Table | null }>('alertrules', window_(ctx));
      const live = rowsOf(d.rules).filter(r => r.live);
      const insts = (await fleet()).instances;
      // a wider rule on the same metric and database; a tag rule only where the instance carries that tag
      const same = (w: Row, r: Row) => w.metric === r.metric && String(w.database ?? '') === String(r.database ?? '');
      const over = (r: Row): string => {
        const wide = live.find(w => w.scope === 'fleet' && same(w, r));
        const tags = r.scope === 'instance' ? tagsOf(insts.find(i => Number(i.instance_id) === Number(r.instance_id)) ?? {}) : [];
        const tag = r.scope === 'instance' ? live.find(w => w.scope === 'tag' && same(w, r) && tags.includes(String(w.tag))) : undefined;
        return tag ? `tag rule ${String(tag.rule_id)}${wide ? ` and fleet rule ${String(wide.rule_id)}` : ''}` : wide ? `fleet rule ${String(wide.rule_id)}` : 'none (no wider rule on this metric: a rule of its own scope)';
      };
      const rows = live.filter(r => r.scope !== 'fleet');
      return el('div', {}, el('p', { class: 'meta' }, 'A tag or an instance rule overrides a fleet rule on the same metric (an instance rule over a tag rule): made and edited on ',
        el('a', { href: href(ctx, { tab: 'alertrules', instance: undefined }) }, 'Alert rules'), ' (its Thresholds in force line opens an override).'),
        grid(rows, [{ key: 'rule_id', label: 'rule', num: true }, { key: 'metric', fmt: (v, r) => `${String(r.family_label ?? '')}: ${String(r.label ?? v)}` },
          { key: 'scope', label: 'covers', fmt: (v, r) => scopeWords(v, r.tag ?? r.instance_name) }, { key: 'op', label: 'alert when', fmt: (_v, r) => conditionWords(r) },
          { key: 'enabled', label: 'on', fmt: v => v ? 'on' : 'off' }, { key: 'overrides', fmt: (_v, r) => over(r) }], 'No override: every live rule covers the fleet.'));
    }],
    ['actions', 'Server actions', async () => {
      const ms = (await fleet()).instances.filter(r => r.engine === 'sqlserver');
      const rows: Row[] = [];
      for (let i = 0; i < ms.length; i += 8) {      // eight at a time: a large fleet in a few round trips, the server not flooded
        const part = ms.slice(i, i + 8);
        const sts = await Promise.all(part.map(r => mssqlActionsState(Number(r.instance_id))));
        part.forEach((r, j) => { for (const k of ['kill', 'job_start', 'job_stop'] as const) rows.push({ instance: r.name, instance_id: r.instance_id, action: k, state: sts[j].actions[k]?.enabled ? 'on' : 'off', reason: sts[j].actions[k]?.reason ?? '' }); });
      }
      return el('div', {}, el('p', { class: 'meta' }, 'Each SQL Server instance\'s action switches (the configuration\'s actions: allow list and the login\'s rights) and why one is off; each instance\'s Actions page does them.'),
        grid(rows, [{ key: 'instance', fmt: (v, r) => el('a', { href: href(ctx, { tab: 'mssqlactions', instance: Number(r.instance_id) }) }, String(v)) }, { key: 'action' },
          { key: 'state', fmt: v => badge(String(v), v === 'on' ? 'ok' : '') }, { key: 'reason', label: 'why off', wide: true }], 'No SQL Server instance.'));
    }],
  ];
  let cur = new URLSearchParams(location.hash.split('?')[1] ?? '').get('atab') ?? 'servers';
  if (!tabs.some(t => t[0] === cur)) cur = 'servers';
  const seg = el('div', { class: 'seg', role: 'group', 'aria-label': 'Admin tabs' });
  const body = el('div', { class: 'admin-body' });
  const btns = new Map<string, HTMLButtonElement>();
  let seq = 0;
  const show = async (k: string) => {
    cur = k; const mine = ++seq;     // a slower tab's answer arriving after a later click is dropped
    for (const [key, b] of btns) b.setAttribute('aria-pressed', String(key === k));
    const [path, qs] = location.hash.split('?'); const q = new URLSearchParams(qs ?? ''); q.set('atab', k); history.replaceState(null, '', `${path}?${q}`);
    body.replaceChildren(el('p', { class: 'meta' }, 'Loading...'));
    const t = tabs.find(x => x[0] === k)!;
    let out: HTMLElement;
    try { out = await t[2](); } catch (e) { if (mine === seq) body.replaceChildren(el('h3', {}, t[1]), errorBox(e)); return; }
    if (mine === seq) body.replaceChildren(el('h3', {}, t[1]), out);
  };
  for (const [k, label] of tabs) {
    const b = el('button', { type: 'button', class: 'toggle', 'aria-pressed': String(k === cur) }, label) as HTMLButtonElement;
    b.addEventListener('click', () => { void show(k); });
    btns.set(k, b); seg.append(b);
  }
  sec.append(seg, body);
  await show(cur);
  return sec;
}
