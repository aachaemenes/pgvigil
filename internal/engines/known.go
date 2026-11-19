package engines

import (
	"fmt"

	"github.com/aachaemenes/pgvigil/internal/mssql"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// The servers this build knows (RELNOTES L217): its query sets and version gates are written and tested for these.
const (
	PGOldestMajor    = 13
	PGNewestMajor    = 18
	MSSQLOldestMajor = 13 // SQL Server 2016
	MSSQLNewestMajor = 17 // SQL Server 2025
)

// knownEditions: the SQL Server engine editions pgvigil runs on (SERVERPROPERTY('EngineEdition')); 6 and 11 (Azure
// Synapse) are refused by the detect itself.
var knownEditions = map[int]bool{2: true, 3: true, 4: true, 5: true, 8: true, 9: true}

// editionNames: Microsoft's names for the editions pgvigil does not run on (SERVERPROPERTY's page, 2026-01-08).
var editionNames = map[int]string{1: "Personal or Desktop Engine", 12: "Microsoft Fabric's SQL database"}

// UnknownServer is the warning 'pgvigil check' gives for a server this build does not know ("" = it knows it): what
// was read and what pgvigil does with it. Nothing is refused for it: each collection keeps its own version rule.
func UnknownServer(pg *platform.Info, ms *mssql.Info) string {
	const runs = "each collection still runs under its own version rule, and one whose read breaks fails alone with the server's error"
	if pg != nil && pg.ServerVersionNum > 0 {
		major := pg.ServerVersionNum / 10000
		switch {
		case major > PGNewestMajor:
			return fmt.Sprintf("PostgreSQL %d is newer than this build knows (%d to %d): %s; a pgvigil release that names %d is the fix", major, PGOldestMajor, PGNewestMajor, runs, major)
		case major < PGOldestMajor:
			return fmt.Sprintf("PostgreSQL %d is older than this build knows (%d to %d): %s", major, PGOldestMajor, PGNewestMajor, runs)
		}
	}
	if ms == nil {
		return ""
	}
	if !knownEditions[ms.EngineEdition] {
		name := editionNames[ms.EngineEdition]
		if name != "" {
			name = " (" + name + ")"
		}
		return fmt.Sprintf("engine edition %d%s is one this build does not know (it runs on 2 Standard, 3 Enterprise, 4 Express, 5 Azure SQL Database, 8 Managed Instance, 9 Azure SQL Edge): its collections run as on %s; %s", ms.EngineEdition, name, ms.Kind, runs)
	}
	// Azure SQL Database and Managed Instance answer major 12 whatever engine they run: their major names no release
	if ms.Kind == mssql.KindAzureDB || ms.Kind == mssql.KindAzureMI || ms.Major == 0 {
		return ""
	}
	switch {
	case ms.Major > MSSQLNewestMajor:
		return fmt.Sprintf("SQL Server major version %d (%s) is newer than this build knows (%d to %d, SQL Server 2016 to 2025): %s; a pgvigil release that names it is the fix", ms.Major, ms.ProductVersion, MSSQLOldestMajor, MSSQLNewestMajor, runs)
	case ms.Major < MSSQLOldestMajor:
		return fmt.Sprintf("SQL Server major version %d (%s) is older than this build knows (%d to %d, SQL Server 2016 to 2025): %s", ms.Major, ms.ProductVersion, MSSQLOldestMajor, MSSQLNewestMajor, runs)
	}
	return ""
}
