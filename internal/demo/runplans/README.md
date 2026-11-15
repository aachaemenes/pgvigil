# The demo's running plans (demo data)

The plans the demo shows on a SQL Server instance's Running queries (Plan, then the running row's Open). They are
DEMO DATA, not read from any demo instance: each was captured by `scripts/capture-demo-running-plans.sh` on a scratch
SQL Server 2022 container (16.0.4325.4, captured 2026-11-15) that ran the demo's own statement (`internal/demo/mssql_demo.go`) over tables of the demo's names,
and read from the plan cache as the `mssql_running_plans` collector reads it (`sys.dm_exec_text_query_plan` at the
statement's offsets). The page's status line says so (the stored row's `plan_note`, `mssql_runplans_demo.go`).

| file | the demo's statement | its request |
|---|---|---|
| report.sqlplan | mssqlReport (Sales) | sql01's parallel report (session 63), sql02's report |
| victim1.sqlplan | mssqlVictim1 (Sales, through sp_executesql) | sql01's first blocked session (84) |
| victim2.sqlplan | mssqlVictim2 (Sales, through sp_executesql) | sql01's second blocked session (92) |
| lookup.sqlplan | mssqlLookup (Ledger, through sp_executesql) | sql03's lookup (58) |

The demo's query and plan hashes are its own, so the seed sets each plan's StmtSimple `QueryHash` and `QueryPlanHash`
to the request's; every other byte is the capture's. The seed passes each plan through `collect.MaskXML`, the credential
mask the collector runs over every plan it sends. To capture again: `PGVIGIL_CAPTURE_OUT=internal/demo/runplans bash
scripts/capture-demo-running-plans.sh` (docker; `MSSQL_IMAGE` picks the version).
