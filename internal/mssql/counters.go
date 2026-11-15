package mssql

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// The performance counters (task 401, B3): three collections read sys.dm_os_performance_counters from a list the
// repository keeps per instance (0152_mssql_counters.sql), never a list fixed here.
//
//   - mssql_counters (every minute): the instance objects of the list (every object but Databases and Database
//     Replica), and two DMVs read as series of the same store: sys.dm_os_schedulers (summed over the VISIBLE ONLINE
//     schedulers) and sys.dm_os_process_memory.
//   - mssql_counters_db (every 5 minutes): the per-database objects (Databases, Database Replica).
//   - mssql_counter_catalog (every 24 hours): every (object, counter, type) the server has, with its instance count,
//     the Admin page's picker.
//
// The list (object, counter, an instance name or every instance, a kind override) is the repository's answer to
// pgvigil.mssql_counter_list: its defaults, then pgvigil.yaml's lines, then Admin's rows, the narrowest scope winning
// (0152). The runner hands it to RunList (ListCollector); a run without it says so and reads nothing.
//
// The arithmetic follows the type SQL Server gives each row (cntr_type), never the counter's name:
//
//	65792, 65536      a value as it stands (gauge)
//	272696576, 272696320  a count since the server started: the import stores its rate per second between two reads
//	537003264         a fraction of its base at the read: 100 * value / base (Buffer cache hit ratio, CPU usage %)
//	1073874176        an average over its base between two reads: (value - value before) / (base - base before)
//	                  (Average Wait Time (ms), Update conflict ratio)
//	1073939712        a base: never a series of its own; it rides on the row of its counter
//
// A counter of type 65792 that counts since the server started (Batch Resp Statistics, Deprecated Features Usage,
// Log Growths / Shrinks / Truncations) carries the kind 'count' in the list: the import stores its change per read.
// A fraction or an average whose base is not in the read is stored as read, kind 'unpaired', and the page says so.
//
// The base of a counter is found as Telegraf's sqlserver input finds it (plugins/inputs/sqlserver/sqlserverqueries.go,
// MIT: the base's name with ' base' taken off, or ' base' made ' (ms)', in the same object and instance, any case),
// and for the five forms that rule misses on SQL Server 2017, 2019 and 2022 (read on the lab box 2026-11-14) by the
// names in irregularBases.
//
// Rights: VIEW SERVER STATE, or VIEW SERVER PERFORMANCE STATE on SQL Server 2022 (perfState). Not on Azure SQL
// Database, where the counters are the host's (B2 reads them there).

// CounterSpec is one line of an instance's counter list as mssql_counter_list returns it.
type CounterSpec struct {
	Object   string `json:"object"`         // without the instance's prefix: 'General Statistics', or a DMV's name
	Counter  string `json:"counter"`        // the counter's name, or the DMV's column
	Instance string `json:"inst,omitempty"` // one instance name; '' = every instance
	Scope    string `json:"scope"`          // 'instance' (mssql_counters) or 'database' (mssql_counters_db)
	Kind     string `json:"kind,omitempty"` // '' = from the type read; 'count', 'rate', 'gauge' = given
	// Except: on an every-instance line, the instances a one-instance removal took out (read no more)
	Except []string `json:"except,omitempty"`
}

// ListCollector is a collection whose read list comes from the repository: RunOnce asks pgvigil.mssql_counter_list
// for the instance's list and hands it to RunList.
type ListCollector interface {
	Collector
	RunList(ctx context.Context, conn *sql.Conn, info Info, list []CounterSpec) ([]collect.Row, error)
}

// ParseCounterList reads the repository's answer (a JSON array of CounterSpec).
func ParseCounterList(b []byte) ([]CounterSpec, error) {
	var list []CounterSpec
	if err := json.Unmarshal(b, &list); err != nil {
		return nil, fmt.Errorf("the counter list: %w", err)
	}
	for i, s := range list {
		if s.Object == "" || s.Counter == "" || (s.Scope != "instance" && s.Scope != "database") {
			return nil, fmt.Errorf("the counter list's line %d is not whole: %+v", i+1, s)
		}
	}
	return list, nil
}

