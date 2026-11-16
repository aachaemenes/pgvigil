// Collector errors (DBA Dash's Checks > DBA Dash ErrorLog): every run of a collection that did not end well, kept 30
// days, and the service's own failures where they are stored (alert sends, report mails, DBA Dash repositories not
// read, a Parquet export failing or behind) as '(the service)' rows, at the root and in a folder. Three views over one row set - a row per instance, per
// collection, per error - each name and count narrowing the page in place (its address carries the filters, so Back
// goes up and a narrowed view is a link). Types: Error, Warning (the run finished with a part that failed), Skipped
// (hidden unless shown). Stages: Connect, Collect, Import, Other. Acknowledge (per instance, or every instance in
// view) takes the instance's errors up to its newest out of the Summary's counts until a newer one comes; it is offered
// only with no filter set, as it covers every error of the instance. Data from GET /api/collectorerrors.
import { get, Row, rowsOf, Table } from './api';
import { AckBody, ackDialog, ackOn, endAck, endButton, loadAckSafe, writeButton } from './ack';
import { markNeed } from './needs';
import type { Ctx } from './router';
import { href, rangeLabel, window_ } from './router';
import { fleet, inTagScope, tagWords } from './fleet';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';

type Part = Table | null;
const views: [string, string][] = [['instance', 'Row per instance'], ['collection', 'Row per collection'], ['error', 'Row per error']];
const types = ['Error', 'Warning', 'Skipped'];
const stages = ['Connect', 'Collect', 'Import', 'Other'];
const countCols: [string, string, string, string][] = [
  ['errors', 'errors', 'type', 'Error'], ['warnings', 'warnings', 'type', 'Warning'], ['skipped', 'skipped', 'type', 'Skipped'],
  ['connect', 'connect', 'stage', 'Connect'], ['collect', 'collect', 'stage', 'Collect'], ['import', 'import', 'stage', 'Import'], ['other', 'other', 'stage', 'Other'],
];
const pageKeys = ['view', 'coll', 'type', 'stage', 'q', 'skipped', 'service'];

// the page's own filters, from its address
function filters(): Record<string, string> {
  const q = new URLSearchParams(location.hash.split('?')[1] ?? '');
  const f: Record<string, string> = {};
  for (const k of pageKeys) { const v = q.get(k); if (v) f[k] = v; }
  return f;
}

