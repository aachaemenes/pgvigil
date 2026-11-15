// rowjump: a status text whose page is the page it is on answers a click there. On a SQL Server instance's Summary its
// Memory dumps and DB Mail (DBA Dash has no page for either: Checks/Summary.cs tabMapping null) are shown by the Server
// card, so their reasons - in the header, the verdict card and the Not OK line - jump to that card's row: the row is
// scrolled to the top of the view, an outline marks it for 2 s and the focus moves to it, the address unchanged.
// Instance Uptime opens its threshold dialog, as DBA Dash's Uptime cell does. The same reason on another page (the
// fleet Summary's cell and its Needs attention line, another tab of the instance) links to the instance's Summary with
// row=<key> in the address: the Summary jumps to the row once it is drawn and takes row= out of the address.
import { openUptimeDialog } from './uptimedialog';

// the Server card row of each check it holds (mssql_summary.ts props: the row's label)
export const rowLabels: Record<string, string> = { dumps: 'memory dumps', dbmail: 'Database Mail' };

// markRows: the Server card's rows of those checks carry data-row=<key>
export function markRows(card: HTMLElement): void {
  for (const tr of card.querySelectorAll('tr')) {
    const th = tr.querySelector('th')?.textContent?.trim() ?? '';
    const key = Object.keys(rowLabels).find(k => rowLabels[k] === th);
    if (key) tr.setAttribute('data-row', key);
  }
}

// jumpToRow: the row of a check at the top of the view, outlined for 2 s, focused; false when the page has no such row
const flashTimers = new WeakMap<HTMLElement, number>();
export function jumpToRow(key: string): boolean {
  const tr = document.querySelector<HTMLElement>(`main [data-row="${key}"]`);
  if (!tr) return false;
  tr.scrollIntoView({ block: 'start' });
  // a second click within the 2 s: the outline again, for its own 2 s
  window.clearTimeout(flashTimers.get(tr));
  tr.classList.remove('row-flash');
  void tr.offsetWidth;
  tr.classList.add('row-flash');
  flashTimers.set(tr, window.setTimeout(() => tr.classList.remove('row-flash'), 2000));
  if (!tr.hasAttribute('tabindex')) tr.tabIndex = -1;
  tr.focus({ preventScroll: true });
  return true;
}

// ownPageAction: a link to the page it is on, for the check key: Instance Uptime opens its dialog, a check with a
// Server card row jumps to it where the page has that card (rows: a SQL Server instance's Summary - a PostgreSQL
// Server state page holds no such row); true when the link got its action (a click with a modifier keeps the
// address's own way: a new tab opens it). Any other key gets nothing: the caller shows text
export function ownPageAction(a: HTMLAnchorElement, key: string, instanceId: number, rows: boolean): boolean {
  if (key !== 'uptime' && !(rows && rowLabels[key])) return false;
  a.addEventListener('click', e => {
    if (e.button !== 0 || e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) return;
    e.preventDefault();
    if (key === 'uptime') void openUptimeDialog(instanceId);
    else jumpToRow(key);
  });
  if (key === 'uptime') a.setAttribute('aria-haspopup', 'dialog');
  return true;
}

// jumpWhenDrawn: the row the address names (row=<key>), once the page holding it is in the document with its header
// (the header follows the page when its own read ends, and would push the row down; after 5 s without it the jump is
// made anyway), then row= out of the address either way (the page's own redraws never jump)
export function jumpWhenDrawn(page: HTMLElement): void {
  const key = new URLSearchParams(location.hash.split('?')[1] ?? '').get('row');
  if (!key) return;
  const t0 = Date.now();
  const drop = () => {
    const [path, qs] = location.hash.split('?'); const now = new URLSearchParams(qs ?? '');
    if (now.get('row') === key) { now.delete('row'); history.replaceState(null, '', now.toString() ? `${path}?${now}` : path); }
  };
  const tick = () => {
    const late = Date.now() - t0 >= 5000;
    if (page.isConnected && (late || document.querySelector('main > .inst-header'))) { if (rowLabels[key]) jumpToRow(key); drop(); return; }
    if (!late) window.setTimeout(tick, 100);
  };
  window.setTimeout(tick, 0);
}
