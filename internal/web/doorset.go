package web

// The doors of one inventory generation (the instances of pgvigil.yaml and, when doors.page_instance_reads is on,
// the instances added in Admin > Instances), swapped whole. A request loads the set ONCE (doorsNow) and hands that
// value down - the community check and run, a custom report's targets, the plans, the index advisor, the actions -
// so one request never mixes two generations and never finds a door gone between two reads of it.
//
// A page instance's door is its read login only: the monitoring login the page stored (config.WriteSecret), resolved
// by this serve. It opens Community tools and custom reports; EXPLAIN, the index advisor and every action stay on
// pgvigil.yaml's instances. It never opens for a sign-in with serve's own identity or a driver option outside the
// page door's lists (config/pagedoor.go), checked on the row for the words and on the resolved string, which holds.
// Serve keeps every open page door's credential in memory while it runs (docs/configuration.md says so).

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/actions"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// doorSet is one generation's doors.
type doorSet struct {
	// Gen is admin_inventory_generation() the set was built from: one number for the repository's whole list (any
	// write of Admin > Instances moves it); 0 = pgvigil.yaml's instances alone
	Gen       int64
	PG        map[string]actions.Door // PostgreSQL: pgvigil.yaml's (with their actions logins) and the open page doors (Page)
	MS        map[string]mssql.Door   // SQL Server: the same
	Gates     map[string]actions.ExplainGate
	QueryText map[string]string // an instance's statement-text policy; DefaultQueryText for one not listed
	DefaultQT string
	Hypo      map[string]bool
	PgJobs    map[string]map[string]bool
	// NoDoor: a page instance with no door here -> the words that say why
	NoDoor    map[string]string
	PageReads bool
}

var doorSets sync.Map // *Server -> *atomic.Pointer[doorSet] (serve's watcher stores it; demo and mcp keep the file's)

// doorsNow is the request's set: the watcher's last one on serve, else pgvigil.yaml's as Open and the Set* calls left
// it. Call it once per request and pass the value down.
func (s *Server) doorsNow() *doorSet {
	if v, ok := doorSets.Load(s); ok {
		if ds := v.(*atomic.Pointer[doorSet]).Load(); ds != nil {
			return ds
		}
	}
	return s.fileDoors()
}

// fileDoors: pgvigil.yaml's doors as the server holds them (the actions door's map, the SQL Server door's, the plans
// configuration, the job allow lists), by reference.
func (s *Server) fileDoors() *doorSet {
	pc := s.plansConfig()
	ds := &doorSet{PG: map[string]actions.Door{}, MS: s.mssqlDoor().doors, Gates: pc.Gates, QueryText: pc.QueryText, DefaultQT: pc.DefaultQueryText,
		Hypo: pc.Hypo, NoDoor: map[string]string{}}
	if s.actions != nil && s.actions.doors != nil {
		ds.PG = s.actions.doors
	}
	if ds.MS == nil {
		ds.MS = map[string]mssql.Door{}
	}
	if v, ok := pgJobAllow.Load(s); ok {
		ds.PgJobs = v.(map[string]map[string]bool)
	}
	return ds
}

func (s *Server) storeDoors(ds *doorSet) {
	v, _ := doorSets.LoadOrStore(s, &atomic.Pointer[doorSet]{})
	v.(*atomic.Pointer[doorSet]).Store(ds)
}

// noDoorWords: the words for an instance neither list holds
func noDoorWords(name string) string {
	return "instance " + name + " has no read login on this server: it is in neither pgvigil.yaml nor Admin > Instances"
}

// readLogin is an instance's read login on this set: its dsn and its door's kind ('file' or 'page'), or why it has
// none. engine is 'sqlserver' or a PostgreSQL one.
func (ds *doorSet) readLogin(engine, name string) (dsn, kind, why string) {
	var monitor string
	var ok, page bool
	if engine == config.EngineSQLServer {
		d, has := ds.MS[name]
		monitor, ok, page = d.Monitor, has, d.Page
	} else {
		d, has := ds.PG[name]
		monitor, ok, page = d.Monitor, has, d.Page
	}
	switch {
	case !ok && ds.NoDoor[name] != "":
		return "", "", ds.NoDoor[name]
	case !ok:
		return "", "", noDoorWords(name)
	case monitor == "" && page:
		return "", "", "instance " + name + ": its credential is not readable on this host (stored by another host's serve, or a file this account cannot read)"
	case monitor == "":
		return "", "", "instance " + name + ": its read login's dsn (env:, file: or dpapi:) resolved to an empty string on this server"
	case page:
		return monitor, "page", ""
	}
	return monitor, "file", ""
}

