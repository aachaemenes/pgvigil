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
	"strings"
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
	// NoDoor: a page instance with no door here -> why, and what opens it
	NoDoor    map[string]noDoor
	PageReads bool
	// Unread: the page's list not read yet on this serve (its first read failed, or has not run): an instance in
	// neither list is said to be unknown here, never 'in neither list'
	Unread bool
}

// noDoor is why an instance has no read login here (Why: the words a refusal and the page carry) and what opens it
// (How: the step a reader takes - never 'make the file readable' for a credential another host's serve stored)
type noDoor struct{ Why, How string }

// the steps that open a door, per case
const (
	howFile      = "set the variable, or make the file readable, for the account pgvigil serve runs as, and serve again (docs/configuration.md)"
	howNeither   = "give the instance a dsn in pgvigil.yaml with a login that is not a sysadmin or superuser and serve with that file, or add it in Admin > Instances (docs/configuration.md)"
	howPageAgain = "serve here as the account, and with the configuration folder, that stored it, or put the instance in pgvigil.yaml (docs/configuration.md); storing it again with Edit on this server moves it to this host, and a collector on the other host then reads nothing"
	howEnable    = "enable it in Admin > Instances"
	howCorrect   = "correct its row in Admin > Instances (docs/configuration.md)"
	howSwitch    = "an admin sets 'doors: page_instance_reads: on' in pgvigil.yaml and serves again, or the instance goes into pgvigil.yaml with its read login (docs/configuration.md)"
	howInTheFile = "put the instance in pgvigil.yaml with its read login (docs/configuration.md)"
	howUnread    = "serve reads the list again every 15 s; its log names why a read failed (a repository without migration 0131, or serve's role without EXECUTE on admin_inventory())"
)

// unreadWords: an instance this serve cannot place while the page's list is unread
func unreadWords(name string) string {
	return "instance " + name + " has no read login on this server yet: this server has not read the list of Admin > Instances"
}

var doorSets sync.Map // *Server -> *atomic.Pointer[doorSet] (serve's watcher stores it; demo and mcp keep the file's)

// doorsNow is the request's set: the watcher's last one on serve, else pgvigil.yaml's as Open and the Set* calls left
// it. Call it once per request and pass the value down.
func (s *Server) doorsNow() *doorSet {
	if v, ok := doorSets.Load(s.self()); ok {
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
		Hypo: pc.Hypo, NoDoor: map[string]noDoor{}}
	if s.actions != nil && s.actions.doors != nil {
		ds.PG = s.actions.doors
	}
	if ds.MS == nil {
		ds.MS = map[string]mssql.Door{}
	}
	if v, ok := pgJobAllow.Load(s.self()); ok {
		ds.PgJobs = v.(map[string]map[string]bool)
	}
	return ds
}

// doorsNow for an Actions: its server's set when it is the server's own Actions; else (one built apart, as a test
// does) the file's set with this Actions' own doors
func (a *Actions) doorsNow() *doorSet {
	if a.s == nil {
		return &doorSet{PG: a.doors, MS: map[string]mssql.Door{}, NoDoor: map[string]noDoor{}}
	}
	if a.s.actions == a {
		return a.s.doorsNow()
	}
	ds := *a.s.fileDoors()
	ds.PG = a.doors
	if ds.PG == nil {
		ds.PG = map[string]actions.Door{}
	}
	return &ds
}

// doorsNow for the SQL Server side: the same, its own doors when it is not the server's
func (m *MSSQLActions) doorsNow() *doorSet {
	if m.s == nil {
		return &doorSet{PG: map[string]actions.Door{}, MS: m.doors, NoDoor: map[string]noDoor{}}
	}
	if v, ok := mssqlActions.Load(m.s.self()); ok && v.(*MSSQLActions) == m {
		return m.s.doorsNow()
	}
	ds := *m.s.fileDoors()
	ds.MS = m.doors
	if ds.MS == nil {
		ds.MS = map[string]mssql.Door{}
	}
	return &ds
}

func (s *Server) storeDoors(ds *doorSet) {
	v, _ := doorSets.LoadOrStore(s.self(), &atomic.Pointer[doorSet]{})
	v.(*atomic.Pointer[doorSet]).Store(ds)
}

// noDoorWords: the words for an instance neither list holds
func noDoorWords(name string) string {
	return "instance " + name + " has no read login on this server: it is in neither pgvigil.yaml nor Admin > Instances"
}

