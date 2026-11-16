package web

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// The stored weekly sp_Blitz (B20-2; migration 0273, the collection mssql_blitz) on a SQL Server instance's Findings tab.
//
//	GET  /api/mssql/blitz?instance=N[&part=...]   state (the due rule now: on or off and whose switch, due or not and
//	     why, the site's weekly slot and timeout, the database sp_Blitz is looked for in), last (the collection's last
//	     tick: a skip's words - not installed, no EXECUTE, off, not due), runs (the stored runs, newest first), shown
//	     (the newest successful run, with the newest run's outcome beside it), findings (the shown run's rows, each
//	     marked judged when the Checks tab judges its CheckID), judged (those CheckIDs: mssql.ChecksJudged).
//	POST /api/mssql/blitz/settings   the admin's switch (needAdmin, through s.post): {op: 'site', enabled, run_dow,
//	     run_hour, run_tz, timeout_s} (a key left out keeps its value) or {op: 'instance', instance_id, enabled (true,
//	     false, or null / left out = the site default), proc_db (left out = kept)}; written through
//	     import_mssql_blitz_setting on the actions door's audit login, every attempt in admin_audit; a refused value is
//	     409 with its words. Not through the demo's door (it names no such route).

const doorBlitzSetting doorRoute = "mssql/blitz/settings"

const sqlBlitzState = `SELECT d.* FROM pgvigil.mssql_blitz_due($1) d`

const sqlBlitzLast = `
SELECT c.snapshot_at, c.status, c.note, c.duration_ms
  FROM pgvigil.collection_dates c
 WHERE c.instance_id = $1 AND c.collection = 'mssql_blitz'`

const sqlBlitzRuns = `
SELECT r.run_id, r.started_at, r.seconds, r.outcome, r.findings, jsonb_array_length(r.messages) AS messages, r.error,
       r.frk_version, r.frk_version_date, r.login, r.proc_db
  FROM pgvigil.mssql_blitz_run r
 WHERE r.instance_id = $1
 ORDER BY r.started_at DESC, r.run_id DESC`

// the newest run, and beside it the newest successful one (the findings drawn): one row once a run is stored
const sqlBlitzShown = `
SELECT g.run_id, g.started_at, g.seconds, g.outcome, g.findings, g.frk_version, g.frk_version_date, g.login, g.proc_db,
       g.messages, n.run_id AS newest_run_id, n.started_at AS newest_at, n.outcome AS newest_outcome, n.error AS newest_error
  FROM (SELECT * FROM pgvigil.mssql_blitz_run x WHERE x.instance_id = $1 ORDER BY x.started_at DESC, x.run_id DESC LIMIT 1) n
  LEFT JOIN LATERAL (SELECT * FROM pgvigil.mssql_blitz_run y
                      WHERE y.instance_id = $1 AND y.outcome IN ('done', 'done with messages')
                      ORDER BY y.started_at DESC, y.run_id DESC LIMIT 1) g ON true`

const sqlBlitzFindings = `
SELECT f.n, f.priority, f.findings_group, f.finding, f.database_name, f.url, f.details, f.check_id,
       coalesce(f.check_id = ANY ($2::int[]), false) AS judged
  FROM pgvigil.mssql_blitz_finding f
 WHERE f.run_id = (SELECT y.run_id FROM pgvigil.mssql_blitz_run y
                    WHERE y.instance_id = $1 AND y.outcome IN ('done', 'done with messages')
                    ORDER BY y.started_at DESC, y.run_id DESC LIMIT 1)
 ORDER BY f.n`

const sqlBlitzJudged = `SELECT j AS check_id FROM unnest($1::int[]) j ORDER BY j`

// blitzJudged: mssql.ChecksJudged as the int[] parameter.
func blitzJudged() []int32 {
	ids := mssql.ChecksJudged()
	out := make([]int32, len(ids))
	for i, id := range ids {
		out[i] = int32(id)
	}
	return out
}

// MSSQLBlitz is GET /api/mssql/blitz: one instance's weekly sp_Blitz.
func (s *Server) MSSQLBlitz(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	judged := blitzJudged()
	s.multiPart(w, r, []part{
		{"state", sqlBlitzState, []any{id}},
		{"last", sqlBlitzLast, []any{id}},
		{"runs", sqlBlitzRuns, []any{id}},
		{"shown", sqlBlitzShown, []any{id}},
		{"findings", sqlBlitzFindings, []any{id, judged}},
		{"judged", sqlBlitzJudged, []any{judged}},
	})
}

