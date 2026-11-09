package demo

// Host and storage rows for the demo fleet (the host and storage collections): the shapes import_host
// and import_storage take, exactly as the collectors send them. On-prem instances read as system_stats,
// RDS and Aurora as CloudWatch; Azure and Cloud SQL have no host door, so the host collection is
// skipped there with its reason, as on a real server. The scenarios: erp01 runs its CPU over 90 %
// (the CPU rule), erp02's data volume fills in about 13 days at 6 % free (the Storage forecast and the
// Disk free-% rule both light), hr01's root volume sits at 4 % free with 3 GiB of swap used, orders01's
// RDS volume at 7.6 % free with 1.2 GiB of swap used (the cloud swap rule is over 1 GiB), billing01 has
// storage autoscaling to 2 TiB. A copy of an instance (a scale run) keeps its
// template's name inside its own, so it keeps the scenario.

import (
	"math"
	"strings"
	"time"
)

const gib = int64(1 << 30)

// hostDoor says whether this instance has a host door: system_stats on-prem, CloudWatch on RDS and Aurora.
func (g *Gen) hostDoor() bool {
	switch g.Spec.Platform {
	case "onprem", "rds", "aurora":
		return true
	}
	return false
}

// hostSkipNote is the collection log's note on an instance without a door, in the collector's words.
const hostSkipNote = "no system_stats extension in database postgres (EDB's source build; not in PGDG) and no CloudWatch door (not RDS / Aurora)"

func pct2(v float64) float64 { return math.Round(v*100) / 100 }

// hostRows is one host row, the volumes and (on-prem) the io devices at t.
func (g *Gen) hostRows(t time.Time) []Row {
	s := g.Spec
	if !g.hostDoor() {
		return nil
	}
	has := func(part string) bool { return strings.Contains(s.Name, part) }
	k := int64(g.idx%5) + 1
	cpu := 25 + 20*curve(t) + 10*noise(s.Name+"cpu", t)
	if has("erp01") {
		cpu += 70
	}
	cpu = math.Min(99, cpu)
	toEnd := g.end.Sub(t).Hours() / 24 // days before the anchor: a volume's used bytes grow towards it
	switch s.Platform {
	case "onprem":
		dataTotal := 2000 * gib
		rate, usedEnd := 3*gib, 1300*gib // growth per day, used at the anchor
		if has("erp02") {
			rate, usedEnd = 9*gib, 1880*gib // 120 GiB free at the anchor: full in about 13 days
		}
		used := usedEnd - int64(float64(rate)*toEnd)
		rootTotal, rootUsed, swap := 50*gib, 19*gib, int64(0)
		if has("hr01") {
			rootUsed, swap = 48*gib, 3*gib
		}
		osName, kernel := "Red Hat Enterprise Linux 9.4 (Plow)", "Linux 5.14.0-427.el9.x86_64"
		if g.idx%2 == 0 {
			osName, kernel = "Ubuntu 22.04.5 LTS", "Linux 5.15.0-125-generic"
		}
		mins := t.Sub(g.start).Minutes()
		cum := func(base, perMin float64) int64 { return int64(base + perMin*mins*float64(k)) }
		return []Row{
			{"kind": "host", "source": "system_stats", "extension_version": "4.0", "os_name": osName, "os_version": kernel,
				"architecture": "x86_64", "host_name": s.Name, "cpu_model": "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz",
				"cpu_cores": 16, "logical_cpus": 32, "uptime_secs": int64(t.Sub(g.pmStart).Seconds()) + 600,
				"cpu_pct": pct2(cpu), "cpu_user_pct": pct2(cpu * 0.7), "cpu_system_pct": pct2(cpu * 0.2), "cpu_iowait_pct": pct2(cpu * 0.1),
				"mem_total": 64 * gib, "mem_used": (40 + k) * gib, "mem_free": (24 - k) * gib, "mem_cache": 12 * gib,
				"swap_total": 8 * gib, "swap_used": swap, "load1": pct2(cpu / 6), "load5": pct2(cpu / 7), "load15": pct2(cpu / 8)},
			{"kind": "disk", "source": "system_stats", "mount_point": "/var/lib/pgsql", "device": "/dev/mapper/vg_data-lv_pg", "fs_type": "xfs",
				"total_bytes": dataTotal, "used_bytes": used, "free_bytes": dataTotal - used, "mounts": []string{"/var/lib/pgsql"}, "holds_data": true},
			{"kind": "disk", "source": "system_stats", "mount_point": "/", "device": "/dev/mapper/vg_root-lv_root", "fs_type": "xfs",
				"total_bytes": rootTotal, "used_bytes": rootUsed, "free_bytes": rootTotal - rootUsed, "mounts": []string{"/", "/home"}, "holds_data": false},
			{"kind": "io", "device": "dm-2", "reads": cum(1e6, 3000), "writes": cum(5e6, 9000),
				"read_bytes": cum(1e6, 3000) * 8192, "write_bytes": cum(5e6, 9000) * 8192,
				"read_time_ms": cum(4e5, 1500), "write_time_ms": cum(9e5, 4000)},
		}
	case "rds":
		total := 500 * gib
		rate, freeEnd := gib/20, 210*gib // flat; orders01 fills in about 15 days
		if has("orders01") {
			rate, freeEnd = 5*gib/2, 38*gib
		}
		free := freeEnd + int64(float64(rate)*toEnd)
		swap := int64(0)
		if has("orders01") {
			swap = 1200 << 20 // over the 1 GiB cloud rule
		}
		return []Row{
			{"kind": "host", "source": "cloudwatch", "os_name": "Amazon RDS", "os_version": "db.r6g.xlarge", "aws_resource": s.Name,
				"cpu_pct": pct2(cpu), "mem_free": (6 + k%3) * gib, "swap_used": swap, "connections": 80 + 5*k, "metrics_at": t.Add(-time.Minute)},
			{"kind": "disk", "source": "cloudwatch", "mount_point": "rds:storage", "device": s.Name, "fs_type": "gp3",
				"total_bytes": total, "used_bytes": total - free, "free_bytes": free},
		}
	case "aurora":
		return []Row{
			{"kind": "host", "source": "cloudwatch", "os_name": "Amazon Aurora", "aws_resource": s.Name + "-instance-1",
				"cpu_pct": pct2(cpu), "mem_free": (10 + k%4) * gib, "swap_used": int64(0), "connections": 40 + k, "metrics_at": t.Add(-time.Minute)},
			{"kind": "disk", "source": "cloudwatch", "mount_point": "aurora:local", "device": s.Name + "-instance-1", "free_bytes": 60 * gib},
		}
	}
	return nil
}

