// The settings grid of a PostgreSQL instance's Configuration page (task 132; Darling's Configuration tab): setting,
// value, unit, default, source, what a change needs, pending restart and category, the settings waiting for a restart
// first. The rows are the server-level non-default settings plus every setting whose file value waits for a restart
// (the instance collection's detail list). Data: /api/pgconfig. The Configuration page calls pgConfigSection with the
// names changed in its range, which it marks.
// Above it the best-practice grid (DBA Dash's coloured Configuration grid, for PostgreSQL): every setting a rule
// covers with the value in use as a status cell - green where the rule is met, yellow where a warning or an advice
// rule is broken, red where a critical one is, grey where the rule is not for this platform - worst first. The same
// colour sits on the setting's value in the Settings grid. Data: the same read's 'rules' table (0099).
import { get, Row, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';

// what a change of a server-level value (the file's, as this grid lists) needs before it is in use, from
// pg_settings.context: a session-settable one (user, superuser) takes the file's value at a reload and can also be
// SET in one session; a backend one is read when a session starts
const needs: Record<string, string> = {
  postmaster: 'restart', sighup: 'reload', superuser: 'reload, or SET (superuser)', user: 'reload, or SET',
  backend: 'reload, new sessions', 'superuser-backend': 'reload, new sessions', internal: 'fixed',
};
// a value as the cell shows it: a long one cut at 60 characters, whole in its title and in a copy or an export
const CUT = 60;
const valueCell = (v: unknown): string | Node => {
  const s = v == null ? '' : String(v);
  return s.length <= CUT ? s : el('span', { title: s, 'data-full': s }, s.slice(0, CUT) + '...');
};

const rank: Record<string, number> = { crit: 0, warn: 1, ok: 2, none: 3 };
const statusOfRule = (r: Row | undefined): string => { const s = String(r?.status ?? ''); return s in rank ? s : ''; };
const verdict = (r: Row): string => {
  switch (statusOfRule(r)) {
    case 'crit': return 'deviates: critical';
    case 'warn': return r.severity === 'info' ? 'deviates: advice' : 'deviates: warning';
    case 'ok': return 'meets the rule';
    default: return 'not for this platform';
  }
};

// bestPractice: the grid of rule-covered settings, worst first; nothing when the server or its store predates the
// rules read (the reply then has no 'rules' table).
function bestPractice(rules: Row[]): HTMLElement[] {
  if (!rules.length) return [];
  const sorted = [...rules].sort((a, b) => (rank[statusOfRule(a)] ?? 9) - (rank[statusOfRule(b)] ?? 9) || String(a.setting).localeCompare(String(b.setting)));
  const n = (k: string) => rules.filter(r => statusOfRule(r) === k).length;
  const cols: Col[] = [
    { key: 'setting' },
    { key: 'value', label: 'value in use', cls: (_v, r) => { const s = statusOfRule(r); return s ? 'status ' + s : ''; },
      fmt: (v, r) => { const c = valueCell(v); return r.is_set === true ? c : el('span', { title: 'the built-in default: nothing sets it' }, c, ' (default)'); } },
    // the value a broken rule asks for; a met rule asks for nothing, so its cell stays empty
    { key: 'suggested', label: 'suggested', fmt: (v, r) => { const s = statusOfRule(r); return s === 'crit' || s === 'warn' ? valueCell(v) : ''; } },
    { key: 'status', label: 'verdict', fmt: (_v, r) => verdict(r) },
    { key: 'detail', label: 'what the rule guards against', wide: true },
    { key: 'platforms', label: 'rule applies to' },
  ];
  return [
    el('h3', {}, 'Best practice'),
    el('p', { class: 'meta' }, `${fmtNum(rules.length)} settings carry a rule: ${fmtNum(n('crit'))} critical, ${fmtNum(n('warn'))} warning or advice, `
      + `${fmtNum(n('ok'))} meet their rule, ${fmtNum(n('none'))} not for this platform. Green: the value in use meets the rule. Yellow: a warning or `
      + 'an advice rule is broken. Red: a critical rule is broken. Grey: the rule is not meant for this platform. Values are in the '
      + "setting's base unit (ms, s, kB, MB, 8 kB pages), as the rules compare them. The rules are pg_gather's parameter "
      + "recommendations and pgvigil's own; a broken one is also a finding."),
    grid(sorted, cols),
  ];
}

export async function pgConfigSection(ctx: Ctx, changed: Set<string> = new Set()): Promise<HTMLElement> {
  const box = el('div', {});
  let rows: Row[], rules: Row[];
  try {
    const d = await get<{ settings: Table | null; rules?: Table | null }>('pgconfig', { instance: ctx.instance });
    rows = rowsOf(d.settings); rules = rowsOf(d.rules ?? null);
  } catch (e) { box.append(el('h3', {}, 'Settings'), errorBox(e)); return box; }
  box.append(...bestPractice(rules), el('h3', {}, 'Settings'));
  const ruleOf = new Map(rules.map(r => [String(r.setting), r]));
  // a setting a rule covers carries the rule's colour on its value here too (grey 'not for this platform' stays plain)
  const valueCls = (_v: unknown, r: Row) => { const s = statusOfRule(ruleOf.get(String(r.name))); return s && s !== 'none' ? 'status ' + s : ''; };
  // the colour never stands alone: the verdict is the value's title and a column of its own (the export carries it)
  const ruleVerdict = (r: Row): string => { const x = ruleOf.get(String(r.name)); return x && statusOfRule(x) !== 'none' ? verdict(x) : ''; };
  const valueFmt = (v: unknown, r: Row): string | Node => { const t = ruleVerdict(r); return t ? el('span', { title: 'best practice: ' + t }, valueCell(v)) : valueCell(v); };
  const bp: Col[] = rules.length ? [{ key: 'best_practice', label: 'best practice', fmt: (_v, r) => ruleVerdict(r) }] : [];
  if (!rows.length) { box.append(el('p', { class: 'empty' }, 'No non-default settings recorded.')); return box; }
  const detail = rows.some(r => r.detail_read === true);
  const pending = rows.filter(r => r.pending_restart === true).length;
  const nonDefault = rows.filter(r => r.non_default === true).length;
  const name = (v: unknown) => changed.has(String(v)) ? el('b', { title: 'changed in this range' }, String(v) + ' *') : String(v ?? '');
  const cols: Col[] = detail ? [
    { key: 'name', label: 'setting', fmt: name },
    { key: 'value', fmt: valueFmt, cls: valueCls },
    ...bp,
    { key: 'unit' },
    { key: 'default_value', label: 'default', fmt: valueCell },
    { key: 'source' },
    { key: 'context', label: 'a change needs', fmt: v => v == null ? '' : el('span', { title: `pg_settings.context: ${String(v)}` }, needs[String(v)] ?? String(v)) },
    { key: 'pending_restart', label: 'pending restart', fmt: v => v === true ? badge('pending restart', 'warn') : '' },
    { key: 'category' },
  ] : [
    { key: 'name', label: 'setting', fmt: name },
    { key: 'value', fmt: valueFmt, cls: valueCls },
    ...bp,
  ];
  box.append(
    el('p', { class: 'meta' }, `${fmtNum(nonDefault)} non-default setting(s) at the server level`
      + (detail ? `, ${fmtNum(pending)} waiting for a restart (listed first)` : '') + `; read ${fmtTime(rows[0].snapshot_at)}. `
      + (detail
        ? 'Value and default are in the setting\'s own unit. Source: where the value in use comes from. A change needs: what a new '
          + 'value in the file takes before it is in use (a restart; a reload; "or SET": a session can also set its own). Pending restart: '
          + 'at the last reload the configuration file held another value than the running server, which takes it at '
          + 'the next restart (such a setting can still read source "default"; PostgreSQL keeps the mark until a restart '
          + 'or until the file names the running value again). A setting marked * changed in this range.'
        : 'The unit, default, source, restart and category columns arrive with the next hourly instance read: this read '
          + 'came from a collector older than them.')),
    grid(rows, cols, 'No non-default settings recorded.'));
  return box;
}