// the cntr_type codes (sys.dm_os_performance_counters)
const (
	typeRawLarge = 65792      // PERF_COUNTER_LARGE_RAWCOUNT
	typeBulk     = 272696576  // PERF_COUNTER_BULK_COUNT
	typeCounter  = 272696320  // PERF_COUNTER_COUNTER
	typeFraction = 537003264  // PERF_LARGE_RAW_FRACTION
	typeAverage  = 1073874176 // PERF_AVERAGE_BULK
	typeBase     = 1073939712 // PERF_LARGE_RAW_BASE
)

// counterKind is the arithmetic a row gets: the list's own kind wins; else the type's; a fraction or an average
// without its base is 'unpaired'.
func counterKind(ctype int64, given string, hasBase bool) string {
	switch given {
	case "count", "rate", "gauge":
		return given
	}
	switch ctype {
	case typeBulk, typeCounter:
		return "rate"
	case typeFraction:
		if hasBase {
			return "fraction"
		}
		return "unpaired"
	case typeAverage:
		if hasBase {
			return "average"
		}
		return "unpaired"
	}
	return "gauge"
}

// irregularBases: the counters whose base Telegraf's rule does not find (object, counter -> base), read on SQL
// Server 2017 CU31, 2019 CU32 and 2022 CU28.
var irregularBases = map[[2]string]string{
	{"access methods", "worktables from cache ratio"}:         "worktables from cache base",
	{"broker to statistics", "avg. length of batched writes"}: "avg. length of batched writes bs",
	{"databases", "avg dist from eol/lp request"}:             "log pool requests base",
	{"databases", "xtp controller dlc latency/fetch"}:         "xtp controller dlc latency base",
}

// baseNames: the names (lower case) a counter's base may have in its object.
func baseNames(object, counter string) []string {
	o, c := strings.ToLower(object), strings.ToLower(counter)
	if b, ok := irregularBases[[2]string{o, c}]; ok {
		return []string{b}
	}
	out := []string{c + " base"}
	if strings.HasSuffix(c, " (ms)") {
		out = append(out, strings.TrimSuffix(c, " (ms)")+" base")
	}
	// FileTable: 'Avg time X' over 'Time X BASE'
	if strings.HasPrefix(c, "avg time ") {
		out = append(out, "time "+strings.TrimPrefix(c, "avg time ")+" base")
	}
	return out
}

