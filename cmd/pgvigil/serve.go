package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/web"
)

// runServe starts the web UI and JSON API over the repository:
//
//	pgvigil serve -config pgvigil.yaml [-listen 127.0.0.1:8080] [-dsn env:PGVIGIL_READER_DSN]
//
// -dsn names a reader login (pgvigil_reader); without it the repository DSN of the config is used.
// The server binds to loopback by default: it has no login of its own yet.
func runServe(ctx context.Context, log *slog.Logger, args []string) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	path := fs.String("config", "pgvigil.yaml", "path to the configuration file")
	listen := fs.String("listen", "127.0.0.1:8080", "address to listen on")
	dsn := fs.String("dsn", "", "reader connection string (or env:NAME / file:path); default the config's repository dsn")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(*path)
	if err != nil {
		return err
	}
	d := cfg.Repository.DSN()
	if *dsn != "" {
		d = config.Resolve(*dsn)
	}
	srv, err := web.Open(ctx, log, d, expectedIntervals(cfg))
	if err != nil {
		return err
	}
	defer srv.Close()

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		return err
	}
	if host, _, _ := net.SplitHostPort(*listen); host != "127.0.0.1" && host != "localhost" && host != "::1" {
		log.Warn("serve listens beyond loopback and has no login; put it behind a proxy with authentication", "listen", *listen)
	}
	hs := &http.Server{Handler: srv.Handler(), ReadHeaderTimeout: 10 * time.Second, WriteTimeout: 30 * time.Second}
	errc := make(chan error, 1)
	go func() { errc <- hs.Serve(ln) }()
	log.Info("pgvigil serve started", "url", fmt.Sprintf("http://%s/", ln.Addr()))
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

// expectedIntervals maps each configured instance to its collections' intervals in seconds.
func expectedIntervals(cfg *config.Config) map[string]map[string]int {
	out := map[string]map[string]int{}
	for _, in := range cfg.Instances {
		m := map[string]int{}
		for _, c := range collect.All() {
			if iv := cfg.Interval(in, c.Name(), c.DefaultInterval()); iv > 0 {
				m[c.Name()] = int(iv / time.Second)
			}
		}
		out[in.Name] = m
	}
	return out
}
