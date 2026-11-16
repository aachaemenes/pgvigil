// SQL Server errors (SQLMonitor's 'All Servers - Alert History' panels): every error of severity 17 or more and every
// number on its alert list at any severity (the Availability Group, corruption and configuration-change numbers),
// across the SQL Server instances in scope - by error number, then every message. Read from what pgvigil already
// stores (the error log's kept lines and AlwaysOn_health's error events, one event counted once): nothing is set up on
// a monitored server. The noise is the DBA's own: 'Mark as known noise' labels a number (or a text) and its lines leave
// the counts, shown again on demand; no list is built in. Data from GET /api/mssql/errorfleet.
import { get, Row, rowsOf, Table } from './api';
import { ackDialog, ackOn, endButton, loadAckSafe, writeButton } from './ack';
import type { Ctx } from './router';
import { href, rangeLabel, window_ } from './router';
import { fleet, inTagScope, tagWords } from './fleet';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';

type Part = Table | null;

// learnLink: Microsoft's page for an error number (the address SQLMonitor's panel uses); not every number has one.
// The documentation-link helper of the waits pages replaces this builder when both are on one branch.
export function learnLink(n: number): HTMLAnchorElement {
  return el('a', { href: `https://learn.microsoft.com/en-us/sql/relational-databases/errors-events/mssqlserver-${n}-database-engine-error`,
    target: '_blank', rel: 'noopener noreferrer', title: `Microsoft's page for error ${n} (not every number has one)` }, String(n));
}

const sevBadge = (v: unknown): string | Node => {
  if (v == null) return '';
  const n = Number(v);
  return badge(String(n), n >= 20 ? 'crit' : n >= 17 ? 'warn' : 'none');   // X18: under 17 = N/A, a status class on every badge
};

