// The tree's right-click menus and the grids' cell-menu lines DBA Dash has (task 172; audit A01, A03, A04, A06, A16,
// A17, A22, B16, E104):
//   - the fleet root ('All instances'): Refresh, Add Connections..., Find Database
//   - an instance: Find Database, Refresh, Instance Actions > Pause/Resume Collections..., Configure Schedule...,
//     Connection Options..., Add Alert Blackout... (pgvigil keeps an instance's collections, schedule and connection in pgvigil.yaml: each
//     dialog shows the instance as the server knows it and writes the config lines that change it, to copy)
//   - a job: Job Info, Configure Thresholds, Start/Stop Job (the Execute Job dialog through the actions door: Run now
//     on a pgAgent job, Stop on a running run, each with its typed confirmation and audit row), Refresh
//   - an instance's Jobs or Databases folder: Filter (the folder's children by a part of their name), Refresh
//   - a node that is a link: Open in a new tab as well (the browser's own menu is replaced on the tree)
//   - a drive node under an instance's Storage folder: the volume's used-space bar beside its name (driveNodes)
//   - every grid's cell menu: Select row / column / all, Filter by value, Exclude value, Clear filters (its Export Excel,
//     the grid alone, is export.ts's, after the copy lines as DBA Dash places it), and DBA Dash's two lines at its foot: 'Rows: n | Cols: m' and the clicked column's (or the
//     selection's) Sum / Avg / Min / Max; a click on a line copies it
// Each menu opens on a right-click, the context-menu key or Shift+F10 on a node; Up / Down move, Right opens a
// submenu, Left closes it, Enter runs, Escape closes and gives the focus back to the node.
// The hooks: installTreeMenu() once (main.ts), driveNodes() in the tree's Storage folders and reloadTree() (tree.ts):
// the WIRING BLOCK of task 172. The tree's nodes are read from what tree.ts draws (the caret's data-key, the name's
// data-nk and its link), so the tree itself carries no menu code.
import { get, Row, rowsOf, Table } from './api';
import { fleet, forget } from './fleet';
import { Cell, fromText, typed } from './export';
import { Ctx, href, isMssql, parse } from './router';
import { hrefWith } from './dbinfo';
import { badge, cellText, copyText, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, gridModel, offControl, props } from './ui';
import { reloadTree } from './tree';
import { loadThresholds, thresholdsDialog } from './mssql_jobs';
import { confirmJobAction, runningState } from './jobs_running';
import { ackDialog, ackWhy, loadAckSafe } from './ack';

// ---- a menu with submenus ------------------------------------------------------------------------------------

export interface MenuItem { label: string; act?: () => void; sub?: MenuItem[]; off?: string; sep?: boolean; info?: boolean }

let open: { boxes: HTMLElement[]; back: HTMLElement | null } | null = null;
function closeAll(focusBack = true) {
  if (!open) return;
  const o = open; open = null;
  for (const b of o.boxes) b.remove();
  if (focusBack && o.back?.isConnected) o.back.focus();
}
const buttonsOf = (box: HTMLElement) => [...box.querySelectorAll<HTMLButtonElement>(':scope > button')];

// menuBox: one level of a menu at x, y (kept inside the window); level 0 replaces any open menu
function menuBox(items: MenuItem[], x: number, y: number, level: number, label: string, parentBtn?: HTMLButtonElement): HTMLElement {
  if (!open) open = { boxes: [], back: null };
  while (open.boxes.length > level) open.boxes.pop()!.remove();
  const box = el('div', { class: 'menu tm-menu', role: 'menu', 'aria-label': label, style: `left:${x}px;top:${y}px` });
  for (const it of items) {
    if (it.sep) { box.append(el('div', { class: 'tm-sep', role: 'separator' })); continue; }
    const b = el('button', { type: 'button', role: 'menuitem', class: it.info ? 'tm-info' : '' }, it.label );
    if (it.sub) {
      b.setAttribute('aria-haspopup', 'menu');
      b.setAttribute('aria-expanded', 'false');
      b.append(el('span', { class: 'tm-arrow', 'aria-hidden': 'true' }, '▸'));
      const openSub = (focus: boolean) => {
        const r = b.getBoundingClientRect();
        buttonsOf(box).forEach(x => x.setAttribute('aria-expanded', 'false'));
        b.setAttribute('aria-expanded', 'true');
        const sub = menuBox(it.sub!, r.right - 2, r.top, level + 1, it.label, b);
        if (focus) buttonsOf(sub)[0]?.focus();
      };
      b.addEventListener('click', () => openSub(true));
      b.addEventListener('mouseenter', () => openSub(false));
    } else if (it.off) {
      b.setAttribute('aria-disabled', 'true');
      b.title = it.off;
      b.classList.add('tm-off');
      b.setAttribute('aria-label', `${it.label}: ${it.off}`);
    } else {
      // the menu closes with the focus back on its node first, so a dialog the item opens returns there when it closes
      b.addEventListener('click', () => { closeAll(true); it.act?.(); });
      b.addEventListener('mouseenter', () => { while (open && open.boxes.length > level + 1) open.boxes.pop()!.remove(); });
    }
    box.append(b);
  }
  box.addEventListener('keydown', e => {
    const bs = buttonsOf(box), i = bs.indexOf(document.activeElement as HTMLButtonElement);
    if (e.key === 'ArrowDown') { e.preventDefault(); bs[(i + 1) % bs.length]?.focus(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); bs[(i - 1 + bs.length) % bs.length]?.focus(); }
    else if (e.key === 'Home') { e.preventDefault(); bs[0]?.focus(); }
    else if (e.key === 'End') { e.preventDefault(); bs[bs.length - 1]?.focus(); }
    else if (e.key === 'ArrowRight' && i >= 0 && bs[i].getAttribute('aria-haspopup')) { e.preventDefault(); bs[i].click(); }
    else if ((e.key === 'ArrowLeft' || e.key === 'Escape') && level > 0) {
      e.preventDefault(); e.stopPropagation();
      while (open && open.boxes.length > level) open.boxes.pop()!.remove();
      parentBtn?.setAttribute('aria-expanded', 'false');
      parentBtn?.focus();
    } else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeAll(); }
    else if (e.key === 'Tab') { e.preventDefault(); closeAll(); }
  });
  document.body.append(box);
  const r = box.getBoundingClientRect();
  if (r.right > innerWidth - 4) box.style.left = `${Math.max(4, (level ? x - r.width - (parentBtn?.getBoundingClientRect().width ?? 0) : x - r.width))}px`;
  if (r.bottom > innerHeight - 4) box.style.top = `${Math.max(4, innerHeight - 4 - r.height)}px`;
  open.boxes.push(box);
  return box;
}

// showTreeMenu: a menu of items at x, y, its first item focused; back: where the focus returns
export function showTreeMenu(x: number, y: number, items: MenuItem[], back: HTMLElement | null, label: string) {
  closeAll(false);
  open = { boxes: [], back };
  const box = menuBox(items, x, y, 0, label);
  open.back = back;
  buttonsOf(box)[0]?.focus();
}

// ---- dialogs -------------------------------------------------------------------------------------------------

