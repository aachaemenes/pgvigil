package collect

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	cwtypes "github.com/aws/aws-sdk-go-v2/service/cloudwatch/types"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// hostCollector reads the host the instance runs on, every minute, through one of two doors.
//
// On-prem: the system_stats extension (EDB, PostgreSQL licence; built from EDB's source, it is not in
// the PGDG repositories) created in the database the collector connects to, with the monitoring login
// granted monitor_system_stats (the extension revokes its functions from PUBLIC): that grant is the one
// documented opt-in beyond pg_monitor. It reads the OS (name, kernel, architecture: the RedHat or Ubuntu
// answer), the CPU, memory, load, every disk mount and the per-device IO counters.
//
// RDS / Aurora: CloudWatch through the instance's aws: block (CPUUtilization, FreeableMemory,
// FreeStorageSpace on RDS or FreeLocalStorage on Aurora, SwapUsage, DatabaseConnections) and, on RDS,
// DescribeDBInstances for the allocated storage (the volume's size) and the class.
//
// Neither door: the run is skipped with the reason, never an error.
type hostCollector struct{}

func init() { Register(hostCollector{}) }

const hostMetricWindow = 15 * time.Minute // CloudWatch is read this far back; the newest datapoint is kept

func (hostCollector) Name() string                         { return "host" }
func (hostCollector) DefaultInterval() time.Duration       { return time.Minute }
func (hostCollector) Applies(platform.Info) (bool, string) { return true, "" }

func (hostCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("host needs the instance config: %w", ErrSkip)
}

func (h hostCollector) RunInstance(ctx context.Context, conn *pgx.Conn, info platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	if info.Kind == platform.RDS || info.Kind == platform.Aurora {
		if in.AWS == nil || (in.AWS.DBInstance == "" && in.AWS.Cluster == "" && info.Kind == platform.RDS) {
			return nil, fmt.Errorf("%s: no aws: block with db_instance in the config (the CloudWatch door): %w", info.Kind, ErrSkip)
		}
		id, err := hostAWSInstanceID(ctx, conn, info, *in.AWS)
		if err != nil {
			return nil, err
		}
		api, err := hostClientFor(ctx, *in.AWS)
		if err != nil {
			return nil, err
		}
		return hostCloudRows(ctx, api, info.Kind, id, time.Now())
	}
	return hostSystemStats(ctx, conn)
}

// ---- the system_stats door ---------------------------------------------------------------------------

