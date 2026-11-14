package mssql

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/microsoft/go-mssqldb/msdsn"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestConnectTimeoutDefault (task 201 DONE-2 N10, both engines - the lead 12:5x): a SQL Server whose port accepts and
// never answers. A DSN without 'connection timeout' ends at collect.DefaultConnectTimeout (lowered here); one that
// sets it keeps its own (go-mssqldb then bounds each read itself). Without the deadline the connect waits for good:
// go-mssqldb dials for 15 s, then reads the login reply with no deadline and without the context.
func TestConnectTimeoutDefault(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var held []net.Conn
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			held = append(held, c)
			mu.Unlock()
		}
	}()
	defer func() {
		_ = ln.Close()
		mu.Lock()
		for _, c := range held {
			_ = c.Close()
		}
		mu.Unlock()
	}()
	old := collect.DefaultConnectTimeout
	collect.DefaultConnectTimeout = 300 * time.Millisecond
	defer func() { collect.DefaultConnectTimeout = old }()
	port := ln.Addr().(*net.TCPAddr).Port
	for _, c := range []struct {
		dsn      string
		min, max time.Duration
	}{
		{fmt.Sprintf("sqlserver://u:p@127.0.0.1:%d?database=master&encrypt=disable", port), 200 * time.Millisecond, 3 * time.Second},
		{fmt.Sprintf("server=127.0.0.1;port=%d;user id=u;password=p;database=master;encrypt=disable", port), 200 * time.Millisecond, 3 * time.Second},
		{fmt.Sprintf("sqlserver://u:p@127.0.0.1:%d?database=master&encrypt=disable&connection+timeout=2", port), 1800 * time.Millisecond, 6 * time.Second},
	} {
		done := make(chan error, 1)
		start := time.Now()
		go func() {
			db, conn, err := Connect(context.Background(), config.Instance{Name: "hang", DSNRaw: c.dsn})
			if conn != nil {
				_ = conn.Close()
			}
			if db != nil {
				_ = db.Close()
			}
			done <- err
		}()
		select {
		case err := <-done:
			el := time.Since(start)
			if err == nil {
				t.Errorf("%s: connected to a port that never answers", c.dsn)
			}
			if el < c.min || el > c.max {
				t.Errorf("%s: ended after %v (want %v to %v): %v", c.dsn, el.Round(10*time.Millisecond), c.min, c.max, err)
			}
		case <-time.After(10 * time.Second):
			t.Fatalf("%s: the connect still waits after 10 s (no deadline)", c.dsn)
		}
	}
}

// silentListener accepts and holds every connection, answering nothing (after, when set, it writes one byte that
// long after the accept); stop closes it and what it holds.
func silentListener(t *testing.T, after time.Duration) (addr string, stop func()) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var held []net.Conn
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			held = append(held, c)
			mu.Unlock()
			if after > 0 {
				go func() { time.Sleep(after); _, _ = c.Write([]byte{1}) }()
			}
		}
	}()
	return ln.Addr().String(), func() {
		_ = ln.Close()
		mu.Lock()
		for _, c := range held {
			_ = c.Close()
		}
		mu.Unlock()
	}
}

// TestDeadlineDialerPast (review part E's should-fix 2): the dial itself carries the connect's deadline - one already
// passed fails the dial (without it the dial runs under the driver's own 15 s).
func TestDeadlineDialerPast(t *testing.T) {
	addr, stop := silentListener(t, 0)
	defer stop()
	d := &deadlineDialer{until: time.Now().Add(-time.Second), keepAlive: 30 * time.Second}
	c, err := d.DialContext(context.Background(), "tcp", addr)
	if err == nil {
		_ = c.Close()
		t.Fatal("dialled after the connect's deadline had passed")
	}
}

