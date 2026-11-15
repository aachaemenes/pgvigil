#!/usr/bin/env bash
# Proof of task 413 (B22): sessions and connections. One SQL Server container per run (MSSQL_IMAGE; the box job runs
# it once per version: 2017, 2019, 2022, 2025), a repository database of its own, pgvigil built from this tree.
# Needs: docker, go, psql, curl, python3, and:
#   ADMIN_DSN       a superuser connection to a PostgreSQL sandbox in KEYWORD form (default 'host=127.0.0.1 port=5432
#                   user=postgres dbname=postgres'); the proof makes its own repository database and drops it; every
#                   other connection string is ADMIN_DSN with user / password / dbname appended (never a fixed port)
#   MSSQL_IMAGE     the SQL Server image (default mcr.microsoft.com/mssql/server:2022-latest)
#   PGVIGIL_PARTS   the parts to run (default every part this file has)
#   PGVIGIL_WIRING  1 (default) applies scripts/proof-mssql-sessions-wiring.patch (activity.go's grouping sets, web.go,
#                   mssql_perf.ts, 0190: the lead's files) to this copy when the tree lacks them.
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch.
#
# Expected (written before the first run; the user / system rule of P1, P1b and A3 waits on the lead's answer to the
# 09:1x question and is written in before the first run of those rows):
#  A. the container: a monitor login (VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE); three logins
#     l1-l3; database pgvss with dbo.t (100,000 rows) and dbo.hold (one row).
#  P2 requests by status: a held set - a request blocked on dbo.hold (suspended, LCK_M_*), a WAITFOR DELAY (suspended,
#     WAITFOR), a CPU loop (running or runnable), a sleeping session with an open transaction - read by mssql_sessions:
#     the stored counts of running + runnable, suspended, sleeping and background equal a hand read of
#     sys.dm_exec_requests taken before and after the collector's read in the same minute (both hand reads equal, or
#     the cycle is retried, at most 5 cycles).
#  P4 waiting tasks: the blocked request counted in waiting tasks with its wait; the WAITFOR (a benign wait of
#     waits.go benignWaits) not counted; the longest wait at least the blocked request's hand-read wait_duration_ms.
#  P5 top-N over a range: a known heavy request (a CPU loop of 20 s, a scan of dbo.t with 50,000+ logical reads, a sort
#     spilling to tempdb, a memory grant of 50 MB+) captured by mssql_requests over its minutes: GET
#     /api/mssql/sessions/top over the range lists it at rank 1 of CPU, reads, tempdb and grant (its session and login),
#     the statement under the query_text policy (full: the text; none: no text, the policy's words); the reply says the
#     snapshot keeps user requests and sessions with an open transaction only.
#  P6 'other': 55 logins each holding one session: the login dimension holds 50 named rows and one 'other' row whose
#     sessions are the other 5 (+ any login past them), 'other' made by GROUPING() (a login named 'other' stays a named
#     row of its own).
#  P7 the page: proof-a11y 0 nodes and proof-wording OK on the Connections page with the wiring (the walks job); the
#     active-transactions chart off with its reason ('needs the Databases counters collector, mssql_counters_db') while
#     401 is not joined; every new control works or is off with its reason.
#  A6 the read's time: 5,000 sessions held open (from the box's own client pool), the groups read and the per-minute
#     read each timed 3 times: printed as MEASURE lines with the rows and bytes each read stores; a read over 5 s FAILs
#     the row (the collector budget's share).
#  Red on f8e89d2 (before 413): collect refuses mssql_sessions (unknown collection); no route /api/mssql/sessions/top;
#  no 'login' group in the activity read's rows.
set -euo pipefail
echo "FAIL: the proof body is written after the lead's answer on the user / system rule (the header above is the expected)" >&2
exit 2
