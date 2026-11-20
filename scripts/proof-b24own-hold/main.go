// Command proof-b24own-hold opens one SQL Server session (the dsn names its login and its app name, so the session's
// program_name is what the proof needs), runs one batch on it and holds the session open until its time runs out:
// scripts/proof-b24own.sh's sessions that call themselves pgvigil (or not) under pgvigil's login (or not).
// Usage: PGV_HOLD_DSN=<sqlserver:// url with app+name> go run ./scripts/proof-b24own-hold <seconds> <batch>
// It prints 'held' once the batch is sent, and the batch's error if it fails.
package main

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/aachaemenes/pgvigil/internal/mssqlopen"
)

func main() { os.Exit(run()) }

// run holds the session; its deferred cancel runs before main exits with the code it returns
func run() int {
	if len(os.Args) != 3 || os.Getenv("PGV_HOLD_DSN") == "" {
		fmt.Fprintln(os.Stderr, "usage: PGV_HOLD_DSN=<dsn> proof-b24own-hold <seconds> <batch>")
		return 2
	}
	secs, err := strconv.Atoi(os.Args[1])
	if err != nil || secs <= 0 {
		fmt.Fprintln(os.Stderr, "seconds must be a positive number")
		return 2
	}
	db, err := mssqlopen.Open(os.Getenv("PGV_HOLD_DSN")) // the tree's one opener: a plain sqlserver:// URL opens as sql.Open did
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(secs)*time.Second)
	defer cancel()
	c, err := db.Conn(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	done := make(chan error, 1)
	go func() { _, err := c.ExecContext(ctx, os.Args[2]); done <- err }()
	fmt.Println("held")
	select {
	case err := <-done:
		if err != nil && ctx.Err() == nil {
			fmt.Fprintln(os.Stderr, "the batch:", err)
		}
		<-ctx.Done() // the session stays open (an open transaction stays open) until the time runs out
	case <-ctx.Done():
	}
	_ = c.Close()
	return 0
}
