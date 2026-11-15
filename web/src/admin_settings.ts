// Admin > Instances: Settings (the ServiceConfig takes, ST5a; DBA Dash's per-instance schedule of its ServiceConfig).
//
// An instance added here gets its own schedules - each collection's interval, or off - and its statement-text policy
// (query_text), as pgvigil.yaml gives one of its own instances schedules:, disabled: and query_text:. Serve judges what
// is sent (the collection names of the instance's engine, a minute or more, the running plans box's collection left to
// the box) and the repository stores and audits it (POST /api/admin/instances op 'settings'); the collector takes it
// within 15 s and restarts that instance's collections alone. An instance of pgvigil.yaml is changed in the file.
//
// The page (admin_instances.ts) owns the tables, the status line and the read-only lock; it hands them in (Deps).
import { Row, rowsOf, Table } from './api';
import { el } from './ui';

type Answer = { ok: boolean; body: Record<string, unknown> };
export interface Deps {
  send: (path: string, data: Record<string, unknown>) => Promise<Answer>;
  say: (text: string, bad?: boolean) => void;
  draw: () => Promise<void>;
  lock: (cell: HTMLElement) => HTMLElement;
  why: (b: Record<string, unknown>) => string;
}

interface Collection { name: string; default_s: number; builtin_s: number; box: boolean; never: string }
interface Stored { schedules?: Record<string, number>; query_text?: string }

