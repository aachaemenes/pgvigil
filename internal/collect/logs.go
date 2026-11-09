package collect

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"sort"
	"strconv"
	"strings"
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

// cwEvent is one CloudWatch log event, the part the reader uses.
type cwEvent struct {
	Stream  string
	Time    time.Time
	Message string
}

// logFetcher reads events of a log group from a start time; the CloudWatch client in production,
// a recorded set in tests.
type logFetcher func(ctx context.Context, group string, from time.Time, limit int) ([]cwEvent, error)

var newFetcher = func(ctx context.Context, a config.AWS) (logFetcher, error) {
	opts := []func(*awsconfig.LoadOptions) error{}
	if a.Region != "" {
		opts = append(opts, awsconfig.WithRegion(a.Region))
	}
	if a.Profile != "" {
		opts = append(opts, awsconfig.WithSharedConfigProfile(a.Profile))
	}
	cfg, err := awsconfig.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		return nil, fmt.Errorf("aws config: %w", err)
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

func (logsCollector) RunInstance(ctx context.Context, _ *pgx.Conn, _ platform.Info, in config.Instance, cursor CursorFunc) ([]Row, error) {
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
	fetch, err := newFetcher(ctx, *in.AWS)
	if err != nil {
		return nil, err
	}
	evs, err := fetch(ctx, group, from, logsMaxEvents)
	if err != nil {
		return nil, err
	}
	return logRows(evs, source, from), nil
}

// logRows parses the events stream by stream (an entry's lines stay together) and returns
// the event rows plus one cursor row. With a full batch (logsMaxEvents) the cursor stops at the
// last event's time so the next run continues there.
func logRows(evs []cwEvent, source string, from time.Time) []Row {
	byStream := map[string][]cwEvent{}
	readTo := from
	for _, e := range evs {
		byStream[e.Stream] = append(byStream[e.Stream], e)
		if e.Time.After(readTo) {
			readTo = e.Time
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
		parsed, _ := logparse.Parse(strings.NewReader(b.String()))
		for _, p := range parsed {
			sum := md5.Sum([]byte(strings.Join([]string{string(p.Kind), s, strconv.Itoa(p.PID), p.At.UTC().Format(time.RFC3339Nano),
				p.Statement, p.Detail, strconv.FormatFloat(p.DurationMS, 'f', -1, 64)}, "\x00")))
			rows = append(rows, Row{
				"kind": "event", "kind_of": string(p.Kind), "at": p.At.UTC(), "pid": p.PID, "client": p.Client,
				"usename": p.User, "datname": p.Database, "duration_ms": nilIfZero(p.DurationMS),
				"statement": nilIfEmpty(p.Statement), "detail": nilIfEmpty(p.Detail),
				"source": source + ":" + s, "event_key": hex.EncodeToString(sum[:]),
			})
		}
	}
	rows = append(rows, Row{"kind": "cursor", "source": source, "read_to": readTo.UTC()})
	return rows
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
