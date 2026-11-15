// Admin > Instances: 'Check all' and 'Rights' (the ServiceConfig takes, ST1 and ST2; DBA Dash's Check Connections with
// its Snapshot Age, and its Permissions Helper's View Script).
//
// Check all tests every instance in view - the ones of pgvigil.yaml too - by the page's own fan-out of the existing
// test (POST /api/admin/instances op 'test'), six at a time: no request is longer than one test, a server that does
// not answer holds one of the six seats, and each row's 'last test' fills as its answer comes. 'Last collected' is an
// age by the repository's clock, with the collection that fails now beside it.
//
// Rights reads, as the instance's own monitoring login, which of the rights pgvigil needs it holds, and prints the
// GRANT script of the missing ones to copy. pgvigil never runs it: there is no button that grants.
//
// The page (admin_instances.ts) owns the tables, the status line and the read-only lock; it hands them in (Deps).
import { Row, rowsOf, Table } from './api';
import { Col, el, fmtTime, grid } from './ui';

type Answer = { ok: boolean; body: Record<string, unknown> };
export interface Deps {
  send: (path: string, data: Record<string, unknown>) => Promise<Answer>;
  say: (text: string, bad?: boolean) => void;
  draw: () => Promise<void>;
  // lock turns a control off where this server cannot write, with the page's reason
  lock: (cell: HTMLElement) => HTMLElement;
  why: (b: Record<string, unknown>) => string;
}

// how many tests run at once
const AT_ONCE = 6;

// ageWords: an age in seconds as DBA Dash's Snapshot Age words, two units at most ('26 seconds', '1 hour 3 minutes')
export function ageWords(v: unknown): string {
  const s = Number(v);
  if (v == null || v === '' || !Number.isFinite(s) || s < 0) return '';
  const unit = (n: number, w: string) => `${n} ${w}${n === 1 ? '' : 's'}`;
  if (s < 120) return unit(Math.floor(s), 'second');
  const m = Math.floor(s / 60);
  if (m < 120) return unit(m, 'minute');
  const h = Math.floor(m / 60);
  if (h < 48) return unit(h, 'hour') + (m % 60 ? ' ' + unit(m % 60, 'minute') : '');
  const d = Math.floor(h / 24);
  return unit(d, 'day') + (h % 24 ? ' ' + unit(h % 24, 'hour') : '');
}

// fanOut runs one task per item, at most limit at a time, in the items' order
export async function fanOut<T>(items: T[], limit: number, run: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const item = items[next++];
      await run(item);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
}

