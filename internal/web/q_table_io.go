package web

// The per-table history of parity set 2's L46 (pgwatch's table details: scans, row changes and the buffer hit over
// time; Most Disk I/O Reads), from task 127's pgvigil.table_activity - the five-minute read of each database's busiest
// tables - which 0363 extended with pg_statio_user_tables' six block counters (the lead 11-17 02:50). No second
// per-table history. scripts/proof-pmrows.sh pins both answers:
//   GET /api/tables/io?instance=<id>&dbid=&relid=&from=&to=  {points: [{at, seq_scan, idx_scan, ins, upd, del, hit_pct}],
//     words: [..]} - per read after the first in the window, each counter's change since the read before it; a counter
//     lower than before (a statistics reset) leaves that point's counts null and the words say 'reset'; hit_pct = 100 x
//     (heap + idx blks_hit change) / (that + heap + idx blks_read change), null when both are 0 or not read (a read
//     before 0363); a table pgvigil.tables lists with no read in the window: no point, and the words say it is outside
//     its database's busiest 100 (the lead 02:50's added check).
//   GET /api/tables/io_top?instance=<id>&from=&to=&top=<n>  {tables: [{table, dbid, relid, blks_read}]} - Most Disk
//     I/O Reads: each table's heap + idx + toast blks_read increases over the window (a reset's drop not counted), the
//     largest first, at most n (default 10, 1 to 100).

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"
)

const sqlTableIO = `
SELECT snapshot_at, seq_scan, idx_scan, n_tup_ins, n_tup_upd, n_tup_del, heap_blks_read, heap_blks_hit, idx_blks_read, idx_blks_hit
  FROM pgvigil.table_activity
 WHERE instance_id = $1 AND dbid = $2 AND relid = $3 AND snapshot_at >= $4 AND snapshot_at < $5
 ORDER BY snapshot_at`

// sqlTableIOTop: the positive steps of each block counter between a table's consecutive reads in the window
const sqlTableIOTop = `
WITH d AS (
  SELECT dbid, relid, schema_name, table_name,
         heap_blks_read - lag(heap_blks_read) OVER w AS dh,
         idx_blks_read - lag(idx_blks_read) OVER w AS di,
         toast_blks_read - lag(toast_blks_read) OVER w AS dt
    FROM pgvigil.table_activity
   WHERE instance_id = $1 AND snapshot_at >= $2 AND snapshot_at < $3
  WINDOW w AS (PARTITION BY dbid, relid ORDER BY snapshot_at)
)
SELECT coalesce(max(t.schema_name || '.' || t.table_name), max(d.schema_name || '.' || d.table_name)) AS name, d.dbid, d.relid,
       sum(CASE WHEN dh > 0 THEN dh ELSE 0 END + CASE WHEN di > 0 THEN di ELSE 0 END + CASE WHEN dt > 0 THEN dt ELSE 0 END)::bigint AS blks_read
  FROM d
  LEFT JOIN pgvigil.tables t ON t.instance_id = $1 AND t.dbid = d.dbid AND t.relid = d.relid
 GROUP BY d.dbid, d.relid
HAVING sum(CASE WHEN dh > 0 THEN dh ELSE 0 END + CASE WHEN di > 0 THEN di ELSE 0 END + CASE WHEN dt > 0 THEN dt ELSE 0 END) > 0
 ORDER BY blks_read DESC, name
 LIMIT $4`

// tableIOQuiet is the words for a table with no read in the window (the lead 11-17 02:50).
const tableIOQuiet = "no read of this table in the window: the table activity read keeps, every 5 minutes, the busiest 100 tables of each database by sequential scans, inserts, updates, deletes and blocks read, and this one was outside its database's busiest 100"

type tableIOPoint struct {
	At     time.Time `json:"at"`
	Seq    *int64    `json:"seq_scan"`
	Idx    *int64    `json:"idx_scan"`
	Ins    *int64    `json:"ins"`
	Upd    *int64    `json:"upd"`
	Del    *int64    `json:"del"`
	HitPct *float64  `json:"hit_pct"`
}

// tableIORead is one stored read: the five counters and the four block counters (nil before 0363)
type tableIORead struct {
	at                                 time.Time
	c                                  [5]*int64 // seq_scan, idx_scan, n_tup_ins, n_tup_upd, n_tup_del
	heapRead, heapHit, idxRead, idxHit *int64
}

