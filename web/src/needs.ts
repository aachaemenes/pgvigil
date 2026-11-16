// The session's role as the pages use it (task B24f: viewer, operator, admin). The server is the boundary: every POST
// is registered with its need and refused below it (internal/web/roles.go). The pages only say it first: a write
// control carries its route's need (data-need) and, for a role below it, is off with the server's own refusal words,
// never a dead button. main.ts hands over GET /api/session's answer and the login's reply (setWho). With the login
// off (pgvigil serve -no-login, pgvigil demo -serve) roles do not apply: the route's own words say what holds there.
import { Session } from './api';
import { el, offControl } from './ui';

export type Need = 'operator' | 'admin';
// Can: what the session's role may do as a server answer said it when it was read ('can' beside its own writable /
// reason); where a page holds one it decides, so a role changed since the page was loaded is seen at the next read
export interface Can { operator: boolean; admin: boolean }

// routeNeeds: every write route above viewer as api.post names it, with its need and what it does. The same list as
// internal/web/roles.go's needs (web.go's s.post lines) and routeWhat: roles_test.go TestPageNeedsMatch reads this
// table, one route a line, and fails on any difference.
export const routeNeeds = {
  'indexes/advise': ['operator', 'running the index advisor'],
  'actions/cancel': ['operator', 'cancelling a query'],
  'actions/terminate': ['operator', 'ending a session'],
  'mssql/actions/run': ['operator', 'running an action on a SQL Server instance'],
  'mssql/actions/verify/preview': ['operator', 'reading a backup to verify'],
  'mssql/actions/verify/run': ['operator', 'verifying a backup'],
  'jobs/actions/stop': ['operator', 'stopping a job'],
  'jobs/actions/start': ['operator', 'starting a job'],
  'ack': ['operator', 'acknowledging'],
  'ack/end': ['operator', 'ending an acknowledgement'],
  'alerts/dismiss': ['operator', 'dismissing an alert'],
  'alerts/mute': ['operator', 'changing a mute rule'],
  'alerts/test': ['operator', 'sending a test alert'],
  'plans/explain': ['operator', 'running EXPLAIN'],
  'plans/analyze': ['operator', 'running EXPLAIN ANALYZE'],
  'plans/hypo': ['operator', 'trying a hypothetical index'],
  'community/run': ['operator', 'running a community tool'],
  'reportmail/send': ['operator', 'sending a report by mail'],
  'reportmail/test': ['operator', 'sending a test report mail'],
  'admin/instances': ['admin', 'changing an instance'],
  'admin/sources': ['admin', 'changing a discovery source'],
  'admin/proposals': ['admin', 'approving or ignoring a proposed instance'],
  'mssql/protection': ['admin', "changing a database's backup thresholds"],
  'admin/dbadash_moves': ['admin', 'moving a DBA Dash instance'],
  'mssql/counteradmin': ['admin', 'changing a SQL Server counter list'],
  'admin/applications': ['admin', 'changing an application'],
  'admin/applications/contacts': ['admin', "changing an application's contacts"],
  'admin/applications/assign': ['admin', 'assigning instances to an application'],
  'admin/applications/routes': ['admin', "changing an application's routes"],
  'admin/applications/import': ['admin', 'importing the applications inventory file'],
  'alertrules': ['admin', 'changing an alert rule'],
  'alertrules/end': ['admin', 'ending an alert rule'],
  'alertwindows': ['operator', 'changing an alert window'],
  'drives/thresholds': ['admin', 'changing a drive threshold'],
  'pg/thresholds': ['admin', 'changing a PostgreSQL threshold'],
  'jobs/thresholds': ['admin', 'changing a job threshold'],
  'pg/backup_dest': ['admin', 'entering where the backups go'],
  'jobs/exclusions': ['admin', 'changing a job exclusion'],
  'mssql/security/config': ['admin', 'changing a SQL Server security setting'],
  'mssql/xecaptures/config': ['admin', 'changing an XE capture setting'],
  'customreports': ['admin', 'changing a custom report'],
  'reportmail': ['admin', 'changing a report mail schedule'],
} as const;
export type WriteRoute = keyof typeof routeNeeds;

let who: Session = { login: false };
// lastCan: the newest 'can' a server answer gave this page (review-18 b24f2 S2 / S3) - a dialog opened from a control
// decides by the same word as the control did, and a session that could not be read is no open door when an answer
// says what the role may do
let lastCan: Can | null = null;
export function setWho(s: Session): void { who = s; lastCan = null; }
const rank: Record<string, number> = { viewer: 1, operator: 2, admin: 3 };