export function instanceChecks(deps: Deps) {
  let checks = new Map<string, Row>();
  const box = el('div', { id: 'admin-instance-rights' });
  let busy = false;

  // the 'last test' cell of an instance: found again by its name while Check all runs
  const testCell = (name: string, text: string, title = ''): HTMLElement =>
    el('span', { 'data-check-name': name, title }, text);
  const lastTest = (name: string): HTMLElement => {
    const c = checks.get(name);
    if (!c || c.tested_at == null) return testCell(name, 'not tested');
    return testCell(name, `${c.tested_ok ? 'connected' : 'failed'} ${fmtTime(c.tested_at)}`, String(c.tested_detail ?? ''));
  };
  const lastCollected = (name: string): HTMLElement | string => {
    const c = checks.get(name);
    if (!c || c.instance_id == null) return 'never collected';
    const failing = Number(c.failing_n ?? 0) > 0
      ? `; ${String(c.failing_n)} failing: ${String(c.failing_collection ?? '')}${c.failing_note ? ' - ' + String(c.failing_note) : ''}` : '';
    if (c.last_collected == null) return `no collection ended ok yet${failing}`;
    return el('span', { title: `last collected ${fmtTime(c.last_collected)}` }, `${ageWords(c.collected_age_s)} ago${failing}`);
  };

  // ---- Rights: the read, the list, the script to copy
  const rightCols: Col[] = [
    { key: 'right_name', label: 'right' },
    { key: 'state', label: 'held', fmt: v => String(v ?? '') },
    { key: 'kind', label: 'needed' },
    { key: 'needed_for', label: 'what needs it', wide: true },
  ];
  async function showRights(name: string): Promise<void> {
    deps.say(`Reading the rights of ${name}'s monitoring login…`);
    const res = await deps.send('admin/instances', { op: 'rights', name });
    if (!res.ok) { deps.say(`Rights of ${name} not read: ${deps.why(res.body)}`, true); return; }
    const b = res.body;
    if (b.ok !== true) {
      box.replaceChildren(el('h3', {}, `Rights: ${name}`), el('p', { class: 'meta' }, `not read: ${String(b.detail ?? '')}`));
      deps.say(`Rights of ${name} not read: ${String(b.detail ?? '')}`, true);
      return;
    }
    const rows = rowsOf(b.rights as Table | null), missing = Number(b.missing ?? 0), needed = Number(b.missing_needed ?? 0), script = String(b.script ?? '');
    const optional = missing - needed;
    const count = (n: number, w: string) => `${n} ${w} right${n === 1 ? '' : 's'}`;
    const lacks = [needed ? count(needed, 'needed') : '', optional ? count(optional, 'optional') : ''].filter(Boolean).join(' and ');
    const kids: (HTMLElement | string)[] = [
      el('h3', { id: 'admin-instance-rights-title' }, `Rights: ${name}`),
      el('p', { class: 'meta' }, `Read just now as the monitoring login ${String(b.login ?? '')} (${String(b.platform ?? '')}). `
        + (missing ? `Missing: ${lacks}. A collection that needs a missing right is skipped and says so; an optional right is one feature's own. `
          : 'Nothing is missing. ')
        + 'pgvigil never grants anything: the script below is printed to copy and to run as an administrator of that server.'),
      grid(rows, rightCols, 'No right is listed for this platform.'),
    ];
    if (script) {
      const pre = el('pre', { id: 'admin-instance-rights-script', tabindex: '0', 'aria-label': `The GRANT script for ${name}` }, script);
      const copy = el('button', { type: 'button', 'aria-label': `Copy the GRANT script for ${name}` }, 'Copy the script');
      copy.addEventListener('click', async () => {
        try { await navigator.clipboard.writeText(script); deps.say(`The GRANT script for ${name} is on the clipboard (${script.split('\n').length} lines). Nothing was run.`); }
        catch { deps.say('The browser refused the clipboard: select the script and copy it by hand.', true); }
      });
      kids.push(el('p', { class: 'meta' }, 'The script of the missing rights (nothing in it was run):'), pre, el('div', {}, copy));
    }
    const close = el('button', { type: 'button', class: 'link', 'aria-label': `Close the rights of ${name}` }, 'Close');
    close.addEventListener('click', () => box.replaceChildren());
    kids.push(el('div', {}, close));
    box.replaceChildren(...kids);
    deps.say(missing ? `${name}: ${lacks} missing; the script is below the tables.` : `${name}: nothing is missing.`, needed > 0);
    box.scrollIntoView({ block: 'nearest' });
  }
  const rightsButton = (name: string): HTMLElement => {
    const b = el('button', { type: 'button', class: 'link', 'aria-label': `Rights of ${name}` }, 'Rights');
    b.addEventListener('click', () => { void showRights(name); });
    return b;
  };

  // ---- one test, as the row's own Test link and as a seat of Check all
  async function testOne(name: string): Promise<'connected' | 'failed' | 'not tested'> {
    const cells = () => document.querySelectorAll(`[data-check-name="${CSS.escape(name)}"]`);
    cells().forEach(c => { c.textContent = 'checking…'; });
    let res: Answer;
    try { res = await deps.send('admin/instances', { op: 'test', name }); }
    catch (e) { res = { ok: false, body: { detail: e instanceof Error ? e.message : String(e) } }; }
    const state = !res.ok ? 'not tested' : res.body.ok ? 'connected' : 'failed';
    const detail = res.ok ? String(res.body.detail ?? '') : deps.why(res.body);
    cells().forEach(c => { c.textContent = state === 'not tested' ? `not tested: ${detail}` : `${state} just now`; (c as HTMLElement).title = detail; });
    return state;
  }

  return {
    // set takes the page's answer at each draw
    set(d: { checks?: Table | null }): void { checks = new Map(rowsOf(d.checks ?? null).map(r => [String(r.name), r])); },
    lastTest, lastCollected, rightsButton,
    // the panel the Rights read fills, placed by the page under its tables
    rightsBox: box,
    // the columns of the file's table: as the page's own table's cells, with a Test and a Rights link
    fileCols(): Col[] {
      return [
        { key: 'name' }, { key: 'engine' }, { key: 'platform' }, { key: 'tags', wide: true },
        { key: 'tested', label: 'last test', fmt: (_v, r) => lastTest(String(r.name)) },
        { key: 'collected', label: 'last collected', fmt: (_v, r) => lastCollected(String(r.name)) },
        { key: 'source' },
        { key: 'actions', fmt: (_v, r) => {
          const n = String(r.name);
          const test = el('button', { type: 'button', class: 'link', 'aria-label': `Test ${n}` }, 'Test');
          test.addEventListener('click', async () => {
            deps.say(`Connecting to ${n}…`);
            const state = await testOne(n);
            await deps.draw();
            deps.say(`${n}: ${state}.`, state !== 'connected');
          });
          return deps.lock(el('span', { class: 'actions' }, test, ' ', rightsButton(n)));
        } },
      ];
    },
    // the Check all button over the instances in view: the page's enabled ones and the file's
    control(page: Row[], file: Row[]): HTMLElement {
      const names = [...page.filter(r => !r.disabled).map(r => String(r.name)), ...file.map(r => String(r.name))];
      const off = page.filter(r => r.disabled).length;
      const b = el('button', { type: 'button', id: 'admin-check-all' }, 'Check all');
      b.addEventListener('click', async () => {
        if (busy) return;
        busy = true;
        b.setAttribute('aria-busy', 'true');
        const n = { connected: 0, failed: 0, 'not tested': 0 };
        let done = 0;
        deps.say(`Checking ${names.length} instance${names.length === 1 ? '' : 's'}, ${AT_ONCE} at a time…`);
        await fanOut(names, AT_ONCE, async name => {
          n[await testOne(name)]++;
          deps.say(`Checking: ${++done} of ${names.length} answered (${n.connected} connected, ${n.failed} failed${n['not tested'] ? `, ${n['not tested']} not tested` : ''})…`);
        });
        busy = false;
        b.removeAttribute('aria-busy');
        await deps.draw();
        deps.say(`Checked ${names.length}: ${n.connected} connected, ${n.failed} failed${n['not tested'] ? `, ${n['not tested']} not tested` : ''}`
          + (off ? `; ${off} disabled, not checked.` : '.'), n.failed + n['not tested'] > 0);
      });
      return el('p', {}, deps.lock(el('span', {}, b)), ' ',
        el('span', { class: 'meta' }, `Tests the connection of every instance in view (${names.length}${off ? `; ${off} disabled, not checked` : ''}), ${AT_ONCE} at a time, as each one's own monitoring login.`));
    },
  };
}
