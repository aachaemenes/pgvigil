package mssql

// The script that creates the SQL Server Agent alerts the alerts area of mssql_checks asks for (C13, B9d): one alert
// per severity of alertSeverities and per error of alertErrors, and (a choice) per Availability Group message, each
// e-mailing an operator where one is named. pgvigil prints the script and never runs it: the CLI
// 'pgvigil mssql-agent-alerts -print' and the instance's Checks page show it, the server's DBA reads it and runs it as
// a sysadmin. Its twin AgentAlertsDropScript drops what it made and nothing else.
//
// What the script holds to (the design's C13-1..10 as the design pass folded them):
//   - it stops with words, before anything else, where Agent alerts cannot be made: Express, Azure SQL Database,
//     Managed Instance (sp_add_alert raises 41914 there), Azure SQL Edge, Amazon RDS (rdsadmin present), SQL Server on
//     Linux (Microsoft lists Agent alerts among its unsupported features; read through @@VERSION,
//     which every version has - sys.dm_os_host_info came in SQL Server 2017), and a login
//     that is not sysadmin (sp_verify_alert, error 15003: Cloud SQL and RDS give no login that role). The stop is its
//     own first batch, so its words print before a later batch's msdb reference is compiled;
//   - a condition is covered when an alert of ANY name sits on msdb's own key for it (sp_add_alert_internal: message
//     id, severity, ISNULL(database_name, ''), ISNULL(event_description_keyword, ''), no performance condition): the
//     script then creates nothing there and says which alert covers it and why it may not serve (disabled, notifies
//     nobody, no error text); a pgvigil name held by an alert on another condition is said and skipped;
//   - a message id this version's sys.messages lacks is skipped with words; every sp_add_* return code and error is
//     caught (sp_add_alert raises at severity 16 and returns 1: never a 'created' line after it);
//   - the Availability Group alerts are made only where SERVERPROPERTY('IsHadrEnabled') = 1 when the script runs, and
//     each is marked 'not proven to fire' (sys.messages' is_event_logged is no test of whether the engine raises an
//     id WITH LOG; a firing test on an AG pair narrows the set: docs/sqlserver-checks.md);
//   - the delay between two responses is a CONFIG line (AgentAlertsDelay, set on create only), each alert sends the
//     error's text by e-mail (@include_event_description_in = 1: the area's own 'leaves the error text out' rule) and
//     starts no job;
//   - notifications are a block of their own over every '(pgvigil) ...' alert: a later run with the operator named
//     connects the alerts an earlier run made; an operator of that name is reused, never changed, and is created (with
//     the address given to the CLI) only when none exists;
//   - read-only notes on whether the mail can go anywhere (Database Mail XPs, a mail profile, the Agent's own mail
//     profile, the Agent running); no server or Agent setting is changed;
//   - it ends with every alert on the set's conditions, as XEScript ends with its sessions' state.

import (
	"errors"
	"fmt"
	"strings"
	"unicode"
	"unicode/utf16"
)

// AgentAlertsDelay is the script's default @delay_between_responses, in seconds: the larger of the two published
// scripts' values (Glenn Berry's 'Configuring Alerts for High Severity Problems': 900; the script the First Responder
// Kit's sp_Blitz links, brentozar.com/go/alert: 60), so a storm of one error mails once per 15 minutes.
const AgentAlertsDelay = 900

// agAlertIDs are the Availability Group message ids SQLMonitor (de87d37, MIT, Ajay Dwivedi) alerts on
// (dbo.alert_categories); none proven to fire by pgvigil yet.
var agAlertIDs = []int64{1480, 976, 983, 3402, 19406, 35206, 35250, 35264, 35273, 35274, 35275, 35276, 41091, 41131, 41142, 41406, 41414}

// AgentAlertsOptions are the script's choices.
type AgentAlertsOptions struct {
	// Operator is the operator each pgvigil alert e-mails; "" = none named (the script says the alerts notify nobody).
	Operator string
	// Email, with Operator, creates that operator when none of its name exists; "" = never create one. It goes into
	// the printed text only, never pgvigil's store.
	Email string
	// AG includes the Availability Group alerts (made only where Availability Groups are on when the script runs).
	AG bool
	// DelaySeconds is the CONFIG line's value; 0 = AgentAlertsDelay.
	DelaySeconds int
	// Placeholder: with no Operator, the CONFIG line carries a commented example instead of NULL alone (the page).
	Placeholder bool
}