// tableIOPoints: each read after the first, its change since the one before; a fall in any counter (a statistics
// reset) leaves the point's counts and hit null and is counted
func tableIOPoints(rs []tableIORead) ([]tableIOPoint, int) {
	pts, resets := []tableIOPoint{}, 0
	fell := func(a, b *int64) bool { return a != nil && b != nil && *b < *a }
	diff := func(a, b *int64) *int64 {
		if a == nil || b == nil {
			return nil
		}
		d := *b - *a
		return &d
	}
	for i := 1; i < len(rs); i++ {
		a, b := rs[i-1], rs[i]
		p := tableIOPoint{At: b.at}
		reset := fell(a.heapRead, b.heapRead) || fell(a.heapHit, b.heapHit) || fell(a.idxRead, b.idxRead) || fell(a.idxHit, b.idxHit)
		for k := range a.c {
			reset = reset || fell(a.c[k], b.c[k])
		}
		if reset {
			resets++
			pts = append(pts, p)
			continue
		}
		p.Seq, p.Idx, p.Ins, p.Upd, p.Del = diff(a.c[0], b.c[0]), diff(a.c[1], b.c[1]), diff(a.c[2], b.c[2]), diff(a.c[3], b.c[3]), diff(a.c[4], b.c[4])
		hr, hh, ir, ih := diff(a.heapRead, b.heapRead), diff(a.heapHit, b.heapHit), diff(a.idxRead, b.idxRead), diff(a.idxHit, b.idxHit)
		if hr != nil && hh != nil {
			hit, rd := *hh, *hr
			if ih != nil && ir != nil {
				hit, rd = hit+*ih, rd+*ir
			}
			if hit+rd > 0 {
				v := 100 * float64(hit) / float64(hit+rd)
				p.HitPct = &v
			}
		}
		pts = append(pts, p)
	}
	return pts, resets
}

// TableIO answers GET /api/tables/io.
func (s *Server) TableIO(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	dbid, err1 := strconv.ParseInt(r.URL.Query().Get("dbid"), 10, 64)
	relid, err2 := strconv.ParseInt(r.URL.Query().Get("relid"), 10, 64)
	if err1 != nil || err2 != nil {
		writeErr(w, http.StatusBadRequest, errors.New("dbid and relid must be numbers"))
		return
	}
	v, err := s.tableIO(r.Context(), id, dbid, relid, from, to)
	s.reply(w, r, v, err)
}

func (s *Server) tableIO(ctx context.Context, id int, dbid, relid int64, from, to time.Time) (map[string]any, error) {
	rows, err := s.pool.Query(ctx, sqlTableIO, id, dbid, relid, from, to)
	if err != nil {
		return nil, fmt.Errorf("table io: %w", err)
	}
	defer rows.Close()
	var rs []tableIORead
	for rows.Next() {
		var x tableIORead
		if err := rows.Scan(&x.at, &x.c[0], &x.c[1], &x.c[2], &x.c[3], &x.c[4], &x.heapRead, &x.heapHit, &x.idxRead, &x.idxHit); err != nil {
			return nil, fmt.Errorf("table io: %w", err)
		}
		rs = append(rs, x)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("table io: %w", err)
	}
	pts, resets := tableIOPoints(rs)
	words := []string{}
	switch {
	case len(rs) == 0:
		var listed bool
		if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pgvigil.tables WHERE instance_id = $1 AND dbid = $2 AND relid = $3)`, id, dbid, relid).Scan(&listed); err != nil {
			return nil, fmt.Errorf("table io: %w", err)
		}
		if listed {
			words = append(words, tableIOQuiet)
		} else {
			words = append(words, "no read of this table in the window")
		}
	case len(rs) == 1:
		words = append(words, "one read of this table in the window: a change needs two")
	}
	if resets > 0 {
		words = append(words, fmt.Sprintf("%d reset(s) of the table's statistics in the window: a counter fell, so those reads' changes are left out", resets))
	}
	for _, x := range rs {
		if x.heapRead == nil {
			words = append(words, "the buffer hit is read from this version on: an older read holds no block counters")
			break
		}
	}
	return map[string]any{"points": pts, "words": words}, nil
}

type tableIOTop struct {
	Table    string `json:"table"`
	DBID     int64  `json:"dbid"`
	RelID    int64  `json:"relid"`
	BlksRead int64  `json:"blks_read"`
}

// TableIOTop answers GET /api/tables/io_top.
func (s *Server) TableIOTop(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := paramsReach(r, true, tablesTopMaxWindow)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	top := 10
	if v := r.URL.Query().Get("top"); v != "" {
		if top, err = strconv.Atoi(v); err != nil || top < 1 || top > 100 {
			writeErr(w, http.StatusBadRequest, errors.New("top must be 1 to 100"))
			return
		}
	}
	rows, err := s.pool.Query(r.Context(), sqlTableIOTop, id, from, to, top)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("table io top: %w", err))
		return
	}
	defer rows.Close()
	out := []tableIOTop{}
	for rows.Next() {
		var x tableIOTop
		if err := rows.Scan(&x.Table, &x.DBID, &x.RelID, &x.BlksRead); err != nil {
			s.reply(w, r, nil, fmt.Errorf("table io top: %w", err))
			return
		}
		out = append(out, x)
	}
	s.reply(w, r, map[string]any{"tables": out}, rows.Err())
}
