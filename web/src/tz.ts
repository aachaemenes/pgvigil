// The display time zone: every time the UI prints, every chart's time axis, a typed start or end and an export's times
// are in ONE zone, named in the header beside the range and chosen in the range panel (DBA Dash's time-zone box,
// Darling's 'Times are in ...' line): the browser's own zone (the default), UTC, or any zone the browser knows.
// Remembered per browser. Under the default every function here takes the Date object's own local getters, so a page
// reads exactly as it did before a zone could be chosen.

const KEY = 'pgvigil.tz';
function lsGet(k: string): string | null { try { return localStorage.getItem(k); } catch { return null; } }
function lsSet(k: string, v: string) { try { localStorage.setItem(k, v); } catch { /* private window */ } }
const two = (n: number) => String(n).padStart(2, '0');

export function browserZone(): string { try { return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'; } catch { return 'UTC'; } }
const known = (z: string) => { try { new Intl.DateTimeFormat('en-US', { timeZone: z }); return true; } catch { return false; } };

let choice: string | undefined;
// zoneChoice: 'local' (the browser's zone) or a zone name; a stored name this browser does not know reads as 'local'
export function zoneChoice(): string {
  if (choice === undefined) { const v = lsGet(KEY) ?? 'local'; choice = v !== 'local' && known(v) ? v : 'local'; }
  return choice;
}
export function setZone(z: string) { choice = z !== 'local' && known(z) ? z : 'local'; lsSet(KEY, choice); }
// zoneName: the zone the times are in, by its name
export const zoneName = () => zoneChoice() === 'local' ? browserZone() : zoneChoice();
// zones: what the chooser offers after the browser's own: UTC, then every zone name the browser lists
export function zones(): string[] {
  let all: string[] = [];
  try { all = (Intl as unknown as { supportedValuesOf?: (k: string) => string[] }).supportedValuesOf?.('timeZone') ?? []; } catch { /* an old browser: UTC alone */ }
  return ['UTC', ...all.filter(z => z !== 'UTC')];
}

// fmt: a time as the user's locale writes it, in the display zone (date and time unless the options name parts)
export function fmt(d: Date, o: Intl.DateTimeFormatOptions = { hour12: false }): string {
  const z = zoneChoice();
  return d.toLocaleString(undefined, z === 'local' ? o : { ...o, timeZone: z });
}
// fmtClock: the time of day alone
export function fmtClock(d: Date, o: Intl.DateTimeFormatOptions = { hour12: false }): string {
  const z = zoneChoice();
  return d.toLocaleTimeString(undefined, z === 'local' ? o : { ...o, timeZone: z });
}

// parts: the wall clock of an instant in the display zone (mo 1-12, wd 0 = Sunday)
export interface Parts { y: number; mo: number; d: number; h: number; mi: number; s: number; wd: number }
const WD: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
let pf: { z: string; f: Intl.DateTimeFormat } | undefined;
export function parts(d: Date): Parts {
  const z = zoneChoice();
  if (z === 'local') return { y: d.getFullYear(), mo: d.getMonth() + 1, d: d.getDate(), h: d.getHours(), mi: d.getMinutes(), s: d.getSeconds(), wd: d.getDay() };
  if (!pf || pf.z !== z) pf = { z, f: new Intl.DateTimeFormat('en-US', { timeZone: z, hourCycle: 'h23', weekday: 'short', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric' }) };
  const o: Record<string, string> = {};
  for (const p of pf.f.formatToParts(d)) o[p.type] = p.value;
  return { y: Number(o.year), mo: Number(o.month), d: Number(o.day), h: Number(o.hour) % 24, mi: Number(o.minute), s: Number(o.second), wd: WD[o.weekday] ?? 0 };
}

// offsetMin: the display zone's minutes east of UTC at that instant (a zone's offset changes with its daylight saving)
export function offsetMin(at: Date): number {
  if (zoneChoice() === 'local') return -at.getTimezoneOffset();
  const p = parts(at);
  return Math.round((Date.UTC(p.y, p.mo - 1, p.d, p.h, p.mi, p.s) - Math.floor(at.getTime() / 1000) * 1000) / 60000);
}
export function offsetLabel(at: Date): string {
  const m = offsetMin(at), a = Math.abs(m);
  return `UTC${m < 0 ? '-' : '+'}${two(Math.floor(a / 60))}:${two(a % 60)}`;
}

// zonedToUtc: the instant of a wall-clock time in the display zone. A day or a month out of its range rolls over (day 0
// = the last day of the month before). A time a daylight-saving jump skips lands on the far side of the jump (as the
// browser's own Date does); a time a fall-back repeats is one of its two passes.
export function zonedToUtc(y: number, mo: number, d: number, h = 0, mi = 0, s = 0): Date {
  if (zoneChoice() === 'local') return new Date(y, mo - 1, d, h, mi, s);
  const wall = Date.UTC(y, mo - 1, d, h, mi, s);
  // two guesses: the offset in force at the wall time read as UTC, then the offset in force at that first guess
  const a = wall - offsetMin(new Date(wall)) * 60000, b = wall - offsetMin(new Date(a)) * 60000;
  if (a === b) return new Date(a);
  const hit = (t: number) => { const p = parts(new Date(t)); return Date.UTC(p.y, p.mo - 1, p.d, p.h, p.mi, p.s) === wall; };
  return new Date(hit(b) ? b : hit(a) ? a : Math.max(a, b));
}

// toInput / fromInput: a datetime-local input shows and takes the display zone's wall clock
export function toInput(d: Date, secs = false): string {
  const p = parts(d);
  return `${String(p.y).padStart(4, '0')}-${two(p.mo)}-${two(p.d)}T${two(p.h)}:${two(p.mi)}${secs ? ':' + two(p.s) : ''}`;
}
export function fromInput(v: string): Date {
  const m = /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)(?::(\d\d))?/.exec(v);
  return m ? zonedToUtc(Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6] ?? 0)) : new Date(NaN);
}

// stamp: 'YYYY-MM-DD HH:MM:SS' for a copied or exported row; fileStamp: 'YYYYMMDD-HHMM' for a saved file's name
export function stamp(d: Date): string { const p = parts(d); return `${p.y}-${two(p.mo)}-${two(p.d)} ${two(p.h)}:${two(p.mi)}:${two(p.s)}`; }
export function fileStamp(d: Date): string { const p = parts(d); return `${p.y}${two(p.mo)}${two(p.d)}-${two(p.h)}${two(p.mi)}`; }
