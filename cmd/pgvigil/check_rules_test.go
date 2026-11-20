package main

import (
	"context"
	"net"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/web"
)

// TestCheckBlankRepositoryDSN: a repository dsn of white space is refused as an empty one - a FAIL with its reason,
// exit 2 - and connects nowhere (pgx would dial libpq's defaults).
func TestCheckBlankRepositoryDSN(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ln.Close() }()
	var hits atomic.Int32
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			hits.Add(1)
			_ = c.Close()
		}
	}()
	t.Setenv("PGHOST", "127.0.0.1")
	t.Setenv("PGPORT", strconv.Itoa(ln.Addr().(*net.TCPAddr).Port))
	t.Setenv("PGCONNECT_TIMEOUT", "2")
	t.Setenv("L241_REPO_BLANK", " ")
	p := checkYaml(t, t.TempDir(), "repository:\n  dsn: env:L241_REPO_BLANK\ninstances: []\n")
	rows, exit := checkRun(context.Background(), testLog(), p, nil)
	if exit != 2 || !rowWith(rows, "FAIL", "repository", "holds only white space") {
		t.Errorf("exit %d, want 2 and a FAIL naming the white space:\n%s", exit, rowsText(rows))
	}
	if n := hits.Load(); n != 0 {
		t.Errorf("a white-space dsn connected %d time(s) to libpq's defaults", n)
	}
}

// TestCheckFormsTheReaderRefuses: a value in a form its reader never takes is a FAIL before run or serve stops on it -
// a webhook url written as dpapi: (the alerts loader's words, or off Windows its reference's own FAIL, never an OK
// row alone) and a metrics token that is no file: / env: reference (serve's start check, run here).
func TestCheckFormsTheReaderRefuses(t *testing.T) {
	p := checkYaml(t, t.TempDir(), "repository:\n  dsn: \"host=127.0.0.1 port=1 user=u dbname=d connect_timeout=1\"\ninstances: []\n"+
		"alerts:\n  - name: ops\n    kind: webhook\n    webhook:\n      url: \"dpapi:/var/lib/pgvigil/secrets/hook.bin\"\n"+
		"doors:\n  prometheus_metrics: on\nmetrics:\n  token: the-token-itself-written-inline-0123456789\n")
	rows, _ := checkRun(context.Background(), testLog(), p, nil)
	hook, token := false, false
	for _, r := range rows {
		hook = hook || (r.Level == "FAIL" && ((r.What == "configuration" && strings.Contains(r.Words, "env:NAME or file:/path")) || strings.Contains(r.What, "webhook.url")))
		token = token || (r.Level == "FAIL" && r.What == "configuration" && strings.Contains(r.Words, "doors.prometheus_metrics"))
	}
	if !hook || !token {
		t.Errorf("a dpapi: webhook url (FAIL %v) and an inline metrics token (FAIL %v):\n%s", hook, token, rowsText(rows))
	}
}

// TestInstanceRowsListNote: an answered connection whose list step failed (a detect refused, as on an Azure Synapse
// pool) carries a WARN with the note, never an OK row alone.
func TestInstanceRowsListNote(t *testing.T) {
	rows := instanceCheckRows("syn", web.CheckResult{OK: true, Detail: "connected", ListNote: "the server's detect failed (engine edition 6 is Azure Synapse Analytics)"}, "")
	if len(rows) != 2 || rows[0].Level != "OK" || rows[1].Level != "WARN" || !strings.Contains(rows[1].Words, "Synapse") {
		t.Errorf("rows %+v, want OK then a WARN with the note", rows)
	}
}

// TestReferenceRowsUnderInstance: under -instance, the instances not tested have no row of their own, so their dsn is
// judged as a reference.
func TestReferenceRowsUnderInstance(t *testing.T) {
	t.Setenv("L241_PG1_SET", "host=pg1 user=u")
	unsetEnv(t, "L241_PG2_UNSET")
	p := checkYaml(t, t.TempDir(), "repository:\n  dsn: \"host=127.0.0.1 port=1 user=u dbname=d connect_timeout=1\"\ninstances:\n"+
		"  - name: pg1\n    dsn: env:L241_PG1_SET\n  - name: pg2\n    dsn: env:L241_PG2_UNSET\n")
	rows, _ := checkRun(context.Background(), testLog(), p, []string{"pg1"})
	if !rowWith(rows, "FAIL", "reference instances[pg2].dsn", `"L241_PG2_UNSET" is not set`) {
		t.Errorf("pg2's dsn, not tested under -instance pg1, is not judged as a reference:\n%s", rowsText(rows))
	}
}