// check refuses a value the script could not carry safely: sysoperators.name is sysname (128), sp_add_operator's
// @email_address nvarchar(100), both counted in UTF-16 units as SQL Server counts them (an emoji is two); no control
// character in either.
func (o AgentAlertsOptions) check() error {
	ctl := func(s string) bool { return strings.IndexFunc(s, unicode.IsControl) >= 0 }
	switch {
	case strings.TrimSpace(o.Operator) != o.Operator:
		return errors.New("the operator's name has leading or trailing spaces")
	case len(utf16.Encode([]rune(o.Operator))) > 128:
		return errors.New("the operator's name is longer than 128 characters (sysname)")
	case ctl(o.Operator) || ctl(o.Email):
		return errors.New("the operator's name or the e-mail address holds a control character")
	case o.Email != "" && o.Operator == "":
		return errors.New("an e-mail address needs the operator's name (-operator)")
	case strings.TrimSpace(o.Email) != o.Email:
		return errors.New("the e-mail address has leading or trailing spaces")
	case len(utf16.Encode([]rune(o.Email))) > 100:
		return errors.New("the e-mail address is longer than 100 characters (sp_add_operator's @email_address is nvarchar(100))")
	case o.DelaySeconds < 0 || o.DelaySeconds > 86400:
		return errors.New("the delay between responses must be 0 to 86400 seconds")
	}
	return nil
}

// nq is s as a T-SQL N'...' literal.
func nq(s string) string { return "N'" + strings.ReplaceAll(s, "'", "''") + "'" }

// agentAlertsStop is the first batch of both scripts: where it runs, or the words and NOEXEC (the later batches are
// compiled and not run; the last batch turns NOEXEC off again).
const agentAlertsStop = `SET NOCOUNT ON;
-- 1. where it runs: it stops here, with words, where SQL Server Agent alerts cannot be made
DECLARE @pgv_stop nvarchar(400) = CASE
  WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 4 THEN N'SQL Server Express has no SQL Server Agent'
  WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN N'Azure SQL Database has no SQL Server Agent'
  WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 8 THEN N'Azure SQL Managed Instance does not support SQL Server Agent alerts (msdb.dbo.sp_add_alert raises error 41914 there)'
  WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 9 THEN N'Azure SQL Edge is not a platform this script supports'
  WHEN DB_ID(N'rdsadmin') IS NOT NULL THEN N'Amazon RDS for SQL Server does not support SQL Server Agent alerts and operators'
  WHEN @@VERSION LIKE N'% on Linux %' THEN N'SQL Server on Linux does not support SQL Server Agent alerts (Microsoft, Editions and supported features of SQL Server on Linux: Unsupported features and services, SQL Server Agent, Alerts)'
  WHEN ISNULL(IS_SRVROLEMEMBER(N'sysadmin'), 0) <> 1 THEN N'this login is not a member of sysadmin, which msdb.dbo.sp_add_alert needs (error 15003); Cloud SQL and Amazon RDS give no login that role'
END;
IF @pgv_stop IS NOT NULL
BEGIN
  PRINT N'pgvigil: STOPPED, nothing was created, changed or dropped: ' + @pgv_stop + N'.';
  SET NOEXEC ON;
END
GO
`

const agentAlertsEnd = `GO
SET NOEXEC OFF;
GO
`

