// The stored weekly sp_Blitz (B20-2) on a SQL Server instance's Findings tab: GET /api/mssql/blitz drawn as the due
// rule's words, the switch (admin: the instance's own and the site default), the shown run - the newest one with
// findings - with its server messages, its findings folded by FindingsGroup (and All) under a database filter, and the
// stored runs. sp_Blitz is the SQL Server First Responder Kit's (MIT, Copyright (c) Brent Ozar Unlimited): its findings
// are in its own words; pgvigil calls the copy the DBA installed and never installs one.
import { get, post, Row, rowsOf, Table } from './api';
import { AckData, loadAckSafe, offBeside, seatWhy } from './ack';
import { needControl, needWords } from './needs';
import { Ctx, href } from './router';
import { Col, el, errorBox, fmtTime, grid } from './ui';

type Parts = Record<'state' | 'last' | 'runs' | 'shown' | 'findings' | 'judged', Table | null>;

const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

// blitzUrl: sp_Blitz's URL cell - a link only for an http or https address (read through new URL(), set as text)
function blitzUrl(v: unknown): Node {
  const s = String(v ?? '');
  let u: URL | null = null;
  try { u = s ? new URL(s) : null; } catch { u = null; }
  if (u && (u.protocol === 'http:' || u.protocol === 'https:')) {
    return el('a', { href: u.href, target: '_blank', rel: 'noopener noreferrer', class: 'blitz-url' }, s);
  }
  return el('span', { class: 'blitz-url' }, s);
}

// the findings' columns; a CheckID the Checks tab judges links there
function findingCols(ctx: Ctx, id: number, withGroup: boolean): Col[] {
  return [
    { key: 'priority', num: true },
    ...(withGroup ? [{ key: 'findings_group', label: 'group' } as Col] : []),
    { key: 'finding' },
    { key: 'database_name', label: 'database' },
    { key: 'details', wide: true },
    { key: 'url', label: 'URL', fmt: v => blitzUrl(v) },
    {
      key: 'check_id', label: 'CheckID', num: true, fmt: (v, r) => r.judged
        ? el('a', { href: href(ctx, { tab: 'mssqlchecks', instance: id, tag: undefined }), class: 'blitz-judged', title: "this instance's Checks tab judges this check hourly" }, String(v ?? ''), ' (Checks)')
        : String(v ?? ''),
    },
  ];
}

// groupsView: one folding group per FindingsGroup, All first (open), in sp_Blitz's own order of the rows
function groupsView(ctx: Ctx, id: number, rows: Row[]): HTMLElement {
  const by = new Map<string, Row[]>();
  for (const r of rows) {
    const g = r.findings_group == null || r.findings_group === '' ? '(no group)' : String(r.findings_group);
    if (!by.has(g)) by.set(g, []);
    by.get(g)!.push(r);
  }
  const fold = (name: string, rs: Row[], open: boolean) => {
    const d = el('details', { class: 'blitz-group', 'data-group': name }, el('summary', {}, `${name} (${rs.length})`),
      grid(rs, findingCols(ctx, id, name === 'All'), 'No findings in this group.'));
    if (open) d.open = true;
    return d;
  };
  return el('div', { class: 'blitz-groups' }, fold('All', rows, true), ...[...by.entries()].map(([g, rs]) => fold(g, rs, false)));
}