// hostSystemStats finds the extension and the grant, then reads each function on its own: a function that
// fails becomes a collector_error row and the rest still land.
func hostSystemStats(ctx context.Context, conn *pgx.Conn) ([]Row, error) {
	var schema, version, datadir string
	var canExec bool
	err := conn.QueryRow(ctx, `
SELECT n.nspname, e.extversion,
       has_function_privilege(format('%I.pg_sys_os_info()', n.nspname), 'EXECUTE'),
       coalesce(current_setting('data_directory', true), '')
  FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
 WHERE e.extname = 'system_stats'`).Scan(&schema, &version, &canExec, &datadir)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("no system_stats extension in database %s (EDB's source build; not in PGDG) and no CloudWatch door (not RDS / Aurora): %w",
			conn.Config().Database, ErrSkip)
	}
	if err != nil {
		return nil, fmt.Errorf("system_stats lookup: %w", err)
	}
	if !canExec {
		return nil, fmt.Errorf("system_stats %s is installed but the login may not run it: GRANT monitor_system_stats TO %s (the documented opt-in): %w",
			version, conn.Config().User, ErrSkip)
	}

	var errRows []Row
	read := func(part, fn string) []map[string]any {
		var out []map[string]any
		rows, err := conn.Query(ctx, fmt.Sprintf(`SELECT to_jsonb(x) FROM %s.%s() x`, pgx.Identifier{schema}.Sanitize(), fn))
		if err == nil {
			for rows.Next() {
				var raw []byte
				if err = rows.Scan(&raw); err != nil {
					break
				}
				m := map[string]any{}
				if err = json.Unmarshal(raw, &m); err != nil {
					break
				}
				out = append(out, m)
			}
			rows.Close()
			if err == nil {
				err = rows.Err()
			}
		}
		if err != nil {
			errRows = append(errRows, Row{"kind": "collector_error", "source": "system_stats:" + part, "message": fn + ": " + err.Error()})
			return nil
		}
		return out
	}
	osRows := read("os", "pg_sys_os_info")
	cpuRows := read("cpu", "pg_sys_cpu_info")
	useRows := read("cpu", "pg_sys_cpu_usage_info")
	memRows := read("memory", "pg_sys_memory_info")
	loadRows := read("load", "pg_sys_load_avg_info")
	diskRows := read("disk", "pg_sys_disk_info")
	ioRows := read("io", "pg_sys_io_analysis_info")

	host := Row{"kind": "host", "source": "system_stats", "extension_version": version}
	if len(osRows) > 0 {
		o := osRows[0]
		host["os_name"], host["os_version"], host["architecture"], host["host_name"] = o["name"], o["version"], o["architecture"], o["host_name"]
		host["uptime_secs"] = o["os_up_since_seconds"]
	}
	if len(cpuRows) > 0 {
		c := cpuRows[0]
		host["cpu_model"], host["cpu_cores"] = c["model_name"], c["no_of_cores"]
		if host["architecture"] == nil {
			host["architecture"] = c["architecture"]
		}
		// pg_sys_cpu_info returns one row per processor on some builds and one in total on others
		host["logical_cpus"] = len(cpuRows)
		if len(cpuRows) == 1 {
			host["logical_cpus"] = c["physical_processor"]
		}
	}
	if len(useRows) > 0 {
		u := useRows[0]
		if idle, ok := num(u["idle_mode_percent"]); ok {
			host["cpu_pct"] = round2(100 - idle)
		}
		if a, ok := num(u["usermode_normal_process_percent"]); ok {
			b, _ := num(u["usermode_niced_process_percent"])
			host["cpu_user_pct"] = round2(a + b)
		}
		host["cpu_system_pct"], host["cpu_iowait_pct"] = u["kernelmode_process_percent"], u["io_completion_percent"]
	}
	if len(memRows) > 0 {
		m := memRows[0]
		host["mem_total"], host["mem_used"], host["mem_free"], host["mem_cache"] = m["total_memory"], m["used_memory"], m["free_memory"], m["cache_total"]
		host["swap_total"], host["swap_used"] = m["swap_total"], m["swap_used"]
	}
	if len(loadRows) > 0 {
		l := loadRows[0]
		host["load1"], host["load5"], host["load15"] = l["load_avg_one_minute"], l["load_avg_five_minutes"], l["load_avg_fifteen_minutes"]
		if host["load15"] == nil { // older builds stop at ten minutes
			host["load15"] = l["load_avg_ten_minutes"]
		}
	}
	out := []Row{host}
	out = append(out, hostDisks(diskRows, datadir)...)
	for _, d := range ioRows {
		name, _ := d["device_name"].(string)
		if name == "" || strings.HasPrefix(name, "loop") || strings.HasPrefix(name, "ram") {
			continue
		}
		out = append(out, Row{"kind": "io", "device": name, "reads": d["total_reads"], "writes": d["total_writes"],
			"read_bytes": d["read_bytes"], "write_bytes": d["write_bytes"], "read_time_ms": d["read_time_ms"], "write_time_ms": d["write_time_ms"]})
	}
	return append(out, errRows...), nil
}

// hostPseudoFS are file systems with no disk under them.
var hostPseudoFS = map[string]bool{"tmpfs": true, "devtmpfs": true, "overlay": true, "proc": true, "sysfs": true, "squashfs": true,
	"nsfs": true, "cgroup": true, "cgroup2": true, "devpts": true, "mqueue": true, "autofs": true, "ramfs": true, "tracefs": true,
	"debugfs": true, "securityfs": true, "pstore": true, "bpf": true, "configfs": true, "fusectl": true, "hugetlbfs": true,
	"binfmt_misc": true, "efivarfs": true, "rpc_pipefs": true, "selinuxfs": true}

