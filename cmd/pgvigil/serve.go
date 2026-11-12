package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/actions"
	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/dbadash"
	"github.com/aachaemenes/pgvigil/internal/engines"
	"github.com/aachaemenes/pgvigil/internal/mssql"
	"github.com/aachaemenes/pgvigil/internal/web"
)

// runServe starts the web UI and JSON API over the repository:
//
//	pgvigil serve -config pgvigil.yaml [-listen 127.0.0.1:8080] [-dsn env:PGVIGIL_UI_DSN] [-open]
//	              [-tls-cert pgvigil.crt -tls-key pgvigil.key] [-no-login] [-session-hours 12]
//
// -dsn names the UI's repository login (pgvigil_reader + pgvigil_auth); without it the repository
// DSN of the config is used. The UI login (pgvigil.ui_users) is on unless -no-login, which a loopback
// listen alone may ask for. A listen beyond loopback needs TLS and the login; it refuses to start
// without them.
func runServe(ctx context.Context, log *slog.Logger, args []string) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	path := fs.String("config", "pgvigil.yaml", "path to the configuration file")
	listen := fs.String("listen", "127.0.0.1:8080", "address to listen on")
	dsn := fs.String("dsn", "", "UI connection string (or env:NAME / file:path); default the config's repository dsn")
	tlsCert := fs.String("tls-cert", "", "PEM certificate (with -tls-key): serve HTTPS")
	tlsKey := fs.String("tls-key", "", "PEM private key (with -tls-cert)")
	noLogin := fs.Bool("no-login", false, "serve without the UI login (allowed on a loopback listen only)")
	open := fs.Bool("open", false, "open the UI in an app-mode browser window (Edge or Chrome, its own window) once it listens; the default browser when neither is found")
	sessionHours := fs.Int("session-hours", 12, "hours a login stays valid")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(*path)
	if err != nil {
		return err
	}
	// the custom: list (task 61): with it the stale check counts the custom collection among the expected ones
	if err := collect.LoadCustomChecks(*path, cfg.Instances); err != nil {
		return err
	}
	for _, w := range collect.CustomWarnings() {
		log.Warn(w)
	}
	d := cfg.Repository.DSN()
	if *dsn != "" {
		d = config.Resolve(*dsn)
	}
	if strings.TrimSpace(d) == "" {
		src := "repository.dsn " + cfg.Repository.DSNRaw
		if *dsn != "" {
			src = "-dsn " + *dsn
		}
		return &configError{fmt.Errorf("config %s: the repository dsn (%s) resolves to nothing: fill in the env file or the file it names", *path, src)}
	}
	host, _, err := net.SplitHostPort(*listen)
	if err != nil {
		return fmt.Errorf("-listen: %w", err)
	}
	if *sessionHours < 1 || *sessionHours > 24*30 {
		return errors.New("-session-hours must be 1..720")
	}
	useTLS := *tlsCert != "" || *tlsKey != ""
	if useTLS && (*tlsCert == "" || *tlsKey == "") {
		return errors.New("-tls-cert and -tls-key go together")
	}
	loopback := host == "127.0.0.1" || host == "localhost" || host == "::1"
	if !loopback {
		if !useTLS {
			return fmt.Errorf("a listen on %s is reachable from other machines and needs -tls-cert and -tls-key ('pgvigil cert' writes a self-signed pair)", *listen)
		}
		if *noLogin {
			return errors.New("-no-login is allowed on a loopback listen (127.0.0.1, localhost, ::1) only")
		}
	}
	var tlsCfg *tls.Config
	if useTLS {
		pair, err := tls.LoadX509KeyPair(*tlsCert, *tlsKey)
		if err != nil {
			return fmt.Errorf("tls: %w", err)
		}
		tlsCfg = &tls.Config{Certificates: []tls.Certificate{pair}, MinVersion: tls.VersionTLS12}
	}
	if *noLogin {
		log.Warn("serve runs without the UI login: anyone who reaches this loopback port reads the repository", "listen", *listen)
	}
	// bind first: the accepted Host values follow the bound port (-listen 127.0.0.1:0 picks one, as demo does)
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		return err
	}
	var hosts []string // nil = any Host (beyond loopback the certificate names the server)
	if loopback {
		hosts = web.LoopbackHosts(strconv.Itoa(ln.Addr().(*net.TCPAddr).Port))
	}
	srv, err := web.Open(ctx, log, d, web.Options{Expected: expectedIntervals(cfg), Hosts: hosts, Login: !*noLogin, TLS: useTLS,
		SessionTTL: time.Duration(*sessionHours) * time.Hour,
		Actions:    &web.ActionsConfig{LogDSN: cfg.Repository.DSN(), Doors: actions.DoorsFromConfig(cfg)},
		Tags:       web.TagsUI{GroupBy: cfg.UI.GroupBy, EnvOrder: cfg.UI.EnvOrder}, Version: versionLine()})
	if err != nil {
		_ = ln.Close()
		return err
	}
	defer srv.Close()
	pc := web.PlansConfig{Gates: map[string]actions.ExplainGate{}, QueryText: map[string]string{}, Hypo: map[string]bool{}, DefaultQueryText: cfg.QueryText}
	for _, in := range cfg.Instances {
		pc.Gates[in.Name] = actions.ExplainGate{Enabled: in.ExplainAnalyze, DSN: in.ExplainDSN(),
			Configured: strings.TrimSpace(in.ExplainDSNRaw) != "", Timeout: in.ExplainTimeout.Duration}
		pc.QueryText[in.Name] = in.QueryText
		pc.Hypo[in.Name] = in.HypoIndex
	}
	srv.SetPlans(pc)
	doors := map[string]mssql.Door{}
	for _, in := range cfg.Instances {
		if in.Engine == config.EngineSQLServer {
			doors[in.Name] = mssql.Door{Monitor: in.DSN(), Actions: in.ActionsDSN(), Configured: strings.TrimSpace(in.ActionsDSNRaw) != "", Allow: in.Actions}
		}
	}
	srv.SetMSSQLActions(doors)
	dbadash.SetRepositories(cfg.DBADash) // the imported servers' live screens (task 168) read the repositories through serve
	// task 161: a PostgreSQL instance's job actions (job_stop, job_start) are on only where its actions: list names them
	pgJobs := map[string][]string{}
	for _, in := range cfg.Instances {
		if in.Engine != config.EngineSQLServer && len(in.Actions) > 0 {
			pgJobs[in.Name] = in.Actions
		}
	}
	srv.SetPgJobActions(pgJobs)
	// task 204: Admin > Instances (the credential files beside the config, the file's instances read-only) and its sync loop
	dd := map[string]string{}
	for _, d := range cfg.DBADash {
		dd[d.Name] = d.DSNRaw
	}
	srv.SetInstancesAdmin(web.InstancesAdmin{ConfigPath: *path, File: cfg.Instances, DBADash: dd})
	go srv.RunInstanceSync(ctx)
	// task 171: the report mail schedules (claimed, rendered headless, queued for the alert sender)
	go srv.RunReportMail(ctx)

	// activity runs up to four 15 s statements in a row: the write deadline covers all of them
	hs := &http.Server{Handler: srv.Handler(), ReadHeaderTimeout: 10 * time.Second, WriteTimeout: 75 * time.Second, TLSConfig: tlsCfg}
	errc := make(chan error, 1)
	scheme := "http"
	if useTLS {
		scheme = "https"
		go func() { errc <- hs.ServeTLS(ln, "", "") }()
	} else {
		go func() { errc <- hs.Serve(ln) }()
	}
	log.Info("pgvigil serve started", "url", fmt.Sprintf("%s://%s/", scheme, ln.Addr()), "login", !*noLogin)
	if *open {
		openWindow(log, browseURL(scheme, ln.Addr()))
	}
	select {
	case <-ctx.Done():
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return hs.Shutdown(sctx)
	case err := <-errc:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

// expectedIntervals gives the stale check every collection's default interval and each
// configured instance's effective one (0 = disabled there), in seconds.
func expectedIntervals(cfg *config.Config) web.Expected {
	e := web.Expected{Defaults: map[string]int{}, Instances: map[string]map[string]int{}, Builtin: map[string]int{}}
	all := engines.AllSpecs()
	for _, c := range all {
		// the file's global schedules: apply to an instance the page holds (it has no entry below); the dialogs'
		// default_s stays the collection's own (Builtin)
		e.Defaults[c.Name] = int(cfg.Interval(config.Instance{}, c.Name, c.Default) / time.Second)
		e.Builtin[c.Name] = int(c.Default / time.Second)
	}
	for _, in := range cfg.Instances {
		m := map[string]int{}
		for _, c := range all {
			// a collection of another engine, or one gated off by the instance's config (no aws: block), never
			// writes a row: 0 keeps the stale check from flagging the row an earlier build left behind
			if skip, _ := engines.Gated(in, c.Name); skip {
				m[c.Name] = 0
				continue
			}
			m[c.Name] = int(cfg.Interval(in, c.Name, c.Default) / time.Second)
		}
		e.Instances[in.Name] = m
	}
	return e
}
