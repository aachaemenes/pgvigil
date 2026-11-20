package config

import (
	"slices"
	"strings"
	"testing"
)

// B24p: the aws: and azure: blocks of a page instance (0193). The doors: every
// page block is dropped while doors.page_cloud_blocks is off; a block's target must be the instance's own host by
// name; a profile only when doors.page_aws_profiles lists it. A dropped block never drops the instance.

func pgPage(host string, aws *PageAWS) PageInstance {
	return PageInstance{Name: "pg1", Engine: EnginePostgres, Platform: "rds", DSNRef: "file:/x/pg1.dsn", Host: host, AWS: aws}
}

func msPage(host string, az *PageAzure) PageInstance {
	return PageInstance{Name: "ms1", Engine: EngineSQLServer, Platform: "azuresqldb", DSNRef: "file:/x/ms1.dsn", Host: host, Azure: az}
}

// A block set, edited or cleared changes the instance's Fingerprint, so Diff restarts
// its loops (a collection whose Configured was false had no loop).
func TestFingerprintHoldsTheBlocks(t *testing.T) {
	base := Instance{Name: "a", Engine: EnginePostgres, Platform: "rds", DSNRaw: "file:/x"}
	withAWS := base
	withAWS.AWS = &AWS{Region: "us-east-2", DBInstance: "db1"}
	edited := base
	edited.AWS = &AWS{Region: "us-east-2", DBInstance: "db2"}
	prof := base
	prof.AWS = &AWS{Region: "us-east-2", DBInstance: "db1", Profile: "p"}
	ms := Instance{Name: "m", Engine: EngineSQLServer, Platform: "azuresqldb", DSNRaw: "file:/x"}
	withAz := ms
	withAz.Azure = &Azure{Subscription: "s", ResourceGroup: "g", Server: "srv"}
	cloud := ms
	cloud.Azure = &Azure{Subscription: "s", ResourceGroup: "g", Server: "srv", Cloud: "usgov"}
	for _, c := range []struct {
		what   string
		before Instance
		after  Instance
	}{
		{"aws set", base, withAWS}, {"aws edited", withAWS, edited}, {"aws profile", withAWS, prof}, {"aws cleared", withAWS, base},
		{"azure set", ms, withAz}, {"azure cloud", withAz, cloud}, {"azure cleared", withAz, ms},
	} {
		stop, start := Diff([]Instance{c.before}, []Instance{c.after})
		if len(stop) != 1 || len(start) != 1 {
			t.Errorf("%s: stop %v start %v, want the instance in both", c.what, stop, start)
		}
	}
}

// The switch off (the default): every page block dropped with its reason, the instance kept.
func TestPageCloudSwitchOff(t *testing.T) {
	SetPageCloud(Doors{})
	all, skipped, dropped := MergeNotes(nil, []PageInstance{pgPage("db1.abc.us-east-2.rds.amazonaws.com", &PageAWS{Region: "us-east-2", DBInstance: "db1"})}, "", CounterEdits{})
	if len(all) != 1 || len(skipped) != 0 || all[0].AWS != nil {
		t.Fatalf("switch off: %+v skipped %v, want the instance kept without its block", all, skipped)
	}
	if len(dropped) != 1 || !strings.Contains(dropped[0], "page_cloud_blocks") {
		t.Errorf("switch off: dropped %v, want one reason naming doors.page_cloud_blocks", dropped)
	}
}

