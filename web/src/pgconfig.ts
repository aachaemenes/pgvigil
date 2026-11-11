// The settings grid of a PostgreSQL instance's Configuration page (task 132; Darling's Configuration tab): setting,
// value, unit, default, source, what a change needs, pending restart and category, the settings waiting for a restart
// first. The rows are the server-level non-default settings plus every setting whose file value waits for a restart
// (the instance collection's detail list). Data: /api/pgconfig. The Configuration page calls pgConfigSection with the
// names changed in its range, which it marks.
import { get, Row, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';

// what a change of a setting needs, from pg_settings.context
const needs: Record<string, string> = {
  postmaster: 'a restart', sighup: 'a reload', superuser: 'a session (superuser)', user: 'a session',
  backend: 'a new session', 'superuser-backend': 'a new session (superuser)', internal: 'cannot be changed',
};

export async function pgConfigSection(ctx: Ctx, changed: Set<string> = new Set()): Promise<HTMLElement> {
  const box = el('div', {}, el('h3', {}, 'Settings'));
  let rows: Row[];
  try { rows = rowsOf((await get<{ settings: Table | null }>('pgconfig', { instance: ctx.instance })).settings); }
  catch (e) { box.append(errorBox(e)); return box; }
  if (!rows.length) { box.append(el('p', { class: 'empty' }, 'No non-default settings recorded.')); return box; }
  const detail = rows.some(r => r.detail_read === true);
  const pending = rows.filter(r => r.pending_restart === true).length;
  const nonDefault = rows.filter(r => r.non_default === true).length;
  const name = (v: unknown) => changed.has(String(v)) ? el('b', { title: 'changed in this range' }, String(v) + ' *') : String(v ?? '');
  const cols: Col[] = detail ? [
    { key: 'name', label: 'setting', fmt: name },
    { key: 'value', wide: true },
    { key: 'unit' },
    { key: 'default_value', label: 'default', wide: true },
    { key: 'source' },
    { key: 'context', label: 'a change needs', fmt: v => v == null ? '' : `${needs[String(v)] ?? String(v)} (${String(v)})` },
    { key: 'pending_restart', label: 'pending restart', fmt: v => v === true ? badge('pending restart', 'warn') : '' },
    { key: 'category' },
  ] : [
    { key: 'name', label: 'setting', fmt: name },
    { key: 'value', wide: true },
  ];
  box.append(
    el('p', { class: 'meta' }, `${fmtNum(nonDefault)} non-default setting(s) at the server level`
      + (detail ? `, ${fmtNum(pending)} waiting for a restart (listed first)` : '') + `; read ${fmtTime(rows[0].snapshot_at)}. `
      + (detail
        ? 'Value and default are in the setting\'s own unit. Source: where the value in use comes from. Pending restart: '
          + 'at the last reload the configuration file held another value than the running server, which takes it at '
          + 'the next restart (such a setting can still read source "default"; PostgreSQL keeps the mark until a restart '
          + 'or until the file names the running value again). A setting marked * changed in this range.'
        : 'The unit, default, source, restart and category columns arrive with the next hourly instance read: this read '
          + 'came from a collector older than them.')),
    grid(rows, cols, 'No non-default settings recorded.'));
  return box;
}
