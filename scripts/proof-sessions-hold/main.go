// Command proof-sessions-hold opens N connections to a SQL Server and holds them idle until it is killed or its time
// runs out: the many sessions of scripts/proof-mssql-sessions.sh part A6 (the reads' time at about 5,000 sessions).
// Usage: PGV_HOLD_DSN=<sqlserver:// url> go run ./scripts/proof-sessions-hold <n> <seconds>
// It prints 'held <n>' once every connection is open, and nothing else unless a connection fails.
package main

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"

	_ "github.com/microsoft/go-mssqldb"
)

func main() {
	if len(os.Args) != 3 || os.Getenv("PGV_HOLD_DSN") == "" {
		fmt.Fprintln(os.Stderr, "usage: PGV_HOLD_DSN=<dsn> proof-sessions-hold <n> <seconds>")
		os.Exit(2)
	}
	n, err1 := strconv.Atoi(os.Args[1])
	secs, err2 := strconv.Atoi(os.Args[2])
	if err1 != nil || err2 != nil || n <= 0 || secs <= 0 {
		fmt.Fprintln(os.Stderr, "n and seconds must be positive numbers")
		os.Exit(2)
	}
	db, err := sql.Open("sqlserver", os.Getenv("PGV_HOLD_DSN"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	db.SetMaxOpenConns(n + 1)
	db.SetMaxIdleConns(n + 1)
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(secs)*time.Second)
	defer cancel()
	conns := make([]*sql.Conn, n)
	var wg sync.WaitGroup
	var mu sync.Mutex
	failed := 0
	sem := make(chan struct{}, 64) // open at most 64 at once
	for i := range conns {
		wg.Add(1)
		sem <- struct{}{}
		go func(i int) {
			defer wg.Done()
			defer func() { <-sem }()
			c, err := db.Conn(ctx)
			if err == nil {
				err = c.PingContext(ctx)
			}
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				failed++
				if failed <= 3 {
					fmt.Fprintln(os.Stderr, "connection", i, err)
				}
				return
			}
			conns[i] = c
		}(i)
	}
	wg.Wait()
	fmt.Printf("held %d\n", n-failed)
	<-ctx.Done()
	for _, c := range conns {
		if c != nil {
			_ = c.Close()
		}
	}
}