// The switch on: a block whose target is the instance's own host is set on the Instance (every field copied); one
// whose target is another host, or a host that is not the provider's name (a CNAME, a private DNS name), is dropped
// with both names.
func TestPageCloudNameMatch(t *testing.T) {
	SetPageCloud(Doors{PageCloudBlocks: true})
	defer SetPageCloud(Doors{})
	for _, c := range []struct {
		what string
		p    PageInstance
		ok   bool
	}{
		{"an RDS instance's endpoint", pgPage("db1.c9akciq32.us-east-2.rds.amazonaws.com", &PageAWS{Region: "us-east-2", DBInstance: "db1"}), true},
		{"case folded", pgPage("DB1.c9akciq32.us-east-2.rds.amazonaws.com", &PageAWS{Region: "us-east-2", DBInstance: "db1"}), true},
		{"an Aurora cluster's writer endpoint", pgPage("dba-lab-pg.cluster-c9akciq32.us-east-2.rds.amazonaws.com", &PageAWS{Region: "us-east-2", Cluster: "dba-lab-pg", DBInstance: "dba-lab-pg-1"}), true},
		{"an Aurora cluster's reader endpoint", pgPage("dba-lab-pg.cluster-ro-c9akciq32.us-east-2.rds.amazonaws.com", &PageAWS{Region: "us-east-2", Cluster: "dba-lab-pg"}), true},
		{"a member's own endpoint", pgPage("dba-lab-pg-1.c9akciq32.us-east-2.rds.amazonaws.com", &PageAWS{Region: "us-east-2", Cluster: "dba-lab-pg", DBInstance: "dba-lab-pg-1"}), true},
		// the China partition's instance form is not confirmed (AWS China's RDS pages show only
		// global examples): both orders pass the name, the provider's Endpoint.Address decides (collect.checkPageAWS)
		{"the China partition, the region first", pgPage("db1.c9akciq32.cn-north-1.rds.amazonaws.com.cn", &PageAWS{Region: "cn-north-1", DBInstance: "db1"}), true},
		{"the China partition, the service first", pgPage("db1.c9akciq32.rds.cn-north-1.amazonaws.com.cn", &PageAWS{Region: "cn-north-1", DBInstance: "db1"}), true},
		{"a China host for a global region", pgPage("db1.c9akciq32.rds.us-east-2.amazonaws.com.cn", &PageAWS{Region: "us-east-2", DBInstance: "db1"}), false},
		// an instance endpoint names its DB instance, a cluster endpoint its cluster - the other name
		// is the provider's to confirm, never the first label's
		{"a cluster-only block on an instance endpoint of the same name", pgPage("dba-lab-pg.c9akciq32.us-east-2.rds.amazonaws.com", &PageAWS{Region: "us-east-2", Cluster: "dba-lab-pg"}), false},
		{"a db_instance-only block on a cluster endpoint of the same name", pgPage("dba-lab-pg.cluster-c9akciq32.us-east-2.rds.amazonaws.com", &PageAWS{Region: "us-east-2", DBInstance: "dba-lab-pg"}), false},
		// a custom endpoint's first label is the endpoint's own name, not its cluster's
		{"a custom endpoint", pgPage("reporting.cluster-custom-c9akciq32.us-east-2.rds.amazonaws.com", &PageAWS{Region: "us-east-2", Cluster: "reporting"}), false},
		{"another instance", pgPage("db2.c9akciq32.us-east-2.rds.amazonaws.com", &PageAWS{Region: "us-east-2", DBInstance: "db1"}), false},
		{"another region", pgPage("db1.c9akciq32.us-west-2.rds.amazonaws.com", &PageAWS{Region: "us-east-2", DBInstance: "db1"}), false},
		{"a CNAME", pgPage("billing-db.corp.example", &PageAWS{Region: "us-east-2", DBInstance: "db1"}), false},
		{"an address", pgPage("10.0.0.5", &PageAWS{Region: "us-east-2", DBInstance: "db1"}), false},
		{"an Azure server's host", msPage("srv1.database.windows.net", &PageAzure{Subscription: "0b1f6471-1bf0-4dda-aec3-111122223333", ResourceGroup: "rg-1", Server: "srv1"}), true},
		{"Azure US Government", msPage("srv1.database.usgovcloudapi.net", &PageAzure{Subscription: "0b1f6471-1bf0-4dda-aec3-111122223333", ResourceGroup: "rg-1", Server: "srv1", Cloud: "usgov"}), true},
		{"Azure's public suffix on usgov", msPage("srv1.database.windows.net", &PageAzure{Subscription: "0b1f6471-1bf0-4dda-aec3-111122223333", ResourceGroup: "rg-1", Server: "srv1", Cloud: "usgov"}), false},
		{"another Azure server", msPage("srv2.database.windows.net", &PageAzure{Subscription: "0b1f6471-1bf0-4dda-aec3-111122223333", ResourceGroup: "rg-1", Server: "srv1"}), false},
		{"a private DNS name", msPage("srv1.privatelink.database.windows.net", &PageAzure{Subscription: "0b1f6471-1bf0-4dda-aec3-111122223333", ResourceGroup: "rg-1", Server: "srv1"}), false},
	} {
		all, skipped, dropped := MergeNotes(nil, []PageInstance{c.p}, "", CounterEdits{})
		if len(all) != 1 || len(skipped) != 0 {
			t.Errorf("%s: %+v skipped %v: the instance must be kept either way", c.what, all, skipped)
			continue
		}
		got := all[0].AWS != nil || all[0].Azure != nil
		if got != c.ok {
			t.Errorf("%s: block kept %v (dropped %v), want %v", c.what, got, dropped, c.ok)
		}
		if !c.ok && (len(dropped) != 1 || !strings.Contains(dropped[0], c.p.Host)) {
			t.Errorf("%s: dropped %v, want one reason naming the host %s", c.what, dropped, c.p.Host)
		}
	}
	all, _, _ := MergeNotes(nil, []PageInstance{pgPage("dba-lab-pg.cluster-c9akciq32.us-east-2.rds.amazonaws.com", &PageAWS{Region: "us-east-2", Cluster: "dba-lab-pg", DBInstance: "dba-lab-pg-1"})}, "", CounterEdits{})
	if a := all[0].AWS; a == nil || a.Region != "us-east-2" || a.Cluster != "dba-lab-pg" || a.DBInstance != "dba-lab-pg-1" || a.Profile != "" {
		t.Errorf("the aws block's fields: %+v", a)
	}
	// fold 1: the instance carries the page row's host, so the collector checks the block against the provider first
	if all[0].PageAWSHost != "dba-lab-pg.cluster-c9akciq32.us-east-2.rds.amazonaws.com" {
		t.Errorf("the page block's host mark: %q", all[0].PageAWSHost)
	}
	if all, _, _ := MergeNotes([]Instance{{Name: "f", Engine: EnginePostgres, AWS: &AWS{Region: "us-east-2", DBInstance: "db1"}}}, nil, "", CounterEdits{}); all[0].PageAWSHost != "" {
		t.Errorf("a file instance's block carries the page mark %q (pgvigil.yaml's block is its own door)", all[0].PageAWSHost)
	}
	all, _, _ = MergeNotes(nil, []PageInstance{msPage("srv1.database.windows.net", &PageAzure{Subscription: "0b1f6471-1bf0-4dda-aec3-111122223333", ResourceGroup: "rg-1", Server: "srv1"})}, "", CounterEdits{})
	if a := all[0].Azure; a == nil || a.Subscription != "0b1f6471-1bf0-4dda-aec3-111122223333" || a.ResourceGroup != "rg-1" || a.Server != "srv1" {
		t.Errorf("the azure block's fields: %+v", a)
	}
}