// refind: a tree node again after the tree drew itself anew (its name's data-nk, else its link), else the node itself
function refind(back: HTMLElement | null): HTMLElement | null {
  if (!back || back.isConnected) return back;
  const nk = back.dataset.nk, h = back.getAttribute('href');
  return (nk ? document.querySelector<HTMLElement>(`#tree [data-nk="${CSS.escape(nk)}"]`) : null)
    ?? (h ? document.querySelector<HTMLElement>(`#tree a[href="${CSS.escape(h)}"]`) : null);
}

// dialog: a modal with a heading, its body and a Close button; the focus goes back to `back` when it closes
function dialog(title: string, back: HTMLElement | null, wide = false): { dlg: HTMLDialogElement; body: HTMLElement; foot: HTMLElement } {
  const body = el('div', { class: 'tm-body' });
  const close = el('button', { type: 'button' }, 'Close');
  const foot = el('div', { style: 'margin-top:.6rem' }, close);
  const dlg = el('dialog', { class: 'act-dialog tm-dialog', style: `max-width:${wide ? 60 : 42}rem`, 'aria-label': title },
    el('h3', {}, title), body, foot) as HTMLDialogElement;
  close.addEventListener('click', () => dlg.close());
  dlg.addEventListener('close', () => { dlg.remove(); refind(back)?.focus(); });
  document.body.append(dlg);
  dlg.showModal();
  return { dlg, body, foot };
}

// snippet: config lines with a Copy button that says it copied
function snippet(lines: () => string): HTMLElement {
  const pre = el('pre', { class: 'sql tm-yaml', style: 'white-space:pre;margin:.3rem 0;max-height:16rem;overflow:auto', tabindex: '0', 'aria-label': 'the config lines' });
  const said = el('span', { class: 'meta', role: 'status' });
  const copy = el('button', { type: 'button' }, 'Copy the lines');
  copy.addEventListener('click', () => { void copyText(pre.textContent ?? '').then(ok => { said.textContent = ok ? ' Copied.' : ' Not copied: the browser refused the clipboard.'; }); });
  const box = el('div', {}, pre, el('p', {}, copy, said));
  const draw = () => { pre.textContent = lines(); };
  draw();
  (box as HTMLElement & { redraw?: () => void }).redraw = draw;
  return box;
}
const redraw = (e: HTMLElement) => (e as HTMLElement & { redraw?: () => void }).redraw?.();
// yamlStr: a plain YAML scalar only for a word that cannot be read as anything else (a leading letter or underscore, no
// YAML keyword), else a quoted one
const yamlStr = (s: string) => /^[A-Za-z_][A-Za-z0-9_.\/-]*$/.test(s) && !/^(true|false|yes|no|on|off|null|y|n)$/i.test(s) ? s : JSON.stringify(s);
const mergeNote = () => el('p', { class: 'meta' }, 'Merge these keys into the instance\'s own entry under instances: in pgvigil.yaml; a second entry of the same name is refused at start.');
const restartNote = () => el('p', { class: 'meta' }, 'pgvigil reads pgvigil.yaml when the collector starts: change the file, then restart the service (systemctl restart pgvigil, or the Windows service).');

// ---- the node under a click or the focus ----------------------------------------------------------------------

type TNode =
  | { kind: 'root'; el: HTMLElement }
  | { kind: 'instance'; el: HTMLElement; id: number }
  | { kind: 'folder'; el: HTMLElement; id: number; key: string; what: 'jobs' | 'db' }
  | { kind: 'job'; el: HTMLElement; id: number; scheduler: string; job: string; name: string };

function nodeOf(target: Element): TNode | null {
  const tree = target.closest('#tree');
  if (!tree) return null;
  const root = target.closest<HTMLElement>('a.tree-root');
  if (root) return { kind: 'root', el: root };
  const inst = target.closest<HTMLElement>('.tree-inst');
  if (inst) {
    const k = inst.querySelector<HTMLElement>('button.caret')?.dataset.key ?? '';
    const m = /^i(\d+)$/.exec(k);
    if (m) return { kind: 'instance', el: inst.querySelector<HTMLElement>('a.inst') ?? inst, id: Number(m[1]) };
  }
  const head = target.closest<HTMLElement>('.tree-node');
  if (head) {
    const k = head.querySelector<HTMLElement>('button.caret')?.dataset.key ?? '';
    const m = /^i(\d+)\/(jobs|db)$/.exec(k);
    // a PostgreSQL instance's Jobs and Databases folders: their name is a link and their children are jobs and databases
    // (a SQL Server instance's Jobs folder holds its tabs: no Filter there)
    const link = head.querySelector<HTMLElement>('a');
    if (m && link) return { kind: 'folder', el: link, id: Number(m[1]), key: k, what: m[2] as 'jobs' | 'db' };
  }
  const a = target.closest<HTMLAnchorElement>('a.inst[href]');
  if (a) {
    const h = a.getAttribute('href') ?? '';
    if (/^#\/job\?/.test(h)) {
      const q = new URLSearchParams(h.split('?')[1] ?? '');
      const id = Number(q.get('i')), job = q.get('job'), scheduler = q.get('scheduler');
      if (id && job && scheduler) return { kind: 'job', el: a, id, scheduler, job, name: (a.textContent ?? '').trim() };
    }
  }
  return null;
}

const ctxNow = (): Ctx => parse();
async function instanceRow(id: number): Promise<Row | undefined> {
  return (await fleet().catch(() => null))?.instances.find(r => Number(r.instance_id) === id);
}
// refreshAll: the fleet read again and every folder of the tree read again (the bar's Refresh redraws the page)
function refreshAll(prefix = '') {
  forget();
  const inst = /^i(\d+)/.exec(prefix);
  if (!prefix) vols.clear(); else if (inst) vols.delete(Number(inst[1]));
  reloadTree(prefix);
  const b = document.querySelector<HTMLButtonElement>('#bar button[title="Read everything again"]');
  if (b) b.click(); else window.dispatchEvent(new HashChangeEvent('hashchange'));
}
const newTab = (a: HTMLElement): MenuItem[] => {
  const h = a.getAttribute('href');
  return h ? [{ sep: true, label: '' }, { label: 'Open in a new tab', act: () => { window.open(h, '_blank', 'noopener'); } }] : [];
};

// ---- Find Database (the fleet's, or one instance's) ----------------------------------------------------------------

