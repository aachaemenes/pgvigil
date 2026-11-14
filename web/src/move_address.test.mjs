// Unit tests of move_address.ts (the add's prefill: which DBA Dash connection is a network address). Node, no DOM: the
// module is compiled by esbuild (web's own) and its path given as the argument.
//   web/node_modules/.bin/esbuild web/src/move_address.ts --format=esm --outfile=<tmp>/move_address.mjs
//   node web/src/move_address.test.mjs <tmp>/move_address.mjs
// scripts/proof-dbadash-door.sh part G runs it after the web build. Every row prints 'ok' or 'FAIL'; the exit is 1 when
// any failed. The host rows are internal/web/migrate_test.go TestMoveAddCheck's (the server's addressWhy decides).
const m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
const { addrWhy, hostPort, rowAddress } = m;
let bad = 0, n = 0;
const eq = (what, got, want) => {
  n++;
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${g}, want ${w}`); }
};
const has = (what, got, part) => {
  n++;
  if (typeof got === 'string' && got.includes(part)) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${JSON.stringify(got)}, want it to hold ${JSON.stringify(part)}`); }
};

// addresses: '' (the Go rows that are accepted)
for (const s of ['sql01\\PROD', 'localhost2', 'sql01.corp.example.com,14330', 'tcp:sql01,1433', 'sql_01', '10.1.2.3', '[fe80::1]:1433', '[2001:db8::5]', 'sql01:1433', 'fe80::1']) {
  eq(`address: ${s}`, addrWhy(s), '');
}
// labels: a reason (the Go rows that are refused)
has('a free-text label', addrWhy('SQL01 payroll box (old)'), 'a space');
has('two servers in one label', addrWhy('X_App and Y_Prod'), 'a space');
has('an alias in brackets before the name', addrWhy('[ERP] SQL01'), 'a space');
has('an alias alone in brackets', addrWhy('[ERP]'), 'brackets');
has('an IPv4 address in brackets', addrWhy('[10.1.2.3]'), 'brackets');
has('a note in parentheses', addrWhy('SQL01(old)'), 'brackets');
has('a comma before no port', addrWhy('sql01,prod'), 'is not a port');
has('a port out of range', addrWhy('sql01,70000'), 'not 1 to 65535');
has('an instance name with a space', addrWhy('SQL01\\MY INST'), 'a space');
has('an instance name of 17 characters', addrWhy('SQL01\\' + 'A'.repeat(17)), 'not 1 to 16');
has('an instance name with a hyphen', addrWhy('SQL01\\MY-INST'), 'not a character of an instance name');
has('a name with a slash', addrWhy('sql01/prod'), 'not a character of a network name');
has('a name ending in a dot', addrWhy('sql01.'), 'not a host name');
has('empty', addrWhy('  '), 'empty');

// hostPort: the row's two fields
eq('host,port', hostPort('sql01.corp.example.com,14330'), ['sql01.corp.example.com', '14330']);
eq('tcp:host,port', hostPort('tcp:sql01,1433'), ['sql01', '1433']);
eq('host:port', hostPort('sql01:1433'), ['sql01', '1433']);
eq('[v6]:port', hostPort('[fe80::1]:1433'), ['fe80::1', '1433']);
eq('[v6]', hostPort('[2001:db8::5]'), ['2001:db8::5', '']);
eq('a named instance', hostPort('sql01\\PROD'), ['sql01\\PROD', '']);

// rowAddress: the prefill of a movable row
eq('an address ConnectionID: its host and port, no why', rowAddress('SQL01\\PROD', ['sql01.corp.example.com,14330']), { host: 'sql01.corp.example.com', port: '14330', why: '' });
eq('the first ConnectionID that is an address', rowAddress('SQL02', ['SQL02 (old box)', 'sql02.corp.example.com']), { host: 'sql02.corp.example.com', port: '', why: '' });
const lab = rowAddress('SQL03\\ERP', ['X_App and Y_Prod']);
eq('a label: the host is the Instance, no port', [lab.host, lab.port], ['SQL03\\ERP', '']);
has('a label: why names the ConnectionID', lab.why, '"X_App and Y_Prod"');
has('a label: why says it is not an address', lab.why, 'not a network address (a space in it');
has('a label: why names the Instance', lab.why, "DBA Dash's Instance (@@SERVERNAME)");
const none = rowAddress('SQL04', []);
eq('no ConnectionID: the Instance', none.host, 'SQL04');
has('no ConnectionID: why says so', none.why, 'holds no connection');
const neither = rowAddress('[odd] name', ['[ERP]']);
eq('neither is an address: the host empty', [neither.host, neither.port], ['', '']);
has('neither is an address: why asks for both', neither.why, 'type its host and port');

console.log(`${n - bad} of ${n} ok`);
process.exit(bad ? 1 : 0);
