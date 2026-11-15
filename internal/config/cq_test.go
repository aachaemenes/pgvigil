package config

import (
	"strings"
	"testing"
)

// The request queue's keys: the defaults (actions.via direct, cq.workers 4, cq.result_keep read), the bounds and words
// of a bad value, and ST4's allow-lists (all / none alone; jobs '*' and '-name'; a tool list takes no '*').
func TestValidateCQ(t *testing.T) {
	c := Config{Instances: []Instance{{Name: "a"}}}
	if err := c.validateCQ(); err != nil || c.Actions.Via != "direct" || c.CQ.Workers != 4 || c.CQ.ResultKeep != "read" || c.CQ.Enabled {
		t.Fatalf("defaults: %+v %+v %v", c.Actions, c.CQ, err)
	}
	for _, tc := range []struct {
		c    Config
		want string
	}{
		{Config{Actions: ActionsVia{Via: "queued"}}, "actions.via must be direct or queue"},
		{Config{CQ: CQ{Workers: 17}}, "cq.workers must be 1 to 16"},
		{Config{CQ: CQ{Workers: -1}}, "cq.workers must be 1 to 16"},
		{Config{CQ: CQ{ResultKeep: "30d"}}, "cq.result_keep must be read or 7d"},
		{Config{Instances: []Instance{{Name: "a", CommunityAllow: []string{"all", "sp_Blitz"}}}}, `instance "a": community_allow: all stands alone`},
		{Config{Instances: []Instance{{Name: "a", CommunityAllow: []string{"*"}}}}, "the community list takes all, none or tool names"},
		{Config{Instances: []Instance{{Name: "a", JobsAllow: []string{" "}}}}, `instance "a": jobs_allow: an empty entry`},
	} {
		if err := tc.c.validateCQ(); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Fatalf("%+v: %v, want %q", tc.c, err, tc.want)
		}
	}
	if !(ActionsVia{Via: "queue"}).Queue() || (ActionsVia{Via: "direct"}).Queue() {
		t.Fatal("Queue()")
	}
}

func TestAllowed(t *testing.T) {
	for _, tc := range []struct {
		list []string
		name string
		def  bool
		ok   bool
		why  string
	}{
		{nil, "sp_Blitz", true, true, ""},
		{nil, "sp_Blitz", false, false, "community_allow is not set"},
		{[]string{"all"}, "sp_Blitz", false, true, ""},
		{[]string{"none"}, "sp_Blitz", true, false, "community_allow is none"},
		{[]string{"sp_WhoIsActive", "SP_BLITZ"}, "sp_Blitz", false, true, ""},
		{[]string{"sp_WhoIsActive"}, "sp_Blitz", true, false, "sp_Blitz is not in community_allow"},
		{[]string{"*", "-nightly etl"}, "Nightly ETL", false, false, "community_allow excludes Nightly ETL"},
		{[]string{"*", "-nightly etl"}, "backup", false, true, ""},
	} {
		ok, why := Allowed(tc.list, tc.name, "community_allow", tc.def)
		if ok != tc.ok || (tc.why != "" && !strings.Contains(why, tc.why)) {
			t.Fatalf("Allowed(%v, %q, %v) = %v %q, want %v %q", tc.list, tc.name, tc.def, ok, why, tc.ok, tc.why)
		}
	}
}
