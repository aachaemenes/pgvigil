-- 0130: Amazon RDS for SQL Server's Agent alerts and operators, stored by earlier releases, removed (CLOUDSQL C3-2).
-- AWS's 'Using SQL Server Agent for Amazon RDS': "SQL Server Agent alerts and operators aren't supported." The
-- checks no longer read the alerts area on RDS (internal/mssql agentalerts.go), so a store that read an RDS Web,
-- Standard or Enterprise instance before keeps its 'no alerts for severity 19 to 25', 'no operator' and other alerts
-- findings for good (0090: an area not read keeps its findings, and the unread area's row is refreshed every run).
-- Removed here once: the alerts area's findings and the alert, operator and fail-safe rows of every rdssqlserver
-- instance. Nothing new is stored for them after this release. Running it again changes nothing.
DELETE FROM pgvigil.mssql_check_finding f USING pgvigil.instances i
 WHERE f.instance_id = i.instance_id AND i.platform = 'rdssqlserver' AND f.area = 'alerts';
DELETE FROM pgvigil.mssql_agent_alert a USING pgvigil.instances i
 WHERE a.instance_id = i.instance_id AND i.platform = 'rdssqlserver';
DELETE FROM pgvigil.mssql_agent_operator o USING pgvigil.instances i
 WHERE o.instance_id = i.instance_id AND i.platform = 'rdssqlserver';
DELETE FROM pgvigil.mssql_agent_alerting g USING pgvigil.instances i
 WHERE g.instance_id = i.instance_id AND i.platform = 'rdssqlserver';
