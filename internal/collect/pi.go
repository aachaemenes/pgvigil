package collect

import (
	"context"
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/pi"
	pitypes "github.com/aws/aws-sdk-go-v2/service/pi/types"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// piCollector keeps Performance Insights past its seven days: once an hour, on an RDS or Aurora DB instance with PI
// on (DescribeDBInstances PerformanceInsightsEnabled, read once an hour), the DB load of the last complete hours
// (db.load.avg, one point per hour) in total, by wait event and by SQL digest (db.sql_tokenized, the top 25), and the
// top digests' text, from the last stored hour (the pi cursor in pgvigil.log_cursor, one overlap behind it) up to the
// last complete hour, capped at PI's own retention: the first read takes PI's whole window, a collector down for
// hours loses nothing. GetResourceMetrics cuts every element at 500 bytes, so a digest at the cut gets the whole text
// of its heaviest statement from GetDimensionKeyDetails (group db.sql: the API serves the whole text by the db.sql.id;
// the heaviest db.sql.id of the digest comes from the same call's db.sql group, or, when none of the digest's
// statements is in its top 25, from a call filtered on the digest; db.sql_tokenized has no details group). The text rides the
// rows' query (the digest) and statement (the whole text) keys, so the instance's query_text policy applies to both
// before the import. PI off: one state row saying so, nothing else (the Load tab shows it). Read only:
// pi:GetResourceMetrics, pi:GetDimensionKeyDetails (one call per cut digest, the answer kept for the process) and
// rds:DescribeDBInstances / DescribeDBClusters.
type piCollector struct{}

func init() { Register(piCollector{}) }

const (
	piOverlap  = time.Hour // re-read this far behind the stored cursor (the newest stored hour is read again)
	piMaxDays  = 7         // the hours read when PI's retention is unknown: its free tier
	piTop      = 25        // the GroupBy limit: the top 25 waits and digests (the API's maximum)
	piTextCut  = 500       // bytes: GetResourceMetrics returns at most this much of an element
	piMaxCalls = 25        // GetDimensionKeyDetails calls per run at most (one per cut digest)
	piService  = "RDS"     // ServiceType
)

func (piCollector) Name() string                   { return "pi" }
func (piCollector) DefaultInterval() time.Duration { return time.Hour }

func (piCollector) Applies(info platform.Info) (bool, string) {
	if info.Kind != platform.RDS && info.Kind != platform.Aurora {
		return false, "Performance Insights is read for RDS and Aurora only"
	}
	return true, ""
}

// Configured: the collection runs only on an instance with an aws: block.
func (piCollector) Configured(in config.Instance) (bool, string) {
	if in.AWS == nil {
		return false, "no aws: block in the config"
	}
	return true, ""
}

func (piCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("pi needs the instance config: %w", ErrSkip)
}

// piAPI is the slice of the PI and RDS clients the collector calls; a recorded set in a test.
type piAPI interface {
	GetResourceMetrics(context.Context, *pi.GetResourceMetricsInput, ...func(*pi.Options)) (*pi.GetResourceMetricsOutput, error)
	GetDimensionKeyDetails(context.Context, *pi.GetDimensionKeyDetailsInput, ...func(*pi.Options)) (*pi.GetDimensionKeyDetailsOutput, error)
	platform.AWSDescriber
}

type awsPI struct {
	*rds.Client
	pc *pi.Client
}

func (c awsPI) GetResourceMetrics(ctx context.Context, in *pi.GetResourceMetricsInput, opts ...func(*pi.Options)) (*pi.GetResourceMetricsOutput, error) {
	return c.pc.GetResourceMetrics(ctx, in, opts...)
}

func (c awsPI) GetDimensionKeyDetails(ctx context.Context, in *pi.GetDimensionKeyDetailsInput, opts ...func(*pi.Options)) (*pi.GetDimensionKeyDetailsOutput, error) {
	return c.pc.GetDimensionKeyDetails(ctx, in, opts...)
}

var (
	piClientsMu sync.Mutex
	piClients   = map[string]piAPI{}
)

var newPIAPI = func(ctx context.Context, a config.AWS) (piAPI, error) {
	cfg, err := loadAWS(ctx, a)
	if err != nil {
		return nil, err
	}
	return awsPI{Client: rds.NewFromConfig(cfg), pc: pi.NewFromConfig(cfg)}, nil
}

func piClientFor(ctx context.Context, a config.AWS) (piAPI, error) {
	k := a.Profile + "|" + a.Region
	piClientsMu.Lock()
	defer piClientsMu.Unlock()
	if c, ok := piClients[k]; ok {
		return c, nil
	}
	c, err := newPIAPI(ctx, a)
	if err == nil {
		piClients[k] = c
	}
	return c, err
}

func (c piCollector) RunInstance(ctx context.Context, conn *pgx.Conn, info platform.Info, in config.Instance, cursor CursorFunc) ([]Row, error) {
	if ok, why := c.Configured(in); !ok {
		return nil, fmt.Errorf("%s: %w", why, ErrSkip)
	}
	if ok, why := c.Applies(info); !ok {
		return nil, fmt.Errorf("%s: %w", why, ErrSkip)
	}
	id, err := hostAWSInstanceID(ctx, conn, info, *in.AWS)
	if err != nil {
		return nil, err
	}
	api, err := piClientFor(ctx, *in.AWS)
	if err != nil {
		return nil, err
	}
	var since time.Time
	if cursor != nil {
		t, ok, err := cursor(ctx, piCursorSource)
		if err != nil {
			return nil, err
		}
		if ok {
			since = t
		}
	}
	// under the none policy every text is dropped before the import: the calls that fetch it are not made
	return piRows(ctx, api, in.AWS.Profile+"|"+in.AWS.Region, id, time.Now(), piOpts{since: since, wantText: in.QueryText != "none"})
}

// piCursorSource is the log_cursor source the pi collection keeps its last complete hour under.
const piCursorSource = "pi"

// piOpts: since is the stored cursor (zero: never read), wantText whether the whole-text calls are worth making.
type piOpts struct {
	since    time.Time
	wantText bool
}

// piText keeps the whole texts fetched, per resource and digest, for the life of the process (a digest's text does
// not change; only an AVAILABLE answer is kept, so a PROCESSING one is asked again next hour), at most piTextKeep
// of them (the map starts over past it: the repository keeps every text the import stored).
var (
	piTextMu sync.Mutex
	piText   = map[string]piWhole{}
)

type piWhole struct{ text, status, sqlID string }

const piTextKeep = 2000

// piRows returns {kind:'state'} always, and with PI on the {kind:'load'} rows (at, group total|wait|sql, key,
// wait_type, value), the {kind:'sql'} rows (tokenized_id, db_id, query, statement, text_status, sql_id) and one
// {kind:'cursor', source:'pi', read_to} row (the end of the hours read).
func piRows(ctx context.Context, api piAPI, awsKey, id string, now time.Time, o piOpts) ([]Row, error) {
	d, err := platform.DescribeAWSInstance(ctx, api, awsKey, id, now)
	if err != nil {
		return nil, err
	}
	state := Row{"kind": "state", "db_instance": id, "resource_id": nilIfEmpty(d.ResourceID), "enabled": d.PIEnabled}
	if d.PIRetention > 0 {
		state["retention_days"] = d.PIRetention
	}
	if !d.PIEnabled {
		state["note"] = fmt.Sprintf("Performance Insights is off on %s (DescribeDBInstances PerformanceInsightsEnabled false): no DB load is read", id)
		return []Row{state}, nil
	}
	if d.ResourceID == "" {
		return nil, fmt.Errorf("DescribeDBInstances %s: no DbiResourceId", id)
	}
	end := now.UTC().Truncate(time.Hour)
	days := d.PIRetention
	if days <= 0 {
		days = piMaxDays
	}
	start := end.Add(-time.Duration(days) * 24 * time.Hour) // PI refuses a start before its retention
	if s := o.since.Add(-piOverlap); !o.since.IsZero() && s.After(start) {
		start = s
	}
	if !start.Before(end) { // the last complete hour is stored already
		state["hours_read"] = 0
		return []Row{state}, nil
	}
	in := &pi.GetResourceMetricsInput{
		ServiceType: pitypes.ServiceType(piService), Identifier: aws.String(d.ResourceID),
		StartTime: aws.Time(start), EndTime: aws.Time(end), PeriodInSeconds: aws.Int32(3600),
		PeriodAlignment: pitypes.PeriodAlignmentStartTime,
		MetricQueries: []pitypes.MetricQuery{
			{Metric: aws.String("db.load.avg"), GroupBy: &pitypes.DimensionGroup{Group: aws.String("db.wait_event"),
				Dimensions: []string{"db.wait_event.name", "db.wait_event.type"}, Limit: aws.Int32(piTop)}},
			{Metric: aws.String("db.load.avg"), GroupBy: &pitypes.DimensionGroup{Group: aws.String("db.sql_tokenized"),
				Dimensions: []string{"db.sql_tokenized.id", "db.sql_tokenized.db_id", "db.sql_tokenized.statement"}, Limit: aws.Int32(piTop)}},
			{Metric: aws.String("db.load.avg"), GroupBy: &pitypes.DimensionGroup{Group: aws.String("db.sql"),
				Dimensions: []string{"db.sql.id", "db.sql.tokenized_id"}, Limit: aws.Int32(piTop)}},
		},
	}
	type digest struct {
		id, dbID, text string
		load           float64
	}
	var rows []Row
	total := map[time.Time]bool{}
	digests := map[string]*digest{}
	stmtOf := map[string]struct {
		sqlID string
		load  float64
	}{} // a digest's heaviest db.sql.id
	sum := func(dp []pitypes.DataPoint) float64 {
		var s float64
		for _, p := range dp {
			if p.Value != nil {
				s += *p.Value
			}
		}
		return s
	}
	for {
		res, err := api.GetResourceMetrics(ctx, in)
		if err != nil {
			return nil, fmt.Errorf("pi:GetResourceMetrics %s (%s): %w", id, d.ResourceID, err)
		}
		for _, m := range res.MetricList {
			if m.Key == nil {
				continue
			}
			dim := m.Key.Dimensions
			group, key, waitType := "total", "", ""
			switch {
			case dim["db.wait_event.name"] != "":
				group, key, waitType = "wait", dim["db.wait_event.name"], dim["db.wait_event.type"]
			case dim["db.sql_tokenized.id"] != "":
				group, key = "sql", dim["db.sql_tokenized.id"]
				g := digests[key]
				if g == nil {
					g = &digest{id: key}
					digests[key] = g
				}
				g.dbID, g.text = dim["db.sql_tokenized.db_id"], dim["db.sql_tokenized.statement"]
				g.load += sum(m.DataPoints)
			case dim["db.sql.id"] != "":
				// not stored as load: only the bridge from a digest to a statement whose whole text can be asked for
				t, l := dim["db.sql.tokenized_id"], sum(m.DataPoints)
				if t != "" && (stmtOf[t].sqlID == "" || l > stmtOf[t].load) {
					stmtOf[t] = struct {
						sqlID string
						load  float64
					}{dim["db.sql.id"], l}
				}
				continue
			case len(dim) > 0:
				continue // a dimension this collector did not ask for
			}
			for _, p := range m.DataPoints {
				if p.Timestamp == nil || p.Value == nil {
					continue
				}
				at := p.Timestamp.UTC()
				if group == "total" { // every grouped query returns the total series too: kept once
					if total[at] {
						continue
					}
					total[at] = true
				}
				r := Row{"kind": "load", "at": at, "group": group, "key": key, "value": *p.Value}
				if waitType != "" {
					r["wait_type"] = waitType
				}
				rows = append(rows, r)
			}
		}
		if aws.ToString(res.NextToken) == "" {
			break
		}
		in.NextToken = res.NextToken
	}

	// the digests, heaviest first; a digest at the cut gets its whole text (at most piMaxCalls calls a run, the
	// filtered statement lookup and the details call each counted)
	list := make([]*digest, 0, len(digests))
	for _, g := range digests {
		list = append(list, g)
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].load != list[j].load {
			return list[i].load > list[j].load
		}
		return list[i].id < list[j].id
	})
	calls := 0
	for _, g := range list {
		r := Row{"kind": "sql", "tokenized_id": g.id, "db_id": nilIfEmpty(g.dbID), "query": nilIfEmpty(g.text)}
		if len(g.text) < piTextCut-3 { // under the cut (3 bytes of slack: a cut that lands inside a multi-byte character)
			r["text_status"] = "whole"
			rows = append(rows, r)
			continue
		}
		ck := d.ResourceID + "|" + g.id
		piTextMu.Lock()
		w, ok := piText[ck]
		piTextMu.Unlock()
		if !ok && !o.wantText {
			rows = append(rows, withStatus(r, "not asked (query_text none)"))
			continue
		}
		if !ok {
			sqlID := stmtOf[g.id].sqlID
			if sqlID == "" && calls < piMaxCalls {
				// none of the digest's statements is in the top 25 statements (many light literal variants): ask for
				// the heaviest statement of exactly this digest
				calls++
				if sqlID, err = piStatementOf(ctx, api, d.ResourceID, g.id, start, end); err != nil {
					rows = append(rows, Row{"kind": "collector_error", "source": "pi", "message": err.Error()}, withStatus(r, "error"))
					continue
				}
				if sqlID == "" {
					rows = append(rows, withStatus(r, "no statement id"))
					continue
				}
			}
			if sqlID == "" || calls >= piMaxCalls {
				rows = append(rows, withStatus(r, "not asked (call cap)"))
				continue
			}
			calls++
			if w, err = piWholeText(ctx, api, d.ResourceID, sqlID); err != nil {
				rows = append(rows, Row{"kind": "collector_error", "source": "pi", "message": err.Error()}, withStatus(r, "error"))
				continue
			}
			if w.status == "AVAILABLE" {
				piTextMu.Lock()
				if len(piText) >= piTextKeep { // a bound on the process's memory: the repository keeps every text anyway
					piText = map[string]piWhole{}
				}
				piText[ck] = w
				piTextMu.Unlock()
			}
		}
		r["text_status"], r["sql_id"] = w.status, w.sqlID
		if w.text != "" {
			r["statement"] = w.text
		}
		rows = append(rows, r)
	}
	state["hours_read"] = len(total)
	rows = append(rows, Row{"kind": "cursor", "source": piCursorSource, "read_to": end})
	return append([]Row{state}, rows...), nil
}

