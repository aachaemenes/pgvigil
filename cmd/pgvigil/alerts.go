package main

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/aachaemenes/pgvigil/internal/alerts"
)

// runAlerts is `pgvigil alerts -config f`: one pass of the alert channels the configuration's alerts: list names
// (internal/alerts): what is owed is sent, every attempt recorded in pgvigil.alert_log. No channel = nothing sent, and
// the log's 'none' row says so when the login may write it (without alerts_dsn on a least-privilege install it may not:
// still exit 0, nothing sent). It connects as alerts_dsn (a login IN ROLE pgvigil_alerter), else the repository's dsn.
func runAlerts(ctx context.Context, log *slog.Logger, args []string) error {
	cfg, fs, err := loadConfig(args, false)
	if err != nil {
		return err
	}
	st, err := alerts.LoadFile(fs.Lookup("config").Value.String())
	if err != nil {
		return &configError{err}
	}
	chs := st.Channels
	dsn := st.DSN()
	if dsn == "" {
		dsn = cfg.Repository.DSN()
	}
	res, err := alerts.Once(ctx, dsn, chs)
	if err != nil {
		return err
	}
	if len(chs) == 0 {
		fmt.Println("alerts: no channel configured: nothing sent")
		return nil
	}
	fmt.Println("alerts: " + res.String())
	for _, e := range res.Errors {
		log.Warn("alert channel failed", "err", e)
	}
	if res.Failed > 0 {
		return fmt.Errorf("%d alert(s) not sent", res.Failed)
	}
	return nil
}
