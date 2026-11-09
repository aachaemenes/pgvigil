package web

import (
	"errors"
	"net/http"
	"strconv"
)

// The roles collection's API (task 31): one instance's Roles tab and the fleet root of superusers and login
// roles. The route is wired in Handler (GET /api/roles -> s.Roles); the overview check below feeds the Summary
// column Roles (check_group 'roles'): the role findings of warning severity.

func init() {
	overviewChecks = append(overviewChecks, struct{ name, sql string }{"roles", `
SELECT f.instance_id, f.severity, 'role: ' || f.setting, f.value, f.at, f.detail
  FROM pgvigil.role_findings f JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND f.severity IN ('warning', 'critical')`})
}

// sqlRolesState is the instance's read state: the collector's login, pg_monitor, the hba read or its skip.
const sqlRolesState = `
SELECT s.login_name, s.login_is_super, s.login_has_pg_monitor, s.hba_status, s.hba_note, s.hba_checksum, s.hba_rules,
       s.hba_read_at, array_to_string(s.unreadable_dbs, ', ') AS unreadable_dbs, s.snapshot_at
  FROM pgvigil.role_state s
 WHERE s.instance_id = $1`

// sqlRolesRoles is every present role with its attributes and the roles it is a direct member of; the server's and
// the platform's own roles flagged, the superusers and the login roles first.
const sqlRolesRoles = `
SELECT a.rolname, a.super, a.canlogin, a.createrole, a.createdb, a.replication, a.bypassrls, a.inherit,
       a.connlimit, a.valid_until, array_to_string(a.config, '; ') AS config,
       pgvigil.role_is_platform(i.platform, a.rolname, a.role_oid) AS is_platform,
       (SELECT string_agg(m.role_name, ', ' ORDER BY m.role_name) FROM pgvigil.role_members m
         WHERE m.instance_id = a.instance_id AND m.member_name = a.rolname AND m.is_present) AS member_of,
       a.snapshot_at
  FROM pgvigil.role_attributes a JOIN pgvigil.instances i USING (instance_id)
 WHERE a.instance_id = $1 AND a.is_present
 ORDER BY a.super DESC, a.canlogin DESC, pgvigil.role_is_platform(i.platform, a.rolname, a.role_oid), a.rolname`

// sqlRolesMembers is every present membership grant.
const sqlRolesMembers = `
SELECT m.role_name, m.member_name, nullif(m.grantor_name, '') AS grantor, m.admin_option, m.inherit_option, m.set_option, m.snapshot_at
  FROM pgvigil.role_members m
 WHERE m.instance_id = $1 AND m.is_present
 ORDER BY m.role_name, m.member_name, m.grantor_name`

// sqlRolesDatabaseACL is every database's ACL, one row per grantee and grantor.
const sqlRolesDatabaseACL = `
SELECT d.datname, d.owner, d.grantee, d.grantor, d.privileges, nullif(d.grantable, '') AS grantable, d.is_default, d.snapshot_at
  FROM pgvigil.acl_databases d
 WHERE d.instance_id = $1 AND d.is_present
 ORDER BY d.datname, d.grantee = 'PUBLIC' DESC, d.grantee, d.grantor`

// sqlRolesSchemaACL is every schema's ACL per database read.
const sqlRolesSchemaACL = `
SELECT s.datname, s.schema_name, s.owner, s.grantee, s.grantor, s.privileges, nullif(s.grantable, '') AS grantable, s.is_default, s.snapshot_at
  FROM pgvigil.acl_schemas s
 WHERE s.instance_id = $1 AND s.is_present
 ORDER BY s.datname, s.schema_name, s.grantee = 'PUBLIC' DESC, s.grantee, s.grantor`

// sqlRolesDefaultACL is every ALTER DEFAULT PRIVILEGES entry per database read.
const sqlRolesDefaultACL = `
SELECT p.datname, p.owner, nullif(p.schema_name, '') AS schema_name, p.objtype, p.grantee, p.grantor, p.privileges,
       nullif(p.grantable, '') AS grantable, p.snapshot_at
  FROM pgvigil.acl_default_privileges p
 WHERE p.instance_id = $1 AND p.is_present
 ORDER BY p.datname, p.owner, p.schema_name, p.objtype, p.grantee`

