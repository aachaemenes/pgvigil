package demo

import (
	"math"
	"strings"
	"time"
)

// The files, volumes and version store of the demo's SQL Server instances, in the payload shapes the import
// functions of 0067 read: sql01 is the busy one (a volume at 7 % free, a file one growth from its maximum, a per
// cent growth on a large file, a version store one session holds for the last hour), sql02 is quiet, sql03 has a
// log larger than its data and accelerated database recovery with aborted transactions in its store.

const mib = int64(1) << 20

type mssqlDemoFile struct {
	db, name, typ, fg, path, vol string
	startGiB, endGiB             float64 // the size a year before `end`, and at `end`
	usedShare                    float64 // of the size
	maxGiB                       float64 // 0 = until the volume is full
	growthMiB                    int64   // a size step; 0 with growthPct 0 = does not grow
	growthPct                    int64
}

func mssqlDemoFiles(name string) []mssqlDemoFile {
	switch {
	case strings.HasSuffix(name, "-sql01"):
		return []mssqlDemoFile{
			{"Sales", "Sales_data", "ROWS", "PRIMARY", `E:\Data\Sales.mdf`, `E:\`, 210, 388, 0.91, 0, 0, 10}, // a per cent growth on a large file
			{"Sales_archive", "Sales_archive_data", "ROWS", "PRIMARY", `E:\Data\Sales_archive.mdf`, `E:\`, 120, 164, 0.97, 0, 4096, 0},
			{"Sales_archive", "Sales_archive_log", "LOG", "", `L:\Log\Sales_archive_log.ldf`, `L:\`, 4, 4, 0.10, 0, 512, 0},
			{"staging_import", "staging_import", "ROWS", "PRIMARY", `E:\Data\staging_import.mdf`, `E:\`, 3, 3, 0.60, 0, 512, 0},
			{"staging_import", "staging_import_log", "LOG", "", `L:\Log\staging_import_log.ldf`, `L:\`, 1, 9, 0.93, 0, 512, 0}, // no log backup: the log grows
			{"scratch_etl", "scratch_etl", "ROWS", "PRIMARY", `E:\Data\scratch_etl.mdf`, `E:\`, 1, 1, 0.40, 0, 256, 0},
			{"scratch_etl", "scratch_etl_log", "LOG", "", `L:\Log\scratch_etl_log.ldf`, `L:\`, 0.25, 0.25, 0.10, 0, 64, 0},
			{"Sales", "Sales_log", "LOG", "", `L:\Log\Sales_log.ldf`, `L:\`, 24, 32, 0.22, 0, 1024, 0},
			{"Orders", "Orders_data", "ROWS", "PRIMARY", `E:\Data\Orders.mdf`, `E:\`, 61, 93, 0.88, 96, 4096, 0}, // one growth from its maximum
			{"Orders", "Orders_log", "LOG", "", `L:\Log\Orders_log.ldf`, `L:\`, 8, 12, 0.35, 0, 1024, 0},
			{"Reporting", "Reporting_data", "ROWS", "PRIMARY", `E:\Data\Reporting.mdf`, `E:\`, 40, 58, 0.74, 0, 2048, 0},
			{"Reporting", "Reporting_log", "LOG", "", `L:\Log\Reporting_log.ldf`, `L:\`, 6, 6, 0.10, 0, 512, 0},
			{"tempdb", "tempdev", "ROWS", "PRIMARY", `T:\TempDB\tempdb.mdf`, `T:\`, 16, 16, 0.40, 0, 1024, 0},
			{"tempdb", "temp2", "ROWS", "PRIMARY", `T:\TempDB\tempdb_2.ndf`, `T:\`, 16, 16, 0.40, 0, 1024, 0},
			{"tempdb", "templog", "LOG", "", `T:\TempDB\templog.ldf`, `T:\`, 4, 4, 0.15, 0, 512, 0},
			{"msdb", "MSDBData", "ROWS", "PRIMARY", `C:\SQL\MSDBData.mdf`, `C:\`, 1.2, 2.9, 0.80, 0, 0, 10},
			{"msdb", "MSDBLog", "LOG", "", `C:\SQL\MSDBLog.ldf`, `C:\`, 0.5, 0.6, 0.20, 0, 0, 10},
		}
	case strings.HasSuffix(name, "-sql03"):
		return []mssqlDemoFile{
			{"Ledger", "Ledger_data", "ROWS", "PRIMARY", "/var/opt/mssql/data/Ledger.mdf", "/var/opt/mssql/data/", 18, 26, 0.86, 0, 1024, 0},
			{"Ledger", "Ledger_log", "LOG", "", "/var/opt/mssql/log/Ledger_log.ldf", "/var/opt/mssql/log/", 9, 41, 0.64, 0, 1024, 0}, // a log larger than its data
			{"Staging", "Staging_data", "ROWS", "PRIMARY", "/var/opt/mssql/data/Staging.mdf", "/var/opt/mssql/data/", 30, 33, 0.52, 0, 1024, 0},
			{"Staging", "Staging_log", "LOG", "", "/var/opt/mssql/log/Staging_log.ldf", "/var/opt/mssql/log/", 4, 4, 0.08, 0, 512, 0},
			{"tempdb", "tempdev", "ROWS", "PRIMARY", "/var/opt/mssql/data/tempdb.mdf", "/var/opt/mssql/data/", 8, 8, 0.30, 0, 512, 0},
			{"tempdb", "templog", "LOG", "", "/var/opt/mssql/data/templog.ldf", "/var/opt/mssql/data/", 2, 2, 0.10, 0, 256, 0},
		}
	case strings.HasSuffix(name, "-sql02"):
		return []mssqlDemoFile{
			// the group's two databases, as on the primary, and one of its own
			{"Sales", "Sales_data", "ROWS", "PRIMARY", `D:\Data\Sales.mdf`, `D:\`, 210, 388, 0.91, 0, 4096, 0},
			{"Sales", "Sales_log", "LOG", "", `D:\Log\Sales_log.ldf`, `D:\`, 24, 32, 0.22, 0, 1024, 0},
			{"Sales_archive", "Sales_archive_data", "ROWS", "PRIMARY", `D:\Data\Sales_archive.mdf`, `D:\`, 120, 164, 0.97, 0, 4096, 0},
			{"Sales_archive", "Sales_archive_log", "LOG", "", `D:\Log\Sales_archive_log.ldf`, `D:\`, 4, 4, 0.10, 0, 512, 0},
			{"Vault", "Vault_data", "ROWS", "PRIMARY", `D:\Data\Vault.mdf`, `D:\`, 12, 14, 0.70, 0, 512, 0}, // the read login has no user there
			{"Vault", "Vault_log", "LOG", "", `D:\Log\Vault_log.ldf`, `D:\`, 2, 2, 0, 0, 256, 0},
			{"tempdb", "tempdev", "ROWS", "PRIMARY", `D:\TempDB\tempdb.mdf`, `D:\`, 8, 8, 0.25, 0, 512, 0},
			{"tempdb", "templog", "LOG", "", `D:\TempDB\templog.ldf`, `D:\`, 2, 2, 0.10, 0, 256, 0},
		}
	}
	return nil
}

// the volumes: total GiB and what besides the database files sits on them (backups, the OS), in GiB
var mssqlDemoVolumes = map[string][2]float64{
	`E:\`: {800, 46}, `L:\`: {120, 4}, `T:\`: {80, 2}, `C:\`: {120, 71}, `D:\`: {900, 38},
	"/var/opt/mssql/data/": {200, 12}, "/var/opt/mssql/log/": {100, 3},
}

// mssqlStorageRows is one mssql_storage payload of a demo SQL Server instance at t: every file at its size on the
// year's line (a step every growth increment, as a real file grows), and the volumes with what is left on them.
func mssqlStorageRows(name string, t, end time.Time) []Row {
	files := mssqlDemoFiles(name)
	if files == nil {
		return nil
	}
	year := 365 * 24 * time.Hour
	at := 1 - float64(end.Sub(t))/float64(year) // 0 a year ago, 1 at the end
	at = math.Max(0, math.Min(1, at))
	dbID := map[string]int{}
	fileNo := map[string]int{}
	usedOn := map[string]float64{}
	countOn := map[string]int{}
	var rows []Row
	for _, f := range files {
		if _, ok := dbID[f.db]; !ok {
			dbID[f.db] = 5 + len(dbID)
			if f.db == "tempdb" {
				dbID[f.db] = 2
			}
			if f.db == "msdb" {
				dbID[f.db] = 4
			}
		}
		fileNo[f.db]++
		size := f.startGiB + (f.endGiB-f.startGiB)*at
		step := float64(f.growthMiB) / 1024
		if step > 0 {
			size = f.startGiB + math.Floor((size-f.startGiB)/step)*step // a file grows in its steps
		}
		sizeB := int64(size * float64(gib))
		row := Row{"kind": "file", "database_id": dbID[f.db], "database_name": f.db, "database_state": "ONLINE",
			"file_id": fileNo[f.db], "file_name": f.name, "type_desc": f.typ, "physical_name": f.path, "state_desc": "ONLINE",
			"size_bytes": sizeB, "growth_bytes": f.growthMiB * mib, "growth_pct": f.growthPct, "volume": f.vol}
		if f.fg != "" {
			row["filegroup"] = f.fg
		}
		if f.maxGiB > 0 {
			row["max_size_bytes"] = int64(f.maxGiB * float64(gib))
		}
		if f.db == "Vault" {
			row["used_read"], row["used_note"] = 0, "used not read: the login cannot enter the database"
		} else {
			row["used_read"], row["used_bytes"] = 1, int64(float64(sizeB)*f.usedShare)
		}
		rows = append(rows, row)
		usedOn[f.vol] += size
		countOn[f.vol]++
	}
	for vol, n := range countOn {
		v := mssqlDemoVolumes[vol]
		total := int64(v[0] * float64(gib))
		used := int64((usedOn[vol] + v[1]) * float64(gib))
		r := Row{"kind": "volume", "volume": vol, "total_bytes": total, "free_bytes": total - used, "files": n}
		if !strings.HasPrefix(vol, "/") {
			r["logical_name"], r["file_system"] = map[string]string{`E:\`: "Data", `L:\`: "Log", `T:\`: "TempDB", `C:\`: "OS", `D:\`: "SQL"}[vol], "NTFS"
		}
		rows = append(rows, r)
	}
	return rows
}

// mssqlVersionStoreRows is one mssql_versionstore payload at t. On sql01 a reporting session opened a snapshot
// transaction an hour before `end` and never closed it: from then the store grows by what the writers generate
// (about 9 MB a minute) and cleanup stands at zero; before that the store idles at about 60 MB with cleanup keeping
// up. sql02 idles. sql03 has accelerated database recovery on Ledger with aborted transactions in its store.
func mssqlVersionStoreRows(name string, t, end time.Time) []Row {
	if mssqlDemoFiles(name) == nil {
		return nil
	}
	mins := int64(t.Unix() / 60) // the cumulative counters count from the epoch: they only ever rise
	held := end.Add(-time.Hour)  // the holder's transaction starts here
	genPerMin, baseKB := int64(9216), int64(61440)
	tempdbKB := int64(32) * 1024 * 1024
	if !strings.HasSuffix(name, "-sql01") {
		genPerMin, baseKB, tempdbKB = 512, 4096, 8*1024*1024
	}
	gen := mins * genPerMin
	clean := gen - baseKB // cleanup keeps up: the store stays at its base
	store := baseKB
	rows := []Row{}
	if strings.HasSuffix(name, "-sql01") && !t.Before(held) {
		heldMins := int64(t.Sub(held) / time.Minute)
		clean = (int64(held.Unix()/60))*genPerMin - baseKB // cleanup stopped when the holder started
		store = baseKB + heldMins*genPerMin
		// the last twenty minutes a batch load doubles the churn: the store passes a third of tempdb
		// (the load ends at the anchor: on the live ticks after it the store grows at the writers' own rate again)
		if left := max(int64(end.Sub(t)/time.Minute), 0); left < 20 {
			store += (20 - left) * 600000
			gen += (20 - left) * 600000
		}
		rows = append(rows, Row{"kind": "holder", "session_id": 97, "login_name": "report_svc", "host_name": "RPT-APP02",
			"program_name": "Reporting Scheduler", "database_name": "Sales", "is_snapshot": 1,
			"started_at_utc": held.UTC().Format(time.RFC3339), "elapsed_s": int64(t.Sub(held) / time.Second),
			"statement": "SET TRANSACTION ISOLATION LEVEL SNAPSHOT; BEGIN TRANSACTION; SELECT region, SUM(amount) FROM dbo.order_lines WHERE order_date >= @from GROUP BY region;"})
	}
	n := 0
	if len(rows) > 0 {
		n = 1
	}
	rows = append(rows, Row{"kind": "store", "store_kb": store, "reserved_kb": store, "tempdb_data_kb": tempdbKB,
		"generation_raw_kb": gen, "cleanup_raw_kb": clean, "snapshot_tx_count": n})
	switch {
	case strings.HasSuffix(name, "-sql01"):
		rows = append(rows, Row{"kind": "db", "database_name": "Sales", "reserved_kb": store * 8 / 10},
			Row{"kind": "db", "database_name": "Orders", "reserved_kb": store * 2 / 10})
	case strings.HasSuffix(name, "-sql03"):
		rows = append(rows, Row{"kind": "pvs", "database_name": "Ledger", "adr_on": 1, "pvs_kb": int64(3400) * 1024, "online_index_kb": 0,
			"aborted_tx_count": 4, "oldest_active_tx_id": 918273, "oldest_aborted_tx_id": 918101, "oldest_tx_session_id": 64,
			"oldest_tx_started_at_utc": end.Add(-95 * time.Minute).UTC().Format(time.RFC3339)})
	}
	// the markers: the read succeeded, so the per-database states are replaced even when no database is listed
	return append(rows, Row{"kind": "db", "database_name": nil}, Row{"kind": "pvs", "database_name": nil})
}
