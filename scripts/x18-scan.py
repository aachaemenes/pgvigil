#!/usr/bin/env python3
"""A status column's other cells, on the screen's side of xlsx-check's X18. A status column is a grid column (a Col
literal `{ key: '...', ... }` in web/src) that draws a warning or critical badge on some rows - in its own text or
through a helper of its file that does. Its other value-holding cells must carry a status too: OK where the column's
check judged the row and found nothing, N/A where it did not judge it. Two ways pass:
  - the column's cls (a 'status ok' / 'status none' class on the cell), or
  - the column is on the REVIEWED list below (read one by one: its other cells are empty, or each is a badge whose
    class is a status), and every badge it draws - in its text and in its helpers - has a status class: never ''
    and never 'info' (a badge with no status class is a plain cell beside coloured ones).
A status column that does neither is a FAIL; a REVIEWED entry that matches no status column is a FAIL too (the list
follows the source).

usage: x18-scan.py <the web/src folder>   prints one line per FAIL, then the counts; exit 1 on any FAIL
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


def main():
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
        for m in re.finditer(r"\{ key: '([^']+)'", text):
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