// countersInUse: what a page or a rule reads of the list - Admin refuses to remove these, and so does the config's
// validation (0152's defaults carry the same in used_by; counters_test.go holds the two equal).
var countersInUse = map[[2]string]string{
	{"Workload Group Stats", "Active requests"}:               "the CPU page's thread use",
	{"Workload Group Stats", "Queued requests"}:               "the CPU page's thread use and its scheduler level",
	{"Workload Group Stats", "Blocked tasks"}:                 "the CPU page's thread use",
	{"Workload Group Stats", "Active parallel threads"}:       "the CPU page's thread use",
	{"Databases", "Log Bytes Flushed/sec"}:                    "the File IO page's log flushes",
	{"SQL Statistics", "Batch Requests/sec"}:                  "the counters metrics (compilations, page splits and page lookups per batch)",
	{"SQL Statistics", "SQL Compilations/sec"}:                "the counters metrics (compilations per batch, re-compilations per compilation)",
	{"SQL Statistics", "SQL Re-Compilations/sec"}:             "the counters metric re-compilations per compilation",
	{"SQL Statistics", "Misguided plan executions/sec"}:       "the counters metric misguided plan executions",
	{"General Statistics", "Logins/sec"}:                      "the counters metric logins/sec",
	{"General Statistics", "Logouts/sec"}:                     "the counters metric logouts/sec",
	{"General Statistics", "User Connections"}:                "the counters metric user connections",
	{"SQL Errors", "Errors/sec"}:                              "the counters metrics errors/sec by kind",
	{"Locks", "Lock Timeouts (timeout > 0)/sec"}:              "the counters metric lock timeouts (timeout > 0)",
	{"Locks", "Lock Waits/sec"}:                               "the counters metric lock waits/sec",
	{"Locks", "Lock Requests/sec"}:                            "the counters metric lock requests/sec",

	// the Metrics page's batch response histogram reads every bucket (T41: review part 3, finding 4)
	{"Batch Resp Statistics", "Batches >=000000ms & <000001ms"}: "the Metrics page's batch response histogram",
	{"Batch Resp Statistics", "Batches >=000001ms & <000002ms"}: "the Metrics page's batch response histogram",
	{"Batch Resp Statistics", "Batches >=000002ms & <000005ms"}: "the Metrics page's batch response histogram",
	{"Batch Resp Statistics", "Batches >=000005ms & <000010ms"}: "the Metrics page's batch response histogram",
	{"Batch Resp Statistics", "Batches >=000010ms & <000020ms"}: "the Metrics page's batch response histogram",
	{"Batch Resp Statistics", "Batches >=000020ms & <000050ms"}: "the Metrics page's batch response histogram",
	{"Batch Resp Statistics", "Batches >=000050ms & <000100ms"}: "the Metrics page's batch response histogram",
	{"Batch Resp Statistics", "Batches >=000100ms & <000200ms"}: "the Metrics page's batch response histogram",
	{"Batch Resp Statistics", "Batches >=000200ms & <000500ms"}: "the Metrics page's batch response histogram",
	{"Batch Resp Statistics", "Batches >=000500ms & <001000ms"}: "the Metrics page's batch response histogram",
	{"Batch Resp Statistics", "Batches >=001000ms & <002000ms"}: "the Metrics page's batch response histogram",
	{"Batch Resp Statistics", "Batches >=002000ms & <005000ms"}: "the Metrics page's batch response histogram",
	{"Batch Resp Statistics", "Batches >=005000ms & <010000ms"}: "the Metrics page's batch response histogram",
	{"Batch Resp Statistics", "Batches >=010000ms & <020000ms"}: "the Metrics page's batch response histogram",
	{"Batch Resp Statistics", "Batches >=020000ms & <050000ms"}: "the Metrics page's batch response histogram",
	{"Batch Resp Statistics", "Batches >=050000ms & <100000ms"}: "the Metrics page's batch response histogram",
	{"Batch Resp Statistics", "Batches >=100000ms"}:             "the Metrics page's batch response histogram",

	{"Locks", "Average Wait Time (ms)"}:                       "the counters metric average lock wait",
	{"Latches", "Latch Waits/sec"}:                            "the counters metric latch waits/sec",
	{"Latches", "Average Latch Wait Time (ms)"}:               "the counters metric average latch wait",
	{"Access Methods", "Full Scans/sec"}:                      "the counters metric full scans per index search",
	{"Access Methods", "Index Searches/sec"}:                  "the counters metric full scans per index search",
	{"Access Methods", "Page Splits/sec"}:                     "the counters metric page splits per batch",
	{"Buffer Manager", "Page lookups/sec"}:                    "the counters metric page lookups per batch",
	{"Buffer Manager", "Page reads/sec"}:                      "the counters metrics page reads/sec and read-ahead share",
	{"Buffer Manager", "Page writes/sec"}:                     "the counters metric page writes/sec",
	{"Buffer Manager", "Readahead pages/sec"}:                 "the counters metric read-ahead share",
	{"Buffer Manager", "Lazy writes/sec"}:                     "the counters metric lazy writes/sec",
	{"Buffer Manager", "Free list stalls/sec"}:                "the counters metric free list stalls/sec",
	{"Buffer Manager", "Buffer cache hit ratio"}:              "the counters metric buffer cache hit ratio",
	{"Buffer Node", "Page life expectancy"}:                   "the counters metric page life expectancy per 4 GB",
	{"Buffer Node", "Database pages"}:                         "the counters metric page life expectancy per 4 GB",
	{"Transactions", "Update conflict ratio"}:                 "the counters metric update conflicts",
	{"Databases", "Write Transactions/sec"}:                   "the counters metric write transactions/sec and the storage pages",
	{"Databases", "Log Flush Waits/sec"}:                      "the counters metric log flush waits/sec",
	{"Databases", "Log Flush Wait Time"}:                      "the counters metric log flush wait time",
	{"Databases", "Log Growths"}:                              "the counters metric log growths",
	{"Databases", "Percent Log Used"}:                         "the counters metric percent log used and the storage pages",
	{"Databases", "Active Transactions"}:                      "the counters metric active transactions and the storage pages",
	{"sys.dm_os_process_memory", "physical_memory_in_use_kb"}: "the counters metric memory in use of the commit limit",
	{"sys.dm_os_process_memory", "available_commit_limit_kb"}: "the counters metric memory in use of the commit limit",
	{"sys.dm_os_schedulers", "failed_to_create_worker"}:       "the counters metric failed to create a worker and the CPU page's scheduler trend",
}

