-- capture.sql - the workload capture.sh runs on a throwaway SQL Server 2022 container to take real plans for the
-- plan-warning rules (internal/plans/mssqlwarn.go). Invented names only: the database warnlab and its tables.
--
-- Shape: everything before the first '--@case' line is the setup, run once as sa (GO separates its batches).
-- Each case after it:
--   --@case <name> runs=<n> [timeout=<s>]   the case and how many times it executes (0 = the estimated plan only)
--   --@pre <one batch>                       a batch run first in the same session (a session trace flag)
--   the case's batch                         up to the next '--@' line; its plan-bearing statement holds the marker
--                                            /* case:<name> */, which capture.sh finds in the estimated plan's
--                                            StatementText to read that statement's QueryHash
-- Every case is one ad hoc batch with one plan-bearing statement (a cursor's or a table variable's batch carries its
-- DECLARE beside it) and, for each rule it aims at, one candidate operator. Hits and near misses differ in shape, not
-- only in a literal, so their QueryHash differs.

CREATE DATABASE warnlab;
GO
ALTER DATABASE warnlab SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE warnlab SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL, INTERVAL_LENGTH_MINUTES = 1);
GO
USE warnlab;
GO
ALTER DATABASE SCOPED CONFIGURATION SET LAST_QUERY_PLAN_STATS = OFF;
GO
SELECT TOP (500000) IDENTITY(int, 1, 1) AS n INTO dbo.nums FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b;
CREATE UNIQUE CLUSTERED INDEX cx_nums ON dbo.nums (n);
GO
CREATE TABLE dbo.big (id int NOT NULL PRIMARY KEY, k int NOT NULL, v int NOT NULL, s varchar(20) NOT NULL, pad char(200) NOT NULL);
INSERT dbo.big (id, k, v, s, pad) SELECT n, n % 1000, n % 7919, CONCAT('s', n % 50000), 'x' FROM dbo.nums WHERE n <= 200000;
CREATE INDEX ix_big_k ON dbo.big (k);
CREATE INDEX ix_big_s ON dbo.big (s);
CREATE TABLE dbo.big2 (id int NOT NULL PRIMARY KEY, k int NOT NULL, v int NOT NULL, pad char(100) NOT NULL);
INSERT dbo.big2 (id, k, v, pad) SELECT n, n % 500, n % 997, 'y' FROM dbo.nums WHERE n <= 50000;
CREATE TABLE dbo.np_t (id int NOT NULL PRIMARY KEY, v int NOT NULL, pad char(200) NOT NULL);
INSERT dbo.np_t (id, v, pad) SELECT n, n % 100, 'z' FROM dbo.nums WHERE n <= 300000;
CREATE TABLE dbo.heap_t (id int NOT NULL, k int NOT NULL, pad char(100) NOT NULL);
INSERT dbo.heap_t (id, k, pad) SELECT n, n % 1000, 'h' FROM dbo.nums WHERE n <= 50000;
CREATE INDEX ix_heap_k ON dbo.heap_t (k);
CREATE TABLE dbo.spool_src (k int NOT NULL, v int NOT NULL);
INSERT dbo.spool_src (k, v) SELECT n % 500, n FROM dbo.nums WHERE n <= 20000;
CREATE TABLE dbo.tiny (k int NOT NULL PRIMARY KEY, v int NOT NULL);
INSERT dbo.tiny (k, v) SELECT n, n FROM dbo.nums WHERE n <= 10;
CREATE TABLE dbo.hier_t (id int NOT NULL PRIMARY KEY, h hierarchyid NOT NULL);
INSERT dbo.hier_t (id, h) SELECT n, hierarchyid::Parse(CONCAT('/', n % 10 + 1, '/', n % 7 + 1, '/')) FROM dbo.nums WHERE n <= 1000;
CREATE TABLE dbo.cs_fact (id int NOT NULL, k int NOT NULL, amount decimal(12, 2) NOT NULL, region int NOT NULL);
INSERT dbo.cs_fact (id, k, amount, region) SELECT n, 1 + n % 200000, n % 1000 / 10.0, n % 20 FROM dbo.nums WHERE n <= 500000;
CREATE CLUSTERED COLUMNSTORE INDEX ccx_cs_fact ON dbo.cs_fact;
CREATE TABLE dbo.five_ix (id int NOT NULL PRIMARY KEY, a int NOT NULL, b int NOT NULL, c int NOT NULL, d int NOT NULL);
INSERT dbo.five_ix (id, a, b, c, d) SELECT n, n, n, n, n FROM dbo.nums WHERE n <= 50000;
CREATE INDEX ix5_a ON dbo.five_ix (a);
CREATE INDEX ix5_b ON dbo.five_ix (b);
CREATE INDEX ix5_c ON dbo.five_ix (c);
CREATE INDEX ix5_d ON dbo.five_ix (d);
CREATE TABLE dbo.four_ix (id int NOT NULL PRIMARY KEY, a int NOT NULL, b int NOT NULL, c int NOT NULL, d int NOT NULL);
INSERT dbo.four_ix (id, a, b, c, d) SELECT n, n, n, n, n FROM dbo.nums WHERE n <= 50000;
CREATE INDEX ix4_a ON dbo.four_ix (a);
CREATE INDEX ix4_b ON dbo.four_ix (b);
CREATE INDEX ix4_c ON dbo.four_ix (c);
CREATE TABLE dbo.skew_t (id int NOT NULL PRIMARY KEY, k int NOT NULL);
INSERT dbo.skew_t (id, k) SELECT n, CASE WHEN n <= 197000 THEN 1 ELSE n - 196998 END FROM dbo.nums WHERE n <= 200000;
CREATE TABLE dbo.ddl_src (id int NOT NULL PRIMARY KEY, v int NOT NULL);
INSERT dbo.ddl_src (id, v) SELECT n, n FROM dbo.nums WHERE n <= 1000;
GO
-- stale statistics: a statistic made over 10 rows, NORECOMPUTE, then 200,000 (or 50,000) rows added; the statement
-- reads only that statistic
CREATE TABLE dbo.stale_hi (k int NOT NULL);
INSERT dbo.stale_hi (k) SELECT n FROM dbo.nums WHERE n <= 10;
CREATE STATISTICS st_hi ON dbo.stale_hi (k) WITH FULLSCAN, NORECOMPUTE;
INSERT dbo.stale_hi (k) SELECT 1 FROM dbo.nums WHERE n <= 200000;
CREATE TABLE dbo.stale_lo (k int NOT NULL);
INSERT dbo.stale_lo (k) SELECT n FROM dbo.nums WHERE n <= 10;
CREATE STATISTICS st_lo ON dbo.stale_lo (k) WITH FULLSCAN, NORECOMPUTE;
INSERT dbo.stale_lo (k) SELECT 1 FROM dbo.nums WHERE n <= 50000;
GO
-- twenty small tables for the compile cases
DECLARE @i int = 1, @t sysname;
WHILE @i <= 20
BEGIN
    SET @t = CONCAT(N'dbo.j', RIGHT(CONCAT(N'0', @i), 2));
    EXEC (N'CREATE TABLE ' + @t + N' (id int NOT NULL PRIMARY KEY, fk int NOT NULL, v int NOT NULL, w int NOT NULL); INSERT ' + @t + N' (id, fk, v, w) SELECT n, 1 + n % 97, n % 13, n % 7 FROM dbo.nums WHERE n <= 100; CREATE INDEX ix_v ON ' + @t + N' (v);');
    SET @i += 1;
