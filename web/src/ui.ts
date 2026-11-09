// DOM helpers and formatters. Data is always set as text, never parsed as HTML.
export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K, attrs: Record<string, string> = {}, ...kids: (Node | string | null | undefined)[]
): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  for (const k of kids) if (k !== null && k !== undefined) e.append(k);
  return e;
}

export function fmtTime(v: unknown): string {
  if (typeof v !== 'string') return v == null ? '' : String(v);
  const d = new Date(v);
  return isNaN(d.getTime()) ? v : d.toLocaleString(undefined, { hour12: false });
}

export function fmtSecs(v: unknown): string {
  if (v == null || v === '') return '';
  let s = Number(v);
  if (!isFinite(s)) return String(v);
  const neg = s < 0; s = Math.abs(s);
  const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60), r = Math.floor(s % 60);
  const t = d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : m ? `${m}m ${r}s` : `${r}s`;
  return neg ? '-' + t : t;
}

export function fmtBytes(v: unknown): string {
  if (v == null || v === '') return '';
  let n = Number(v);
  if (!isFinite(n)) return String(v);
  const u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let i = 0;
  while (Math.abs(n) >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return (i ? n.toFixed(1) : String(Math.round(n))) + ' ' + u[i];
}

export function fmtNum(v: unknown): string {
  if (v == null || v === '') return '';
  const n = Number(v);
  if (!isFinite(n)) return String(v);
  return n.toLocaleString(undefined, { maximumFractionDigits: 2 });
}

export function fmtAny(v: unknown): string {
  if (v == null) return '';
  if (Array.isArray(v)) return v.join(', ');
  if (typeof v === 'object') return JSON.stringify(v);
  if (typeof v === 'string' && /^\d{4}-\d\d-\d\dT/.test(v)) return fmtTime(v);
  return String(v);
}

export interface Col {
  key: string;
  label?: string;
  fmt?: (v: unknown, row: Record<string, unknown>) => string | Node;
  num?: boolean;          // right-aligned, sorted numerically
  wide?: boolean;         // long text, clipped with a title
}

// grid renders rows as a sortable table; clicking a header sorts by it.
export function grid(rows: Record<string, unknown>[], cols: Col[], empty = 'No rows.'): HTMLElement {
  if (rows.length === 0) return el('p', { class: 'empty' }, empty);
  let sortKey = '', asc = true;
  const table = el('table', { class: 'grid' });
  const thead = el('thead'), tbody = el('tbody');
  const head = el('tr');
  for (const c of cols) {
    const th = el('th', c.num ? { class: 'num' } : {}, c.label ?? c.key);
    th.addEventListener('click', () => {
      asc = sortKey === c.key ? !asc : true; sortKey = c.key;
      draw();
    });
    head.append(th);
  }
  thead.append(head);
  table.append(thead, tbody);
  function draw() {
    const data = [...rows];
    if (sortKey) {
      const col = cols.find(c => c.key === sortKey)!;
      data.sort((a, b) => {
        const x = a[sortKey], y = b[sortKey];
        if (x == null) return 1; if (y == null) return -1;
        const r = col.num ? Number(x) - Number(y) : String(x).localeCompare(String(y));
        return asc ? r : -r;
      });
    }
    tbody.replaceChildren(...data.map(r => {
      const tr = el('tr');
      for (const c of cols) {
        const v = r[c.key];
        const out = c.fmt ? c.fmt(v, r) : (c.num ? fmtNum(v) : fmtAny(v));
        const td = el('td', c.num ? { class: 'num' } : c.wide ? { class: 'wide' } : {});
        if (c.wide && typeof out === 'string') td.title = out;
        td.append(out);
        tr.append(td);
      }
      return tr;
    }));
  }
  draw();
  return el('div', { class: 'grid-wrap' }, table);
}

export function badge(text: string, kind: string): HTMLElement {
  return el('span', { class: 'badge ' + kind }, text);
}

export function errorBox(e: unknown): HTMLElement {
  return el('p', { class: 'error' }, 'Error: ' + (e instanceof Error ? e.message : String(e)));
}
