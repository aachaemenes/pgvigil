// The Alerts tab at the root (task 60): the channels the configuration's alerts: list names (SMTP, a webhook, a file
// drop) with each one's last attempt and last send, the alerts open now (a finding sent and not yet cleared), and every
// send attempt of the time range with its outcome and error text. Nothing is sent unless a channel is configured: with
// none the page says so. alertCol is the Findings tab's sent / when / where column (it reads the alert_* columns
// pgvigil.findings_alerts adds to each finding). Data from /api/alerts; the route, the root tab and the Findings
// column's place are the shell's.
import { get, Row, rowsOf, Table } from './api';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtSecs, fmtTime, grid } from './ui';

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

// alertsView: the Alerts tab
export async function alertsView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Alerts'));
  let d: AlertsData;
  try {
    d = await get<AlertsData>('alerts', window_(ctx));
  } catch (e) {
    sec.append(errorBox(e));
    return sec;
  }
  const chans = rowsOf(d.channels), open = rowsOf(d.open), log = rowsOf(d.log);
  const configured = chans.filter(r => r.is_configured);
  const failed = log.filter(r => r.outcome === 'failed' || r.outcome === 'refused').length;
  sec.append(el('p', { class: 'meta' }, configured.length === 0
    ? 'No alert channel is configured: pgvigil sends nothing. A channel is named in the configuration\'s alerts: list (SMTP, a webhook or a file drop); see docs/alerts.md.'
    : `${configured.length} channel(s) configured, ${open.length} alert(s) open, ${log.length} send attempt(s) ${rangeLabel(ctx)}, ${failed} failed or refused.`));
  sec.append(el('h3', {}, 'Channels'),
    grid(chans, channelCols, 'No channel recorded: the alert sender has not run with a channel configured.'));
  sec.append(el('h3', {}, 'Open alerts'),
    grid(open, openCols, 'No open alert: nothing sent is still standing.'));
  sec.append(el('h3', {}, `Send log ${rangeLabel(ctx)}`),
    grid(log, logCols, 'No send attempt in the time range.'));
  return sec;
}

// alertCol: the Findings tab's column - sent, when (the last send) and where (the channels); empty when not sent
export const alertCol: Col = {
  key: 'alert_last_sent', label: 'alerted',
  fmt: (v, r) => v == null ? '' : el('span', { title: `first sent ${fmtTime(r.alert_first_sent)}, ${fmtNum(r.alert_sends)} send(s)` },
    `sent ${fmtTime(v)} to ${list(r.alert_channels)}`),
};
