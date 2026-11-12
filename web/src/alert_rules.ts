// Alert rules (task 131; Darling's Alert Rules and Threshold Overrides, DBA Dash's metric thresholds): a rule is one
// metric of the Metrics grid above or below a warning and / or a critical value for n minutes, on the fleet, one tag or
// one instance, optionally for one database's series. The most specific live rule is the one in force on an instance
// (instance over tag over fleet), so a tag or an instance rule is that scope's threshold override. The alert sender
// judges the rules in its pass and a firing rule goes out through the alert channels like any finding (the Alerts
// page lists it; acknowledge, mute and silence apply). GET /api/alertrules reads the store of 0085; POST
// /api/alertrules and /api/alertrules/end write it behind the UI login (api.post carries the X-Pgvigil header). Every
// write opens a dialog that says what it does; the server answers with the rule's id or the reason it refused. An
// edit ends the rule and writes its successor, so the table is its own history. ruleDialog is also the Metrics page's
// 'threshold' dialog (metrics.ts). The route and the root tab are the shell's. Task 151 (K07.07): Thresholds in force,
// every threshold each instance is judged by, a rule's line opening an override for the instance or one of its tags.
import { get, post, Row, rowsOf, Table } from './api';
import { fleet, tagsOf } from './fleet';
import { Ctx, rangeLabel, window_ } from './router';
import { whatIsThis } from './sqlview';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, showMenu } from './ui';

export interface RulesDoor { writable: boolean; reason?: string; user: string }
interface RulesData extends RulesDoor {
  rules?: Table | null; state?: Table | null; log?: Table | null; catalog?: Table | null; sender?: Table | null;
  inforce?: Table | null;
}
interface RuleResult { outcome: string; detail: string; rule_id?: number | null }

// what a rule's values are counted in, as the dialog and the grids say it
const unitWords: Record<string, string> = {
  count: 'a count', pct: 'percent', secs: 'seconds', xids: 'transaction ids', per_s: 'per second',
  bytes_per_s: 'bytes per second', ms: 'milliseconds', mb: 'MB', bytes: 'bytes',
};
export const unitWord = (unit: unknown): string => unitWords[String(unit ?? '')] ?? String(unit ?? '');

// fmtMetric: a figure in its metric's unit (the grid's max / min / avg / current, a threshold, a state's value)
export function fmtMetric(v: unknown, unit: unknown): string {
  if (v == null || v === '') return '';
  const n = Number(v);
  if (!isFinite(n)) return String(v);
  switch (unit) {
    case 'pct': return fmtNum(n) + ' %';
    case 'secs': return Math.abs(n) < 60 ? fmtNum(n) + ' s' : fmtSecs(n);
    case 'ms': return fmtNum(n) + ' ms';
    case 'per_s': return fmtNum(n) + '/s';
    case 'bytes_per_s': return fmtBytes(n) + '/s';
    case 'bytes': return fmtBytes(n);
    case 'mb': return fmtNum(n) + ' MB';
    default: return fmtNum(n);
  }
}

// scopeWords: what a rule covers
export function scopeWords(scope: unknown, target: unknown): string {
  return scope === 'fleet' ? 'every instance' : scope === 'tag' ? `tag ${String(target ?? '')}` : `instance ${String(target ?? '')}`;
}

// conditionWords: 'above 3 (warning), 5 (critical) for 5 min', the values in the metric's unit
export function conditionWords(r: Row, unit: unknown = r.unit): string {
  const lv = [r.warning != null ? `${fmtMetric(r.warning, unit)} (warning)` : '', r.critical != null ? `${fmtMetric(r.critical, unit)} (critical)` : ''].filter(Boolean);
  const mins = Number(r.for_minutes ?? 0);
  return `${String(r.op ?? '')} ${lv.join(', ')} ${mins > 0 ? `for ${mins} min` : 'at the first sample'}`;
}

// willAlert: every rule switched on as one sentence: 'pgvigil will alert when Sessions: active sessions is above 50
// (warning), 100 (critical) for 5 min on every instance; or when ...' (the dialog's own words per rule)
// overridden: a narrower rule takes the place of a wider one on what it covers; noChannel: no sender judges the rules
export function willAlert(rules: Row[], name: (r: Row) => string, noChannel = false): string {
  const one = (r: Row) => `${name(r)} is ${conditionWords(r).trim()} on ${scopeWords(r.scope, r.tag ?? r.instance_name)}${r.database ? ` (database ${String(r.database)})` : ''}`;
  // a narrower rule on the same metric as a wider one (a tag or an instance rule beside a fleet rule, an instance rule beside a tag rule)
  const narrower = rules.some(n => n.scope !== 'fleet' && rules.some(w => w !== n && w.metric === n.metric && (w.scope === 'fleet' || (w.scope === 'tag' && n.scope === 'instance'))));
  return `pgvigil ${noChannel ? 'would alert (no alert channel is configured, so nothing is sent)' : 'will alert'} when ${rules.map(one).join('; or when ')}`
    + (narrower ? ', each where no narrower rule on the same metric overrides it (an instance rule over a tag rule over a fleet rule).' : '.');
}

