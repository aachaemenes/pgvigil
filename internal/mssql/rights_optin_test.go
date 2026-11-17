package mssql

import (
	"database/sql"
	"strings"
	"testing"
)

// TestRightsPoolHistoryOptIn (P25 task 9b, desk Q176 = a: dbmanager an OPT-IN): the rights catalogue has a row for
// Pool history's dbmanager, shown only on an Azure SQL Database in an elastic pool, not a needed right; its state says
// where it is read (in master, by mssql_pool_limits - the rights read runs in the database, which cannot see master's
// roles), it never counts as missing, and its grant is printed as a SEPARATE block whose every line is a comment and
// whose first lines say what it opens (create and drop databases, money) and that only Pool history needs it - in the
// script even when nothing else is missing, and never where the guard takes the statements out.
func TestRightsPoolHistoryOptIn(t *testing.T) {
	var opt *Right
	for i := range Rights {
		if Rights[i].Key == "azure_dbmanager_pool_history" {
			opt = &Rights[i]
		}
	}
	if opt == nil {
		t.Fatal("no rights row azure_dbmanager_pool_history")
	}
	if opt.Core {
		t.Error("the opt-in is a needed (core) right")
	}
	for _, c := range []struct {
		info Info
		want string
	}{
		{Info{Kind: KindAzureDB, ServiceObjective: "ElasticPool"}, ""},
		{Info{Kind: KindAzureDB, ServiceObjective: "S0"}, "hide"},
		{Info{Kind: KindServer}, "hide"},
		{Info{Kind: KindAzureMI}, "hide"},
	} {
		if got := opt.On(c.info); got != c.want {
			t.Errorf("On(%s %s) = %q, want %q", c.info.Kind, c.info.ServiceObjective, got, c.want)
		}
	}
	if !strings.Contains(opt.Null, "master") || !strings.Contains(opt.Null, "mssql_pool_limits") {
		t.Errorf("its state %q does not say it is read in master by mssql_pool_limits", opt.Null)
	}
	lines := strings.Split(strings.TrimSpace(opt.OptIn), "\n")
	for _, l := range lines {
		if !strings.HasPrefix(strings.TrimSpace(l), "--") {
			t.Errorf("a line of the opt-in block runs: %q (every line is a comment)", l)
		}
	}
	head := strings.Join(lines[:min(4, len(lines))], " ")
	for _, w := range []string{"OPT-IN", "create and drop databases", "cost money", "Pool history"} {
		if !strings.Contains(head, w) {
			t.Errorf("the block's first lines do not say %q: %s", w, head)
		}
	}
	if !strings.Contains(opt.OptIn, "ALTER ROLE dbmanager ADD MEMBER") || !strings.Contains(opt.OptIn, "master") {
		t.Errorf("the block gives no dbmanager in master: %s", opt.OptIn)
	}
	// the lead's 13:08 (a): the server role beside dbmanager, in the same words, commented out like every line
	if !strings.Contains(opt.OptIn, "-- or: ALTER SERVER ROLE ##MS_DatabaseManager## ADD MEMBER") || !strings.Contains(opt.OptIn, "ALTER SERVER ROLE ##MS_DatabaseManager## DROP MEMBER") {
		t.Errorf("the block does not give ##MS_DatabaseManager## beside dbmanager: %s", opt.OptIn)
	}
	// review t11-1 SHOULD 2: a contained database user has no login for FROM LOGIN, and an Entra identity is made FROM
	// EXTERNAL PROVIDER - the block says both in comment lines
	if !strings.Contains(opt.OptIn, "contained database user") || !strings.Contains(opt.OptIn, "FROM EXTERNAL PROVIDER") {
		t.Errorf("the block says nothing of a contained user or an Entra identity: %s", opt.OptIn)
	}
	id := rightsIdentity{login: "pgv_monitor", quoted: "[pgv_monitor]", literal: "N'pgv_monitor'", server: "srv1", user: "[pgv_monitor]", ownLogin: true}
	st := optInState(*opt, id)
	if st.State != opt.Null || !strings.Contains(st.Grant, "[pgv_monitor]") || strings.Contains(st.Grant, "{login}") {
		t.Errorf("the row's state %q and block %q: want its Null words and the block with the login filled in", st.State, st.Grant)
	}
	// the script: the opt-in's block alone (nothing missing), after the head; the guard takes it out with the rest
	read := RightsRead{Login: "pgv_monitor", Server: "srv1", Platform: "azuresqldb", Rights: []RightState{st}, OptIns: 1}
	read.guard(id, Info{Kind: KindAzureDB, ServiceObjective: "ElasticPool"})
	script := read.Script("2026-11-17 09:50")
	// review t11-1 NIT 6: nothing missing, only the opt-in: the head says so, never that the login lacks rights
	if strings.Contains(script, "lacks") || !strings.Contains(script, "opt-in") {
		t.Errorf("the script's head with only the opt-in block: %q", strings.SplitN(script, "\n", 3)[:2])
	}
	if read.Missing != 0 || !strings.Contains(script, "pgvigil did not run it") || !strings.Contains(script, "ALTER ROLE dbmanager ADD MEMBER [pgv_monitor]") {
		t.Errorf("the script with the opt-in alone:\n%s", script)
	}
	for _, l := range strings.Split(script, "\n") {
		if t2 := strings.TrimSpace(l); t2 != "" && !strings.HasPrefix(t2, "--") {
			t.Errorf("the script with the opt-in alone runs a line: %q", l)
		}
	}
	bad := rightsIdentity{login: "x\nDROP DATABASE y", quoted: "[x\nDROP DATABASE y]", literal: "N'x'", server: "srv1", ownLogin: true}
	unsafe := RightsRead{Login: bad.login, Server: "srv1", Rights: []RightState{optInState(*opt, bad)}, OptIns: 1}
	unsafe.guard(bad, Info{Kind: KindAzureDB, ServiceObjective: "ElasticPool"})
	if unsafe.Script("now") != "" || unsafe.NoScript == "" {
		t.Errorf("a login name with a line break: script %q, no-script %q - want none, said why", unsafe.Script("now"), unsafe.NoScript)
	}
}

