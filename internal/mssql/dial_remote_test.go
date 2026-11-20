package mssql

import (
	"context"
	"net"
	"testing"
	"time"
)

// TestDialerRemoteAlways: the dialer keeps the address of every TCP connection it
// opens, whatever its deadline - a DSN with its own 'connection timeout' (no deadline of the dialer's) was never probed,
// as lastRemote read only the connections kept for their deadline; a UDP dial (the SQL Server Browser) is not one
func TestDialerRemoteAlways(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ln.Close() }()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			_ = c.Close()
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for name, d := range map[string]*deadlineDialer{
		"the DSN's own connection timeout (no deadline)": {keepAlive: 30 * time.Second},
		"the dialer's deadline":                          {keepAlive: 30 * time.Second, until: time.Now().Add(3 * time.Second)},
	} {
		c, err := d.DialContext(ctx, "tcp", ln.Addr().String())
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if got := d.lastRemote(); got != ln.Addr().String() {
			t.Errorf("%s: lastRemote %q, want %q", name, got, ln.Addr().String())
		}
		_ = c.Close()
		d.done()
		if got := d.lastRemote(); got != ln.Addr().String() {
			t.Errorf("%s, after done(): lastRemote %q, want %q", name, got, ln.Addr().String())
		}
	}
	u := &deadlineDialer{keepAlive: 30 * time.Second}
	if c, err := u.DialContext(ctx, "udp", "127.0.0.1:1434"); err == nil {
		_ = c.Close()
	}
	if got := u.lastRemote(); got != "" {
		t.Errorf("a UDP dial (the Browser): lastRemote %q, want none", got)
	}
}
