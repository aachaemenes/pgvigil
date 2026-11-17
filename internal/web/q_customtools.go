package web

// Custom tools (parity set 3, task 8; DBA Dash's Custom Tools folder, L169): an instance's own functions (PostgreSQL)
// or procedures (SQL Server) in the schema pgvigil_tools of the database its read login connects to - a DBA's opt-in:
// the schema is theirs to make - listed and run as tools. They run as custom reports run: read-only, as the instance's
// read login after its refusal (pgRefusal) or fence (reportFence), under a timeout, each run audited (custom_report_log,
// op run, its tool named). The list is read live, the tool to run looked up in it: a name or a type that is not the
// catalog's own is never put in a statement.
//
//	GET  /api/customtools?instance=N        the tools (name, arguments, result, description, params)
//	POST /api/customtools/run               {instance_id, tool, params: {name: value}} -> {runs: [one run]}

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// customTool is one tool as the list read it: its IN parameters in order with their types as the catalog writes them
type customTool struct {
	Name        string       `json:"name"`
	Arguments   string       `json:"arguments"`
	Result      string       `json:"result"`
	Description string       `json:"description"`
	Params      []customArgs `json:"params"`
}

type customArgs struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

// the list: the functions in pgvigil_tools the read login may execute, their IN (and INOUT, VARIADIC) arguments by
// name and type (format_type: the catalog's own spelling)
const sqlCustomToolsPG = `
SELECT p.proname AS name, pg_get_function_arguments(p.oid) AS arguments, pg_get_function_result(p.oid) AS result,
       coalesce(obj_description(p.oid, 'pg_proc'), '') AS description,
       (SELECT coalesce(json_agg(json_build_object('name', coalesce(a.name, ''), 'type', format_type(a.typ, NULL)) ORDER BY a.n), '[]'::json)
          FROM unnest(coalesce(p.proallargtypes, p.proargtypes::oid[]),
                      coalesce(p.proargmodes, array_fill('i'::"char", ARRAY[p.pronargs::int])),
                      p.proargnames) WITH ORDINALITY AS a(typ, mode, name, n)
         WHERE a.mode IN ('i', 'b', 'v'))::text AS params
  FROM pg_proc p
 WHERE p.pronamespace = to_regnamespace('pgvigil_tools') AND p.prokind = 'f' AND has_function_privilege(p.oid, 'EXECUTE')
 ORDER BY 1
 LIMIT 500`

const sqlCustomToolsMS = `
SELECT o.name, '' AS arguments, '' AS result, CAST(ISNULL(ep.value, '') AS nvarchar(4000)) AS description,
       ISNULL((SELECT p.name AS name, TYPE_NAME(p.user_type_id) AS type FROM sys.parameters p
                WHERE p.object_id = o.object_id AND p.is_output = 0 ORDER BY p.parameter_id FOR JSON PATH), '[]') AS params
  FROM sys.procedures o
  LEFT JOIN sys.extended_properties ep ON ep.major_id = o.object_id AND ep.minor_id = 0 AND ep.class = 1 AND ep.name = 'MS_Description'
 WHERE SCHEMA_NAME(o.schema_id) = 'pgvigil_tools'
   AND HAS_PERMS_BY_NAME(QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name), 'OBJECT', 'EXECUTE') = 1
 ORDER BY o.name`

// a type the catalog wrote, as it may stand after '::' (no statement break, no comment); a SQL Server parameter's name
var (
	toolType  = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_ ."\[\](),]{0,120}$`)
	toolParam = regexp.MustCompile(`^@[A-Za-z0-9_#$@]{1,127}$`)
)

const toolNone = "No tool: the schema pgvigil_tools of the database the read login connects to holds no function (PostgreSQL) or procedure (SQL Server) the login may execute. A DBA makes the schema and its tools; each runs read-only, as the read login."

// toolInstance is the instance a request names (active only)
func (s *Server) toolInstance(ctx context.Context, id int) (name, engine string, err error) {
	err = s.pool.QueryRow(ctx, `SELECT name, engine FROM pgvigil.instances WHERE instance_id = $1 AND is_active`, id).Scan(&name, &engine)
	return name, engine, err
}

