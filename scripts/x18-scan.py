#!/usr/bin/env python3
"""A status column's other cells, on the screen's side of xlsx-check's X18, for the BADGE-DRAWN status columns: a
grid column (a Col literal `{ key: '...', ... }` in web/src, on one line or several) that draws a warning or critical
badge on some rows - in its own text or through a helper of its file that does. X18 itself counts any column with an
OK, warning or critical fill: a column coloured by its cls alone, or by an OK badge alone, is held by `--wide`
(WIDE_REVIEWED: an '' branch may hold only empty values, so each is read one by one). A badge-drawn status
column's other value-holding cells must carry a status too: OK where the column's check judged the row and found
nothing, N/A where it did not judge it. Two ways pass:
  - the column's cls (a 'status ok' / 'status none' class on the cell), or
  - the column is on the REVIEWED list below (read one by one: its other cells are empty, or each is a badge whose
    class is a status), and every badge it draws - in its text and in its helpers - has a status class: never ''
    and never 'info' (a badge with no status class is a plain cell beside coloured ones).
The scan reads that a cls is there, not what it returns: each cls's values are read by review. A status column that
does neither is a FAIL; a REVIEWED entry that matches no status column is a FAIL too (the list
follows the source).
Known limits (none wrong on today's tree): the bracket reader skips // comments and strings, not /* */ comments or
regex literals; a REVIEWED key covers every Col of that key in its file; a badge class held in a variable passes
unread.

usage: x18-scan.py <the web/src folder>   prints one line per FAIL, then the counts; exit 1 on any FAIL
       x18-scan.py --wide <the web/src folder>   the columns beyond the badge scan, held by WIDE_REVIEWED; exit 1 on any FAIL
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
            if not re.match(r'(\?|:|\+|\.|&&|\|\|)', nxt) and not text[k:j].rstrip().endswith('=>'):
                return j   # a line that ends in '=>' goes on (a curried helper's inner arrow)
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
CLS_STATUS = re.compile(r"'(?:status )?(?:ok|warn|crit)'|'status ' \+|`status \$\{")   # a class built from a status word too
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
    """a Col's cls as written, with the body of each helper of the file it names or calls, and of theirs"""
    i = body.find('cls:')
    if i < 0:
        return None
    k = i + 4
    while body[k:k + 1] in (' ', '\n'):
        k += 1
    t = body[k:expr_end(body, k)]
    seen, todo = set(), [t]
    while todo:   # each helper it names or calls, and theirs, to any depth
        code = re.sub(r"'[^'\\]*'", "''", todo.pop())   # a helper's name inside a string is no call
        for h in hs:
            if h not in seen and re.search(r'\b' + h + r'\b', code):
                seen.add(h)
                todo.append(hs[h])
    return t + ''.join(hs[h] for h in sorted(seen))


