package demo

// Role rows for the demo fleet (the roles collection, task 31): the shapes import_roles takes.
//
// Wiring (the lead's, in gen.go):
//   Step:        inside `if first || t.Minute() == 0 {` next to extensions and versions:  add("roles", g.roleRows(t))
//   Collections: append "roles" to the final list: ..., "extensions", "versions", "roles")

import (
	"strings"
	"time"
)

// roleRows is the hourly roles read. Every instance has the platform's own roles (postgres on-prem; rdsadmin,
// rds_superuser and the master user on RDS / Aurora; azuresu and azure_pg_admin on Azure; cloudsqladmin and
// cloudsqlsuperuser on Cloud SQL), the predefined pg_monitor, the collector's login pgvigil, and the application's
// roles <app>_owner (NOLOGIN, owns the app schema), <app>_rw, <app>_ro and report_ro. One scenario by instance:
// idx%4 == 0 an extra superuser dba_legacy, 1 <app>_rw with CREATEROLE, 2 report_ro granted CONNECT on every
// database, 3 <app>_ro with BYPASSRLS; idx%5 == 4 the pgvigil login lacks pg_monitor; idx%3 == 0 report_ro
// joins <app>_ro two days before the anchor and <app>_rw loses TEMPORARY on the first database (history rows).
// The hba rules are read on an on-prem primary of even idx (the login granted SELECT on pg_hba_file_rules);
// elsewhere they are skipped with the collector's reason. Where both hold (idx%4 == 0 on an on-prem primary with the
// rules read: onprem-erp01), dba_legacy is named by no hba rule, so it also shows 'login without a way in'. The
// checksum is fixed, so the demo never shows an hba change.
func (g *Gen) roleRows(t time.Time) []Row {
	s := g.Spec
	app := strings.ToLower(s.App)
	owner, rw, ro := app+"_owner", app+"_rw", app+"_ro"
	changed := g.idx%3 == 0 && !t.Before(g.end.Add(-48*time.Hour))
	out := []Row{}
	role := func(name string, oid int64, super, login, createrole, createdb, bypass bool) {
		out = append(out, Row{"kind": "role", "name": name, "oid": oid, "super": super, "inherit": true, "createrole": createrole,
			"createdb": createdb, "canlogin": login, "replication": false, "bypassrls": bypass, "connlimit": -1,
			"valid_until": nil, "config": []string{}})
	}
	member := func(r, m, grantor string) {
		out = append(out, Row{"kind": "member", "role": r, "member": m, "grantor": grantor, "admin_option": false,
			"inherit_option": true, "set_option": true})
	}
	boot, admin := "postgres", ""
	switch s.Platform {
	case "rds", "aurora":
		boot, admin = "rdsadmin", "dbadmin"
		role("rdsadmin", 10, true, true, true, true, true)
		role("rds_superuser", 16385, false, false, true, true, false)
		role(admin, 16390, false, true, true, true, false)
		member("rds_superuser", admin, "rdsadmin")
	case "azure":
		boot, admin = "azuresu", "pgadmin"
		role("azuresu", 10, true, true, true, true, true)
		role("azure_pg_admin", 16385, false, false, true, true, false)
		role(admin, 16390, false, true, true, true, false)
		member("azure_pg_admin", admin, "azuresu")
	case "cloudsql":
		boot, admin = "cloudsqladmin", "postgres"
		role("cloudsqladmin", 10, true, true, true, true, true)
		role("cloudsqlsuperuser", 16385, false, false, true, true, false)
		role(admin, 16390, false, true, true, true, false)
		member("cloudsqlsuperuser", admin, "cloudsqladmin")
	default:
		role("postgres", 10, true, true, true, true, true)
	}
	role("pg_monitor", 3373, false, false, false, false, false)
	role("pgvigil", 16400, false, true, false, false, false)
	monitor := g.idx%5 != 4
	if monitor {
		member("pg_monitor", "pgvigil", boot)
	}
	role(owner, 16401, false, false, false, false, false)
	role(rw, 16402, false, true, g.idx%4 == 1, false, false)
	role(ro, 16403, false, true, false, false, g.idx%4 == 3)
	role("report_ro", 16404, false, true, false, false, false)
	if g.idx%4 == 0 {
		role("dba_legacy", 16405, true, true, false, false, false)
	}
	member(ro, rw, boot)
	if changed {
		member(ro, "report_ro", boot)
	}
	out = append(out, Row{"kind": "login", "name": "pgvigil", "is_super": false, "has_pg_monitor": monitor})

	// the database ACLs: every database owned by the owner role (postgres by the bootstrap one), PUBLIC's default
	// CONNECT and TEMPORARY, the application's login on its own databases, report_ro everywhere on idx%4 == 2
	dbs := g.dbList()
	out = append(out, Row{"kind": "dbacls", "names": dbs}, Row{"kind": "databases", "names": dbs})
	acl := func(kind, db string, extra Row) {
		r := Row{"kind": kind, "datname": db, "grantable": ""}
		for k, v := range extra {
			r[k] = v
		}
		out = append(out, r)
	}
	for i, db := range dbs {
		own := owner
		if db == "postgres" {
			own = boot
		}
		acl("dbacl", db, Row{"owner": own, "grantee": own, "grantor": own, "privileges": "CONNECT,CREATE,TEMPORARY", "is_default": false})
		acl("dbacl", db, Row{"owner": own, "grantee": "PUBLIC", "grantor": own, "privileges": "CONNECT,TEMPORARY", "is_default": false})
		if db != "postgres" {
			p := "CONNECT,TEMPORARY"
			if changed && i == 0 {
				p = "CONNECT"
			}
			acl("dbacl", db, Row{"owner": own, "grantee": rw, "grantor": own, "privileges": p, "is_default": false})
			acl("dbacl", db, Row{"owner": own, "grantee": ro, "grantor": own, "privileges": "CONNECT", "is_default": false})
		}
		if g.idx%4 == 2 {
			acl("dbacl", db, Row{"owner": own, "grantee": "report_ro", "grantor": own, "privileges": "CONNECT", "is_default": false})
		}

		// per database: the public schema and, on an application database, the app schema and its default privileges
		id := dbOID(i)
		if db == "postgres" {
			id = dbOID(-1)
		}
		out = append(out, Row{"kind": "db", "dbid": id, "datname": db})
		acl("schemaacl", db, Row{"schema_name": "public", "owner": "pg_database_owner", "grantee": "pg_database_owner",
			"grantor": "pg_database_owner", "privileges": "CREATE,USAGE", "is_default": false})
		acl("schemaacl", db, Row{"schema_name": "public", "owner": "pg_database_owner", "grantee": "PUBLIC",
			"grantor": "pg_database_owner", "privileges": "USAGE", "is_default": false})
		if db == "postgres" {
			continue
		}
		acl("schemaacl", db, Row{"schema_name": app, "owner": owner, "grantee": owner, "grantor": owner, "privileges": "CREATE,USAGE", "is_default": false})
		acl("schemaacl", db, Row{"schema_name": app, "owner": owner, "grantee": rw, "grantor": owner, "privileges": "USAGE", "is_default": false})
		acl("schemaacl", db, Row{"schema_name": app, "owner": owner, "grantee": ro, "grantor": owner, "privileges": "USAGE", "is_default": false})
		acl("defacl", db, Row{"owner": owner, "schema_name": app, "objtype": "table", "grantee": rw, "grantor": owner, "privileges": "DELETE,INSERT,SELECT,UPDATE"})
		acl("defacl", db, Row{"owner": owner, "schema_name": app, "objtype": "table", "grantee": ro, "grantor": owner, "privileges": "SELECT"})
		acl("defacl", db, Row{"owner": owner, "schema_name": app, "objtype": "sequence", "grantee": rw, "grantor": owner, "privileges": "SELECT,USAGE"})
	}

	if s.Platform == "onprem" && !s.Replica && g.idx%2 == 0 {
		hba := [][]any{
			{1, "local", "all", "postgres", nil, "peer"},
			{2, "host", "all", "pgvigil", "10.0.0.0/8", "scram-sha-256"},
			{3, "hostssl", app, "+" + ro, "10.20.0.0/16", "scram-sha-256"},
			{4, "hostssl", app, rw, "10.20.0.0/16", "scram-sha-256"},
			{5, "hostssl", "all", "report_ro", "10.30.0.0/16", "scram-sha-256"},
			{6, "host", "replication", "replicator", "10.0.0.0/8", "scram-sha-256"},
		}
		for _, h := range hba {
			out = append(out, Row{"kind": "hba", "rule_number": h[0], "file_name": "/etc/postgresql/pg_hba.conf", "line_number": 80 + h[0].(int),
				"type": h[1], "databases": []string{h[2].(string)}, "users": []string{h[3].(string)}, "address": h[4],
				"netmask": nil, "auth_method": h[5], "options": nil, "error": nil})
		}
		out = append(out, Row{"kind": "hba_state", "status": "read", "note": "", "checksum": "6f1c0d2e9b8a7c4d3e2f1a0b9c8d7e6f", "rules": len(hba)})
	} else {
		out = append(out, Row{"kind": "hba_state", "status": "skipped",
			"note": "pg_hba_file_rules is readable by a superuser only (or a login granted SELECT on it): the monitoring login is neither, so the hba rules are not read"})
	}
	return out
}
