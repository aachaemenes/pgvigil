// Command proof-b24own-hold opens one SQL Server session (the dsn names its login and its app name, so the session's
// program_name is what the proof needs), runs one batch on it and holds the session open until its time runs out:
// scripts/proof-b24own.sh's sessions that call themselves pgvigil (or not) under pgvigil's login (or not).
// Usage: PGV_HOLD_DSN=<sqlserver:// url with app+name> go run ./scripts/proof-b24own-hold <seconds> <batch>
// It prints 'held' once the batch is sent, and the batch's error if it fails.
package main

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"strconv"
	"time"

	_ "github.com/microsoft/go-mssqldb"
)

func main() {
	if len(os.Args) != 3 || os.Getenv("PGV_HOLD_DSN") == "" {
		fmt.Fprintln(os.Stderr, "usage: PGV_HOLD_DSN=<dsn> proof-b24own-hold <seconds> <batch>")
		os.Exit(2)
	}
	secs, err := strconv.Atoi(os.Args[1])
	if err != nil || secs <= 0 {
		fmt.Fprintln(os.Stderr, "seconds must be a positive number")
		os.Exit(2)
	}
	db, err := sql.Open("sqlserver", os.Getenv("PGV_HOLD_DSN"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(secs)*time.Second)
	defer cancel()
	c, err := db.Conn(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
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
}
