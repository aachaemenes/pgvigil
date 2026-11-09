// Package demo seeds a pgvigil repository with a synthetic fleet: every collection's rows are
// generated here and handed to the repository through its import functions only, exactly as the
// collector hands them, so every view, check and page reads demo data the way it reads real data.
//
// The fleet is twelve instances across on-prem PostgreSQL, RDS, Aurora, Azure and Cloud SQL, with
// seven days of history and the conditions a walk-through needs: two blocking chains and an
// idle-in-transaction head, a pg_stat_statements reset, a daily load curve, a lagging replica and
// an inactive slot, a failed pg_cron job, a DMS task over its latency threshold with tables in
// error, deadlocks, and log events. Every instance carries the tag "demo"; a re-run replaces them.
// The data is a pure function of the seed and the anchor time.
package demo

import "fmt"

// Spec is one synthetic instance and the conditions it shows.
type Spec struct {
	Name       string
	Platform   string // onprem | rds | aurora | azure | cloudsql (platform.Kind values)
	Version    string
	VersionNum int
	Replica    bool
	Tags       []string
	App        string   // the application whose statements it runs
	DBs        []string // application databases (postgres and the templates are added)
	Load       float64  // workload multiplier
	MaxConn    int
	Addr       string

	ChainActive bool   // an active head blocking a depth-2 chain (UPDATE convoy)
	ChainDDL    bool   // a long report blocking an ALTER TABLE, sessions queued behind it
	IdleHead    bool   // an idle-in-transaction head holding row locks
	StmtReset   bool   // pg_stat_statements_reset() three days ago
	SenderTo    string // streams to this replica (lagging in the last 90 minutes)
	ReceiverOf  string // the primary it replays from
	SlotStale   bool   // an inactive logical slot retaining WAL
	AuroraRead  string // an Aurora reader's server_id
	Cron        bool   // pg_cron jobs
	CronFail    bool   // a pg_cron job that failed in the last 24 h
	DMS         bool   // a DMS task with CDC latency over its threshold and tables in error
	Deadlocks   bool   // deadlocks in the last 24 h
	Logs        bool   // CloudWatch log events (RDS / Aurora)
	StmtBroken  bool   // the statements collection fails (pg_stat_statements not preloaded)
	SettingEdit string // a setting changed during the week: name=old>new
}

// base is the twelve-instance fleet of the walk-through.
var base = []Spec{
	{Name: "onprem-erp01", Platform: "onprem", Version: "16.6", VersionNum: 160006, App: "erp", DBs: []string{"erp", "erp_audit"},
		Load: 1.6, MaxConn: 400, Addr: "10.20.1.11", ChainActive: true, SenderTo: "onprem-erp02", Tags: []string{"prod", "erp"},
		SettingEdit: "work_mem=4MB>64MB"},
	{Name: "onprem-erp02", Platform: "onprem", Version: "16.6", VersionNum: 160006, Replica: true, App: "erp", DBs: []string{"erp", "erp_audit"},
		Load: 0.4, MaxConn: 400, Addr: "10.20.1.12", ReceiverOf: "onprem-erp01", Tags: []string{"prod", "erp"}},
	{Name: "onprem-hr01", Platform: "onprem", Version: "15.10", VersionNum: 150010, App: "hr", DBs: []string{"hr"},
		Load: 0.6, MaxConn: 200, Addr: "10.20.2.21", IdleHead: true, Tags: []string{"prod", "hr"}},
	{Name: "rds-orders01", Platform: "rds", Version: "16.4", VersionNum: 160004, App: "orders", DBs: []string{"orders"},
		Load: 2.0, MaxConn: 500, Addr: "10.30.4.15", ChainDDL: true, StmtReset: true, Deadlocks: true, Logs: true, Tags: []string{"prod", "orders"},
		SettingEdit: "log_min_duration_statement=-1>1000"},
	{Name: "rds-billing01", Platform: "rds", Version: "17.2", VersionNum: 170002, App: "billing", DBs: []string{"billing"},
		Load: 0.9, MaxConn: 300, Addr: "10.30.4.22", SlotStale: true, Cron: true, Logs: true, Tags: []string{"prod", "billing"}},
	{Name: "aurora-crm01", Platform: "aurora", Version: "17.4", VersionNum: 170004, App: "crm", DBs: []string{"crm"},
		Load: 1.3, MaxConn: 1000, Addr: "10.30.8.31", AuroraRead: "aurora-crm01-reader1", Cron: true, CronFail: true, Logs: true,
		Tags: []string{"prod", "crm"}},
	{Name: "aurora-dms01", Platform: "aurora", Version: "17.4", VersionNum: 170004, App: "erp", DBs: []string{"erp_mirror"},
		Load: 0.8, MaxConn: 1000, Addr: "10.30.8.41", DMS: true, Logs: true, Tags: []string{"prod", "migration"}},
	{Name: "aurora-reporting01", Platform: "aurora", Version: "16.6", VersionNum: 160006, App: "reporting", DBs: []string{"warehouse"},
		Load: 0.7, MaxConn: 800, Addr: "10.30.8.51", Logs: true, Tags: []string{"staging", "reporting"}},
	{Name: "azure-portal01", Platform: "azure", Version: "16.8", VersionNum: 160008, App: "portal", DBs: []string{"portal"},
		Load: 1.1, MaxConn: 500, Addr: "10.40.1.11", Tags: []string{"prod", "portal"}},
	{Name: "azure-portal02", Platform: "azure", Version: "15.12", VersionNum: 150012, App: "portal", DBs: []string{"portal_qa"},
		Load: 0.3, MaxConn: 200, Addr: "10.40.1.12", Tags: []string{"staging", "portal"}},
	{Name: "cloudsql-analytics01", Platform: "cloudsql", Version: "16.6", VersionNum: 160006, App: "analytics", DBs: []string{"events"},
		Load: 1.0, MaxConn: 600, Addr: "10.50.0.11", Tags: []string{"prod", "analytics"}},
	{Name: "cloudsql-analytics02", Platform: "cloudsql", Version: "15.10", VersionNum: 150010, App: "analytics", DBs: []string{"events_dev"},
		Load: 0.25, MaxConn: 200, Addr: "10.50.0.12", StmtBroken: true, Tags: []string{"staging", "analytics"}},
}

// Specs returns n instances named with prefix: the twelve of the walk-through first, then copies of
// them (for a scale measurement) numbered from 13, each copy keeping its template's conditions and
// pointing its replication pair at the copy of the same round.
func Specs(prefix string, n int) []Spec {
	out := make([]Spec, 0, n)
	for i := 0; i < n; i++ {
		s := base[i%len(base)]
		round := i / len(base)
		rename := func(name string) string {
			if name == "" {
				return ""
			}
			if round == 0 {
				return prefix + name
			}
			return fmt.Sprintf("%s%s-%03d", prefix, name, round)
		}
		s.Name = rename(s.Name)
		s.SenderTo = rename(s.SenderTo)
		s.ReceiverOf = rename(s.ReceiverOf)
		s.AuroraRead = rename(s.AuroraRead)
		tags := append([]string{"demo", s.Platform}, s.Tags...)
		s.Tags = tags
		out = append(out, s)
	}
	return out
}
