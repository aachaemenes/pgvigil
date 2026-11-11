// Alert rules (task 131; Darling's Alert Rules and Threshold Overrides, DBA Dash's metric thresholds): a rule is one
// metric of the Metrics grid above or below a warning and / or a critical value for n minutes, on the fleet, one tag or
// one instance, optionally for one database's series. The most specific live rule is the one in force on an instance
// (instance over tag over fleet), so a tag or an instance rule is that scope's threshold override. The alert sender
// judges the rules in its pass and a firing rule goes out through the alert channels like any finding (the Alerts
// page lists it; acknowledge, mute and silence apply). GET /api/alertrules reads the store of 0085; POST
// /api/alertrules and /api/alertrules/end write it behind the UI login (api.post carries the X-Pgvigil header). Every
// write opens a dialog that says what it does; the server answers with the rule's id or the reason it refused. An
// edit ends the rule and writes its successor, so the table is its own history. ruleDialog is also the Metrics page's
// 'threshold' dialog (metrics.ts). The route and the root tab are the shell's.
import { get, post, Row, rowsOf, Table } from './api';
import { fleet, tagsOf } from './fleet';
import { Ctx, rangeLabel, window_ } from './router';
import { whatIsThis } from './sqlview';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid } from './ui';

export interface RulesDoor { writable: boolean; reason?: string; user: string }
interface RulesData extends RulesDoor {
  rules?: Table | null; state?: Table | null; log?: Table | null; catalog?: Table | null; sender?: Table | null;
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
  database?: string;          // a new rule for this database's series
  after: () => void;
}

let catalogCache: Row[] | null = null;
async function catalog(): Promise<Row[]> {
  if (!catalogCache) catalogCache = rowsOf((await get<RulesData>('alertrules', { part: 'catalog' })).catalog);
  return catalogCache;
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
  const name = el('input', { type: 'text', maxlength: '100', value: String(r?.name ?? '') });
  const dir = el('select', {}, el('option', { value: 'above' }, 'above'), el('option', { value: 'below' }, 'below'));
  dir.value = String(p?.op ?? 'above');
  const num = (v: unknown) => el('input', { type: 'number', step: 'any', style: 'width:9em', value: v == null ? '' : String(v) });
  const warn = num(p?.warning), crit = num(p?.critical);
  const mins = el('input', { type: 'number', min: '0', max: '1440', step: '1', style: 'width:5em', value: String(p?.for_minutes ?? 5) });
  const scope = el('select', {}, el('option', { value: 'fleet' }, 'every instance'), el('option', { value: 'tag' }, 'one tag'), el('option', { value: 'instance' }, 'one instance'));
  scope.value = String(r?.scope ?? (o.instanceId ? 'instance' : 'fleet'));
  const tags = [...new Set(insts.flatMap(tagsOf))].sort();
  const tagSel = el('select', {}, ...tags.map(t => el('option', { value: t }, t)));
  if (r?.tag != null) { if (!tags.includes(String(r.tag))) tagSel.append(el('option', { value: String(r.tag) }, String(r.tag))); tagSel.value = String(r.tag); }
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
  // a number field holding something that is not a number reads empty: it must not pass as 'no value'
  const valid = () => metricSel.value !== '' && (warn.value.trim() !== '' || crit.value.trim() !== '')
    && !warn.validity.badInput && !crit.validity.badInput && mins.validity.valid
    && (scope.value !== 'tag' || tagSel.value !== '') && (scope.value !== 'instance' || instSel.value !== '');
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
    'Save', () => post<RuleResult>('alertrules', body()), o.after, fields, valid, [metricSel, warn, crit, mins, scope, tagSel, instSel]);
}

// formDialog: a modal with what the write does, its fields, Save / Back, and the server's answer in place
function formDialog(title: string, what: string, go: string, run: () => Promise<RuleResult>, after: () => void,
  fields: HTMLElement[] = [], valid: () => boolean = () => true, watch: HTMLElement[] = []) {
  const ok = el('button', { type: 'submit' }, go);
  const no = el('button', { type: 'button' }, 'Back');
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const check = () => { ok.disabled = !valid(); };
  for (const w of watch) { w.addEventListener('input', check); w.addEventListener('change', check); }
  check();
  const form = el('form', { method: 'dialog' }, el('h3', {}, title), el('p', {}, what),
    ...fields.map(f => el('div', { style: 'margin:.3rem 0' }, f)), msg, el('div', { style: 'margin-top:.6rem' }, ok, ' ', no));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:44rem', 'aria-label': title }, form);
  let done = false;
  const close = () => { dlg.close(); dlg.remove(); if (done) after(); };
  no.addEventListener('click', close);
  dlg.addEventListener('cancel', () => { dlg.remove(); if (done) after(); });
  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    ok.disabled = true;
    msg.textContent = 'Saving...';
    try {
      const res = await run();
      done = true;
      msg.replaceChildren(badge(res.outcome, 'ok'), ' ', res.detail);
      no.textContent = 'Close';
    } catch (e) {
      msg.replaceChildren(badge('not saved', 'crit'), ' ', e instanceof Error ? e.message : String(e));
      ok.disabled = !valid();   // a refusal leaves the form as typed: correct it and save again
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
  const newRule = () => ruleButton(d, 'New rule', 'New rule', () => { void ruleDialog({ door: d, after: redraw }); });
  // who judges the rules: the alert sender, with at least one channel
  const judged = sender.evaluated_at != null
    ? `The alert sender last judged the rules ${fmtTime(sender.evaluated_at)}.`
    : Number(sender.channels ?? 0) === 0
      ? 'No alert channel is configured, so no sender runs and the rules are not judged: a channel is named in the configuration\'s alerts: list (docs/alerts.md).'
      : 'The alert sender has not judged the rules yet (its pass runs once a minute inside pgvigil run).';
  sec.append(el('p', { class: 'meta' }, live.length
    ? `${live.length} rule(s) live${off ? ` (${off} switched off)` : ''}, ${firing} firing on an instance. ${judged} `
    : `No alert rule yet. ${judged} `, what()));
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
      { key: 'firing', label: 'state', fmt: (v, r) => !r.live || !r.enabled ? '' : r.evaluated_at == null ? 'not judged yet'
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
    sec.append(el('h3', {}, 'Rules'), el('div', { class: 'seg' }, endedBtn), wrap);
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
  return sec;
}
