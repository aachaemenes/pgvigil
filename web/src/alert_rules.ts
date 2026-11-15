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
import { offBeside } from './ack';

// note: the page's one visible sentence where rules cannot be written here - every off control of the page shares that
// reason and points at it (the page that draws the sentence sets it); without one an off control says the reason beside itself
export interface RulesDoor { writable: boolean; reason?: string; user: string; note?: HTMLElement }
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
  return scope === 'fleet' ? 'every instance' : scope === 'tag' ? `tag ${String(target ?? '')}`
    : scope === 'tags' ? `tags ${String(target ?? '')}` : `instance ${String(target ?? '')}`;
}

// opWords: a rule's operator as the dialog and the grids say it (0154's families beside above / below)
export function opWords(op: unknown, r?: Row): string {
  switch (op) {
    case 'rises': return 'rises by more than';
    case 'above_baseline': return `above the hour's baseline + ${fmtNum(r?.band_pct ?? 20)} % and above`;
    default: return String(op ?? '');
  }
}

// tagKey / tagValue: 'key:value' split at the first colon (a bare tag is key '' with its whole text), as 0154 does
const tagKey = (t: string) => t.includes(':') ? t.slice(0, t.indexOf(':')).trim().toLowerCase() : '';
const tagValue = (t: string) => t.includes(':') ? t.slice(t.indexOf(':') + 1) : t;

// tagsMatch: 0154's alert_tags_match - every key of the list met by one of its values among an instance's tags
export function tagsMatch(list: string[], tags: string[]): boolean {
  if (!list.length) return false;
  const keys = [...new Set(list.map(tagKey))];
  return keys.every(k => list.some(s => tagKey(s) === k && tags.some(t => tagKey(t) === k && tagValue(t) === tagValue(s))));
}

// tagsExpression: a tag list as a reader says it - '(env:prod OR env:stage) AND app:billing'
export function tagsExpression(list: string[]): string {
  const by = new Map<string, string[]>();
  for (const t of [...list].sort()) { const k = tagKey(t); by.set(k, [...(by.get(k) ?? []), t]); }
  return [...by.keys()].sort().map(k => { const v = by.get(k)!; return v.length > 1 ? `(${v.join(' OR ')})` : v[0]; }).join(' AND ');
}

