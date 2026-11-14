// The verdict card (Allen 11-14: a plain-language verdict per instance; the idea from NexaPG's 'Easy mode', no code or
// text taken): one sentence and the reasons named, on the instance's Summary under its header. It is a READING of the
// header's own band (instheader.ts instBand: the Summary's checks, acknowledgements left out, Offline first) and of
// the header's freshness - never a second judgement: no new check, no new threshold. Four states: OK, Warning,
// Problem (Critical and Offline: the header's badge keeps its own words) and 'pgvigil has not read <name> yet' (no
// collection ever, or no live read answered); a collection that is late (the header's 'Warning' status) is named.
import { Row } from './api';
import { Cell, cellText, groups, labelOf } from './fleet';
import type { BandItem, Freshness, InstBand } from './instheader';
import { Ctx, href } from './router';
import { el } from './ui';

// a group's plain phrase: one for both engines, or PostgreSQL's and SQL Server's; a pair [warning, critical] where the
// level changes the words. No DMV, setting or SQL name (the card's rule): what a reader would say to a colleague.
type Phrase = string | [string, string];
const phrases: Record<string, Phrase | { pg: Phrase; ms: Phrase }> = {
  dumps: { pg: 'the server restarted after a crash', ms: 'the server wrote memory dumps' },
  corruption: 'signs of damaged data were found',
  checkdb: { pg: 'an integrity check of the indexes is overdue', ms: 'a database integrity check is overdue' },
  alerts: 'the server raised alerts of its own',
  full: 'a full backup is overdue',
  diff: 'a differential backup is overdue',
  log: { pg: 'archiving of the write-ahead log is behind or failing', ms: 'a transaction log backup is overdue' },
  disk: ['a drive is filling up', 'a drive is nearly full'],
  jobs: 'a scheduled job failed',
  agent: 'the job scheduler is not running',
  logship: { pg: 'a standby is behind in replaying changes', ms: 'log shipping is behind' },
  mirroring: 'database mirroring is not healthy',
  replication: { pg: 'replication is behind or broken', ms: 'an availability group is not healthy' },
  logspace: 'a transaction log is nearly full',
  filespace: 'a database file is nearly full',
  pctmax: 'a database file is near its maximum size',
  elasticpool: 'the elastic pool is nearly full',
  qs: 'query history is not being kept as set',
  custom: 'a custom check failed',
  errors: 'some collections failed in the last 24 hours',
  snapshot: 'some of its data is out of date',
  dbmail: 'the server cannot send mail',
  identity: 'a table is running out of id values',
  dbstate: 'a database is not in a normal state',
  servicebroker: 'message queuing in the server is not working',
  uptime: 'the server restarted recently',
  activity: 'sessions are blocked, stuck or running long',
  dbhealth: 'deadlocks or checksum failures were seen',
  audit: 'auditing is not set up as expected',
  pgss: 'query statistics are not being collected',
  dms: 'a data migration task is failing or behind',
  tables: 'a table is bloated or growing fast',
  vacuum: 'table cleanup is falling behind',
  host: 'the server\'s host is under pressure',
  io: 'disk reads or writes are slow',
  roles: 'a login or role is set unsafely',
  indexes: 'an index is unused, duplicated or broken',
  version: 'the server\'s version is out of date',
};
export function phraseOf(key: string, level: number, pg: boolean): string {
  const p = phrases[key];
  if (p == null) return `${key} is not OK`;
  const q = typeof p === 'object' && !Array.isArray(p) ? (pg ? p.pg : p.ms) : p;
  return Array.isArray(q) ? q[level >= 2 ? 1 : 0] : q;
}

export type VerdictState = 'ok' | 'warning' | 'problem' | 'unread';
export interface VerdictReason { key: string; phrase: string; level: number; cell?: Cell; target: { tab: string; kind?: string; cv?: string } }
export interface Verdict { state: VerdictState; word: string; sentence: string; reasons: VerdictReason[]; notes: string[]; acked: BandItem[]; notJudged: { key: string; label: string }[] }

const mins = (ms: number) => Math.max(1, Math.round(ms / 60000));