// CounterInUse says what reads a counter (” = nothing): config validation refuses a 'remove' of it.
func CounterInUse(object, counter string) string {
	for k, v := range countersInUse {
		if strings.EqualFold(k[0], object) && strings.EqualFold(k[1], counter) {
			return v
		}
	}
	return ""
}

// pseudoColumns: the DMV columns the list may name as series, each with its kind (a count since the server started
// is a rate) and the SQL that reads it. A name not here is never put into a statement.
var pseudoColumns = map[string]map[string]struct{ kind, expr string }{
	"sys.dm_os_schedulers": {
		"failed_to_create_worker":   {"gauge", "SUM(CAST(failed_to_create_worker AS int))"},
		"context_switches_count":    {"rate", "SUM(CAST(context_switches_count AS bigint))"},
		"preemptive_switches_count": {"rate", "SUM(CAST(preemptive_switches_count AS bigint))"},
		"idle_switches_count":       {"rate", "SUM(CAST(idle_switches_count AS bigint))"},
		"yield_count":               {"rate", "SUM(CAST(yield_count AS bigint))"},
		"load_factor":               {"gauge", "SUM(CAST(load_factor AS bigint))"},
	},
	"sys.dm_os_process_memory": {
		"physical_memory_in_use_kb":          {"gauge", "MAX(physical_memory_in_use_kb)"},
		"large_page_allocations_kb":          {"gauge", "MAX(large_page_allocations_kb)"},
		"locked_page_allocations_kb":         {"gauge", "MAX(locked_page_allocations_kb)"},
		"total_virtual_address_space_kb":     {"gauge", "MAX(total_virtual_address_space_kb)"},
		"virtual_address_space_reserved_kb":  {"gauge", "MAX(virtual_address_space_reserved_kb)"},
		"virtual_address_space_committed_kb": {"gauge", "MAX(virtual_address_space_committed_kb)"},
		"virtual_address_space_available_kb": {"gauge", "MAX(virtual_address_space_available_kb)"},
		"page_fault_count":                   {"rate", "MAX(page_fault_count)"},
		"memory_utilization_percentage":      {"gauge", "MAX(memory_utilization_percentage)"},
		"available_commit_limit_kb":          {"gauge", "MAX(available_commit_limit_kb)"},
		"process_physical_memory_low":        {"gauge", "MAX(CAST(process_physical_memory_low AS int))"},
		"process_virtual_memory_low":         {"gauge", "MAX(CAST(process_virtual_memory_low AS int))"},
	},
}

// the filter of a DMV whose rows are summed
var pseudoWhere = map[string]string{"sys.dm_os_schedulers": " WHERE status = N'VISIBLE ONLINE'"}

type countersCollector struct{ scope string }

func init() {
	Register(countersCollector{"instance"})
	Register(countersCollector{"database"})
	Register(counterCatalogCollector{})
}

func (c countersCollector) Name() string {
	if c.scope == "database" {
		return Prefix + "counters_db"
	}
	return Prefix + "counters"
}

func (c countersCollector) DefaultInterval() time.Duration {
	if c.scope == "database" {
		return 5 * time.Minute
	}
	return time.Minute
}

func (countersCollector) Applies(info Info) (bool, string) {
	return perfApplies(info, "sys.dm_os_performance_counters")
}

// Run without a list reads nothing: the list is the repository's, handed in by the runner.
func (c countersCollector) Run(context.Context, *sql.Conn, Info) ([]collect.Row, error) {
	return nil, fmt.Errorf("%s reads the counter list the repository keeps for the instance: the runner hands it over (ListCollector)", c.Name())
}