# (file, key): why a column the badge scan does not see passes X18. 'empty' = its '' branch only meets an empty cell
# (the fmt draws nothing there); 'cls' = its cls read one by one: every value-holding row gets a status (OK, N/A or its
# warning / critical); 'badges' = every badge it draws has a status class (ok / none / warn / crit); 'nostatus' = the
# OK badge the scan saw is in a dialog the cell's button opens, or a word that names a helper - the cell draws none
WIDE_REVIEWED = {
    ('actions.ts', '_actions'): 'nostatus',
    ('alert_rules.ts', 'source'): 'badges',
    ('alerts.ts', '_act'): 'nostatus',
    ('alerts.ts', 'state'): 'badges',
    ('backups.ts', 'archive_age_s'): 'cls',
    ('backups.ts', 'archiver_failing'): 'cls',
    ('filedrop.ts', 'actRows'): 'cls',
    ('filedrop.ts', 'share'): 'cls',
    ('filedrop.ts', 'warnings'): 'empty',
    ('indexes.ts', 'bloat_pct'): 'cls',
    ('indexes.ts', 'pct_used'): 'cls',
    ('indexes.ts', 'uses_index'): 'badges',
    ('io.ts', 'blks_read'): 'cls',
    ('jobs_fleet_status.ts', 'outcome'): 'empty',
    ('jobsreport.ts', 'last_start'): 'cls',
    ('mssql_actions.ts', 'state'): 'badges',
    ('mssql_backups.ts', 'ag_name'): 'empty',
    ('mssql_backups.ts', 'diff_status'): 'empty',
    ('mssql_backups.ts', 'log_status'): 'empty',
    ('mssql_backups.ts', 'nul_at'): 'empty',
    ('mssql_checks.ts', 'i'): 'cls',
    ('mssql_checks.ts', 'is_on'): 'cls',
    ('mssql_checks.ts', 'notifies'): 'cls',
    ('mssql_checks.ts', 'opt_'): 'cls',
    ('mssql_checks.ts', 'pct_used'): 'cls',
    ('mssql_checks.ts', 'value'): 'cls',
    ('mssql_checks.ts', 'value_in_use'): 'cls',
    ('mssql_errorlog.ts', 'access_violation'): 'cls',
    ('mssql_errorlog.ts', 'bad_pages_detected'): 'cls',
    ('mssql_errorlog.ts', 'deadlocked_schedulers'): 'cls',
    ('mssql_errorlog.ts', 'dump_requests'): 'cls',
    ('mssql_errorlog.ts', 'duration_ms'): 'cls',
    ('mssql_errorlog.ts', 'failure_type'): 'empty',
    ('mssql_errorlog.ts', 'interval_long_ios'): 'cls',
    ('mssql_errorlog.ts', 'io_latch_timeouts'): 'cls',
    ('mssql_errorlog.ts', 'is_process_physical_memory_low'): 'cls',
    ('mssql_errorlog.ts', 'is_process_virtual_memory_low'): 'cls',
    ('mssql_errorlog.ts', 'is_system_physical_memory_low'): 'cls',
    ('mssql_errorlog.ts', 'last_notification'): 'cls',
    ('mssql_errorlog.ts', 'latch_warnings'): 'cls',
    ('mssql_errorlog.ts', 'memory_utilization'): 'cls',
    ('mssql_errorlog.ts', 'non_yielding'): 'cls',
    ('mssql_errorlog.ts', 'notification'): 'cls',
    ('mssql_errorlog.ts', 'oom_exceptions'): 'cls',
    ('mssql_errorlog.ts', 'other_cpu'): 'cls',
    ('mssql_errorlog.ts', 'pending_tasks'): 'cls',
    ('mssql_errorlog.ts', 'pool_out_of_memory'): 'cls',
    ('mssql_errorlog.ts', 'process_memory_low'): 'cls',
    ('mssql_errorlog.ts', 'process_virtual_low'): 'cls',
    ('mssql_errorlog.ts', 'severity'): 'cls',
    ('mssql_errorlog.ts', 'sick_spinlock'): 'empty',
    ('mssql_errorlog.ts', 'slow'): 'cls',
    ('mssql_errorlog.ts', 'sql_cpu'): 'cls',
    ('mssql_errorlog.ts', 'system_memory_low'): 'cls',
    ('mssql_errorlog.ts', 'unresolvable_deadlock'): 'cls',
    ('mssql_errorlog.ts', 'write_access_violations'): 'cls',
    ('mssql_hadr.ts', 'age_minutes'): 'cls',
    ('mssql_hadr.ts', 'connected_state'): 'cls',
    ('mssql_hadr.ts', 'member_state'): 'cls',
    ('mssql_hadr.ts', 'state'): 'cls',
    ('mssql_hadr.ts', 'status'): 'cls',
    ('mssql_hadr.ts', 'synchronization_health'): 'cls',
    ('mssql_hadr.ts', 'synchronization_state'): 'cls',
    ('mssql_indexes.ts', 'benefit_per_day'): 'cls',
    ('mssql_jobs.ts', 'last_run_at'): 'cls',
    ('mssql_jobs.ts', 'last_run_utc'): 'empty',
    ('mssql_perf.ts', 'read_ms'): 'cls',
    ('mssql_perf.ts', 'write_ms'): 'cls',
    ('mssql_plancache.ts', 'compiled_24h_pct'): 'cls',
    ('mssql_plancache.ts', 'duplicate_pct'): 'cls',
    ('mssql_plancache.ts', 'single_use_pct'): 'cls',
    ('mssql_querystore.ts', 'actual_state'): 'cls',
    ('mssql_querystore.ts', 'cpu_ratio'): 'cls',
    ('mssql_querystore.ts', 'duration_ratio'): 'cls',
    ('mssql_querystore.ts', 'force_failure_count'): 'cls',
    ('mssql_querystore.ts', 'forced'): 'empty',
    ('mssql_querystore.ts', 'severity'): 'cls',
    ('pages.ts', 'waiting_lock'): 'empty',
    ('pg_backups.ts', 'datname'): 'nostatus',
    ('pg_backups.ts', 'key'): 'nostatus',
    ('pg_backups.ts', 'postmaster_restarted'): 'nostatus',
    ('pg_backups.ts', 'role'): 'badges',
    ('pg_backups.ts', 'sync_state'): 'badges',
    ('pg_backups.ts', 'worst'): 'badges',
    ('pg_dboptions.ts', 'server_text'): 'cls',
    ('pg_dboptions.ts', 'value_text'): 'cls',
    ('pooler.ts', 'cl_waiting'): 'cls',
    ('pooler.ts', 'clients_waiting'): 'cls',
    ('reportmail.ts', 'enabled'): 'badges',
    ('reportmail.ts', 'last_outcome'): 'badges',
    ('reports.ts', 'days_until_expiration'): 'cls',
    ('reports.ts', 'expired'): 'cls',
    ('reports.ts', 'expiring'): 'cls',
    ('reports.ts', 'i:'): 'cls',
    ('reports.ts', 'ifi_enabled'): 'cls',
    ('reports.ts', 'is_expired'): 'cls',
    ('reports.ts', 'is_locked'): 'cls',
    ('reports.ts', 'l:'): 'cls',
    ('reports.ts', 'max_age'): 'cls',
    ('reports.ts', 'md5'): 'cls',
    ('reports.ts', 'outcome'): 'empty',
    ('reports.ts', 'password_age_days'): 'cls',
    ('reports.ts', 'snapshot_at'): 'empty',
    ('reports.ts', 'startup_type'): 'cls',
    ('reports.ts', 'status'): 'empty',
    ('retention.ts', 'actual_days'): 'cls',
    ('retention.ts', 'retention'): 'cls',
    ('schema.ts', 'ddl_log'): 'badges',
    ('statements.ts', 'jit_pct'): 'cls',
    ('statements.ts', 'plan_pct'): 'cls',
    ('statements.ts', 'workers_missing'): 'cls',
    ('vacuum.ts', 'anl_ratio'): 'cls',
    ('vacuum.ts', 'dead_ratio'): 'cls',
    ('vacuum.ts', 'elapsed_secs'): 'cls',
    ('vacuum.ts', 'freeze_pct'): 'cls',
    ('vacuum.ts', 'hours_over'): 'cls',
    ('vacuum.ts', 'ins_ratio'): 'cls',
    ('vacuum.ts', 'mxid_freeze_pct'): 'cls',
    ('vacuum.ts', 'xid_freeze_pct'): 'cls',
}


