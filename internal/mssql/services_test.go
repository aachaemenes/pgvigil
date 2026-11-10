package mssql

import (
	"strings"
	"testing"
	"time"
)

func TestServicesCollector(t *testing.T) {
	c, ok := Get("mssql_services")
	if !ok {
		t.Fatal("mssql_services is not registered")
	}
	if c.DefaultInterval() != 5*time.Minute {
		t.Errorf("default interval %v", c.DefaultInterval())
	}
	if ok, why := c.Applies(Info{Kind: KindAzureDB, ViewServerState: true}); ok || !strings.Contains(why, "Azure SQL Database") {
		t.Errorf("Azure SQL Database: %v %q", ok, why)
	}
	if ok, why := c.Applies(Info{Kind: KindServer}); ok || !strings.Contains(why, "VIEW SERVER STATE") {
		t.Errorf("without VIEW SERVER STATE: %v %q", ok, why)
	}
	for _, k := range []Kind{KindServer, KindRDS, KindAzureMI} {
		if ok, why := c.Applies(Info{Kind: k, ViewServerState: true}); !ok {
			t.Errorf("%s: skipped: %s", k, why)
		}
	}
	// nothing of the collection writes, runs a procedure or reads a user table
	for _, q := range []string{serviceListSQL, agentSQL, dbmailSQL, dbmailOffSQL, dumpsSQL} {
		u := strings.ToUpper(q)
		for _, bad := range []string{"EXEC ", "EXECUTE", "INSERT ", "UPDATE ", "DELETE ", "XP_", " SP_", ".SP_"} {
			if strings.Contains(u, bad) {
				t.Errorf("a statement holds %q: %s", bad, q)
			}
		}
	}
}