// fileOnly: the words for EXPLAIN and the index advisor on a page door (they stay on pgvigil.yaml's instances)
func fileOnly(name string) string {
	return "instance " + name + ": EXPLAIN and the index advisor run only on an instance of pgvigil.yaml"
}

// pageDoorsConfig is what serve hands the watcher: pgvigil.yaml's instances (their names win over the page's) and
// the switch.
type pageDoorsConfig struct {
	file      []config.Instance
	queryText string
	reads     bool
}

// pageDoors builds the set of one generation: the file's set copied, each open page door added. prev (the set
// before) lends a page door's resolved string when the generation did not move and it was not empty; an empty one
// is resolved again on each tick.
func pageDoors(file *doorSet, prev *doorSet, c pageDoorsConfig, all []config.Instance, page []config.PageInstance, gen int64) *doorSet {
	ds := &doorSet{Gen: gen, PG: map[string]actions.Door{}, MS: map[string]mssql.Door{}, Gates: file.Gates, QueryText: map[string]string{},
		DefaultQT: file.DefaultQT, Hypo: file.Hypo, PgJobs: file.PgJobs, NoDoor: map[string]string{}, PageReads: c.reads}
	for k, v := range file.PG {
		ds.PG[k] = v
	}
	for k, v := range file.MS {
		ds.MS[k] = v
	}
	for k, v := range file.QueryText {
		ds.QueryText[k] = v
	}
	inFile := map[string]bool{}
	for _, in := range c.file {
		inFile[in.Name] = true
	}
	merged := map[string]config.Instance{}
	for _, in := range all {
		merged[in.Name] = in
	}
	_, skipped := config.Merge(c.file, page, c.queryText)
	left := map[string]string{}
	for _, sk := range skipped {
		if n, why, ok := cutColon(sk); ok {
			left[n] = why
		}
	}
	for _, p := range page {
		name := p.Name
		if inFile[name] {
			continue // pgvigil.yaml's door stands
		}
		in, isMerged := merged[name]
		switch {
		case p.Disabled:
			ds.NoDoor[name] = "instance " + name + " is disabled in Admin > Instances"
			continue
		case !isMerged:
			ds.NoDoor[name] = "instance " + name + " is left out of the list: " + left[name]
			continue
		case !c.reads:
			ds.NoDoor[name] = "instance " + name + ": " + config.PageReadsOff
			continue
		}
		if why := config.PageDoorRefusal(name, p.Engine, p.Auth, p.Options); why != "" {
			ds.NoDoor[name] = why
			continue
		}
		dsn := ""
		if prev != nil && prev.Gen == gen {
			if p.Engine == config.EngineSQLServer {
				dsn = prev.MS[name].Monitor
			} else {
				dsn = prev.PG[name].Monitor
			}
		}
		if dsn == "" {
			dsn = config.Resolve(p.DSNRef)
		}
		if dsn != "" {
			if why := pageDSNRefusal(name, p.Engine, dsn); why != "" {
				ds.NoDoor[name] = why
				continue
			}
		}
		ds.QueryText[name] = in.QueryText
		if p.Engine == config.EngineSQLServer {
			ds.MS[name] = mssql.Door{Monitor: dsn, Page: true}
		} else {
			ds.PG[name] = actions.Door{Monitor: dsn, Page: true}
		}
	}
	return ds
}

func cutColon(s string) (string, string, bool) {
	for i := 0; i+1 < len(s); i++ {
		if s[i] == ':' && s[i+1] == ' ' {
			return s[:i], s[i+2:], true
		}
	}
	return "", "", false
}

