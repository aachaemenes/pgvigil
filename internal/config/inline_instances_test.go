package config

import (
	"strings"
	"testing"
)

// TestInlinePasswordInstances (L9): the names of the PostgreSQL instances whose dsn carries an inline password, in
// the file's order - never one whose dsn comes through env: or file:, one without a password, or a sqlserver instance.
func TestInlinePasswordInstances(t *testing.T) {
	c := &Config{Instances: []Instance{
		{Name: "a", DSNRaw: "host=h password=x"},
		{Name: "b", DSNRaw: "env:B"},
		{Name: "c", Engine: EnginePostgres, DSNRaw: " postgres://u:p@h/d "},
		{Name: "d", DSNRaw: "file:/x"},
		{Name: "e", DSNRaw: "host=h"},
		{Name: "f", Engine: EngineSQLServer, DSNRaw: "server=h;user id=u"},
	}}
	if got := strings.Join(c.InlinePasswordInstances(), ","); got != "a,c" {
		t.Errorf("InlinePasswordInstances = %q, want a,c", got)
	}
}
