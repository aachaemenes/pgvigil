// The API returns {columns, rows}; Row gives named access to one row.
export interface Table { columns: string[]; rows: unknown[][] }
export type Row = Record<string, unknown>;

export function rowsOf(t: Table | null | undefined): Row[] {
  if (!t) return [];
  return t.rows.map(r => Object.fromEntries(t.columns.map((c, i) => [c, r[i]])));
}

export async function get<T = Table>(path: string, params: Record<string, string | number | undefined> = {}): Promise<T> {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== '') q.set(k, String(v));
  const url = '/api/' + path + (q.toString() ? '?' + q : '');
  const res = await fetch(url, { headers: { Accept: 'application/json' } });
  const body = await res.json().catch(() => ({ error: res.statusText }));
  if (!res.ok) throw new Error((body as { error?: string }).error ?? res.statusText);
  return body as T;
}

export interface Activity {
  snapshot_at: string | null;
  summary: Table | null;
  sessions: Table | null;
  chains: Table | null;
}