function findDatabase(back: HTMLElement | null, instance?: number) {
  const { dlg, body } = dialog(instance ? 'Find Database on this instance' : 'Find Database', back);
  const input = el('input', { type: 'search', id: 'tm-find', autocomplete: 'off', 'aria-describedby': 'tm-find-out' }) as HTMLInputElement;
  const ok = el('button', { type: 'submit' }, 'OK');
  const out = el('div', { id: 'tm-find-out', role: 'status', 'aria-live': 'polite' });
  const form = el('form', {}, el('label', { for: 'tm-find' }, 'Enter database name '), input, ' ', ok);
  body.append(form, out);
  input.focus();
  let seq = 0;
  form.addEventListener('submit', ev => {
    ev.preventDefault();
    const q = input.value.trim(), lq = q.toLowerCase();
    if ([...q].length < 2) { out.replaceChildren(el('p', { class: 'meta' }, 'Type two characters or more.')); return; }
    const mine = ++seq;
    // only the newest search of a dialog still open shows its answer or moves the page
    const live = () => mine === seq && dlg.open;
    out.replaceChildren(el('p', { class: 'meta' }, 'Searching...'));
    void (async () => {
      const ctx = ctxNow();
      const hits: { name: string; inst: string; to: string; size?: unknown }[] = [];
      const notes: string[] = [];
      try {
        const f = await fleet();
        const scope = f.instances.filter(r => !instance || Number(r.instance_id) === instance);
        const pg = scope.filter(r => !isMssql(r.engine)), ms = scope.filter(r => isMssql(r.engine));
        if (instance && pg.length) {
          // one instance: its own database list (the fleet search stops at its first 50 rows)
          const d = await get<Record<'databases', Table | null>>('dbinfo', { instance, part: 'databases' });
          for (const r of rowsOf(d.databases).filter(x => x.is_present !== false && !x.is_template && String(x.datname).toLowerCase().includes(lq))) {
            hits.push({ name: String(r.datname), inst: String(pg[0].name), to: hrefWith(ctx, 'db', { db: String(r.dbid) }, instance), size: r.size_bytes ?? r.bytes });
          }
        } else if (!instance) {
          const rows = rowsOf(await get<Table>('search', { q })).filter(r => r.kind === 'database');
          if (rows.length > 50) notes.push('More than 50 PostgreSQL databases match: the first 50 are listed; type more of the name.');
          for (const r of rows.slice(0, 50)) hits.push({ name: String(r.datname), inst: String(r.instance), to: hrefWith(ctx, 'db', { db: String(r.dbid) }, Number(r.instance_id)), size: r.bytes });
        }
        // SQL Server: each instance's storage read (the search covers PostgreSQL's collections), four at a time
        let failed = 0;
        for (let i = 0; i < ms.length && live(); i += 4) {
          await Promise.all(ms.slice(i, i + 4).map(async r => {
            const d = await get<Record<string, Table | null>>('mssql/storage', { instance: Number(r.instance_id), part: 'databases' }).catch(() => null);
            if (!d) { failed++; return; }
            for (const x of rowsOf(d.databases)) {
              const n = String(x.database_name ?? x.name ?? '');
              if (n.toLowerCase().includes(lq)) hits.push({ name: n, inst: String(r.name), to: href(ctx, { tab: 'mssqlfiles', instance: Number(r.instance_id), tag: undefined }), size: x.size_bytes ?? x.total_bytes });
            }
          }));
        }
        if (failed) notes.push(`${failed} SQL Server instance${failed === 1 ? '' : 's'} could not be read: their databases are not in this list.`);
      } catch (e) { if (live()) out.replaceChildren(errorBox(e)); return; }
      if (!live()) return;
      const said = notes.map(t => el('p', { class: 'meta' }, t));
      if (hits.length === 0) { out.replaceChildren(el('p', {}, `No database named like "${q}"${instance ? ' on this instance' : ''}.`), ...said); return; }
      hits.sort((a, b) => Number(b.name.toLowerCase() === lq) - Number(a.name.toLowerCase() === lq) || a.name.localeCompare(b.name));
      const exact = hits.filter(h => h.name.toLowerCase() === lq);
      if (exact.length === 1 && !notes.length) { dlg.close(); location.hash = exact[0].to.slice(1); return; }
      out.replaceChildren(el('p', {}, `${hits.length} database${hits.length === 1 ? '' : 's'} named like "${q}":`), ...said,
        el('ul', {}, ...hits.map(h => el('li', {}, el('a', { href: h.to }, h.name), ` on ${h.inst}`, h.size != null ? `, ${fmtBytes(h.size)}` : ''))));
      out.querySelectorAll('a').forEach(a => a.addEventListener('click', () => dlg.close()));
    })();
  });
}

// ---- Add Connections... -----------------------------------------------------------------------------------------

function addConnections(back: HTMLElement | null) {
  const { body } = dialog('Add Connections', back, true);
  const f = (id: string, label: string, input: HTMLElement) => el('p', {}, el('label', { for: id }, label + ' '), input);
  const name = el('input', { id: 'tm-ac-name', placeholder: 'sql02', autocomplete: 'off' }) as HTMLInputElement;
  const engine = el('select', { id: 'tm-ac-engine' }, el('option', { value: 'postgres' }, 'PostgreSQL'), el('option', { value: 'sqlserver' }, 'SQL Server')) as HTMLSelectElement;
  // the platforms the config accepts for each engine (config.Validate): another pair stops the collector at start
  const platforms: Record<string, string[]> = { postgres: ['auto', 'onprem', 'rds', 'aurora', 'azure', 'cloudsql', 'alloydb'], sqlserver: ['auto', 'onprem', 'rds', 'azuresqldb', 'azuresqlmi', 'cloudsql'] };
  const platform = el('select', { id: 'tm-ac-platform' }) as HTMLSelectElement;
  const fillPlatforms = () => { const was = platform.value; platform.replaceChildren(...platforms[engine.value].map(p => el('option', { value: p }, p))); if (platforms[engine.value].includes(was)) platform.value = was; };
  const taken = el('p', { class: 'error', role: 'status', 'aria-live': 'polite' });
  let names = new Set<string>();
  void fleet().then(f => { names = new Set(f.instances.map(r => String(r.name).toLowerCase())); }).catch(() => { /* no check without the fleet */ });
  const env = el('input', { id: 'tm-ac-env', placeholder: 'PGVIGIL_DSN_SQL02', autocomplete: 'off' }) as HTMLInputElement;
  const tags = el('input', { id: 'tm-ac-tags', placeholder: 'env:prod, team:billing', autocomplete: 'off' }) as HTMLInputElement;
  const lines = () => {
    const n = name.value.trim() || '<name>';
    const tg = tags.value.split(',').map(t => t.trim()).filter(Boolean);
    const dsnVar = env.value.trim() || `PGVIGIL_DSN_${n.toUpperCase().replace(/[^A-Z0-9]+/g, '_')}`;
    return ['instances:', `  - name: ${yamlStr(n)}`, ...(engine.value === 'sqlserver' ? ['    engine: sqlserver'] : []),
      ...(platform.value !== 'auto' ? [`    platform: ${platform.value}`] : []),
      `    dsn: env:${dsnVar}`, ...(tg.length ? [`    tags: [${tg.map(yamlStr).join(', ')}]`] : [])].join('\n')
      + `\n\n# the connection string itself goes in the service's environment, never in the file:\n# ${dsnVar}=${engine.value === 'sqlserver' ? 'sqlserver://pgvigil_reader@host:1433?database=master' : 'host=... dbname=postgres user=pgvigil_reader sslmode=require'}`;
  };
  fillPlatforms();
  const snip = snippet(lines);
  const check = () => { taken.textContent = names.has(name.value.trim().toLowerCase()) ? `An instance named ${name.value.trim()} is in the fleet already: the config refuses a second one.` : ''; };
  engine.addEventListener('change', fillPlatforms);
  for (const i of [name, engine, platform, env, tags]) { i.addEventListener('input', () => { check(); redraw(snip); }); i.addEventListener('change', () => { check(); redraw(snip); }); }
  body.append(el('p', {}, 'pgvigil reads its instances from pgvigil.yaml (instances:). These lines add one; the login it connects as needs the rights the install guide names (docs/install, docs/sqlserver-readers).'),
    f('tm-ac-name', 'Name', name), taken, f('tm-ac-engine', 'Engine', engine), f('tm-ac-platform', 'Platform', platform),
    f('tm-ac-env', 'Environment variable with the connection string', env), f('tm-ac-tags', 'Tags (comma-separated)', tags),
    snip, restartNote());
  name.focus();
}