// conditionWords: 'above 3 (warning), 5 (critical) for 5 min', the values in the metric's unit
export function conditionWords(r: Row, unit: unknown = r.unit): string {
  const lv = [r.warning != null ? `${fmtMetric(r.warning, unit)} (warning)` : '', r.critical != null ? `${fmtMetric(r.critical, unit)} (critical)` : ''].filter(Boolean);
  const mins = Number(r.for_minutes ?? 0);
  return `${opWords(r.op, r)} ${lv.join(', ')} ${mins > 0 ? `for ${mins} min` : 'at the first sample'}`;
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

// ruleButton: a button that opens the rule dialog; where rules cannot be written here it is off with the reason in
// words on the page (the page's sentence, door.note, or beside itself)
export function ruleButton(door: RulesDoor, label: string, aria: string, open: () => void): HTMLButtonElement {
  const b = el('button', { type: 'button', class: 'link', 'aria-label': aria }, label);
  if (!door.writable) offBeside(b, door.reason || 'alert rules are read only here', door.note);
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
  const dir = el('select', {}, el('option', { value: 'above' }, 'above'), el('option', { value: 'below' }, 'below'),
    el('option', { value: 'rises' }, 'rises between two samples by more than'),
    el('option', { value: 'above_baseline' }, "above the hour's baseline (7 days) and above"));
  dir.value = String(p?.op ?? 'above');
  // a baseline rule's band and zone (0154: the same local hour of the last 7 days, widened by the band; relaxed - the
  // rule's own value must be passed too), and the flapping opt-out (SQLWATCH's per-check ignore_flapping)
  const band = el('input', { type: 'number', min: '0', max: '1000', step: 'any', style: 'width:6em', value: String(r?.band_pct ?? 20) });
  const browserZone = (() => { try { return Intl.DateTimeFormat().resolvedOptions().timeZone; } catch { return 'UTC'; } })();
  const zone = el('input', { type: 'text', maxlength: '64', style: 'width:14em', value: String(r?.zone ?? browserZone) });
  const baseBox = el('span', {}, el('label', {}, 'band ', band, ' % above the baseline'), ' ', el('label', {}, 'hours read in ', zone));
  const noFlap = el('input', { type: 'checkbox' });
  noFlap.checked = !!r?.ignore_flapping;
  const num = (v: unknown) => el('input', { type: 'number', step: 'any', style: 'width:9em', value: v == null ? '' : String(v) });
  const warn = num(p?.warning), crit = num(p?.critical);
  const mins = el('input', { type: 'number', min: '0', max: '1440', step: '1', style: 'width:5em', value: String(p?.for_minutes ?? 5) });
  const scope = el('select', {}, el('option', { value: 'fleet' }, 'every instance'), el('option', { value: 'tag' }, 'one tag'),
    el('option', { value: 'tags' }, 'a tag list'), el('option', { value: 'instance' }, 'one instance'));
  scope.value = String(r?.scope ?? (o.instanceId ? 'instance' : o.tag ? 'tag' : 'fleet'));
  const tags = [...new Set(insts.flatMap(tagsOf))].sort();
  // a tag list (N15 N16 N20): a tick list with a search; the expression and the active instances it matches, live
  const picked = new Set<string>(Array.isArray(r?.scope_tags) ? (r!.scope_tags as unknown[]).map(String) : []);
  const tagFind = el('input', { type: 'search', placeholder: 'find a tag', 'aria-label': 'Find a tag' });
  const tagTicks = el('div', { class: 'tag-ticks', style: 'max-height:10em;overflow:auto' });
  const tagExpr = el('p', { class: 'meta', 'aria-live': 'polite' });
  const drawTicks = () => {
    const q = tagFind.value.trim().toLowerCase();
    tagTicks.replaceChildren(...[...new Set([...tags, ...picked])].sort().filter(t => !q || t.toLowerCase().includes(q)).map(t => {
      const cb = el('input', { type: 'checkbox' });
      cb.checked = picked.has(t);
      cb.addEventListener('change', () => { if (cb.checked) picked.add(t); else picked.delete(t); drawExpr(); });
      return el('label', { style: 'display:block' }, cb, ' ', t);
    }));
  };
  const drawExpr = () => {
    const list = [...picked];
    const n = insts.filter(i => tagsMatch(list, tagsOf(i))).length;
    tagExpr.textContent = list.length ? `Applies to: ${tagsExpression(list)}. Matches ${n} active instance(s).` : 'Tick at least one tag.';
  };
  tagFind.addEventListener('input', drawTicks);
  drawTicks(); drawExpr();
  const tagsBox = el('div', {}, tagFind, tagTicks, tagExpr);
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
    tagsBox.hidden = scope.value !== 'tags';
    instBox.hidden = scope.value !== 'instance';
    baseBox.hidden = dir.value !== 'above_baseline';
    dbBox.hidden = !m?.per_database;
  };
  metricSel.addEventListener('change', sync);
  scope.addEventListener('change', sync);
  dir.addEventListener('change', sync);
  instSel.addEventListener('change', () => { instSel.dataset.picked = '1'; });
  sync();
  const fields: HTMLElement[] = [
    el('label', {}, 'Metric ', metricSel), unitLine,
    el('span', {}, el('label', {}, 'Alert when it is ', dir), ' ', el('label', {}, 'warning ', warn), ' ', el('label', {}, 'critical ', crit), ' ', el('label', {}, 'for ', mins, ' minutes')),
    baseBox,
    el('p', { class: 'meta' }, 'One of warning and critical is enough. 0 minutes alerts at the first sample beyond the value; n minutes needs every sample of n minutes beyond it. A rise compares each sample with the one before it. A baseline rule fires above the same local hour\'s average of the last 7 days widened by the band AND above its own value; until 7 days are known it judges by its own value alone. Rules of different kinds on one metric work side by side.'),
    el('span', {}, el('label', {}, 'Covers ', scope), ' ', tagBox, ' ', instBox),
    tagsBox,
    el('label', {}, noFlap, ' Never hold as flapping (by default an alert whose last 12 results change 4 to 7 times is sent once, then its repeats are held)'),
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
    scope.value === 'tags' && picked.size === 0 ? 'at least one tag in the list' : '',
    dir.value === 'above_baseline' && zone.value.trim() === '' ? "the baseline's time zone" : '',
    dir.value === 'above_baseline' && (band.validity.badInput || !band.validity.valid) ? 'a band from 0 to 1000 %' : '',
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
      scope_tags: scope.value === 'tags' ? [...picked] : undefined,
      band_pct: dir.value === 'above_baseline' && band.value.trim() !== '' ? Number(band.value) : undefined,
      zone: dir.value === 'above_baseline' ? zone.value.trim() : undefined,
      ignore_flapping: noFlap.checked,
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
    [metricSel, warn, crit, mins, scope, tagSel, instSel, band, zone]);
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
  // 0154's fields of each rule (the tag list, the family, the baseline's band and zone, the flapping opt-out) and the
  // overrides, read beside 0085's page; a repository before 0154 answers without them and the page is 0085's
  let overrides: Row[] = [];
  try {
    const x = await get<{ rules?: Table | null }>('alertscope', { ...window_(ctx), part: 'rules' });
    const by = new Map(rowsOf(x.rules).map(e => [String(e.rule_id), e]));
    for (const r of all) Object.assign(r, by.get(String(r.rule_id)) ?? {});
    overrides = rowsOf((await get<{ overrides?: Table | null }>('alertscope', { part: 'overrides' })).overrides);
  } catch { /* the scope parts are 0154's: without them the rules read as 0085 wrote them */ }
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
  // the page's one sentence where rules cannot be written here: every off control below points at it
  if (!d.writable) { d.note = el('p', { class: 'meta' }, `Alert rules are read only here: ${d.reason ?? ''}`); sec.append(d.note); }
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
        if (!d.writable) offBeside(b, d.reason || 'alert rules are read only here', d.note);
        else b.addEventListener('click', () => confirmWrite(v ? `Switch rule ${String(r.rule_id)} off?` : `Switch rule ${String(r.rule_id)} on?`,
          v ? 'A rule switched off is in force nowhere: a wider rule on the same metric takes its place, and an alert it raised resolves. The row stays.' : 'The alert sender judges the rule again from its next pass.',
          v ? 'Switch off' : 'Switch on', () => post<RuleResult>('alertrules', { op: v ? 'disable' : 'enable', rule_id: Number(r.rule_id) }), redraw));
        return el('span', { class: 'seg', style: 'margin:0' }, b);
      } },
      { key: 'rule_id', label: 'rule', num: true },
      { key: 'name', fmt: v => String(v ?? '') },
      { key: 'metric', fmt: (v, r) => r.label == null ? `${String(v)} (no longer a metric)` : `${String(r.family_label)}: ${String(r.label)}` },
      { key: 'op', label: 'alert when', fmt: (_v, r) => conditionWords(r) },
      { key: 'scope', label: 'covers', fmt: (v, r) => {
        const words = scopeWords(v, r.tag ?? r.instance_name ?? r.scope_text);
        // the override line (finding 3 of the 403 pass): a rule of the same kind in force instead of this one
        const by = overrides.filter(o => String(o.rule_id) === String(r.rule_id));
        const over = overrides.filter(o => String(o.by_rule_id) === String(r.rule_id));
        const lines = [
          ...by.map(o => `overridden on ${fmtNum(o.instances)} instance(s) by rule ${String(o.by_rule_id)}${o.by_rule_name != null ? ` ${String(o.by_rule_name)}` : ''}`),
          ...over.map(o => `overrides rule ${String(o.rule_id)} on ${fmtNum(o.instances)} instance(s)`),
        ];
        return lines.length ? el('span', {}, words, el('br'), el('span', { class: 'meta' }, lines.join('; '))) : words;
      } },
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
  sec.append(await windowsView(d, ctx));
  sec.append(timelineView(ctx));
  return sec;
}

