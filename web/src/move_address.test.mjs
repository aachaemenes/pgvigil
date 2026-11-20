// Unit tests of move_address.ts (the add's prefill: which DBA Dash connection is a network address). Node, no DOM: the
// module is compiled by esbuild (web's own) and its path given as the argument.
//   web/node_modules/.bin/esbuild web/src/move_address.ts --format=esm --outfile=<tmp>/move_address.mjs
//   node web/src/move_address.test.mjs <tmp>/move_address.mjs
// scripts/proof-dbadash-door.sh part G runs it after the web build. Every row prints 'ok' or 'FAIL'; the exit is 1 when
// any failed. The host rows are internal/web/migrate_test.go TestMoveAddCheck's (the server's addressWhy decides).
const m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
const { addrWhy, hostPort, rowAddress, localHost, isV6, addChunks } = m;
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
// an IPv6 address with ',port' (the server takes it); spaces around the ','; isV6 as strict as Go's net.ParseIP;
// an unclosed bracket; a name's 253 limit in bytes (Go's len)
for (const s of ['fe80::1,1433', 'tcp:2001:db8::5,1433', 'sql01, 1433', 'sql01 , 1433', '::ffff:10.1.2.3', '::', '1::']) {
  eq(`address: ${s}`, addrWhy(s), '');
}
has('a space in the name before the comma', addrWhy('sql01 old,1433'), 'a space');
for (const s of ['db1:2:3', ':::', '12345::1', '1:2:3:4:5:6:7:8::', '1::2::3']) has(`not IPv6: ${s}`, addrWhy(s), 'colons');
has('[cafe:1] is not IPv6', addrWhy('[cafe:1]'), 'brackets');
has('an unclosed bracket', addrWhy('[fe80::1'), "a '[' with no ']'");
has('a name of 254 bytes (127 letters)', addrWhy('\u00e9'.repeat(127)), 'not a host name');
eq('isV6 of 8 groups', isV6('1:2:3:4:5:6:7:8'), true);
eq('isV6 of 7 groups', isV6('1:2:3:4:5:6:7'), false);
// the server's localHost: DBA Dash's own host is no address for pgvigil
for (const s of ['localhost', '127.0.0.1', '::1', '[::1]', 'localhost\\SQLEXPRESS', 'localhost,1433', 'tcp:localhost', '.', '(local)', '.\\SQLEXPRESS', '(localdb)\\v11']) {
  eq(`local: ${s}`, localHost(s), true);
}
eq('not local: localhost2', localHost('localhost2'), false);

// hostPort: the row's two fields
eq('host,port', hostPort('sql01.corp.example.com,14330'), ['sql01.corp.example.com', '14330']);
eq('tcp:host,port', hostPort('tcp:sql01,1433'), ['sql01', '1433']);
eq('host:port', hostPort('sql01:1433'), ['sql01', '1433']);
eq('host , port', hostPort('sql01 , 1433'), ['sql01', '1433']);
eq('v6,port', hostPort('fe80::1,1433'), ['fe80::1', '1433']);
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
// a ConnectionID on DBA Dash's own host falls back to the Instance, with why
const loc = rowAddress('SQL01', ['localhost']);
eq('localhost: the host is the Instance', [loc.host, loc.port], ['SQL01', '']);
has('localhost: why says DBA Dash\'s own host', loc.why, "DBA Dash's own host");
const loc2 = rowAddress('SQL01', ['localhost,1433', 'sql01.corp.example.com,14330']);
eq('a local ConnectionID is skipped for the next address', loc2, { host: 'sql01.corp.example.com', port: '14330', why: '' });
eq('tcp:localhost: the Instance', rowAddress('SQL05', ['tcp:localhost']).host, 'SQL05');

// an add's posts under the server's 16 KB body, in order, nothing lost
const base = { op: 'add', repo: 'corp', auth: 'sql', login: 'pgv_mon', password: 'p'.repeat(40) };
const fifty = Array.from({ length: 50 }, (_, i) => ({ server: 'SQL' + i + 'X'.repeat(120), dbadash_ids: [1000 + i, 2000 + i], host: 'sql' + i + '.a-long-domain.example.com', port: '14330', name: 'sql' + i + 'x'.repeat(50) }));
const parts = addChunks(base, fifty);
const sizes = parts.map(p => new TextEncoder().encode(JSON.stringify({ ...base, servers: p })).length);
eq('50 long servers: more than one post', parts.length > 1, true);
eq('every post under 14000 bytes', sizes.every(z => z <= 14000), true);
eq('in order, none lost', parts.flat().map(x => x.server), fifty.map(x => x.server));
eq('a short add: one post', addChunks(base, fifty.slice(0, 3)).length, 1);
console.log(`${n - bad} of ${n} ok`);
process.exit(bad ? 1 : 0);