END;
GO
CREATE FUNCTION dbo.f_scalar (@k int) RETURNS int WITH INLINE = OFF AS BEGIN RETURN @k % 3; END;
GO
CREATE FUNCTION dbo.f_slow (@n int) RETURNS int WITH INLINE = OFF AS
BEGIN
    DECLARE @i int = 0, @x int = 0;
    WHILE @i < @n BEGIN SET @x = (@x + @i) % 7; SET @i += 1; END;
    RETURN @x;
END;
GO
CREATE FUNCTION dbo.f_mstvf (@m int) RETURNS @r TABLE (k int NOT NULL) AS
BEGIN
    INSERT @r (k) SELECT DISTINCT k FROM dbo.big2 WHERE k % @m = 0;
    RETURN;
END;
GO
CREATE TABLE dbo.cc_t (id int NOT NULL PRIMARY KEY, k int NOT NULL, c AS dbo.f_scalar(k));
INSERT dbo.cc_t (id, k) SELECT n, n FROM dbo.nums WHERE n <= 5000;
GO

--@case clean runs=2
SELECT /* case:clean */ id, v FROM dbo.big WHERE id = 5;
--@case ic_seek runs=2
SELECT /* case:ic_seek */ id FROM dbo.big WHERE s = N's123';
--@case ic_none runs=2
SELECT /* case:ic_none */ id, k FROM dbo.big WHERE s = 's123';
--@case lookup_hit runs=2
SELECT /* case:lookup_hit */ pad FROM dbo.big WHERE k BETWEEN 1 AND 4;
--@case lookup_cheap runs=2
SELECT /* case:lookup_cheap */ pad, v FROM dbo.big WHERE k = 7;
--@case rid_lookup runs=2
SELECT /* case:rid_lookup */ pad FROM dbo.heap_t WHERE k = 3;
--@case missing_ix runs=2
SELECT /* case:missing_ix */ id FROM dbo.big2 WHERE v = 12;
--@case udf_scalar runs=2
SELECT /* case:udf_scalar */ dbo.f_scalar(k) AS m FROM dbo.big2;
--@case udf_clr runs=2
SELECT /* case:udf_clr */ h.GetLevel() AS lvl FROM dbo.hier_t;
--@case udf_filter runs=2
SELECT /* case:udf_filter */ id FROM dbo.big2 WHERE dbo.f_scalar(v) = 1;
--@case udf_computed runs=2
SELECT /* case:udf_computed */ id, c FROM dbo.cc_t;
--@case mstvf_fixed runs=2
SELECT /* case:mstvf_fixed */ b.id FROM dbo.big2 AS b JOIN dbo.f_mstvf(7) AS t ON t.k = b.k OPTION (USE HINT ('DISABLE_INTERLEAVED_EXECUTION_TVF'));
--@case mstvf_interleaved runs=2
SELECT /* case:mstvf_interleaved */ t.k, b.v FROM dbo.f_mstvf(7) AS t JOIN dbo.big2 AS b ON b.k = t.k;
--@case table_var runs=2
DECLARE @t TABLE (k int NOT NULL PRIMARY KEY);
SELECT /* case:table_var */ b.id FROM dbo.big2 AS b WHERE b.k IN (SELECT t.k FROM @t AS t);
--@case cursor_dynamic runs=2
DECLARE c CURSOR DYNAMIC FOR SELECT /* case:cursor_dynamic */ id FROM dbo.big WHERE k = 3;
OPEN c; FETCH NEXT FROM c; CLOSE c; DEALLOCATE c;
--@case cursor_ff runs=2
DECLARE c CURSOR FAST_FORWARD FOR SELECT /* case:cursor_ff */ id, v FROM dbo.big WHERE k = 4;
OPEN c; FETCH NEXT FROM c; CLOSE c; DEALLOCATE c;
--@case cursor_keyset runs=2
DECLARE c CURSOR KEYSET FOR SELECT /* case:cursor_keyset */ id, s FROM dbo.big WHERE k = 5;
OPEN c; FETCH NEXT FROM c; CLOSE c; DEALLOCATE c;
--@case np_a runs=2
SELECT /* case:np_a */ COUNT(v) FROM dbo.np_t WHERE id <= 190000;
--@case np_b runs=2
SELECT /* case:np_b */ SUM(v) FROM dbo.np_t WHERE id <= 205000;
--@case np_c runs=2
SELECT /* case:np_c */ MAX(v) FROM dbo.np_t WHERE id <= 212000;
--@case np_d runs=2
SELECT /* case:np_d */ MIN(v) FROM dbo.np_t WHERE id <= 230000;
--@case sort_big runs=2
SELECT /* case:sort_big */ id, pad FROM dbo.big2 ORDER BY v;
--@case sort_topn runs=2
SELECT /* case:sort_topn */ TOP (10) id FROM dbo.big2 ORDER BY v;
--@case idx_spool runs=2
SELECT /* case:idx_spool */ b.id, x.v FROM dbo.big2 AS b CROSS APPLY (SELECT TOP (1) s.v FROM dbo.spool_src AS s WHERE s.k = b.k ORDER BY s.v DESC) AS x OPTION (LOOP JOIN);
--@case win_spool runs=2
SELECT /* case:win_spool */ k, v, SUM(v) OVER (PARTITION BY k) AS s FROM dbo.big2 OPTION (USE HINT ('DISALLOW_BATCH_MODE'));
--@case remote_all runs=2
--@pre IF NOT EXISTS (SELECT 1 FROM sys.servers WHERE name = N'LOOPBACK') EXEC master.dbo.sp_addlinkedserver @server = N'LOOPBACK', @srvproduct = N'', @provider = N'MSOLEDBSQL', @datasrc = N'localhost', @provstr = N'TrustServerCertificate=yes';
SELECT /* case:remote_all */ COUNT(*) FROM LOOPBACK.warnlab.dbo.big2;
--@case remote_small runs=2
--@pre IF NOT EXISTS (SELECT 1 FROM sys.servers WHERE name = N'LOOPBACK') EXEC master.dbo.sp_addlinkedserver @server = N'LOOPBACK', @srvproduct = N'', @provider = N'MSOLEDBSQL', @datasrc = N'localhost', @provstr = N'TrustServerCertificate=yes';
SELECT /* case:remote_small */ COUNT(*) FROM dbo.np_t AS n JOIN LOOPBACK.warnlab.dbo.tiny AS t ON t.k = n.v;
--@case row_goal runs=2
SELECT /* case:row_goal */ COUNT(*) FROM dbo.tiny AS t WHERE EXISTS (SELECT 1 FROM dbo.big2 AS b WHERE b.k = t.k);
--@case stale_hit runs=2
SELECT /* case:stale_hit */ COUNT(*) FROM dbo.stale_hi WHERE k = 1;
--@case stale_low runs=2
SELECT /* case:stale_low */ COUNT_BIG(*) FROM dbo.stale_lo WHERE k = 1;
--@case bad_est runs=2
DECLARE @x int = 1;
SELECT /* case:bad_est */ id FROM dbo.skew_t WHERE k = @x;
--@case adaptive runs=2
SELECT /* case:adaptive */ f.id, b.v FROM dbo.cs_fact AS f JOIN dbo.big AS b ON b.id = f.k WHERE f.region = 3;
--@case back_scan runs=2
SELECT /* case:back_scan */ TOP (10) id, v FROM dbo.big ORDER BY id DESC;
--@case heap_scan runs=2
SELECT /* case:heap_scan */ COUNT(*) FROM dbo.heap_t WHERE pad <> 'q';
--@case forced_ix runs=2
SELECT /* case:forced_ix */ id, v FROM dbo.big WITH (INDEX (ix_big_k)) WHERE v = 5;
--@case cs_rowmode runs=2
SELECT /* case:cs_rowmode */ SUM(amount) FROM dbo.cs_fact WHERE region = 4 OPTION (USE HINT ('DISALLOW_BATCH_MODE'));
--@case upd5_narrow runs=2
UPDATE /* case:upd5_narrow */ dbo.five_ix SET a = a + 1, b = b + 1, c = c + 1, d = d + 1 WHERE id = 7;
--@case upd5_wide runs=1
UPDATE /* case:upd5_wide */ dbo.five_ix SET a = a + 1, b = b + 1, c = c + 1, d = d + 1 WHERE id BETWEEN 1 AND 40000;
--@case upd4_narrow runs=2
UPDATE /* case:upd4_narrow */ dbo.four_ix SET a = a + 1, b = b + 1, c = c + 1, d = d + 1 WHERE id = 7;
--@case slow_udf runs=2 timeout=120
SELECT /* case:slow_udf */ dbo.f_slow(8000000) AS x;
--@case sort_spill runs=2
SELECT /* case:sort_spill */ id, pad FROM dbo.big ORDER BY pad DESC, v OPTION (MAX_GRANT_PERCENT = 0);
--@case tf_session runs=2
--@pre DBCC TRACEON (9481, 4199) WITH NO_INFOMSGS;
SELECT /* case:tf_session */ COUNT(*) FROM dbo.big2 WHERE v = 3 AND k = 2;
--@case compile_to runs=1 timeout=300
SELECT /* case:compile_to */ COUNT(*) FROM dbo.j01 AS a01 JOIN dbo.j02 AS a02 ON a02.v = a01.v JOIN dbo.j03 AS a03 ON a03.v = a02.v JOIN dbo.j04 AS a04 ON a04.v = a03.v JOIN dbo.j05 AS a05 ON a05.v = a04.v JOIN dbo.j06 AS a06 ON a06.v = a05.v JOIN dbo.j07 AS a07 ON a07.v = a06.v JOIN dbo.j08 AS a08 ON a08.v = a07.v JOIN dbo.j09 AS a09 ON a09.v = a08.v JOIN dbo.j10 AS a10 ON a10.v = a09.v JOIN dbo.j11 AS a11 ON a11.v = a10.v JOIN dbo.j12 AS a12 ON a12.v = a11.v JOIN dbo.j13 AS a13 ON a13.v = a12.v JOIN dbo.j14 AS a14 ON a14.v = a13.v JOIN dbo.j15 AS a15 ON a15.v = a14.v JOIN dbo.j16 AS a16 ON a16.v = a15.v JOIN dbo.j17 AS a17 ON a17.v = a16.v JOIN dbo.j18 AS a18 ON a18.v = a17.v JOIN dbo.j19 AS a19 ON a19.v = a18.v JOIN dbo.j20 AS a20 ON a20.v = a19.v WHERE a01.w = 1 AND a10.w = 2 AND a20.w = 3 AND a05.fk = a15.fk;
--@case long_compile runs=1 timeout=300
--@pre DBCC TRACEON (8780) WITH NO_INFOMSGS;
SELECT /* case:long_compile */ a01.w, COUNT(*) FROM dbo.j01 AS a01 JOIN dbo.j02 AS a02 ON a02.fk = a01.fk JOIN dbo.j03 AS a03 ON a03.fk = a02.fk JOIN dbo.j04 AS a04 ON a04.fk = a03.fk JOIN dbo.j05 AS a05 ON a05.fk = a04.fk JOIN dbo.j06 AS a06 ON a06.fk = a05.fk JOIN dbo.j07 AS a07 ON a07.fk = a06.fk JOIN dbo.j08 AS a08 ON a08.fk = a07.fk JOIN dbo.j09 AS a09 ON a09.fk = a08.fk JOIN dbo.j10 AS a10 ON a10.fk = a09.fk JOIN dbo.j11 AS a11 ON a11.fk = a10.fk JOIN dbo.j12 AS a12 ON a12.fk = a11.fk JOIN dbo.j13 AS a13 ON a13.fk = a12.fk JOIN dbo.j14 AS a14 ON a14.fk = a13.fk JOIN dbo.j15 AS a15 ON a15.fk = a14.fk JOIN dbo.j16 AS a16 ON a16.fk = a15.fk JOIN dbo.j17 AS a17 ON a17.fk = a16.fk JOIN dbo.j18 AS a18 ON a18.fk = a17.fk WHERE a01.v = 1 AND a09.v = 2 AND a18.v = 3 AND a04.w = a14.w GROUP BY a01.w;
--@case nonsarg_fn runs=2
SELECT /* case:nonsarg_fn */ id FROM dbo.big WHERE LEFT(s, 3) = 's12';
--@case nonsarg_like runs=2
SELECT /* case:nonsarg_like */ id, s FROM dbo.big WHERE s LIKE '%123';
--@case nojoin runs=2
SELECT /* case:nojoin */ COUNT(*) FROM dbo.tiny AS a, dbo.big2 AS b WHERE a.v > 3;
--@case ddl_create_index runs=1
CREATE INDEX /* case:ddl_create_index */ ix_ddl ON dbo.ddl_src (v);
--@case ddl_drop_index runs=1
DROP INDEX /* case:ddl_drop_index */ ix_ddl ON dbo.ddl_src;
--@case ddl_create_table runs=1
CREATE TABLE /* case:ddl_create_table */ dbo.ddl_tmp (i int NOT NULL);
--@case ddl_drop_table runs=1
DROP TABLE /* case:ddl_drop_table */ dbo.ddl_tmp;