// ---- Instance Actions ---------------------------------------------------------------------------------------------

interface Collections { instance: string; engine: string; collections: Table | null }
const every = (s: unknown) => s == null ? 'not known to this server' : Number(s) === 0 ? 'disabled' : fmtSecs(s);
function goDuration(s: number): string {
  if (s % 3600 === 0) return `${s / 3600}h`;
  if (s % 60 === 0) return `${s / 60}m`;
  return `${s}s`;
}

async function collectionsOf(id: number): Promise<Collections> { return get<Collections>('instance/collections', { instance: id }); }

function pauseResume(id: number, back: HTMLElement | null) {
  const { body } = dialog('Pause/Resume Collections', back, true);
  body.append(el('p', { class: 'meta', role: 'status' }, 'Reading the instance\'s collections...'));
  void collectionsOf(id).then(d => {
    const rows = rowsOf(d.collections);
    // an opt-in collection (its default interval 0) runs only with a schedule: it is never paused or resumed by disabled:
    const optIn = (r: Row) => r.default_s != null && Number(r.default_s) === 0;
    const off = new Set(rows.filter(r => !optIn(r) && r.interval_s != null && Number(r.interval_s) === 0).map(r => String(r.collection)));
    const lines = () => [`# pgvigil.yaml, the instance ${d.instance}:`, 'instances:', `  - name: ${yamlStr(d.instance)}`,
      off.size ? `    disabled: [${[...off].sort().map(yamlStr).join(', ')}]` : '    # disabled: none (every collection runs)'].join('\n');
    const snip = snippet(lines);
    const t = el('table', { class: 'grid' }, el('thead', {}, el('tr', {}, ...['Runs', 'Collection', 'Every', 'Last read', 'Status', 'Errors (24 h)'].map(h => el('th', { scope: 'col' }, h)))),
      el('tbody', {}, ...rows.map(r => {
        const c = String(r.collection);
        const tick = el('input', { type: 'checkbox', 'aria-label': `${c} runs` }) as HTMLInputElement;
        if (optIn(r)) {
          // on only by a schedule: its tick says whether it runs, and Configure Schedule is where it changes
          tick.checked = Number(r.interval_s ?? 0) > 0;
          tick.disabled = true;
          tick.setAttribute('aria-label', `${c}: an opt-in collection, ${tick.checked ? 'on by a schedule' : 'off'}; Configure Schedule gives it an interval`);
        } else {
          tick.checked = !off.has(c);
          tick.addEventListener('change', () => { if (tick.checked) off.delete(c); else off.add(c); redraw(snip); });
        }
        return el('tr', {}, el('td', {}, tick), el('td', {}, c), el('td', {}, optIn(r) && !(Number(r.interval_s ?? 0) > 0) ? 'opt-in: off until a schedule gives it an interval' : every(r.interval_s)), el('td', {}, fmtTime(r.snapshot_at)),
          el('td', {}, r.status === 'error' ? badge('error', 'crit') : r.status === 'skipped' ? badge('skipped', 'warn') : String(r.status ?? '')), el('td', { class: 'num' }, fmtNum(r.errors_24h)));
      })));
    body.replaceChildren(el('p', {}, `The collections of ${d.instance} that have stored a read, as the server knows them. An unticked collection is paused: the config's disabled: list keeps it from running on this instance; tick it again to resume.`),
      el('p', { class: 'meta' }, 'A collection paused by a schedules: value of 0 (the instance\'s or the file\'s) shows unticked too: it resumes when that value goes. One that never ran here is not listed: take it out of disabled: by hand.'),
      rows.length ? el('div', { class: 'grid-wrap', tabindex: '0' }, t) : el('p', { class: 'empty' }, 'No collection has stored a read for this instance yet.'),
      snip, mergeNote(), restartNote());
  }, e => body.replaceChildren(errorBox(e)));
}

function configureSchedule(id: number, back: HTMLElement | null) {
  const { body } = dialog('Configure Schedule', back, true);
  body.append(el('p', { class: 'meta', role: 'status' }, 'Reading the instance\'s collections...'));
  void collectionsOf(id).then(d => {
    // the running collections, and the opt-in ones (off until a schedule gives them an interval: here is where they get one)
    const rows = rowsOf(d.collections).filter(r => r.interval_s == null || Number(r.interval_s) > 0 || (r.default_s != null && Number(r.default_s) === 0));
    const want = new Map<string, string>();
    const lines = () => [`# pgvigil.yaml, the instance ${d.instance}:`, 'instances:', `  - name: ${yamlStr(d.instance)}`,
      ...(want.size ? ['    schedules:', ...[...want.entries()].sort().map(([c, v]) => `      ${c}: ${v}`)] : ['    # schedules: none changed (each collection at its interval)'])].join('\n');
    const snip = snippet(lines);
    const t = el('table', { class: 'grid' }, el('thead', {}, el('tr', {}, ...['Collection', 'Every now', 'Last read', 'Took', 'New interval'].map(h => el('th', { scope: 'col' }, h)))),
      el('tbody', {}, ...rows.map(r => {
        const c = String(r.collection);
        const inp = el('input', { type: 'text', size: '6', placeholder: Number(r.interval_s) > 0 ? goDuration(Number(r.interval_s)) : '1h', 'aria-label': `new interval of ${c} (1m, 15m, 1h)` }) as HTMLInputElement;
        inp.addEventListener('input', () => {
          const v = inp.value.trim();
          // a minute or more (0 would stop the collection: that is Pause/Resume's), at most Go's longest duration
          const m = /^(\d{1,10})(s|m|h)$/.exec(v);
          const secs = m ? Number(m[1]) * ({ s: 1, m: 60, h: 3600 } as Record<string, number>)[m[2]] : NaN;
          const okv = Number.isFinite(secs) && secs >= 60 && secs <= 2562047 * 3600;
          inp.setCustomValidity(v === '' || okv ? '' : 'a whole number of s, m or h from a minute (60s, 15m, 1h)');
          if (v && okv) want.set(c, v); else want.delete(c);
          redraw(snip);
        });
        const optOff = r.default_s != null && Number(r.default_s) === 0 && !(Number(r.interval_s ?? 0) > 0);
        return el('tr', {}, el('td', {}, c), el('td', {}, optOff ? 'opt-in: off' : every(r.interval_s)), el('td', {}, fmtTime(r.snapshot_at)),
          el('td', { class: 'num' }, r.duration_ms != null ? `${fmtNum(r.duration_ms)} ms` : ''), el('td', {}, inp));
      })));
    body.replaceChildren(el('p', {}, `How often each collection of ${d.instance} runs. A new interval goes in the config's schedules: for this instance.`),
      rows.length ? el('div', { class: 'grid-wrap', tabindex: '0' }, t) : el('p', { class: 'empty' }, 'No running collection has stored a read for this instance yet.'),
      snip, mergeNote(), restartNote());
  }, e => body.replaceChildren(errorBox(e)));
}