export const stateBadge = (v: unknown, held?: unknown): HTMLElement | string => {
  if (v == null) return '';
  const s = String(v);
  const kind = s === 'critical' ? 'crit' : s === 'warning' ? 'warn' : s === 'ok' ? 'ok' : '';
  const words = s === 'nodata' ? 'no data' : s === 'pending' ? 'pending (beyond, not yet for its minutes)' : s;
  return badge(held ? `${words}, held (no fresh sample)` : words, kind);
};

export interface RuleDialog {
  door: RulesDoor;
  rule?: Row;                 // edit this rule (its fields fill the form)
  metric?: string;            // a new rule for this metric (the Metrics grid's 'New threshold'): the metric is fixed
  prefill?: Row;              // a new rule starting from these values (op, warning, critical, for_minutes): an override
  instanceId?: number;        // the scope a new rule starts with: this instance
  tag?: string;               // or this tag (an override for a tag, opened from a threshold's line)
  database?: string;          // a new rule for this database's series
  after: () => void;
}

let catalogCache: Row[] | null = null;
async function catalog(): Promise<Row[]> {
  if (!catalogCache) catalogCache = rowsOf((await get<RulesData>('alertrules', { part: 'catalog' })).catalog);
  return catalogCache;
}

// ---- the starter rules (PerformanceMonitor's alert rule templates; MIT, (c) Erik Darling, Darling Data, LLC: its
// rule names and default values, PerformanceMonitor 3.12.0, see STARTERS) -----------------------------------------------
// STARTERS: a rule each that pre-fills the New alert rule dialog: its metric (metric_catalog key), direction, warning,
// critical and minutes; a starter whose metric this server's catalog lacks is left out of the menu
// (CustomAlertTemplates.cs L46-141: nine templates; the seven whose measure pgvigil does not chart as a metric - dead
// tuples, replay lag, table bloat, slot WAL, signal wait share, average elapsed per execution, tempdb growth - are
// pgvigil findings instead, not rules). The translation, one for both: a template's warning and critical bars as they
// are; its breach samples as the minutes the value must hold (the sender judges once a minute: breach 3 = 3 minutes);
// its 'ge' as pgvigil's 'above' (pgvigil has no 'at or above': a value exactly at the bar does not fire here)
export const STARTERS: { name: string; metric: string; op: 'above' | 'below'; warning: number | null; critical: number | null; for_minutes: number; from: string }[] = [
  { name: 'PostgreSQL: connection count high', metric: 'sessions.total', op: 'above', warning: 200, critical: 500, for_minutes: 3, from: 'pg-connection-saturation (200 / 500 sessions, breach 3)' },
  { name: 'SQL Server: sustained blocking', metric: 'requests.longest_wait_ms', op: 'above', warning: 30000, critical: 120000, for_minutes: 2, from: 'sqlserver-sustained-blocking (30 s / 2 min, breach 2)' },
];

// starterButton: 'Starter rules', a menu of the starters; an item opens the rule dialog filled with it (read-only, the
// dialog shows the values and says why Save is off)
function starterButton(door: RulesDoor, after: () => void): HTMLElement {
  const b = el('button', { type: 'button', class: 'link', 'aria-haspopup': 'menu' }, 'Starter rules') as HTMLButtonElement;
  b.addEventListener('click', () => {
    void catalog().catch((e: unknown) => { b.title = 'The metric catalog could not be read: ' + (e instanceof Error ? e.message : String(e)); return [] as Row[]; }).then(cat => {
      const keys = new Set(cat.map(c => String(c.key)));
      const items: [string, () => void][] = STARTERS.filter(x => keys.has(x.metric)).map(x => [x.name, () => {
        void ruleDialog({ door, metric: x.metric, prefill: { op: x.op, warning: x.warning, critical: x.critical, for_minutes: x.for_minutes, name: x.name }, after });
      }]);
      const r = b.getBoundingClientRect();
      showMenu(r.left, r.bottom + 2, items.length ? items : [[b.title.startsWith('The metric catalog') ? b.title : 'No starter fits this server\'s metrics', () => { /* nothing */ }]], b);
    });
  });
  return b;
}

