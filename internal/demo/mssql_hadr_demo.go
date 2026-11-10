package demo

import (
	"fmt"
	"time"
)

// The availability group, Agent jobs and backups of the demo's SQL Server pair ("-sql01" the primary, "-sql02" the
// secondary), in the payload shapes the import functions of 0066 read: a two-replica group whose redo queue grows
// and drains, a failed job, a database in the full recovery model without a log backup.

const demoAgID = "5f6d1c2e-7a41-4c1b-9a53-0d2b6f3e8a10"

func z(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05Z") }

// demoRedoKB: the redo queue of sales on the secondary. A nightly index rebuild on the primary (01:00 UTC, 40
// minutes) makes it grow to about 900 MB and drain over the next 25 minutes; and once more in the last half hour
// of the seed, still over the 500 MB threshold at the anchor, so the finding is on the page.
func (g *Gen) demoRedoKB(t time.Time) int64 {
	shape := func(since time.Duration, grow, drain time.Duration, peak float64) float64 {
		switch {
		case since < 0 || since > grow+drain:
			return 0
		case since <= grow:
			return peak * float64(since) / float64(grow)
		default:
			return peak * (1 - float64(since-grow)/float64(drain))
		}
	}
	night := time.Date(t.Year(), t.Month(), t.Day(), 1, 0, 0, 0, time.UTC)
	v := shape(t.Sub(night), 40*time.Minute, 25*time.Minute, 900000)
	// the walk-through's lag: it builds over the 20 minutes before the anchor's last 8 and then holds over the
	// threshold, on the live ticks too, so the finding stays on the page while the demo is served
	if since := t.Sub(g.end.Add(-28 * time.Minute)); since > 20*time.Minute {
		v += 760000 * (0.86 + 0.1*noise("redohold", t))
	} else {
		v += shape(since, 20*time.Minute, 30*time.Minute, 760000)
	}
	return int64(v + 200*noise("redo", t))
}

func (g *Gen) mssqlAgDemoRows(t time.Time) []Row {
	sql01, sql02 := g.is("-sql01"), g.is("-sql02")
	if !sql01 && !sql02 {
		return nil
	}
	// the failover of the walk-through: DEMO-SQL02 was the primary until 30 minutes before the anchor, DEMO-SQL01 is
	// since. The minute read sees the primary change (mssql_ag_failovers) at the time AlwaysOn_health's events of
	// the Extended Events payload say it did.
	after := !t.Before(g.mssqlFailoverAt())
	primary := sql01 == after
	p, s := "DEMO-SQL01", "DEMO-SQL02" // the primary's and the secondary's server names at t
	if !after {
		p, s = s, p
	}
	replica := func(name string, local bool, role any, mode string, visible bool) Row {
		r := Row{"kind": "replica", "group_id": demoAgID, "group_name": "ag_sales", "cluster_type": "WSFC", "is_distributed": 0,
			"is_contained": 0, "backup_preference": "SECONDARY", "db_failover": 1, "primary_replica": p, "replica_server": name,
			"endpoint_url": "TCP://" + name + ":5022", "availability_mode": mode, "failover_mode": "AUTOMATIC", "seeding_mode": "AUTOMATIC",
			"secondary_connections": "READ_ONLY", "backup_priority": 50, "session_timeout": 10, "is_local": b2i(local)}
		if visible {
			r["role"], r["connected_state"], r["synchronization_health"], r["operational_state"], r["recovery_health"] = role, "CONNECTED", "HEALTHY", "ONLINE", "ONLINE"
			r["group_health"] = "HEALTHY"
		}
		return r
	}
	redo := g.demoRedoKB(t)
	db := func(name, rep string, isPrimary, local bool, redoKB int64) Row {
		r := Row{"kind": "database", "group_id": demoAgID, "group_name": "ag_sales", "replica_server": rep, "database_name": name,
			"is_local": b2i(local), "is_primary_replica": b2i(isPrimary), "synchronization_state": "SYNCHRONIZED",
			"synchronization_health": "HEALTHY", "database_state": "ONLINE", "is_suspended": 0, "last_commit_utc": z(t.Add(-2 * time.Second))}
		if !isPrimary {
			r["log_send_queue_kb"], r["log_send_rate_kb_s"] = int64(40+60*noise("send"+name, t)), 5200
			r["redo_queue_kb"], r["redo_rate_kb_s"] = redoKB, 14000
			r["est_recovery_s"] = float64(redoKB) / 14000
			r["last_hardened_utc"], r["last_received_utc"] = z(t.Add(-2*time.Second)), z(t.Add(-2*time.Second))
			r["last_redone_utc"] = z(t.Add(-time.Duration(2+redoKB/14000) * time.Second))
			if !local { // only the primary computes the data loss
				r["est_data_loss_s"] = 0
			}
		}
		return r
	}
	listener := Row{"kind": "listener", "group_id": demoAgID, "dns_name": "ag-sales-l", "port": 1433, "ip_configuration": "('IP Address: 10.20.0.50')"}
	var rows []Row
	if primary {
		rows = append(rows, replica(p, true, "PRIMARY", "SYNCHRONOUS_COMMIT", true), replica(s, false, "SECONDARY", "SYNCHRONOUS_COMMIT", true))
		for _, d := range []string{"Sales", "Sales_archive"} {
			q := int64(0)
			if d == "Sales" {
				q = redo
			}
			rows = append(rows, db(d, p, true, true, 0), db(d, s, false, false, q))
		}
	} else {
		rows = append(rows, replica(p, false, nil, "SYNCHRONOUS_COMMIT", false), replica(s, true, "SECONDARY", "SYNCHRONOUS_COMMIT", true))
		rows = append(rows, db("Sales", s, false, true, redo), db("Sales_archive", s, false, true, 0))
	}
	rows = append(rows, listener)
	for _, m := range []string{p, s, "DEMO-FSW"} {
		typ := "CLUSTER_NODE"
		if m == "DEMO-FSW" {
			typ = "FILE_SHARE_WITNESS"
		}
		rows = append(rows, Row{"kind": "cluster_member", "cluster_name": "DEMO-CL01", "quorum_type": "NODE_AND_FILE_SHARE_MAJORITY",
			"quorum_state": "NORMAL_QUORUM", "member_name": m, "member_type": typ, "member_state": "UP", "quorum_votes": 1})
	}
	return rows
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// mssqlJobsDemoRows: four jobs on the primary. 'ETL - load orders' failed at its second step at 02:10 UTC today
// (the finding); 'DBA - index maintenance' runs now when t falls in its nightly window. The history rows are sent
// for the last two days on every read (the import stores each once) without a cursor row, as a read without one.
func (g *Gen) mssqlJobsDemoRows(t time.Time) []Row {
	if !g.is("-sql01") {
		return nil
	}
	type job struct {
		id, name, sched string
		hour, min       int
		durS            int64
		failStep        int
	}
	jobs := []job{
		{"0a000000-0000-0000-0000-000000000001", "DBA - log backups", "every 15 minutes", -1, 0, 4, 0},
		{"0a000000-0000-0000-0000-000000000002", "DBA - full backups", "nightly 00:30", 0, 30, 410, 0},
		{"0a000000-0000-0000-0000-000000000003", "DBA - index maintenance", "nightly 01:00", 1, 0, 2400, 0},
		{"0a000000-0000-0000-0000-000000000004", "ETL - load orders", "nightly 02:10", 2, 10, 95, 2},
	}
	var rows []Row
	hid := func(at time.Time, j, step int) int64 { return at.Unix()/60*10 + int64(j)*3 + int64(step) }
	for ji, j := range jobs {
		last := time.Date(t.Year(), t.Month(), t.Day(), j.hour, j.min, 0, 0, time.UTC)
		if j.hour < 0 {
			last = t.Truncate(15 * time.Minute)
		} else if last.After(t) {
			last = last.Add(-24 * time.Hour)
		}
		every := 24 * time.Hour
		if j.hour < 0 {
			every = 15 * time.Minute
		}
		running := j.failStep == 0 && j.durS > 600 && t.Sub(last) < time.Duration(j.durS)*time.Second
		outcome, msg := 1, "The job succeeded.  The Job was invoked by Schedule 9 ("+j.sched+").  The last step to run was step 1."
		if j.failStep > 0 {
			outcome, msg = 0, fmt.Sprintf("The job failed.  The Job was invoked by Schedule 12 (%s).  The last step to run was step %d (merge into orders).", j.sched, j.failStep)
		}
		r := Row{"kind": "job", "job_id": j.id, "name": j.name, "enabled": 1, "category": "Database Maintenance", "owner": "sa",
			"schedules": 1, "enabled_schedules": 1, "schedule_names": j.sched, "next_run_utc": z(last.Add(every)),
			"last_outcome": outcome, "last_run_utc": z(last), "last_duration_s": j.durS, "last_message": msg}
		if running {
			r["running_since_utc"], r["running_after_step"] = z(last), 0
			r["last_run_utc"] = z(last.Add(-every))
		}
		rows = append(rows, r, Row{"kind": "step", "job_id": j.id, "step_id": 1, "step_name": "run", "subsystem": "TSQL", "database_name": "master",
			"last_outcome": 1, "last_run_utc": z(last), "last_duration_s": j.durS})
		if j.failStep == 2 {
			rows = append(rows, Row{"kind": "step", "job_id": j.id, "step_id": 2, "step_name": "merge into orders", "subsystem": "TSQL",
				"database_name": "Sales", "last_outcome": 0, "last_run_utc": z(last.Add(60 * time.Second)), "last_duration_s": 35})
		}
		// history: the last two days of the nightly jobs, the last three hours of the 15-minute one
		back := 48 * time.Hour
		if j.hour < 0 {
			back = 3 * time.Hour
		}
		for at := last; at.After(t.Add(-back)); at = at.Add(-every) {
			if running && at.Equal(last) {
				continue
			}
			failed := j.failStep > 0 && at.Equal(last) // only today's run failed
			st := 1
			if failed {
				st = 0
				rows = append(rows, Row{"kind": "run", "history_id": hid(at, ji, 1), "job_id": j.id, "job_name": j.name, "step_id": 1, "step_name": "run",
					"run_status": 1, "duration_s": 60, "run_utc": z(at), "message": "Executed as user: DEMO\\svc_sqlagent. The step succeeded."},
					Row{"kind": "run", "history_id": hid(at, ji, 2), "job_id": j.id, "job_name": j.name, "step_id": 2, "step_name": "merge into orders",
						"run_status": 0, "duration_s": 35, "run_utc": z(at.Add(60 * time.Second)), "sql_message_id": 2627, "sql_severity": 14,
						"message": "Executed as user: DEMO\\svc_sqlagent. Violation of PRIMARY KEY constraint 'PK_orders'. Cannot insert duplicate key in object 'dbo.orders'. The duplicate key value is (884213). [SQLSTATE 23000] (Error 2627)  The statement has been terminated. [SQLSTATE 01000] (Error 3621).  The step failed."})
			} else {
				rows = append(rows, Row{"kind": "run", "history_id": hid(at, ji, 1), "job_id": j.id, "job_name": j.name, "step_id": 1, "step_name": "run",
					"run_status": 1, "duration_s": j.durS, "run_utc": z(at), "message": "Executed as user: DEMO\\svc_sqlagent. The step succeeded."})
			}
			m := "The job succeeded."
			if failed {
				m = msg
			}
			rows = append(rows, Row{"kind": "run", "history_id": hid(at, ji, 3), "job_id": j.id, "job_name": j.name, "step_id": 0, "step_name": "(Job outcome)",
				"run_status": st, "duration_s": j.durS, "run_utc": z(at), "message": m})
		}
	}
	return append(rows, Row{"kind": "read", "cursor": false})
}

// mssqlBackupsDemoRows: on both replicas. Full backups run on the SECONDARY (the group's backup preference), log
// backups on the primary: each instance's row alone would alarm, the merged row does not. 'staging_import' is in
// the full recovery model with a full backup and no log backup at all (the finding); 'scratch_etl' has no backup
// and is new.
func (g *Gen) mssqlBackupsDemoRows(t time.Time) []Row {
	primary, secondary := g.is("-sql01"), g.is("-sql02")
	if !primary && !secondary {
		return nil
	}
	old := z(g.start.Add(-200 * 24 * time.Hour))
	dbRow := func(name, model string, inAg bool, created string) Row {
		r := Row{"kind": "database", "database_name": name, "state": "ONLINE", "recovery_model": model, "created_utc": created,
			"is_snapshot": 0, "is_read_only": 0, "is_standby": 0}
		if inAg {
			r["ag_group_id"], r["ag_name"] = demoAgID, "ag_sales"
		}
		return r
	}
	bk := func(name, typ string, at time.Time, size int64, durS int64) Row {
		return Row{"kind": "backup", "database_name": name, "backup_type": typ, "sink": "backup", "finish_utc": z(at), "duration_s": durS,
			"size_bytes": size, "compressed_bytes": size / 4, "is_copy_only": 0, "is_snapshot": 0, "device": "disk",
			"device_name": fmt.Sprintf("\\\\demo-bak01\\sql\\%s\\%s_%s.bak", name, name, at.UTC().Format("20060102_1504"))}
	}
	lastFull := time.Date(t.Year(), t.Month(), t.Day(), 0, 37, 0, 0, time.UTC)
	if lastFull.After(t) {
		lastFull = lastFull.Add(-24 * time.Hour)
	}
	lastLog := t.Truncate(15 * time.Minute).Add(4 * time.Second)
	if lastLog.After(t) {
		lastLog = lastLog.Add(-15 * time.Minute)
	}
	rows := []Row{dbRow("master", "SIMPLE", false, old), dbRow("model", "FULL", false, old), dbRow("msdb", "SIMPLE", false, old),
		dbRow("tempdb", "SIMPLE", false, z(g.pmStart)), dbRow("Sales", "FULL", true, old), dbRow("Sales_archive", "FULL", true, old)}
	for _, d := range []string{"master", "model", "msdb"} {
		rows = append(rows, bk(d, "full", lastFull.Add(-7*time.Minute), 6<<20, 2))
	}
	if secondary {
		// a full backup on a secondary replica is copy-only: SQL Server takes no other there
		copyOnly := func(r Row) Row { r["is_copy_only"] = 1; return r }
		rows = append(rows, copyOnly(bk("Sales", "full", lastFull, 84<<30, 410)), copyOnly(bk("Sales_archive", "full", lastFull.Add(3*time.Minute), 12<<30, 70)),
			dbRow("Vault", "SIMPLE", false, old), bk("Vault", "full", lastFull.Add(6*time.Minute), 3<<30, 20))
	}
	if primary {
		rows = append(rows, bk("Sales", "log", lastLog, 180<<20, 4), bk("Sales_archive", "log", lastLog, 2<<20, 1),
			dbRow("Orders", "FULL", false, old), bk("Orders", "full", lastFull.Add(9*time.Minute), 20<<30, 95), bk("Orders", "log", lastLog, 40<<20, 1),
			dbRow("Reporting", "SIMPLE", false, old), bk("Reporting", "full", lastFull.Add(12*time.Minute), 11<<30, 60),
			dbRow("staging_import", "FULL", false, z(g.start.Add(-30*24*time.Hour))), bk("staging_import", "full", lastFull.Add(5*time.Minute), 3<<30, 25),
			dbRow("scratch_etl", "SIMPLE", false, z(t.Add(-5*time.Hour))))
	}
	return append(rows, Row{"kind": "history", "backup_sets": 4200, "oldest_utc": z(g.start.Add(-60 * 24 * time.Hour))})
}