// everyWords: seconds as the panel writes an interval ('5m', '1h', '90s', '2d'; 0 = 'off')
export function everyWords(secs: number): string {
  if (secs <= 0) return 'off';
  for (const [n, u] of [[86400, 'd'], [3600, 'h'], [60, 'm']] as const) if (secs % n === 0) return `${secs / n}${u}`;
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

export function instanceSettings(deps: Deps) {
  let stored = new Map<string, Stored>();
  let catalogue: Record<string, Collection[]> = {};
  let floor = 60, defaultQT = '', readError = '';
  const box = el('div', { id: 'admin-instance-settings' });

  function set(data: object): void {
    const d = data as Record<string, unknown>;
    stored = new Map(rowsOf(d.settings as Table | null).map((r: Row) => {
      let v: Stored = {};
      try { v = JSON.parse(String(r.settings ?? '{}')) as Stored; } catch { v = {}; }
      return [String(r.name), v];
    }));
    catalogue = (d.settings_catalogue ?? {}) as Record<string, Collection[]>;
    floor = Number(d.settings_floor_s ?? 60);
    defaultQT = String(d.settings_default_qt ?? '');
    readError = String(d.settings_error ?? '');
  }

  // summary: the row's words for what it has of its own ('statements 1m, activity off; query_text none')
  function summary(name: string): string {
    const s = stored.get(name) ?? {};
    const sch = Object.entries(s.schedules ?? {}).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => `${k} ${everyWords(v)}`);
    const parts = [sch.join(', '), s.query_text ? `query_text ${s.query_text}` : ''].filter(Boolean);
    return parts.length ? parts.join('; ') : 'defaults';
  }

  function show(name: string, engine: string): void {
    const have = stored.get(name) ?? {};
    const list = catalogue[engine] ?? [];
    if (!list.length) {
      box.replaceChildren(el('h3', {}, `Settings: ${name}`), el('p', { class: 'meta' }, readError || 'This server lists no collection to set (pgvigil serve does).'));
      return;
    }
    const inputs = new Map<string, HTMLInputElement>();
    const rows = list.map(c => {
      const own = have.schedules?.[c.name];
      const def = c.default_s > 0 ? `every ${everyWords(c.default_s)}` + (c.default_s !== c.builtin_s ? ` (pgvigil.yaml's schedules:; its own ${everyWords(c.builtin_s)})` : '')
        : 'off: opt-in, it runs only where an interval is set';
      let cell: HTMLElement;
      let note = '';
      if (c.box) {
        cell = el('span', {}, 'the running plans box');
        note = 'ticked or cleared on the instance\'s row';
      } else if (c.never) {
        cell = el('span', {}, 'never here');
        note = c.never;
      } else {
        const input = el('input', { type: 'text', size: '6', inputmode: 'text', 'aria-label': `${c.name}: interval for ${name}`, placeholder: 'default' });
        input.value = own === undefined ? '' : everyWords(own);
        inputs.set(c.name, input);
        cell = input;
      }
      return el('tr', {}, el('td', {}, c.name), el('td', {}, def), el('td', {}, cell), el('td', { class: 'meta' }, note));
    });
    const qt = el('select', { id: 'admin-settings-qt' },
      el('option', { value: '' }, `pgvigil.yaml's (${defaultQT || 'full'})`),
      ...['full', 'normalized', 'none'].map(v => el('option', { value: v }, v)));
    qt.value = have.query_text ?? '';
    const save = deps.lock(el('button', { type: 'button', 'aria-label': `Save the settings of ${name}` }, 'Save the settings'));
    save.addEventListener('click', async () => {
      const schedules: Record<string, number> = {};
      for (const [k, input] of inputs) {
        const v = parseEvery(input.value);
        if (v === null) { deps.say(`${k}: '${input.value}' is not an interval (5m, 1h, 2d or off)`, true); input.focus(); return; }
        if (v === '') continue;
        if (v > 0 && v < floor) { deps.say(`${k}: an interval set here is ${everyWords(floor)} or more`, true); input.focus(); return; }
        schedules[k] = v;
      }
      const settings: Stored = { schedules };
      if (qt.value) settings.query_text = qt.value;
      deps.say(`Saving the settings of ${name}…`);
      const res = await deps.send('admin/instances', { op: 'settings', name, settings });
      if (!res.ok) { deps.say(`Settings of ${name} not saved: ${deps.why(res.body)}`, true); return; }
      deps.say(`${String(res.body.detail ?? 'saved')}. ${String(res.body.takes_effect ?? '')}`);
      await deps.draw();
    });
    const close = el('button', { type: 'button', class: 'link', 'aria-label': `Close the settings of ${name}` }, 'Close');
    // Close hands focus back to the row's Settings button (the page may have drawn the row again since: found by name)
    close.addEventListener('click', () => {
      box.replaceChildren();
      const opener = Array.from(document.querySelectorAll<HTMLElement>('button[data-settings-of]')).find(b => b.dataset.settingsOf === name);
      opener?.focus();
    });
    const title = el('h3', { id: 'admin-instance-settings-title', tabindex: '-1' }, `Settings: ${name}`);
    box.replaceChildren(
      title,
      el('p', { class: 'meta' }, 'Each collection runs at its default unless an interval is set here: 5m, 1h, 2d, or off. '
        + `An interval set here is ${everyWords(floor)} or more, and comes before pgvigil.yaml's global schedules: for this instance. `
        + 'The collector takes a change within 15 seconds and restarts this instance\'s collections alone.'),
      el('p', {}, el('label', { for: 'admin-settings-qt' }, 'Statement text kept (query_text): '), qt),
      el('table', { class: 'grid', 'aria-labelledby': 'admin-instance-settings-title' },
        el('thead', {}, el('tr', {}, ...['collection', 'by default', 'this instance', 'note'].map(h => el('th', { scope: 'col' }, h)))),
        el('tbody', {}, ...rows)),
      el('div', {}, save, ' ', close));
    box.scrollIntoView({ block: 'nearest' });
    title.focus(); // a screen reader hears the panel open (ST5a's review F5)
  }

  // the row's link: its own settings' words, the panel on a click
  const settingsButton = (name: string, engine: string): HTMLElement => {
    const b = el('button', { type: 'button', class: 'link', 'aria-label': `Settings of ${name}: ${summary(name)}`, 'data-settings-of': name }, 'Settings');
    b.title = summary(name);
    b.addEventListener('click', () => show(name, engine));
    return b;
  };

  return { set, summary, settingsButton, box };
}