// ruleButton: a button that opens the rule dialog, disabled with the reason when rules cannot be written here
export function ruleButton(door: RulesDoor, label: string, aria: string, open: () => void): HTMLButtonElement {
  const b = el('button', { type: 'button', class: 'link', 'aria-label': aria }, label);
  if (!door.writable) { b.disabled = true; b.title = door.reason ?? 'alert rules are read only here'; }
  else b.addEventListener('click', open);
  return b;
}

// ruleDialog: the one form a rule is made or edited through
export async function ruleDialog(o: RuleDialog) {
  let cat: Row[], insts: Row[];
  try { cat = await catalog(); insts = (await fleet()).instances; } catch (e) { window.alert('The rule form could not load: ' + (e instanceof Error ? e.message : String(e))); return; }
  const r = o.rule;                 // the rule being edited; none = a new rule
  const p = o.rule ?? o.prefill;    // where the condition's fields start
  const fixedMetric = o.metric ?? undefined;
  const startMetric = String(r?.metric ?? fixedMetric ?? '');
  const metricSel = el('select', { required: '' });
  const engines: [string, string][] = [['postgres', 'PostgreSQL'], ['sqlserver', 'SQL Server'], ['any', 'Host (both engines)']];
  for (const [eng, engName] of engines) {
    const fams = [...new Set(cat.filter(c => c.engine === eng).map(c => String(c.family_label)))];
    for (const fam of fams) {
      const g = el('optgroup', { label: `${engName}: ${fam}` });
      for (const c of cat.filter(x => x.engine === eng && x.family_label === fam)) g.append(el('option', { value: String(c.key) }, String(c.label)));
      metricSel.append(g);
    }
  }
  // a rule on a metric the catalogue no longer has: the form says so, and the server refuses it until another is picked
  if (startMetric && !cat.some(c => c.key === startMetric)) metricSel.prepend(el('option', { value: startMetric }, `${startMetric} (no longer a metric)`));
  if (startMetric) metricSel.value = startMetric;
  if (fixedMetric) metricSel.disabled = true;
  const meta = () => cat.find(c => c.key === metricSel.value);
  const name = el('input', { type: 'text', maxlength: '100', value: String(r?.name ?? o.prefill?.name ?? '') });
  const dir = el('select', {}, el('option', { value: 'above' }, 'above'), el('option', { value: 'below' }, 'below'));
  dir.value = String(p?.op ?? 'above');
  const num = (v: unknown) => el('input', { type: 'number', step: 'any', style: 'width:9em', value: v == null ? '' : String(v) });
  const warn = num(p?.warning), crit = num(p?.critical);
  const mins = el('input', { type: 'number', min: '0', max: '1440', step: '1', style: 'width:5em', value: String(p?.for_minutes ?? 5) });
  const scope = el('select', {}, el('option', { value: 'fleet' }, 'every instance'), el('option', { value: 'tag' }, 'one tag'), el('option', { value: 'instance' }, 'one instance'));
  scope.value = String(r?.scope ?? (o.instanceId ? 'instance' : o.tag ? 'tag' : 'fleet'));
  const tags = [...new Set(insts.flatMap(tagsOf))].sort();
  const tagSel = el('select', {}, ...tags.map(t => el('option', { value: t }, t)));
  if (r?.tag != null) { if (!tags.includes(String(r.tag))) tagSel.append(el('option', { value: String(r.tag) }, String(r.tag))); tagSel.value = String(r.tag); }
  else if (o.tag) { if (!tags.includes(o.tag)) tagSel.append(el('option', { value: o.tag }, o.tag)); tagSel.value = o.tag; }
  const instSel = el('select', {});
  const db = el('input', { type: 'text', maxlength: '200', value: String(r?.database ?? o.database ?? '') });
  const note = el('textarea', { rows: '2', maxlength: '500', style: 'width:100%' });
  note.value = String(r?.note ?? '');
  const unitLine = el('p', { class: 'meta' });
  const tagBox = el('label', {}, 'Tag ', tagSel, tags.length || r?.tag != null ? '' : ' (no instance carries a tag)'), instBox = el('label', {}, 'Instance ', instSel), dbBox = el('label', {}, 'Database (empty = the whole instance) ', db);
  const wantInst = Number(r?.instance_id ?? o.instanceId ?? 0);
  const sync = () => {
    const m = meta();
    unitLine.textContent = m ? `${String(m.family_label)}: ${String(m.label)} is counted in ${unitWord(m.unit)}; the values below are in that unit.` : '';
    // an instance rule offers the instances of the metric's engine
    const keep = instSel.value || String(wantInst || '');
    const fit = insts.filter(i => !m || m.engine === 'any' || String(i.engine ?? 'postgres') === m.engine);
    instSel.replaceChildren(...fit.map(i => el('option', { value: String(i.instance_id) }, String(i.name))));
    if (fit.some(i => String(i.instance_id) === keep)) instSel.value = keep;
    else if (r?.scope === 'instance' && !instSel.dataset.picked) {
      // the rule's own instance is gone, or not of this metric's engine: never retarget it silently, ask
      instSel.prepend(el('option', { value: '' }, `${String(r.instance_name ?? 'its instance')} (not an active instance of this engine: pick one)`));
      instSel.value = '';
    }
    tagBox.hidden = scope.value !== 'tag';
    instBox.hidden = scope.value !== 'instance';
    dbBox.hidden = !m?.per_database;
  };
  metricSel.addEventListener('change', sync);
  scope.addEventListener('change', sync);
  instSel.addEventListener('change', () => { instSel.dataset.picked = '1'; });
  sync();
  const fields: HTMLElement[] = [
    el('label', {}, 'Metric ', metricSel), unitLine,
    el('span', {}, el('label', {}, 'Alert when it is ', dir), ' ', el('label', {}, 'warning ', warn), ' ', el('label', {}, 'critical ', crit), ' ', el('label', {}, 'for ', mins, ' minutes')),
    el('p', { class: 'meta' }, 'One of warning and critical is enough. 0 minutes alerts at the first sample beyond the value; n minutes needs every sample of n minutes beyond it.'),
    el('span', {}, el('label', {}, 'Covers ', scope), ' ', tagBox, ' ', instBox),
    dbBox,
    el('label', {}, 'Name (optional) ', name),
    el('label', {}, 'Note (optional)', el('br'), note),
  ];
  // what Save still needs, in words ('' = nothing). A number field holding something that is not a number reads
  // empty: it must not pass as 'no value'; empty minutes are asked for, never saved as the store's default.
  const invalid = () => [
    metricSel.value === '' ? 'a metric' : '',
    warn.validity.badInput || crit.validity.badInput ? 'numbers in warning and critical'
      : warn.value.trim() === '' && crit.value.trim() === '' ? 'a warning or a critical value' : '',
    mins.value.trim() === '' || !mins.validity.valid ? 'whole minutes from 0 to 1440' : '',
    scope.value === 'tag' && tagSel.value === '' ? 'a tag' : '',
    scope.value === 'instance' && instSel.value === '' ? 'an instance' : '',
  ].filter(Boolean).join(', ');
  const body = () => {
    const m = meta();
    return {
      op: r ? 'edit' : 'add', rule_id: r ? Number(r.rule_id) : undefined,
      metric: metricSel.value, op_dir: dir.value,
      warning: warn.value.trim() === '' ? undefined : Number(warn.value), critical: crit.value.trim() === '' ? undefined : Number(crit.value),
      for_minutes: mins.value.trim() === '' ? undefined : Math.trunc(Number(mins.value)),
      scope: scope.value, tag: scope.value === 'tag' ? tagSel.value : undefined,
      instance_id: scope.value === 'instance' ? Number(instSel.value) : undefined,
      database: m?.per_database && db.value.trim() ? db.value.trim() : undefined,
      name: name.value.trim() || undefined, note: note.value.trim() || undefined,
    };
  };
  formDialog(r ? `Edit alert rule ${String(r.rule_id)}` : 'New alert rule',
    r ? 'Saving ends this rule and writes its successor (the old row stays with who ended it and when). The alert sender judges the new rule from its next pass.'
      : 'The alert sender judges the rule from its next pass; a firing rule is sent through the alert channels like any finding. A tag or an instance rule overrides a wider rule on the same metric.',
    'Save', () => post<RuleResult>('alertrules', body()), o.after, fields,
    // a read-only server shows the form (a starter's values can be read anywhere) and says why Save is off
    () => o.door.writable ? invalid() : `a server where alert rules can be written (${o.door.reason ?? 'read only here'})`,
    [metricSel, warn, crit, mins, scope, tagSel, instSel]);
}

