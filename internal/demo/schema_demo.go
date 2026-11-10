package demo

// Schema rows for the demo fleet (the schema collection, task 59): the shapes import_schema takes. Every database
// of every instance carries a small snapshot (the public schema; on the first application database the app's three
// tables with their columns, primary keys and one secondary index); the erp instances (onprem-erp01 and its physical
// standby onprem-erp02, which shares its catalog) show the history the brief asks for on database erp:
//   - five days before the anchor public.order_lines.amount goes from numeric(12,2) to numeric(14,2);
//   - ten hours before the anchor the index public.order_lines_status_idx is dropped (inside the findings' 24 hours,
//     so a fresh demo shows the warning; the column change is the info only while it is 24 hours old or less);
// and the event trigger is installed on erp (the two statements are logged with their role), not on erp_audit and
// postgres, so the Schema tab shows a statement beside both changes and 'not installed' elsewhere.

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"time"
)

// schemaRows is the hourly schema read at t.
func (g *Gen) schemaRows(t time.Time) []Row {
	s := g.Spec
	erp := s.App == "erp"
	alterAt := g.end.Add(-5*24*time.Hour - 25*time.Minute)
	dropAt := g.end.Add(-10*time.Hour - 40*time.Minute)
	out := []Row{}
	for di, db := range g.dbList() {
		dbid := dbOID(di)
		if db == "postgres" {
			dbid = dbOID(-1)
		}
		objs := []Row{}
		obj := func(kind, identity, name, parent, def, owner, acl string) {
			h := sha256.New()
			for _, x := range []string{kind, def, owner, acl} {
				h.Write([]byte(x))
				h.Write([]byte{0})
			}
			r := Row{"kind": "obj", "dbid": dbid, "datname": db, "object_kind": kind, "identity": identity,
				"schema_name": "public", "object_name": name, "definition": def, "hash": hex.EncodeToString(h.Sum(nil))}
			if parent != "" {
				r["parent"] = parent
			}
			if owner != "" {
				r["owner"] = owner
			}
			if acl != "" {
				r["acl"] = acl
			}
			objs = append(objs, r)
		}
		owner := "app_" + s.App
		obj("schema", "public", "public", "", "schema", "pg_database_owner", "{pg_database_owner=UC/pg_database_owner,=U/pg_database_owner}")
		if di == 0 {
			ts := tables[s.App]
			for _, tb := range ts {
				id := "public." + tb
				obj("table", id, tb, "", "table", owner, fmt.Sprintf("{%s=arwdDxtm/%s,app_readonly=r/%s}", owner, owner, owner))
				obj("column", id+".id", "id", id, "bigint not null generated always as identity", "", "")
				obj("column", id+".created_at", "created_at", id, "timestamp with time zone not null default now()", "", "")
				obj("constraint", tb+"_pkey on "+id, tb+"_pkey", id, "PRIMARY KEY (id)", "", "")
				obj("index", "public."+tb+"_pkey", tb+"_pkey", id, fmt.Sprintf("CREATE UNIQUE INDEX %s_pkey ON public.%s USING btree (id)", tb, tb), "", "")
				obj("sequence", id+"_id_seq", tb+"_id_seq", "", "sequence bigint start 1 increment 1 min 1 max 9223372036854775807 cache 1 owned by "+id+".id", owner, "")
			}
			if erp {
				amount := "numeric(14,2) not null default 0"
				if t.Before(alterAt) {
					amount = "numeric(12,2) not null default 0"
				}
				obj("column", "public.order_lines.amount", "amount", "public.order_lines", amount, "", "")
				obj("column", "public.order_lines.status", "status", "public.order_lines", "text not null default 'open'::text", "", "")
				if t.Before(dropAt) {
					obj("index", "public.order_lines_status_idx", "order_lines_status_idx", "public.order_lines",
						"CREATE INDEX order_lines_status_idx ON public.order_lines USING btree (status)", "", "")
				}
				obj("function", "public.order_total(bigint)", "order_total", "",
					"function returns numeric language sql stable body sha256:5d1f0c2a9e7b4c31", owner, "")
			}
		}
		ddlLog := "not installed"
		dbRow := Row{"kind": "db", "dbid": dbid, "datname": db, "read_at": t, "objects": len(objs)}
		if erp && di == 0 {
			ddlLog = "installed"
			dbRow["ddl_log_table"] = "public.pgvigil_ddl_log"
		}
		dbRow["ddl_log"] = ddlLog
		out = append(out, dbRow)
		out = append(out, objs...)
		if erp && di == 0 {
			// the event trigger's rows of the hour before t (the collector reads since its cursor)
			for _, e := range []struct {
				at                     time.Time
				id                     int64
				event, tag, otype, oid string
				stmt                   string
			}{
				{alterAt, 4101, "ddl_command_end", "ALTER TABLE", "table", "public.order_lines",
					"ALTER TABLE order_lines ALTER COLUMN amount TYPE numeric(14,2)"},
				{dropAt, 4187, "sql_drop", "DROP INDEX", "index", "public.order_lines_status_idx",
					"DROP INDEX CONCURRENTLY order_lines_status_idx"},
			} {
				if e.at.After(t.Add(-time.Hour)) && !e.at.After(t) {
					out = append(out, Row{"kind": "ddl", "dbid": dbid, "datname": db, "log_id": e.id, "logged_at": e.at,
						"event": e.event, "command_tag": e.tag, "object_type": e.otype, "schema_name": "public",
						"object_identity": e.oid, "role_name": "erp_deploy", "statement": e.stmt})
				}
			}
		}
	}
	return out
}
