#!/usr/bin/env python3
"""A status column's other cells, on the screen's side of xlsx-check's X18: each column listed below draws a warning or
critical badge on some rows, so its other value-holding cells carry a status class too - OK where the column's own check
judged the row and found nothing, N/A ('status none') where it did not judge it - set by the column's cls. The list is
the columns read one by one; a column whose other cells are empty needs no class (X18 does not judge an empty cell) and
is not listed. A column found without a cls, or not found at all, is a FAIL.

usage: x18-scan.py <the web/src folder>   prints 'ok' or 'FAIL' per column; exit 1 on any FAIL
"""
import re
import sys

# (file, key, a word on the column's line that marks it: its badge's words or the helper drawing the cell)
COLS = [
    ('admin_instances.ts', 'disabled', "'collected'"),
    ('admin_instances.ts', 'enabled', "'off'"),
    ('admin_instances.ts', 'state', "'gone from the source'"),
    ('blocking_history.ts', 'blocking_status', "badge('sleeping'"),
    ('blocking_history.ts', 'last_state', 'stateCell'),
    ('blocking_history.ts', 'state_at_peak', 'stateCell'),
    ('borrowed.ts', 'autovacuum_off', "badge('off'"),
    ('jobs_running.ts', 'last_status', "badge('aborted'"),
    ('jobs_running.ts', 'status', "v === 'ignored'"),
    ('mssql_audit.ts', 'audit_name', 'no such audit'),
    ('mssql_audit.ts', 'action', "badge('denied'"),
    ('mssql_checks.ts', 'value_set', 'not in use yet'),
    ('mssql_config.ts', 'change', "badge('removed'"),
    ('mssql_errorlog.ts', 'class', "badge('corruption'"),
    ('mssql_querystore.ts', 'new_plan', 'not seen before'),
    ('mssql_xe.ts', 'blocking_status', "badge('sleeping'"),
    ('pgaudit.ts', 'created', 'not created'),
    ('pgaudit.ts', 'fires', "badge('firing'"),
    ('roles.ts', 'bypassrls', "badge('yes'"),
    ('roles.ts', 'auth_method', "badge('trust'"),
    ('running.ts', '_head', "badge('head'"),
    ('running.ts', 'wait_event', 'waitCell'),
    ('running.ts', '_wait', 'waitCell'),
    ('vacuum.ts', 'autovacuum_enabled', 'own settings'),
]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    src = sys.argv[1].rstrip('/')
    bad = 0
    for name, key, mark in COLS:
        found = []
        with open(f'{src}/{name}', encoding='utf-8') as fh:
            for no, line in enumerate(fh, 1):
                for seg in re.split(r"(?=\{ key: ')", line):
                    if seg.startswith(f"{{ key: '{key}'") and mark in seg:
                        found.append((no, 'cls:' in seg))
        where = f"{name} '{key}'"
        if not found:
            print(f'FAIL {where}: not found (its line no longer holds {mark})')
            bad += 1
        elif not all(c for _, c in found):
            print(f"FAIL {where} L{','.join(str(n) for n, c in found if not c)}: a status badge on some rows, no cls for the other cells")
            bad += 1
        else:
            print(f"ok   {where} L{','.join(str(n) for n, _ in found)}: its other cells carry a status")
    print(f'{len(COLS) - bad} of {len(COLS)} columns ok')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