// formDialog: a modal with what the write does, its fields, Save / Back, and the server's answer in place. invalid
// says what Save still needs ('' = nothing): the form shows it, so a disabled Save is never unexplained. One dialog
// makes one write: after a save the button stays off (a change typed into the still-open form would otherwise be a
// second rule), and it is off while a save is on its way.
function formDialog(title: string, what: string, go: string, run: () => Promise<RuleResult>, after: () => void,
  fields: HTMLElement[] = [], invalid: () => string = () => '', watch: HTMLElement[] = []) {
  const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  const ok = el('button', { type: 'submit' }, go);
  const no = el('button', { type: 'button' }, 'Back');
  const need = el('p', { class: 'meta' });   // not a live region: it changes with every key
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  let busy = false, done = false;
  const check = () => {
    const w = done ? '' : invalid();
    need.textContent = w ? `${go} needs ${w}.` : '';
    ok.disabled = busy || done || w !== '';
  };
  for (const w of watch) { w.addEventListener('input', check); w.addEventListener('change', check); }
  check();
  const form = el('form', { method: 'dialog' }, el('h3', {}, title), el('p', {}, what),
    ...fields.map(f => el('div', { style: 'margin:.3rem 0' }, f)), need, msg, el('div', { style: 'margin-top:.6rem' }, ok, ' ', no));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:44rem', 'aria-label': title }, form);
  // the dialog leaves the page; after a save the page is read again, else the focus goes back where it came from
  const leave = () => { dlg.remove(); if (done) after(); else if (opener?.isConnected) opener.focus(); };
  no.addEventListener('click', () => { dlg.close(); leave(); });
  dlg.addEventListener('cancel', leave);
  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    if (busy || done) return;
    busy = true; check();
    msg.textContent = 'Saving...';
    try {
      const res = await run();
      done = true;
      msg.replaceChildren(badge(res.outcome, 'ok'), ' ', res.detail);
      no.textContent = 'Close';
    } catch (e) {
      // a refusal leaves the form as typed: correct it and save again
      msg.replaceChildren(badge('not saved', 'crit'), ' ', e instanceof Error ? e.message : String(e));
    } finally {
      busy = false; check();
    }
  });
  document.body.append(dlg);
  dlg.showModal();
  (dlg.querySelector('input,select,textarea,button') as HTMLElement | null)?.focus();
}

