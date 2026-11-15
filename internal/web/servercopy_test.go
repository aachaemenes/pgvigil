package web

import (
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/actions"
	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// TestServerCopyKeepsSideMaps: report mail renders a page through a copy of the server (renderCopy: no Host list, no
// TLS, on loopback), and six of the server's settings live in maps keyed by *Server, set by serve after Open - the door
// set and its watcher's wake channel, the PostgreSQL job allow lists, the Plan page's configuration, the SQL Server
// door and Admin > Instances' settings. Each one read through the copy is the server's own (uidoor-u7: a mailed custom
// report on a page instance was refused 'in neither pgvigil.yaml nor Admin > Instances', door ”, generation 0 - the
// copy found no door set and fell back to pgvigil.yaml's). The rule: a map keyed by *Server keys by s.self().
func TestServerCopyKeepsSideMaps(t *testing.T) {
	s := &Server{}
	ds := &doorSet{Gen: 41, PG: map[string]actions.Door{}, MS: map[string]mssql.Door{}, NoDoor: map[string]noDoor{}}
	s.storeDoors(ds)
	wake := make(chan struct{}, 1)
	doorWake.Store(s, wake) // as WatchDoors does
	s.SetPgJobActions(map[string][]string{"pg1": {collect.JobStop}})
	s.SetPlans(PlansConfig{DefaultQueryText: "full"})
	s.SetMSSQLActions(map[string]mssql.Door{})
	s.SetInstancesAdmin(InstancesAdmin{ConfigPath: "/srv/pgvigil/pgvigil.yaml"})
	t.Cleanup(func() {
		for _, m := range []*sync.Map{&doorSets, &doorWake, &pgJobAllow, &plansConfigs, &mssqlActions, &instancesAdmins} {
			m.Delete(s)
		}
	})

	c := s.renderCopy()
	if c == s || c.hosts != nil || c.tls {
		t.Fatalf("renderCopy: the server itself or its Host list / TLS kept (%v %v %v)", c == s, c.hosts, c.tls)
	}
	var bad []string
	if c.doorsNow() != ds {
		bad = append(bad, "the door set (doorSets: generation "+strconv.FormatInt(c.doorsNow().Gen, 10)+", want 41)")
	}
	c.wakeDoors(0, 0)
	if len(wake) != 1 {
		bad = append(bad, "the watcher's wake (doorWake)")
	}
	if !c.fileDoors().PgJobs["pg1"][collect.JobStop] {
		bad = append(bad, "the PostgreSQL job allow lists (pgJobAllow)")
	}
	if c.plansConfig().DefaultQueryText != "full" {
		bad = append(bad, "the Plan page's configuration (plansConfigs)")
	}
	if c.mssqlDoor() != s.mssqlDoor() {
		bad = append(bad, "the SQL Server door (mssqlActions)")
	}
	if c.instAdmin() != s.instAdmin() {
		bad = append(bad, "Admin > Instances' settings (instancesAdmins)")
	}
	if len(bad) > 0 {
		t.Errorf("a render's copy of the server misses %d of its six side maps: %s", len(bad), strings.Join(bad, "; "))
	}
	if c2 := c.renderCopy(); c2.origin != s {
		t.Errorf("a copy of a copy names %p as its origin, want the server %p", c2.origin, s)
	}
}