// ---- windows (0154; N17 N18 N22, PM Added 4 / 7): blackout, mute and daily-digest windows ---------------------------

interface WindowResult { outcome: string; detail: string; window_id?: number | null }
const isoDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const actionWords: Record<string, string> = { blackout: 'blackout (nothing sent)', mute: 'mute (nothing sent)', digest: 'hold for the daily digest' };

// windowWords: a window's span as one line - 'Mon-Fri 22:00-06:00 America/Chicago (across midnight)'
export function windowWords(w: Row): string {
  const days = Array.isArray(w.weekdays) ? (w.weekdays as unknown[]).map(Number) : [];
  const d = days.length === 7 ? 'every day' : days.map(n => isoDays[n - 1] ?? String(n)).join(' ');
  const across = String(w.end_local) <= String(w.start_local) ? ' (across midnight: the start day\'s)' : '';
  return `${d} ${String(w.start_local)}-${String(w.end_local)} ${String(w.zone)}${across}`;
}

async function windowsView(door: RulesDoor, ctx: Ctx): Promise<HTMLElement> {
  const box = el('div', {});
  box.append(el('h3', {}, 'Windows ', whatIsThis('A window holds alerts on chosen weekdays during a daily span in a time zone: a blackout or a mute sends nothing (the held sends are logged, and the Alerts page says why each was held); a digest window holds info and warning alerts for the channel\'s daily digest (a channel\'s digest_hour: docs/alerts.md) - a critical always pages at once. Its scope is one instance, a tag list or the whole fleet, or a rule\'s own. A span across midnight belongs to the day it starts. On a daylight-saving day a span inside the skipped hour holds nothing, and one in the repeated hour holds for both passes of it. A window never holds pgvigil\'s own alerts about the repository or a collector.', 'Alert windows')));
  let rows: Row[] = [];
  try { rows = rowsOf((await get<{ windows?: Table | null }>('alertscope', { ...window_(ctx), part: 'windows' })).windows); }
  catch (e) { box.append(errorBox(e)); return box; }
  box.append(el('div', { class: 'seg' }, ruleButton(door, 'New window', 'New window', () => { void windowDialog(door, undefined, redraw); })));
  const cols: Col[] = [
    { key: 'holds_now', label: 'now', fmt: (v, w) => !w.live ? 'ended' : v ? badge('holding', 'warn') : 'not now' },
    { key: 'window_id', label: 'window', num: true },
    { key: 'name', fmt: v => String(v ?? '') },
    { key: 'action', fmt: (v, w) => actionWords[String(v)] + (v === 'digest' ? ` (up to ${String(w.severity_ceiling ?? 'warning')})` : '') },
    { key: 'scope', label: 'covers', fmt: (v, w) => v === 'tags' ? `tags ${tagsExpression((w.scope_tags as string[]) ?? [])}` : scopeWords(v, w.instance_name) },
    { key: 'weekdays', label: 'when', fmt: (_v, w) => windowWords(w) },
    { key: 'until', fmt: (v, w) => [w.starts_at != null ? `from ${fmtTime(w.starts_at)}` : '', v != null ? `until ${fmtTime(v)}` : ''].filter(Boolean).join(' ') },
    { key: 'created_at', label: 'made', fmt: (v, w) => `${fmtTime(v)} by ${String(w.created_by)}` + (w.replaces != null ? ` (replaces window ${String(w.replaces)})` : '') },
    { key: 'note', wide: true },
    { key: '_edit', label: '', fmt: (_v, w) => !w.live ? '' : el('span', { style: 'white-space:nowrap' },
      ruleButton(door, 'Edit', `Edit window ${String(w.window_id)}`, () => { void windowDialog(door, w, redraw); }), ' · ',
      ruleButton(door, 'End', `End window ${String(w.window_id)}`, () => confirmWrite(`End window ${String(w.window_id)}?`,
        'An ended window holds nothing from the next pass; the row stays with who ended it and when.', 'End',
        () => post<WindowResult>('alertwindows', { op: 'end', window_id: Number(w.window_id) }) as Promise<RuleResult>, redraw))) },
  ];
  box.append(grid(rows, cols, 'No window. A window holds alerts on weekdays during a daily span (a maintenance blackout, a nightly mute, a digest).'));
  return box;
}