function connectionOptions(id: number, back: HTMLElement | null) {
  const { body } = dialog('Connection Options', back, true);
  void instanceRow(id).then(r => {
    if (!r) { body.append(el('p', {}, `No instance ${id} in the fleet read.`)); return; }
    const name = String(r.name), engine = isMssql(r.engine) ? 'sqlserver' : 'postgres';
    const tg = Array.isArray(r.tags) ? (r.tags as unknown[]).map(String) : [];
    const lines = () => ['instances:', `  - name: ${yamlStr(name)}`, ...(engine === 'sqlserver' ? ['    engine: sqlserver'] : []),
      ...(r.platform ? [`    platform: ${String(r.platform)}`] : []), '    dsn: env:<the variable it reads now>   # the server never shows a connection string',
      ...(tg.length ? [`    tags: [${tg.map(yamlStr).join(', ')}]`] : [])].join('\n');
    body.append(props([['name', name], ['engine', engine === 'sqlserver' ? 'SQL Server' : 'PostgreSQL'], ['platform', String(r.platform ?? '')],
      ['version', String(r.server_version ?? '')], ['tags', tg.join(', ') || '(none)']]),
    el('p', {}, 'Its line in pgvigil.yaml (the connection string is read from the environment or a file it names, so it is not shown here):'),
    snippet(lines), mergeNote(), restartNote());
  });
}

// Add Alert Blackout: the acknowledgement store's blackout of one instance (a start and an end; its alerts held, still
// logged, flagged blackout), through the same dialog the Alerts page's Blackout button opens
function addBlackout(id: number, back: HTMLElement | null) {
  void Promise.all([instanceRow(id), loadAckSafe(['acks'])]).then(([r, ad]) => {
    const name = String(r?.name ?? `instance ${id}`);
    const why = ackWhy(ad, id, name);
    if (why) {
      const { body } = dialog('Add Alert Blackout', back);
      body.append(el('p', {}, badge('read only', 'warn'), ' ', why));
      return;
    }
    ackDialog({ title: `Blackout '${name}'`, what: 'From the start to the end the server\'s alerts are held (still logged) and flagged blackout.',
      body: { kind: 'blackout', instance_id: id }, expiry: false, blackout: true, noteField: 'optional', after: () => { /* the Alerts page lists it */ } });
  });
}

// ---- a job: Execute Job, thresholds ---------------------------------------------------------------------------

function executeJob(n: Extract<TNode, { kind: 'job' }>, back: HTMLElement | null) {
  const { body } = dialog(`Execute Job - ${n.name}`, back);
  const ctx: Ctx = { ...ctxNow(), instance: n.id };
  const status = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' }, 'Reading the job...');
  body.append(status);
  const draw = async () => {
    let st: Awaited<ReturnType<typeof runningState>>, jobs: Row[];
    try {
      [st, jobs] = await Promise.all([runningState(n.id), get<Record<'jobs', Table | null>>('jobs', { instance: n.id, part: 'jobs' }).then(d => rowsOf(d.jobs))]);
    } catch (e) { body.replaceChildren(errorBox(e)); return; }
    const job = jobs.find(r => String(r.job_id) === n.job && String(r.scheduler) === n.scheduler) ?? { job_id: n.job, scheduler: n.scheduler, job_name: n.name };
    const run = rowsOf(st.running).find(r => String(r.job_id) === n.job && String(r.scheduler) === n.scheduler);
    const start = el('button', { type: 'button' }, 'Start'), stop = el('button', { type: 'button' }, 'Stop');
    // an off Start or Stop: aria-disabled, described by the popup's own line that says why (offP, below the buttons)
    const offP = el('p', { class: 'meta' });
    const why = (b: HTMLButtonElement, reason: string) => { offControl(b, reason, offP); b.classList.add('tm-off'); };
    const startWhy = n.scheduler !== 'pgagent' ? 'pg_cron runs a job at its schedule only: it has no run-now call'
      : job.active === false ? 'the job is disabled: pgAgent runs no disabled job' : !st.actions?.job_start?.on ? (st.actions?.job_start?.reason || 'job actions are off for this instance') : '';
    const stopWhy = !run ? 'the job is not running at the newest read' : !st.actions?.job_stop?.on ? (st.actions?.job_stop?.reason || 'job actions are off for this instance') : '';
    const after = () => { status.textContent = 'Sent. Reading the job again...'; void draw(); };
    if (startWhy) why(start, startWhy); else start.addEventListener('click', () => { void confirmJobAction(ctx, 'job_start', { ...job, job_name: job.job_name ?? n.name }, after); });
    if (stopWhy) why(stop, stopWhy); else stop.addEventListener('click', () => { void confirmJobAction(ctx, 'job_stop', { ...run!, job_name: run!.job_name ?? n.name }, after); });
    body.replaceChildren(
      props([['Job Name', el('a', { href: n.el.getAttribute('href') ?? '#' }, n.name)], ['Scheduler', n.scheduler], ['Enabled', job.active === false ? 'No' : 'Yes'],
        ['Last run', `${fmtTime(job.last_start)}${job.last_status ? ' (' + String(job.last_status) + ')' : ''}`],
        ['Running now', run ? `since ${fmtTime(run.start_time)}, ${fmtSecs(run.running_secs)}${run.current_step ? ', step ' + String(run.current_step) : ''}` : 'no']]),
      el('p', {}, start, ' ', stop),
      (offP.replaceChildren(startWhy ? `Start: ${startWhy}. ` : '', stopWhy ? `Stop: ${stopWhy}.` : ''), offP),
      status);
    status.textContent = '';
  };
  void draw();
}

async function jobThresholds(n: Extract<TNode, { kind: 'job' }>, back: HTMLElement | null) {
  const th = await loadThresholds(n.id);
  if (!th) {
    const { body } = dialog(`Job thresholds: ${n.name}`, back);
    body.append(el('p', {}, 'This server has no job thresholds (an older repository, or the demo).'));
    return;
  }
  thresholdsDialog(n.id, n.name, th, () => refreshAll(`i${n.id}/jobs`));
}

// ---- a folder's filter (Jobs, Databases) -------------------------------------------------------------------------

