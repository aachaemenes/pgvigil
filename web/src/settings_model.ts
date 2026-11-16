// The settings of an instance added in Admin > Instances as one model (ST5b, the design pass's F7): the panel
// (admin_settings.ts) and the tree's Pause / Resume Collections and Configure Schedule (treemenu.ts) each draw their own
// table in DBA Dash's shape and share this - the stored object, reading what was typed, the floor and the ceiling, the
// changes a dialog makes to the whole object, and the write (POST /api/admin/instances op 'settings' with expect: the
// settings as read, so a change made meanwhile elsewhere is refused, never undone unseen).

export interface Stored {
  schedules?: Record<string, number>;          // seconds; 0 = off
  query_text?: string;
  thresholds?: Record<string, number | string[]>; // a SQL Server instance's; backup_exclude a list of LIKE patterns
  paused?: Record<string, number>;             // the own interval of a paused collection, for its resume
}

// everyWords: seconds as the panel writes an interval ('5m', '1h', '90s', '2d'; 0 = 'off')
export function everyWords(secs: number): string {
  if (secs <= 0) return 'off';
  for (const [n, u] of [[86400, 'd'], [3600, 'h'], [60, 'm']] as const) if (secs % n === 0) return `${secs / n}${u}`;
  return `${secs}s`;
}

// goDuration: seconds as pgvigil.yaml takes them (Go's time.ParseDuration: s, m and h only - never 'd')
export function goDuration(secs: number): string {
  for (const [n, u] of [[3600, 'h'], [60, 'm']] as const) if (secs > 0 && secs % n === 0) return `${secs / n}${u}`;
  return `${secs}s`;
}

// parseEvery reads what an admin typed: '' = the default, 'off' (or 0) = off, else a number with s, m, h or d
// (a bare number is minutes, as nothing else would be meant); null = not an interval
export function parseEvery(text: string): number | '' | null {
  const t = text.trim().toLowerCase();
  if (t === '') return '';
  if (t === 'off' || t === '0') return 0;
  const m = /^(\d+)\s*(s|m|h|d)?$/.exec(t);
  if (!m) return null;
  return Number(m[1]) * { s: 1, m: 60, h: 3600, d: 86400 }[(m[2] ?? 'm') as 's' | 'm' | 'h' | 'd'];
}

// checkEvery: why an interval cannot be set here ('' = it can): off, or from the floor to the ceiling
export function checkEvery(secs: number, floor: number, ceiling: number): string {
  if (secs === 0) return '';
  if (secs < floor) return `an interval set here is ${everyWords(floor)} or more`;
  if (secs > ceiling) return `an interval set here is ${everyWords(ceiling)} or less`;
  return '';
}

// copyOf: a deep copy of the stored object (each change works on its own copy: the read stays the expect)
export function copyOf(s: Stored): Stored {
  return JSON.parse(JSON.stringify(s ?? {})) as Stored;
}

// withSchedule: the object with one collection's own interval set (secs), or taken away (undefined: back to the
// default); a value set by hand ends a pause of that collection
export function withSchedule(s: Stored, name: string, secs: number | undefined): Stored {
  const out = copyOf(s);
  const sch = { ...(out.schedules ?? {}) };
  if (secs === undefined) delete sch[name]; else sch[name] = secs;
  out.schedules = sch;
  if (out.paused) { delete out.paused[name]; if (!Object.keys(out.paused).length) delete out.paused; }
  if (!Object.keys(sch).length) delete out.schedules;
  return out;
}

// paused: the object with the collection off, its own interval (when it had one) kept for the resume; a collection
// already paused keeps the interval it kept (the build review's m1)
export function pausedOf(s: Stored, name: string): Stored {
  const own = s.schedules?.[name];
  const kept = own !== undefined && own > 0 ? own : s.paused?.[name];
  const out = withSchedule(s, name, 0);
  if (kept !== undefined) out.paused = { ...(out.paused ?? {}), [name]: kept };
  return out;
}

// offOf: whether a collection is off for a page instance - its own stored value first (0 = off), else the interval in
// force (serve's, which may lag a write made through another serve: the build review's m1)
export function offOf(s: Stored, name: string, interval: number | null | undefined): boolean {
  const own = s.schedules?.[name];
  if (own !== undefined) return own === 0;
  return interval != null && Number(interval) === 0;
}

// fileOffOf: whether pgvigil.yaml's global schedules: turns the collection off for every instance - its default here 0
// while it has a built-in interval (an opt-in collection has none); the build review's m2
export interface CatalogueTimes { default_s: number; builtin_s: number }
export function fileOffOf(e: CatalogueTimes | undefined): boolean {
  return e != null && Number(e.default_s) === 0 && Number(e.builtin_s) > 0;
}

// pauseResumeOf: Pause/Resume Collections' Save - each collection whose tick changed paused (its own interval kept) or
// resumed (the kept interval, else the built-in one where the file turns it off, else its default); everything else of
// the object (thresholds, query_text, every other schedule) as it was read
export function pauseResumeOf(s: Stored, runs: Record<string, boolean>, cat: Record<string, CatalogueTimes | undefined>,
  intervals: Record<string, number | null | undefined>): Stored {
  let out = copyOf(s);
  for (const [name, want] of Object.entries(runs)) {
    if (want === !offOf(s, name, intervals[name])) continue;
    out = want ? resumedOf(out, name, fileOffOf(cat[name]), Number(cat[name]?.builtin_s ?? 0)) : pausedOf(out, name);
  }
  return out;
}

// resumed: the object with the collection running again - its kept interval written back, else its default (the key
// taken away); a collection off for every instance by pgvigil.yaml's global schedules: is given its own built-in
// interval (builtin), as an own value comes before the file's global one (ST5a's S1)
export function resumedOf(s: Stored, name: string, fileOff: boolean, builtin: number): Stored {
  const kept = s.paused?.[name];
  if (kept !== undefined) return withSchedule(s, name, kept);
  if (fileOff) return withSchedule(s, name, builtin);
  return withSchedule(s, name, undefined);
}

// withThresholds: the object with the thresholds the panel read (an empty set takes the key away)
export function withThresholds(s: Stored, th: Record<string, number | string[]>): Stored {
  const out = copyOf(s);
  if (Object.keys(th).length) out.thresholds = th; else delete out.thresholds;
  return out;
}

// patternsOf: what was typed for backup_exclude, a comma-separated list of LIKE patterns ('' = none)
export function patternsOf(text: string): string[] {
  return text.split(',').map(p => p.trim()).filter(p => p !== '');
}

// the write of the whole object, with the settings it was read as
type Answer = { ok: boolean; body: Record<string, unknown> };
export function saveSettings(send: (path: string, data: Record<string, unknown>) => Promise<Answer>, name: string, settings: Stored, expect: Stored): Promise<Answer> {
  return send('admin/instances', { op: 'settings', name, settings, expect });
}

// postAdmin POSTs a write of Admin > Instances and answers the server's outcome (a refusal, 409, carries its reason)
export async function postAdmin(path: string, data: Record<string, unknown>): Promise<Answer> {
  const res = await fetch('/api/' + path, {
    method: 'POST', credentials: 'same-origin',
    headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-Pgvigil': '1' },
    body: JSON.stringify(data),
  });
  let body: Record<string, unknown> = {};
  try { body = await res.json(); } catch { /* an empty answer */ }
  return { ok: res.ok, body };
}
