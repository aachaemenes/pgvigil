package sched

import (
	"reflect"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// A configured application: tag is named (the collector logs it at the instance's start); other tags are not.
func TestApplicationTags(t *testing.T) {
	in := config.Instance{Name: "p", Tags: []string{"env:prod", "Application: Billing System: EU", "application:Payroll", "applications:x", "plain"}}
	if got, want := applicationTags(in), []string{"application:Billing System: EU", "application:Payroll"}; !reflect.DeepEqual(got, want) {
		t.Errorf("applicationTags = %q, want %q", got, want)
	}
	if got := applicationTags(config.Instance{Name: "q", Tags: []string{"env:test"}}); got != nil {
		t.Errorf("no application tag: %q", got)
	}
}
