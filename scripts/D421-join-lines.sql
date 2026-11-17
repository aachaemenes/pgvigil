-- D421-join-lines.sql - D421's lines for the joined objects (the JOIN-FILE RULE): its migration 0342 sorts after the
-- join file, so it creates and alters only what its header names (mssql_pc_extreme, mssql_pc_last.clr_us,
-- mssql_proc_sample's extremes, the two imports with their marked arms, mssql_pc_diagnostics,
-- mssql_plancache_grant_findings) and this file holds the lines the next join file puts into the objects it
-- re-creates whole. Not a migration: nothing runs this file.

-- 1. pgvigil.findings (the join file's union): one arm after mssql_plancache_findings', under the same source - the
--    Plan cache page already reads the view (sqlMSSQLPCFindings unions both); with the arm it reaches the Findings
--    pages and the alerts. One row per instance under a constant check_name and object ('wasteful memory grants',
--    'plan cache'): the count and the five largest are in the detail, which is outside the alert key, so the alert
--    is one per instance while any statement of the last 3 hours qualifies.
    UNION ALL
    -- D421 (0342): statements that ran in the last 3 hours with a grant over 1 MB of which under 10 % was used
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_plancache', at FROM pgvigil.mssql_plancache_grant_findings

-- 2. purge()'s month-partition parents: mssql_pc_extreme beside mssql_pc_read and mssql_pc_sample (it sorts before
--    both: the imports lock the three in that order) -
--                         'mssql_pc_extreme', 'mssql_pc_read', 'mssql_pc_sample',
--    Until a join file carries it, mssql_pc_extreme's months are not dropped (about 30 columns a statement and read).
--    mssql_proc_sample's 12 new columns go with its own months; mssql_pc_last.clr_us with mssql_plancache_purge's
--    rows. No new purge function and no new owner-only entry.

-- 3. What a later slice reads: a rewrite of the Plan cache and Procedures readers (q_mssql_plancache.go,
--    q_mssql_procs.go) takes these with it - top's and extremes' filter (pcFilter, pcFiltered: $6-$8), part=extremes
--    over mssql_pc_extreme with pgvigil.mssql_pc_diagnostics on the key's newest read, the findings part's union,
--    and the procedures' 12 extremes of mssql_proc_sample.

-- 4. The branch: rel-d421 was cut from rel-j16-joinfix db880b8c, not from main (main moved since with other joins):
--    it is rebased onto main once that branch has landed there; 0342 names no object of a later migration.
