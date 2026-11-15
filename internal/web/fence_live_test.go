package web

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

// The two fences of the DBA's own SQL on SQL Server, against a live server (scripts/proof-custom-mssql.sh sets the
// variables; skipped without them):
//
//   - custom reports (ST6's one fence, mssqlread.Fence): the documented read login runs; a login with one right more
//     (ALTER ANY CONNECTION) is refused by that right's name; a sysadmin is refused;
//
//   - community tools keep openMS as it was (the lead 11-15 12:5x: they run named procedures pgvigil knows, some
//     needing rights outside a read-only allowlist): the same login with one right more is let in, a sysadmin is not.
//
//     PGVIGIL_ST6_MON_DSN    the documented read login
//     PGVIGIL_ST6_EXTRA_DSN  the documented login with ALTER ANY CONNECTION
//     PGVIGIL_ST6_SA_DSN     a sysadmin login
func TestST6FencesLive(t *testing.T) {
	mon, extra, sa := os.Getenv("PGVIGIL_ST6_MON_DSN"), os.Getenv("PGVIGIL_ST6_EXTRA_DSN"), os.Getenv("PGVIGIL_ST6_SA_DSN")
	if mon == "" || extra == "" || sa == "" {
		t.Skip("PGVIGIL_ST6_MON_DSN, PGVIGIL_ST6_EXTRA_DSN and PGVIGIL_ST6_SA_DSN name a live SQL Server's logins (scripts/proof-custom-mssql.sh)")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	report := func(dsn string) (string, error) {
		sets, why, err := runMSWith(ctx, dsn, "SELECT 1 AS one", nil, 30*time.Second, 10, true, reportFence)
		if err == nil && why == "" && (len(sets) != 1 || len(sets[0].Rows) != 1) {
			t.Errorf("the report's rows: %+v", sets)
		}
		return why, err
	}
	if why, err := report(mon); err != nil || why != "" {
		t.Errorf("a custom report as the documented read login: refused %q, %v", why, err)
	}
	if why, err := report(extra); err != nil || !strings.Contains(why, "custom reports run only as the documented read login") || !strings.Contains(why, "ALTER ANY CONNECTION") {
		t.Errorf("a custom report as the login with ALTER ANY CONNECTION: %q, %v (want the refusal naming the right)", why, err)
	}
	if why, err := report(sa); err != nil || !strings.Contains(why, "sysadmin") {
		t.Errorf("a custom report as a sysadmin: %q, %v", why, err)
	}
	community := func(dsn string) (string, error) {
		db, conn, why, err := openMS(ctx, dsn, "pgvigil-community")
		if conn != nil {
			_ = conn.Close()
		}
		if db != nil {
			_ = db.Close()
		}
		return why, err
	}
	if why, err := community(extra); err != nil || why != "" {
		t.Errorf("community tools as the login with ALTER ANY CONNECTION: refused %q, %v (they keep openMS's sysadmin check alone)", why, err)
	}
	if why, err := community(sa); err != nil || !strings.Contains(why, "is a member of sysadmin") {
		t.Errorf("community tools as a sysadmin: %q, %v (want the refusal)", why, err)
	}
}