// runLine: what the shown run is, and the newest run beside it when it is another
function runLine(sh: Row | undefined): HTMLElement[] {
  if (!sh) return [];
  const out: HTMLElement[] = [];
  if (sh.run_id != null) {
    const ver = sh.frk_version ? `sp_Blitz ${sh.frk_version}${sh.frk_version_date ? ` (${String(sh.frk_version_date).slice(0, 10)})` : ''}` : 'sp_Blitz (its version not read)';
    out.push(el('p', { class: 'blitz-run' }, `The newest run with findings: ${fmtTime(sh.started_at)} as ${sh.login ?? '?'} in ${sh.proc_db ?? '?'}, ${ver}, ${sh.outcome}, ${sh.findings} finding(s) in ${sh.seconds ?? '?'} s.`));
  } else {
    out.push(el('p', { class: 'blitz-run' }, 'No run with findings is stored yet.'));
  }
  if (sh.newest_run_id != null && sh.newest_run_id !== sh.run_id) {
    out.push(el('p', { class: 'meta blitz-newest' }, `The newest run (${fmtTime(sh.newest_at)}) ${sh.newest_outcome}${sh.newest_error ? ': ' + String(sh.newest_error) : ''}.` + (sh.run_id != null ? ' The findings below are from the run above.' : '')));
  }
  const msgs = Array.isArray(sh.messages) ? sh.messages as Row[] : [];
  if (msgs.length) {
    out.push(el('details', { class: 'blitz-msgs' }, el('summary', {}, `The server's messages of that run (${msgs.length})`),
      el('ul', {}, ...msgs.map(m => el('li', {}, (m.proc === 'pgvigil' ? 'pgvigil: ' : `Msg ${m.number ?? 0}, severity ${m.severity ?? 0}${m.line ? ', line ' + m.line : ''}${m.proc ? ' (' + m.proc + ')' : ''}: `) + String(m.message ?? ''))))));
  }
  return out;
}

// switchView: the instance's switch and the site default, each with its Save (admin; off with the server's or the
// role's words otherwise)
function switchView(st: Row | undefined, id: number, ad: AckData, again: () => void): HTMLElement {
  const server = seatWhy(ad, 'sp_Blitz settings');
  const roleP = el('p', { class: 'meta off-reason' }, needWords('mssql/blitz/settings', ad.can));
  const gate = (b: HTMLElement) => { if (server) offBeside(b, server); needControl(b, 'mssql/blitz/settings', { note: roleP, can: ad.can }); return b; };
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const opt = (v: string, label: string, on: boolean) => { const o = el('option', { value: v }, label); if (on) o.selected = true; return o; };
  const own = st?.own_switch ? (st.enabled ? 'on' : 'off') : 'site';
  const sel = el('select', { 'aria-label': 'this instance', class: 'blitz-switch' },
    opt('site', `the site default (${st?.site_enabled ? 'on' : 'off'})`, own === 'site'), opt('on', 'on', own === 'on'), opt('off', 'off', own === 'off'));
  const db = el('input', { type: 'text', 'aria-label': "sp_Blitz's database", value: String(st?.proc_db ?? 'master'), maxlength: '128', style: 'width:10rem' });
  const save = gate(el('button', { type: 'button', class: 'blitz-save' }, 'Save'));
  const send = async (body: Record<string, unknown>) => {
    msg.textContent = 'Saving...';
    try { const r = await post<{ detail: string }>('mssql/blitz/settings', body); msg.textContent = 'Saved: ' + r.detail; again(); } catch (e) { msg.textContent = 'Not saved: ' + (e instanceof Error ? e.message : String(e)); }
  };
  save.addEventListener('click', () => {
    const v = sel.value;
    void send({ op: 'instance', instance_id: id, enabled: v === 'site' ? null : v === 'on', proc_db: db.value.trim() });
  });
  // the site default
  const sOn = el('select', { 'aria-label': 'the site default' }, opt('on', 'on', !!st?.site_enabled), opt('off', 'off', !st?.site_enabled));
  const sDay = el('select', { 'aria-label': 'the day' }, ...DAYS.map((d, i) => opt(String(i), d, Number(st?.run_dow ?? 0) === i)));
  const sHour = el('input', { type: 'number', min: '0', max: '23', step: '1', 'aria-label': 'the hour', value: String(st?.run_hour ?? 2), style: 'width:4rem' });
  const sTz = el('input', { type: 'text', 'aria-label': 'the zone', value: String(st?.run_tz ?? 'UTC'), style: 'width:12rem' });
  const sTo = el('input', { type: 'number', min: '1', max: '1800', step: '1', 'aria-label': 'the timeout in seconds', value: String(st?.timeout_s ?? 600), style: 'width:5rem' });
  const sSave = gate(el('button', { type: 'button', class: 'blitz-site-save' }, 'Save the site default'));
  sSave.addEventListener('click', () => {
    void send({ op: 'site', enabled: sOn.value === 'on', run_dow: Number(sDay.value), run_hour: Number(sHour.value), run_tz: sTz.value.trim(), timeout_s: Number(sTo.value) });
  });
  return el('div', { class: 'blitz-switches' },
    el('p', {}, el('label', {}, 'This instance: ', sel), ' ', el('label', {}, "sp_Blitz's database ", db), ' ', save),
    el('details', { class: 'blitz-site' }, el('summary', {}, `The site default: ${st?.site_enabled ? 'on' : 'off'}, every ${DAYS[Number(st?.run_dow ?? 0)] ?? '?'} ${String(st?.run_hour ?? 2).padStart(2, '0')}:00 ${st?.run_tz ?? 'UTC'}, a ${st?.timeout_s ?? 600} s timeout`),
      el('p', {}, el('label', {}, 'Default ', sOn), ' ', el('label', {}, 'Day ', sDay), ' ', el('label', {}, 'Hour ', sHour), ' ', el('label', {}, 'Zone ', sTz), ' ', el('label', {}, 'Timeout (s) ', sTo), ' ', sSave)),
    roleP, msg);
}

