package collect

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs"
	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/logparse"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// logsCollector reads the server log for slow statements, lock waits, deadlocks and failed
// logins. RDS and Aurora: the postgresql log exported to CloudWatch Logs (the instance's aws:
// block names the cluster or instance). Each run reads from the stored cursor minus an overlap
// (CloudWatch can deliver late), so a re-read event is dropped by the repository's event key.
type logsCollector struct{}

func init() { Register(logsCollector{}) }

const (
	logsOverlap   = 5 * time.Minute // re-read window behind the cursor
	logsFirstRead = time.Hour       // how far back the very first read goes
	logsMaxEvents = 20000           // per run; the rest is read on the next run
)

func (logsCollector) Name() string                   { return "logs" }
func (logsCollector) DefaultInterval() time.Duration { return time.Minute }
func (logsCollector) Applies(info platform.Info) (bool, string) {
	if info.Kind == platform.Aurora || info.Kind == platform.RDS {
		return true, ""
	}
	return false, "the log reader covers RDS and Aurora (CloudWatch Logs) so far"
}

func (logsCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("logs needs the instance config: %w", ErrSkip)
}

// Configured: the reader needs an aws: block naming the cluster, the instance or the log group.
func (logsCollector) Configured(in config.Instance) (bool, string) {
	if in.AWS == nil || in.AWS.PostgresLogGroup() == "" {
		return false, "no aws: block with cluster or db_instance in the config"
	}
	return true, ""
}

// cwEvent is one CloudWatch log event, the part the reader uses.
type cwEvent struct {
	Stream  string
	Time    time.Time
	Message string
}

// logFetcher reads events of a log group from a start time; the CloudWatch client in production,
// a recorded set in tests.
type logFetcher func(ctx context.Context, group string, from time.Time, limit int) ([]cwEvent, error)

// fetchers keeps one CloudWatch client per profile and region across runs.
var (
	fetchersMu sync.Mutex
	fetchers   = map[string]logFetcher{}
)

func fetcherFor(ctx context.Context, a config.AWS) (logFetcher, error) {
	k := a.Profile + "|" + a.Region
	fetchersMu.Lock()
	defer fetchersMu.Unlock()
	if f, ok := fetchers[k]; ok {
		return f, nil
	}
	f, err := newFetcher(ctx, a)
	if err == nil {
		fetchers[k] = f
	}
	return f, err
}

// loadAWS resolves the SDK configuration for an instance's AWS door: the region and profile of the
// aws: block over the SDK's usual chain (environment, shared config incl. an `aws login` session, a role).
func loadAWS(ctx context.Context, a config.AWS) (aws.Config, error) {
	opts := []func(*awsconfig.LoadOptions) error{}
	if a.Region != "" {
		opts = append(opts, awsconfig.WithRegion(a.Region))
	}
	if a.Profile != "" {
		opts = append(opts, awsconfig.WithSharedConfigProfile(a.Profile))
	}
	cfg, err := awsconfig.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		return aws.Config{}, fmt.Errorf("aws config: %w", err)
	}
	return cfg, nil
}

var newFetcher = func(ctx context.Context, a config.AWS) (logFetcher, error) {
	cfg, err := loadAWS(ctx, a)
	if err != nil {
		return nil, err
	}
	cl := cloudwatchlogs.NewFromConfig(cfg)
	return func(ctx context.Context, group string, from time.Time, limit int) ([]cwEvent, error) {
		var out []cwEvent
		p := cloudwatchlogs.NewFilterLogEventsPaginator(cl, &cloudwatchlogs.FilterLogEventsInput{
			LogGroupName: aws.String(group),
			StartTime:    aws.Int64(from.UnixMilli()),
		})
		for p.HasMorePages() && len(out) < limit {
			page, err := p.NextPage(ctx)
			if err != nil {
				return nil, fmt.Errorf("FilterLogEvents %s: %w", group, err)
			}
			for _, e := range page.Events {
				out = append(out, cwEvent{Stream: aws.ToString(e.LogStreamName), Time: time.UnixMilli(aws.ToInt64(e.Timestamp)), Message: aws.ToString(e.Message)})
			}
		}
		return out, nil
	}, nil
}

