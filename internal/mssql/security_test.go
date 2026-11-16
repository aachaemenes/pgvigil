package mssql

import (
	"context"
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

// TestSecurityRegistryOffWhereHostOnly: on a platform that runs the host - Azure SQL
// Database, Managed Instance, Amazon RDS, Google Cloud SQL - the security read never calls xp_instance_regread and never
// prints a GRANT for it; the rights page says the same there (hostOnly). A server someone runs reads it.
func TestSecurityRegistryOffWhereHostOnly(t *testing.T) {
	for _, k := range []Kind{KindAzureDB, KindAzureMI, KindRDS, KindCloudSQL} {
		why := secRegreadOff(Info{Kind: k, Major: 16})
		if !strings.Contains(why, "the registry is not read there") {
			t.Errorf("%s: secRegreadOff = %q, want the platform's words ('... the registry is not read there')", k, why)
		}
		if on := hostOnly(Info{Kind: k, Major: 16}); on == "" {
			t.Errorf("%s: hostOnly lists the registry right as applying, the read skips it", k)
		}
	}
	if why := secRegreadOff(Info{Kind: KindServer, Major: 16}); why != "" {
		t.Errorf("a server someone runs: secRegreadOff = %q, want it read", why)
	}
}

// TestSecurityRegistryPartWhereHostOnly: the registry part itself, run with no connection (no sys.dm_server_registry
// read, no xp_instance_regread right): where the platform runs the host each value is noted in the platform's words,
// no GRANT is printed and the part is 'n/a'; on a server someone runs the missing right is printed and the part is
// 'no right' - so the read skipping xp_instance_regread is the part's own doing, not secRegreadOff's alone.
func TestSecurityRegistryPartWhereHostOnly(t *testing.T) {
	part := func(k Kind) collect.Row {
		r := &secRun{ctx: context.Background(), info: Info{Kind: k, Major: 16}, want: map[string]bool{"registry": true},
			ctxt: secContext{Login: "pgvigil_reader"}}
		r.registry()
		for _, row := range r.out {
			if row["kind"] == "part" && row["part"] == "registry" {
				return row
			}
		}
		t.Fatalf("%s: the registry part wrote no part row: %v", k, r.out)
		return nil
	}
	for _, k := range []Kind{KindAzureDB, KindAzureMI, KindRDS, KindCloudSQL} {
		row := part(k)
		note, _ := row["note"].(string)
		if row["status"] != "n/a" || strings.Contains(note, "GRANT") || !strings.Contains(note, "the registry is not read there") {
			t.Errorf("%s: the registry part %v %q, want 'n/a' in the platform's words and no GRANT", k, row["status"], note)
		}
	}
	row := part(KindServer)
	if note, _ := row["note"].(string); row["status"] != "no right" || !strings.Contains(note, "GRANT EXECUTE ON master.dbo.xp_instance_regread TO [pgvigil_reader]") {
		t.Errorf("a server someone runs: the registry part %v %q, want 'no right' with the GRANT", row["status"], note)
	}
}