// confirmWrite: a write with no field (end a rule, switch it on or off)
function confirmWrite(title: string, what: string, go: string, run: () => Promise<RuleResult>, after: () => void) {
  formDialog(title, what, go, run, after);
}

const redraw = () => window.dispatchEvent(new HashChangeEvent('hashchange'));

const what = () => whatIsThis('A rule watches one metric of the Metrics page: above or below a warning and / or a critical value for n minutes. It covers every instance, the instances of one tag, or one instance; where two rules on one metric cover an instance the narrower one is in force (instance over tag over fleet), so a tag or an instance rule is a threshold override. A rule naming a database watches that database\'s own series. The alert sender judges the rules once a minute with its channels; a firing rule is sent like any finding, repeats, recovers, and can be acknowledged or muted on the Alerts page. A firing rule whose series stops is held, not recovered. Every change is logged; an edit ends the rule and writes its successor (docs/alerts.md).', 'Alert rules');

// alertRulesView: the root page - the rules, what the sender last made of each, and the log of every change
export async function alertRulesView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Alert rules'));
  let d: RulesData;
  try { d = await get<RulesData>('alertrules', window_(ctx)); } catch (e) { sec.append(errorBox(e)); return sec; }
  const all = rowsOf(d.rules), state = rowsOf(d.state), log = rowsOf(d.log), sender = rowsOf(d.sender)[0] ?? {};
  const live = all.filter(r => r.live), off = live.filter(r => !r.enabled).length;
  const firing = state.filter(r => r.state === 'warning' || r.state === 'critical').length;
  const newRule = () => el('span', {}, ruleButton(d, 'New rule', 'New rule', () => { void ruleDialog({ door: d, after: redraw }); }), ' ', starterButton(d, () => redraw()));
  // who judges the rules: the alert sender, with at least one channel
  const noChannel = Number(sender.channels ?? 0) === 0, ago = Number(sender.evaluated_secs_ago ?? 0);
  const judged = sender.evaluated_at == null
    ? noChannel
      ? 'No alert channel is configured, so no sender runs and the rules are not judged: a channel is named in the configuration\'s alerts: list (docs/alerts.md).'
      : 'The alert sender has not judged the rules yet (its pass runs once a minute inside pgvigil run).'
    : ago > 180
      // the sender stopped (or its channels went): its last states are still in the store, and are not the state now
      ? `The alert sender last judged the rules ${fmtTime(sender.evaluated_at)}, ${fmtSecs(ago)} ago: no pass has run since, so the states below are from then.${noChannel ? ' No alert channel is configured.' : ''}`
      : `The alert sender last judged the rules ${fmtTime(sender.evaluated_at)}.`;
  sec.append(el('p', { class: 'meta' }, live.length
    ? `${live.length} rule(s) live${off ? ` (${off} switched off)` : ''}, ${firing} firing on an instance. ${judged} `
    : `No alert rule yet. ${judged} `, what()));
  // the rules in force as one sentence (PerformanceMonitor's 'will alert when' summary over its active rules)
  const on = live.filter(r => r.enabled);
  if (on.length) sec.append(el('p', { class: 'will-alert' }, willAlert(on, r => String(r.name ?? `${String(r.family_label ?? '')}: ${String(r.label ?? r.metric)}`), noChannel)));
  if (!d.writable) sec.append(el('p', { class: 'meta' }, `Alert rules are read only here: ${d.reason ?? ''}`));
  if (!live.length) {
    sec.append(el('div', { class: 'empty' },
      el('h3', {}, 'Alert on any metric you can chart'),
      el('p', {}, 'Pick a metric of an instance\'s Metrics page, say whether it must stay above or below a warning and a critical value and for how many minutes, and choose what the rule covers: every instance, one tag or one instance. A firing rule goes out through the alert channels like any finding. No SQL.'),
      el('div', { class: 'seg' }, newRule())));
  } else sec.append(el('div', { class: 'toolbar' }, el('div', { class: 'seg' }, newRule())));

  let showEnded = false;
  const wrap = el('div', {});
  const endedBtn = el('button', { type: 'button', class: 'toggle', 'aria-pressed': 'false' }, `Show ended (${rangeLabel(ctx)})`);
  const label = (r: Row) => String(r.name ?? `${String(r.family_label ?? '')}: ${String(r.label ?? r.metric)}`);
  const draw = () => {
    const rows = all.filter(r => showEnded || r.live);
    const cols: Col[] = [
      { key: 'enabled', label: 'on', fmt: (v, r) => {
        if (!r.live) return 'ended';
        const b = el('button', { type: 'button', class: 'toggle', 'aria-pressed': String(!!v), 'aria-label': `rule ${String(r.rule_id)} ${label(r)}: ${v ? 'on' : 'off'}` }, v ? 'on' : 'off');
        if (!d.writable) { b.disabled = true; b.title = d.reason ?? ''; }
        else b.addEventListener('click', () => confirmWrite(v ? `Switch rule ${String(r.rule_id)} off?` : `Switch rule ${String(r.rule_id)} on?`,
          v ? 'A rule switched off is in force nowhere: a wider rule on the same metric takes its place, and an alert it raised resolves. The row stays.' : 'The alert sender judges the rule again from its next pass.',
          v ? 'Switch off' : 'Switch on', () => post<RuleResult>('alertrules', { op: v ? 'disable' : 'enable', rule_id: Number(r.rule_id) }), redraw));
        return el('span', { class: 'seg', style: 'margin:0' }, b);
      } },
      { key: 'rule_id', label: 'rule', num: true },
      { key: 'name', fmt: v => String(v ?? '') },
      { key: 'metric', fmt: (v, r) => r.label == null ? `${String(v)} (no longer a metric)` : `${String(r.family_label)}: ${String(r.label)}` },
      { key: 'op', label: 'alert when', fmt: (_v, r) => conditionWords(r) },
      { key: 'scope', label: 'covers', fmt: (v, r) => scopeWords(v, r.tag ?? r.instance_name) },
      { key: 'database', fmt: v => String(v ?? '') },
      { key: 'in_force', label: 'in force on', num: true, fmt: (v, r) => r.live && r.enabled ? `${fmtNum(v)} of ${fmtNum(r.covers)}` : '' },
      { key: 'firing', label: 'state', fmt: (v, r) => !r.live || !r.enabled ? ''
        : Number(r.covers) === 0 ? 'covers no instance' : Number(r.in_force) === 0 ? 'in force nowhere: a narrower rule overrides it on every instance it covers'
        : r.evaluated_at == null ? 'not judged yet'
        : Number(v) > 0 ? el('span', {}, badge(`${fmtNum(v)} firing`, 'crit'), ` ${String(r.firing_on ?? '')}`)
        : [Number(r.pending) ? `${fmtNum(r.pending)} pending` : '', Number(r.nodata) ? `${fmtNum(r.nodata)} without data` : ''].filter(Boolean).join(', ') || badge('ok', 'ok') },
      { key: 'last_fired_at', label: 'last fired', fmt: (v, r) => v == null ? '' : `${fmtTime(v)} on ${String(r.last_instance ?? '')} (${fmtNum(r.fired)} in all)` },
      { key: 'created_at', label: 'made', fmt: (v, r) => `${fmtTime(v)} by ${String(r.created_by)}` + (r.replaces != null ? ` (replaces rule ${String(r.replaces)})` : '') },
      { key: 'ended_at', label: 'ended', fmt: (v, r) => v == null ? '' : `${fmtTime(v)} by ${String(r.ended_by ?? '')}` },
      { key: 'note', wide: true },
      { key: '_edit', label: '', fmt: (_v, r) => !r.live ? '' : el('span', { style: 'white-space:nowrap' },
        ruleButton(d, 'Edit', `Edit rule ${String(r.rule_id)} ${label(r)}`, () => { void ruleDialog({ door: d, rule: r, after: redraw }); }), ' · ',
        ruleButton(d, 'End', `End rule ${String(r.rule_id)} ${label(r)}`, () => confirmWrite(`End rule ${String(r.rule_id)}?`,
          'An ended rule is in force nowhere and an alert it raised resolves. The row stays with who ended it and when.', 'End',
          () => post<RuleResult>('alertrules/end', { rule_id: Number(r.rule_id) }), redraw))) },
    ];
    wrap.replaceChildren(grid(rows, cols.filter(c => showEnded || c.key !== 'ended_at'), all.length ? 'Every rule is ended: Show ended lists them.' : 'No rule.'));
  };
  endedBtn.addEventListener('click', () => { showEnded = !showEnded; endedBtn.setAttribute('aria-pressed', String(showEnded)); draw(); });
  if (all.length) {
    draw();
    sec.append(el('h3', { class: 'alert-rules-rules' }, 'Rules'), el('div', { class: 'seg' }, endedBtn), wrap);
  }

  const stateCols: Col[] = [
    { key: 'state', fmt: (v, r) => stateBadge(v, r.held) },
    { key: 'instance' },
    { key: 'metric', fmt: (v, r) => r.label == null ? String(v) : `${String(r.family_label)}: ${String(r.label)}` },
    { key: 'database', fmt: v => String(v ?? '') },
    { key: 'value', label: 'newest sample', num: true, fmt: (v, r) => fmtMetric(v, r.unit) },
    { key: 'threshold', num: true, fmt: (v, r) => v == null ? '' : `${String(r.op ?? '')} ${fmtMetric(v, r.unit)}` },
    { key: 'beyond_since', label: 'beyond since', fmt: (v, r) => r.state === 'ok' || r.state === 'nodata' ? '' : fmtTime(v) },
    { key: 'sample_at', label: 'sample', fmt: fmtTime },
    { key: 'rule_id', label: 'rule', num: true, fmt: (v, r) => `${String(v)}${r.rule_name != null ? ` ${String(r.rule_name)}` : ''} (${scopeWords(r.scope, r.target)})` },
    { key: 'since', label: 'in this state since', fmt: fmtTime },
  ];
  sec.append(el('h3', {}, 'State per instance ', whatIsThis('One row per rule in force, instance and series, as the alert sender last judged it: ok, pending (the newest samples are beyond the value, not yet for the rule\'s minutes), warning or critical (firing: on the Alerts page too), or no data (no sample newer than the metric\'s limit: 10 minutes, 30 for IO, 15 for the host). A firing row whose series stops is held: no data is not a recovery.', 'Rule state')),
    grid(state, stateCols, live.length ? 'No rule has been judged yet.' : 'No rule.'));

  const logCols: Col[] = [
    { key: 'at', label: 'when', fmt: fmtTime },
    { key: 'ui_user', label: 'by' },
    { key: 'client', label: 'from' },
    { key: 'op' },
    { key: 'rule_id', label: 'rule', num: true },
    { key: 'metric' },
    { key: 'outcome', fmt: v => badge(String(v ?? ''), v === 'done' ? 'ok' : 'warn') },
    { key: 'detail', wide: true },
  ];
  sec.append(el('h3', {}, `Rule log ${rangeLabel(ctx)}`), grid(log, logCols, 'No rule was made, edited, switched or ended in the time range.'));
  sec.append(inForceView(d, rowsOf(d.inforce), all));
  return sec;
}