export async function mssqlErrorFleetView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `SQL Server errors (${rangeLabel(ctx)})`));
  const hq = new URLSearchParams(location.hash.split('?')[1] ?? '');
  const num = hq.get('n') ?? '';
  const noise = hq.get('noise') === '1';
  const to = (over: Record<string, string | undefined>): string => {
    const [path, qs] = href(ctx, { tab: 'mssqlerrors' }).split('?');
    const q = new URLSearchParams(qs ?? '');
    const next: Record<string, string | undefined> = { n: num || undefined, noise: noise ? '1' : undefined, ...over };
    for (const [k, v] of Object.entries(next)) { if (v) q.set(k, v); else q.delete(k); }
    return `${path}?${q.toString()}`;
  };
  const params: Record<string, string | number | undefined> = { ...window_(ctx), n: num || undefined, noise: noise ? 1 : undefined };
  let folder = 'every SQL Server instance';
  try {
    if (ctx.instance) { params.instance = ctx.instance; folder = 'this instance'; }
    else if (ctx.tag) {
      const fl = await fleet();
      params.instances = fl.instances.filter(r => inTagScope(ctx.tag!, r)).map(r => Number(r.instance_id)).join(',') || '0';
      folder = `the SQL Server instances of ${tagWords(ctx.tag!)}`;
    }
  } catch (e) { sec.append(errorBox(e)); return sec; }
  sec.append(el('p', { class: 'meta' },
    `Every error of severity 17 or more on ${folder}, and the numbers SQLMonitor alerts on at any severity (Availability Group role and `
    + 'data-movement events, 823 / 824 / 825, the configuration changes), from the error log\'s kept lines and AlwaysOn_health\'s error events '
    + '(an event in both is counted once). Severity 20 or more is critical. Known noise is what you label: its lines leave the counts and come '
    + 'back with Show known noise. Nothing is set up on a monitored server.'));

  const body = el('div');
  sec.append(body);
  const ad = await loadAckSafe(['acks']);
  let seq = 0;
  const draw = async (): Promise<void> => {
    const mine = ++seq;
    let d: Record<string, Part>;
    try { d = await get<Record<string, Part>>('mssql/errorfleet', params); } catch (e) { if (mine === seq) body.replaceChildren(errorBox(e)); return; }
    if (mine !== seq) return;
    const out: Node[] = [];
    const byErr = rowsOf(d.byerror), lines = rowsOf(d.lines), labels = rowsOf(d.noise), ag = rowsOf(d.agstate), cannot = rowsOf(d.cannot);
    for (const r of ag) out.push(el('p', { class: 'meta', role: 'note' }, badge('Not read', 'warn'),
      ` AlwaysOn_health not read on ${String(r.instance)}: ${String(r.state)} since ${fmtTime(r.since)} - the events only it holds (such as 1480's role changes) are not here; its errors written to the error log still are.`));
    const hidden = labels.reduce((s, r) => s + Number(r.hits ?? 0), 0);
    const bar = el('div', { class: 'toolbar' },
      el('a', { href: to({ noise: noise ? undefined : '1' }) }, noise ? 'Hide known noise' : `Show known noise (${fmtNum(hidden)} hidden)`));
    if (num) bar.append(' ', badge(`error ${num}`, ''), ' ', el('a', { href: to({ n: undefined }) }, 'Every number'));
    out.push(bar);
    // on an instance's page the label names that instance (the number stays counted elsewhere); at the root or a tag it
    // names none, and a tag or a text in the dialog narrows it. No expiry, as the Alerts page's known patterns: it lasts
    // until it is ended under Known noise.
    const one = ctx.instance ? Number(ctx.instance) : null;
    const markNoise = (n: number) => writeButton(ad, 'Mark as known noise', `Mark as known noise: error ${n}`, () => ackDialog({   // the name holds the visible words (WCAG 2.5.3)
      title: `Mark error ${n} as known noise`,
      what: `Its lines leave this page's counts (${one ? 'on this instance only' : 'on every instance, or those of the tag you give'}; with a text, only the lines whose message holds it) and come back with Show known noise. The label lasts until you End it under Known noise. The check 'error log:${n}' is this number; 'error log' with a text is the text under any number. Nothing is held: no alert matches these labels.`,
      body: { kind: 'noise', check_key: `error log:${n}`, ...(one ? { instance_id: one } : {}) }, expiry: false, noteField: 'label', matchFields: true, after: () => { void draw(); },
    }), { instance: one });
    const errCols: Col[] = [
      { key: 'error_number', label: 'error', fmt: v => learnLink(Number(v)) },
      { key: 'severity', num: true, fmt: sevBadge },
      { key: 'occurrences', num: true, fmt: (v, r) => el('a', { href: to({ n: String(r.error_number) }) }, fmtNum(v)) },
      { key: 'instances', num: true, fmt: (v, r) => el('a', { href: to({ n: String(r.error_number) }), title: `error ${String(r.error_number)}'s messages, each with its instance` }, fmtNum(v)) },
      { key: 'first_at', label: 'first', fmt: fmtTime }, { key: 'last_at', label: 'last', fmt: fmtTime },
      { key: 'message', label: 'latest message', wide: true },
      { key: 'hidden', label: 'known noise', num: true, fmt: v => v == null ? '' : fmtNum(v) },
      { key: 'mark', label: '', fmt: (_v, r) => markNoise(Number(r.error_number)) },
    ];
    out.push(el('h3', {}, 'By error number'), grid(byErr, errCols, 'No error of these severities or numbers in this range.'));
    const lineCols: Col[] = [
      { key: 'at', label: 'time', fmt: fmtTime },
      ...(ctx.instance ? [] : [{ key: 'instance', fmt: (v: unknown, r: Row) => el('a', { href: href(ctx, { tab: 'mssqlerrorlog', instance: Number(r.instance_id) }) }, String(v ?? '')) } as Col]),
      { key: 'error_number', label: 'error', fmt: v => learnLink(Number(v)) },
      { key: 'severity', num: true, fmt: sevBadge }, { key: 'state', num: true }, { key: 'class' }, { key: 'database' },
      // a line under a known-noise label (shown with Show known noise) is greyed
      { key: 'message', wide: true, fmt: (v: unknown, r: Row) => r.noise ? el('span', { class: 'meta' }, String(v ?? '')) : String(v ?? '') }, { key: 'source' },
      ...(noise ? [{ key: 'noise', label: 'known noise', fmt: (v: unknown) => v == null ? '' : el('span', { class: 'meta' }, String(v)) } as Col] : []),
    ];
    out.push(el('h3', {}, 'Every message'),
      el('p', { class: 'meta' }, `${fmtNum(lines.length)}${lines.length >= 1000 ? '+ (the newest 1,000)' : ''} message(s), newest first.`),
      grid(lines, lineCols, 'No message in this range.'));
    out.push(el('h3', {}, 'Known noise'), labels.length
      ? el('ul', {}, ...labels.map(l => el('li', {}, `${String(l.note ?? '')} - ${String(l.check_key)}${l.match_text ? `, text '${String(l.match_text)}'` : ''}`
          + `${l.instance ? `, ${String(l.instance)}` : ''}${l.tag ? `, tag ${String(l.tag)}` : ''}: ${fmtNum(l.hits ?? 0)} line(s) hidden`
          + `${l.check_key === 'error log' && !l.match_text ? ' (no number and no text: it hides nothing)' : ''} `,
          ackOn(ad, Number(l.instance_id) || null) ? endButton(Number(l.ack_id), `End the known-noise label ${String(l.note ?? '')}`, () => { void draw(); }) : '')))
      : el('p', { class: 'meta' }, 'No label yet: Mark as known noise on a number makes one. These labels also show in the Alerts page\'s list of known noise, where they match no alert.'));
    if (cannot.length) out.push(el('h3', {}, 'Not kept'), el('ul', {}, ...cannot.map(c => el('li', {}, `${String(c.error_number)}: ${String(c.why)}`))));
    body.replaceChildren(...out);
  };
  await draw();
  return sec;
}