func (logsCollector) RunInstance(ctx context.Context, conn *pgx.Conn, _ platform.Info, in config.Instance, cursor CursorFunc) ([]Row, error) {
	if in.AWS == nil || in.AWS.PostgresLogGroup() == "" {
		return nil, fmt.Errorf("no aws: block with cluster or db_instance in the config: %w", ErrSkip)
	}
	group := in.AWS.PostgresLogGroup()
	source := "cloudwatch:" + group
	from := time.Now().Add(-logsFirstRead)
	if t, ok, err := cursor(ctx, source); err != nil {
		return nil, err
	} else if ok {
		from = t.Add(-logsOverlap)
	}
	loc := time.UTC
	var tz string
	if err := conn.QueryRow(ctx, "SELECT current_setting('log_timezone')").Scan(&tz); err == nil {
		if l, err := time.LoadLocation(tz); err == nil {
			loc = l
		}
	}
	fetch, err := fetcherFor(ctx, *in.AWS)
	if err != nil {
		return nil, err
	}
	evs, err := fetch(ctx, group, from, logsMaxEvents)
	if err != nil {
		return nil, err
	}
	return logRows(evs, source, from, loc, len(evs) >= logsMaxEvents), nil
}

// logRows parses the events stream by stream (an entry's lines stay together) and returns
// the event rows plus one cursor row. The cursor is the earliest of the streams' latest events,
// so a stream that delivers behind the others is re-read from there (within the overlap). A full
// batch (the limit reached) puts the cursor one overlap past its last event: the next run then
// starts at that event instead of re-reading the same window for ever. Lines delivered later
// than the overlap behind the cursor are not read (a stated limit).
func logRows(evs []cwEvent, source string, from time.Time, loc *time.Location, full bool) []Row {
	byStream := map[string][]cwEvent{}
	latest := map[string]time.Time{}
	var last time.Time
	for _, e := range evs {
		byStream[e.Stream] = append(byStream[e.Stream], e)
		if e.Time.After(latest[e.Stream]) {
			latest[e.Stream] = e.Time
		}
		if e.Time.After(last) {
			last = e.Time
		}
	}
	readTo := from
	if full {
		readTo = last.Add(logsOverlap)
	} else {
		first := true
		for _, t := range latest {
			if first || t.Before(readTo) {
				readTo, first = t, false
			}
		}
		if readTo.Before(from) {
			readTo = from
		}
	}
	streams := make([]string, 0, len(byStream))
	for s := range byStream {
		streams = append(streams, s)
	}
	sort.Strings(streams)
	var rows []Row
	for _, s := range streams {
		list := byStream[s]
		sort.SliceStable(list, func(i, j int) bool { return list[i].Time.Before(list[j].Time) })
		var b strings.Builder
		for _, e := range list {
			b.WriteString(strings.TrimRight(e.Message, "\n"))
			b.WriteByte('\n')
		}
		parsed, _ := logparse.ParseIn(strings.NewReader(b.String()), loc)
		for _, p := range parsed {
			sum := md5.Sum([]byte(string(p.Kind) + "\x00" + s + "\x00" + p.Key))
			rows = append(rows, Row{
				"kind": "event", "kind_of": string(p.Kind), "at": p.At.UTC(), "pid": p.PID, "client": p.Client,
				"usename": p.User, "datname": p.Database, "duration_ms": nilIfZero(p.DurationMS),
				"statement": nilIfEmpty(maskText(p.Statement)), "detail": nilIfEmpty(maskText(p.Detail)),
				"source": source + ":" + s, "event_key": hex.EncodeToString(sum[:]),
			})
		}
	}
	rows = append(rows, Row{"kind": "cursor", "source": source, "read_to": readTo.UTC()})
	return rows
}

var (
	maskPasswordRE = regexp.MustCompile(`(?i)((PASSWORD|IDENTIFIED\s+BY)\s+)('(?:[^']|'')*'|E'(?:[^']|'')*'|\$[0-9]+)`)
	maskConnRE     = regexp.MustCompile(`(?i)(password|passfile|sslkey|sslpassword|pwd)=\S+`)
)

// maskText applies maskSQL's two rules to text read from a log, then the statements text cap.
func maskText(s string) string {
	s = maskPasswordRE.ReplaceAllString(s, "${1}'<masked>'")
	s = maskConnRE.ReplaceAllString(s, "${1}=<masked>")
	if len(s) > statementsTextMax {
		s = strings.ToValidUTF8(s[:statementsTextMax], "")
	}
	return s
}

func nilIfZero(f float64) any {
	if f == 0 {
		return nil
	}
	return f
}

func nilIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}
