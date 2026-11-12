-- 0117 (task P08): the Summary's Memory Dump threshold, one for both engines.
--   pg_threshold_keys 'crash'  the time since the newest memory dump (SQL Server, sys.dm_server_memory_dumps) or the
--                newest crash restart (PostgreSQL, the server log): DBA Dash's Memory Dump Thresholds dialog, set at
--                the root from the Summary's Options > Memory Dumps > Configure Thresholds. Its defaults become DBA
--                Dash's: critical under 48 hours, warning under 168 (7 days); 0103 had critical under 24. The SQL
--                Server summary reads pg_threshold(instance, 'crash') for its Memory Dump cell (0070's view kept its
--                fixed 48 / 168 and is no longer read for that cell).
UPDATE pgvigil.pg_threshold_keys
   SET label = 'Memory dumps / crashes: time since the newest memory dump (SQL Server) or crash restart (PostgreSQL)',
       crit_default = 48, warn_default = 168
 WHERE key = 'crash';
