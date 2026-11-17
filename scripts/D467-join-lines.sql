-- D467-join-lines.sql - D467's lines for the joined objects (the JOIN-FILE RULE): its migration 0343 sorts after the
-- join file and creates only its own objects (mssql_func_state, mssql_func_last, mssql_func_sample, mssql_func_read,
-- mssql_func_inline, import_mssql_funcstats, mssql_func_purge); this file holds the lines the next join file puts
-- into the objects it re-creates whole. Not a migration: nothing runs this file.

-- 1. purge()'s month-partition parents: mssql_func_read and mssql_func_sample, anywhere in its IN list (purge drops
--    by parent name, then partition - ORDER BY p.relname, c.relname - so the two go before mssql_proc_*, in the
--    order 0343's import locks them: mssql_func_read, then mssql_func_sample) -
--                         'mssql_func_read', 'mssql_func_sample',
--    Until a join file carries them, their months are not dropped (one row per read, and one per object and kind
--    that ran in the read).

-- 2. purge()'s body, beside n := n + pgvigil.mssql_plancache_purge(p_days); - the counters, the state and the
--    inlineability of an instance no longer read within the window (0092 L42-46's form) -
    n := n + pgvigil.mssql_func_purge(p_days);

-- 3. apply_roles()' owner-only list, beside 'mssql_plancache_purge' (it deletes, and the reader never calls it) -
                        'mssql_func_purge',

-- 4. What a later slice reads: a rewrite of the Procedures reader (q_mssql_procs.go) takes with it procsParts'
--    three parts - func_state (the collection's state apart from 'state', whose first row the page reads as the
--    procedures'), functions (sqlMSSQLFuncs with the inline mark from mssql_func_inline) and triggers
--    (sqlMSSQLTriggers) - and web/src/mssql_procs.ts' two sections.

-- 5. The branch: rel-d467 was cut from rel-d421 (3b57f678, then rel-d421 c5303d9e merged), so it joins after D421 and
--    takes D421's lines with it; 0343 names no object of a later migration.

-- 6. The cloud proofs' lists of every collection (each fails its 'B' row while internal/mssql registers a collection
--    its list lacks): scripts/proof-mssql-azuresqldb.sh's SKIPS gains mssql_funcstats (its skip note holds 'Azure
--    SQL Database': funcstats.go's Applies) with TABLES [mssql_funcstats]="mssql_func_last" (nothing stored);
--    scripts/proof-mssql-rds.sh's ALL gains mssql_funcstats with a verdict from its gate (perfApplies: it runs on
--    RDS - stored with status ok, NOT PROVEN until the next RDS SQL Server lab). scripts/proof-mssql-2016.sh counts
--    names against Register calls and needs no line.

-- 7. The shared docs' collection tables (D467 edits docs/sqlserver-reads.md alone): docs/sqlserver.md's collection
--    table gains, after mssql_procstats' row -
--    | `mssql_funcstats` | 5 min | what each scalar function run without inlining and each trigger did between two reads; hourly, whether each scalar function can be inlined | as `mssql_procstats` | not run | [properties, procedures, index locks](sqlserver-reads.md) |
--    and docs/sqlserver-cloud.md's Azure SQL Database row "`mssql_procstats`, `mssql_indexlocks`, `mssql_querystore`
--    | skipped (not yet)" names mssql_funcstats with them; its RDS table a row "`mssql_funcstats` | runs | not proven
--    on RDS (no lab since D467)".
