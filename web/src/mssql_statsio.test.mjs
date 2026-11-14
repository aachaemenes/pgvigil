// Unit tests of mssql_statsio.ts (the STATISTICS IO / TIME reader, task 406). Node, no DOM: the module is compiled by
// esbuild (web's own) and its path given as the first argument; a second argument names a messages file captured from
// a server with its expected figures beside it (<file>.expect.json: {statements, logical_reads[], rows[]}), which
// scripts/proof-mssql-qs-plans.sh writes on the box.
//   web/node_modules/.bin/esbuild web/src/mssql_statsio.ts --format=esm --outfile=<tmp>/mssql_statsio.mjs
//   node web/src/mssql_statsio.test.mjs <tmp>/mssql_statsio.mjs [<captured messages>]
// Every row prints 'ok' or 'FAIL'; the exit is 1 when any failed.
import { readFileSync } from 'node:fs';
const m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
const { parseMessages, totals, byTable, counterNames, change, saveText, readSaved, looksLikeStatistics, topStatements, tableKey } = m;
let bad = 0, n = 0;
const eq = (what, got, want) => {
  n++;
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${g}, want ${w}`); }
};

// one statement as sqlcmd prints it (2019+: the page server counters)
const one = `SQL Server parse and compile time:
   CPU time = 0 ms, elapsed time = 3 ms.

(5000 rows affected)
Table 't'. Scan count 1, logical reads 22, physical reads 0, page server reads 0, read-ahead reads 0, page server read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob page server reads 0, lob read-ahead reads 0, lob page server read-ahead reads 0.

 SQL Server Execution Times:
   CPU time = 15 ms,  elapsed time = 120 ms.
`;
let p = parseMessages(one);
eq('one: one run, one statement', [p.runs.length, p.runs[0].statements.length], [1, 1]);
const s1 = p.runs[0].statements[0];
eq('one: rows, CPU, elapsed, compile', [s1.rows, s1.cpuMs, s1.elapsedMs, s1.compileCpuMs, s1.compileElapsedMs], [5000, 15, 120, 0, 3]);
eq('one: the counters by name', [s1.io[0].table, s1.io[0].counters['scan count'], s1.io[0].counters['logical reads'], s1.io[0].counters['page server read-ahead reads']], ['t', 1, 22, 0]);
let t = totals(p.runs[0]);
eq('one: totals exact', [t.exact, t.cpuMs, t.elapsedMs, t.logicalReads, t.rows], [true, { low: 15, high: 15 }, { low: 120, high: 120 }, 22, 5000]);

// two statements, a temporary table with its session suffix, a worktable, a columnstore's segment reads (SSMS adds
// 'Completion time'); the totals without the query are a range
const two = `
(1 row affected)
Table '#t__________________________________________________________________________________________________________000000000012'. Scan count 1, logical reads 5, physical reads 0, read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob read-ahead reads 0.
Table 'Worktable'. Scan count 0, logical reads 0, physical reads 0, read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob read-ahead reads 0.

 SQL Server Execution Times:
   CPU time = 0 ms,  elapsed time = 2 ms.
Table 'sales'. Scan count 4, logical reads 0, physical reads 0, read-ahead reads 0, lob logical reads 310, lob physical reads 0, lob read-ahead reads 0.
Table 'sales'. Segment reads 6, segment skipped 2.

(4 rows affected)

 SQL Server Execution Times:
   CPU time = 47 ms,  elapsed time = 51 ms.

Completion time: 2026-11-14T14:20:00.1234567-08:00
`;
p = parseMessages(two);
eq('two: statements', p.runs[0].statements.length, 2);
eq('two: a temporary table folded', tableKey(p.runs[0].statements[0].io[0].table), '#t');
const tabs = byTable(p.runs[0]);
eq('two: tables', tabs.map(x => x.table).sort(), ['#t', 'Worktable', 'sales']);
eq('two: segment reads summed under the table', tabs.find(x => x.table === 'sales').counters['segment reads'], 6);
eq('two: a new counter becomes a column', counterNames(p.runs).includes('segment skipped'), true);
eq('two: % logical reads', tabs.find(x => x.table === '#t').share, 100);
t = totals(p.runs[0]);
eq('two: no query = a range', [t.exact, t.cpuMs, t.elapsedMs], [false, { low: 47, high: 47 }, { low: 51, high: 53 }]);
eq('two: Completion time is not a statement', p.read, 8);
t = totals(p.runs[0], 'EXEC dbo.report @d = 1;');
eq('two: one statement at the top = its last block', [t.exact, t.elapsedMs], [true, { low: 51, high: 51 }]);
t = totals(p.runs[0], "UPDATE dbo.x SET a = 1; SELECT 'insert into' FROM y;");
eq('two: DML warns of triggers', t.warnings.some(w => /trigger/.test(w)), true);

// runs: the markers (the PRINT's own time left out), a labelled run, a run with STATISTICS off
const runs = `DBADash-Compare: before

 SQL Server Execution Times:
   CPU time = 0 ms,  elapsed time = 0 ms.
Table 't'. Scan count 1, logical reads 100, physical reads 3, read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob read-ahead reads 0.

 SQL Server Execution Times:
   CPU time = 20 ms,  elapsed time = 40 ms.
DBADash-Compare

 SQL Server Execution Times:
   CPU time = 0 ms,  elapsed time = 0 ms.
(3 rows affected)
DBADash-Compare: after

 SQL Server Execution Times:
   CPU time = 0 ms,  elapsed time = 0 ms.
Table 't'. Scan count 1, logical reads 25, physical reads 0, read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob read-ahead reads 0.

 SQL Server Execution Times:
   CPU time = 5 ms,  elapsed time = 9 ms.
`;
p = parseMessages(runs);
eq('runs: three runs with their labels', p.runs.map(r => r.label), ['before', 'run 2', 'after']);
eq('runs: the PRINT\'s time left out', p.runs[0].statements.map(s => s.cpuMs), [20]);
eq('runs: the middle run has no statistics (blank, not 0)', [p.runs[1].off || totals(p.runs[1]).logicalReads === null], [true]);
eq('runs: first against last', change(totals(p.runs[0]).logicalReads, totals(p.runs[2]).logicalReads), -75);
eq('change: blank side', change(null, 5), null);

// another language: nothing read, and the reader says so
p = parseMessages(`Tabelle 't'. Scananzahl 1, logische Lesevorgänge 22, physische Lesevorgänge 0.

 SQL Server-Ausführungszeiten:
   CPU-Zeit = 0 ms, verstrichene Zeit = 1 ms.`);
eq('German: nothing read, a note', [p.read, p.notes.some(x => /language/.test(x))], [0, true]);

// Azure Data Studio's own lines are not statistics
p = parseMessages(`Started executing query at Line 1
Table 't'. Scan count 1, logical reads 2, physical reads 0.
Total execution time: 00:00:00.012`);
eq('ADS: the table read, its lines not', [p.read, p.runs[0].statements.length], [1, 1]);

// the saved file: the messages are parsed again, the figures in the file are not read
const saved = saveText('x.txt', one, 'SELECT 1');
const back = readSaved(saved);
eq('save: round trip', [back.messages === one, back.query], [true, 'SELECT 1']);
const forged = JSON.stringify({ kind: 'pgvigil-statistics', version: 1, messages: one, runs: [{ statements: [{ cpuMs: 999999 }] }] });
eq('save: a forged figure is not read', totals(parseMessages(readSaved(forged).messages).runs[0]).cpuMs, { low: 15, high: 15 });
eq('save: not a saved file', readSaved('{"kind":"other"}'), null);

eq('detect', [looksLikeStatistics(one), looksLikeStatistics('select 1')], [true, false]);
eq('top statements', [topStatements("EXEC p; SELECT 'a;b' -- SELECT\n/* UPDATE */").count, topStatements('INSERT t SELECT 1 FROM x').count, topStatements('UPDATE t SET a=1').dml], [2, 1, true]);

// a messages file captured on a server, with the figures the server gave for each statement
if (process.argv[3]) {
  const text = readFileSync(process.argv[3], 'utf8');
  const want = JSON.parse(readFileSync(process.argv[3] + '.expect.json', 'utf8'));
  const cap = parseMessages(text);
  const st = cap.runs.flatMap(r => r.statements).filter(s => s.io.length);
  eq('captured: statements with I/O', st.length, want.statements);
  eq('captured: logical reads per statement = the server\'s last_logical_reads', st.map(s => s.io.reduce((a, x) => a + (x.counters['logical reads'] ?? 0), 0)), want.logical_reads);
  eq('captured: rows per statement = the server\'s last_rows', st.map(s => s.rows), want.rows);
}

console.log(`${n - bad} of ${n} ok`);
process.exit(bad ? 1 : 0);