func (c countersCollector) RunList(ctx context.Context, conn *sql.Conn, info Info, list []CounterSpec) ([]collect.Row, error) {
	if err := perfState(ctx, conn, info, "sys.dm_os_performance_counters"); err != nil {
		return nil, err
	}
	out, err := QueryRows(ctx, conn, perfStateSQL)
	if err != nil {
		return nil, err
	}
	var mine []CounterSpec
	for _, s := range list {
		if s.Scope == c.scope {
			mine = append(mine, s)
		}
	}
	if q := counterQuery(mine, c.scope); q != "" {
		rows, err := QueryRows(ctx, conn, q)
		if err != nil {
			return nil, err
		}
		out = append(out, pairCounters(rows, mine)...)
	}
	if c.scope == "instance" {
		for dmv := range pseudoColumns {
			q, specs := pseudoQuery(dmv, mine)
			if q == "" {
				continue
			}
			rows, err := QueryRows(ctx, conn, q)
			if err != nil {
				out = append(out, collect.Row{"kind": "collector_error", "source": dmv, "message": err.Error()})
				continue
			}
			out = append(out, pseudoRows(dmv, rows, specs)...)
		}
	}
	return out, nil
}

// counterQuery reads the listed counters' rows of the scope's objects and every base of those objects. The names are
// N” literals with quotes doubled (nList); the object is matched in Go (pairCounters), the prefix being the
// instance's (SQLServer: or MSSQL$<name>:).
func counterQuery(list []CounterSpec, scope string) string {
	names := map[string]bool{}
	for _, s := range list {
		if _, pseudo := pseudoColumns[s.Object]; !pseudo {
			names[s.Counter] = true
		}
	}
	if len(names) == 0 {
		return ""
	}
	ns := make([]string, 0, len(names))
	for n := range names {
		ns = append(ns, n)
	}
	sort.Strings(ns)
	where := `(RTRIM(object_name) LIKE N'%:Databases' OR RTRIM(object_name) LIKE N'%:Database Replica')`
	if scope != "database" {
		where = `NOT ` + where
	}
	return `SELECT CAST(RTRIM(object_name) AS nvarchar(128)) AS object, CAST(RTRIM(counter_name) AS nvarchar(128)) AS counter,
  CAST(RTRIM(instance_name) AS nvarchar(128)) AS instance, CAST(cntr_value AS bigint) AS value, CAST(cntr_type AS bigint) AS type
FROM sys.dm_os_performance_counters
WHERE (counter_name IN (` + nList(ns) + `) OR cntr_type = 1073939712) AND ` + where
}

// pairCounters keeps the rows the list names (object without its prefix, counter, an instance or every one; the
// system names of perfmonSkip left out, an empty instance read as _Total), each fraction and average with its base.
func pairCounters(rows []collect.Row, list []CounterSpec) []collect.Row {
	type key struct{ object, inst string }
	bases := map[key]map[string]int64{}
	for _, r := range rows {
		if t, _ := r["type"].(int64); t != typeBase {
			continue
		}
		object, _ := r["object"].(string)
		inst, _ := r["instance"].(string)
		counter, _ := r["counter"].(string)
		k := key{strings.ToLower(counterObject(object)), inst}
		if bases[k] == nil {
			bases[k] = map[string]int64{}
		}
		if v, ok := r["value"].(int64); ok {
			bases[k][strings.ToLower(counter)] = v
		}
	}
	skip := make(map[string]bool, len(perfmonSkip))
	for _, s := range perfmonSkip {
		skip[s] = true
	}
	var out []collect.Row
	for _, r := range rows {
		ctype, _ := r["type"].(int64)
		if ctype == typeBase {
			continue
		}
		object, _ := r["object"].(string)
		counter, _ := r["counter"].(string)
		inst, _ := r["instance"].(string)
		obj := counterObject(object)
		if skip[inst] {
			continue
		}
		spec, ok := matchSpec(list, obj, counter, inst)
		if !ok {
			continue
		}
		var base any
		if ctype == typeFraction || ctype == typeAverage {
			for _, b := range baseNames(obj, counter) {
				if v, ok := bases[key{strings.ToLower(obj), inst}][b]; ok {
					base = v
					break
				}
			}
		}
		name := inst
		if name == "" {
			name = "_Total"
		}
		out = append(out, collect.Row{"kind": "ctr", "object": obj, "counter": counter, "instance": name, "value": r["value"],
			"type": ctype, "base": base, "ckind": counterKind(ctype, spec.Kind, base != nil)})
	}
	return out
}

