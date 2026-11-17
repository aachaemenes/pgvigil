package web

// GET /api/pooler/trend?instance=<id>&from=&to= - the pooler's rates over time (parity set 2, the sweep's L47: pgwatch's
// PgBouncer TPS, QPS, average query time, pool wait and traffic), from the 'stats' rows pooler_sample already holds
// (SHOW STATS per database, summed per read). scripts/proof-pmrows.sh pins the answer:
//   tps = sum(xact_rate), qps = sum(query_rate), avg_query_ms = sum(avg_query_us x query_rate) / sum(query_rate) / 1000,
//   avg_wait_ms the same weighted by xact_rate (null when the weight is 0), recv_bps / sent_bps = sum(avg_recv) /
//   sum(avg_sent) - SHOW STATS' bytes per second, stored from 0363 (task 4); null on a read before it

import (
	"context"
	"fmt"
	"net/http"
	"time"
)

const sqlPoolerTrend = `
SELECT snapshot_at,
       sum(xact_rate)::float8 AS tps,
       sum(query_rate)::float8 AS qps,
       sum(avg_query_us::float8 * query_rate) / nullif(sum(query_rate), 0) / 1000 AS avg_query_ms,
       sum(avg_wait_us::float8 * xact_rate) / nullif(sum(xact_rate), 0) / 1000 AS avg_wait_ms,
       sum(avg_recv)::float8 AS recv_bps,
       sum(avg_sent)::float8 AS sent_bps
  FROM pgvigil.pooler_sample
 WHERE instance_id = $1 AND kind = 'stats' AND snapshot_at >= $2 AND snapshot_at < $3
 GROUP BY snapshot_at
 ORDER BY snapshot_at`

type poolerTrendPoint struct {
	At         time.Time `json:"at"`
	TPS        *float64  `json:"tps"`
	QPS        *float64  `json:"qps"`
	AvgQueryMS *float64  `json:"avg_query_ms"`
	AvgWaitMS  *float64  `json:"avg_wait_ms"`
	RecvBPS    *float64  `json:"recv_bps"`
	SentBPS    *float64  `json:"sent_bps"`
}

// PoolerTrend answers GET /api/pooler/trend.
func (s *Server) PoolerTrend(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	v, err := s.poolerTrend(r.Context(), id, from, to)
	s.reply(w, r, v, err)
}

func (s *Server) poolerTrend(ctx context.Context, id int, from, to time.Time) (map[string]any, error) {
	rows, err := s.pool.Query(ctx, sqlPoolerTrend, id, from, to)
	if err != nil {
		return nil, fmt.Errorf("pooler trend: %w", err)
	}
	defer rows.Close()
	series := []poolerTrendPoint{}
	for rows.Next() {
		var p poolerTrendPoint
		if err := rows.Scan(&p.At, &p.TPS, &p.QPS, &p.AvgQueryMS, &p.AvgWaitMS, &p.RecvBPS, &p.SentBPS); err != nil {
			return nil, fmt.Errorf("pooler trend: %w", err)
		}
		series = append(series, p)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("pooler trend: %w", err)
	}
	return map[string]any{"series": series}, nil
}