// verdict: ONE function over the header's own band and freshness (instheader.ts instBand, freshness: the caller reads
// them once for both); task 90's role views list one card per instance from it
export function verdict(r: Row, live: Row | undefined, now: number, b: InstBand, fr: Freshness): Verdict {
  const name = String(r.name), pg = r.engine !== 'sqlserver';
  const reasons: VerdictReason[] = b.items.map(i => ({ key: i.key, phrase: phraseOf(i.key, i.level, pg), level: i.level, cell: i.cell, target: i.target }));
  const more = (n: number) => n > 1 ? ` and ${n - 1} more` : '';
  const late = Number(live?.coll_stale ?? 0);
  const notes: string[] = [];
  if (fr === 'stale' && b.level > 0) notes.push(`${late} of pgvigil's collections of it ${late === 1 ? 'is' : 'are'} late.`);
  if (fr === 'awaiting' && b.level > 0) notes.push(live ? 'No collection of it has run yet: these come from older reads.' : 'No live read of it answered: these come from older reads.');
  // the groups the Summary shows as 'no sample' for this instance's engine (never the other engine's 'n/a')
  const notJudged = groups.filter(g => {
    const c = b.cells[g.key];
    return c != null && c.none && c.text !== 'n/a';
  }).map(g => ({ key: g.key, label: labelOf(g, pg) }));
  let state: VerdictState, sentence: string;
  if (b.offline) {
    const at = Date.parse(String(live?.last_collect_at ?? ''));
    state = 'problem';
    sentence = `pgvigil has not read ${name} for ${isNaN(at) ? 'over 30' : mins(now - at)} minutes.`;
    reasons.unshift({ key: 'offline', phrase: 'no collection of it ran well in the last 30 minutes', level: 2, target: { tab: 'collectiondates' } });
  } else if (fr === 'awaiting' && b.level === 0) {
    state = 'unread';
    sentence = live ? `pgvigil has not read ${name} yet.` : `pgvigil has not read ${name} yet: no live read of it answered.`;
  } else if (b.level === 2) {
    state = 'problem';
    sentence = `${name} has a problem: ${reasons[0].phrase}${more(reasons.length)}.`;
  } else if (b.level === 1) {
    state = 'warning';
    sentence = `${name} needs a look: ${reasons[0].phrase}${more(reasons.length)}.`;
  } else if (fr === 'stale') {
    state = 'warning';
    sentence = `${name} needs a look: ${late} of pgvigil's collections of it ${late === 1 ? 'is' : 'are'} late.`;
  } else {
    state = 'ok';
    sentence = `${name} looks healthy: nothing needs attention.`;
  }
  const word = { ok: 'OK', warning: 'Warning', problem: 'Problem', unread: 'Not read yet' }[state];
  return { state, word, sentence, reasons, notes, acked: b.acked, notJudged };
}

const stateCls: Record<VerdictState, string> = { ok: 'ok', warning: 'warn', problem: 'crit', unread: 'none' };

// verdictCard: the card on the instance's Summary (instheader.ts instanceFrame places it under the header)
export function verdictCard(ctx: Ctx, v: Verdict): HTMLElement {
  const to = (t: VerdictReason['target']) => {
    const base = href(ctx, { tab: t.tab, ...(t.kind ? { kind: t.kind } : {}) });
    return t.cv ? `${base}${base.includes('?') ? '&' : '?'}cv=${t.cv}` : base;
  };
  const card = el('section', { class: `verdict-card ${stateCls[v.state]}`, 'data-state': v.state, 'aria-label': `In plain words: ${v.word}` },
    el('div', { class: 'verdict-head' }, el('span', { class: `badge verdict-word ${stateCls[v.state]}` }, v.word), ' ', el('span', { class: 'verdict-sentence' }, v.sentence)));
  if (v.reasons.length) {
    card.append(el('ul', { class: 'verdict-reasons' }, ...v.reasons.map(q => {
      const a = el('a', { href: to(q.target) }, q.phrase);
      if (q.cell?.detail.length) a.title = q.cell.detail.join('\n');
      return el('li', { class: q.level >= 2 ? 'crit' : 'warn', 'data-group': q.key, 'data-phrase': q.phrase }, a, q.cell ? ` (${cellText(q.cell)})` : '');
    })));
  }
  for (const n of v.notes) card.append(el('p', { class: 'meta verdict-note' }, n));
  const list = (cls: string, lead: string, xs: { key: string; label: string }[]) => xs.length
    ? el('p', { class: `meta ${cls}` }, lead, ...xs.flatMap((x, i) => [i ? ', ' : '', el('span', { 'data-group': x.key }, x.label)])) : null;
  const acked = list('verdict-acked', 'Acknowledged, not counted: ', v.acked);
  const nj = list('verdict-notjudged', 'Not judged (no data yet): ', v.notJudged);
  if (acked) card.append(acked);
  if (nj) card.append(nj);
  return card;
}
