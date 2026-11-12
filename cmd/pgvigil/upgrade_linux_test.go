//go:build linux

package main

import "testing"

// The upgrade reads the installed unit's own paths and account (task 202, D8).

func TestParseUnit(t *testing.T) {
	o, found, err := parseUnit(renderUnit("/opt/pgv/bin/pgvigil", "/srv/pgv/etc/pgvigil/pgvigil.yaml", "/srv/pgv/etc/pgvigil/pgvigil.env", "svc_pgv"))
	if err != nil || !found {
		t.Fatalf("found %v err %v", found, err)
	}
	if o.Bin != "/opt/pgv/bin/pgvigil" || o.Config != "/srv/pgv/etc/pgvigil/pgvigil.yaml" || o.User != "svc_pgv" {
		t.Errorf("got %+v", o)
	}
	if _, _, err := parseUnit("[Service]\nExecStart=/usr/bin/other\n"); err == nil {
		t.Error("a foreign unit was taken for the installer's")
	}
}
