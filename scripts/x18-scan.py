#!/usr/bin/env python3
"""A status column's other cells, on the screen's side of xlsx-check's X18, for the BADGE-DRAWN status columns: a
grid column (a Col literal `{ key: '...', ... }` in web/src, on one line or several) that draws a warning or critical
badge on some rows - in its own text or through a helper of its file that does. X18 itself counts any column with an
OK, warning or critical fill: a column coloured by its cls alone, or by an OK badge alone, is NOT held here - `--wide`
lists those as candidates (an '' branch may hold only empty values: each read one by one). A badge-drawn status
column's other value-holding cells must carry a status too: OK where the column's check judged the row and found
nothing, N/A where it did not judge it. Two ways pass:
  - the column's cls (a 'status ok' / 'status none' class on the cell), or
  - the column is on the REVIEWED list below (read one by one: its other cells are empty, or each is a badge whose
    class is a status), and every badge it draws - in its text and in its helpers - has a status class: never ''
    and never 'info' (a badge with no status class is a plain cell beside coloured ones).
The scan reads that a cls is there, not what it returns: each cls's values are read by review. A status column that
does neither is a FAIL; a REVIEWED entry that matches no status column is a FAIL too (the list
follows the source).

usage: x18-scan.py <the web/src folder>   prints one line per FAIL, then the counts; exit 1 on any FAIL
       x18-scan.py --wide <the web/src folder>   the candidates beyond the badge scan; exit 1 on any
"""
import glob
import re
import sys

