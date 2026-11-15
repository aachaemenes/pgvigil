package mssql

import (
	"fmt"
	"strings"
	"testing"
)

// C13 / B9d: the text of the alerts script and its drop twin (C13-8's Go row): the stop batch first, the CONFIG lines,
// one row per severity, error and Availability Group message (each AG row 'not proven to fire'), the guard on msdb's
// own key, every sp_add_* in a TRY with its return code read, the notify block over pgvigil's own alerts, the mail notes,
// the closing SELECT, NOEXEC off at the end; the operator and the address carried as literals with quotes doubled; the
// refusals of what the script could not carry.
func TestAgentAlertsScript(t *testing.T) {
	s, err := AgentAlertsScript(AgentAlertsOptions{})
	if err != nil {
		t.Fatal(err)
	}
	must := func(text, what string) {
		t.Helper()
		if !strings.Contains(s, text) {
			t.Errorf("the script lacks %s: %q", what, text)
		}
	}
	stop := strings.Index(s, "IF @pgv_stop IS NOT NULL")
	cfg := strings.Index(s, "-- 2. CONFIG")
	if stop < 0 || cfg < 0 || stop > cfg || !strings.Contains(s[stop:cfg], "SET NOEXEC ON;") || !strings.Contains(s[stop:cfg], "\nGO\n") {
		t.Fatalf("the stop batch is not first and alone (stop at %d, CONFIG at %d)", stop, cfg)
	}
	for _, w := range []string{"EngineEdition') AS int) = 4", "= 5", "= 8", "= 9", "DB_ID(N'rdsadmin')", "@@VERSION LIKE N'% on Linux %'", "IS_SRVROLEMEMBER(N'sysadmin')"} {
		must(w, "a platform stop")
	}
	must(fmt.Sprintf("DECLARE @delay_seconds int = %d;", AgentAlertsDelay), "the delay's CONFIG line")
	must("DECLARE @operator sysname = NULL;", "no operator")
	must("DECLARE @operator_email nvarchar(100) = NULL;", "no address")
	must("DECLARE @include_ag bit = 0;", "the AG block off")
	for _, v := range alertSeverities {
		must(fmt.Sprintf("(N'(pgvigil) Severity %d', %d, 0, 0, NULL)", v, v), "a severity row")
	}
	for _, e := range alertErrors {
		must(fmt.Sprintf("(N'(pgvigil) Error %d', 0, %d, 0, NULL)", e, e), "an error row")
	}
	if len(agAlertIDs) != 17 {
		t.Fatalf("the AG ids: %d, want SQLMonitor's 17", len(agAlertIDs))
	}
	for _, m := range agAlertIDs {
		must(fmt.Sprintf("(N'(pgvigil) AG %d', 0, %d, 1, N'not proven to fire')", m, m), "an AG row")
	}
	must("ISNULL(a.database_name, N'') = N'' AND ISNULL(a.event_description_keyword, N'') = N''", "the guard on msdb's key")
	must("IF EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name = @name)", "the name guard")
	must("SERVERPROPERTY('IsHadrEnabled')", "the AG guard at run time")
	must("NOT EXISTS (SELECT 1 FROM sys.messages WHERE message_id = @mid", "the message id check")
	must("@include_event_description_in = 1", "the error text by e-mail")
	must("a.name LIKE N'(pgvigil) %' AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysnotifications", "the notify block")
	must("N'Database Mail XPs'", "the mail note")
	must("program_name LIKE N'SQLAgent - %'", "the Agent's sessions")
	must("JOIN @pgv_want w ON", "the closing SELECT")
	if !strings.HasSuffix(s, "GO\nSET NOEXEC OFF;\nGO\n") {
		t.Errorf("the script does not end by turning NOEXEC off: %q", s[len(s)-60:])
	}
	for _, p := range []string{"sp_add_alert", "sp_add_operator", "sp_add_notification"} {
		if strings.Count(s, "EXEC @rc = msdb.dbo."+p) != 1 {
			t.Errorf("%s is not called once with its return code read", p)
		}
	}
	if strings.Count(s, "BEGIN TRY") != strings.Count(s, "END TRY") || strings.Count(s, "BEGIN CATCH") != strings.Count(s, "END CATCH") || strings.Count(s, "BEGIN TRY") != 4 {
		t.Errorf("TRY / CATCH blocks: %d BEGIN TRY, %d END TRY, %d BEGIN CATCH, %d END CATCH (want 4 each)",
			strings.Count(s, "BEGIN TRY"), strings.Count(s, "END TRY"), strings.Count(s, "BEGIN CATCH"), strings.Count(s, "END CATCH"))
	}
	for _, never := range []string{"sp_update_alert", "sp_update_operator", "EXEC sp_configure", "dbo.sp_configure", "sys.sp_configure", "RECONFIGURE",
		"sp_set_sqlagent_properties", "sp_altermessage", "sp_delete_"} {
		if strings.Contains(s, never) {
			t.Errorf("the script holds %s: it changes no setting and drops nothing", never)
		}
	}

	o, err := AgentAlertsScript(AgentAlertsOptions{Operator: "O'Brien team", Email: "ops+sql@example.com", AG: true, DelaySeconds: 60})
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range []string{"DECLARE @operator sysname = N'O''Brien team';", "DECLARE @operator_email nvarchar(100) = N'ops+sql@example.com';", "DECLARE @include_ag bit = 1;", "DECLARE @delay_seconds int = 60;"} {
		if !strings.Contains(o, w) {
			t.Errorf("the script with an operator lacks %q", w)
		}
	}
	if strings.Count(o, "ops+sql@example.com") != 1 {
		t.Errorf("the address is in the script %d times, want once (the CONFIG line)", strings.Count(o, "ops+sql@example.com"))
	}
	if p, _ := AgentAlertsScript(AgentAlertsOptions{Placeholder: true}); !strings.Contains(p, "for example N'dba team'") {
		t.Error("the page's script without an operator carries no example in its @operator line")
	}
	for name, bad := range map[string]AgentAlertsOptions{
		"an address without an operator": {Email: "a@b.c"},
		"an address over 100":            {Operator: "o", Email: strings.Repeat("a", 95) + "@b.com"},
		"a control character":            {Operator: "o\nGO\nDROP"},
		"an operator over 128":           {Operator: strings.Repeat("o", 129)},
		"spaces around the operator":     {Operator: " o"},
		"a negative delay":               {DelaySeconds: -1},
	} {
		if _, err := AgentAlertsScript(bad); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}

	d := AgentAlertsDropScript()
	for _, w := range []string{"IF @pgv_stop IS NOT NULL", "WHERE name LIKE N'(pgvigil) %'", "EXEC @rc = msdb.dbo.sp_delete_alert @name = @an;", "pgvigil_alerts_left", "GO\nSET NOEXEC OFF;\nGO\n"} {
		if !strings.Contains(d, w) {
			t.Errorf("the drop script lacks %q", w)
		}
	}
	if strings.Contains(d, "sp_delete_operator") || strings.Contains(d, "sp_add_") {
		t.Error("the drop script touches an operator or adds something")
	}
	for _, c := range []struct {
		platform string
		edition  int
		want     string
	}{
		{"sqlserver", 3, ""}, {"sqlserver", 0, ""}, {"sqlserver", 4, "Express"}, {"rdssqlserver", 2, "Amazon RDS"},
		{"azuresqlmi", 8, "41914"}, {"azuresqldb", 5, "Azure SQL Database"}, {"cloudsqlsqlserver", 3, "sysadmin"}, {"sqlserver", 9, "Edge"},
	} {
		if got := AgentAlertsNotApplicable(c.platform, c.edition); (c.want == "") != (got == "") || !strings.Contains(got, c.want) {
			t.Errorf("AgentAlertsNotApplicable(%s, %d) = %q, want %q", c.platform, c.edition, got, c.want)
		}
	}
}