def wide(src):
    """the status columns the badge scan does not see (X18 calls a column a status column by any OK, warning or
    critical fill): (a) a cls that colours some rows (warn / crit / ok, bare or 'status ...') and returns '' on
    others; (b) a column whose only status is an OK badge. Each passes only on WIDE_REVIEWED (an '' branch may hold
    only empty values: read one by one); a 'badges' entry also with every badge of a status class. A WIDE_REVIEWED
    entry that matches no such column is a FAIL (the list follows the source)"""
    bad, n, seen = 0, 0, set()
    for path in sorted(glob.glob(f'{src}/*.ts')):
        name = path.split('/')[-1]
        if '.test.' in name:
            continue
        text = open(path, encoding='utf-8').read()
        hs, ha = helpers(text), all_helpers(text)
        okh = {h: b for h, b in ha.items() if 'badge(' in b and re.search(r"'ok'", b)}
        done = set()
        for m in COL.finditer(text):
            body = text[m.start():close_of(text, m.start(), '{')]
            key, line = m.group(1), text.count('\n', 0, m.start()) + 1
            if (key, body) in done:
                continue
            done.add((key, body))
            used = [h for h in hs if re.search(r'fmt:\s*(?:(?:\([^)]*\)|\w+)\s*=>\s*)?' + h + r'\b', body)]
            if ('badge(' in body and STATUS.search(body)) or used:
                continue   # the badge scan's own
            ct = cls_text(body, ha)
            oku = [h for h in okh if re.search(r'\b' + h + r'\b', body)]
            if ct is not None:
                if not (CLS_STATUS.search(ct) and "''" in ct):
                    continue
                kind = "its cls colours some rows and returns '' on others"
            elif ('badge(' in body and "'ok'" in ' '.join(badges(body))) or oku:
                kind = 'an OK badge on some rows, no cls'
            else:
                continue
            n += 1
            why = WIDE_REVIEWED.get((name, key))
            if why is None:
                print(f"FAIL {name}:{line} '{key}': {kind}, not reviewed")
                bad += 1
                continue
            seen.add((name, key))
            if why == 'badges':
                plain = [c for c in badges(body + ''.join(okh[h] for h in oku)) if c in ("''", "'info'") or re.search(r"(?<!\?)\?\s*''|:\s*''|[?:]\s*'info'", c)]
                if plain:
                    print(f"FAIL {name}:{line} '{key}' (badges): a badge with no status class ({', '.join(plain)})")
                    bad += 1
    for k in sorted(set(WIDE_REVIEWED) - seen):
        print(f"FAIL WIDE_REVIEWED {k[0]} '{k[1]}': no such column (the list follows the source)")
        bad += 1
    print(f'{n - bad} of {n} wide status columns ok' if bad <= n else f'{bad} FAIL')
    return 1 if bad else 0

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
