package main

import (
	"context"
	"strings"
	"testing"
)

func TestTagOps(t *testing.T) {
	ops, err := tagOps([]string{"ENV=prod", "team=a, b ,a", "-dc", "tag=prod,erp"}, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(ops) != 4 || ops[0].Key != "env" || ops[0].Vals[0] != "prod" || len(ops[1].Vals) != 2 || ops[1].Vals[1] != "b" ||
		!ops[2].Hide || ops[2].Key != "dc" || ops[3].Key != "tag" || len(ops[3].Vals) != 2 {
		t.Fatalf("ops: %+v", ops)
	}
	r, err := tagOps([]string{"env", "team"}, true)
	if err != nil || len(r) != 2 || !r[0].Reset {
		t.Fatalf("reset: %+v %v", r, err)
	}
	for _, bad := range [][]string{{"env"}, {"env="}, {"=prod"}, {"Env Name=x"}, {"env=a", "env=b"}, {"env=a,,b"}, {"-"}} {
		if _, err := tagOps(bad, false); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
	if _, err := tagOps(nil, true); err == nil {
		t.Error("-reset without keys accepted")
	}
}

func TestRunTagUsage(t *testing.T) {
	if err := runTag(context.Background(), []string{"-config", "/nonexistent.yaml"}); err == nil || !strings.Contains(err.Error(), "usage") {
		t.Fatalf("no instance: %v", err)
	}
	if err := runTag(context.Background(), []string{"-config", "/nonexistent.yaml", "x", "bad"}); err == nil || !strings.Contains(err.Error(), "key=value") {
		t.Fatalf("a bad op: %v", err)
	}
}