# (file, key): why the column passes without a cls. 'empty' = its other cells hold no value; 'badges' = every other
# value is a badge of class ok or none (OK / N/A).
REVIEWED = {
    ('actions.ts', 'outcome'): 'badges',
    ('admin_instances.ts', 'note'): 'empty',
    ('admin_instances.ts', 'outcome'): 'badges',
    ('alert_page.ts', 'outcome'): 'badges',
    ('alert_page.ts', 'severity'): 'badges',
    ('alert_page.ts', 'status'): 'badges',
    ('alert_rules.ts', 'outcome'): 'badges',
    ('alert_rules.ts', 'state'): 'badges',
    ('alerts.ts', 'last_outcome'): 'badges',
    ('alerts.ts', 'min_severity'): 'badges',
    ('alerts.ts', 'outcome'): 'badges',
    ('alerts.ts', 'severity'): 'badges',
    ('alerts.ts', 'state'): 'badges',
    ('alerts.ts', 'status'): 'badges',
    ('backups.ts', 'severity'): 'badges',
    ('backups.ts', 'worst'): 'badges',
    ('blocking_history.ts', 'victims'): 'empty',
    ('borrowed.ts', 'checks'): 'empty',
    ('borrowed.ts', 'severity'): 'badges',
    ('borrowed.ts', 'was_blocked'): 'empty',
    ('borrowed.ts', 'was_blocker'): 'empty',
    ('corruption.ts', 'amcheck_corrupt'): 'empty',
    ('corruption.ts', 'class'): 'badges',
    ('corruption.ts', 'events_24h'): 'empty',
    ('corruption.ts', 'severity'): 'badges',
    ('corruption.ts', 'status'): 'badges',
    ('custom.ts', 'status_rank'): 'badges',
    ('customreports.ts', 'outcome'): 'badges',
    ('dbadash.ts', 'status'): 'badges',
    ('drill.ts', 'checks'): 'empty',
    ('drill.ts', 'is_wraparound'): 'empty',
    ('drill.ts', 'missed'): 'empty',
    ('drill.ts', 'problems'): 'badges',
    ('drill.ts', 'severity'): 'badges',
    ('drill.ts', 'waited_lock'): 'empty',
    ('extensions.ts', 'outdated_dbs'): 'empty',
    ('extensions.ts', 'severity'): 'badges',
    ('host.ts', 'severity'): 'badges',
    ('indexes.ts', 'is_replica'): 'empty',
    ('indexes.ts', 'problems'): 'badges',
    ('indexes.ts', 'readable'): 'empty',
    ('indexes.ts', 'severity'): 'badges',
    ('io.ts', 'cause'): 'badges',
    ('io.ts', 'severity'): 'badges',
    ('jobs_running.ts', 'outcome'): 'badges',
    ('jobs_timeline.ts', 'outcome'): 'badges',
    ('jobsreport.ts', 'severity'): 'badges',
    ('memory.ts', 'severity'): 'badges',
    ('mssql_actions.ts', 'outcome'): 'badges',
    ('mssql_audit.ts', 'is_enabled'): 'badges',
    ('mssql_audit.ts', 'read_state'): 'badges',
    ('mssql_audit.ts', 'severity'): 'badges',
    ('mssql_audit.ts', 'state'): 'badges',
    ('mssql_backups.ts', 'findings'): 'badges',
    ('mssql_checks.ts', 'severity'): 'badges',
    ('mssql_deadlocks.ts', 'severity'): 'badges',
    ('mssql_deadlocks.ts', 'victim'): 'empty',
    ('mssql_errorlog.ts', 'severity'): 'badges',
    ('mssql_errorlog.ts', 'state'): 'badges',
    ('mssql_hadr.ts', 'severity'): 'badges',
    ('mssql_indexes.ts', 'rule'): 'badges',
    ('mssql_indexes.ts', 'severity'): 'badges',
    ('mssql_perf.ts', 'severity'): 'badges',
    ('mssql_plancache.ts', 'severity'): 'badges',
    ('mssql_querystore.ts', 'forced'): 'empty',
    ('mssql_querystore.ts', 'severity'): 'badges',
    ('mssql_rowversions.ts', 'severity'): 'badges',
    ('mssql_running.ts', 'implicit'): 'empty',
    ('mssql_running.ts', 'is_implicit_tran'): 'empty',
    ('mssql_running.ts', 'victims'): 'empty',
    ('mssql_storage.ts', 'severity'): 'badges',
    ('mssql_summary.ts', 'severity'): 'badges',
    ('mssql_waits.ts', 'severity'): 'badges',
    ('mssql_xe.ts', 'is_failover'): 'empty',
    ('mssql_xe.ts', 'severity'): 'badges',
    ('mssql_xe.ts', 'victim'): 'empty',
    ('pages.ts', 'check_name'): 'badges',
    ('pages.ts', 'kind'): 'badges',
    ('pages.ts', 'severity'): 'badges',
    ('pages.ts', 'status'): 'badges',
    ('pg_backups.ts', 'caught_up'): 'badges',
    ('pg_backups.ts', 'change'): 'badges',
    ('pg_backups.ts', 'ok'): 'badges',
    ('pg_backups.ts', 'replay_paused'): 'empty',
    ('pg_backups.ts', 'severity'): 'badges',
    ('pg_backups.ts', 'state'): 'badges',
    ('pg_backups.ts', 'status'): 'badges',
    ('pg_dboptions.ts', 'severity'): 'badges',
    ('pg_deadlocks.ts', 'victim'): 'empty',
    ('pgconfig.ts', 'pending_restart'): 'empty',
    ('pi.ts', 'severity'): 'badges',
    ('plan.ts', 'severity'): 'badges',
    ('reportmail.ts', 'outcome'): 'badges',
    ('reports.ts', 'victim'): 'empty',
    ('roles.ts', 'error'): 'empty',
    ('running.ts', '_behind'): 'empty',
    ('schema.ts', 'change'): 'badges',
    ('schema.ts', 'severity'): 'badges',
    ('sessionsets.ts', 'fires'): 'empty',
    ('slow.ts', 'result'): 'badges',
    ('slow.ts', 'status'): 'badges',
    ('storage.ts', 'severity'): 'badges',
    ('vacuum.ts', 'severity'): 'badges',
    ('versions.ts', 'collation_mismatches'): 'empty',
    ('versions.ts', 'extensions_outdated'): 'empty',
    ('versions.ts', 'mismatch'): 'empty',
    ('versions.ts', 'pending_actions'): 'badges',
    ('versions.ts', 'severity'): 'badges',
    ('waits.ts', 'blocked'): 'empty',
    ('waits.ts', 'event_type'): 'badges',
}