// thresholdLine: a threshold's rule as one line with its numbers ("above 80 / 95 % for 5 min")
export function thresholdLine(r: Row): string {
  if (r.source !== 'rule') return String(r.value ?? '');
  return conditionWords(r);
}

// inForceView (task 151, K07.07): every threshold in force per instance - the alert rule each metric is judged by on
// it, with the rules it overrides there, and a SQL Server instance's HA/DR, jobs and backups thresholds (the file's,
// or the default: read only, the configuration is their source). The number of a rule's line opens its menu: an
// override for this instance, an override for one of its tags, or the rule itself. Only an override that would be in
// force is offered: an instance rule beats a tag rule and a tag rule beats the fleet's (0085), so a tag override is
// offered over a fleet rule only, and an instance's own rule is edited, not overridden.
function inForceView(door: RulesDoor, rows: Row[], rules: Row[]): HTMLElement {
  const insts = [...new Set(rows.map(r => String(r.instance)))].sort();
  const sel = el('select', { 'aria-label': 'instance' }, el('option', { value: '' }, 'every instance'), ...insts.map(n => el('option', { value: n }, n)));
  const wrap = el('div', {});
  const menu = (r: Row, at: HTMLElement) => {
    const items: [string, () => void][] = [];
    const prefill: Row = { op: r.op, warning: r.warning, critical: r.critical, for_minutes: r.for_minutes };
    const db = r.database == null ? undefined : String(r.database);
    const rule = rules.find(x => String(x.rule_id) === String(r.rule_id) && x.live);
    if (door.writable) {
      if (r.scope === 'instance') {
        if (rule) items.push([`Edit rule ${String(r.rule_id)} (${String(r.instance)}'s own)`, () => { void ruleDialog({ door, rule, after: redraw }); }]);
      } else {
        items.push([`Override for ${String(r.instance)}`, () => { void ruleDialog({ door, metric: String(r.what), prefill, instanceId: Number(r.instance_id), database: db, after: redraw }); }]);
      }
      if (r.scope === 'fleet') {
        for (const t of (Array.isArray(r.tags) ? r.tags : []).map(String)) items.push([`Override for tag ${t} (every instance of it)`, () => { void ruleDialog({ door, metric: String(r.what), prefill, tag: t, database: db, after: redraw }); }]);
      }
      if (r.scope === 'tag' && rule) items.push([`Edit rule ${String(r.rule_id)} (tag ${String(r.target)})`, () => { void ruleDialog({ door, rule, after: redraw }); }]);
    }
    items.push([`Rule ${String(r.rule_id)} on the Rules grid`, () => {
      const h = document.querySelector<HTMLElement>('.alert-rules-rules');
      if (h) { h.tabIndex = -1; h.scrollIntoView(); h.focus(); }
    }]);
    const box = at.getBoundingClientRect();
    showMenu(box.left, box.bottom, items, at);
  };
  const cols: Col[] = [
    { key: 'instance' },
    { key: 'source', label: 'from', fmt: v => badge(v === 'rule' ? 'alert rule' : v === 'file' ? 'configuration file' : 'default', v === 'rule' ? 'ok' : '') },
    { key: 'what', label: 'threshold', fmt: (v, r) => r.source === 'rule' ? `${String(r.family_label ?? '')}: ${String(r.label ?? v)}` : String(r.label ?? v) },
    { key: 'database', fmt: v => String(v ?? '') },
    { key: 'op', label: 'rule', fmt: (_v, r) => {
      const line = thresholdLine(r);
      if (r.source !== 'rule') return el('span', { title: 'read only: mssql_thresholds in the configuration file sets it (docs/sqlserver-hadr.md)' }, line);
      const b = el('button', { type: 'button', class: 'link', 'aria-haspopup': 'menu', 'aria-label': `${line}: override for this instance or a tag` }, line);
      b.addEventListener('click', () => menu(r, b));
      return b;
    } },
    { key: 'scope', label: 'in force by', fmt: (v, r) => r.source === 'rule' ? `rule ${String(r.rule_id)}${r.rule_name != null ? ` ${String(r.rule_name)}` : ''} (${scopeWords(v, r.target)})` : r.source === 'file' ? 'mssql_thresholds' : 'built in' },
    { key: 'overrides', label: 'overrides here', wide: true, fmt: v => String(v ?? '') },
  ];
  const draw = () => wrap.replaceChildren(grid(rows.filter(r => !sel.value || r.instance === sel.value), cols,
    'No threshold in force: no alert rule covers an active instance, and no SQL Server instance is in the fleet.'));
  sel.addEventListener('change', draw);
  draw();
  return el('div', {}, el('h3', {}, 'Thresholds in force ', whatIsThis('Every threshold an active instance is judged by: per metric the alert rule in force on it (an instance\'s rule over a tag\'s over the fleet\'s) with the wider rules it overrides there, and on a SQL Server instance the HA/DR, jobs and backups thresholds (set by mssql_thresholds in the configuration file, else the default; read only here). Click a rule\'s line for an override: on a fleet rule, for this instance or one of its tags; on a tag rule, for this instance; an instance\'s own rule is edited. The override is a narrower rule, made in the rule form.', 'Thresholds in force')),
    el('div', { class: 'toolbar' }, el('label', {}, 'Instance ', sel)), wrap);
}
