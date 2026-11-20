package engines

import (
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/mssql"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// TestUnknownServerL217 (RELNOTES L217): 'pgvigil check' warns on a server this build does not know - a PostgreSQL
// major outside 13 to 18, a SQL Server major outside 13 to 17 where the major means a release (a server, RDS, Cloud
// SQL; Azure SQL Database and Managed Instance answer 12 whatever they run), an engine edition pgvigil does not run on
// - and says nothing for one it knows. The words name what was read and what pgvigil does with it.
func TestUnknownServerL217(t *testing.T) {
	pg := func(num int) *platform.Info { return &platform.Info{ServerVersionNum: num} }
	ms := func(edition, major int, kind mssql.Kind) *mssql.Info {
		return &mssql.Info{EngineEdition: edition, Major: major, Kind: kind, ProductVersion: "x"}
	}
	for _, c := range []struct {
		name string
		pg   *platform.Info
		ms   *mssql.Info
		want []string // "" = no warning; else words the warning carries
	}{
		{"PostgreSQL 18", pg(180001), nil, nil},
		{"PostgreSQL 13", pg(130020), nil, nil},
		{"PostgreSQL 19", pg(190000), nil, []string{"PostgreSQL 19", "newer than this build knows", "13 to 18"}},
		{"PostgreSQL 12", pg(120022), nil, []string{"PostgreSQL 12", "older than this build knows", "13 to 18"}},
		{"SQL Server 2025 Standard", nil, ms(2, 17, mssql.KindServer), nil},
		{"SQL Server 2016 Enterprise", nil, ms(3, 13, mssql.KindServer), nil},
		{"SQL Server 18 on a server", nil, ms(3, 18, mssql.KindServer), []string{"major version 18", "newer than this build knows", "13 to 17"}},
		{"SQL Server 2014 on RDS", nil, ms(2, 12, mssql.KindRDS), []string{"major version 12", "older than this build knows"}},
		{"Azure SQL Database answers 12", nil, ms(5, 12, mssql.KindAzureDB), nil},
		{"Managed Instance answers 12", nil, ms(8, 12, mssql.KindAzureMI), nil},
		{"Azure SQL Edge", nil, ms(9, 15, mssql.KindServer), nil},
		{"Fabric's SQL database", nil, ms(12, 12, mssql.KindServer), []string{"engine edition 12", "Microsoft Fabric", "does not know"}},
		{"an edition with no name", nil, ms(14, 17, mssql.KindServer), []string{"engine edition 14", "does not know"}},
		{"nothing read", nil, nil, nil},
	} {
		got := UnknownServer(c.pg, c.ms)
		if len(c.want) == 0 {
			if got != "" {
				t.Errorf("%s: no warning wanted, got %q", c.name, got)
			}
			continue
		}
		for _, w := range c.want {
			if !strings.Contains(got, w) {
				t.Errorf("%s: %q lacks %q", c.name, got, w)
			}
		}
	}
}
