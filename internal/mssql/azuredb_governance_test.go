package mssql

import (
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// mssql_azuredb_governance: Azure SQL Database only; VIEW DATABASE STATE, except on Basic, S0, S1 and in an elastic
// pool, where Microsoft asks the server admin, the Entra admin or ##MS_ServerStateReader##.
func TestAzureDBGovernanceApplies(t *testing.T) {
	for _, c := range []struct {
		info Info
		run  bool
		word string
	}{
		{Info{Kind: KindAzureDB, ServiceObjective: "GP_S_Gen5_1", ViewDatabaseState: true}, true, ""},
		{Info{Kind: KindAzureDB, ServiceObjective: "GP_S_Gen5_1"}, false, "the login lacks VIEW DATABASE STATE: the tier's limits are not readable"},
		{Info{Kind: KindAzureDB, ServiceObjective: "Basic", ViewDatabaseState: true}, false, "the login lacks ##MS_ServerStateReader## (Basic, S0, S1 and elastic pools): the tier's limits are not readable"},
		{Info{Kind: KindAzureDB, ServiceObjective: "ElasticPool", ViewDatabaseState: true}, false, "##MS_ServerStateReader##"},
		{Info{Kind: KindAzureDB, ServiceObjective: "S1", ViewServerState: true, ViewDatabaseState: true}, true, ""},
		{Info{Kind: KindAzureMI, ViewServerState: true, ViewDatabaseState: true}, false, "Azure SQL Database's"},
	} {
		run, why := azureDBGovernanceCollector{}.Applies(c.info)
		if run != c.run || !strings.Contains(why, c.word) {
			t.Errorf("%+v: %v %q, want %v with %q", c.info, run, why, c.run, c.word)
		}
	}
	if (azureDBGovernanceCollector{}).Name() != "mssql_azuredb_governance" || (azureDBGovernanceCollector{}).DefaultInterval() != time.Hour {
		t.Error("the collection is mssql_azuredb_governance, hourly")
	}
}

// The view's row (every column, as FOR JSON gives it), the database's edition, service objective and max size, and
// the pool's name: the service objectives view's where the login may read it, else the tag, else a sentence.
func TestAzureDBGovernanceRow(t *testing.T) {
	gov := collect.Row{"gov": `{"database_id":5,"slo_name":"SQLDB_GP_S_GEN5_1","dtu_limit":null,"cpu_limit":1,"user_data_directory_space_usage_mb":12}`,
		"edition": "GeneralPurpose", "service_objective": "GP_S_Gen5_1", "max_size_bytes": int64(34359738368)}
	rows, err := azdbGovernance([]collect.Row{gov}, nil, "", "GP_S_Gen5_1")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0]["kind"] != "governance" {
		t.Fatalf("rows %v, want one governance row", rows)
	}
	r := rows[0]
	g, ok := r["gov"].(map[string]any)
	if !ok || g["slo_name"] != "SQLDB_GP_S_GEN5_1" || g["cpu_limit"] != 1.0 || g["dtu_limit"] != nil {
		t.Errorf("gov %#v, want the view's row as an object", r["gov"])
	}
	if r["edition"] != "GeneralPurpose" || r["service_objective"] != "GP_S_Gen5_1" || r["max_size_bytes"] != int64(34359738368) || r["pool"] != nil || r["pool_note"] != nil {
		t.Errorf("row %v: the database's own figures, no pool", r)
	}

	// in a pool: the service objectives view's name; without it the tag's; without either the sentence
	pooled := collect.Row{"gov": `{"database_id":5,"dtu_limit":5}`, "edition": "Basic", "service_objective": "ElasticPool", "max_size_bytes": int64(2147483648)}
	for _, c := range []struct {
		obj        []collect.Row
		tag        string
		pool, from any
		note       string
	}{
		{[]collect.Row{{"pool": "pgvpool"}}, "", "pgvpool", "service objectives", ""},
		{nil, "tagpool", "tagpool", "tag", ""},
		{nil, "", nil, nil, "the service objectives view answers dbManager, the database's creator or owner: the pool name comes from the tag pool:<name>"},
	} {
		rows, err := azdbGovernance([]collect.Row{pooled}, c.obj, c.tag, "ElasticPool")
		if err != nil {
			t.Fatal(err)
		}
		r := rows[0]
		note, _ := r["pool_note"].(string)
		if r["pool"] != c.pool || r["pool_from"] != c.from || note != c.note {
			t.Errorf("objectives %v tag %q: pool %v from %v note %q, want %v %v %q", c.obj, c.tag, r["pool"], r["pool_from"], note, c.pool, c.from, c.note)
		}
	}

	// no row in the view: the run is partial with the words, nothing stored as a tier
	rows, err = azdbGovernance([]collect.Row{{"gov": nil, "edition": "Basic", "service_objective": "Basic", "max_size_bytes": nil}}, nil, "", "Basic")
	if err != nil || len(rows) != 1 || rows[0]["kind"] != "collector_error" || !strings.Contains(rows[0]["message"].(string), "no row for the database") {
		t.Errorf("no row: %v %v, want one collector_error row", rows, err)
	}
	// a row that is not JSON is an error
	if _, err := azdbGovernance([]collect.Row{{"gov": "{", "edition": "Basic"}}, nil, "", "Basic"); err == nil {
		t.Error("a broken JSON row: no error")
	}
	if !strings.Contains(azdbGovernanceSQL, "FROM sys.dm_user_db_resource_governance WHERE database_id = DB_ID() FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER") {
		t.Error("every column of the database's row, by FOR JSON")
	}
}
