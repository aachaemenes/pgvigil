-- proof-mssql-properties-windows.sql - task 301c's row N5: one read-only pass on a Windows SQL Server instance (its
-- default instance, a sysadmin over Windows authentication: sqlcmd -S localhost -E -b -I -i <this file>).
--
-- It sends the four statements pgvigil's mssql_properties collection sends for its network rows and for
-- Win32PrioritySeparation (internal/mssql/properties.go: propsGateSQL, propsNetViewSQL, propsNetRegSQL and
-- propsPrioritySQL - the text here is the code's, quotes doubled, held equal by TestWindowsRunnerSendsTheCodesStatements)
-- and, beside them, the same facts read another way: each key's own value list (xp_instance_regenumvalues,
-- xp_regenumvalues), the two encryption values on their own with their return codes, the Tcp key's sub-keys, the
-- listeners SQL Server reports, the transports of the sessions connected now, and the error log's lines about what it
-- listens on.
--
-- Every result is printed as one line 'N5|<part>|...|~' (the '|~' ends the line: a wrapped or cut line is seen). The
-- N5| lines are the fixture of TestNetRowsOnWindowsFixture (internal/mssql/testdata/properties-windows.txt). They hold
-- no login, host or instance name and no address: an IpAddress value and a listener's address are printed as their
-- kind (ipv4, ipv6, loopback, any), and a registry value's data is printed only for the values the rows are built
-- from (any other - a certificate's thumbprint, an SPN - is named, its data '<not printed>'). Lines 'N5x|...' are for
-- the reader of the run only and never go into the fixture.
--
-- Nothing is changed: SELECTs, xp_instance_regread, xp_regread, xp_instance_regenumvalues, xp_regenumvalues,
-- xp_instance_regenumkeys and xp_readerrorlog, and #temp tables of this session that hold what they answered. Each read
-- sits in its own TRY / CATCH (an error is a line 'N5|<part>|ERROR|<number>|<message>|~', the pass goes on); an xp_
-- procedure's failure is a message, never an error, so its return code is printed.
SET NOCOUNT ON;
DROP TABLE IF EXISTS #n5_gate;
DROP TABLE IF EXISTS #n5_view;
DROP TABLE IF EXISTS #n5_reg;
DROP TABLE IF EXISTS #n5_prio;
DROP TABLE IF EXISTS #n5_enum;
DROP TABLE IF EXISTS #n5_keys;
DROP TABLE IF EXISTS #n5_log;
GO
PRINT 'N5x|start|proof-mssql-properties-windows|~';
BEGIN TRY
  SELECT CAST(N'N5|version|' + CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(30)) + N'|' + CAST(SERVERPROPERTY('ProductMajorVersion') AS nvarchar(10))
         + N'|' + (SELECT TOP (1) CAST(host_platform AS nvarchar(60)) FROM sys.dm_os_host_info) + N'|' + CAST(SERVERPROPERTY('EngineEdition') AS nvarchar(10))
         + N'|sysadmin ' + CAST(ISNULL(IS_SRVROLEMEMBER('sysadmin'), 0) AS nvarchar(2))
         + N'|default instance ' + CASE WHEN SERVERPROPERTY('InstanceName') IS NULL THEN N'1' ELSE N'0' END + N'|~' AS nvarchar(400)) AS line;
END TRY BEGIN CATCH SELECT CAST(N'N5|version|ERROR|' + CAST(ERROR_NUMBER() AS nvarchar(12)) + N'|' + ERROR_MESSAGE() + N'|~' AS nvarchar(900)) AS line; END CATCH
GO
-- ---- 1. the code's gate (propsGateSQL); the login's name is never printed
CREATE TABLE #n5_gate (can_registry_view int, can_instance_regread int, can_regread int, login_name nvarchar(128));
BEGIN TRY
  INSERT #n5_gate (can_registry_view, can_instance_regread, can_regread, login_name) EXEC sys.sp_executesql N'SELECT
  CAST(CASE WHEN ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, ''VIEW SERVER STATE''), 0) = 1
              OR ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, ''VIEW SERVER PERFORMANCE STATE''), 0) = 1 THEN 1 ELSE 0 END AS int) AS can_registry_view,
  CAST(ISNULL(HAS_PERMS_BY_NAME(N''master.dbo.xp_instance_regread'', ''OBJECT'', ''EXECUTE''), 0) AS int) AS can_instance_regread,
  CAST(ISNULL(HAS_PERMS_BY_NAME(N''master.dbo.xp_regread'', ''OBJECT'', ''EXECUTE''), 0) AS int) AS can_regread,
  CAST(SUSER_SNAME() AS nvarchar(128)) AS login_name';
  SELECT CAST(N'N5|gate|' + ISNULL(CAST(can_registry_view AS nvarchar(12)), N'<NULL>') + N'|' + ISNULL(CAST(can_instance_regread AS nvarchar(12)), N'<NULL>')
         + N'|' + ISNULL(CAST(can_regread AS nvarchar(12)), N'<NULL>') + N'|login named ' + CASE WHEN login_name IS NULL THEN N'0' ELSE N'1' END + N'|~' AS nvarchar(400)) AS line
    FROM #n5_gate;
  SELECT CAST(N'N5|gate-rows|' + CAST(COUNT(*) AS nvarchar(12)) + N'|~' AS nvarchar(400)) AS line FROM #n5_gate;