// TestDeadlineDialerClamp (review part E's should-fix 2): while the connect is under way a later deadline the driver
// sets (the SQL Server Browser read sets its 15 s one) is held to the connect's.
func TestDeadlineDialerClamp(t *testing.T) {
	addr, stop := silentListener(t, 0)
	defer stop()
	d := &deadlineDialer{until: time.Now().Add(300 * time.Millisecond), keepAlive: 30 * time.Second}
	c, err := d.DialContext(context.Background(), "tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(time.Hour))
	done := make(chan error, 1)
	start := time.Now()
	go func() { _, err := c.Read(make([]byte, 1)); done <- err }()
	select {
	case err := <-done:
		if err == nil || time.Since(start) > 1500*time.Millisecond {
			t.Errorf("the read ended after %v with %v (want an i/o timeout at about 300 ms)", time.Since(start).Round(10*time.Millisecond), err)
		}
	case <-time.After(2 * time.Second):
		t.Error("a later deadline set during the connect replaced the connect's: the read still waits after 2 s")
	}
}

// TestDeadlineDialerDone (review part E's nit 8, a guard): done() lifts the deadline - a read after it gets its byte.
func TestDeadlineDialerDone(t *testing.T) {
	addr, stop := silentListener(t, 300*time.Millisecond)
	defer stop()
	d := &deadlineDialer{until: time.Now().Add(100 * time.Millisecond), keepAlive: 30 * time.Second}
	c, err := d.DialContext(context.Background(), "tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	d.done()
	time.Sleep(200 * time.Millisecond)
	if _, err := c.Read(make([]byte, 1)); err != nil {
		t.Errorf("a read after done() failed: %v (want the byte)", err)
	}
}

// TestNamedInstanceNoBrowser (review part E's should-fix 1): a named instance with no port asks the SQL Server Browser
// (UDP 1434) first; go-mssqldb only logs a failed Browser read and returns "no instance matching ..." - the network's
// error is joined, so the host that answers no one counts as no answer. The loopback has no Browser: refused at once.
func TestNamedInstanceNoBrowser(t *testing.T) {
	old := collect.DefaultConnectTimeout
	collect.DefaultConnectTimeout = 2 * time.Second
	defer func() { collect.DefaultConnectTimeout = old }()
	db, conn, err := Connect(context.Background(), config.Instance{Name: "ni", DSNRaw: `server=127.0.0.1\NOSUCH;user id=u;password=p;encrypt=disable`})
	if conn != nil {
		_ = conn.Close()
	}
	if db != nil {
		_ = db.Close()
	}
	if err == nil {
		t.Fatal("connected to a named instance no Browser knows")
	}
	if !collect.NoAnswer(err) {
		t.Errorf("a named instance whose Browser answered no one counts as answered: %v", err)
	}
}

// TestTLSStallNoAnswer (review part E's nit 4): a server that answers PRELOGIN with encryption on and then says
// nothing in the TLS handshake answers no one, as PostgreSQL's does (go-mssqldb wraps the handshake's error with %v,
// dropping the network cause: the recorded one is joined).
func TestTLSStallNoAnswer(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var held []net.Conn
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			held = append(held, c)
			mu.Unlock()
			go func() {
				hdr := make([]byte, 8)
				if _, err := io.ReadFull(c, hdr); err != nil {
					return
				}
				if _, err := io.ReadFull(c, make([]byte, int(binary.BigEndian.Uint16(hdr[2:4]))-8)); err != nil {
					return
				}
				// a PRELOGIN reply: VERSION (offset 11, 6 bytes), ENCRYPTION (offset 17, 1 byte: ENCRYPT_ON), the end
				// of the option table; then the data
				payload := []byte{0x00, 0x00, 0x0B, 0x00, 0x06, 0x01, 0x00, 0x11, 0x00, 0x01, 0xFF,
					0x10, 0x00, 0x07, 0xD0, 0x00, 0x00, 0x01}
				pkt := append([]byte{0x04, 0x01, 0x00, byte(8 + len(payload)), 0x00, 0x00, 0x01, 0x00}, payload...)
				_, _ = c.Write(pkt)
				_, _ = io.Copy(io.Discard, c) // the client's TLS hello: never answered
			}()
		}
	}()
	defer func() {
		_ = ln.Close()
		mu.Lock()
		for _, c := range held {
			_ = c.Close()
		}
		mu.Unlock()
	}()
	old := collect.DefaultConnectTimeout
	collect.DefaultConnectTimeout = 300 * time.Millisecond
	defer func() { collect.DefaultConnectTimeout = old }()
	dsn := fmt.Sprintf("sqlserver://u:p@127.0.0.1:%d?database=master&encrypt=true&trustservercertificate=true", ln.Addr().(*net.TCPAddr).Port)
	db, conn, err := Connect(context.Background(), config.Instance{Name: "tls", DSNRaw: dsn})
	if conn != nil {
		_ = conn.Close()
	}
	if db != nil {
		_ = db.Close()
	}
	if err == nil {
		t.Fatal("connected through a TLS handshake that was never answered")
	}
	if !collect.NoAnswer(err) {
		t.Errorf("a TLS handshake the server never answered counts as answered: %v", err)
	}
}

// TestMsTarget (review part E's nit 5): one SQL Server, one target - no port and no instance name is the driver's
// 1433; a port given makes the instance name moot (the driver dials the port).
func TestMsTarget(t *testing.T) {
	for _, c := range []struct{ dsn, want string }{
		{`server=DB1;user id=u`, `mssql:db1:1433`},
		{`server=db1,1433;user id=u`, `mssql:db1:1433`},
		{`sqlserver://u:p@db1?database=x`, `mssql:db1:1433`},
		{`server=db1\SQL2;user id=u`, `mssql:db1\sql2:0`},
		{`server=db1\SQL2;port=1500;user id=u`, `mssql:db1:1500`},
	} {
		p, err := msdsn.Parse(c.dsn)
		if err != nil {
			t.Fatalf("%s: %v", c.dsn, err)
		}
		if got := msTarget(p); got != c.want {
			t.Errorf("%s: msTarget = %q (want %q)", c.dsn, got, c.want)
		}
	}
}