// hostDisks folds pg_sys_disk_info's mounts into one row per device (a container's bind mounts and a
// btrfs subvolume are one disk), named by the mount that holds the data directory, else the shortest.
func hostDisks(rows []map[string]any, datadir string) []Row {
	type disk struct {
		dev, fs        string
		total, used, f any
		mounts         []string
	}
	byDev := map[string]*disk{}
	var order []string
	for _, r := range rows {
		mp, _ := r["mount_point"].(string)
		fs, _ := r["file_system_type"].(string)
		dev, _ := r["file_system"].(string)
		if mp == "" || hostPseudoFS[fs] {
			continue
		}
		if t, ok := num(r["total_space"]); !ok || t <= 0 {
			continue
		}
		key := dev
		if key == "" {
			key = mp
		}
		d, ok := byDev[key]
		if !ok {
			d = &disk{dev: dev, fs: fs, total: r["total_space"], used: r["used_space"], f: r["free_space"]}
			byDev[key] = d
			order = append(order, key)
		}
		d.mounts = append(d.mounts, mp)
	}
	out := make([]Row, 0, len(order))
	for _, k := range order {
		d := byDev[k]
		sort.Strings(d.mounts)
		name, holds := "", false
		for _, m := range d.mounts { // the longest mount that is a prefix of the data directory
			if datadir != "" && (datadir == m || strings.HasPrefix(datadir, strings.TrimSuffix(m, "/")+"/")) && len(m) > len(name) {
				name, holds = m, true
			}
		}
		if name == "" {
			name = d.mounts[0]
			for _, m := range d.mounts {
				if len(m) < len(name) {
					name = m
				}
			}
		}
		out = append(out, Row{"kind": "disk", "source": "system_stats", "mount_point": name, "device": nilIfEmpty(d.dev),
			"fs_type": nilIfEmpty(d.fs), "total_bytes": d.total, "used_bytes": d.used, "free_bytes": d.f,
			"mounts": d.mounts, "holds_data": holds})
	}
	return out
}

func num(v any) (float64, bool) {
	switch x := v.(type) {
	case float64:
		return x, true
	case json.Number:
		f, err := x.Float64()
		return f, err == nil
	case int64:
		return float64(x), true
	case int:
		return float64(x), true
	}
	return 0, false
}

func round2(f float64) float64 { return float64(int64(f*100+0.5)) / 100 }

// ---- the CloudWatch door -----------------------------------------------------------------------------

// hostAPI is the slice of the CloudWatch and RDS clients the collector calls; a recorded set in a test.
type hostAPI interface {
	cloudwatch.GetMetricDataAPIClient
	rds.DescribeDBInstancesAPIClient
}

type awsHost struct {
	*rds.Client
	cw *cloudwatch.Client
}

func (c awsHost) GetMetricData(ctx context.Context, in *cloudwatch.GetMetricDataInput, opts ...func(*cloudwatch.Options)) (*cloudwatch.GetMetricDataOutput, error) {
	return c.cw.GetMetricData(ctx, in, opts...)
}

var (
	hostClientsMu sync.Mutex
	hostClients   = map[string]hostAPI{}
)

var newHostAPI = func(ctx context.Context, a config.AWS) (hostAPI, error) {
	cfg, err := loadAWS(ctx, a)
	if err != nil {
		return nil, err
	}
	return awsHost{Client: rds.NewFromConfig(cfg), cw: cloudwatch.NewFromConfig(cfg)}, nil
}

func hostClientFor(ctx context.Context, a config.AWS) (hostAPI, error) {
	k := a.Profile + "|" + a.Region
	hostClientsMu.Lock()
	defer hostClientsMu.Unlock()
	if c, ok := hostClients[k]; ok {
		return c, nil
	}
	c, err := newHostAPI(ctx, a)
	if err == nil {
		hostClients[k] = c
	}
	return c, err
}

// hostAWSInstanceID is the DB instance CloudWatch files this connection's metrics under: the config's
// db_instance, else (Aurora) the instance the connection landed on, so a cluster endpoint follows a failover.
func hostAWSInstanceID(ctx context.Context, conn *pgx.Conn, info platform.Info, a config.AWS) (string, error) {
	if a.DBInstance != "" {
		return a.DBInstance, nil
	}
	if info.Kind == platform.Aurora {
		var id string
		if err := conn.QueryRow(ctx, `SELECT aurora_db_instance_identifier()`).Scan(&id); err != nil {
			return "", fmt.Errorf("aurora_db_instance_identifier(): %w (set aws.db_instance in the config)", err)
		}
		return id, nil
	}
	return "", fmt.Errorf("no aws.db_instance in the config: %w", ErrSkip)
}

// hostCloudMetrics are read per DB instance: the column, the metric and the statistic over each minute.
var hostCloudMetrics = []struct{ col, metric, stat string }{
	{"cpu_pct", "CPUUtilization", "Average"},
	{"mem_free", "FreeableMemory", "Minimum"},
	{"swap_used", "SwapUsage", "Maximum"},
	{"connections", "DatabaseConnections", "Maximum"},
	{"free_storage", "FreeStorageSpace", "Minimum"},
	{"free_local", "FreeLocalStorage", "Minimum"},
}