func withStatus(r Row, status string) Row { r["text_status"] = status; return r }

// piStatementOf finds the heaviest statement (db.sql.id) of one digest over the window: GetResourceMetrics grouped by
// db.sql, filtered on the digest (a filter on a dimension of the grouped group), limit 1.
func piStatementOf(ctx context.Context, api piAPI, resourceID, tokenizedID string, start, end time.Time) (string, error) {
	res, err := api.GetResourceMetrics(ctx, &pi.GetResourceMetricsInput{
		ServiceType: pitypes.ServiceType(piService), Identifier: aws.String(resourceID),
		StartTime: aws.Time(start), EndTime: aws.Time(end), PeriodInSeconds: aws.Int32(3600),
		PeriodAlignment: pitypes.PeriodAlignmentStartTime,
		MetricQueries: []pitypes.MetricQuery{{Metric: aws.String("db.load.avg"),
			GroupBy: &pitypes.DimensionGroup{Group: aws.String("db.sql"), Dimensions: []string{"db.sql.id", "db.sql.tokenized_id"}, Limit: aws.Int32(1)},
			Filter:  map[string]string{"db.sql.tokenized_id": tokenizedID}}},
	})
	if err != nil {
		return "", fmt.Errorf("pi:GetResourceMetrics db.sql of digest %s: %w", tokenizedID, err)
	}
	for _, m := range res.MetricList {
		if m.Key != nil && m.Key.Dimensions["db.sql.id"] != "" && m.Key.Dimensions["db.sql.tokenized_id"] == tokenizedID {
			return m.Key.Dimensions["db.sql.id"], nil
		}
	}
	return "", nil
}

// piWholeText asks GetDimensionKeyDetails for the whole text of one statement (group db.sql, its db.sql.id).
func piWholeText(ctx context.Context, api piAPI, resourceID, sqlID string) (piWhole, error) {
	res, err := api.GetDimensionKeyDetails(ctx, &pi.GetDimensionKeyDetailsInput{
		ServiceType: pitypes.ServiceType(piService), Identifier: aws.String(resourceID),
		Group: aws.String("db.sql"), GroupIdentifier: aws.String(sqlID), RequestedDimensions: []string{"statement"},
	})
	if err != nil {
		return piWhole{}, fmt.Errorf("pi:GetDimensionKeyDetails db.sql %s: %w", sqlID, err)
	}
	for _, x := range res.Dimensions {
		if dn := aws.ToString(x.Dimension); dn == "db.sql.statement" || dn == "statement" {
			return piWhole{text: aws.ToString(x.Value), status: string(x.Status), sqlID: sqlID}, nil
		}
	}
	return piWhole{status: "UNAVAILABLE", sqlID: sqlID}, nil
}