export async function collectorErrorsView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Collector errors (${rangeLabel(ctx)})`));
  const f = filters();
  const view = f.view ?? (ctx.instance ? 'collection' : 'instance');
  // a link to this page: the scope (an instance, else the folder), the range, the filters kept and changed
  const to = (over: Record<string, string | undefined>, instance?: number | null): string => {
    const base = href(ctx, { tab: 'collectorerrors', instance: instance === null ? undefined : instance ?? ctx.instance });
    const [path, qs] = base.split('?');
    const q = new URLSearchParams(qs ?? '');
    const next = { ...f, ...over };
    for (const k of pageKeys) { const v = next[k]; if (v) q.set(k, v); else q.delete(k); }
    return `${path}?${q.toString()}`;
  };
  const filtered = !!(f.coll || f.type || f.stage || f.q || f.service);
  // an acknowledgement covers every error of an instance up to its newest, and the Summary counts the last 24 hours: it
  // is offered only with no filter set and a range of 24 hours or more that ends now, so nothing it covers went unseen
  const win = window_(ctx);
  const wide = Date.parse(win.from) <= Date.now() - 24 * 3600000 + 60000 && Date.parse(win.to) >= Date.now() - 5 * 60000;
  const canAck = !filtered && wide;
  const params: Record<string, string | number | undefined> = { ...win, view, coll: f.coll, type: f.type, stage: f.stage, q: f.q,
    skipped: f.skipped === '1' ? 1 : undefined, service: f.service === '1' ? 1 : undefined };
  let folder = ' of the fleet';
  try {
    if (ctx.instance) { params.instance = ctx.instance; folder = ''; }
    else if (ctx.tag) {
      const fl = await fleet();
      params.instances = fl.instances.filter(r => inTagScope(ctx.tag!, r)).map(r => Number(r.instance_id)).join(',') || '0';
      folder = ` of ${tagWords(ctx.tag!)}`;
    }
  } catch (e) { sec.append(errorBox(e)); return sec; }

  sec.append(el('p', { class: 'meta' },
    'Every run of a collection that did not end well' + folder + ', kept 30 days, and the service\'s own failures where they are stored '
    + '(alert sends, report mails, DBA Dash repositories not read, a Parquet export failing or behind) under \'(the service)\'. Types: Error (the run failed), Warning (the run '
    + 'finished, one of its parts did not), Skipped (the collection did not apply or lacked a right: hidden unless shown). pgvigil never retries '
    + 'a run, so there is no Retry type. Stages: Connect (the server did not answer), Collect (the read on the server), Import (the write into '
    + 'the repository), Other (the service\'s own work). Each name and count narrows the page; Back goes up. Not here: what only the service\'s '
    + 'own log holds (journalctl or the Windows event log), and a run that failed before its instance was recognised.'));

  // the toolbar: the view, skips, type, stage, the text; a change is a new address (Back undoes it)
  const sel = (label: string, key: string, items: [string, string][]) => {
    const s = el('select', { 'aria-label': label }, ...items.map(([v, t]) => el('option', { value: v }, t)));
    s.value = key === 'view' ? view : f[key] ?? '';
    s.addEventListener('change', () => { location.hash = to({ [key]: s.value || undefined }); });
    return el('label', {}, label + ' ', s);
  };
  const text = el('input', { type: 'search', placeholder: 'text in the note', 'aria-label': 'text in the note', maxlength: '200', value: f.q ?? '' });
  text.addEventListener('change', () => { location.hash = to({ q: text.value.trim() || undefined }); });
  const bar = el('div', { class: 'toolbar' },
    sel('View', 'view', views), ' ', sel('Skipped', 'skipped', [['', 'Hidden'], ['1', 'Shown']]), ' ',
    sel('Type', 'type', [['', 'All'], ...types.map(t => [t, t] as [string, string])]), ' ',
    sel('Stage', 'stage', [['', 'All'], ...stages.map(t => [t, t] as [string, string])]), ' ', text);
  if (filtered) bar.append(' ', el('a', { href: to({ coll: undefined, type: undefined, stage: undefined, q: undefined, service: undefined }) }, 'Clear the filters'));
  if (f.coll) bar.append(' ', badge(`collection ${f.coll}`, ''));
  sec.append(bar);

  const body = el('div');
  sec.append(body);
  const ad = await loadAckSafe(['acks']);
  let seq = 0;
  const draw = async (): Promise<void> => {
    const mine = ++seq;
    let d: Record<string, Part>;
    try { d = await get<Record<string, Part>>('collectorerrors', params); } catch (e) { if (mine === seq) body.replaceChildren(errorBox(e)); return; }
    if (mine === seq) body.replaceChildren(...render(d));
  };
  const redraw = () => { void draw(); };
  let said = ''; // what the last Unacknowledge could not end, shown once on the next drawing
  const render = (d: Record<string, Part>): Node[] => {
  const out: Node[] = [];
  const rows = rowsOf(d.rows), marks = rowsOf(d.marks), cards = rowsOf(d.insights);
  if (said) { out.push(el('p', { class: 'meta', role: 'status' }, said)); said = ''; }

  // the suggestions: one card per kind, naming its instances (DBA Dash's insight card)
  for (const c of cards) out.push(el('div', { class: 'card warn', role: 'note' }, badge('Suggestion', 'warn'), ' ', String(c.text ?? ''), ' ',
    el('span', { class: 'meta' }, String(c.instances ?? ''))));

  // the acknowledgement of the instance in scope
  const ackBody = (r: Row): AckBody => ({ kind: 'ack', instance_id: Number(r.instance_id), check_key: 'collector errors', seen_state: `log_id:${Number(r.max_log_id)}`, until_change: true });
  // Unacknowledge ends every live row of the instance: the first through the dialog, the rest after it, any refusal
  // said on the page; no control where this serve cannot write for the instance
  const unack = (m: Row): HTMLElement => {
    const ids = (m.ack_ids as number[] | null) ?? [];
    if (!ids.length || !ackOn(ad, Number(m.instance_id))) return el('span');
    const b = endButton(ids[0], `Unacknowledge the collector errors of ${String(m.instance)}`, async () => {
      const not: string[] = [];
      for (const id of ids.slice(1)) { try { await endAck(id); } catch (e) { not.push(e instanceof Error ? e.message : String(e)); } }
      if (not.length) said = `${ids.length - not.length} of ${ids.length} acknowledgement rows of ${String(m.instance)} ended; not: ${[...new Set(not)].join('; ')}`;
      redraw();
    }, 'Unacknowledge');
    return markNeed(b, 'ack/end'); // the button's need (endButton's) covers the rows it ends after the first
  };
  const ackButton = (r: Row, name: string): HTMLElement => writeButton(ad, 'Acknowledge', `Acknowledge the collector errors of ${name}`, () => ackDialog({
    title: `Acknowledge the collector errors of ${name}`,
    what: 'Its errors up to the newest (every one of them, in this range or before it) leave the Summary\'s failing collections until a newer one comes, and its Collection Health cell is judged from the next failure on (then all of its failures in a row; its rate from the next whole hour). The Collection Health page keeps its Status and counts; the collection failing alert keeps its own acknowledgement. Who and when are kept; Unacknowledge brings them back.',
    body: ackBody(r), expiry: false, noteField: 'optional', after: redraw,
  }), { instance: Number(r.instance_id), name });
  // an instance with nothing new since its mark gets no second row
  const ackable = (r: Row): boolean => canAck && r.max_log_id != null && (r.mark == null || Number(r.new_since_mark ?? 0) > 0);
  if (ctx.instance) {
    const m = marks[0];
    const top = rows.reduce((x, r) => Math.max(x, Number(r.max_log_id ?? 0)), 0);
    const line = el('p', { class: 'meta' }, m ? `Acknowledged up to log_id ${String(m.mark ?? '?')}: the errors up to it are greyed and left out of the Summary. ` : '');
    if (m) line.append(unack(m), ' ');
    if (canAck && top > 0 && (!m || top > Number(m.mark ?? 0))) line.append(ackButton({ instance_id: ctx.instance, max_log_id: top }, String(m?.instance ?? 'this instance')));
    if (line.childNodes.length) out.push(line);
  }

  // the grid of the view
  const nameLink = (r: Row): Node => r.instance_id == null
    ? el('a', { href: to({ view: 'error', service: '1' }, null) }, String(r.instance ?? ''))
    : el('a', { href: to({ view: 'collection' }, Number(r.instance_id)) }, String(r.instance ?? ''));
  const countLink = (r: Row, key: string, val: string) => (v: unknown): string | Node => {
    if (v == null) return '';
    const over: Record<string, string | undefined> = { view: 'error', [key]: val };
    if (view === 'collection') over.coll = String(r.collection);
    const inst = view === 'instance' ? (r.instance_id == null ? null : Number(r.instance_id)) : undefined;
    if (view === 'instance' && r.instance_id == null) over.service = '1';
    return el('a', { href: to(over, inst) }, fmtNum(v));
  };
  let cols: Col[];
  const counts = (): Col[] => [
    { key: 'total', num: true, fmt: (v, r) => countLink(r, 'view', 'error')(v) },
    ...countCols.filter(([k]) => k !== 'skipped' || f.skipped === '1').map(([k, label, key, val]) => ({ key: k, label, num: true,
      fmt: (v: unknown, r: Row) => countLink(r, key, val)(v) } as Col)),
    { key: 'first_at', label: 'first', fmt: fmtTime }, { key: 'last_at', label: 'last', fmt: fmtTime },
    // the first 1000 characters; a longer one opens whole (DBA Dash's Last Message link)
    { key: 'last_message', label: 'last message', wide: true, fmt: (v, r) => String(r.last_message_full ?? '').length > String(v ?? '').length
      ? el('details', {}, el('summary', {}, String(v ?? '')), el('pre', { class: 'wrap' }, String(r.last_message_full))) : String(v ?? '') },
  ];
  if (view === 'instance') {
    cols = [
      { key: 'instance', fmt: (_v, r) => nameLink(r) },
      { key: 'collections', num: true, fmt: (v, r) => r.instance_id == null ? fmtNum(v) : el('a', { href: to({ view: 'collection' }, Number(r.instance_id)) }, fmtNum(v)) },
      ...counts(),
      { key: 'suggestion', wide: true, fmt: (v, r) => v == null ? '' : r.help ? el('a', { href: String(r.help) }, String(v)) : String(v) },
      { key: 'mark', label: 'acknowledged', fmt: (v, r) => {
        if (r.instance_id == null) return '';
        const m = marks.find(x => Number(x.instance_id) === Number(r.instance_id));
        const box = el('span', {}, v == null ? '' : `up to ${String(v)} (${fmtNum(r.new_since_mark ?? 0)} new) `);
        if (m) box.append(unack(m), ' ');
        if (ackable(r)) box.append(ackButton(r, String(r.instance)));
        return box;
      } },
    ];
  } else if (view === 'collection') {
    cols = [
      { key: 'collection', fmt: v => el('a', { href: to({ view: 'error', coll: String(v) }) }, String(v ?? '')) },
      ...(ctx.instance ? [] : [{ key: 'instances', num: true, fmt: (v: unknown, r: Row) => el('a', { href: to({ view: 'instance', coll: String(r.collection) }) }, fmtNum(v)) } as Col]),
      ...counts(),
    ];
  } else {
    cols = [
      { key: 'at', label: 'time', fmt: (v, r) => el('span', { class: r.acked ? 'muted' : '' }, fmtTime(v)) },
      ...(ctx.instance ? [] : [{ key: 'instance', fmt: (_v: unknown, r: Row) => nameLink(r) } as Col]),
      { key: 'collection', fmt: v => el('a', { href: to({ coll: String(v) }) }, String(v ?? '')) },
      { key: 'type', fmt: v => badge(String(v ?? ''), v === 'Error' ? 'crit' : v === 'Warning' ? 'warn' : '') },
      { key: 'stage', fmt: v => el('a', { href: to({ stage: String(v) }) }, String(v ?? '')) },
      { key: 'note', wide: true, fmt: (v, r) => el('span', { class: r.acked ? 'muted' : '' }, String(v ?? ''), r.acked ? ' (acknowledged)' : '') },
      { key: 'link', label: 'handled on', fmt: v => v ? el('a', { href: href(ctx, { tab: String(v).replace('#/', ''), instance: undefined }) }, String(v).replace('#/', '')) : '' },
    ];
  }
  // Acknowledge every instance in view: one write per instance, offered only with no filter set
  if (!canAck) out.push(el('p', { class: 'meta' }, (filtered ? 'Clear the filters' : 'Widen the range to the last 24 hours or more, ending now,')
    + ' to acknowledge: an acknowledgement covers every error of an instance up to its newest, shown or not.'));
  if (view === 'instance' && !ctx.instance && canAck) {
    const all = rows.filter(r => r.instance_id != null && ackable(r));
    if (all.length) out.push(el('div', { class: 'toolbar' }, writeButton(ad, `Acknowledge all ${fmtNum(all.length)} in view`, `Acknowledge all ${fmtNum(all.length)} in view: the collector errors of every instance in view`, () => ackDialog({
      title: `Acknowledge the collector errors of ${fmtNum(all.length)} instance(s)`,
      what: 'Each instance\'s errors up to its newest shown leave the Summary\'s counts until a newer one comes, its Collection Health cell judged from the next failure on: one write per instance, the answer says which were refused.',
      body: all.map(ackBody), expiry: false, noteField: 'optional', after: redraw,
    }), { instance: 'any' })));
  }
  const n = rows.length;
  out.push(el('p', { class: 'meta' }, view === 'error' ? `${fmtNum(n)}${n >= 5000 ? '+ (the newest 5,000)' : ''} error(s), newest first.` : `${fmtNum(n)} row(s).`),
    grid(rows, cols, filtered ? 'No error matches the filters.' : 'No collection error in this range.'));
  return out;
  };
  if (filtered || f.view) {
    const back = el('button', { type: 'button', class: 'link' }, 'Back');
    back.addEventListener('click', () => history.back());
    bar.append(' ', back);
  }
  await draw();
  return sec;
}