// sqlRolesHBA is the hba rules of the last read that could read them, in the order the server applies them.
const sqlRolesHBA = `
SELECT h.rule_number, h.file_name, h.line_number, h.type, array_to_string(h.databases, ',') AS databases,
       array_to_string(h.users, ',') AS users, h.address, h.netmask, h.auth_method, array_to_string(h.options, ' ') AS options,
       h.error, h.snapshot_at
  FROM pgvigil.hba_rules h
 WHERE h.instance_id = $1 AND h.is_present
 ORDER BY h.rule_number NULLS LAST, h.file_name, h.line_number`

// sqlRolesHistory is the newest 300 role and privilege changes of one instance.
const sqlRolesHistory = `
SELECT h.changed_at, h.object_kind, h.datname, h.object, h.change, h.old_value, h.new_value
  FROM pgvigil.role_history h
 WHERE h.instance_id = $1
 ORDER BY h.changed_at DESC, h.object_kind, h.datname NULLS FIRST, h.object
 LIMIT 300`

// sqlRolesFindings is one instance's role findings, the most severe first.
const sqlRolesFindings = `
SELECT f.severity, f.setting, f.value, f.suggested, f.detail, f.at
  FROM pgvigil.role_findings f
 WHERE f.instance_id = $1
 ORDER BY CASE f.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, f.setting, f.value`

// sqlRolesFleet is the fleet root: every active instance's superusers and login roles.
const sqlRolesFleet = `
SELECT f.instance_id, i.name AS instance, i.platform, f.rolname, f.super, f.canlogin, f.createrole, f.createdb,
       f.replication, f.bypassrls, f.valid_until, f.is_platform, f.member_of, f.snapshot_at
  FROM pgvigil.role_fleet f JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active
 ORDER BY i.name, f.super DESC, f.is_platform, f.rolname`

// sqlRolesFleetSummary is one row per active instance with a roles read: how many superusers (beyond the platform's
// own), login roles, findings above info, changes in 7 days, and whether the hba rules were read. Each count is one
// grouped pass, not a per-instance subquery.
const sqlRolesFleetSummary = `
WITH r AS (
  SELECT instance_id, count(*) FILTER (WHERE super AND NOT is_platform) AS superusers, count(*) FILTER (WHERE canlogin) AS login_roles
    FROM pgvigil.role_fleet GROUP BY instance_id
), f AS (
  SELECT instance_id, count(*) AS warnings FROM pgvigil.role_findings WHERE severity <> 'info' GROUP BY instance_id
), h AS (
  SELECT instance_id, count(*) AS changes_7d FROM pgvigil.role_history WHERE changed_at > now() - interval '7 days' GROUP BY instance_id
)
SELECT s.instance_id, i.name AS instance, i.platform, s.login_name, s.login_has_pg_monitor, s.hba_status,
       coalesce(r.superusers, 0) AS superusers, coalesce(r.login_roles, 0) AS login_roles,
       coalesce(f.warnings, 0) AS warnings, coalesce(h.changes_7d, 0) AS changes_7d, s.snapshot_at
  FROM pgvigil.role_state s JOIN pgvigil.instances i USING (instance_id)
  LEFT JOIN r USING (instance_id) LEFT JOIN f USING (instance_id) LEFT JOIN h USING (instance_id)
 WHERE i.is_active
 ORDER BY i.name`

// Roles serves /api/roles: with ?instance= that instance's read state, roles, memberships, database, schema and
// default ACLs, hba rules, change history and findings; without, the fleet's superusers and login roles with a
// per-instance summary.
func (s *Server) Roles(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if q.Get("instance") == "" {
		s.multi(w, r, []part{
			{"summary", sqlRolesFleetSummary, nil},
			{"roles", sqlRolesFleet, nil},
		})
		return
	}
	id, err := strconv.Atoi(q.Get("instance"))
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("instance must be a positive instance_id"))
		return
	}
	s.multi(w, r, []part{
		{"state", sqlRolesState, []any{id}},
		{"roles", sqlRolesRoles, []any{id}},
		{"members", sqlRolesMembers, []any{id}},
		{"dbacl", sqlRolesDatabaseACL, []any{id}},
		{"schemaacl", sqlRolesSchemaACL, []any{id}},
		{"defacl", sqlRolesDefaultACL, []any{id}},
		{"hba", sqlRolesHBA, []any{id}},
		{"history", sqlRolesHistory, []any{id}},
		{"findings", sqlRolesFindings, []any{id}},
	})
}