// blitzSection: the section, drawn again in place after a save
export async function blitzSection(ctx: Ctx, id: number): Promise<HTMLElement> {
  const sec = el('section', { class: 'blitz' }, el('h2', {}, 'sp_Blitz weekly'));
  let d: Parts, ad: AckData;
  try {
    [d, ad] = await Promise.all([get<Parts>('mssql/blitz', { instance: id }), loadAckSafe(['acks'])]);
  } catch (e) {
    sec.append(errorBox(e));
    return sec;
  }
  const again = () => { void blitzSection(ctx, id).then(n => sec.replaceWith(n)); };
  const st = rowsOf(d.state)[0], last = rowsOf(d.last)[0], sh = rowsOf(d.shown)[0];
  const rows = rowsOf(d.findings), runs = rowsOf(d.runs);
  sec.append(
    el('p', { class: 'meta' }, "The First Responder Kit's sp_Blitz, run once a week where it is installed (pgvigil never installs it) and stored: 12 runs are kept, and the newest one with findings beside them. Its findings are in its own words."),
    el('p', { class: 'blitz-state' }, String(st?.why ?? 'the weekly sp_Blitz has no state here yet')),
  );
  if (last && last.status !== 'ok' && last.note) {
    sec.append(el('p', { class: 'meta blitz-last' }, `The last hourly look (${fmtTime(last.snapshot_at)}): ${last.status}: ${String(last.note)}`));
  }
  sec.append(switchView(st, id, ad, again), ...runLine(sh));
  if (sh?.run_id != null) {
    const dbs = [...new Set(rows.map(r => String(r.database_name ?? '')).filter(Boolean))].sort((a, b) => a.localeCompare(b));
    const pick = el('select', { class: 'blitz-db', 'aria-label': 'the database' }, el('option', { value: '' }, 'All databases'), ...dbs.map(x => el('option', { value: x }, x)));
    const holder = el('div', {}, groupsView(ctx, id, rows));
    pick.addEventListener('change', () => holder.replaceChildren(groupsView(ctx, id, pick.value ? rows.filter(r => String(r.database_name ?? '') === pick.value) : rows)));
    sec.append(el('p', {}, el('label', {}, 'Filter by database ', pick), ' ', el('span', { class: 'meta' }, 'A CheckID marked (Checks) is judged hourly on this instance\'s Checks tab too.')), holder);
  }
  if (runs.length) {
    sec.append(el('details', { class: 'blitz-runs' }, el('summary', {}, `The stored runs (${runs.length})`),
      grid(runs, [{ key: 'started_at', label: 'started', fmt: v => fmtTime(v) }, { key: 'outcome' }, { key: 'findings', num: true }, { key: 'seconds', num: true },
        { key: 'messages', num: true }, { key: 'error', wide: true }, { key: 'login' }, { key: 'proc_db', label: 'database' }, { key: 'frk_version', label: 'version' }])));
  }
  return sec;
}
