// The wording walk's matcher (the pre-publish walk, DONE-1): does a piece of text a reader sees on a page of one engine
// carry a word only the other engine has? Pure functions over strings - the walk (scripts/wording-walk.mjs) reads the
// pages and hands each element here; the click-through hands each dialog it opens. Usage alone:
//   node scripts/wording-match.mjs --self-test      the rules against their fixtures (no browser, no server)
// The rules (notes: the design D1-D2 as folded after its design pass):
//   - the words: scripts/wording-words.txt (engine | word | pattern | source); a word of the other engine is a red
//   - U: the scope's own names (instances, tags, databases, jobs, hosts, logins) are taken out of the text first -
//     they are the user's data, never the UI's words ('aurora' as a tag on a SQL Server page is no red)
//   - a label (th, tab, tree node, heading, button, menu item, tile, legend) is judged as it stands: right or wrong
//     for its page whatever it names; the other engine's NAME in a label is a red too ('PostgreSQL options' on a SQL
//     Server scope)
//   - prose (a paragraph, a list item, a title, a dialog's text, a cell's text) is split into sentences at . ! ?
//     outside parentheses; a sentence that names the word's own engine attributes it (A1: 'SQL Server's Query
//     Store', 'PostgreSQL: the WAL directory ...'); a sentence that names this page's engine with no / not / none /
//     without / never / n/a says it is absent here (A2: 'PostgreSQL has no Query Store')
//   - the allow rows: scripts/wording-allow.txt (page | kind | pattern | reason): a place the other engine's word is
//     right on purpose (A4) or a stated analogy (A5); never a page skipped whole

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ENGINES = ['sqlserver', 'postgres'];
const OTHER = { sqlserver: 'postgres', postgres: 'sqlserver' };
// an engine's own name in text (A1, A2, and the label rule)
const NAME = {
  sqlserver: /\b(SQL Server|Azure SQL|MSSQL)\b/i,
  postgres: /\b(PostgreSQL|Postgres)\b/i,
};
const NEGATION = /\b(no|not|none|without|never|n\/a|isn't|doesn't|does not|has no|have no)\b/i;
export const LABEL_KINDS = new Set(['label', 'th', 'tab', 'tree', 'heading', 'button', 'menuitem', 'tile', 'legend']);
export const PROSE_KINDS = new Set(['prose', 'cell', 'title', 'attr', 'dialog']);

// a row's fields are split at a '|' with a space before it and a space (or the end) after it: a pattern's own
// alternation ('(database|db)') never has a space before its '|'
const rows = (text) => text.split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#')).map(l => l.split(/\s+\|(?=\s|$)/).map(f => f.trim()));

// loadWords: the words file's rows as { engine, word, re, source }
export function loadWords(text) {
  return rows(text).map(([engine, word, pattern, ...src]) => {
    if (!ENGINES.includes(engine)) throw new Error(`words: unknown engine ${engine} (${word})`);
    let re;
    if (!pattern) re = new RegExp(`\\b${word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\s+/g, '\\s+')}\\b`, 'i');
    else if (pattern.startsWith('cs:')) re = new RegExp(pattern.slice(3));
    else re = new RegExp(pattern, 'i');
    return { engine, word, re, source: src.join(' | ') };
  });
}

// loadAllow: the allow file's rows as { page, kind, re, reason }
export function loadAllow(text) {
  return rows(text).map(([page, kind, pattern, ...why]) => ({
    page: page === '*' ? null : new RegExp(page), kind: kind === '*' ? null : kind, re: new RegExp(pattern, 'i'), reason: why.join(' | '),
  }));
}

// stripNames (U): each name of the scope, longest first, without case, replaced by a neutral mark where it stands as a
// whole token (a name inside another word stays: 'erp' in 'erp_audit' is taken as part of that name if it is one)
export function stripNames(text, names) {
  const list = [...new Set((names ?? []).map(n => String(n).trim()).filter(n => n.length >= 2))].sort((a, b) => b.length - a.length);
  let out = text;
  for (const n of list) {
    const esc = n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    out = out.replace(new RegExp(`(^|[^\\w-])${esc}(?=$|[^\\w-])`, 'gi'), '$1‹name›');
  }
  return out;
}

