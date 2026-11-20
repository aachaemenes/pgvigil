package web

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// ---- running one composed panel (the server half) ---------------------------------------------------------------------
//   POST /api/compose/run[?check=1] {panel, scope, from, to, database} -> {rows, metric, unit, grain, read, from, to,
//                                       cut, bucket_secs, utc_days, instances, last_partial}; check=1 compiles and counts
//                                       the scope without reading (the composer's validate-then-save: rows absent)
//   GET  /api/compose/catalog  every metric a panel may name: key, engine, family, label, unit, grain, per_database,
//                              fresh_secs (the composer's grouped picker)
// The dashboard page posts each composed panel (and the composer its live preview); serve compiles it (compose.go) and
// runs its one statement, after counting the scope's instances (a scope over composeMaxInstances is refused in
// words; the count scales the family's range). At most composeSlots panels read at once (2 of serve's 8
// connections), so dashboards and previews never hold every connection - the page sends at most 2 at once; a panel that
// waits past composeWait is told so in words, and one that runs past serve's 15 s statement timeout is told what to narrow. A request the client drops (a preview superseded by the
// next change) cancels its statement. A read, so the UI login's reads rule applies; the X-Pgvigil header is required
// because the body is POSTed.                                                                     -> Server.ComposeRun

const (
	composeSlotsN  = 2
	composeWait    = 45 * time.Second // under serve's 75 s write timeout: a 12-panel dashboard at the caps (about 7.5 s a panel) queues 2 wide
	composeBodyMax = 64 << 10
)

var composeSlots = make(chan struct{}, composeSlotsN)

type composeRequest struct {
	Panel    PanelSpec    `json:"panel"`
	Scope    ComposeScope `json:"scope"`
	From     time.Time    `json:"from"`
	To       time.Time    `json:"to"`
	Database string       `json:"database"` // the dashboard's $database variable ("" = none)
}

// catalogGrain is metric_catalog.grain's rule (scripts/metric-catalog-grain.sql), for a repository whose catalog has no
// grain column yet: a rate or a gauge averaged, a count per collection interval summed, a ratio never summed.
func catalogGrain(key, unit string) string {
	switch {
	case unit == "per_s" || unit == "bytes_per_s":
		return "rate"
	case unit == "pct":
		return "ratio"
	case key == "database.deadlocks" || key == "server.checkpoints" || key == "server.checkpoints_req":
		return "interval_count"
	}
	return "gauge"
}

// ComposeRun is POST /api/compose/run.
func (s *Server) ComposeRun(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, composeBodyMax+1))
	if err != nil || len(raw) > composeBodyMax {
		writeErr(w, http.StatusBadRequest, errors.New("body: unreadable or over 64 KB"))
		return
	}
	var in composeRequest
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	if in.To.IsZero() {
		in.To = time.Now()
	}
	if in.From.IsZero() {
		in.From = in.To.Add(-24 * time.Hour)
	}
	// the metric: its catalog row (its grain from the catalog's column once 0300's lines are in, else the same rule)
	var cat map[string]any
	if err := s.pool.QueryRow(r.Context(), `SELECT to_jsonb(c) FROM pgvigil.metric_catalog c WHERE c.key = $1`, in.Panel.Metric).Scan(&cat); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeErr(w, http.StatusBadRequest, fmt.Errorf("no metric %q in the catalog", in.Panel.Metric))
		} else {
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("the catalog could not be read: %v", err))
		}
		return
	}
	str := func(k string) string { v, _ := cat[k].(string); return v }
	m := catalogMetric{Key: str("key"), Engine: str("engine"), Family: str("family"), Metric: str("metric"), Unit: str("unit"), Grain: str("grain")}
	m.PerDatabase, _ = cat["per_database"].(bool)
	if m.Grain == "" {
		m.Grain = catalogGrain(m.Key, m.Unit)
	}
	// the scope's instances first: past composeMaxInstances the panel is refused, never cut; the count scales the range
	cq, cargs, err := countScope(in.Panel, m, in.Scope)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var n int
	if err := s.pool.QueryRow(r.Context(), cq, cargs...).Scan(&n); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("the scope's instances could not be counted: %v", err))
		return
	}
	c, err := compilePanel(in.Panel, m, in.Scope, in.From, in.To, in.Database, n, time.Now())
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	out := map[string]any{"metric": m.Key, "unit": m.Unit, "grain": m.Grain, "read": c.Read, "from": c.From, "to": c.To,
		"cut": c.Cut, "bucket_secs": c.BucketSecs, "utc_days": c.UTCDays, "instances": c.Instances, "last_partial": c.LastPart}
	if r.URL.Query().Get("check") == "1" {
		s.reply(w, r, out, nil)
		return
	}
	select {
	case composeSlots <- struct{}{}:
	case <-time.After(composeWait):
		writeErr(w, http.StatusServiceUnavailable, fmt.Errorf("%d panel reads are running and this one waited %s: it runs on the next refresh", composeSlotsN, composeWait))
		return
	case <-r.Context().Done():
		return
	}
	t, err := s.query(r.Context(), c.SQL, c.Args...)
	<-composeSlots // the slot back before the reply is written: a slow client never holds it
	if err != nil {
		var pe *pgconn.PgError
		if errors.As(err, &pe) && pe.Code == "57014" && r.Context().Err() == nil {
			writeErr(w, http.StatusGatewayTimeout, fmt.Errorf("the panel's read ran past serve's 15 s: a shorter range, a smaller scope or a coarser bucket (%s)", c.Read))
			return
		}
		if r.Context().Err() != nil {
			return // the client went away (a superseded preview): nothing to answer
		}
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("the panel could not be read: %v", err))
		return
	}
	out["rows"] = t
	s.reply(w, r, out, nil)
}

// ComposeCatalog is GET /api/compose/catalog: the metrics a panel may name, each with its grain (the catalog's column
// once scripts/metric-catalog-grain.sql is in, else catalogGrain's same rule).
func (s *Server) ComposeCatalog(w http.ResponseWriter, r *http.Request) {
	t, err := s.query(r.Context(), `SELECT c.key, c.engine, c.family, c.family_label, c.metric, c.label, c.unit, c.per_database,
       c.fresh_secs, to_jsonb(c)->>'grain' AS grain
  FROM pgvigil.metric_catalog c ORDER BY c.family_sort, c.sort`)
	if err == nil && t != nil {
		gi, ki, ui := -1, -1, -1
		for i, col := range t.Columns {
			switch col {
			case "grain":
				gi = i
			case "key":
				ki = i
			case "unit":
				ui = i
			}
		}
		for _, row := range t.Rows {
			if row[gi] == nil {
				k, _ := row[ki].(string)
				u, _ := row[ui].(string)
				row[gi] = catalogGrain(k, u)
			}
		}
	}
	s.reply(w, r, map[string]any{"metrics": t}, err)
}