// windowDialog: the one form a window is made or edited through (minimum role operator, B24f)
async function windowDialog(door: RulesDoor, w: Row | undefined, after: () => void) {
  let insts: Row[];
  try { insts = (await fleet()).instances; } catch (e) { window.alert('The window form could not load: ' + (e instanceof Error ? e.message : String(e))); return; }
  const name = el('input', { type: 'text', maxlength: '100', value: String(w?.name ?? '') });
  const action = el('select', {}, ...Object.entries(actionWords).map(([k, v]) => el('option', { value: k }, v)));
  action.value = String(w?.action ?? 'blackout');
  const ceiling = el('select', {}, el('option', { value: 'warning' }, 'info and warning'), el('option', { value: 'info' }, 'info only'));
  ceiling.value = String(w?.severity_ceiling ?? 'warning');
  const ceilBox = el('label', {}, 'Holds ', ceiling, ' (a critical always pages at once)');
  const scope = el('select', {}, el('option', { value: 'fleet' }, 'every instance'), el('option', { value: 'tags' }, 'a tag list'), el('option', { value: 'instance' }, 'one instance'));
  scope.value = String(w?.scope ?? 'fleet');
  const instSel = el('select', {}, ...insts.map(i => el('option', { value: String(i.instance_id) }, String(i.name))));
  if (w?.instance_name != null) { const m = insts.find(i => i.name === w.instance_name); if (m) instSel.value = String(m.instance_id); }
  const tags = [...new Set(insts.flatMap(tagsOf))].sort();
  const picked = new Set<string>(Array.isArray(w?.scope_tags) ? (w!.scope_tags as unknown[]).map(String) : []);
  const ticks = el('div', { style: 'max-height:10em;overflow:auto' });
  const expr = el('p', { class: 'meta', 'aria-live': 'polite' });
  const drawExpr = () => {
    const list = [...picked];
    expr.textContent = list.length ? `Applies to: ${tagsExpression(list)}. Matches ${insts.filter(i => tagsMatch(list, tagsOf(i))).length} active instance(s).` : 'Tick at least one tag.';
  };
  ticks.append(...[...new Set([...tags, ...picked])].sort().map(t => {
    const cb = el('input', { type: 'checkbox' });
    cb.checked = picked.has(t);
    cb.addEventListener('change', () => { if (cb.checked) picked.add(t); else picked.delete(t); drawExpr(); });
    return el('label', { style: 'display:block' }, cb, ' ', t);
  }));
  drawExpr();
  const tagsBox = el('div', {}, ticks, expr), instBox = el('label', {}, 'Instance ', instSel);
  const days = isoDays.map((d, i) => {
    const cb = el('input', { type: 'checkbox' });
    cb.checked = Array.isArray(w?.weekdays) ? (w!.weekdays as unknown[]).map(Number).includes(i + 1) : i < 5;
    return { cb, label: el('label', {}, cb, ' ', d) };
  });
  const start = el('input', { type: 'time', value: String(w?.start_local ?? '22:00') });
  const end = el('input', { type: 'time', value: String(w?.end_local ?? '06:00') });
  const browserZone = (() => { try { return Intl.DateTimeFormat().resolvedOptions().timeZone; } catch { return 'UTC'; } })();
  const zone = el('input', { type: 'text', maxlength: '64', style: 'width:14em', value: String(w?.zone ?? browserZone) });
  const note = el('textarea', { rows: '2', maxlength: '500', style: 'width:100%' });
  note.value = String(w?.note ?? '');
  const sync = () => { ceilBox.hidden = action.value !== 'digest'; tagsBox.hidden = scope.value !== 'tags'; instBox.hidden = scope.value !== 'instance'; };
  action.addEventListener('change', sync); scope.addEventListener('change', sync); sync();
  const fields: HTMLElement[] = [
    el('label', {}, 'Action ', action), ceilBox,
    el('span', {}, el('label', {}, 'Covers ', scope), ' ', instBox), tagsBox,
    el('span', {}, ...days.map(x => x.label)),
    el('span', {}, el('label', {}, 'from ', start), ' ', el('label', {}, 'to ', end), ' ', el('label', {}, 'in ', zone)),
    el('p', { class: 'meta' }, 'An end before the start runs across midnight, as part of the day it starts.'),
    el('label', {}, 'Name (optional) ', name),
    el('label', {}, 'Note (optional)', el('br'), note),
  ];
  const invalid = () => [
    days.some(x => x.cb.checked) ? '' : 'at least one weekday',
    start.value === '' || end.value === '' ? 'a start and an end' : start.value === end.value ? 'an end different from the start' : '',
    zone.value.trim() === '' ? 'a time zone' : '',
    scope.value === 'tags' && picked.size === 0 ? 'at least one tag' : '',
  ].filter(Boolean).join(', ');
  const body = () => ({
    op: w ? 'edit' : 'add', window_id: w ? Number(w.window_id) : undefined,
    name: name.value.trim() || undefined, action: action.value, scope: scope.value,
    scope_tags: scope.value === 'tags' ? [...picked] : undefined,
    instance_id: scope.value === 'instance' ? Number(instSel.value) : undefined,
    weekdays: days.flatMap((x, i) => x.cb.checked ? [i + 1] : []),
    start_local: start.value, end_local: end.value, zone: zone.value.trim(),
    severity_ceiling: action.value === 'digest' ? ceiling.value : undefined,
    note: note.value.trim() || undefined,
  });
  formDialog(w ? `Edit window ${String(w.window_id)}` : 'New window',
    w ? 'Saving ends this window and writes its successor (the old row stays). The alert sender reads it from its next pass.'
      : 'The alert sender reads the window from its next pass. Held sends are logged; the Alerts page says why each was held.',
    'Save', () => post<WindowResult>('alertwindows', body()) as Promise<RuleResult>, after, fields,
    () => door.writable ? invalid() : `a server where alert windows can be written (${door.reason ?? 'read only here'})`,
    [action, scope, start, end, zone, ...days.map(x => x.cb)]);
}