// the guard: a page block's profile only when pgvigil.yaml's doors.page_aws_profiles lists it (empty = none).
func TestPageCloudProfile(t *testing.T) {
	host := "db1.c9akciq32.us-east-2.rds.amazonaws.com"
	p := pgPage(host, &PageAWS{Region: "us-east-2", DBInstance: "db1", Profile: "prod-read"})
	SetPageCloud(Doors{PageCloudBlocks: true})
	defer SetPageCloud(Doors{})
	all, _, dropped := MergeNotes(nil, []PageInstance{p}, "", CounterEdits{})
	if all[0].AWS != nil || len(dropped) != 1 || !strings.Contains(dropped[0], "page_aws_profiles") {
		t.Errorf("an unlisted profile: %+v %v, want the block dropped naming doors.page_aws_profiles", all[0].AWS, dropped)
	}
	SetPageCloud(Doors{PageCloudBlocks: true, PageAWSProfiles: []string{"prod-read"}})
	all, _, dropped = MergeNotes(nil, []PageInstance{p}, "", CounterEdits{})
	if all[0].AWS == nil || all[0].AWS.Profile != "prod-read" || len(dropped) != 0 {
		t.Errorf("a listed profile: %+v %v", all[0].AWS, dropped)
	}
}

// The store's rules = Go's: aws on PostgreSQL only (until 390b), azure on an azuresqldb SQL Server only; the
// shapes (an RDS identifier, a region, an Azure server, a resource group, a subscription id); a block the store takes
// passes here, one it refuses is refused here with the same reason.
func TestPageCloudShape(t *testing.T) {
	sub := "0b1f6471-1bf0-4dda-aec3-111122223333"
	for _, c := range []struct {
		what   string
		p      PageInstance
		refuse string
	}{
		{"aws on PostgreSQL", pgPage("h", &PageAWS{Region: "us-east-2", DBInstance: "db1"}), ""},
		{"aws on SQL Server", PageInstance{Name: "m", Engine: EngineSQLServer, Platform: "rds", AWS: &PageAWS{Region: "us-east-2", DBInstance: "db1"}}, "PostgreSQL"},
		{"azure on PostgreSQL", PageInstance{Name: "p", Engine: EnginePostgres, Platform: "azure", Azure: &PageAzure{Subscription: sub, ResourceGroup: "g", Server: "s"}}, "azuresqldb"},
		{"azure on a SQL Server that is not azuresqldb", PageInstance{Name: "m", Engine: EngineSQLServer, Platform: "auto", Azure: &PageAzure{Subscription: sub, ResourceGroup: "g", Server: "s"}}, "azuresqldb"},
		{"aws without an identifier", pgPage("h", &PageAWS{Region: "us-east-2"}), "db_instance or cluster"},
		{"a bad region", pgPage("h", &PageAWS{Region: "east", DBInstance: "db1"}), "region"},
		{"a bad identifier", pgPage("h", &PageAWS{Region: "us-east-2", DBInstance: "db--1"}), "identifier"},
		{"an identifier ending in a hyphen", pgPage("h", &PageAWS{Region: "us-east-2", Cluster: "c1-"}), "identifier"},
		{"azure without its server", msPage("h", &PageAzure{Subscription: sub, ResourceGroup: "g"}), "server"},
		{"a bad subscription", msPage("h", &PageAzure{Subscription: "not-a-guid", ResourceGroup: "g", Server: "s"}), "subscription"},
		{"an upper-case server", msPage("h", &PageAzure{Subscription: sub, ResourceGroup: "g", Server: "Srv"}), "server"},
		{"a resource group ending in a dot", msPage("h", &PageAzure{Subscription: sub, ResourceGroup: "g.", Server: "s"}), "resource_group"},
		{"an unknown cloud", msPage("h", &PageAzure{Subscription: sub, ResourceGroup: "g", Server: "s", Cloud: "moon"}), "cloud"},
		// the store's rules, rule for rule - an ASCII resource group, a cloud name as written
		{"a resource group with a letter outside ASCII", msPage("h", &PageAzure{Subscription: sub, ResourceGroup: "rg-\u00e9", Server: "s"}), "resource_group"},
		{"a resource group with parentheses", msPage("h", &PageAzure{Subscription: sub, ResourceGroup: "rg_(1).a", Server: "s"}), ""},
		{"a cloud name with a space", msPage("h", &PageAzure{Subscription: sub, ResourceGroup: "g", Server: "s", Cloud: " public"}), "cloud"},
	} {
		why := PageCloudShape(c.p)
		switch {
		case c.refuse == "" && why != "":
			t.Errorf("%s: refused: %s", c.what, why)
		case c.refuse != "" && !strings.Contains(why, c.refuse):
			t.Errorf("%s: %q, want a refusal naming %q", c.what, why, c.refuse)
		}
	}
}

// The shared scan: both inventory readers name the same columns, the blocks and the host among them.
func TestInventoryColumns(t *testing.T) {
	for _, col := range []string{"name", "engine", "platform", "dsn_ref", "tags", "disabled", "auth", "options", "generation", "running_plans", "host", "aws", "azure"} {
		if !slices.Contains(strings.Fields(strings.NewReplacer(",", " ").Replace(InventorySQL)), col) {
			t.Errorf("InventorySQL does not read %s", col)
		}
	}
}