def close_of(text, i, opener):
    """index just past the bracket closing text[i] (opener '{' or '('), skipping strings, template parts, comments"""
    pair = {'{': '}', '(': ')'}
    stack = [opener]
    j = i + 1
    while j < len(text) and stack:
        c = text[j]
        top = stack[-1]
        if top in ("'", '"'):
            if c == '\\':
                j += 2
                continue
            if c == top:
                stack.pop()
        elif top == '`':
            if c == '\\':
                j += 2
                continue
            if c == '`':
                stack.pop()
            elif c == '$' and text[j + 1:j + 2] == '{':
                stack.append('{')
                j += 2
                continue
        else:
            if c in "'\"`":
                stack.append(c)
            elif c in '{(':
                stack.append(c)
            elif c in '})':
                if pair.get(top) == c:
                    stack.pop()
            elif c == '/' and text[j + 1:j + 2] == '/':
                k = text.find('\n', j)
                j = len(text) if k < 0 else k
                continue
        j += 1
    return j


def top_args(call):
    """the top-level arguments of 'name(a, b, ...)' (string-aware)"""
    i = call.index('(')
    inner = call[i + 1:close_of(call, i, '(') - 1]
    args, depth, q, start, k = [], 0, None, 0, 0
    while k < len(inner):
        c = inner[k]
        if q:
            if c == '\\':
                k += 2
                continue
            if c == q:
                q = None
        elif c in "'\"`":
            q = c
        elif c in '({[':
            depth += 1
        elif c in ')}]':
            depth -= 1
        elif c == ',' and depth == 0:
            args.append(inner[start:k])
            start = k + 1
        k += 1
    args.append(inner[start:])
    return [a.strip() for a in args]


def badges(text):
    """the class argument of every badge(...) call in text"""
    out = []
    for m in re.finditer(r'\bbadge\(', text):
        end = close_of(text, m.end() - 1, '(')
        a = top_args(text[m.start():end])
        out.append(a[1] if len(a) > 1 else '')
    return out


STATUS = re.compile(r"'(warn|crit)'")


def expr_end(text, k):
    """index just past an arrow function's expression body starting at text[k]: its first top-level ';', or a line
    break at depth 0 whose next line does not go on with an operator (? : + . && ||)"""
    stack, j = [], k
    while j < len(text):
        c = text[j]
        if stack and stack[-1] in ("'", '"', '`'):
            if c == '\\':
                j += 2
                continue
            if c == stack[-1]:
                stack.pop()
            elif stack[-1] == '`' and c == '$' and text[j + 1:j + 2] == '{':
                stack.append('{')
                j += 2
                continue
        elif c in "'\"`":
            stack.append(c)
        elif c in '({[':
            stack.append(c)
        elif c in ')}]':
            if not stack:
                return j
            stack.pop()
        elif not stack and c in ';,':
            return j
        elif not stack and c == '\n':
            nxt = text[j + 1:].lstrip(' ')
            if not re.match(r'(\?|:|\+|\.|&&|\|\|)', nxt):
                return j
        j += 1
    return j


def helpers(text):
    """name -> body of each function-shaped helper in the file (an arrow or a function declaration, a name of three
    letters or more) that draws a warning or critical badge"""
    found = {}
    for m in re.finditer(r"(?m)^[ \t]*(?:export\s+)?(?:const\s+(\w{3,})\s*=\s*(?:\([^)]*\)|\w+)\s*(?::\s*[\w |]+)?\s*=>\s*|function\s+(\w{3,})\s*\()", text):
        name = m.group(1) or m.group(2)
        k = m.end()
        if m.group(2):   # a function declaration: its braces
            b = text.index('{', k)
            body = text[k:close_of(text, b, '{')]
        elif text[k:k + 1] == '{':
            body = text[k:close_of(text, k, '{')]
        else:
            body = text[k:expr_end(text, k)]
        if 'badge(' in body and STATUS.search(body):
            found[name] = body
    return found


COL = re.compile(r"\{\s*key:\s*'([^']+)'")          # a Col literal, on one line or over several
CLS_STATUS = re.compile(r"'(?:status )?(?:ok|warn|crit)'")
HELPER = re.compile(r"(?m)^[ \t]*(?:export\s+)?(?:const\s+(\w{3,})\s*=\s*(?:\([^)]*\)|\w+)\s*(?::\s*[\w |]+)?\s*=>\s*|function\s+(\w{3,})\s*\()")