// ---- the findings history (0154; ENG#7, OVW#137, PBI#3): one instance's timeline -----------------------------------

function timelineView(ctx: Ctx): HTMLElement {
  const box = el('div', {});
  const pick = el('select', { 'aria-label': 'Instance for the findings timeline' }, el('option', { value: '' }, 'pick an instance'));
  const out = el('div', {});
  void fleet().then(f => { for (const i of f.instances) pick.append(el('option', { value: String(i.instance_id) }, String(i.name))); }).catch(() => undefined);
  pick.addEventListener('change', async () => {
    if (!pick.value) { out.replaceChildren(); return; }
    let rows: Row[];
    try { rows = rowsOf((await get<{ history?: Table | null }>('alertscope', { ...window_(ctx), part: 'history', instance_id: pick.value })).history); }
    catch (e) { out.replaceChildren(errorBox(e)); return; }
    // one line per finding: its opens, closes and severity changes in order; the hourly samples counted
    const by = new Map<string, Row[]>();
    for (const r of rows) by.set(String(r.finding_key), [...(by.get(String(r.finding_key)) ?? []), r]);
    const lines: Row[] = [...by.values()].map(ev => ({
      finding: `${String(ev[0].source ?? '')}: ${String(ev[0].setting ?? '')}`,
      value: String(ev[0].value ?? ''),
      events: ev.filter(e => e.event !== 'sample').map(e => `${String(e.event)} ${String(e.severity ?? '')} ${fmtTime(e.snapshot_at)}`).join(' > '),
      samples: ev.filter(e => e.event === 'sample').length,
      last: ev[ev.length - 1].snapshot_at,
    }));
    out.replaceChildren(grid(lines, [
      { key: 'finding' }, { key: 'value', wide: true }, { key: 'events', label: 'opened, changed, closed', wide: true },
      { key: 'samples', label: 'hourly samples', num: true }, { key: 'last', label: 'last row', fmt: fmtTime },
    ], `No finding opened, changed or stood on this instance ${rangeLabel(ctx)}.`));
  });
  box.append(el('h3', {}, `Findings history ${rangeLabel(ctx)} `, whatIsThis('Every finding\'s open, close and severity change on one instance, whatever the channels, and one sample an hour while it stands: the timeline of what was wrong and when. Kept 90 days.', 'Findings history')), pick, out);
  return box;
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
