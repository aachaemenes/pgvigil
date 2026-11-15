package mssql

import (
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// TestCertUse: a master certificate's use from its row of the use read; a test the login had no right for (NULL) and
// no use found is "unknown", never "no use" (the hit then keeps the rule's severity).
func TestCertUse(t *testing.T) {
	all := func(tde, backup, mirroring, broker any) collect.Row {
		return collect.Row{"tde": tde, "backup_encryptor": backup, "mirroring_endpoint": mirroring, "broker_endpoint": broker}
	}
	for _, c := range []struct {
		name string
		row  collect.Row
		want any
	}{
		{"no row at all", nil, "unknown"},
		{"every test read, no use", all(int64(0), int64(0), int64(0), int64(0)), nil},
		{"TDE", all(int64(1), int64(0), int64(0), int64(0)), "TDE"},
		{"TDE not read, nothing else", all(nil, int64(0), int64(0), int64(0)), "unknown"},
		{"TDE not read, a backup found", all(nil, int64(1), int64(0), int64(0)), "backup encryption"},
		{"two uses", all(int64(1), int64(0), int64(1), int64(0)), "mirroring / availability group endpoint, TDE"},
		{"nothing read", all(nil, nil, nil, nil), "unknown"},
	} {
		if got := certUse(c.row); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// TestCertUseSQL: each test of the use read only with its own right; one the login lacks is NULL in the statement
// and named in the note's list.
func TestCertUseSQL(t *testing.T) {
	r := &secRun{ctxt: secContext{Login: "pgv"}}
	q, missing := r.certUseSQL()
	if strings.Contains(q, "dm_database_encryption_keys") || strings.Contains(q, "msdb.dbo.backupset") || strings.Contains(q, "_endpoints") {
		t.Errorf("no rights, yet the statement reads a DMV, msdb or the endpoints:\n%s", q)
	}
	if len(missing) != 3 {
		t.Errorf("no rights: missing %v, want three", missing)
	}
	r.ctxt = secContext{VSSS: true, CanBackupset: true, VAD: true}
	q, missing = r.certUseSQL()
	for _, s := range []string{"dm_database_encryption_keys", "msdb.dbo.backupset", "database_mirroring_endpoints", "service_broker_endpoints"} {
		if !strings.Contains(q, s) {
			t.Errorf("every right (VIEW SERVER SECURITY STATE for TDE), yet no %s in:\n%s", s, q)
		}
	}
	if len(missing) != 0 {
		t.Errorf("every right: missing %v", missing)
	}
}

// TestSecAuthOwnSQLNeedsNoRight: the collector's own connection is read without a DMV (dm_exec_connections refuses
// even a login's own row without VIEW SERVER STATE).
func TestSecAuthOwnSQLNeedsNoRight(t *testing.T) {
	if strings.Contains(secAuthOwnSQL, "dm_exec_connections") || !strings.Contains(secAuthOwnSQL, "CONNECTIONPROPERTY('auth_scheme')") {
		t.Errorf("the own connection's read: %s", secAuthOwnSQL)
	}
}