def all_helpers(text):
    """name -> body of every function-shaped helper in the file (a cls may be one, or a call of one)"""
    found = {}
    for m in HELPER.finditer(text):
        name, k = m.group(1) or m.group(2), m.end()
        if m.group(2):
            b = text.index('{', k)
            found[name] = text[k:close_of(text, b, '{')]
        elif text[k:k + 1] == '{':
            found[name] = text[k:close_of(text, k, '{')]
        else:
            found[name] = text[k:expr_end(text, k)]
    return found


def cls_text(body, hs):
    """a Col's cls as written, with the body of the file's helper it names or calls"""
    i = body.find('cls:')
    if i < 0:
        return None
    k = i + 4
    while body[k:k + 1] in (' ', '\n'):
        k += 1
    t = body[k:expr_end(body, k)]
    m = re.match(r'(\w+)\s*(?:\(|$)', t)
    if m and m.group(1) in hs:
        t += hs[m.group(1)]
    return t


def wide(src):
    """the status columns the badge scan does not see (X18 calls a column a status column by any OK, warning or
    critical fill): (a) a cls that colours some rows (warn / crit / ok, bare or 'status ...') and returns '' on
    others; (b) a column whose only status is an OK badge. Each is a candidate: an '' branch may be an empty value
    only - read one by one"""
    n = 0
    for path in sorted(glob.glob(f'{src}/*.ts')):
        name = path.split('/')[-1]
        if '.test.' in name:
            continue
        text = open(path, encoding='utf-8').read()
        hs, ha = helpers(text), all_helpers(text)
        okh = {h: b for h, b in ha.items() if 'badge(' in b and re.search(r"'ok'", b)}
        for m in COL.finditer(text):
            body = text[m.start():close_of(text, m.start(), '{')]
            key, line = m.group(1), text.count('\n', 0, m.start()) + 1
            used = [h for h in hs if re.search(r'fmt:\s*(?:(?:\([^)]*\)|\w+)\s*=>\s*)?' + h + r'\b', body)]
            if ('badge(' in body and STATUS.search(body)) or used:
                continue   # the badge scan's own
            ct = cls_text(body, ha)
            if ct is not None:
                if CLS_STATUS.search(ct) and "''" in ct:
                    print(f"WIDE a {name}:{line} '{key}': its cls colours some rows and returns '' on others")
                    n += 1
                continue
            oku = [h for h in okh if re.search(r'\b' + h + r'\b', body)]
            if ('badge(' in body and "'ok'" in ' '.join(badges(body))) or oku:
                print(f"WIDE b {name}:{line} '{key}': an OK badge on some rows, no cls")
                n += 1
    print(f'{n} candidate status columns beyond the badge scan')
    return 1 if n else 0


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--wide':
        return wide(sys.argv[2].rstrip('/'))
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    src = sys.argv[1].rstrip('/')
    bad, n, seen = 0, 0, set()
    for path in sorted(glob.glob(f'{src}/*.ts')):
        name = path.split('/')[-1]
        if '.test.' in name:
            continue
        text = open(path, encoding='utf-8').read()
        hs = helpers(text)
        for m in COL.finditer(text):
            body = text[m.start():close_of(text, m.start(), '{')]
            key = m.group(1)
            used = [h for h in hs if re.search(r'fmt:\s*(?:(?:\([^)]*\)|\w+)\s*=>\s*)?' + h + r'\b', body)]
            if not (('badge(' in body and STATUS.search(body)) or used):
                continue
            n += 1
            line = text.count('\n', 0, m.start()) + 1
            if 'cls:' in body:
                continue
            why = REVIEWED.get((name, key))
            if why is None:
                print(f"FAIL {name}:{line} '{key}': a status column without a cls, not reviewed")
                bad += 1
                continue
            seen.add((name, key))
            plain = [c for c in badges(body + ''.join(hs[h] for h in used)) if c in ("''", "'info'") or re.search(r"(?<!\?)\?\s*''|:\s*''|[?:]\s*'info'", c)]
            if plain:
                print(f"FAIL {name}:{line} '{key}' ({why}): a badge with no status class ({', '.join(plain)})")
                bad += 1
    for k in sorted(set(REVIEWED) - seen):
        print(f"FAIL REVIEWED {k[0]} '{k[1]}': no status column of that key without a cls (the list follows the source)")
        bad += 1
    print(f'{n - bad} of {n} status columns ok' if bad <= n else f'{bad} FAIL')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