END TRY BEGIN CATCH SELECT CAST(N'N5|gate|ERROR|' + CAST(ERROR_NUMBER() AS nvarchar(12)) + N'|' + ERROR_MESSAGE() + N'|~' AS nvarchar(900)) AS line; END CATCH
GO
-- ---- 2. the code's read of the registry view (propsNetViewSQL), every row as it came, in its order
CREATE TABLE #n5_view (id int IDENTITY(1, 1) NOT NULL, registry_key nvarchar(256), value_name nvarchar(256), value_data nvarchar(512));
BEGIN TRY
  INSERT #n5_view (registry_key, value_name, value_data) EXEC sys.sp_executesql N'SELECT CAST(registry_key AS nvarchar(256)) AS registry_key, CAST(value_name AS nvarchar(256)) AS value_name,
  CAST(value_data AS nvarchar(512)) AS value_data
FROM sys.dm_server_registry WHERE registry_key LIKE N''%SuperSocketNetLib%''';
  SELECT CAST(N'N5|view|' + ISNULL(registry_key, N'<NULL>') + N'|' + ISNULL(value_name, N'<NULL>') + N'|'
         + CASE WHEN value_data IS NULL THEN N'<NULL>'
                WHEN value_name IN (N'ForceEncryption', N'ForceStrictEncryption', N'ForceStrict', N'ListenOnAllIPs', N'Enabled', N'TcpPort',
                                    N'TcpDynamicPorts') THEN value_data
                WHEN value_name <> N'IpAddress' OR value_name IS NULL THEN N'<not printed>'
                WHEN value_data = N'' THEN N''
                WHEN value_data IN (N'127.0.0.1', N'::1') THEN N'loopback'
                WHEN value_data LIKE N'%:%' THEN N'ipv6' ELSE N'ipv4' END + N'|~' AS nvarchar(900)) AS line
    FROM #n5_view ORDER BY id;
  SELECT CAST(N'N5|view-rows|' + CAST(COUNT(*) AS nvarchar(12)) + N'|~' AS nvarchar(400)) AS line FROM #n5_view;
END TRY BEGIN CATCH SELECT CAST(N'N5|view|ERROR|' + CAST(ERROR_NUMBER() AS nvarchar(12)) + N'|' + ERROR_MESSAGE() + N'|~' AS nvarchar(900)) AS line; END CATCH
GO
-- ---- 3. the code's read through xp_instance_regread (propsNetRegSQL): its one row
CREATE TABLE #n5_reg (force_encryption int, force_strict_encryption int, listen_all int, tcp_enabled int, np_enabled int, sm_enabled int,
                      ipall_port nvarchar(256), ipall_dynamic nvarchar(256));
BEGIN TRY
  INSERT #n5_reg (force_encryption, force_strict_encryption, listen_all, tcp_enabled, np_enabled, sm_enabled, ipall_port, ipall_dynamic)
  EXEC sys.sp_executesql N'DECLARE @fe int, @fse int, @all int, @tcp int, @np int, @sm int, @port nvarchar(256), @dyn nvarchar(256);
DECLARE @k nvarchar(200) = N''Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib'';
EXEC master.dbo.xp_instance_regread N''HKEY_LOCAL_MACHINE'', @k, N''ForceEncryption'', @fe OUTPUT;
EXEC master.dbo.xp_instance_regread N''HKEY_LOCAL_MACHINE'', @k, N''ForceStrictEncryption'', @fse OUTPUT;
SET @k = N''Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib\Tcp'';
EXEC master.dbo.xp_instance_regread N''HKEY_LOCAL_MACHINE'', @k, N''ListenOnAllIPs'', @all OUTPUT;
EXEC master.dbo.xp_instance_regread N''HKEY_LOCAL_MACHINE'', @k, N''Enabled'', @tcp OUTPUT;
SET @k = N''Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib\Tcp\IPAll'';
EXEC master.dbo.xp_instance_regread N''HKEY_LOCAL_MACHINE'', @k, N''TcpPort'', @port OUTPUT;
EXEC master.dbo.xp_instance_regread N''HKEY_LOCAL_MACHINE'', @k, N''TcpDynamicPorts'', @dyn OUTPUT;
EXEC master.dbo.xp_instance_regread N''HKEY_LOCAL_MACHINE'', N''Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib\Np'', N''Enabled'', @np OUTPUT;
EXEC master.dbo.xp_instance_regread N''HKEY_LOCAL_MACHINE'', N''Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib\Sm'', N''Enabled'', @sm OUTPUT;
SELECT @fe AS force_encryption, @fse AS force_strict_encryption, @all AS listen_all, @tcp AS tcp_enabled, @np AS np_enabled,
  @sm AS sm_enabled, @port AS ipall_port, @dyn AS ipall_dynamic;';
  SELECT CAST(N'N5|reg|' + ISNULL(CAST(force_encryption AS nvarchar(12)), N'<NULL>') + N'|' + ISNULL(CAST(force_strict_encryption AS nvarchar(12)), N'<NULL>')
         + N'|' + ISNULL(CAST(listen_all AS nvarchar(12)), N'<NULL>') + N'|' + ISNULL(CAST(tcp_enabled AS nvarchar(12)), N'<NULL>')
         + N'|' + ISNULL(CAST(np_enabled AS nvarchar(12)), N'<NULL>') + N'|' + ISNULL(CAST(sm_enabled AS nvarchar(12)), N'<NULL>')
         + N'|' + ISNULL(ipall_port, N'<NULL>') + N'|' + ISNULL(ipall_dynamic, N'<NULL>') + N'|~' AS nvarchar(900)) AS line
    FROM #n5_reg;
  SELECT CAST(N'N5|reg-rows|' + CAST(COUNT(*) AS nvarchar(12)) + N'|~' AS nvarchar(400)) AS line FROM #n5_reg;
END TRY BEGIN CATCH SELECT CAST(N'N5|reg|ERROR|' + CAST(ERROR_NUMBER() AS nvarchar(12)) + N'|' + ERROR_MESSAGE() + N'|~' AS nvarchar(900)) AS line; END CATCH
GO
-- ---- 4. the code's read of Win32PrioritySeparation (propsPrioritySQL): its one row
CREATE TABLE #n5_prio (priority_separation int);
BEGIN TRY
  INSERT #n5_prio (priority_separation) EXEC sys.sp_executesql N'DECLARE @ps int;
EXEC master.dbo.xp_regread N''HKEY_LOCAL_MACHINE'', N''SYSTEM\CurrentControlSet\Control\PriorityControl'', N''Win32PrioritySeparation'', @ps OUTPUT;
SELECT @ps AS priority_separation;';
  SELECT CAST(N'N5|prio|' + ISNULL(CAST(priority_separation AS nvarchar(12)), N'<NULL>') + N'|~' AS nvarchar(400)) AS line FROM #n5_prio;
  SELECT CAST(N'N5|prio-rows|' + CAST(COUNT(*) AS nvarchar(12)) + N'|~' AS nvarchar(400)) AS line FROM #n5_prio;
END TRY BEGIN CATCH SELECT CAST(N'N5|prio|ERROR|' + CAST(ERROR_NUMBER() AS nvarchar(12)) + N'|' + ERROR_MESSAGE() + N'|~' AS nvarchar(900)) AS line; END CATCH
GO
-- ---- 5. the same facts another way: each key's own value list (a value that is not set is a missing row). Only the
-- values the rows are built from are printed with their data; any other value of a key is named, its data not printed.
CREATE TABLE #n5_enum (id int IDENTITY(1, 1) NOT NULL, k nvarchar(40) NULL, value_name nvarchar(256), value_data sql_variant);
DECLARE @n5_keys TABLE (ord int NOT NULL PRIMARY KEY, label nvarchar(40) NOT NULL, of_instance bit NOT NULL, reg_path nvarchar(300) NOT NULL);
INSERT @n5_keys (ord, label, of_instance, reg_path) VALUES
  (1, N'SuperSocketNetLib', 1, N'Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib'),
  (2, N'Tcp', 1, N'Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib\Tcp'),
  (3, N'Tcp\IPAll', 1, N'Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib\Tcp\IPAll'),
  (4, N'Np', 1, N'Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib\Np'),
  (5, N'Sm', 1, N'Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib\Sm'),
  (6, N'PriorityControl', 0, N'SYSTEM\CurrentControlSet\Control\PriorityControl');
DECLARE @n5_ord int = 1, @n5_label nvarchar(40), @n5_inst bit, @n5_path nvarchar(300), @n5_rc int;
WHILE @n5_ord <= 6
BEGIN
  SELECT @n5_label = label, @n5_inst = of_instance, @n5_path = reg_path FROM @n5_keys WHERE ord = @n5_ord;
  BEGIN TRY
    SET @n5_rc = NULL;
    IF @n5_inst = 1
      INSERT #n5_enum (value_name, value_data) EXEC @n5_rc = master.dbo.xp_instance_regenumvalues N'HKEY_LOCAL_MACHINE', @n5_path;
    ELSE
      INSERT #n5_enum (value_name, value_data) EXEC @n5_rc = master.dbo.xp_regenumvalues N'HKEY_LOCAL_MACHINE', @n5_path;
    UPDATE #n5_enum SET k = @n5_label WHERE k IS NULL;
    SELECT CAST(N'N5|sa-enum-rc|' + @n5_label + N'|' + ISNULL(CAST(@n5_rc AS nvarchar(12)), N'<NULL>') + N'|~' AS nvarchar(400)) AS line;
  END TRY
  BEGIN CATCH
    SELECT CAST(N'N5|sa-enum|ERROR|' + @n5_label + N'|' + CAST(ERROR_NUMBER() AS nvarchar(12)) + N'|' + ERROR_MESSAGE() + N'|~' AS nvarchar(900)) AS line;
  END CATCH
  SET @n5_ord += 1;
END
SELECT CAST(N'N5|sa-enum|' + ISNULL(k, N'<NULL>') + N'|' + ISNULL(value_name, N'<NULL>') + N'|'
       + CASE WHEN value_name NOT IN (N'ForceEncryption', N'ForceStrictEncryption', N'ForceStrict', N'ListenOnAllIPs', N'Enabled', N'TcpPort', N'TcpDynamicPorts',
                                      N'Win32PrioritySeparation') THEN N'<not printed>'
              WHEN value_data IS NULL THEN N'<NULL>' ELSE CAST(value_data AS nvarchar(300)) END + N'|~' AS nvarchar(900)) AS line
  FROM #n5_enum ORDER BY id;
-- the two encryption values on their own, each with its return code (0 = read; a value that is not set leaves NULL)
DECLARE @n5_val int;
BEGIN TRY
  SET @n5_rc = NULL; SET @n5_val = NULL;
  EXEC @n5_rc = master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib', N'ForceEncryption', @n5_val OUTPUT;
  SELECT CAST(N'N5|sa-read|SuperSocketNetLib|ForceEncryption|rc ' + ISNULL(CAST(@n5_rc AS nvarchar(12)), N'<NULL>') + N'|' + ISNULL(CAST(@n5_val AS nvarchar(12)), N'<NULL>') + N'|~' AS nvarchar(400)) AS line;
  SET @n5_rc = NULL; SET @n5_val = NULL;
  EXEC @n5_rc = master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib', N'ForceStrictEncryption', @n5_val OUTPUT;
  SELECT CAST(N'N5|sa-read|SuperSocketNetLib|ForceStrictEncryption|rc ' + ISNULL(CAST(@n5_rc AS nvarchar(12)), N'<NULL>') + N'|' + ISNULL(CAST(@n5_val AS nvarchar(12)), N'<NULL>') + N'|~' AS nvarchar(400)) AS line;
END TRY BEGIN CATCH SELECT CAST(N'N5|sa-read|ERROR|' + CAST(ERROR_NUMBER() AS nvarchar(12)) + N'|' + ERROR_MESSAGE() + N'|~' AS nvarchar(900)) AS line; END CATCH
GO
-- ---- 6. the Tcp key's sub-keys (the IPn entries and IPAll), by name
CREATE TABLE #n5_keys (id int IDENTITY(1, 1) NOT NULL, key_name nvarchar(256));
DECLARE @rc int;
BEGIN TRY
  INSERT #n5_keys (key_name) EXEC @rc = master.dbo.xp_instance_regenumkeys N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib\Tcp';
  SELECT CAST(N'N5|sa-keys-rc|Tcp|' + ISNULL(CAST(@rc AS nvarchar(12)), N'<NULL>') + N'|~' AS nvarchar(400)) AS line;
  SELECT CAST(N'N5|sa-keys|Tcp|' + ISNULL(key_name, N'<NULL>') + N'|~' AS nvarchar(900)) AS line FROM #n5_keys ORDER BY id;
END TRY BEGIN CATCH SELECT CAST(N'N5|sa-keys|ERROR|' + CAST(ERROR_NUMBER() AS nvarchar(12)) + N'|' + ERROR_MESSAGE() + N'|~' AS nvarchar(900)) AS line; END CATCH
GO
-- ---- 7. what SQL Server itself reports: its listeners, and the transports of the sessions connected now
BEGIN TRY
  SELECT CAST(N'N5|sa-listener|' + CASE WHEN ip_address IN (N'127.0.0.1', N'::1') THEN N'loopback' WHEN ip_address IN (N'::', N'0.0.0.0') THEN N'any'
                                        WHEN is_ipv4 = 1 THEN N'ipv4' ELSE N'ipv6' END
         + N'|' + CAST(port AS nvarchar(12)) + N'|' + CAST(type_desc AS nvarchar(60)) + N'|' + CAST(state_desc AS nvarchar(60)) + N'|~' AS nvarchar(400)) AS line
    FROM sys.dm_tcp_listener_states ORDER BY listener_id;
  SELECT CAST(N'N5|sa-listener-rows|' + CAST(COUNT(*) AS nvarchar(12)) + N'|~' AS nvarchar(400)) AS line FROM sys.dm_tcp_listener_states;
END TRY BEGIN CATCH SELECT CAST(N'N5|sa-listener|ERROR|' + CAST(ERROR_NUMBER() AS nvarchar(12)) + N'|' + ERROR_MESSAGE() + N'|~' AS nvarchar(900)) AS line; END CATCH
BEGIN TRY
  SELECT CAST(N'N5|sa-conn|' + CAST(net_transport AS nvarchar(40)) + N'|encrypt ' + CAST(encrypt_option AS nvarchar(40)) + N'|port '
         + ISNULL(CAST(local_tcp_port AS nvarchar(12)), N'<NULL>') + N'|' + CAST(COUNT(*) AS nvarchar(12)) + N'|~' AS nvarchar(400)) AS line
    FROM sys.dm_exec_connections GROUP BY net_transport, encrypt_option, local_tcp_port ORDER BY net_transport, encrypt_option, local_tcp_port;
END TRY BEGIN CATCH SELECT CAST(N'N5|sa-conn|ERROR|' + CAST(ERROR_NUMBER() AS nvarchar(12)) + N'|' + ERROR_MESSAGE() + N'|~' AS nvarchar(900)) AS line; END CATCH
GO
-- ---- 8. for the reader of the run only (N5x): the current error log's lines about what the instance listens on
CREATE TABLE #n5_log (id int IDENTITY(1, 1) NOT NULL, log_date datetime, process_info nvarchar(100), log_text nvarchar(max));
BEGIN TRY
  INSERT #n5_log (log_date, process_info, log_text) EXEC master.dbo.xp_readerrorlog 0, 1, N'listening on';
  INSERT #n5_log (log_date, process_info, log_text) EXEC master.dbo.xp_readerrorlog 0, 1, N'ready to accept connection';
  SELECT CAST(N'N5x|errorlog|' + CONVERT(nvarchar(19), log_date, 126) + N'|' + LEFT(ISNULL(log_text, N'<NULL>'), 600) + N'|~' AS nvarchar(900)) AS line FROM #n5_log ORDER BY id;
END TRY BEGIN CATCH SELECT CAST(N'N5x|errorlog|ERROR|' + CAST(ERROR_NUMBER() AS nvarchar(12)) + N'|' + ERROR_MESSAGE() + N'|~' AS nvarchar(900)) AS line; END CATCH
GO
DROP TABLE IF EXISTS #n5_gate;
DROP TABLE IF EXISTS #n5_view;
DROP TABLE IF EXISTS #n5_reg;
DROP TABLE IF EXISTS #n5_prio;
DROP TABLE IF EXISTS #n5_enum;
DROP TABLE IF EXISTS #n5_keys;
DROP TABLE IF EXISTS #n5_log;
PRINT 'N5|done|~';
