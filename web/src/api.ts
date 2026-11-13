// The API returns {columns, rows}; Row gives named access to one row. A part that read only the newest part of a long
// window (its reach, internal/web paramsReach) carries what it read: read_from / read_to.
export interface Table { columns: string[]; rows: unknown[][]; read_from?: string; read_to?: string }
export type Row = Record<string, unknown>;
// ReadWindow: the window a list read when its part was cut to its reach; rowsOf hangs it on the rows it returns (as
// `readWindow`, not enumerable), so a grid drawn from them says so above itself and in its export (ui.ts grid)
export interface ReadWindow { from: string; to: string }
export const readWindowOf = (rows: unknown): ReadWindow | undefined => (rows as { readWindow?: ReadWindow } | null | undefined)?.readWindow;

export function rowsOf(t: Table | null | undefined): Row[] {
  if (!t) return [];
  const out = t.rows.map(r => Object.fromEntries(t.columns.map((c, i) => [c, r[i]])));
  if (t.read_from && t.read_to) Object.defineProperty(out, 'readWindow', { value: { from: t.read_from, to: t.read_to }, enumerable: false });
  return out;
}

// the reads of the page being drawn that the server cut to a part's reach (its X-Pgvigil-Read-* headers): main.ts
// starts the list at each draw and says them under the range bar; the export and the mail carry them. A section read
// after the page is placed (a lazy part) is heard by the listeners.
export interface CutRead { path: string; asked: string; from: string; to: string }
let cuts: CutRead[] = [];
let cutHeard: ((c: CutRead) => void)[] = [];
export function startReads() { cuts = []; cutHeard = []; }
export function cutReads(): CutRead[] { return cuts.slice(); }
export function onCutRead(f: (c: CutRead) => void) { cutHeard.push(f); }

// LoginRequired is thrown on a 401: the shell shows the sign-in form.
export class LoginRequired extends Error { constructor() { super('login required'); } }

async function body(res: Response): Promise<unknown> {
  if (res.status === 204) return null;
  return res.json().catch(() => ({ error: res.statusText }));
}

// signal: the caller's AbortSignal; an aborted read is cancelled on the server too (the request's context ends its query)
export async function get<T = Table>(path: string, params: Record<string, string | number | undefined> = {}, signal?: AbortSignal): Promise<T> {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== '') q.set(k, String(v));
  const url = '/api/' + path + (q.toString() ? '?' + q : '');
  const res = await fetch(url, { headers: { Accept: 'application/json' }, credentials: 'same-origin', signal });
  if (res.status === 401) throw new LoginRequired();
  const b = await body(res);
  if (!res.ok) throw new Error((b as { error?: string }).error ?? res.statusText);
  const rf = res.headers.get('X-Pgvigil-Read-From');
  if (rf) {
    const c: CutRead = { path, asked: res.headers.get('X-Pgvigil-Window-From') ?? '', from: rf, to: res.headers.get('X-Pgvigil-Read-To') ?? '' };
    cuts.push(c);
    for (const f of cutHeard) f(c);
  }
  return b as T;
}

// post carries the X-Pgvigil header: a cross-site form cannot set it, so the session cookie alone never acts.
export async function post<T = unknown>(path: string, data: unknown = {}): Promise<T> {
  const res = await fetch('/api/' + path, {
    method: 'POST', credentials: 'same-origin',
    headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-Pgvigil': '1' },
    body: JSON.stringify(data),
  });
  const b = await body(res);
  if (!res.ok) throw new Error((b as { error?: string })?.error ?? res.statusText);
  return b as T;
}

export interface Session { login: boolean; user?: string }

export interface Activity {
  snapshot_at: string | null;
  summary: Table | null;
  sessions: Table | null;
  chains: Table | null;
}

export interface DMS {
  tasks: Table | null;
  instances: Table | null;
  tables: Table | null;
  drain?: Table | null;
}

export type Tables<K extends string> = Record<K, Table | null>;
