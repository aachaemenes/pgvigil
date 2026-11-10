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
// top digests' text. GetResourceMetrics cuts every element at 500 bytes, so a digest at the cut gets the whole text
// of one of its statements from GetDimensionKeyDetails (group db.sql: the API serves the whole text by the db.sql.id,
// read in the same call with its db.sql.tokenized_id; db.sql_tokenized has no details group). The text rides the
// rows' query (the digest) and statement (the whole text) keys, so the instance's query_text policy applies to both
// before the import. PI off: one state row saying so, nothing else (the Load tab shows it). Read only:
// pi:GetResourceMetrics, pi:GetDimensionKeyDetails (one call per cut digest, the answer kept for the process) and
// rds:DescribeDBInstances / DescribeDBClusters.
type piCollector struct{}

func init() { Register(piCollector{}) }

const (
	piHours    = 3     // the complete hours read each run: two missed runs lose nothing (an hour read again replaces itself)
	piTop      = 25    // the GroupBy limit: the top 25 waits and digests (the API's maximum)
	piTextCut  = 500   // bytes: GetResourceMetrics returns at most this much of an element
	piMaxCalls = 25    // GetDimensionKeyDetails calls per run at most (one per cut digest)
	piService  = "RDS" // ServiceType
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

func (c piCollector) RunInstance(ctx context.Context, conn *pgx.Conn, info platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
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
	return piRows(ctx, api, id, time.Now())
}

// piText keeps the whole texts fetched, per resource and digest, for the life of the process (a digest's text does
// not change; only an AVAILABLE answer is kept, so a PROCESSING one is asked again next hour).
var (
	piTextMu sync.Mutex
	piText   = map[string]piWhole{}
)

type piWhole struct{ text, status, sqlID string }

// piRows returns {kind:'state'} always, and with PI on the {kind:'load'} rows (at, group total|wait|sql, key,
// wait_type, value) and the {kind:'sql'} rows (tokenized_id, db_id, query, statement, text_status, sql_id).
func piRows(ctx context.Context, api piAPI, id string, now time.Time) ([]Row, error) {
	d, err := platform.DescribeAWSInstance(ctx, api, id, now)
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
	start := end.Add(-piHours * time.Hour)
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

	// the digests, heaviest first; a digest at the cut gets its whole text (at most piMaxCalls calls a run)
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
		switch {
		case len(g.text) < piTextCut:
			r["text_status"] = "whole"
		case stmtOf[g.id].sqlID == "":
			r["text_status"] = "no statement id"
		default:
			sqlID := stmtOf[g.id].sqlID
			ck := d.ResourceID + "|" + g.id
			piTextMu.Lock()
			w, ok := piText[ck]
			piTextMu.Unlock()
			if !ok && calls < piMaxCalls {
				calls++
				w, err = piWholeText(ctx, api, d.ResourceID, sqlID)
				if err != nil {
					rows = append(rows, Row{"kind": "collector_error", "source": "pi", "message": err.Error()})
					r["text_status"] = "error"
					rows = append(rows, r)
					continue
				}
				if w.status == "AVAILABLE" {
					piTextMu.Lock()
					piText[ck] = w
					piTextMu.Unlock()
				}
			}
			if w.status == "" {
				r["text_status"] = "not asked (call cap)"
				break
			}
			r["text_status"], r["sql_id"] = w.status, sqlID
			if w.text != "" {
				r["statement"] = w.text
			}
		}
		rows = append(rows, r)
	}
	state["hours_read"] = len(total)
	return append([]Row{state}, rows...), nil
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