// readLogin is an instance's read login on this set: its dsn and its door's kind ('file' or 'page'), or why it has
// none and what opens it. engine is 'sqlserver' or a PostgreSQL one.
func (ds *doorSet) readLogin(engine, name string) (dsn, kind string, no noDoor) {
	var monitor string
	var ok, page, secret bool
	if engine == config.EngineSQLServer {
		d, has := ds.MS[name]
		monitor, ok, page, secret = d.Monitor, has, d.Page, d.Secret != nil
	} else {
		d, has := ds.PG[name]
		monitor, ok, page, secret = d.Monitor, has, d.Page, d.Secret != nil
	}
	switch {
	case secret:
		// B24e: these readers take the login as a string; an instance whose password is in AWS Secrets Manager is
		// refused in words here rather than connecting without its password (a NOT PROVEN line of B24e's DONE)
		return "", "", noDoor{"instance " + name + ": its read login's password comes from AWS Secrets Manager (password_secret): custom reports, the community tools and Query Store plans do not read it yet", howFile}
	case ds.NoDoor[name].Why != "":
		return "", "", ds.NoDoor[name]
	case !ok && ds.Unread:
		return "", "", noDoor{unreadWords(name), howUnread}
	case !ok:
		return "", "", noDoor{noDoorWords(name), howNeither}
	case monitor == "" && page:
		return "", "", noDoor{"instance " + name + ": its credential is not readable on this host (stored by another host's serve, or a file this account cannot read)", howPageAgain}
	case monitor == "":
		return "", "", noDoor{"instance " + name + ": its read login's dsn (env:, file: or dpapi:) resolved to an empty string on this server", howFile}
	case page:
		return monitor, "page", noDoor{}
	}
	return monitor, "file", noDoor{}
}

