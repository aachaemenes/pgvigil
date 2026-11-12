// The tab icon (task 191): mark E with its iris in the fleet's worst state - ok, warning or critical - by the same
// roll-up as the tree's 'All instances' dot; the plain mark (favicon.svg) while no state is known (before the first
// fleet read, after a failed one, an empty fleet). main.ts calls it after each fleet read.
import { Fleet, Level, worst } from './fleet';

// mark E's -ok / -warn / -crit irises
const iris = ['#16a34a', '#d97706', '#dc2626'];
const stateName = ['ok', 'warn', 'crit'];

// e-eye-16 (favicon.svg): the drawing made for 16 px, its iris coloured
const mark = (c: string) => '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16" shape-rendering="geometricPrecision">'
  + '<rect x="0" y="0" width="16" height="16" rx="3.5" fill="#0f766e"/>'
  + '<path d="M1 8 C 3.6 3.4, 12.4 3.4, 15 8 C 12.4 12.6, 3.6 12.6, 1 8 Z" fill="#ffffff"/>'
  + `<circle cx="8" cy="8" r="3.4" fill="${c}"/><circle cx="8" cy="8" r="1.5" fill="#0b1f2a"/></svg>`;

let shown: Level | null | undefined;

export function tabMark(f: Fleet | null) {
  const link = document.querySelector<HTMLLinkElement>('link[rel="icon"][type="image/svg+xml"]');
  if (!link) return;
  const lv = f && f.instances.length ? f.instances.reduce<Level>((a, r) => Math.max(a, worst(f, r)) as Level, 0) : null;
  if (lv === shown) return;   // the same state: the browser keeps the icon it has
  shown = lv;
  link.href = lv == null ? 'favicon.svg' : 'data:image/svg+xml,' + encodeURIComponent(mark(iris[lv]));
  link.dataset.state = lv == null ? 'none' : stateName[lv];
}