// sentences: split at . ! ? followed by a space or the end, outside parentheses (a version '16.0.4325.4' or 'e.g.'
// inside a sentence stays whole when no space follows the dot)
export function sentences(text) {
  const out = []; let depth = 0, cur = '';
  for (let i = 0; i < text.length; i++) {
    const c = text[i]; cur += c;
    if (c === '(' || c === '[') depth++;
    else if ((c === ')' || c === ']') && depth > 0) depth--;
    else if (depth === 0 && (c === '.' || c === '!' || c === '?') && (i + 1 === text.length || /\s/.test(text[i + 1]))) { out.push(cur.trim()); cur = ''; }
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

const allowed = (allow, page, kind, text) => (allow ?? []).find(a => (!a.page || a.page.test(page)) && (!a.kind || a.kind === kind) && a.re.test(text));

// check: the reds of one element. el = { text, kind, page }, ctx = { engine (the page's), words, allow, names }.
// Returns [{ word, owner, source, sentence, why }] - an empty list when the text is right for the page.
export function check(el, ctx) {
  const { engine } = ctx;
  if (!ENGINES.includes(engine)) throw new Error(`check: the page's engine ${engine}`);
  const other = OTHER[engine];
  const raw = String(el.text ?? '').replace(/\s+/g, ' ').trim();
  if (!raw) return [];
  const a = allowed(ctx.allow, el.page ?? '', el.kind, raw);
  if (a) return [];
  const text = stripNames(raw, ctx.names);
  const reds = [];
  const words = ctx.words.filter(w => w.engine === other);
  if (LABEL_KINDS.has(el.kind)) {
    for (const w of words) if (w.re.test(text)) reds.push({ word: w.word, owner: other, source: w.source, sentence: raw, why: 'a label' });
    if (NAME[other].test(text)) reds.push({ word: text.match(NAME[other])[0], owner: other, source: "the other engine's name in a label", sentence: raw, why: 'a label' });
    return reds;
  }
  for (const s of sentences(text)) {
    if (NAME[other].test(s)) continue;                               // A1: the word's own engine named
    if (NAME[engine].test(s) && NEGATION.test(s)) continue;          // A2: absent on this engine, said
    for (const w of words) if (w.re.test(s)) reds.push({ word: w.word, owner: other, source: w.source, sentence: s, why: 'prose' });
  }
  return reds;
}

// loadExpected: the expected file's rows as { status, scope, page, kind, word, source, fix }
export const SCOPES = ['pg-instance', 'ms-instance', 'pg-tag', 'ms-tag', 'root-pg-row', 'root-ms-row'];
export function loadExpected(text) {
  return rows(text).map(([status, scope, page, kind, word, source, ...fix], i) => {
    if (!['must', 'may', 'must-not'].includes(status) || !SCOPES.includes(scope)) throw new Error(`expected row ${i + 1}: status ${status}, scope ${scope}`);
    return { status, scope, page: new RegExp(page), pageText: page, kind, word, source, fix: fix.join(' | ') };
  });
}

// validateExpected: each row's word is a word of the file or an engine's name (a typo would never match)
export function validateExpected(expected, words) {
  const known = new Set([...words.map(w => w.word), 'SQL Server', 'PostgreSQL']);
  return expected.filter(e => !known.has(e.word)).map(e => `the expected row '${e.scope} ${e.pageText} ${e.kind} ${e.word}' names no word of wording-words.txt`);
}

// grade: the run's reds ({ scope, page, kind, word, ... }) against the expected rows. A red matches a row of its
// scope whose page pattern, kind (or '*') and word fit; returns each row's hits and the reds no row holds.
export function grade(reds, expected) {
  const fits = (r, e) => e.scope === r.scope && e.page.test(r.page) && (e.kind === '*' || e.kind === r.kind) && e.word === r.word;
  const rowsOut = expected.map(e => ({ ...e, hits: reds.filter(r => fits(r, e)) }));
  const outside = reds.filter(r => !expected.some(e => e.status !== 'must-not' && fits(r, e)));
  const mustMissing = rowsOut.filter(e => e.status === 'must' && e.hits.length === 0);
  const mustNotSeen = rowsOut.filter(e => e.status === 'must-not' && e.hits.length > 0);
  return { rows: rowsOut, outside, mustMissing, mustNotSeen, ok: outside.length === 0 && mustMissing.length === 0 && mustNotSeen.length === 0 };
}

// the self-test: each case is one element on a page of one engine, and the words it must find (none = right)
const here = path.dirname(fileURLToPath(import.meta.url));
export function selfTest() {
  const words = loadWords(fs.readFileSync(path.join(here, 'wording-words.txt'), 'utf8'));
  const allow = loadAllow(fs.readFileSync(path.join(here, 'wording-allow.txt'), 'utf8'));
  const names = ['demo-aurora-crm01', 'aurora', 'sqlserver', 'demo-onprem-sql01', 'erp', 'Sales'];
  const cases = [
    // [engine, page, kind, text, the words it must find]
    ['sqlserver', 'mssqlfiles?i=9', 'prose', 'PostgreSQL: the WAL directory and each tablespace (pg_wal, pg_default and pg_global) on its own drive.', []],
    ['postgres', 'summary?tag=aurora', 'th', 'QS (SQL Server)', ['QS', 'SQL Server']],   // the word and the other engine's name: a label
    ['sqlserver', 'mssqlmemory?i=9', 'tile', 'bloat', []],
    ['sqlserver', 'mssqlmemory?i=9', 'prose', 'A high share of single-use plans means plan cache bloat with optimize for ad hoc off.', []],
    ['sqlserver', 'mssqlindexes?i=9', 'label', 'table bloat', ['table bloat']],
    ['sqlserver', 'summary?i=9', 'tree', 'demo-aurora-crm01', []],
    ['sqlserver', 'summary?i=9', 'tree', 'aurora', []],
    ['postgres', 'summary?i=3', 'prose', 'No warning or critical; no sample for: SQL Agent Alerts, QS.', ['QS', 'Agent Alerts', 'SQL Agent']],
    ['postgres', 'statements?i=3', 'prose', 'PostgreSQL has no Query Store: the statements come from pg_stat_statements.', []],
    ['postgres', 'memory?i=3', 'prose', 'There is no grant queue on PostgreSQL.', []],
    ['postgres', 'pgtemp?i=3', 'prose', "PostgreSQL's TempDB: the temp files and temp_tablespaces.", []],
    ['postgres', 'summary?tag=aurora', 'th', 'Backup FULL', []],
    ['postgres', 'summary?tag=aurora', 'th', 'Backup LOG', ['Backup LOG']],
    ['sqlserver', 'summary?tag=sales', 'tab', 'PostgreSQL options', ['PostgreSQL']],
    ['sqlserver', 'pgrisks?tag=sales', 'prose', 'PostgreSQL options are read every hour from pg_settings.', []],
    ['sqlserver', 'summary?i=9', 'label', 'pgvigil_reader', []],
    ['sqlserver', 'waiting?i=9', 'tab', 'Waiting backends', ['backends']],
    ['postgres', 'waiting?i=3', 'tab', 'Waiting backends', []],
    ['postgres', 'admin_instances', 'option', 'SQL login', []],
    ['sqlserver', 'versions?i=9', 'prose', 'Microsoft SQL Server 2022 16.0.4325.4 on Linux.', []],
    ['postgres', 'jobsreport?i=3', 'label', 'Agent Jobs', ['Agent Jobs']],
    ['postgres', 'jobsreport?i=3', 'label', 'pgAgent jobs', []],
    ['sqlserver', 'mssqljobs?i=9', 'label', 'pgAgent jobs', ['pgAgent']],
    ['sqlserver', 'mssql_running?i=9', 'th', 'pid', ['pid']],
    ['sqlserver', 'mssql_running?i=9', 'th', 'rapid', []],
    ['postgres', 'rp_props?i=3', 'tab', 'Database Extended Properties', ['Extended Properties']],
    ['postgres', 'dbfiles?i=3', 'th', 'filegroup', ['Filegroup']],
    ['postgres', 'running?tag=aurora', 'th', 'tempdb latch waits', ['tempdb']],
    ['postgres', 'rp_flushed?tag=aurora', 'prose', 'The plan cache was cleared by DBCC FREEPROCCACHE.', ['plan cache', 'DBCC']],
    ['postgres', 'summary?tag=aurora', 'cell', 'Memory Dump', ['Memory Dump']],
    ['postgres', 'summary?tag=aurora', 'attr', 'demo-aurora-crm01: Last Good Check DB warning', ['Last Good Check DB']],
    ['sqlserver', 'dbadash', 'prose', 'Imported from DBA Dash: its SQL Server repository.', []],
    ['postgres', 'customreports?i=3', 'prose', 'Reads mssql_plancache for the instance.', ['mssql_']],
    ['postgres', 'rp_props?i=3', 'prose', 'From sys.extended_properties of each database.', ['sys.']],
    ['sqlserver', 'mssql_slow?i=9', 'prose', 'Sessions idle in transaction hold their locks.', ['idle in transaction']],
    ['sqlserver', 'mssql_slow?i=9', 'prose', 'On PostgreSQL, sessions idle in transaction hold their locks.', []],
    ['postgres', 'host?i=3', 'prose', 'The Sales database on erp is the largest.', []],
  ];
  let bad = 0;
  for (const [engine, page, kind, text, want] of cases) {
    const got = check({ text, kind, page }, { engine, words, allow, names }).map(r => r.word);
    const ok = want.length === new Set(got).size && want.every(w => got.includes(w));
    if (!ok) { bad++; console.log(`FAIL self-test: ${engine} ${page} ${kind} ${JSON.stringify(text)}: found [${got.join(', ')}], want [${want.join(', ')}]`); }
  }
  // the expected file loads, names only known words; grade: a listed red, a missing must, a must-not seen, one outside
  const expected = loadExpected(fs.readFileSync(path.join(here, 'wording-expected.txt'), 'utf8'));
  const unknown = validateExpected(expected, words);
  for (const u of unknown) { bad++; console.log('FAIL self-test: ' + u); }
  const ex = loadExpected([
    'must | pg-tag | ^summary\\?tag= | th | Memory Dump | s | f',
    'must | pg-tag | ^running\\?tag= | th | tempdb | s | f',
    'must-not | pg-instance | ^summary\\?i= | prose | QS | s | -',
    'may | pg-instance | . | attr | Agent Jobs | s | f'].join('\n'));
  const g = grade([
    { scope: 'pg-tag', page: 'summary?tag=aurora', kind: 'th', word: 'Memory Dump' },
    { scope: 'pg-instance', page: 'summary?i=3', kind: 'prose', word: 'QS' },
    { scope: 'ms-tag', page: 'versions?tag=sales', kind: 'tab', word: 'PostgreSQL' }], ex);
  const gOk = !g.ok && g.mustMissing.map(e => e.word).join() === 'tempdb' && g.mustNotSeen.map(e => e.word).join() === 'QS'
    && g.outside.map(r => r.word).join() === 'QS,PostgreSQL' && g.rows[3].hits.length === 0;
  if (!gOk) { bad++; console.log(`FAIL self-test: grade ${JSON.stringify({ missing: g.mustMissing.map(e => e.word), notSeen: g.mustNotSeen.map(e => e.word), outside: g.outside.map(r => r.word) })}`); }
  console.log(`wording-match self-test: ${cases.length - bad + 2} of ${cases.length + 2} cases right (${words.length} words, ${allow.length} allow rows, ${expected.length} expected rows)`);
  return bad === 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv[2] === '--self-test') process.exit(selfTest() ? 0 : 1);
  console.error('usage: node scripts/wording-match.mjs --self-test'); process.exit(2);
}