// blitzSettingKeys: the keys each op of the switch takes.
var blitzSettingKeys = map[string][]string{
	"site":     {"enabled", "run_dow", "run_hour", "run_tz", "timeout_s"},
	"instance": {"instance_id", "enabled", "proc_db"},
}

// blitzSettingBody reads the switch's body into the function's payload, each value of its JSON type (a wrong type is
// the request's fault, said here; a value out of its range is the function's refusal, in admin_audit).
func blitzSettingBody(raw []byte) (map[string]any, error) {
	var in map[string]json.RawMessage
	if err := json.Unmarshal(raw, &in); err != nil {
		return nil, fmt.Errorf("body: %w", err)
	}
	var op string
	if err := json.Unmarshal(in["op"], &op); err != nil || blitzSettingKeys[op] == nil {
		return nil, errors.New("op is site or instance")
	}
	allowed := map[string]bool{"op": true}
	for _, k := range blitzSettingKeys[op] {
		allowed[k] = true
	}
	keys := make([]string, 0, len(in))
	for k := range in {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := map[string]any{"op": op}
	for _, k := range keys {
		v := in[k]
		if !allowed[k] {
			return nil, fmt.Errorf("%s is not a key of op %s (%s)", k, op, strings.Join(blitzSettingKeys[op], ", "))
		}
		if k != "op" && strings.TrimSpace(string(v)) == "null" {
			if k == "enabled" && op == "instance" {
				out[k] = nil // the site default
				continue
			}
			return nil, fmt.Errorf("%s is not null here", k)
		}
		switch k {
		case "op":
		case "enabled":
			var b bool
			if err := json.Unmarshal(v, &b); err != nil {
				if op == "site" {
					return nil, errors.New("enabled is true or false")
				}
				return nil, errors.New("enabled is true, false or null (the site default)")
			}
			out[k] = b
		case "run_dow", "run_hour", "timeout_s", "instance_id":
			var n float64
			limit := 30000.0
			if k == "instance_id" {
				limit = math.MaxInt32
			}
			if err := json.Unmarshal(v, &n); err != nil || n != math.Trunc(n) || math.Abs(n) > limit {
				return nil, fmt.Errorf("%s is a whole number", k)
			}
			out[k] = int64(n)
		case "run_tz", "proc_db":
			var str string
			if err := json.Unmarshal(v, &str); err != nil {
				return nil, fmt.Errorf("%s is a text", k)
			}
			out[k] = str
		}
	}
	if _, ok := out["instance_id"]; op == "instance" && !ok {
		return nil, errors.New("instance_id names the instance")
	}
	return out, nil
}

// MSSQLBlitzSettings is POST /api/mssql/blitz/settings: one attempt to change the site default or an instance's switch.
func (s *Server) MSSQLBlitzSettings(w http.ResponseWriter, r *http.Request) {
	seat, ok := s.seat(w, r, strings.Replace(s.ackOff(), "acknowledgements", "sp_Blitz settings", 1))
	if !ok {
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 4097))
	if err != nil || len(raw) > 4096 {
		writeErr(w, http.StatusBadRequest, errors.New("body: unreadable or over 4 KB"))
		return
	}
	if strings.Contains(string(raw), `\u0000`) || strings.ContainsRune(string(raw), 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was written"))
		return
	}
	pay, err := blitzSettingBody(raw)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	pay["ui_user"], pay["client"] = seat.user, seat.client
	sc := writeScope{Route: doorBlitzSetting}
	if v, ok := pay["instance_id"].(int64); ok {
		sc.InstanceID = int(v)
	} else {
		sc.AnyInstance = true // the site default reaches every instance
	}
	b, _ := json.Marshal(pay)
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	pool, ok := seat.poolFor(wctx, w, sc)
	if !ok {
		return
	}
	var out string
	if err := pool.QueryRow(wctx, `SELECT pgvigil.import_mssql_blitz_setting($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("sp_Blitz settings: not written", "user", seat.user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	var res struct {
		Outcome string `json:"outcome"`
		Detail  string `json:"detail"`
	}
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("import_mssql_blitz_setting answered %q", out))
		return
	}
	if res.Outcome != "done" {
		writeErr(w, http.StatusConflict, errors.New(res.Detail))
		return
	}
	s.log.Info("sp_Blitz settings: written", "user", seat.user, "detail", res.Detail)
	s.reply(w, r, res, nil)
}
