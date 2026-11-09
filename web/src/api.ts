// The API returns {columns, rows}; Row gives named access to one row.
export interface Table { columns: string[]; rows: unknown[][] }
export type Row = Record<string, unknown>;

export function rowsOf(t: Table | null | undefined): Row[] {
  if (!t) return [];
  return t.rows.map(r => Object.fromEntries(t.columns.map((c, i) => [c, r[i]])));
}

// LoginRequired is thrown on a 401: the shell shows the sign-in form.
export class LoginRequired extends Error { constructor() { super('login required'); } }

async function body(res: Response): Promise<unknown> {
  if (res.status === 204) return null;
  return res.json().catch(() => ({ error: res.statusText }));
}

export async function get<T = Table>(path: string, params: Record<string, string | number | undefined> = {}): Promise<T> {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== '') q.set(k, String(v));
  const url = '/api/' + path + (q.toString() ? '?' + q : '');
  const res = await fetch(url, { headers: { Accept: 'application/json' }, credentials: 'same-origin' });
  if (res.status === 401) throw new LoginRequired();
  const b = await body(res);
  if (!res.ok) throw new Error((b as { error?: string }).error ?? res.statusText);
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
}

export type Tables<K extends string> = Record<K, Table | null>;
