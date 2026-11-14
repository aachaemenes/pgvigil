// The add's prefill rule (task 206, DONE-2): which of DBA Dash's connections for a server is a network address
// pgvigil can connect to, split into the row's host and port; else DBA Dash's Instance (@@SERVERNAME) with why. No
// imports and no DOM: web/src/move_address.test.mjs runs it in Node (scripts/proof-dbadash-door.sh part G).

// addrWhy is q_migrate.go's addressWhy for the row's prefill (the server decides): why a server as DBA Dash connects to
// it is not a network name or address, '' when it is. A ConnectionID is often a free-text label (a host and a comment,
// an alias in brackets, two names in one).
export const isV4 = (s: string) => /^\d{1,3}(\.\d{1,3}){3}$/.test(s) && s.split('.').every(p => Number(p) <= 255);
// isV6 is Go's net.ParseIP for a text with ':' (no zone): 8 groups of 1 to 4 hex digits, or fewer with one '::' standing
// for at least one zero group; the last two groups may be an IPv4 address.
export function isV6(s: string): boolean {
  if (!s.includes(':')) return false;
  let t = s;
  const last = t.lastIndexOf(':'), tail = t.slice(last + 1);
  if (tail.includes('.')) { if (!isV4(tail)) return false; t = t.slice(0, last + 1) + '0:0'; }
  const halves = t.split('::');
  if (halves.length > 2) return false;
  const groups = halves.flatMap(h => (h === '' ? [] : h.split(':')));
  if (!groups.every(g => /^[0-9A-Fa-f]{1,4}$/.test(g))) return false;
  return halves.length === 2 ? groups.length < 8 : groups.length === 8;
}
// localHost is q_migrate.go's localHost on the row's host: DBA Dash's connection names the server on DBA Dash's own
// host, which pgvigil cannot reach so.
export function localHost(raw: string): boolean {
  const h = hostPort(raw)[0].toLowerCase();
  if (['', '.', '(local)', 'localhost', '127.0.0.1', '::1', '(localdb)'].includes(h)) return true;
  return ['.\\', '(local)\\', 'localhost\\', '(localdb)\\'].some(p => h.startsWith(p));
}
// spaces around the ',' before a port come off ('sql01, 1433' is sql01 on 1433), as on the server
const commaTrim = (s: string) => { const i = s.indexOf(','); return i < 0 ? s : s.slice(0, i).trim() + ',' + s.slice(i + 1).trim(); };
export function portWhy(p: string): string {
  const t = p.trim();
  if (!/^\d+$/.test(t)) return `"${p}" after the name is not a port`;
  const n = Number(t);
  return n < 1 || n > 65535 ? `port ${n} is not 1 to 65535` : '';
}
export function addrWhy(raw: string): string {
  let s = raw.trim();
  if (s.length > 4 && s.slice(0, 4).toLowerCase() === 'tcp:') s = s.slice(4);
  s = commaTrim(s);
  if (s === '') return 'empty';
  if (/[ \t]/.test(s)) return 'a space in it: a label, not a network name';
  if (s.startsWith('[')) {
    const close = s.indexOf(']');
    if (close < 0) return "a '[' with no ']': not a network address";
    const inner = s.slice(1, close), rest = s.slice(close + 1);
    if (!isV6(inner) || inner.includes('.')) return 'brackets around a name: an alias, not a network address';
    if (rest === '') return '';
    return rest.startsWith(':') ? portWhy(rest.slice(1)) : 'text after the bracketed address';
  }
  let host = s;
  const colons = (s.match(/:/g) ?? []).length;
  if (s.includes(',')) {
    const i = s.indexOf(','), why = portWhy(s.slice(i + 1));
    if (why) return why;
    host = s.slice(0, i);
  } else if (colons === 1) {
    const i = s.indexOf(':'), why = portWhy(s.slice(i + 1));
    if (why) return why;
    host = s.slice(0, i);
  } else if (colons > 1) {
    return isV6(s) ? '' : 'colons that are neither an IPv6 address nor a port';
  }
  const b = host.indexOf('\\');
  const name = b < 0 ? host : host.slice(0, b), inst = b < 0 ? null : host.slice(b + 1);
  if (/[[\](){}]/.test(name)) return 'brackets in it: a label, not a network name';
  if (!isV4(name) && !isV6(name)) {
    if (name === '' || new TextEncoder().encode(name).length > 253 || name.includes('..') || /^[.-]|[.-]$/.test(name)) return 'not a host name';
    const bad = [...name].find(r => !/[\p{L}\p{Nd}_.-]/u.test(r));
    if (bad !== undefined) return `"${bad}" is not a character of a network name`;
  }
  if (inst !== null) {
    if (inst === '' || [...inst].length > 16) return 'the instance name after \'\\\' is not 1 to 16 characters';
    const bad = [...inst].find(r => !/[\p{L}\p{Nd}_$#]/u.test(r));
    if (bad !== undefined) return `"${bad}" is not a character of an instance name`;
  }
  return '';
}

// hostPort splits an address addrWhy took into the row's host and port fields ('tcp:', ',port', ':port', '[v6]:port').
export function hostPort(raw: string): [string, string] {
  let s = raw.trim();
  if (s.length > 4 && s.slice(0, 4).toLowerCase() === 'tcp:') s = s.slice(4);
  if (s.startsWith('[')) { const i = s.indexOf(']'); return [s.slice(1, i), s.slice(i + 1).replace(/^:/, '')]; }
  if (s.includes(',')) { const i = s.indexOf(','); return [s.slice(0, i).trim(), s.slice(i + 1).trim()]; }
  if ((s.match(/:/g) ?? []).length === 1) { const i = s.indexOf(':'); return [s.slice(0, i), s.slice(i + 1)]; }
  return [s, ''];
}

// rowAddress is a movable row's prefill: the first of DBA Dash's ConnectionIDs that is a network address (its port
// apart), else DBA Dash's Instance (@@SERVERNAME) with why, else nothing with why - never a silent refusal at the add.
// A connection on DBA Dash's own host (localhost, 127.0.0.1, '.') is no address for pgvigil: the server refuses it.
export function rowAddress(server: string, conns: string[]): { host: string; port: string; why: string } {
  const why = (c: string) => addrWhy(c) || (localHost(c) ? "it names DBA Dash's own host" : '');
  const pick = conns.find(c => why(c) === '');
  if (pick !== undefined) { const [host, port] = hostPort(pick); return { host, port, why: '' }; }
  const said = conns.length ? `DBA Dash connects to it as ${conns.map(c => `"${c}"`).join(', ')}: not a network address (${why(conns[0])})` : 'DBA Dash holds no connection for it';
  if (why(server) === '') return { host: server, port: '', why: `${said}; the host here is DBA Dash's Instance (@@SERVERNAME) - check it and the port.` };
  return { host: '', port: '', why: `${said}, nor is its Instance "${server}" - type its host and port.` };
}

// addChunks splits an add's servers into posts whose JSON body stays under limit bytes (the server takes 16 KB per
// post): 50 servers with long names and their InstanceIDs pass 16 KB in one. In order; a server too long alone is a
// post of its own (the server then refuses it in its words).
export function addChunks<T>(base: object, servers: T[], limit = 14000): T[][] {
  const size = (x: unknown) => new TextEncoder().encode(JSON.stringify(x)).length;
  const out: T[][] = [];
  let cur: T[] = [];
  for (const sv of servers) {
    if (cur.length && size({ ...base, servers: [...cur, sv] }) > limit) { out.push(cur); cur = []; }
    cur.push(sv);
  }
  if (cur.length) out.push(cur);
  return out;
}