// storageRows is the WAL directory, the tablespaces and the platform volume at t (every 15 minutes, the
// collection's cadence); the tablespace and the Aurora volume grow towards the anchor.
func (g *Gen) storageRows(t time.Time) []Row {
	s := g.Spec
	has := func(part string) bool { return strings.Contains(s.Name, part) }
	k := int64(g.idx%5) + 1
	toEnd := g.end.Sub(t).Hours() / 24
	h := int64(t.Sub(g.start).Hours())
	wal, files := int64(1+h%5)*256<<20, int64(16*(1+h%5))
	if s.Platform == "aurora" { // Aurora keeps no local WAL
		wal, files = 0, 0
	}
	out := []Row{
		{"kind": "wal", "name": "pg_wal", "size_bytes": wal, "files": files},
		{"kind": "tablespace", "name": "pg_default", "size_bytes": (300+k*40)*gib - int64(2*float64(gib)*toEnd)},
		{"kind": "tablespace", "name": "pg_global", "size_bytes": int64(800000)},
	}
	switch s.Platform {
	case "rds":
		row := Row{"kind": "rds", "name": s.Name, "allocated_bytes": 500 * gib, "autoscaling": false,
			"storage_type": "gp3", "iops": 3000, "throughput": 125, "class": "db.r6g.xlarge"}
		if has("billing01") {
			row["max_allocated_bytes"], row["autoscaling"] = 2000*gib, true
		}
		out = append(out, row)
	case "aurora":
		out = append(out, Row{"kind": "aurora_volume", "name": s.Name, "size_bytes": (200+k*30)*gib - int64(4*float64(gib)*toEnd),
			"limit_bytes": int64(140737488355328), "metrics_at": t})
	}
	return out
}
