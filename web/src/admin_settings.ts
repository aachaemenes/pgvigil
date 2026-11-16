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
import { checkEvery, copyOf, everyWords, parseEvery, patternsOf, saveSettings, Stored, withSchedule, withThresholds } from './settings_model';

type Answer = { ok: boolean; body: Record<string, unknown> };
export interface Deps {
  send: (path: string, data: Record<string, unknown>) => Promise<Answer>;
  say: (text: string, bad?: boolean) => void;
  draw: () => Promise<void>;
  lock: (cell: HTMLElement) => HTMLElement;
  why: (b: Record<string, unknown>) => string;
}

interface Collection { name: string; default_s: number; builtin_s: number; box: boolean; never: string }
interface Threshold { name: string; default: number; patterns: boolean }
const CEILING = 2592000; // 30 days, config.PageScheduleCeiling

export { everyWords, parseEvery } from './settings_model';

export function instanceSettings(deps: Deps) {
  let stored = new Map<string, Stored>();
  let catalogue: Record<string, Collection[]> = {};
  let thresholds: Threshold[] = [];
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
    thresholds = (d.settings_thresholds ?? []) as Threshold[];
    defaultQT = String(d.settings_default_qt ?? '');
    readError = String(d.settings_error ?? '');
  }

  // summary: the row's words for what it has of its own ('statements 1m, activity off; query_text none')
  function summary(name: string): string {
    const s = stored.get(name) ?? {};
    const sch = Object.entries(s.schedules ?? {}).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => `${k} ${everyWords(v)}`);
    const th = Object.keys(s.thresholds ?? {}).length;
    const parts = [sch.join(', '), s.query_text ? `query_text ${s.query_text}` : '', th ? `${th} threshold(s) of its own` : ''].filter(Boolean);
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
    // ST5b: a SQL Server instance's own thresholds (mssql_thresholds), each empty = the collector's default
    const thInputs = new Map<string, HTMLInputElement>();
    const thRows = engine !== 'sqlserver' ? [] : thresholds.map(t => {
      const own = have.thresholds?.[t.name];
      const input = el('input', { type: 'text', size: t.patterns ? '24' : '10', 'aria-label': `${t.name}: threshold for ${name}`, placeholder: 'default' });
      input.value = own === undefined ? '' : Array.isArray(own) ? own.join(', ') : String(own);
      thInputs.set(t.name, input);
      return el('tr', {}, el('td', {}, t.name), el('td', {}, t.patterns ? 'none' : String(t.default)), el('td', {}, input),
        el('td', { class: 'meta' }, t.patterns ? 'database name patterns, comma-separated (LIKE: _ and % match any character)' : 'a number of 0 or more'));
    });
    save.addEventListener('click', async () => {
      // the whole object from the one read (its paused intervals and anything this panel does not draw kept)
      let settings: Stored = copyOf(have);
      for (const [k, input] of inputs) {
        const v = parseEvery(input.value);
        if (v === null) { deps.say(`${k}: '${input.value}' is not an interval (5m, 1h, 2d or off)`, true); input.focus(); return; }
        const was = have.schedules?.[k];
        if (v === '' ? was === undefined : v === was) continue; // unchanged: a pause stays a pause
        if (v !== '') { const why = checkEvery(v, floor, CEILING); if (why) { deps.say(`${k}: ${why}`, true); input.focus(); return; } }
        settings = withSchedule(settings, k, v === '' ? undefined : v);
      }
      if (qt.value) settings.query_text = qt.value; else delete settings.query_text;
      if (thRows.length) {
        const th: Record<string, number | string[]> = {};
        for (const [k, input] of thInputs) {
          const t = input.value.trim();
          if (t === '') continue;
          if (k === 'backup_exclude') { const p = patternsOf(t); if (p.length) th[k] = p; continue; }
          const n = Number(t);
          if (!/^\d+(\.\d+)?$/.test(t) || !Number.isFinite(n)) { deps.say(`${k}: '${t}' is not a number of 0 or more`, true); input.focus(); return; }
          th[k] = n;
        }
        settings = withThresholds(settings, th);
      }
      deps.say(`Saving the settings of ${name}…`);
      const res = await saveSettings(deps.send, name, settings, have);
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
      ...(thRows.length ? [el('h4', { id: 'admin-instance-thresholds-title' }, 'Thresholds (mssql_thresholds: HA/DR, jobs and backups)'),
        el('p', { class: 'meta' }, 'Each threshold is the collector\'s default unless a value is set here; the collector stores a change at the instance\'s next HA/DR, jobs or backups read.'),
        el('table', { class: 'grid', 'aria-labelledby': 'admin-instance-thresholds-title' },
          el('thead', {}, el('tr', {}, ...['threshold', 'by default', 'this instance', 'note'].map(h => el('th', { scope: 'col' }, h)))),
          el('tbody', {}, ...thRows))] : []),
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

  return { set, summary, settingsButton, box, open: show };
}