const filters = new Map<string, string>();   // the folder's caret key -> the part of a name its children must hold
function folderFilter(n: Extract<TNode, { kind: 'folder' }>, back: HTMLElement | null) {
  const { dlg, body } = dialog('Filter', back);
  const input = el('input', { type: 'search', id: 'tm-filter', value: filters.get(n.key) ?? '', autocomplete: 'off' }) as HTMLInputElement;
  const form = el('form', {}, el('label', { for: 'tm-filter' }, `Show the ${n.what === 'jobs' ? 'jobs' : 'databases'} whose name holds `), input, ' ', el('button', { type: 'submit' }, 'OK'));
  body.append(form, el('p', { class: 'meta' }, 'Empty shows them all. The filter holds while this page is open.'));
  input.focus();
  form.addEventListener('submit', ev => {
    ev.preventDefault();
    const v = input.value.trim();
    if (v) filters.set(n.key, v); else filters.delete(n.key);
    // the folder opens to show its children filtered
    const caret = document.querySelector<HTMLButtonElement>(`#tree button.caret[data-key="${CSS.escape(n.key)}"]`);
    if (caret && caret.getAttribute('aria-expanded') !== 'true') caret.click();
    applyFilters();
    dlg.close();
  });
}
// applyFilters: each filtered folder's children shown or hidden by name, and a line under its head that says so
function applyFilters() {
  for (const [key, f] of filters) {
    const caret = document.querySelector<HTMLElement>(`#tree button.caret[data-key="${CSS.escape(key)}"]`);
    const box = caret?.closest('.tree-node')?.parentElement;
    if (!box) continue;
    const kids = [...box.children].slice(1) as HTMLElement[];
    let shown = 0, all = 0;
    for (const k of kids) {
      if (k.classList.contains('tm-filtered')) continue;
      const name = k.querySelector('a, .folder-name');
      if (!name || k.tagName === 'P' || /^all \d+ /.test(name.textContent ?? '')) continue;
      all++;
      const hit = (name.textContent ?? '').toLowerCase().includes(f.toLowerCase());
      k.hidden = !hit;
      if (hit) shown++;
    }
    let line = box.querySelector<HTMLElement>(':scope > .tm-filtered');
    if (!line) {
      const clear = el('button', { type: 'button', class: 'link' }, 'Clear');
      clear.addEventListener('click', () => { filters.delete(key); line?.remove(); kids.forEach(k => { k.hidden = false; }); caret?.focus(); });
      line = el('p', { class: 'meta tm-filtered', style: 'padding:.1rem .4rem;margin:0', role: 'status' }, el('span'), ' ', clear);
      box.insertBefore(line, box.children[1] ?? null);
    }
    // 'all N jobs...': the tree draws the first jobs only; the Jobs tab lists them all
    const more = kids.map(k => /^all (\d+) /.exec(k.querySelector('a')?.textContent ?? '')).find(Boolean);
    const words = `Filter "${f}": ${shown} of ${all}${more ? ` drawn here (the first ${all} of ${more[1]}: the tab lists them all)` : ''}.`;
    const span = line.firstChild as HTMLElement;
    if (span.textContent !== words) span.textContent = words;   // an equal text is not set again: no mutation, no loop
  }
}

// ---- the drive nodes under an instance's Storage folder (A22) ---------------------------------------------------------

interface Vol { at: number; rows?: Row[]; err?: string; pending?: boolean }
const vols = new Map<number, Vol>();
const VOL_TTL = 600000;
// driveNodes: one node per volume of the instance, its used share as a bar beside its name and its free space after
// it, a link to the instance's Storage tab. Read once per 10 minutes (the volume collections run every few minutes);
// redraw is the tree's own draw, called when the read arrives.
export function driveNodes(ctx: Ctx, id: number, engine: unknown, depth: number, redrawTree: () => void): HTMLElement[] {
  let v = vols.get(id);
  const ms = isMssql(engine);
  if (!v || (!v.pending && Date.now() - v.at > (v.err ? 30000 : VOL_TTL))) {
    v = { at: Date.now(), pending: true, rows: v?.rows };
    vols.set(id, v);
    get<Record<'volumes', Table | null>>(ms ? 'mssql/storage' : 'storage', { instance: id, part: 'volumes' })
      .then(d => { vols.set(id, { at: Date.now(), rows: rowsOf(d.volumes) }); redrawTree(); },
        e => { vols.set(id, { at: Date.now(), err: e instanceof Error ? e.message : String(e) }); redrawTree(); });
  }
  const style = `margin-left:${(depth * 0.8).toFixed(1)}rem`;
  if (v.err) return [el('p', { class: 'error', style: 'padding:.1rem .4rem;' + style }, 'Drives: ' + v.err)];
  if (!v.rows) return [el('p', { class: 'empty', style: 'padding:.1rem .4rem;' + style }, 'Reading the drives...')];
  const tab = ms ? 'mssqlstorage' : 'storage';
  return v.rows.filter(r => Number(r.total_bytes) > 0).map(r => {
    const total = Number(r.total_bytes);
    const free = r.free_bytes != null ? Number(r.free_bytes) : r.used_bytes != null ? total - Number(r.used_bytes) : NaN;
    const name = String(r.logical_name ? `${String(r.logical_name)} (${String(r.volume)})` : r.volume ?? '');
    const to = href(ctx, { tab, instance: id, tag: undefined, at: undefined, task: undefined, taskInstance: undefined });
    // the link's visible words are its whole name (WCAG 2.5.3); the bar beside them is a picture of the same figure
    if (!Number.isFinite(free)) {
      return el('div', { style, class: 'tm-drive', 'data-volume': String(r.volume ?? '') },
        el('a', { class: 'inst', href: to, title: `${name}: ${fmtBytes(total)}, free space not read` }, el('span', { class: 'tm-bar none', 'aria-hidden': 'true' }), ` ${name} free not known`));
    }
    const used = Math.max(0, Math.min(100, (total - free) / total * 100)), freePct = 100 - used;
    const lvl = freePct < 10 ? 'crit' : freePct < 20 ? 'warn' : 'ok';
    const pct = fmtNum(Math.round(freePct * 10) / 10);
    return el('div', { style, class: 'tm-drive', 'data-volume': String(r.volume ?? '') },
      el('a', { class: 'inst', href: to, title: `${name}: ${fmtBytes(free)} free of ${fmtBytes(total)} (${pct} % free)` },
        el('span', { class: `tm-bar ${lvl}`, 'aria-hidden': 'true' }, el('span', { style: `width:${used.toFixed(1)}%` })),
        ` ${name} ${fmtBytes(free)} free (${pct} %)`));
  });
}

// ---- the menus of each node ---------------------------------------------------------------------------------------