// toolsOf reads an instance's tools live through its read login; why = the words when they cannot be read
func (s *Server) toolsOf(ctx context.Context, ds *doorSet, name, engine string) (tools []customTool, why string, err error) {
	dsn, _, no := ds.readLogin(engine, name)
	if no.Why != "" {
		return nil, no.Why, nil
	}
	var sets []resultSet
	if engine == "sqlserver" {
		sets, why, err = runMSWith(ctx, dsn, sqlCustomToolsMS, nil, 15*time.Second, 500, true, reportFence)
	} else {
		cfg, perr := pgx.ParseConfig(dsn)
		if perr != nil {
			return nil, "", errors.New("the monitoring dsn does not parse")
		}
		sets, why, err = runPG(ctx, cfg, sqlCustomToolsPG, nil, 15*time.Second, 500, nil)
	}
	if err != nil || why != "" || len(sets) == 0 {
		return nil, why, err
	}
	for _, r := range sets[0].Rows {
		if len(r) < 5 {
			continue
		}
		t := customTool{Name: fmt.Sprint(r[0]), Arguments: cellStr(r[1]), Result: cellStr(r[2]), Description: cellStr(r[3])}
		if err := json.Unmarshal([]byte(cellStr(r[4])), &t.Params); err != nil {
			return nil, "", fmt.Errorf("the tool %s's parameters cannot be read: %v", t.Name, err)
		}
		tools = append(tools, t)
	}
	return tools, "", nil
}

// cellStr is a cell as text ("" for NULL)
func cellStr(v any) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	b, _ := json.Marshal(v)
	return string(b)
}

// CustomTools is GET /api/customtools?instance=N.
func (s *Server) CustomTools(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.URL.Query().Get("instance"))
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("instance is an instance's id"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	name, engine, err := s.toolInstance(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no active instance %d", id))
		return
	} else if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	out := struct {
		Instance string          `json:"instance"`
		Engine   string          `json:"engine"`
		Tools    []customTool    `json:"tools"`
		Off      string          `json:"off,omitempty"`  // why the list was not read
		None     string          `json:"none,omitempty"` // the words for an empty list
		RunOff   string          `json:"run_off,omitempty"`
		Can      map[string]bool `json:"can"` // what the session's role may do (B24f): a run needs operator
	}{Instance: name, Engine: engine, Tools: []customTool{}, RunOff: s.customReportsOff(), Can: s.roleCan(r)}
	if s.demo != nil {
		out.Off = name + " is a demo instance: no server stands behind it, so it has no tool"
	} else {
		tools, why, err := s.toolsOf(ctx, s.doorsNow(), name, engine)
		switch {
		case err != nil:
			out.Off = "The tools could not be read: " + err.Error()
		case why != "":
			out.Off = why
		case len(tools) == 0:
			out.None = toolNone
		default:
			out.Tools = tools
		}
	}
	s.reply(w, r, out, nil)
}

type toolRunBody struct {
	InstanceID int                `json:"instance_id"`
	Tool       string             `json:"tool"`
	Params     map[string]*string `json:"params"`
}

// toolCall is the statement that runs t and its bound values: each parameter given a value bound as text and cast to
// the catalog's own type (PostgreSQL), or passed by its name (SQL Server); a parameter left empty takes the tool's
// default (by name) or NULL (an unnamed PostgreSQL argument)
func toolCall(engine string, t customTool, given map[string]*string) (stmt string, pgArgs pgx.NamedArgs, msArgs []any, err error) {
	val := func(p customArgs, i int) (string, bool) {
		k := p.Name
		if k == "" {
			k = "$" + strconv.Itoa(i+1)
		}
		v, ok := given[strings.TrimPrefix(k, "@")]
		if !ok || v == nil || strings.TrimSpace(*v) == "" {
			return "", false
		}
		return *v, true
	}
	if engine == "sqlserver" {
		parts := []string{}
		for i, p := range t.Params {
			if !toolParam.MatchString(p.Name) {
				return "", nil, nil, fmt.Errorf("the tool's parameter %q is not one pgvigil binds", p.Name)
			}
			if v, ok := val(p, i); ok {
				a := "a" + strconv.Itoa(i+1)
				parts = append(parts, p.Name+" = @"+a)
				msArgs = append(msArgs, sql.Named(a, v))
			}
		}
		stmt = "EXEC [pgvigil_tools].[" + strings.ReplaceAll(t.Name, "]", "]]") + "]"
		if len(parts) > 0 {
			stmt += " " + strings.Join(parts, ", ")
		}
		return stmt, nil, msArgs, nil
	}
	named := true
	for _, p := range t.Params {
		if p.Name == "" {
			named = false
		}
	}
	pgArgs = pgx.NamedArgs{}
	parts := []string{}
	for i, p := range t.Params {
		if !toolType.MatchString(p.Type) || strings.Contains(p.Type, "--") {
			return "", nil, nil, fmt.Errorf("the tool's argument type %q is not one pgvigil binds", p.Type)
		}
		a := "a" + strconv.Itoa(i+1)
		v, ok := val(p, i)
		bound := "(@" + a + "::text)::" + p.Type
		switch {
		case named && !ok:
			continue // the function's own default
		case named:
			parts = append(parts, pgx.Identifier{p.Name}.Sanitize()+" => "+bound)
		case !ok:
			parts = append(parts, "NULL::"+p.Type)
			continue
		default:
			parts = append(parts, bound)
		}
		pgArgs[a] = v
	}
	stmt = "SELECT * FROM " + pgx.Identifier{"pgvigil_tools", t.Name}.Sanitize() + "(" + strings.Join(parts, ", ") + ")"
	return stmt, pgArgs, nil, nil
}