// matchSpec: the list's line for a row (an exact instance line before an every-instance line).
func matchSpec(list []CounterSpec, object, counter, inst string) (CounterSpec, bool) {
	var every *CounterSpec
	for i := range list {
		s := list[i]
		if !strings.EqualFold(s.Object, object) || !strings.EqualFold(s.Counter, counter) {
			continue
		}
		// a line for one instance; '_Total' (as the pages show a row without an instance name) is the empty name
		if s.Instance != "" && (s.Instance == inst || (inst == "" && strings.EqualFold(s.Instance, "_Total"))) {
			return s, true
		}
		if s.Instance == "" && every == nil && !excepted(s.Except, inst) {
			every = &list[i]
		}
	}
	if every != nil {
		return *every, true
	}
	return CounterSpec{}, false
}

// excepted: an instance a one-instance removal names (the same match as a one-instance line's: exact, '_Total' for the
// row without an instance name)
func excepted(except []string, inst string) bool {
	for _, e := range except {
		if e == inst || (inst == "" && strings.EqualFold(e, "_Total")) {
			return true
		}
	}
	return false
}

// pseudoQuery: one row of the listed columns of a DMV (only names of pseudoColumns reach the statement).
func pseudoQuery(dmv string, list []CounterSpec) (string, []CounterSpec) {
	cols := pseudoColumns[dmv]
	var sel []string
	var specs []CounterSpec
	for _, s := range list {
		if s.Object != dmv {
			continue
		}
		c, ok := cols[s.Counter]
		if !ok {
			continue
		}
		sel = append(sel, c.expr+" AS "+s.Counter)
		specs = append(specs, s)
	}
	if len(sel) == 0 {
		return "", nil
	}
	sort.Strings(sel)
	return "SELECT " + strings.Join(sel, ", ") + " FROM " + dmv + pseudoWhere[dmv], specs
}

// pseudoRows: a DMV's one row as series rows (instance '_Total'; the type code of the kind, so the import's
// arithmetic is the same as a counter's).
func pseudoRows(dmv string, rows []collect.Row, specs []CounterSpec) []collect.Row {
	if len(rows) == 0 {
		return nil
	}
	var out []collect.Row
	for _, s := range specs {
		v, ok := rows[0][s.Counter]
		if !ok || v == nil {
			continue
		}
		kind := pseudoColumns[dmv][s.Counter].kind
		ctype := int64(typeRawLarge)
		if kind == "rate" {
			ctype = typeBulk
		}
		out = append(out, collect.Row{"kind": "ctr", "object": dmv, "counter": s.Counter, "instance": "_Total", "value": v,
			"type": ctype, "base": nil, "ckind": kind})
	}
	return out
}

// counterCatalogCollector is mssql_counter_catalog: every (object, counter, type) the server has with its instance
// count and the first and last instance names (the Admin page's picker; INV#5's catalogue), once a day.
type counterCatalogCollector struct{}

func (counterCatalogCollector) Name() string                   { return Prefix + "counter_catalog" }
func (counterCatalogCollector) DefaultInterval() time.Duration { return 24 * time.Hour }
func (counterCatalogCollector) Applies(info Info) (bool, string) {
	return perfApplies(info, "sys.dm_os_performance_counters")
}

const counterCatalogSQL = `SELECT 'cat' AS kind,
  CAST(SUBSTRING(RTRIM(object_name), CHARINDEX(':', object_name) + 1, 128) AS nvarchar(128)) AS object,
  CAST(RTRIM(counter_name) AS nvarchar(128)) AS counter, CAST(MIN(cntr_type) AS bigint) AS type,
  CAST(COUNT(*) AS bigint) AS instances, CAST(MIN(RTRIM(instance_name)) AS nvarchar(128)) AS first_instance,
  CAST(MAX(RTRIM(instance_name)) AS nvarchar(128)) AS last_instance
FROM sys.dm_os_performance_counters
GROUP BY SUBSTRING(RTRIM(object_name), CHARINDEX(':', object_name) + 1, 128), RTRIM(counter_name)`

func (counterCatalogCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	if err := perfState(ctx, conn, info, "sys.dm_os_performance_counters"); err != nil {
		return nil, err
	}
	return QueryRows(ctx, conn, counterCatalogSQL)
}