// isPage: the instance's door on this set is a page door (EXPLAIN, the index advisor and the actions stay off on it)
func (ds *doorSet) isPage(engine, name string) bool {
	if engine == config.EngineSQLServer {
		return ds.MS[name].Page
	}
	return ds.PG[name].Page
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
// is resolved again on each tick. gen < 0: the page's list could not be read yet (the file's doors alone, Unread).
// A page row with no door keeps a Door marked Page with no login, so the actions, EXPLAIN and the index advisor say
// a page instance's words on it, and NoDoor says why it has no read login.
func pageDoors(file *doorSet, prev *doorSet, c pageDoorsConfig, all []config.Instance, page []config.PageInstance, gen int64) *doorSet {
	ds := &doorSet{Gen: gen, PG: map[string]actions.Door{}, MS: map[string]mssql.Door{}, Gates: file.Gates, QueryText: map[string]string{},
		DefaultQT: file.DefaultQT, Hypo: file.Hypo, PgJobs: file.PgJobs, NoDoor: map[string]noDoor{}, PageReads: c.reads, Unread: gen < 0}
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
	_, skipped := config.Merge(c.file, page, c.queryText, config.CounterEdits{}) // only skipped is read: the root counter lines never decide it
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
		shut := func(no noDoor) {
			ds.NoDoor[name] = no
			if p.Engine == config.EngineSQLServer {
				ds.MS[name] = mssql.Door{Page: true}
			} else {
				ds.PG[name] = actions.Door{Page: true}
			}
		}
		in, isMerged := merged[name]
		// the row's own refusal before the switch: the switch never opens it, so its words come first
		switch why := config.PageDoorRefusal(name, p.Engine, p.Auth, p.Options); {
		case p.Disabled:
			shut(noDoor{"instance " + name + " is disabled in Admin > Instances", howEnable})
			continue
		case !isMerged:
			shut(noDoor{"instance " + name + " is left out of the list: " + left[name], howCorrect})
			continue
		case why != "":
			shut(noDoor{why, howInTheFile})
			continue
		case !c.reads:
			shut(noDoor{"instance " + name + ": " + config.PageReadsOff, howSwitch})
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
				shut(noDoor{why, howInTheFile})
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
		return "instance " + name + " signs in with this server's own identity (this server's environment: PGSSLCERT or PGSSLKEY): Community tools and custom reports run on it only from pgvigil.yaml"
	}
	// pgx's own reading against the check's: a parser that drifts refuses instead of opening
	kv, err := config.PGSettings(dsn)
	if err != nil || pc.User != kv["user"] || pc.Password != kv["password"] || kv["dbname"] != "" && pc.Database != kv["dbname"] {
		return "instance " + name + ": its credential reads differently to the driver than to the door's check: Community tools and custom reports run on it only from pgvigil.yaml"
	}
	hosts := map[string]bool{}
	for _, h := range strings.Split(kv["host"], ",") {
		hosts[strings.TrimSpace(h)] = true
	}
	for _, c := range append([]*pgconn.FallbackConfig{{Host: pc.Host, Port: pc.Port}}, pc.Fallbacks...) {
		if network, _ := pgconn.NetworkAddress(c.Host, c.Port); network == "unix" || !hosts[c.Host] {
			return "instance " + name + " signs in through this server's own socket or a host its credential does not name (" + c.Host + "): Community tools and custom reports run on it only from pgvigil.yaml"
		}
	}
	return ""
}

// poolInventory reads Admin > Instances' list on serve's own pool (config.InventorySQL, as repo.Inventory; 0131 lets
// pgvigil_reader call admin_inventory()).
type poolInventory struct{ pool *pgxpool.Pool }

func (p poolInventory) InventoryGeneration(ctx context.Context) (int64, error) {
	var g int64
	err := p.pool.QueryRow(ctx, `SELECT pgvigil.admin_inventory_generation()`).Scan(&g)
	return g, err
}

func (p poolInventory) Inventory(ctx context.Context) ([]config.PageInstance, int64, error) {
	rows, err := p.pool.Query(ctx, config.InventorySQL) // the collector's statement and scan (B24p's fold 5)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	return config.ScanInventory(rows)
}

// DoorEvery is how often serve's watcher reads the inventory's generation (another serve's write reaches this one
// within it)
const DoorEvery = 15 * time.Second

// doorWait bounds InstancesAdminWrite's wait for this serve's new door set: past it the write still succeeds and its
// answer says the door follows within DoorEvery (a stuck watcher never hangs the admin page)
const doorWait = 5 * time.Second

// doorWake: serve's watcher's wake channel per server (InstancesAdminWrite signals it after a write)
var doorWake sync.Map // *Server -> chan struct{}

// schedCfg: serve's loaded configuration per server (WatchDoors keeps it): the Connection Test's list of what will
// not run reads it as the scheduler does (B24e review 11)
var schedCfg sync.Map // *Server -> *config.Config

// WatchDoors runs serve's watcher: pgvigil.yaml's set at once, then a new set on each generation of Admin >
// Instances (at once after this serve's own write, within every of another serve's), each stored whole. Serve
// alone calls it (demo and mcp keep pgvigil.yaml's doors).
func (s *Server) WatchDoors(ctx context.Context, log *slog.Logger, cfg *config.Config, every time.Duration) {
	wake := make(chan struct{}, 1)
	doorWake.Store(s.self(), wake)
	schedCfg.Store(s.self(), cfg) // the Connection Test's list reads the loaded configuration (B24e review 11)
	c := pageDoorsConfig{file: cfg.Instances, queryText: cfg.QueryText, reads: cfg.Doors.PageInstanceReads}
	file := s.fileDoors()
	first := *file // until the first read: pgvigil.yaml's doors, the page's list unread
	first.Unread, first.PageReads = true, c.reads
	s.storeDoors(&first)
	config.WatchInventoryRaw(ctx, log, poolInventory{s.pool}, nil, cfg.Instances, cfg.QueryText, cfg.MSSQLCounters, every, wake, true,
		func(all []config.Instance, page []config.PageInstance, gen int64) {
			prev := s.doorsNow()
			if prev.Gen == gen && !prev.Unread && !prev.emptyPage() {
				return // the same generation and every page door resolved: the set stands
			}
			s.storeDoors(pageDoors(file, prev, c, all, page, gen))
		})
}

// emptyPage: a page door of this set whose credential resolved to nothing here (read again on the next tick)
func (ds *doorSet) emptyPage() bool {
	for name, d := range ds.PG {
		if d.Page && d.Monitor == "" && ds.NoDoor[name].Why == "" {
			return true
		}
	}
	for name, d := range ds.MS {
		if d.Page && d.Monitor == "" && ds.NoDoor[name].Why == "" {
			return true
		}
	}
	return false
}

// wakeDoors asks this serve's watcher to read at once and waits for a set at least as new as gen, up to wait; it
// says whether the door changed in time (false: another tick of the watcher brings it, within its interval). Only
// called where a watcher runs (doorsAfterWrite).
func (s *Server) wakeDoors(gen int64, wait time.Duration) bool {
	v, ok := doorWake.Load(s.self())
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

// doorTakesEffect: the words a write's answer carries about the read doors (a change can open, move or close one, or
// leave an instance refused: the words say only when the change reaches them)
func doorTakesEffect(now bool, every time.Duration) string {
	if now {
		return fmt.Sprintf("this change reaches Community tools and custom reports at once on this server (on another serve within %d s)", int(every.Seconds()))
	}
	return fmt.Sprintf("this change reaches Community tools and custom reports within %d s", int(every.Seconds()))
}

// doorUnreadAfterWrite: the words when this serve could not read the inventory's generation after the write
const doorUnreadAfterWrite = "this server could not read the list of Admin > Instances (its log names why): this change reaches Community tools and custom reports when it can"

// doorsAfterWrite: after a done write of Admin > Instances, the words for the answer: "" where no watcher runs
// (pgvigil demo, mcp: pgvigil.yaml's doors alone) and on an install whose page doors are off (the watcher still
// reads the change, for the page's words); else doorsAfterGen on the generation read now
func (s *Server) doorsAfterWrite(ctx context.Context) string {
	v, ok := doorWake.Load(s.self())
	if !ok {
		return ""
	}
	if !s.doorsNow().PageReads {
		select {
		case v.(chan struct{}) <- struct{}{}:
		default: // a wake is already pending
		}
		return ""
	}
	var gen int64
	err := s.pool.QueryRow(ctx, `SELECT pgvigil.admin_inventory_generation()`).Scan(&gen)
	return s.doorsAfterGen(gen, err)
}

// doorsAfterGen: this serve's watcher reads the generation gen at once and the write waits for it up to doorWait (a
// stuck watcher never hangs the page)
func (s *Server) doorsAfterGen(gen int64, err error) string {
	if err != nil {
		return doorUnreadAfterWrite
	}
	return doorTakesEffect(s.wakeDoors(gen, doorWait), DoorEvery)
}