function itemsFor(n: TNode): MenuItem[] {
  const back = n.el;
  switch (n.kind) {
    case 'root':
      return [
        { label: 'Refresh', act: () => refreshAll() },
        { label: 'Add Connections...', act: () => addConnections(back) },
        { label: 'Find Database', act: () => findDatabase(back) },
        ...newTab(n.el),
      ];
    case 'instance':
      return [
        { label: 'Find Database', act: () => findDatabase(back, n.id) },
        { label: 'Refresh', act: () => refreshAll(`i${n.id}`) },
        { label: 'Instance Actions', sub: [
          { label: 'Pause/Resume Collections...', act: () => pauseResume(n.id, back) },
          { label: 'Configure Schedule...', act: () => configureSchedule(n.id, back) },
          { label: 'Connection Options...', act: () => connectionOptions(n.id, back) },
          { label: 'Add Alert Blackout...', act: () => addBlackout(n.id, back) },
        ] },
        ...newTab(n.el),
      ];
    case 'folder':
      return [
        { label: 'Filter', act: () => folderFilter(n, back) },
        { label: 'Refresh', act: () => refreshAll(n.key) },
        ...newTab(n.el),
      ];
    case 'job':
      return [
        { label: 'Job Info', act: () => { location.hash = (n.el.getAttribute('href') ?? '').replace(/^#/, ''); } },
        { label: 'Configure Thresholds', act: () => { void jobThresholds(n, back); } },
        { label: 'Start/Stop Job', act: () => executeJob(n, back) },
        { sep: true, label: '' },
        { label: 'Refresh', act: () => refreshAll(`i${n.id}/jobs`) },
        ...newTab(n.el),
      ];
  }
}
const menuLabel: Record<TNode['kind'], string> = { root: 'All instances', instance: 'Instance', folder: 'Folder', job: 'Job' };

function openFor(n: TNode, x: number, y: number) {
  showTreeMenu(x, y, itemsFor(n), n.el, `${menuLabel[n.kind]} menu`);
}

// ---- the grids' cell menu (B16, E104) -------------------------------------------------------------------------------

type GItem = [string, () => void];
interface GridMenu { table?: HTMLTableElement; td?: Element | null; items?: GItem[] }

const heads = (t: HTMLTableElement) => [...t.querySelectorAll<HTMLTableCellElement>(':scope > thead > tr:first-child > th')];
const dataRows = (t: HTMLTableElement) => [...t.querySelectorAll<HTMLTableRowElement>(':scope > tbody > tr')].filter(tr => !tr.classList.contains('trend-row'));
const headText = (th: Element) => { const c = th.cloneNode(true) as Element; c.querySelectorAll('.whatis, .filter-btn').forEach(b => b.remove()); return cellText(c); };

interface Num { n: number; kind: string }
// numberAt: a cell's number in its unit's base, as the grid tools read it (the page model's raw value, else a number
// column's text); undefined = not a number
function numberAt(t: HTMLTableElement, td: Element, raw: unknown): Num | undefined {
  const text = cellText(td);
  if (text === '') return undefined;
  const j = [...td.parentElement!.children].indexOf(td);
  const numCol = !!heads(t)[j]?.classList.contains('num');
  // a text column whose values look like numbers (a version '17.10', a code '0042') is no number: summed only a number
  // column, or a value the page holds as a number
  if (!numCol && typeof raw !== 'number') return undefined;
  const c: Pick<Cell, 'v' | 'kind'> | undefined = raw !== undefined ? typed(raw, text) : numCol ? fromText(text) : undefined;
  if (!c || typeof c.v !== 'number' || c.kind === 'date') return undefined;
  return { n: c.kind === 'secs' ? c.v * 86400 : c.kind === 'pct' ? c.v * 100 : c.v, kind: c.kind === 'nsecs' ? 'secs' : c.kind === 'dec' ? 'int' : c.kind };
}
const round2 = (n: number) => Math.round(n * 100) / 100;
function shown(n: number, kind: string): string {
  if (kind === 'bytes') return fmtBytes(Math.round(n));
  if (kind === 'secs') return Math.abs(n) < 60 ? `${fmtNum(round2(n))} s` : fmtSecs(n);
  if (kind === 'msecs') return `${fmtNum(round2(n))} ms`;
  if (kind === 'pct') return `${fmtNum(round2(n))} %`;
  return fmtNum(round2(n));
}
// statsLine: 'Sum: x | Avg: y | Min: z | Max: w' of numbers of one unit; '' when none, a note for mixed units
function statsLine(ns: Num[]): string {
  if (!ns.length) return '';
  if (new Set(ns.map(x => x.kind)).size > 1) return 'numbers in different units: no sum';
  const k = ns[0].kind, v = ns.map(x => x.n), sum = v.reduce((a, b) => a + b, 0);
  return `Sum: ${shown(sum, k)} | Avg: ${shown(sum / v.length, k)} | Min: ${shown(Math.min(...v), k)} | Max: ${shown(Math.max(...v), k)}`;
}
function rawOf(t: HTMLTableElement, tr: HTMLTableRowElement, j: number): unknown {
  const m = gridModel(t), rows = dataRows(t), data = m?.rows();
  if (!m || !data || m.cols.length !== heads(t).length) return undefined;
  const i = rows.indexOf(tr);
  return i >= 0 ? data[i]?.[m.cols[j].key] : undefined;
}

// a selection made through the grid tools' own clicks (Ctrl+click toggles a cell, Shift extends a rectangle), so their
// line above the grid follows it
const click = (td: Element, o: MouseEventInit) => td.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, ...o }));
function selectCells(t: HTMLTableElement, from: Element | undefined, to: Element | undefined) {
  if (!from || !to) return;
  const any = t.querySelector(':scope > tbody > tr > td.gt-sel');
  if (any) click(any, {});   // a plain click clears the tools' selection
  click(from, { ctrlKey: true });
  if (from !== to) click(to, { ctrlKey: true, shiftKey: true });
}
function lastVisible(tr: HTMLTableRowElement, hs: HTMLTableCellElement[]): Element | undefined {
  for (let j = tr.children.length - 1; j >= 0; j--) if (!hs[j]?.hasAttribute('data-gt-hidden')) return tr.children[j];
  return undefined;
}
function firstVisible(tr: HTMLTableRowElement, hs: HTMLTableCellElement[]): Element | undefined {
  for (let j = 0; j < tr.children.length; j++) if (!hs[j]?.hasAttribute('data-gt-hidden')) return tr.children[j];
  return undefined;
}

// everyRow: every row the grid's filters leave, past its drawn page too (the page model builds the undrawn ones off the
// screen, as Copy all and the export do), with each row's raw values when the model matches the columns
function everyRow(t: HTMLTableElement): { trs: HTMLTableRowElement[]; raws?: Record<string, unknown>[]; keys?: string[] } {
  const m = gridModel(t);
  if (m?.allRows && m.cols.length === heads(t).length) return { trs: m.allRows(), raws: m.rows(), keys: m.cols.map(c => c.key) };
  return { trs: dataRows(t) };
}

function setFilter(t: HTMLTableElement, j: number, v: string) {
  const row = t.querySelector<HTMLTableRowElement>(':scope > thead > tr.filters');
  const inp = row?.querySelectorAll<HTMLInputElement>('input')[j];
  if (!row || !inp) return;
  if (row.hidden) heads(t)[j]?.querySelector<HTMLButtonElement>('.filter-btn')?.click();
  inp.value = v;
  inp.dispatchEvent(new Event('input'));
}

