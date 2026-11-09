package demo

// Version rows for the demo fleet (the versions collection, task 49): the shapes import_versions takes.

import (
	"fmt"
	"strings"
	"time"
)

// versionRows is the hourly versions read: the Spec's version from the start, except idx%3 == 1, which ran
// the previous minor until a patch restart three days before the anchor (a 'patch' history row, last restart
// then); every database's collation on glibc 2.39, except idx%5 == 2's first application database, recorded
// on 2.36 (the collation finding); on RDS / Aurora the engine side: upgrade targets (the next two minors and
// the next major), auto minor upgrade on, a window, and on idx%2 == 0 a pending system-update forced in 10 days.
func (g *Gen) versionRows(t time.Time) []Row {
	s := g.Spec
	num, ver, pm := s.VersionNum, s.Version, g.pmStart
	patch := g.end.Add(-72 * time.Hour).Truncate(time.Hour)
	if g.idx%3 == 1 {
		if t.Before(patch) {
			num, ver = num-1, fmt.Sprintf("%d.%d", num/10000, num%10000-1)
		} else {
			pm = patch
		}
	}
	out := []Row{{"kind": "server", "server_version_num": num, "server_version": ver,
		"version_string": "PostgreSQL " + ver + " on x86_64-pc-linux-gnu, compiled by gcc, 64-bit", "postmaster_start": pm}}
	if s.Platform == "aurora" {
		out[0]["aurora_version"] = ver + ".1"
	}
	if num >= 150000 {
		for i, db := range g.dbList() {
			id := dbOID(i)
			if db == "postgres" {
				id = dbOID(-1)
			}
			rec := "2.39"
			if g.idx%5 == 2 && i == 0 {
				rec = "2.36"
			}
			out = append(out, Row{"kind": "collation", "dbid": id, "datname": db, "provider": "c", "locale": "en_US.UTF-8",
				"recorded_version": rec, "actual_version": "2.39"})
		}
	}
	if s.Platform != "rds" && s.Platform != "aurora" {
		return out
	}
	engine, res := "postgres", "instance:"+s.Name
	if s.Platform == "aurora" {
		engine, res = "aurora-postgresql", "cluster:"+s.Name
	}
	maj, mi := num/10000, num%10000
	// the cluster's instances (DescribeDBInstances): an Aurora cluster has a writer and a reader, an RDS instance is itself
	members := []Row{{"kind": "aws_instance", "id": s.Name, "class": "db.r6g.xlarge", "engine_version": fmt.Sprintf("%d.%d", maj, mi),
		"auto_minor_version_upgrade": true, "maintenance_window": "sun:06:00-sun:06:30", "is_writer": true}}
	if s.Platform == "aurora" {
		members = []Row{
			{"kind": "aws_instance", "id": s.Name + "-instance-1", "class": "db.r6g.large", "engine_version": fmt.Sprintf("%d.%d", maj, mi),
				"auto_minor_version_upgrade": true, "maintenance_window": "sun:06:00-sun:06:30", "is_writer": true},
			{"kind": "aws_instance", "id": s.Name + "-instance-2", "class": "db.r6g.large", "engine_version": fmt.Sprintf("%d.%d", maj, mi),
				"auto_minor_version_upgrade": true, "maintenance_window": "sun:06:30-sun:07:00", "is_writer": false},
		}
	}
	out = append(out, members...)
	out = append(out, Row{"kind": "aws_engine", "resource": res, "engine": engine, "engine_version": fmt.Sprintf("%d.%d", maj, mi),
		"auto_minor_version_upgrade": true, "maintenance_window": "sun:06:00-sun:06:30", "members": []string{s.Name}},
		Row{"kind": "aws_target", "engine_version": fmt.Sprintf("%d.%d", maj, mi+1), "is_major": false, "description": "minor (demo)", "auto_upgrade": false},
		Row{"kind": "aws_target", "engine_version": fmt.Sprintf("%d.%d", maj, mi+2), "is_major": false, "description": "minor (demo)", "auto_upgrade": false},
		Row{"kind": "aws_target", "engine_version": fmt.Sprintf("%d.1", maj+1), "is_major": true, "description": "major (demo)", "auto_upgrade": false})
	if g.idx%2 == 0 {
		out = append(out, Row{"kind": "aws_pending", "resource": "arn:aws:rds:us-east-1:000000000000:" + strings.Replace(res, "instance:", "db:", 1),
			"action": "system-update", "description": "New operating system update is available (demo)",
			"forced_apply": g.end.Add(10 * 24 * time.Hour), "opt_in_status": "pending"})
	}
	return append(out, Row{"kind": "aws_read"})
}
