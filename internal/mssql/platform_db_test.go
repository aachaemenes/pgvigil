package mssql

import (
	"os"
	"strings"
	"testing"
)

// The cloud services' own databases (G1 on a real Cloud SQL instance, 2026-11-13: gcloud_cloudsqladmin, which no
// monitor login can enter, left mssql_identity, mssql_indexes, mssql_querystore and mssql_stats partial): each is its
// own service's alone, by name without case.
func TestPlatformOwnDatabase(t *testing.T) {
	for _, c := range []struct {
		kind Kind
		name string
		want bool
	}{
		{KindRDS, "rdsadmin", true}, {KindRDS, "RDSADMIN", true}, {KindCloudSQL, "gcloud_cloudsqladmin", true}, {KindCloudSQL, "GCloud_CloudSQLAdmin", true},
		{KindCloudSQL, "rdsadmin", false}, {KindRDS, "gcloud_cloudsqladmin", false}, {KindServer, "gcloud_cloudsqladmin", false}, {KindCloudSQL, "sales", false},
	} {
		if got := platformOwnDatabase(c.kind, c.name); got != c.want {
			t.Errorf("platformOwnDatabase(%s, %s) = %v, want %v", c.kind, c.name, got, c.want)
		}
	}
	for _, n := range []string{"rdsadmin", "gcloud_cloudsqladmin"} {
		if (dbFacts{r: map[string]any{"database_id": int64(5), "state": "ONLINE", "database_name": n}}).user() {
			t.Errorf("dboptions' user() counts %s as a user database", n)
		}
	}
}

// Every per-database read leaves the services' own databases out through platformOwnDatabase: userDatabases (the
// indexes and statistics), the identity scan and the Query Store's list. A new per-database loop that forgets it
// fails here.
func TestPlatformOwnDatabaseInEveryDatabaseLoop(t *testing.T) {
	for file, want := range map[string]int{"indexes.go": 1, "dboptions.go": 1, "querystore.go": 1} {
		b, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		if got := strings.Count(string(b), "if platformOwnDatabase(info.Kind, name) {"); got != want {
			t.Errorf("%s calls platformOwnDatabase in %d database loop(s), want %d", file, got, want)
		}
	}
}