function gridItems(t: HTMLTableElement, td: Element | null): GItem[] {
  const hs = heads(t), rows = dataRows(t);
  const total = Number(t.dataset.rows ?? rows.length);
  const out: GItem[] = [];
  const j = td ? [...td.parentElement!.children].indexOf(td) : -1;
  if (td && j >= 0) {
    const tr = td.parentElement as HTMLTableRowElement;
    out.push(['Select row', () => selectCells(t, firstVisible(tr, hs), lastVisible(tr, hs))]);
    // the selection is of the cells drawn: a grid past its page says how many that is
    out.push([rows.length < total ? `Select column (the ${fmtNum(rows.length)} drawn)` : 'Select column', () => selectCells(t, rows[0]?.children[j], rows[rows.length - 1]?.children[j])]);
    const v = cellText(td), short = v.length > 30 ? v.slice(0, 30) + '...' : v;
    if (t.querySelector(':scope > thead > tr.filters') && v) {
      // a number column compares the value as shown ('=' in the grid's filter: units included); a text column's filter is
      // a part of the words, and the item says so
      const num = !!hs[j]?.classList.contains('num');
      out.push([num ? `Filter by value: ${short}` : `Filter by value (contains): ${short}`, () => setFilter(t, j, num ? '=' + v : v)]);
      out.push(['Exclude value (contains)', () => setFilter(t, j, '!' + v)]);
    }
  }
  if (rows.length) out.push([rows.length < total ? `Select all (the ${fmtNum(rows.length)} rows drawn)` : 'Select all', () => {
    const first = rows[0] ? firstVisible(rows[0], hs) : undefined, last = rows[rows.length - 1] ? lastVisible(rows[rows.length - 1], hs) : undefined;
    selectCells(t, first, last);
  }]);
  const filtered = [...t.querySelectorAll<HTMLInputElement>(':scope > thead > tr.filters input')].some(i => i.value.trim() !== '');
  if (filtered) out.push(['Clear filters', () => { t.querySelectorAll<HTMLInputElement>(':scope > thead > tr.filters input').forEach((i, k) => { if (i.value) setFilter(t, k, ''); }); }]);
  // the statistics: the selection's when there is one, else the clicked cell's column over the rows drawn
  const visibleCols = hs.filter(h => !h.hasAttribute('data-gt-hidden')).length;
  const dims = `Rows: ${fmtNum(total)} | Cols: ${fmtNum(visibleCols)}`;
  out.push([dims, () => { void copyText(dims); }]);
  const sel = [...t.querySelectorAll<HTMLTableCellElement>(':scope > tbody > tr > td.gt-sel')];
  let line = '';
  if (sel.length > 1) {
    const nums = sel.map(c => numberAt(t, c, rawOf(t, c.parentElement as HTMLTableRowElement, [...c.parentElement!.children].indexOf(c)))).filter((x): x is Num => !!x);
    const s = statsLine(nums);
    line = `Selected Cells: ${fmtNum(sel.length)} (${fmtNum(nums.length)} numeric)${s ? ' | ' + s : ''}`;
  } else if (td && j >= 0) {
    // the clicked column over every row the filters leave, drawn or not (the 'Rows' figure above counts the same rows)
    const all = everyRow(t);
    const nums = all.trs.map((tr, i) => tr.children[j] ? numberAt(t, tr.children[j], all.raws && all.keys ? all.raws[i]?.[all.keys[j]] : undefined) : undefined).filter((x): x is Num => !!x);
    const s = statsLine(nums);
    if (s) line = `[${headText(hs[j]) || 'column ' + (j + 1)}] ${s}`;
  }
  if (line) out.push([line, () => { void copyText(line); }]);
  return out;
}

// ---- starting -----------------------------------------------------------------------------------------------------

const css = '.tm-menu{min-width:14rem}.tm-menu button{display:flex;justify-content:space-between;gap:1.5rem;width:100%;text-align:left}'
  + '.tm-menu .tm-arrow{opacity:.7}.tm-menu .tm-off{opacity:.55;cursor:not-allowed}.tm-sep{border-top:1px solid var(--line);margin:.2rem 0}'
  + '.tm-bar{display:inline-block;vertical-align:middle;width:3.2rem;height:.7rem;border:1px solid var(--line);background:var(--bg);margin-right:.2rem}'
  + '.tm-bar.none{border-style:dashed}.tm-bar>span{display:block;height:100%;background:var(--ok,#006638)}.tm-bar.warn>span{background:var(--warn,#e49325)}.tm-bar.crit>span{background:var(--crit,#ab1f26)}'
  + '.tm-dialog table.grid td,.tm-dialog table.grid th{padding:.15rem .5rem}.tm-yaml{background:var(--card);border:1px solid var(--line);padding:.4rem .6rem}'
  + '.tm-drive a.inst{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;display:block}';

let installed = false;
// installTreeMenu: once per page load (main.ts). The tree's right-click, its context-menu key and Shift+F10 open the
// node's menu; the grids' cell menus gain their lines; a filtered tree folder stays filtered through the tree's draws.
export function installTreeMenu() {
  if (installed || typeof document === 'undefined') return;
  installed = true;
  document.head.append(el('style', { id: 'tm-style' }, css));
  const at = (n: TNode, e?: MouseEvent) => {
    const r = n.el.getBoundingClientRect();
    return e && (e.clientX || e.clientY) ? [e.clientX, e.clientY] : [r.left + 12, r.bottom];
  };
  document.addEventListener('contextmenu', e => {
    // on the open menu itself (the context-menu key's keyup on Windows lands where the focus went: the menu): no second
    // menu and no browser menu over it
    if (open && open.boxes.some(b => b.contains(e.target as Node))) { e.preventDefault(); return; }
    const n = nodeOf(e.target as Element);
    if (!n) return;
    e.preventDefault();
    const [x, y] = at(n, e);
    openFor(n, x, y);
  });
  document.addEventListener('keydown', e => {
    if (!(e.key === 'ContextMenu' || (e.key === 'F10' && e.shiftKey))) return;
    const n = nodeOf(document.activeElement ?? document.body);
    if (!n) return;
    e.preventDefault();
    const [x, y] = at(n);
    openFor(n, x, y);
  });
  document.addEventListener('mousedown', e => { if (open && !open.boxes.some(b => b.contains(e.target as Node))) closeAll(false); });
  document.addEventListener('focusin', e => { if (open && !open.boxes.some(b => b.contains(e.target as Node))) closeAll(false); });
  window.addEventListener('hashchange', () => closeAll(false));
  // on window: the event reaches it after the grid tools' document listener, so these lines end the menu as DBA Dash's do
  window.addEventListener('pgvigil:gridmenu', e => {
    const d = (e as CustomEvent<GridMenu>).detail;
    if (d?.table && Array.isArray(d.items)) d.items.push(...gridItems(d.table, d.td ?? null));
  });
  const tree = document.getElementById('tree');
  if (tree) new MutationObserver(ms => {
    if (!filters.size) return;
    // the filter's own line (added, or its words changed) is no draw of the tree
    const own = (m: MutationRecord) => (m.target instanceof Element && !!m.target.closest('.tm-filtered'))
      || [...m.addedNodes].every(x => x instanceof Element && x.classList.contains('tm-filtered'));
    if (ms.every(own)) return;
    applyFilters();
  }).observe(tree, { childList: true, subtree: true });
}