// roleWhy: null when the session may make a change of this need, else why not in the server's words (roles.go
// roleWords). can: a server answer's own word on it (else the newest one this page had), which decides over the role
// this page signed in with; with the login off (-no-login, the demo) every answer says yes (roles.go roleCan).
export function roleWhy(need: Need, what: string, can?: Can | null): string | null {
  if (can) lastCan = can;
  const c = can ?? lastCan;
  const role = who.role ?? '';
  const held = (rank[role] ?? 0) >= rank[need];
  if (c) { if (c[need]) return null; }
  else {
    if (!who.login || !who.user) return null;
    if (who.role_error) return who.role_error;
    if (held) return null;
  }
  if (!who.login || !who.user) return `${what} needs the ${need} role (this page could not read who is signed in: load it again)`;
  if (who.role_error) return who.role_error;
  if (held) return `${what} needs the ${need} role, and ${who.user}'s role changed after this page was loaded: load the page again`;
  return `${what} needs the ${need} role: ${who.user} is ${role === 'viewer' ? 'a' : 'an'} ${role || 'user with no role'} (an admin changes it with 'pgvigil user role ${who.user} ${need}' on the server)`;
}

// routeWhy: roleWhy for a route of the table
export function routeWhy(route: WriteRoute, can?: Can | null): string | null {
  const [need, what] = routeNeeds[route];
  return roleWhy(need, what, can);
}

// roleLine: who is signed in and what the role may do, for the page's header (main.ts draws it at every render). It is
// the one visible sentence a control that is off for the role points at (aria-describedby); the control's own title
// says the exact need in the server's words. null with the login off.
export const ROLE_NOTE_ID = 'role-note';
export function roleLine(): HTMLElement | null {
  if (!who.login || !who.user) return null;
  const role = who.role ?? '';
  const words = who.role_error ? who.role_error
    : role === 'admin' ? ''
    : role === 'operator' ? 'an operator acts on a server and acknowledges; configuration needs the admin role'
    : role === 'viewer' ? 'a viewer reads; a change needs the operator or the admin role'
    : 'no role; a change needs the operator or the admin role';
  return el('span', { class: 'meta', id: ROLE_NOTE_ID }, who.user, ` (${[role, words].filter(Boolean).join(': ')})`);
}

// NeedAt: can - the server answer's word (above); note - the page's own visible sentence that already says the role's
// reason; need / what - a write that needs more than its route does (a fleet-wide or open-ended mute: admin, checked
// in the handler)
export interface NeedAt { can?: Can | null; note?: HTMLElement; need?: Need; what?: string }

// needControl marks a write control with the need of the route it posts to (data-need: the role proof reads every
// one) and, when the session's role is below it, draws it off with the role's words (ui.ts offControl: aria-disabled,
// never the disabled attribute; the words its title and its description). A control already off for the server's own
// reason (no login, no door, the demo, an instance not opted in) keeps that reason: it is the first that holds. The
// description is the page's own sentence when one is given, else the header's role line; inside a dialog (the header
// is behind it) and where no role line stands, a note of its own beside the control once the caller has placed it.
// Returns the control.
export function needControl<T extends HTMLElement>(c: T, route: WriteRoute, at: NeedAt = {}): T {
  const [n, w] = routeNeeds[route];
  const need = at.need ?? n;
  c.dataset.need = need;
  if (c.getAttribute('aria-disabled') === 'true' || (c as unknown as HTMLButtonElement).disabled === true) return c;
  const why = roleWhy(need, at.what ?? w, at.can);
  if (!why) return c;
  if (at.note) { offControl(c, why, at.note); return c; }
  const line = document.getElementById(ROLE_NOTE_ID);
  if (line) offControl(c, why, line);
  const own = line ? null : offControl(c, why);
  queueMicrotask(() => {
    if (!c.parentNode) return;
    if (own) { if (!own.parentNode) c.after(' ', own); return; }
    if (c.closest('dialog')) c.after(' ', offControl(c, why));
  });
  return c;
}

// markNeed: data-need alone, for a control whose off state its own dialog keeps (it folds routeWhy into its reason)
export function markNeed<T extends HTMLElement>(c: T, route: WriteRoute): T {
  c.dataset.need = routeNeeds[route][0];
  return c;
}

// dialogRole: a dialog's go button that keeps its own off state (a typed confirmation, the fields): it carries the
// route's need, and below it is off with the role's words in a note of the dialog's (returned for the caller to
// place), whatever is typed - the dialog's check and its submit leave it off while why is set (review-18 b24f2 B1)
export function dialogRole(go: HTMLElement, route: WriteRoute, can?: Can | null): { why: string | null; note: HTMLElement } {
  markNeed(go, route);
  const why = routeWhy(route, can);
  const note = el('p', { class: 'meta off-reason' }, why ? why + '.' : '');
  if (why) offControl(go, why, note);
  return { why, note };
}

// needWords: the sentence a dialog or a form shows for the write its own Save makes (the Save is marked with
// needControl and points at it): '' when the session may
export function needWords(route: WriteRoute, can?: Can | null): string {
  const why = routeWhy(route, can);
  return why ? why + '.' : '';
}