// AgentAlertsScript is the T-SQL that creates the alerts (see the file's head). pgvigil never runs it.
func AgentAlertsScript(o AgentAlertsOptions) (string, error) {
	if err := o.check(); err != nil {
		return "", err
	}
	delay := o.DelaySeconds
	if delay == 0 {
		delay = AgentAlertsDelay
	}
	var b strings.Builder
	sev := make([]string, len(alertSeverities))
	for i, s := range alertSeverities {
		sev[i] = fmt.Sprint(s)
	}
	errs := make([]string, len(alertErrors))
	for i, e := range alertErrors {
		errs[i] = fmt.Sprint(e)
	}
	fmt.Fprintf(&b, `/* pgvigil - SQL Server Agent alerts for what pgvigil's checks ask for (sp_Blitz 30, 61 and 96): severities %s and
   errors %s, and with @include_ag the Availability Group messages. pgvigil prints this script and never runs it: the
   server's DBA reads it and runs it as a sysadmin. It changes no server or Agent setting. Run again, it creates nothing
   that is there and says so line by line. Undo: pgvigil mssql-agent-alerts -print -drop (drops the '(pgvigil) ...'
   alerts and nothing else). */
`, strings.Join(sev, ", "), strings.Join(errs, ", "))
	b.WriteString(agentAlertsStop)
	op := "NULL"
	opNote := "the operator each pgvigil alert e-mails; NULL = none (the alerts then notify nobody)"
	switch {
	case o.Operator != "":
		op = nq(o.Operator)
	case o.Placeholder:
		opNote = "NULL = none; name an operator that has an e-mail address, for example N'dba team'"
	}
	email := "NULL"
	if o.Email != "" {
		email = nq(o.Email)
	}
	ag := 0
	if o.AG {
		ag = 1
	}
	fmt.Fprintf(&b, `-- 2. CONFIG: edit here
DECLARE @delay_seconds int = %d;   -- seconds between two responses of one alert (an 823 storm raises many a second): 900 is Glenn Berry's script's value, 60 the First Responder Kit's linked script's; set on create only
DECLARE @operator sysname = %s;   -- %s
DECLARE @operator_email nvarchar(100) = %s;   -- creates @operator with this address only when no operator of that name exists; NULL = never create one
DECLARE @include_ag bit = %d;   -- 1 = the Availability Group alerts too (made only where SERVERPROPERTY('IsHadrEnabled') = 1)

-- 3. the conditions: an alert per severity, per error and per Availability Group message (those not proven to fire)
DECLARE @pgv_want TABLE (ord int IDENTITY(1, 1) PRIMARY KEY, name sysname NOT NULL, severity int NOT NULL, message_id int NOT NULL, ag bit NOT NULL, note nvarchar(100) NULL);
INSERT @pgv_want (name, severity, message_id, ag, note) VALUES
`, delay, op, opNote, email, ag)
	var rows []string
	for _, s := range alertSeverities {
		rows = append(rows, fmt.Sprintf("  (N'(pgvigil) Severity %d', %d, 0, 0, NULL)", s, s))
	}
	for _, e := range alertErrors {
		rows = append(rows, fmt.Sprintf("  (N'(pgvigil) Error %d', 0, %d, 0, NULL)", e, e))
	}
	for _, m := range agAlertIDs {
		rows = append(rows, fmt.Sprintf("  (N'(pgvigil) AG %d', 0, %d, 1, N'not proven to fire')", m, m))
	}
	b.WriteString(strings.Join(rows, ",\n") + ";\n")
	b.WriteString(agentAlertsBody)
	b.WriteString(agentAlertsEnd)
	return b.String(), nil
}

