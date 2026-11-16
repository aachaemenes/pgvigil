// Insight cards (B20-3, DBA Dash N49): a result set of exactly two columns InsightSeverity and Insight - the server
// marks it (ResultSet.cards, q_customreports.go markCards) - is drawn as one card per row above the report's grids,
// never as a grid. The insight is text: only [text](url) with an http or https url becomes a link (read through
// new URL(), its words set as text, never HTML); any other [text](url) - javascript:, data:, a relative one - stays
// as its own text. A workbook or a mail of the page carries each card as one line '<severity>: <insight>'
// (export.ts reads the list's data-lines).
import { badge, el } from './ui';

export interface Card { severity: string; insight: string }

const LINK = /\[([^\]]*)\]\(([^)\s]+)\)/g;
const KIND: Record<string, string> = { Critical: 'crit', Warning: 'warn', Info: 'none' };

// insightNodes: the insight's text, its http / https [text](url) links as <a>, everything else as written
export function insightNodes(text: string): (Node | string)[] {
  const out: (Node | string)[] = [];
  let at = 0;
  for (const m of text.matchAll(LINK)) {
    const i = m.index ?? 0;
    let u: URL | null = null;
    try { u = new URL(m[2]); } catch { u = null; }
    if (!u || (u.protocol !== 'http:' && u.protocol !== 'https:')) continue;   // kept as its own text below
    if (i > at) out.push(text.slice(at, i));
    out.push(el('a', { href: u.href, target: '_blank', rel: 'noopener noreferrer' }, m[1] || u.href));
    at = i + m[0].length;
  }
  if (at < text.length) out.push(text.slice(at));
  return out;
}

// cardLine: a card as the workbook's and the mail's text line
export const cardLine = (c: Card): string => `${c.severity}: ${c.insight}`;

// cardList: the cards of one set, in row order (an empty list draws nothing: no rows, no cards)
export function cardList(cards: Card[], label: string): HTMLElement | null {
  if (!cards.length) return null;
  const box = el('div', { class: 'insight-cards', role: 'list', 'aria-label': label, 'data-lines': JSON.stringify(cards.map(cardLine)) });
  for (const c of cards) {
    box.append(el('div', { class: 'insight-card ' + (KIND[c.severity] ?? 'none'), role: 'listitem', 'data-severity': c.severity },
      badge(c.severity, KIND[c.severity] ?? 'none'), ' ', el('span', { class: 'insight-text' }, ...insightNodes(c.insight))));
  }
  return box;
}
