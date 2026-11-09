package demo

// Extension rows for the demo fleet (the extensions collection, task 30): the shapes import_extensions takes.

import (
	"strings"
	"time"
)

// extensionRows is the hourly extensions read: the contrib list the server offers, pg_stat_statements
// preloaded (not on a StmtBroken instance), and per database plpgsql, pg_stat_statements on the first
// application database and one scenario by instance: idx%4 == 0 amcheck updated 1.3 -> 1.5 two days before
// the anchor (a history row), 1 amcheck left at 1.3 (outdated), 2 pg_hint_plan created and not preloaded,
// 3 auto_explain preloaded at 0 ms.
func (g *Gen) extensionRows(t time.Time) []Row {
	avail := [][2]string{{"plpgsql", "1.0"}, {"pg_stat_statements", "1.10"}, {"amcheck", "1.5"}, {"pg_trgm", "1.6"},
		{"hstore", "1.8"}, {"pgcrypto", "1.3"}, {"pg_hint_plan", "1.6.0"}, {"pg_buffercache", "1.4"}}
	out := []Row{}
	for _, a := range avail {
		out = append(out, Row{"kind": "available", "name": a[0], "default_version": a[1], "comment": a[0] + " (demo)"})
	}
	shared := []string{}
	if !g.Spec.StmtBroken {
		shared = append(shared, "pg_stat_statements")
	}
	if g.idx%4 == 3 {
		shared = append(shared, "auto_explain")
	}
	for i, l := range shared {
		out = append(out, Row{"kind": "library", "name": l, "via": "shared", "position": i + 1})
	}
	out = append(out, Row{"kind": "setting", "name": "shared_preload_libraries", "setting": strings.Join(shared, ",")},
		Row{"kind": "setting", "name": "session_preload_libraries", "setting": ""},
		Row{"kind": "setting", "name": "local_preload_libraries", "setting": ""})
	if !g.Spec.StmtBroken {
		out = append(out, Row{"kind": "setting", "name": "pg_stat_statements.track", "setting": "top"},
			Row{"kind": "setting", "name": "pg_stat_statements.max", "setting": "5000"})
	}
	if g.idx%4 == 3 {
		out = append(out, Row{"kind": "setting", "name": "auto_explain.log_min_duration", "setting": "0", "unit": "ms"},
			Row{"kind": "setting", "name": "auto_explain.log_analyze", "setting": "off"})
	}
	dbs := g.dbList()
	out = append(out, Row{"kind": "databases", "names": dbs})
	amcheck := "1.5"
	if g.idx%4 == 1 || (g.idx%4 == 0 && t.Before(g.end.Add(-48*time.Hour))) {
		amcheck = "1.3"
	}
	for i, db := range dbs {
		id := dbOID(i)
		if db == "postgres" {
			id = dbOID(-1)
		}
		out = append(out, Row{"kind": "db", "dbid": id, "datname": db},
			Row{"kind": "installed", "dbid": id, "datname": db, "name": "plpgsql", "version": "1.0", "schema_name": "pg_catalog"})
		if i != 0 || db == "postgres" {
			continue
		}
		if !g.Spec.StmtBroken {
			out = append(out, Row{"kind": "installed", "dbid": id, "datname": db, "name": "pg_stat_statements", "version": "1.10", "schema_name": "public"})
		}
		if g.idx%4 <= 1 {
			out = append(out, Row{"kind": "installed", "dbid": id, "datname": db, "name": "amcheck", "version": amcheck, "schema_name": "public"})
		}
		if g.idx%4 == 2 {
			out = append(out, Row{"kind": "installed", "dbid": id, "datname": db, "name": "pg_hint_plan", "version": "1.6.0", "schema_name": "hint_plan"})
		}
	}
	return out
}