// agentAlertsBody: the alerts, the operator, the notifications, the mail notes and the closing SELECT (the batch the
// CONFIG lines open).
const agentAlertsBody = `
DECLARE @hadr int = CAST(ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) AS int);
IF @include_ag = 1 AND @hadr <> 1 PRINT N'left out: the Availability Group alerts (Availability Groups are off on this server: IsHadrEnabled = 0).';
DECLARE @i int = 1, @n int = (SELECT COUNT(*) FROM @pgv_want), @name sysname, @sev int, @mid int, @ag bit, @note nvarchar(100),
        @cover sysname, @c_enabled tinyint, @c_notifies int, @c_job int, @c_desc int, @c_delay int, @scoped sysname, @rc int;
WHILE @i <= @n
BEGIN
  SELECT @name = name, @sev = severity, @mid = message_id, @ag = ag, @note = note FROM @pgv_want WHERE ord = @i;
  SET @i += 1;
  IF @ag = 1 AND (@include_ag = 0 OR @hadr <> 1) CONTINUE;
  IF @mid > 0 AND NOT EXISTS (SELECT 1 FROM sys.messages WHERE message_id = @mid AND language_id = 1033)
  BEGIN
    PRINT N'not created: ' + @name + N' - message ' + CAST(@mid AS nvarchar(10)) + N' is not in this version''s sys.messages.';
    CONTINUE;
  END
  -- covered: an alert of any name on msdb's own key for this condition (sp_add_alert refuses a second one)
  SET @cover = NULL;
  SELECT TOP (1) @cover = a.name, @c_enabled = a.enabled, @c_desc = a.include_event_description, @c_delay = a.delay_between_responses,
         @c_notifies = (SELECT COUNT(*) FROM msdb.dbo.sysnotifications s WHERE s.alert_id = a.id),
         @c_job = CASE WHEN a.job_id IS NULL OR a.job_id = 0x00 THEN 0 ELSE 1 END
    FROM msdb.dbo.sysalerts a
   WHERE a.message_id = @mid AND a.severity = @sev AND ISNULL(a.database_name, N'') = N'' AND ISNULL(a.event_description_keyword, N'') = N''
     AND a.performance_condition IS NULL
   ORDER BY CASE WHEN a.name = @name THEN 0 ELSE 1 END, a.name;
  IF @cover IS NOT NULL
  BEGIN
    IF @cover = @name
      PRINT N'there: ' + @name
        + CASE WHEN @c_enabled = 0 THEN N' (disabled: this script never turns an alert on)' ELSE N'' END
        + CASE WHEN @c_delay <> @delay_seconds THEN N' (its delay is ' + CAST(@c_delay AS nvarchar(10)) + N' s, the CONFIG line says ' + CAST(@delay_seconds AS nvarchar(10)) + N' s: left as it is)' ELSE N'' END;
    ELSE
      PRINT N'covered: ' + @name + N' - the alert ' + QUOTENAME(@cover) + N' is on this condition: nothing created'
        + CASE WHEN @c_enabled = 0 THEN N'; it is disabled' ELSE N'' END
        + CASE WHEN @c_notifies = 0 AND @c_job = 0 THEN N'; it notifies nobody and starts no job' ELSE N'' END
        + CASE WHEN @c_desc & 1 = 0 THEN N'; its e-mail leaves the error text out' ELSE N'' END;
    CONTINUE;
  END
  IF EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name = @name)
  BEGIN
    PRINT N'not created: ' + @name + N' - an alert of that name is on another condition; its name makes it pgvigil''s: the notify block below e-mails the operator from it and the drop script drops it (rename it to keep it apart).';
    CONTINUE;
  END
  SET @scoped = NULL;
  SELECT TOP (1) @scoped = a.name FROM msdb.dbo.sysalerts a
   WHERE a.message_id = @mid AND a.severity = @sev AND (ISNULL(a.database_name, N'') <> N'' OR ISNULL(a.event_description_keyword, N'') <> N'');
  BEGIN TRY
    SET @rc = NULL;
    EXEC @rc = msdb.dbo.sp_add_alert @name = @name, @message_id = @mid, @severity = @sev, @enabled = 1,
         @delay_between_responses = @delay_seconds, @include_event_description_in = 1;
    PRINT CASE WHEN @rc = 0 THEN N'created: ' ELSE N'not created (sp_add_alert returned ' + ISNULL(CAST(@rc AS nvarchar(10)), N'NULL') + N'): ' END
      + @name + ISNULL(N' (' + @note + N')', N'')
      + ISNULL(N'; the alert ' + QUOTENAME(@scoped) + N' covers this error for one database or keyword only', N'');
  END TRY
  BEGIN CATCH
    -- sp_add_alert inserts, then tells the Agent: a refusal of that step (14258 while the Agent starts) leaves the row
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name = @name)
      PRINT N'created (the Agent was not told: ' + ERROR_MESSAGE() + N'): ' + @name;
    ELSE
      PRINT N'not created: ' + @name + N' - ' + ERROR_MESSAGE();
  END CATCH
END

-- 4. the operator: reused as it is when there, created only with @operator_email
IF @operator IS NULL
  PRINT N'no operator named: the alerts notify nobody until @operator names one and the script runs again.';
ELSE IF EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = @operator)
  PRINT N'there: operator ' + QUOTENAME(@operator) + N' (reused as it is: this script never changes an operator)';
ELSE IF @operator_email IS NULL
  PRINT N'no notification added: operator ' + QUOTENAME(@operator) + N' does not exist (set @operator_email to create it, or name an existing operator).';
ELSE
BEGIN
  BEGIN TRY
    SET @rc = NULL;
    EXEC @rc = msdb.dbo.sp_add_operator @name = @operator, @enabled = 1, @email_address = @operator_email;
    PRINT CASE WHEN @rc = 0 THEN N'created: operator ' ELSE N'not created (sp_add_operator returned ' + ISNULL(CAST(@rc AS nvarchar(10)), N'NULL') + N'): operator ' END + QUOTENAME(@operator);
  END TRY
  BEGIN CATCH
    PRINT N'not created: operator ' + QUOTENAME(@operator) + N' - ' + ERROR_MESSAGE();
  END CATCH
END

-- 5. every pgvigil alert e-mails the operator: added where missing, so a later run with @operator named connects the
-- alerts an earlier run made
DECLARE @op_id int = (SELECT id FROM msdb.dbo.sysoperators WHERE name = @operator), @an sysname;
IF @op_id IS NOT NULL
BEGIN
  DECLARE pgv_notify CURSOR LOCAL FAST_FORWARD FOR
    SELECT a.name FROM msdb.dbo.sysalerts a
     WHERE a.name LIKE N'(pgvigil) %' AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysnotifications s WHERE s.alert_id = a.id AND s.operator_id = @op_id)
     ORDER BY a.name;
  OPEN pgv_notify;
  FETCH NEXT FROM pgv_notify INTO @an;
  WHILE @@FETCH_STATUS = 0
  BEGIN
    BEGIN TRY
      SET @rc = NULL;
      EXEC @rc = msdb.dbo.sp_add_notification @alert_name = @an, @operator_name = @operator, @notification_method = 1;
      PRINT CASE WHEN @rc = 0 THEN N'notifies: ' ELSE N'not added (sp_add_notification returned ' + ISNULL(CAST(@rc AS nvarchar(10)), N'NULL') + N'): ' END
        + @an + N' e-mails ' + QUOTENAME(@operator);
    END TRY
    BEGIN CATCH
      IF EXISTS (SELECT 1 FROM msdb.dbo.sysnotifications s JOIN msdb.dbo.sysalerts a ON a.id = s.alert_id WHERE a.name = @an AND s.operator_id = @op_id)
        PRINT N'notifies (the Agent was not told: ' + ERROR_MESSAGE() + N'): ' + @an + N' e-mails ' + QUOTENAME(@operator);
      ELSE
        PRINT N'not added: ' + @an + N' e-mails ' + QUOTENAME(@operator) + N' - ' + ERROR_MESSAGE();
    END CATCH
    FETCH NEXT FROM pgv_notify INTO @an;
  END
  CLOSE pgv_notify;
  DEALLOCATE pgv_notify;
END

-- 6. can the mail go anywhere? (read only: nothing here is changed)
IF ISNULL((SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'Database Mail XPs'), 0) = 0
  PRINT N'note: Database Mail is off (sp_configure ''Database Mail XPs'' is 0): the alerts cannot e-mail anyone.';
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile)
  PRINT N'note: msdb holds no Database Mail profile: the alerts cannot e-mail anyone.';
DECLARE @agent_profile nvarchar(256), @xrc int, @use_dbmail int, @xrc2 int;
BEGIN TRY
  EXEC @xrc = master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @agent_profile OUTPUT, N'no_output';
END TRY
BEGIN CATCH
  SET @xrc = NULL;
END CATCH
-- the Agent's 'Enable mail profile' (sp_set_sqlagent_properties writes UseDatabaseMail beside the profile's name)
BEGIN TRY
  EXEC @xrc2 = master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'UseDatabaseMail', @use_dbmail OUTPUT, N'no_output';
END TRY
BEGIN CATCH
  SET @xrc2 = NULL;
END CATCH
IF @xrc2 = 0 AND ISNULL(@use_dbmail, 0) = 0
  PRINT N'note: the Agent''s mail profile is not enabled (UseDatabaseMail is 0: the Agent''s properties, Alert System, Enable mail profile): the alerts cannot e-mail anyone.';
IF @xrc = 0 AND NULLIF(LTRIM(RTRIM(@agent_profile)), N'') IS NULL
  PRINT N'note: SQL Server Agent has no mail profile, so alerts and job notifications cannot e-mail (Windows: the Agent''s properties, Alert System; Linux: mssql-conf set sqlagent.databasemailprofile).';
ELSE IF ISNULL(@xrc, 1) <> 0
  PRINT N'note: the Agent''s mail profile was not read here (xp_instance_regread returned ' + ISNULL(CAST(@xrc AS nvarchar(10)), N'an error') + N'): check it in the Agent''s properties.';
IF NOT EXISTS (SELECT 1 FROM sys.dm_exec_sessions WHERE program_name LIKE N'SQLAgent - %')
  PRINT N'note: SQL Server Agent shows no session: it is not running, and no alert fires while it is stopped.';

-- 7. the alerts on these conditions now
SELECT a.name, a.severity, a.message_id, a.enabled, a.delay_between_responses AS delay_s, a.include_event_description,
       (SELECT COUNT(*) FROM msdb.dbo.sysnotifications s WHERE s.alert_id = a.id) AS operators_notified,
       CASE WHEN a.name LIKE N'(pgvigil) %' THEN N'pgvigil' ELSE N'the site' END AS made_by, w.note
  FROM msdb.dbo.sysalerts a
  JOIN @pgv_want w ON w.severity = a.severity AND w.message_id = a.message_id
 ORDER BY w.ord, a.name;
`

