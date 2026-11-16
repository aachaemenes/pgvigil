-- 0272: the job texts an older build stored, masked again by today's rules (task S16: the backup products' keys, a
-- value with its quotes doubled, a key cut by a read). The masking itself is Go - the step remaskJobText in
-- internal/repo/remask.go runs package internal/jobmask's rules over jobs (command), job_runs (command,
-- return_message), mssql_job_runs (message, failed_message), mssql_jobs (description, last_message, steps) and
-- job_versions (definition, its def_hash, script, changes) after this file, in its transaction. Here: no import
-- writes those tables until it commits (a collector's read waits; reads of the tables go on), locked in the order
-- the imports write them (0094: import_jobs jobs, job_runs, job_versions; import_mssql_jobs mssql_job_runs,
-- mssql_jobs, job_versions), so an import already running waits for the migrate instead of deadlocking with it.
LOCK TABLE pgvigil.jobs, pgvigil.job_runs, pgvigil.mssql_job_runs, pgvigil.mssql_jobs, pgvigil.job_versions IN SHARE ROW EXCLUSIVE MODE;
