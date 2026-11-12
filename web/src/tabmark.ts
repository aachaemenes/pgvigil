// The tab icon (task 191): mark E with its iris in the fleet's worst state - ok, warning or critical - by the same
// roll-up as the tree's 'All instances' dot (the worst cell of every instance); the plain mark (favicon.svg) while no
// state is known: before the first fleet read, after a failed one, on the sign-in form, an empty fleet, or a fleet where
// no collection has run yet and no cell is a warning or worse (a PostgreSQL check group with no row reads level 0
// without a 'none' flag, so a fresh fleet would read OK: the tree's dot says OK there, the tab says nothing).
// main.ts calls it after each fleet read and from the sign-in form, and starts watchHiddenTab once.
import { LoginRequired } from './api';
import { cells, Fleet, fleet, Level } from './fleet';

// mark E's -ok / -warn / -crit irises
const iris = ['#16a34a', '#d97706', '#dc2626'];
const stateName = ['ok', 'warn', 'crit'];

// e-eye-16 (favicon.svg): the drawing made for 16 px, its iris coloured
const mark = (c: string) => '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16" shape-rendering="geometricPrecision">'
  + '<rect x="0" y="0" width="16" height="16" rx="3.5" fill="#0f766e"/>'
  + '<path d="M1 8 C 3.6 3.4, 12.4 3.4, 15 8 C 12.4 12.6, 3.6 12.6, 1 8 Z" fill="#ffffff"/>'
  + `<circle cx="8" cy="8" r="3.4" fill="${c}"/><circle cx="8" cy="8" r="1.5" fill="#0b1f2a"/></svg>`;

let shown: Level | null | undefined;

// fleetState: the worst level over every instance's cells, or null when nothing has been read: no instance has a
// collection run (the collect part's age; when that read failed, a cell that is not 'none' stands for it) and no cell
// is a warning or worse. Each instance's cells are built once.
function fleetState(f: Fleet): Level | null {
  let lv: Level = 0, known = false;
  for (const r of f.instances) {
    const cs = Object.values(cells(f, r));
    for (const c of cs) lv = Math.max(lv, c.level) as Level;
    known ||= lv > 0 || (f.mssqlFailed ? cs.some(c => !c.none)
      : f.collect.some(c => Number(c.instance_id) === Number(r.instance_id) && c.age_min_secs != null));
  }
  return known ? lv : null;
}

export function tabMark(f: Fleet | null) {
  const link = document.querySelector<HTMLLinkElement>('link[rel="icon"][type="image/svg+xml"]');
  if (!link) return;
  const lv = f ? fleetState(f) : null;
  if (lv === shown) return;   // the same state: the browser keeps the icon it has
  shown = lv;
  link.href = lv == null ? 'favicon.svg' : 'data:image/svg+xml,' + encodeURIComponent(mark(iris[lv]));
  link.dataset.state = lv == null ? 'none' : stateName[lv];
}

// watchHiddenTab: the page's own refresh stops while its tab is hidden, yet a background tab is where the coloured mark is
// read. While hidden, every 60 s, the fleet's status read alone - fleet(true): the instances, the overview checks, the
// versions, the SQL Server summary (the audit read on its own cache) - sets the mark; no page is drawn. It stops when the
// tab shows again (the page's refresh takes over) and on a sign-in (a 401 leaves the plain mark); paused() says when the
// page is in a state where no read may run (main.ts: the sign-in form). A page opened hidden (a background tab, a
// session restore) starts the watch at once: no visibilitychange comes for it.
let hiddenTimer: number | undefined;
export function watchHiddenTab(paused: () => boolean, everyMs = 60000) {
  const stop = () => { window.clearInterval(hiddenTimer); hiddenTimer = undefined; };
  const tick = () => {
    if (!document.hidden || paused()) { stop(); return; }
    fleet(true).then(f => tabMark(f), (e: unknown) => { tabMark(null); if (e instanceof LoginRequired) stop(); });
  };
  const start = () => { if (hiddenTimer === undefined && !paused()) hiddenTimer = window.setInterval(tick, everyMs); };
  document.addEventListener('visibilitychange', () => { if (document.hidden) start(); else stop(); });
  if (document.hidden) start();
}