// hostCloudRows reads the newest datapoint of each metric (one GetMetricData call) and, on RDS, the
// instance's allocated storage; it returns the host row, the volume row and an error row for a part that failed.
func hostCloudRows(ctx context.Context, api hostAPI, kind platform.Kind, id string, now time.Time) ([]Row, error) {
	var queries []cwtypes.MetricDataQuery
	for i, m := range hostCloudMetrics {
		queries = append(queries, cwtypes.MetricDataQuery{
			Id: aws.String(fmt.Sprintf("m%d", i)),
			MetricStat: &cwtypes.MetricStat{
				Metric: &cwtypes.Metric{Namespace: aws.String("AWS/RDS"), MetricName: aws.String(m.metric),
					Dimensions: []cwtypes.Dimension{{Name: aws.String("DBInstanceIdentifier"), Value: aws.String(id)}}},
				Period: aws.Int32(60), Stat: aws.String(m.stat),
			},
		})
	}
	vals := map[string]float64{}
	var newest time.Time
	in := &cloudwatch.GetMetricDataInput{StartTime: aws.Time(now.Add(-hostMetricWindow)), EndTime: aws.Time(now),
		MetricDataQueries: queries, ScanBy: cwtypes.ScanByTimestampDescending}
	var errRows []Row
	for {
		res, err := api.GetMetricData(ctx, in)
		if err != nil {
			// no metric at all is a failed read: an error, not a host that shows nothing
			return nil, fmt.Errorf("GetMetricData %s: %w", id, err)
		}
		for _, r := range res.MetricDataResults {
			if len(r.Values) == 0 || len(r.Timestamps) == 0 {
				continue
			}
			var i int
			if _, err := fmt.Sscanf(aws.ToString(r.Id), "m%d", &i); err != nil || i >= len(hostCloudMetrics) {
				continue
			}
			vals[hostCloudMetrics[i].col] = r.Values[0]
			if r.Timestamps[0].After(newest) {
				newest = r.Timestamps[0]
			}
		}
		if aws.ToString(res.NextToken) == "" {
			break
		}
		in.NextToken = res.NextToken
	}
	host := Row{"kind": "host", "source": "cloudwatch", "aws_resource": id, "os_name": "Amazon " + map[platform.Kind]string{platform.RDS: "RDS", platform.Aurora: "Aurora"}[kind]}
	for _, c := range []string{"cpu_pct", "mem_free", "swap_used", "connections"} {
		if v, ok := vals[c]; ok {
			if c == "cpu_pct" {
				host[c] = round2(v)
			} else {
				host[c] = int64(v)
			}
		}
	}
	if !newest.IsZero() {
		host["metrics_at"] = newest.UTC()
	} else {
		errRows = append(errRows, Row{"kind": "collector_error", "source": "cloudwatch",
			"message": fmt.Sprintf("no AWS/RDS datapoint for %s in the last %s (a paused Serverless instance, or a wrong identifier)", id, hostMetricWindow)})
	}

	out := []Row{host}
	switch kind {
	case platform.RDS:
		disk := Row{"kind": "disk", "source": "cloudwatch", "mount_point": "rds:storage", "device": id}
		if v, ok := vals["free_storage"]; ok {
			disk["free_bytes"] = int64(v)
		}
		di, err := api.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{DBInstanceIdentifier: aws.String(id)})
		switch {
		case err != nil:
			errRows = append(errRows, Row{"kind": "collector_error", "source": "rds", "message": "DescribeDBInstances: " + err.Error()})
		case len(di.DBInstances) > 0:
			d := di.DBInstances[0]
			host["os_version"] = nilIfEmpty(aws.ToString(d.DBInstanceClass))
			disk["fs_type"] = nilIfEmpty(aws.ToString(d.StorageType))
			if d.AllocatedStorage != nil {
				total := int64(*d.AllocatedStorage) << 30
				disk["total_bytes"] = total
				if f, ok := disk["free_bytes"].(int64); ok {
					disk["used_bytes"] = total - f
				}
			}
		}
		if disk["free_bytes"] != nil || disk["total_bytes"] != nil {
			out = append(out, disk)
		}
	case platform.Aurora:
		// the cluster volume (VolumeBytesUsed against 128 TiB) is the storage collection's; the instance's own
		// local storage (temporary files) has no total in CloudWatch
		if v, ok := vals["free_local"]; ok {
			out = append(out, Row{"kind": "disk", "source": "cloudwatch", "mount_point": "aurora:local", "device": id, "free_bytes": int64(v)})
		}
	}
	return append(out, errRows...), nil
}