// CustomToolRun is POST /api/customtools/run.
func (s *Server) CustomToolRun(w http.ResponseWriter, r *http.Request) {
	user, raw, ok := s.reportGate(w, r, 64<<10)
	if !ok {
		return
	}
	var in toolRunBody
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), runBudget)
	defer cancel()
	if err := s.mayAudit(ctx); err != nil {
		writeErr(w, http.StatusServiceUnavailable, err)
		return
	}
	name, engine, err := s.toolInstance(ctx, in.InstanceID)
	if errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no active instance %d", in.InstanceID))
		return
	} else if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	row := map[string]any{"op": "run", "ui_user": user, "client": clientIP(r), "tool": "custom tool: " + in.Tool, "instance_id": in.InstanceID,
		"instance": name, "params": map[string]any{"values": in.Params}}
	if s.demo != nil {
		s.refuseRun(w, r, row, fmt.Errorf("%s is a demo instance: no server stands behind it, so no tool runs here", name))
		return
	}
	ds := s.doorsNow()
	tools, why, err := s.toolsOf(ctx, ds, name, engine)
	switch {
	case err != nil:
		s.refuseRun(w, r, row, fmt.Errorf("the tools could not be read: %v", err))
		return
	case why != "":
		s.refuseRun(w, r, row, errors.New(why))
		return
	}
	var t *customTool
	for i := range tools {
		if tools[i].Name == in.Tool {
			t = &tools[i]
		}
	}
	if t == nil {
		s.refuseRun(w, r, row, fmt.Errorf("%s has no tool %q in pgvigil_tools that the read login may execute", name, in.Tool))
		return
	}
	stmt, pgArgs, msArgs, err := toolCall(engine, *t, in.Params)
	if err != nil {
		s.refuseRun(w, r, row, err)
		return
	}
	run := instanceRun{InstanceID: in.InstanceID, Instance: name, Engine: engine, Statement: stmt, DoorGen: ds.Gen}
	t0 := time.Now()
	dsn, kind, no := ds.readLogin(engine, name)
	run.Door = kind
	switch {
	case no.Why != "":
		run.finish(t0, nil, no.Why, nil)
	case engine == "sqlserver":
		sets, why, err := runMSWith(ctx, dsn, stmt, msArgs, time.Minute, 5000, true, reportFence)
		run.finish(t0, sets, why, err)
	default:
		cfg, perr := pgx.ParseConfig(dsn)
		if perr != nil {
			run.finish(t0, nil, "", errors.New("the monitoring dsn does not parse"))
			break
		}
		sets, why, err := runPG(ctx, cfg, stmt, pgArgs, time.Minute, 5000, nil)
		run.finish(t0, sets, why, err)
	}
	row["outcome"], row["detail"], row["rows"], row["duration_ms"], row["statement"] = run.Outcome, run.Error, run.Rows, run.DurationMS, run.Statement
	actx, acancel := context.WithTimeout(context.WithoutCancel(r.Context()), auditBudget)
	defer acancel()
	if err := s.auditRun(actx, run.audit(row)); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("the run's audit row could not be written (%v): its rows are withheld", err))
		return
	}
	s.reply(w, r, struct {
		RanAt time.Time     `json:"ran_at"`
		Runs  []instanceRun `json:"runs"`
	}{time.Now().UTC(), []instanceRun{run}}, nil)
}
