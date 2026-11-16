package web

// The instances a remote collector reads (docs/remote-collector.md, migration 0329): a site owns each, its rows arrive
// in bundles, and the hub never connects to it. Every live door - an action, EXPLAIN, the planner check, the index
// advisor, a job action, Community tools, a custom report run on the instance, a histogram, a fragmentation read, a
// plan read by its handle - refuses it in one sentence naming its collector and site, and every page of it says how
// fresh its data is ('as of' the newest bundle's window end).

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/actions"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// remoteDoor is one remote instance as the hub knows it from its newest loaded bundle.
type remoteDoor struct {
	Site, Collector string
	// AsOf: the newest loaded bundle's window end
	AsOf time.Time
	// Every: that bundle's window (the collector's remote.interval)
	Every time.Duration
	// ExpectedEvery: how often the site's bundles arrive (remote_sites: expected_every)
	ExpectedEvery time.Duration
}

// from is the door's words for where the instance is read: 'remote collector <c> of site <s>'.
func (r remoteDoor) from() string { return "remote collector " + r.Collector + " of site " + r.Site }

// remoteWhy is the words every live door says for a remote instance (actions.RemoteOff), or "" for any other.
func (ds *doorSet) remoteWhy(name string) string {
	if r, ok := ds.Remote[name]; ok {
		return actions.RemoteOff(name, r.from())
	}
	return ""
}

// remoteRow is one row of pgvigil.remote_instance_state (migration 0329).
type remoteRow struct {
	Name, Engine string
	Door         remoteDoor
}

// sqlRemoteInstances: every instance a site owns, as of its newest loaded bundle (0329's view, granted to serve's
// reader role)
const sqlRemoteInstances = `SELECT name, engine, site, collector, as_of, coalesce(interval_secs, 0), coalesce(expected_every_secs, 0)
  FROM pgvigil.remote_instance_state ORDER BY name`

// readRemote reads the remote instances; a store before 0329 (no such view) has none.
func readRemote(ctx context.Context, pool *pgxpool.Pool) ([]remoteRow, error) {
	rows, err := pool.Query(ctx, sqlRemoteInstances)
	if err != nil {
		if noRemoteView(err) {
			return nil, nil
		}
		return nil, err
	}
	defer rows.Close()
	var out []remoteRow
	for rows.Next() {
		var r remoteRow
		var asOf *time.Time
		var every, expected int
		if err := rows.Scan(&r.Name, &r.Engine, &r.Door.Site, &r.Door.Collector, &asOf, &every, &expected); err != nil {
			return nil, err
		}
		if asOf != nil {
			r.Door.AsOf = *asOf
		}
		r.Door.Every, r.Door.ExpectedEvery = time.Duration(every)*time.Second, time.Duration(expected)*time.Second
		out = append(out, r)
	}
	return out, rows.Err()
}

// noRemoteView: the store has no remote_instance_state yet (undefined_table: a repository before 0329)
func noRemoteView(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "42P01"
}

// withRemote is a copy of ds with exactly these remote instances: each in Remote and as a door in PG or MS carrying
// its words and no login. A name pgvigil.yaml or Admin > Instances already holds keeps its own door (0329's
// import_remote_ensure refuses such a name; the log says it if one meets here). ds itself is never changed: sets are
// read by requests while the next one is built.
func withRemote(ds *doorSet, rows []remoteRow, log *slog.Logger) *doorSet {
	cp := *ds
	cp.PG, cp.MS, cp.Remote = map[string]actions.Door{}, map[string]mssql.Door{}, map[string]remoteDoor{}
	for k, v := range ds.PG {
		if v.Remote == "" {
			cp.PG[k] = v
		}
	}
	for k, v := range ds.MS {
		if v.Remote == "" {
			cp.MS[k] = v
		}
	}
	for _, r := range rows {
		_, inPG := cp.PG[r.Name]
		_, inMS := cp.MS[r.Name]
		if inPG || inMS {
			if log != nil {
				log.Warn("a remote instance's name is already an instance of this server: its own door stands", "instance", r.Name, "site", r.Door.Site)
			}
			continue
		}
		cp.Remote[r.Name] = r.Door
		if r.Engine == config.EngineSQLServer {
			cp.MS[r.Name] = mssql.Door{Remote: r.Door.from()}
		} else {
			cp.PG[r.Name] = actions.Door{Remote: r.Door.from()}
		}
	}
	return &cp
}

// sameRemote: two reads hold the same instances with the same doors
func sameRemote(a, b []remoteRow) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

var (
	remoteLast sync.Map // *Server -> []remoteRow: the watcher's newest read, applied to every set it stores
	doorStore  sync.Map // *Server -> *sync.Mutex: the inventory's and the remote read's stores, one at a time
)

func (s *Server) doorStoreMu() *sync.Mutex {
	v, _ := doorStore.LoadOrStore(s.self(), &sync.Mutex{})
	return v.(*sync.Mutex)
}

func (s *Server) remoteRows() []remoteRow {
	if v, ok := remoteLast.Load(s.self()); ok {
		return v.([]remoteRow)
	}
	return nil
}

// watchRemote reads the remote instances every 'every' and stores a new set when they changed (a bundle loaded moves
// an instance's as_of; a new instance or site appears). The first read is at once.
func (s *Server) watchRemote(ctx context.Context, log *slog.Logger, every time.Duration) {
	lastErr := ""
	t := time.NewTimer(0)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		t.Reset(every)
		rctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		rows, err := readRemote(rctx, s.pool)
		cancel()
		if err != nil {
			if e := err.Error(); e != lastErr {
				log.Warn("the remote instances could not be read: their doors stay as last read", "err", err)
				lastErr = e
			}
			continue
		}
		lastErr = ""
		if sameRemote(rows, s.remoteRows()) {
			continue
		}
		mu := s.doorStoreMu()
		mu.Lock()
		remoteLast.Store(s.self(), rows)
		s.storeDoors(withRemote(s.doorsNow(), rows, log))
		mu.Unlock()
	}
}