// AgentAlertsDropScript is the T-SQL that drops every alert named '(pgvigil) ...' and nothing else; the operator stays.
func AgentAlertsDropScript() string {
	return `/* pgvigil - drops the SQL Server Agent alerts named '(pgvigil) ...' that 'pgvigil mssql-agent-alerts -print' made,
   and nothing else: their notifications go with them; the operator stays (it may predate pgvigil: drop it by hand if
   it is not wanted). pgvigil prints this script and never runs it. */
` + agentAlertsStop + `DECLARE @an sysname, @rc int, @dropped int = 0;
DECLARE pgv_drop CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM msdb.dbo.sysalerts WHERE name LIKE N'(pgvigil) %' ORDER BY name;
OPEN pgv_drop;
FETCH NEXT FROM pgv_drop INTO @an;
WHILE @@FETCH_STATUS = 0
BEGIN
  BEGIN TRY
    SET @rc = NULL;
    EXEC @rc = msdb.dbo.sp_delete_alert @name = @an;
    IF @rc = 0 SET @dropped += 1;
    PRINT CASE WHEN @rc = 0 THEN N'dropped: ' ELSE N'not dropped (sp_delete_alert returned ' + ISNULL(CAST(@rc AS nvarchar(10)), N'NULL') + N'): ' END + @an;
  END TRY
  BEGIN CATCH
    PRINT N'not dropped: ' + @an + N' - ' + ERROR_MESSAGE();
  END CATCH
  FETCH NEXT FROM pgv_drop INTO @an;
END
CLOSE pgv_drop;
DEALLOCATE pgv_drop;
IF @dropped = 0 PRINT N'no pgvigil alert was dropped.';
SELECT COUNT(*) AS pgvigil_alerts_left FROM msdb.dbo.sysalerts WHERE name LIKE N'(pgvigil) %';
` + agentAlertsEnd
}

