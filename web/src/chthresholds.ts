// chthresholds.ts - the pure half of Collection Health's thresholds dialog (B6g-2, N33 / N41), after DBA Dash 4.25.0's
// CollectionHealthThresholdsDialog.cs and CollectionHealthThresholds_Get.sql: the 'Apply to' levels of a row, a level's
// own live row, what a level inherits setting by setting, the values' words and the write a Save sends. No DOM: the
// dialog itself is collection_health.ts'; the Node rows are chthresholds.test.mjs.

export type CHLevel = 'ic' | 'ia' | 'ac' | 'aa';
// a level of the dialog's 'Apply to': this instance and collection, this instance and every collection, this collection
// on every instance, everything (instance_id / collection null = every)
export interface CHScope { key: CHLevel; words: string; instance_id: number | null; collection: string | null }
export type CHSettingKey = 'warn_fails_in_row' | 'warn_fail_minutes' | 'crit_fails_in_row' | 'crit_fail_minutes' | 'warn_fail_pct' | 'crit_fail_pct' | 'min_runs' | 'dont_monitor';
export interface CHSetting { key: CHSettingKey; group: string; label: string; kind: 'int' | 'pct' | 'bool'; min: number; max: number; def: number | boolean }
export type CHRow = Record<string, unknown>;

// the eight settings in DBA Dash's order, its headings and words (the dialog's AddHeading / AddSetting), its ranges
// (NumericUpDown's Minimum / Maximum; 0166's CHECKs hold the same floors) and its defaults
// (CollectionHealthThresholdDefaults: 0166's coalesce)
export const chSettings: CHSetting[] = [
  { key: 'warn_fails_in_row', group: 'Warning - failures in a row', label: 'Failed runs in a row', kind: 'int', min: 1, max: 100000, def: 1 },
  { key: 'warn_fail_minutes', group: 'Warning - failures in a row', label: 'And failing for at least (minutes)', kind: 'int', min: 0, max: 1000000, def: 10 },
  { key: 'crit_fails_in_row', group: 'Critical - failures in a row', label: 'Failed runs in a row', kind: 'int', min: 1, max: 100000, def: 3 },
  { key: 'crit_fail_minutes', group: 'Critical - failures in a row', label: 'And failing for at least (minutes)', kind: 'int', min: 0, max: 1000000, def: 30 },
  { key: 'warn_fail_pct', group: 'Failure rate', label: 'Warning: failed or partly failed %', kind: 'pct', min: 0, max: 100, def: 10 },
  { key: 'crit_fail_pct', group: 'Failure rate', label: 'Critical: failed %', kind: 'pct', min: 0, max: 100, def: 50 },
  { key: 'min_runs', group: 'Failure rate', label: 'Only with at least this many runs', kind: 'int', min: 1, max: 100000, def: 5 },
  { key: 'dont_monitor', group: 'Monitoring', label: 'Don\'t monitor (always N/A)', kind: 'bool', min: 0, max: 1, def: false },
];

// chScopes: the 'Apply to' list of a row, most specific first - with an instance and a collection all four; a row with
// no instance (the collection grain) this collection on every instance and everything (DBA Dash's hasInstance /
// hasReference)
export function chScopes(instanceId: number | null, instanceName: string, collection: string | null): CHScope[] {
  const out: CHScope[] = [];
  const inst = instanceId != null && instanceId > 0, coll = collection != null && collection !== '';
  if (inst && coll) out.push({ key: 'ic', words: `${collection} on ${instanceName}`, instance_id: instanceId, collection });
  if (inst) out.push({ key: 'ia', words: `All collections on ${instanceName}`, instance_id: instanceId, collection: null });
  if (coll) out.push({ key: 'ac', words: `${collection} on all instances`, instance_id: null, collection });
  out.push({ key: 'aa', words: 'All collections on all instances', instance_id: null, collection: null });
  return out;
}

const sameInst = (a: unknown, b: number | null) => (a == null ? null : Number(a)) === b;
const sameColl = (a: unknown, b: string | null) => (a == null || a === '' ? null : String(a)) === b;

// ownRow: the level's own live row among the dialog's read (the four levels' live rows), or null
export function ownRow(live: CHRow[], scope: CHScope): CHRow | null {
  return live.find(r => sameInst(r.instance_id, scope.instance_id) && sameColl(r.collection, scope.collection)) ?? null;
}

const valueOf = (s: CHSetting, v: unknown): number | boolean | null => {
  if (v == null || v === '') return null;
  if (s.kind === 'bool') return v === true || v === 'true' || v === 't';
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};

// inheritedOf: what a level takes for one setting when it sets none of its own - DBA Dash's CollectionHealthThresholds_Get:
// this instance and collection reads this instance's row, this collection's row on every instance, then everything's;
// this instance's row and this collection's row on every instance read everything's; everything reads the defaults.
// 'from' names the level that set it in the dialog's words, or DBA Dash's default.
export function inheritedOf(live: CHRow[], scopes: CHScope[], scope: CHScope, key: CHSettingKey): { value: number | boolean; from: string } {
  const s = chSettings.find(x => x.key === key);
  if (!s) throw new Error(`no setting ${key}`);
  const above: CHLevel[] = scope.key === 'ic' ? ['ia', 'ac', 'aa'] : scope.key === 'aa' ? [] : ['aa'];
  for (const k of above) {
    const sc = scopes.find(x => x.key === k);
    if (!sc) continue;
    const r = ownRow(live, sc), v = r ? valueOf(s, r[key]) : null;
    if (v != null) return { value: v, from: sc.words };
  }
  return { value: s.def, from: 'DBA Dash\'s default' };
}

// chValue: a level's own value of a setting (null = it inherits)
export function chValue(row: CHRow | null, key: CHSettingKey): number | boolean | null {
  const s = chSettings.find(x => x.key === key);
  return s && row ? valueOf(s, row[key]) : null;
}

// chFormat: a value in the dialog's words (DBA Dash's Setting.Format: Yes / No, a number to two places at most)
export function chFormat(v: unknown): string {
  if (v === true) return 'Yes';
  if (v === false) return 'No';
  const n = Number(v);
  return Number.isFinite(n) ? String(Math.round(n * 100) / 100) : String(v ?? '');
}

// chPayload: what a Save sends to POST /api/collectionhealth/thresholds - the level by its keys (none for every) and the
// values ticked (a value left null inherits); nothing ticked on a level with a row of its own is an inherit, on one with
// none nothing to send (null: the dialog says so)
export function chPayload(scope: CHScope, values: Partial<Record<CHSettingKey, number | boolean | null>>, own: CHRow | null): Record<string, unknown> | null {
  const where: Record<string, unknown> = {};
  if (scope.instance_id != null) where.instance_id = scope.instance_id;
  if (scope.collection != null) where.collection = scope.collection;
  const set: Record<string, unknown> = {};
  for (const s of chSettings) {
    const v = values[s.key];
    if (v != null) set[s.key] = v;
  }
  if (Object.keys(set).length) return { op: 'set', ...where, ...set };
  return own ? { op: 'inherit', ...where } : null;
}