// TestRightStatesOptIn (review t11-1 SHOULD 4): ReadRights' per-right states (addStates) on a pooled Azure SQL Database
// whose every right is held and whose opt-in reads NULL (CAST(NULL AS int): it is read in master by mssql_pool_limits,
// not here) - the opt-in is listed with its Null words and its block as the grant, counted as an opt-in, never as
// missing; without the opt-in branch the row would fall to its Null words with no block and the script would carry none.
func TestRightStatesOptIn(t *testing.T) {
	info := Info{Kind: KindAzureDB, Major: 12, ServiceObjective: "ElasticPool"}
	answers := map[string]sql.NullInt64{}
	for _, r := range Rights {
		if r.On(info) == "" {
			answers[r.Key] = sql.NullInt64{Int64: 1, Valid: true}
		}
	}
	answers["azure_dbmanager_pool_history"] = sql.NullInt64{}
	var out RightsRead
	out.addStates(Rights, map[string]string{}, answers, rightsIdentity{login: "pgv", quoted: "[pgv]"}, func() []string { return nil })
	if out.OptIns != 1 || out.Missing != 0 {
		t.Errorf("opt-ins %d, missing %d: want 1 and 0", out.OptIns, out.Missing)
	}
	var st *RightState
	for i := range out.Rights {
		if out.Rights[i].Key == "azure_dbmanager_pool_history" {
			st = &out.Rights[i]
		}
	}
	if st == nil || !strings.Contains(st.Grant, "-- ALTER ROLE dbmanager ADD MEMBER [pgv];") || st.State == "missing" || st.State == "" {
		t.Errorf("the opt-in's state %+v: want its Null words and its block for [pgv]", st)
	}
}
