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
The scan reads that a cls is there, not what it returns: each cls's values are read by review, and a cls on the
CLS_REVIEWED list is held by its pin (its text and the helpers it names), so an edit of it FAILs until it is read
again. A status column that does neither is a FAIL; a REVIEWED or CLS_REVIEWED entry that matches no status column is
a FAIL too (the list follows the source). A column's helpers are the ones its fmt names (fmt: helper, fmt: v =>
helper(...)) and, for a block-bodied fmt (fmt: (v, r) => { ... }), the ones its block calls.
Each reviewed entry is its reason and the pin of every Col it covers (pin(): the Col's text and the helpers its
check reads): an edit of a reviewed column, or a new Col under a reviewed key, FAILs until it is read again and
its pin written. Known limits (none wrong on today's tree): the bracket reader skips // comments and strings, not
/* */ comments or regex literals; a badge class held in a variable passes unread; a 'badges' entry's branches are
held by its pin, not parsed (a value drawn outside badge() is found by the read, not by the scan).

usage: x18-scan.py <the web/src folder>   prints one line per FAIL, then the counts; exit 1 on any FAIL
       x18-scan.py --wide <the web/src folder>   the columns beyond the badge scan, held by WIDE_REVIEWED; exit 1 on any FAIL
"""
import glob
import hashlib
import re
import sys

# (file, key): why the column passes without a cls. 'empty' = its other cells hold no value; 'badges' = every other
# value is a badge of class ok or none (OK / N/A).
REVIEWED = {
    ('actions.ts', 'outcome'): 'badges 82f5ac63',
    ('admin_instances.ts', 'note'): 'empty 5563eab8',
    ('admin_instances.ts', 'outcome'): 'badges 1fb0c625',
    ('alert_page.ts', 'outcome'): 'badges 12b0f788',
    ('alert_page.ts', 'severity'): 'badges 084d1cd5',
    ('alert_page.ts', 'status'): 'badges f09c04a0',
    ('alert_rules.ts', 'outcome'): 'badges b39648c8',
    ('alert_rules.ts', 'state'): 'badges 648d21db 169eaada',
    ('alerts.ts', 'last_outcome'): 'badges 7ba85e94',
    ('alerts.ts', 'min_severity'): 'badges 21678a64',
    ('alerts.ts', 'outcome'): 'badges b39648c8 d9db3c19',
    ('alerts.ts', 'severity'): 'badges 084d1cd5',
    ('alerts.ts', 'state'): 'badges 60c1dcfa b4594b1f',
    ('alerts.ts', 'status'): 'badges f7df5da8',
    ('backups.ts', 'severity'): 'badges 084d1cd5',
    ('backups.ts', 'worst'): 'badges b20e3e8d',
    ('blocking_history.ts', 'victims'): 'empty 1dac0ce8',
    ('borrowed.ts', 'checks'): 'empty 3b130397',
    ('borrowed.ts', 'severity'): 'badges 084d1cd5',
    ('borrowed.ts', 'was_blocked'): 'empty 2a395cd3',
    ('borrowed.ts', 'was_blocker'): 'empty 751b4ad7',
    ('corruption.ts', 'amcheck_corrupt'): 'empty 12cf16af',
    ('corruption.ts', 'class'): 'badges c1911a7d',
    ('corruption.ts', 'events_24h'): 'empty ce973907',
    ('corruption.ts', 'severity'): 'badges 084d1cd5',
    ('corruption.ts', 'status'): 'badges 5e43e02c',
    ('collectionperf.ts', 'outcome'): 'empty 952dc45a',
    ('collector.ts', 'outcome'): 'badges 98b66f60',
    ('collectorerrors.ts', 'type'): 'badges 6308aba5',
    ('custom.ts', 'status_rank'): 'badges f1586db7',
    ('customreports.ts', 'outcome'): 'badges c8ff2184',
    ('dbadash.ts', 'status'): 'badges 90f8e80d',
    ('drill.ts', 'checks'): 'empty 3b130397',
    ('drill.ts', 'is_wraparound'): 'empty 784dd60c',
    ('drill.ts', 'missed'): 'empty a1f45e37',
    ('drill.ts', 'problems'): 'badges c45c17df',
    ('drill.ts', 'severity'): 'badges 084d1cd5',
    ('drill.ts', 'waited_lock'): 'empty 029194cb',
    ('extensions.ts', 'outdated_dbs'): 'empty 9486db45',
    ('extensions.ts', 'severity'): 'badges 084d1cd5',
    ('host.ts', 'severity'): 'badges 084d1cd5',
    ('indexes.ts', 'is_replica'): 'empty 381a51ac',
    ('indexes.ts', 'problems'): 'badges 64ff6f8d',
    ('indexes.ts', 'readable'): 'empty bf2c7132',
    ('indexes.ts', 'severity'): 'badges 084d1cd5',
    ('investigate.ts', 'state'): 'badges 6389c105',
    ('io.ts', 'cause'): 'badges fbfeb6f0',
    ('io.ts', 'severity'): 'badges 084d1cd5',
    ('jobs_running.ts', 'outcome'): 'badges 223bc7c8',
    ('jobs_timeline.ts', 'outcome'): 'badges bcaccde4',
    ('jobsreport.ts', 'severity'): 'badges 084d1cd5',
    ('memory.ts', 'severity'): 'badges 084d1cd5',
    ('mssql_actions.ts', 'outcome'): 'badges 82f5ac63',
    ('mssql_audit.ts', 'is_enabled'): 'badges a3991de4',
    ('mssql_audit.ts', 'read_state'): 'badges a862afc8',
    ('mssql_audit.ts', 'severity'): 'badges b71107f1',
    ('mssql_audit.ts', 'state'): 'badges 6e63cd62',
    ('mssql_backups.ts', 'findings'): 'badges df6430d5',
    ('mssql_checks.ts', 'severity'): 'badges 0c43d441 e90cf8c8',
    ('mssql_deadlocks.ts', 'severity'): 'badges 084d1cd5',
    ('mssql_deadlocks.ts', 'victim'): 'empty 2a3553bb',
    ('mssql_errorfleet.ts', 'severity'): 'badges 9c6c39c5',
    ('mssql_errorlog.ts', 'severity'): 'badges 0ac11868 b71107f1',
    ('mssql_errorlog.ts', 'state'): 'badges c9052225',
    ('mssql_hadr.ts', 'severity'): 'badges 084d1cd5',
    ('mssql_indexes.ts', 'is_disabled'): 'empty 43c8d3e9',
    ('mssql_indexes.ts', 'marked'): 'empty 47827c67',
    ('mssql_indexes.ts', 'rule'): 'badges 703ac9d4 f96a25fa',
    ('mssql_indexes.ts', 'severity'): 'badges fcefaf09',
    ('mssql_indexes.ts', 'state'): 'badges a0925d27',
    ('mssql_perf.ts', 'severity'): 'badges 084d1cd5',
    ('mssql_plancache.ts', 'severity'): 'badges f3ecc757',
    ('mssql_querystore.ts', 'forced'): 'empty 0826182a 337baa63',
    ('mssql_querystore.ts', 'paged'): 'badges 17b1728c',
    ('mssql_querystore.ts', 'severity'): 'badges 349be0e1 77d4d69b b71107f1 f4deb268',
    ('mssql_rowversions.ts', 'severity'): 'badges 084d1cd5',
    ('mssql_running.ts', 'implicit'): 'empty bc87cec6',
    ('mssql_running.ts', 'is_implicit_tran'): 'empty 0c2a44f6',
    ('mssql_running.ts', 'victims'): 'empty 4d16c36b 525ab77d f72383ea',
    ('mssql_security.ts', 'default_severity'): 'badges 048cdd29',
    ('mssql_security.ts', 'severity'): 'badges b71107f1',
    ('mssql_security.ts', 'status'): 'badges c9c7eba0',
    ('mssql_security.ts', 'verdict'): 'badges 1de1e940',
    ('mssql_statsio.ts', 'change'): 'badges bef4780a',
    ('mssql_storage.ts', 'severity'): 'badges 084d1cd5',
    ('mssql_summary.ts', 'severity'): 'badges 0c43d441',
    ('mssql_waits.ts', 'severity'): 'badges 084d1cd5',
    ('mssql_xe.ts', 'band'): 'empty 46b7bf3e',
    ('mssql_xe.ts', 'is_failover'): 'empty 35f67166',
    ('mssql_xe.ts', 'severity'): 'badges 084d1cd5',
    ('mssql_xe.ts', 'state'): 'badges 935653eb',
    ('mssql_xe.ts', 'victim'): 'empty 2a3553bb',
    ('pages.ts', 'check_name'): 'badges 49e790d8 6c4ba37e 8891a3e4 5f1c09ce',
    ('pages.ts', 'kind'): 'badges 70c64dbd ebff03ab',
    ('pages.ts', 'severity'): 'badges ee154bef',
    ('pages.ts', 'status'): 'badges 00b289df 16323a2a',
    ('pg_backups.ts', 'all_tables'): 'badges eed4fa00',
    ('pg_backups.ts', 'caught_up'): 'badges 86fbbe1f',
    ('pg_backups.ts', 'change'): 'badges 52dd7ead',
    ('pg_backups.ts', 'enabled'): 'badges d35c892e',
    ('pg_backups.ts', 'ok'): 'badges 7c708bb7',
    ('pg_backups.ts', 'paused'): 'empty 30610ac5',
    ('pg_backups.ts', 'pending_restart'): 'empty 093c4df8',
    ('pg_backups.ts', 'replay_paused'): 'empty eb9a5382',
    ('pg_backups.ts', 'secret_seen'): 'empty d2e805bf',
    ('pg_backups.ts', 'severity'): 'badges 0c43d441',
    ('pg_backups.ts', 'state'): 'badges 5d2a357c f7384f4c',
    ('pg_backups.ts', 'status'): 'badges 25e18d9e 3ca3269c',
    ('pg_dboptions.ts', 'severity'): 'badges 0c43d441',
    ('pg_deadlocks.ts', 'victim'): 'empty 2a3553bb',
    ('pgconfig.ts', 'pending_restart'): 'empty 662dbbd1',
    ('pi.ts', 'severity'): 'badges 084d1cd5',
    ('plan.ts', 'severity'): 'badges 084d1cd5',
    ('reportmail.ts', 'outcome'): 'badges cb8206a7 e8524801',
    ('reports.ts', 'victim'): 'empty 818b3f27',
    ('roles.ts', 'error'): 'empty 83776b9e',
    ('running.ts', '_behind'): 'empty 6a7a4e50',
    ('schema.ts', 'change'): 'badges 37e9f768',
    ('schema.ts', 'severity'): 'badges 084d1cd5',
    ('sessionsets.ts', 'fires'): 'empty 522266c5',
    ('slow.ts', 'result'): 'badges 61343366',
    ('slow.ts', 'status'): 'badges 19d857b3',
    ('storage.ts', 'severity'): 'badges 084d1cd5',
    ('vacuum.ts', 'severity'): 'badges 084d1cd5',
    ('versions.ts', 'collation_mismatches'): 'empty 7fba056e',
    ('versions.ts', 'extensions_outdated'): 'empty 480a1001',
    ('versions.ts', 'mismatch'): 'empty a4abd7db',
    ('versions.ts', 'pending_actions'): 'badges 22a0581d',
    ('versions.ts', 'severity'): 'badges 084d1cd5',
    ('waits.ts', 'blocked'): 'empty 2996049c',
    ('waits.ts', 'event_type'): 'badges b8833291',
    ('waits.ts', 'severity'): 'badges d218a0a0',
}

# (file, key): a badge-drawn status column's cls, read one by one (the join's review 6 #3, the lead's 15:07): OK where the
# column's check judged the row and found nothing, N/A where it did not judge it, '' on its warning / critical badge and
# on an empty cell. The pin is the cls as written and the helpers it names (cls_text); a cls not on this list passes on
# its presence alone, as before.
CLS_REVIEWED = {
    ('admin_instances.ts', 'aws'): 'cls 33f56ed4',
    ('alert_rules.ts', 'holds_now'): 'cls fce08f6e',
    ('community.ts', 'kit_version'): 'cls 4bda06b9',
    ('investigate.ts', 'investigate'): 'cls 90a3b73f',
    ('mssql_querystore.ts', 'stale_at_compile'): 'cls 58590af1',
    ('mssql_security.ts', 'days_until_expiration'): 'cls b870bf51',
    ('mssql_security.ts', 'expires_at'): 'cls 07363121',
    ('mssql_security.ts', 'has_login'): 'cls 9292d35f',
    ('mssql_security.ts', 'public_granted'): 'cls 5b8a8df2',
    ('mssql_storage.ts', 'days_until_full'): 'cls 72d937bd',
    ('mssql_storage.ts', 'free_pct'): 'cls b60d873c',
    ('mssql_storage.ts', 'path'): 'cls 8201c730',
    ('pg_backups.ts', 'api_ok'): 'cls 42cfc928',
    ('pg_backups.ts', 'leader'): 'cls db8942cf',
    ('pg_backups.ts', 'receiver_status'): 'cls 79f3bd4c',
    ('pg_backups.ts', 'worker_pid'): 'cls 16236e5a',
    ('schema.ts', 'mssql_state'): 'cls 1816b638',
}


def pin(text):
    """a reviewed column's pin: its Col literal and the helpers its check reads, white space folded - any edit of
    them changes it, so the column fails until it is read again and its new pin written beside its reason"""
    return hashlib.sha1(re.sub(r'\s+', ' ', text).strip().encode()).hexdigest()[:8]


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


FMT_ARROW = re.compile(r'fmt:\s*(?:\([^)]*\)|\w+)\s*=>\s*\{')   # a block-bodied fmt: (v, r) => { ... }


def fmt_helpers(body, hs):
    """the helpers of hs a Col's fmt draws with, in the file's order: the one its fmt names (fmt: h, fmt: v => h...),
    and each one a block-bodied fmt calls (the join's review 6: alerts.ts last_outcome's fmt became a block, and the
    scan lost its helper)"""
    used = {h for h in hs if re.search(r'fmt:\s*(?:(?:\([^)]*\)|\w+)\s*=>\s*)?' + h + r'\b', body)}
    m = FMT_ARROW.search(body)
    if m:
        code = re.sub(r"'[^'\\]*'", "''", body[m.end() - 1:close_of(body, m.end() - 1, '{')])   # a name in a string is no call
        used |= {h for h in hs if re.search(r'\b' + h + r'\s*\(', code)}
    return [h for h in hs if h in used]


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
    ('actions.ts', '_actions'): 'nostatus e7b95ab7',
    ('alert_rules.ts', 'source'): 'badges 4f2e4905',
    ('alerts.ts', '_act'): 'nostatus acbd612e',
    ('alerts.ts', 'state'): 'badges 60c1dcfa b4594b1f',
    ('backups.ts', 'archive_age_s'): 'cls ea109b23',
    ('backups.ts', 'archiver_failing'): 'cls dce7387c',
    ('filedrop.ts', 'actRows'): 'cls a2533674',
    ('filedrop.ts', 'share'): 'cls e101b49e',
    ('filedrop.ts', 'warnings'): 'empty 563067f8',
    ('host.ts', 'free_bytes'): 'cls 05ec5fde',
    ('indexes.ts', 'bloat_pct'): 'cls 0162a06f',
    ('indexes.ts', 'pct_used'): 'cls 864eaf01',
    ('indexes.ts', 'uses_index'): 'badges ec12aa54',
    ('io.ts', 'blks_read'): 'cls 2eaa2a03',
    ('jobs_fleet_status.ts', '_since_fail'): 'cls 714fb96f',
    ('jobs_fleet_status.ts', 'job_name'): 'cls 53a892a9',
    ('jobs_fleet_status.ts', 'last_failed_at'): 'cls f2c34ee2',
    ('jobs_fleet_status.ts', 'outcome'): 'empty c64e016a',
    ('jobsreport.ts', 'last_start'): 'cls 58209f21',
    ('mssql_actions.ts', 'state'): 'badges b4594b1f',
    ('mssql_backups.ts', 'ag_name'): 'empty c107e5db',
    ('mssql_backups.ts', 'diff_at'): 'cls 02a8bc7a',
    ('mssql_backups.ts', 'diff_status'): 'empty 5a9cdeff',
    ('mssql_backups.ts', 'full_age_hours'): 'cls 9f96ddb1',
    ('mssql_backups.ts', 'full_at'): 'cls 9dbfe71f',
    ('mssql_backups.ts', 'full_status'): 'cls 92e93e17',
    ('mssql_backups.ts', 'log_age_minutes'): 'cls ec7a8ab2',
    ('mssql_backups.ts', 'log_at'): 'cls 52a75463',
    ('mssql_backups.ts', 'log_status'): 'empty d294b3ef',
    ('mssql_backups.ts', 'nul_at'): 'empty 6b8c7d95',
    ('mssql_checks.ts', 'i'): 'cls ada33c32',
    ('mssql_checks.ts', 'is_on'): 'cls 25da1cc2',
    ('mssql_checks.ts', 'notifies'): 'cls be2af013',
    ('mssql_checks.ts', 'opt_'): 'cls 7c761477',
    ('mssql_checks.ts', 'pct_used'): 'cls e7d14473',
    ('mssql_checks.ts', 'value'): 'cls 1681dfa0 e8187ee3',
    ('mssql_checks.ts', 'value_in_use'): 'cls a03e223e',
    ('mssql_errorlog.ts', 'access_violation'): 'cls fb98d110',
    ('mssql_errorlog.ts', 'bad_pages_detected'): 'cls f94f9dc0',
    ('mssql_errorlog.ts', 'deadlocked_schedulers'): 'cls a597f7ea',
    ('mssql_errorlog.ts', 'dump_requests'): 'cls fb4840be',
    ('mssql_errorlog.ts', 'duration_ms'): 'cls d06e29df d8eb15e9',
    ('mssql_errorlog.ts', 'failure_type'): 'empty 54670c8e',
    ('mssql_errorlog.ts', 'interval_long_ios'): 'cls 248f2125',
    ('mssql_errorlog.ts', 'io_latch_timeouts'): 'cls 2dbf8880',
    ('mssql_errorlog.ts', 'is_process_physical_memory_low'): 'cls 4803282b',
    ('mssql_errorlog.ts', 'is_process_virtual_memory_low'): 'cls 36c2fb67',
    ('mssql_errorlog.ts', 'is_system_physical_memory_low'): 'cls be6ace79',
    ('mssql_errorlog.ts', 'last_notification'): 'cls 55e9a3cc f533de1f',
    ('mssql_errorlog.ts', 'latch_warnings'): 'cls 069c210b',
    ('mssql_errorlog.ts', 'memory_utilization'): 'cls d96dd221',
    ('mssql_errorlog.ts', 'non_yielding'): 'cls 19f5c39e',
    ('mssql_errorlog.ts', 'notification'): 'cls 466bcf57',
    ('mssql_errorlog.ts', 'oom_exceptions'): 'cls 0fef28d4',
    ('mssql_errorlog.ts', 'other_cpu'): 'cls cf631f48',
    ('mssql_errorlog.ts', 'pending_tasks'): 'cls 1371bd82 eae25722',
    ('mssql_errorlog.ts', 'pool_out_of_memory'): 'cls 83939b4b',
    ('mssql_errorlog.ts', 'process_memory_low'): 'cls 6370e0c2',
    ('mssql_errorlog.ts', 'process_virtual_low'): 'cls 69c55d91',
    ('mssql_errorlog.ts', 'severity'): 'cls 4d64e688 df8f139b',
    ('mssql_errorlog.ts', 'sick_spinlock'): 'empty 4fb2a597',
    ('mssql_errorlog.ts', 'slow'): 'cls 590172ae',
    ('mssql_errorlog.ts', 'sql_cpu'): 'cls 1a90399c 3e1a19d9 770f8568',
    ('mssql_errorlog.ts', 'system_memory_low'): 'cls a7e6a2ec',
    ('mssql_errorlog.ts', 'unresolvable_deadlock'): 'cls 84834bdf',
    ('mssql_errorlog.ts', 'write_access_violations'): 'cls 93a5c26a',
    ('mssql_hadr.ts', 'age_minutes'): 'cls fde053d4',
    ('mssql_hadr.ts', 'connected_state'): 'cls b8405fce',
    ('mssql_hadr.ts', 'member_state'): 'cls f9e59946',
    ('mssql_hadr.ts', 'state'): 'cls 992c73cc',
    ('mssql_hadr.ts', 'status'): 'cls 7a5b33e3',
    ('mssql_hadr.ts', 'synchronization_health'): 'cls cf6bc5ae',
    ('mssql_hadr.ts', 'synchronization_state'): 'cls 8d98cf68',
    ('mssql_indexes.ts', 'benefit_per_day'): 'cls 20e6d76c',
    ('mssql_jobs.ts', '_status'): 'cls 7a0413a6',
    ('mssql_jobs.ts', 'last_failure'): 'cls d6ca7221',
    ('mssql_jobs.ts', 'last_run_at'): 'cls 1d169e9d',
    ('mssql_jobs.ts', 'last_run_utc'): 'empty cb71746a',
    ('mssql_jobs.ts', 'name'): 'cls 43c6afdc',
    ('mssql_perf.ts', 'read_ms'): 'cls 6b2b226d',
    ('mssql_perf.ts', 'write_ms'): 'cls 78ed701b',
    ('mssql_plancache.ts', 'compiled_24h_pct'): 'cls cf1215e4',
    ('mssql_plancache.ts', 'duplicate_pct'): 'cls 72b2aeb6',
    ('mssql_plancache.ts', 'single_use_pct'): 'cls b9904801',
    ('mssql_querystore.ts', 'actual_state'): 'cls 7c707b1c bb2238bc',
    ('mssql_querystore.ts', 'cpu_ratio'): 'cls f4971074',
    ('mssql_querystore.ts', 'duration_ratio'): 'cls ae44a04c',
    ('mssql_querystore.ts', 'force_failure_count'): 'cls bfc8d4e5 f9b23777',
    ('mssql_querystore.ts', 'forced'): 'empty 0826182a 337baa63',
    ('mssql_querystore.ts', 'severity'): 'cls 349be0e1 47e5ffff 4d64e688 961b609a',
    ('mssql_storage.ts', 'free_bytes'): 'cls 4e6debe5',
    ('pages.ts', 'waiting_lock'): 'empty 2fdbe6b7 9e3b8c0c aa88604e',
    ('perfsummary.ts', 'cpu_max'): 'cls 9d1525ef',
    ('perfsummary.ts', 'lock_ms_s'): 'cls d02e499e',
    ('pg_backups.ts', 'datname'): 'nostatus 17e1b34d 45641b60',
    ('pg_backups.ts', 'key'): 'nostatus 16a8c4f4 8d731af7',
    ('pg_backups.ts', 'postmaster_restarted'): 'nostatus a6dd4d3e',
    ('pg_backups.ts', 'role'): 'badges 04a63304 f6bf9538',
    ('pg_backups.ts', 'sync_state'): 'badges 2ef18652',
    ('pg_backups.ts', 'worst'): 'badges f72b6c6d',
    ('pg_dboptions.ts', 'server_text'): 'cls 72268dc0',
    ('pg_dboptions.ts', 'value_text'): 'cls 8e2eacdd',
    ('pgconfig.ts', 'value'): 'cls 5e78c97c b6dbb831',
    ('pooler.ts', 'cl_waiting'): 'cls 3bf78521 8bc70a85',
    ('pooler.ts', 'clients_waiting'): 'cls 4682b99f',
    ('reportmail.ts', 'enabled'): 'badges d91ba281',
    ('reportmail.ts', 'last_outcome'): 'badges 72566702',
    ('reports.ts', 'days_until_expiration'): 'cls c2a74ea1',
    ('reports.ts', 'expired'): 'cls b040287b',
    ('reports.ts', 'expiring'): 'cls 9dd64648',
    ('reports.ts', 'i:'): 'cls 7e12d6e1',
    ('reports.ts', 'ifi_enabled'): 'cls 5a719961',
    ('reports.ts', 'is_expired'): 'cls 7217b587',
    ('reports.ts', 'is_locked'): 'cls 46065e6e',
    ('reports.ts', 'l:'): 'cls 5ffd0b5a',
    ('reports.ts', 'max_age'): 'cls 3448fd99',
    ('reports.ts', 'md5'): 'cls cda18a91',
    ('reports.ts', 'outcome'): 'empty bd6350af',
    ('reports.ts', 'password_age_days'): 'cls 4e6ab10c',
    ('reports.ts', 'snapshot_at'): 'empty 2160cd30 8a3310ec ac78bd43',
    ('reports.ts', 'startup_type'): 'cls 47ceb418',
    ('reports.ts', 'status'): 'empty 1365aec6 69c2c32e c62f5cf1',
    ('retention.ts', 'actual_days'): 'cls 26764b08',
    ('retention.ts', 'retention'): 'cls 24efbe43',
    ('schema.ts', 'ddl_log'): 'badges 61782393',
    ('statements.ts', 'jit_pct'): 'cls 79cc5eee',
    ('statements.ts', 'plan_pct'): 'cls c67651f7',
    ('statements.ts', 'workers_missing'): 'cls af98c356',
    ('storage.ts', 'free_bytes'): 'cls 4e6debe5',
    ('vacuum.ts', 'anl_ratio'): 'cls 75c89c70',
    ('vacuum.ts', 'dead_ratio'): 'cls 0cfe2691',
    ('vacuum.ts', 'elapsed_secs'): 'cls 48df5b51 6c6fcc68',
    ('vacuum.ts', 'freeze_pct'): 'cls 03f396b2',
    ('vacuum.ts', 'hours_over'): 'cls 390ca908',
    ('vacuum.ts', 'ins_ratio'): 'cls af13da2b',
    ('vacuum.ts', 'mxid_freeze_pct'): 'cls 3c452954',
    ('vacuum.ts', 'xid_freeze_pct'): 'cls 345e3ab6',
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
            used = fmt_helpers(body, hs)
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
                print(f"FAIL {name}:{line} '{key}': {kind}, not reviewed (its pin once read: {pin(body + (ct or '') + ''.join(okh[h] for h in oku))})")
                bad += 1
                continue
            seen.add((name, key))
            why, pins = why.split()[0], why.split()[1:]
            got = pin(body + (ct or '') + ''.join(okh[h] for h in oku))
            if got not in pins:
                print(f"FAIL {name}:{line} '{key}' ({why}): changed since it was read (pin {got}): read it again, then pin it")
                bad += 1
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
    bad, n, seen, cseen = 0, 0, set(), set()
    for path in sorted(glob.glob(f'{src}/*.ts')):
        name = path.split('/')[-1]
        if '.test.' in name:
            continue
        text = open(path, encoding='utf-8').read()
        hs, ha = helpers(text), all_helpers(text)
        for m in COL.finditer(text):
            body = text[m.start():close_of(text, m.start(), '{')]
            key = m.group(1)
            used = fmt_helpers(body, hs)
            if not (('badge(' in body and STATUS.search(body)) or used):
                continue
            n += 1
            line = text.count('\n', 0, m.start()) + 1
            if 'cls:' in body:
                why = CLS_REVIEWED.get((name, key))
                if why is not None:
                    cseen.add((name, key))
                    got = pin(cls_text(body, ha))
                    if got not in why.split()[1:]:
                        print(f"FAIL {name}:{line} '{key}' (cls): changed since it was read (pin {got}): read it again, then pin it")
                        bad += 1
                continue
            why = REVIEWED.get((name, key))
            if why is None:
                print(f"FAIL {name}:{line} '{key}': a status column without a cls, not reviewed (its pin once read: {pin(body + ''.join(hs[h] for h in used))})")
                bad += 1
                continue
            seen.add((name, key))
            why, pins = why.split()[0], why.split()[1:]
            got = pin(body + ''.join(hs[h] for h in used))
            if got not in pins:
                print(f"FAIL {name}:{line} '{key}' ({why}): changed since it was read (pin {got}): read it again, then pin it")
                bad += 1
            plain = [c for c in badges(body + ''.join(hs[h] for h in used)) if c in ("''", "'info'") or re.search(r"(?<!\?)\?\s*''|:\s*''|[?:]\s*'info'", c)]
            if plain:
                print(f"FAIL {name}:{line} '{key}' ({why}): a badge with no status class ({', '.join(plain)})")
                bad += 1
    for k in sorted(set(REVIEWED) - seen):
        print(f"FAIL REVIEWED {k[0]} '{k[1]}': no status column of that key without a cls (the list follows the source)")
        bad += 1
    for k in sorted(set(CLS_REVIEWED) - cseen):
        print(f"FAIL CLS_REVIEWED {k[0]} '{k[1]}': no status column of that key with a cls (the list follows the source)")
        bad += 1
    print(f'{n - bad} of {n} status columns ok' if bad <= n else f'{bad} FAIL')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