// pageDSNRefusal: the resolved string's own keys (config.PageDSNRefusal), then what only pgx's effective
// configuration shows - serve's environment lending a client certificate or a Kerberos name (PGSSLCERT, PGSSLKEY,
// PGKRBSRVNAME) to a string that names none
func pageDSNRefusal(name, engine, dsn string) string {
	if why := config.PageDSNRefusal(name, engine, dsn); why != "" {
		return why
	}
	if engine == config.EngineSQLServer {
		return ""
	}
	pc, err := pgconn.ParseConfig(dsn)
	if err != nil {
		return "instance " + name + ": its credential does not read as a PostgreSQL connection string"
	}
	if pc.TLSConfig != nil && len(pc.TLSConfig.Certificates) > 0 || pc.KerberosSrvName != "" || pc.KerberosSpn != "" {
		return "instance " + name + " signs in with this server's own identity (this server's environment: PGSSLCERT, PGSSLKEY or PGKRBSRVNAME): Community tools and custom reports run on it only from pgvigil.yaml"
	}
	return ""
}

// poolInventory reads Admin > Instances' list on serve's own pool (repo.go Inventory's statement; 0131 lets
// pgvigil_reader call admin_inventory()).
type poolInventory struct{ pool *pgxpool.Pool }

func (p poolInventory) InventoryGeneration(ctx context.Context) (int64, error) {
	var g int64
	err := p.pool.QueryRow(ctx, `SELECT pgvigil.admin_inventory_generation()`).Scan(&g)
	return g, err
}

func (p poolInventory) Inventory(ctx context.Context) ([]config.PageInstance, int64, error) {
	rows, err := p.pool.Query(ctx, `SELECT name, engine, platform, dsn_ref, tags, disabled, auth, options, generation FROM pgvigil.admin_inventory()`)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []config.PageInstance
	var gen int64
	for rows.Next() {
		var name, engine, platform, ref, auth, options *string
		var tags []string
		var disabled *bool
		if err := rows.Scan(&name, &engine, &platform, &ref, &tags, &disabled, &auth, &options, &gen); err != nil {
			return nil, 0, err
		}
		if name == nil {
			continue
		}
		pi := config.PageInstance{Name: *name, Tags: tags}
		for _, f := range []struct {
			to   *string
			from *string
		}{{&pi.Engine, engine}, {&pi.Platform, platform}, {&pi.DSNRef, ref}, {&pi.Auth, auth}, {&pi.Options, options}} {
			if f.from != nil {
				*f.to = *f.from
			}
		}
		if disabled != nil {
			pi.Disabled = *disabled
		}
		out = append(out, pi)
	}
	return out, gen, rows.Err()
}

// doorWake: serve's watcher's wake channel per server (InstancesAdminWrite signals it after a write)
var doorWake sync.Map // *Server -> chan struct{}

// WatchDoors runs serve's watcher: pgvigil.yaml's set at once, then a new set on each generation of Admin >
// Instances (at once after this serve's own write, within every of another serve's), each stored whole. Serve
// alone calls it (demo and mcp keep pgvigil.yaml's doors).
func (s *Server) WatchDoors(ctx context.Context, log *slog.Logger, cfg *config.Config, every time.Duration) {
	wake := make(chan struct{}, 1)
	doorWake.Store(s, wake)
	c := pageDoorsConfig{file: cfg.Instances, queryText: cfg.QueryText, reads: cfg.Doors.PageInstanceReads}
	file := s.fileDoors()
	s.storeDoors(file)
	config.WatchInventoryRaw(ctx, log, poolInventory{s.pool}, nil, cfg.Instances, cfg.QueryText, every, wake, true,
		func(all []config.Instance, page []config.PageInstance, gen int64) {
			prev := s.doorsNow()
			s.storeDoors(pageDoors(file, prev, c, all, page, gen))
		})
}

// wakeDoors asks this serve's watcher to read at once and waits for a set at least as new as gen, up to wait; it
// says whether the door changed in time (false: another tick of the watcher brings it, within its interval)
func (s *Server) wakeDoors(gen int64, wait time.Duration) bool {
	v, ok := doorWake.Load(s)
	if !ok {
		return false
	}
	select {
	case v.(chan struct{}) <- struct{}{}:
	default: // a wake is already pending
	}
	for end := time.Now().Add(wait); time.Now().Before(end); time.Sleep(50 * time.Millisecond) {
		if s.doorsNow().Gen >= gen {
			return true
		}
	}
	return false
}

// doorTakesEffect: the words a write's answer carries about its door
func doorTakesEffect(now bool, every time.Duration) string {
	if now {
		return "this server's doors follow at once"
	}
	return fmt.Sprintf("this server's doors follow within %d s", int(every.Seconds()))
}