// AgentAlertsNotApplicable is why the script has no place on an instance of this platform (pgvigil.instances.platform),
// engine edition (0 = not read) and host platform (mssql_property host_platform: Windows | Linux, "" = not read), or ""
// where it applies. The script stops on these by itself as well.
func AgentAlertsNotApplicable(platform string, engineEdition int, hostPlatform string) string {
	switch {
	case Kind(platform) == KindRDS:
		return "Amazon RDS for SQL Server does not support SQL Server Agent alerts and operators"
	case Kind(platform) == KindAzureDB || engineEdition == 5:
		return "Azure SQL Database has no SQL Server Agent"
	case Kind(platform) == KindAzureMI || engineEdition == 8:
		return "Azure SQL Managed Instance does not support SQL Server Agent alerts (msdb.dbo.sp_add_alert raises error 41914 there)"
	case Kind(platform) == KindCloudSQL:
		return "Cloud SQL for SQL Server gives no login the sysadmin role that msdb.dbo.sp_add_alert needs, and has no Database Mail (Google's 'Cloud SQL for SQL Server features')"
	case engineEdition == 4:
		return "SQL Server Express has no SQL Server Agent"
	case engineEdition == 9:
		return "Azure SQL Edge is not a platform the script supports"
	case strings.EqualFold(hostPlatform, "Linux"):
		return "SQL Server on Linux (Microsoft lists Agent alerts as unsupported)"
	}
	return ""
}
