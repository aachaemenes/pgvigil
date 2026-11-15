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

// ---- running one composed panel (VIEWS slice C, the server half) ------------------------------------------------------
//   POST /api/compose/run {panel, scope, from, to, database} -> {rows, metric, unit, grain, read, from, to, cut,
//                                                              bucket_secs, utc_days}
// The dashboard page posts each composed panel (and the composer its live preview); serve compiles it (compose.go) and
// runs its one statement. At most composeSlots panels read at once (2 of serve's 8 connections), so dashboards and
// previews never hold every connection; a panel that waits past composeWait is told so in words, and one that runs
// past serve's 15 s statement timeout is told what to narrow. A request the client drops (a preview superseded by the
// next change) cancels its statement. A read, so the UI login's reads rule applies; the X-Pgvigil header is required
// because the body is POSTed.                                                                     -> Server.ComposeRun

const (
	composeSlotsN  = 2
	composeWait    = 10 * time.Second
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

// catalogGrain is metric_catalog.grain's rule (scripts/views-join-lines.sql), for a repository whose catalog has no
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
	// the metric: its catalog row (its grain from the catalog's column once the join lines are in, else the same rule)
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
	c, err := compilePanel(in.Panel, m, in.Scope, in.From, in.To, in.Database, time.Now())
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	select {
	case composeSlots <- struct{}{}:
		defer func() { <-composeSlots }()
	case <-time.After(composeWait):
		writeErr(w, http.StatusServiceUnavailable, fmt.Errorf("%d panel reads are running and this one waited %s: it runs on the next refresh", composeSlotsN, composeWait))
		return
	case <-r.Context().Done():
		return
	}
	t, err := s.query(r.Context(), c.SQL, c.Args...)
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
	s.reply(w, r, map[string]any{"rows": t, "metric": m.Key, "unit": m.Unit, "grain": m.Grain, "read": c.Read,
		"from": c.From, "to": c.To, "cut": c.Cut, "bucket_secs": c.BucketSecs, "utc_days": c.UTCDays}, nil)
}
