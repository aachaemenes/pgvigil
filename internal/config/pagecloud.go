package config

// The cloud blocks of a page instance (task B24p, 0193): the aws: and azure: blocks an instance of Admin > Instances
// carries, kept in pgvigil.admin_instance_cloud and read through admin_inventory(). A cloud block runs the COLLECTOR
// HOST's own SDK chain (CloudWatch, Performance Insights, Resource Manager), while a page instance may be added by any
// signed-in user (pagedoor.go: its door reaches only what its user typed). So, under the locked-down default:
//
//   - pgvigil.yaml's doors.page_cloud_blocks, off by default, lets a page block be used at all;
//   - a block's target must be the instance's own host BY NAME at the merge: an RDS instance endpoint
//     <db_instance>.<x>.<region>.rds.<the partition's domain> or a cluster's writer / reader endpoint
//     <cluster>.cluster-[ro-]<x>.<region>.rds.<the partition's domain> (China: its .cn domain, either order of the
//     region and 'rds'), an Azure SQL logical server <server>.database.windows.net (.usgovcloudapi.net, .chinacloudapi.cn);
//     a custom endpoint, a CNAME, a private DNS name or an address refuses the block with both names (pgvigil.yaml's
//     block stays the door there);
//   - and an aws: block, which names a resource of the collector host's own account, is checked again by the
//     collector against the provider's answer before its first read (collect.pageAWSVerdict:
//     an RDS name is unique only inside one account): the host must be that instance's Endpoint.Address or that
//     cluster's endpoint, and a block naming both must name an instance of the cluster;
//   - a block's AWS profile only when doors.page_aws_profiles lists it (a discovered instance's source profile).
//
// A refused block is DROPPED with its reason (logged by the collector, shown on the page); the instance keeps
// collecting. The shape rules (PageCloudShape) are the store's own (0193's admin_cloud_shape), rule for rule.

import (
	"encoding/json"
	"fmt"
	"net"
	"regexp"
	"slices"
	"strings"
	"sync/atomic"
)

// PageAWS is a page instance's aws: block as the store keeps it (json: encoding/json does not read the yaml tags):
// the file's keys minus log_group and dms, which stay pgvigil.yaml's.
type PageAWS struct {
	Region     string `json:"region"`
	Profile    string `json:"profile,omitempty"`
	Cluster    string `json:"cluster,omitempty"`
	DBInstance string `json:"db_instance,omitempty"`
}

// PageAzure is a page instance's azure: block as the store keeps it.
type PageAzure struct {
	Subscription  string `json:"subscription"`
	ResourceGroup string `json:"resource_group"`
	Server        string `json:"server"`
	Cloud         string `json:"cloud,omitempty"`
}

// pageCloudDoor is the process's doors for page blocks (SetPageCloud; nil = off)
var pageCloudDoor atomic.Pointer[Doors]

// SetPageCloud takes pgvigil.yaml's doors for the page's cloud blocks (Load calls it; a test sets its own).
func SetPageCloud(d Doors) {
	d.PageAWSProfiles = slices.Clone(d.PageAWSProfiles)
	pageCloudDoor.Store(&d)
}

// PageCloudOn says whether this install's pgvigil.yaml lets page instances carry cloud blocks.
func PageCloudOn() bool {
	d := pageCloudDoor.Load()
	return d != nil && d.PageCloudBlocks
}

// PageAWSProfileListed says whether pgvigil.yaml's doors.page_aws_profiles lists the profile.
func PageAWSProfileListed(profile string) bool {
	d := pageCloudDoor.Load()
	return d != nil && slices.Contains(d.PageAWSProfiles, profile)
}

// PageCloudBlocksOff is the refusal while the switch is off.
const PageCloudBlocksOff = "off on this install: doors.page_cloud_blocks in pgvigil.yaml lets an instance of Admin > Instances carry an aws: or azure: block (its reads run under this host's own cloud identity)"

var (
	awsRegion   = regexp.MustCompile(`^[a-z]{2}(-gov|-iso[a-z]?)?-[a-z]+-[0-9]{1,2}$`)
	rdsID       = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9-]{0,62}$`)
	awsProfile  = regexp.MustCompile(`^[A-Za-z0-9_.+@-]{1,64}$`)
	azureSub    = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)
	azureGroup  = regexp.MustCompile(`^[-A-Za-z0-9_.()]{1,90}$`) // the store's class (0193), ASCII whatever its collation
	azureServer = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)
	azureSuffix = map[string]string{"": ".database.windows.net", "public": ".database.windows.net", "usgov": ".database.usgovcloudapi.net", "china": ".database.chinacloudapi.cn"}
	// an instance's or a cluster's endpoint: <id>.[cluster-[ro-]]<x>.<region>.rds.<the partition's domain>, the China
	// partition's .cn domain in either order (<region>.rds. or rds.<region>.: AWS China's RDS pages show no instance
	// example; the provider's own Endpoint.Address decides at the collector); a custom endpoint is not matched (its
	// first label is the endpoint's own name, not its cluster's)
	rdsEndpoint = regexp.MustCompile(`^([a-z][a-z0-9-]*)\.(cluster-(?:ro-)?)?[a-z0-9]+\.(?:([a-z0-9-]+)\.rds\.amazonaws\.com|([a-z0-9-]+)\.rds\.amazonaws\.com\.cn|rds\.([a-z0-9-]+)\.amazonaws\.com\.cn)$`)
)

// identifierOK: an RDS DB instance or cluster identifier (a letter, then letters, digits and single hyphens, no
// trailing hyphen, 63 at most)
func identifierOK(id string) bool {
	return rdsID.MatchString(id) && !strings.Contains(id, "--") && !strings.HasSuffix(id, "-")
}

// PageCloudShape is the store's rules for a page instance's blocks (0193's admin_cloud_shape): the reason a block is
// refused, or "".
func PageCloudShape(p PageInstance) string {
	if a := p.AWS; a != nil {
		switch {
		case p.Engine != EnginePostgres:
			return "the aws: block is PostgreSQL's (on SQL Server it waits for its own reads)"
		case !awsRegion.MatchString(a.Region):
			return fmt.Sprintf("aws.region %s is not an AWS region code", orNone(a.Region))
		case a.DBInstance == "" && a.Cluster == "":
			return "the aws: block names its db_instance or cluster"
		case a.Profile != "" && !awsProfile.MatchString(a.Profile):
			return fmt.Sprintf("aws.profile %s is not a profile name", a.Profile)
		}
		for _, id := range []string{a.DBInstance, a.Cluster} {
			if id != "" && !identifierOK(id) {
				return fmt.Sprintf("%s is not an RDS identifier (a letter, then letters, digits and single hyphens, 63 at most, no trailing hyphen)", id)
			}
		}
	}
	if a := p.Azure; a != nil {
		switch {
		case p.Engine != EngineSQLServer || p.Platform != "azuresqldb":
			return "the azure: block is an Azure SQL Database's (a SQL Server instance of platform azuresqldb)"
		case !azureSub.MatchString(a.Subscription):
			return fmt.Sprintf("azure.subscription %s is not a subscription id", orNone(a.Subscription))
		case !azureGroup.MatchString(a.ResourceGroup) || strings.HasSuffix(a.ResourceGroup, "."):
			return fmt.Sprintf("azure.resource_group %s is not a resource group name (1-90 letters, digits, . ( ) _ -, no trailing dot)", orNone(a.ResourceGroup))
		case !azureServer.MatchString(a.Server):
			return fmt.Sprintf("azure.server %s is not a logical server's name (1-63 lower-case letters, digits and hyphens)", orNone(a.Server))
		case !validAzureCloud(a.Cloud) || a.Cloud != strings.ToLower(strings.TrimSpace(a.Cloud)):
			return fmt.Sprintf("azure.cloud is public, usgov or china, not %s", a.Cloud)
		}
	}
	return ""
}

func orNone(s string) string {
	if s == "" {
		return "(none)"
	}
	return s
}

// PageCloudRefusal is why a page instance's blocks are not used on this host ("" = they are): the switch, the
// shape, the profile guard, then the name match of each block's target to the instance's own host.
func PageCloudRefusal(p PageInstance) string {
	if p.AWS == nil && p.Azure == nil {
		return ""
	}
	d := pageCloudDoor.Load()
	if d == nil || !d.PageCloudBlocks {
		return PageCloudBlocksOff
	}
	if why := PageCloudShape(p); why != "" {
		return why
	}
	host := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(p.Host), "."))
	if a := p.AWS; a != nil {
		if a.Profile != "" && !slices.Contains(d.PageAWSProfiles, a.Profile) {
			return fmt.Sprintf("the AWS profile %s is not listed in doors.page_aws_profiles in pgvigil.yaml (a page block reads with the host's default chain unless the file lists its profile)", a.Profile)
		}
		if why := rdsHostMatch(host, a); why != "" {
			return why
		}
	}
	if a := p.Azure; a != nil {
		suffix := azureSuffix[a.Cloud]
		if want := a.Server + suffix; host != want {
			return fmt.Sprintf("the azure: block names the server %s, but the instance's host is %s, not %s (a private DNS name or an alias cannot be matched: pgvigil.yaml's block is the door there)", a.Server, orNone(p.Host), want)
		}
	}
	return ""
}

// rdsHostMatch: the host is an RDS endpoint of the block's own db_instance or cluster in its region
func rdsHostMatch(host string, a *PageAWS) string {
	names := []string{}
	for _, n := range []string{a.DBInstance, a.Cluster} {
		if n != "" {
			names = append(names, n)
		}
	}
	want := fmt.Sprintf("%s.<x>.%s.rds.<the partition's domain>", strings.Join(names, " or "), a.Region)
	m := rdsEndpoint.FindStringSubmatch(host)
	if net.ParseIP(host) != nil || m == nil {
		return fmt.Sprintf("the aws: block names %s, but the instance's host %s is not an RDS endpoint (%s): an alias or an address cannot be matched, pgvigil.yaml's block is the door there", strings.Join(names, " / "), orNone(host), want)
	}
	id, isCluster, region, cn := m[1], m[2] != "", m[3], m[3] == ""
	if cn {
		region = m[4] + m[5]
	}
	ok := region == a.Region && cn == strings.HasPrefix(a.Region, "cn-")
	// an instance endpoint names its DB instance, a cluster endpoint its cluster; the block's other name is the
	// provider's to confirm (the collector's check), never the first label's
	switch {
	case isCluster:
		ok = ok && a.Cluster != "" && strings.EqualFold(id, a.Cluster)
	default:
		ok = ok && a.DBInstance != "" && strings.EqualFold(id, a.DBInstance)
	}
	if !ok {
		kind := "an instance endpoint names its db_instance"
		if isCluster {
			kind = "a cluster endpoint names its cluster"
		}
		return fmt.Sprintf("the aws: block names %s in %s, but the instance's host is %s (%s)", strings.Join(names, " / "), a.Region, host, kind)
	}
	return ""
}

// pageCloud sets a page instance's blocks on its Instance when PageCloudRefusal passes them, else gives the reason
func pageCloud(p PageInstance, in *Instance) string {
	if p.AWS == nil && p.Azure == nil {
		return ""
	}
	why := PageCloudRefusal(p)
	if why == "" {
		c := *in
		if a := p.AWS; a != nil {
			c.AWS = &AWS{Region: a.Region, Profile: a.Profile, Cluster: a.Cluster, DBInstance: a.DBInstance}
			c.PageAWSHost = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(p.Host), "."))
		}
		if a := p.Azure; a != nil {
			c.Azure = &Azure{Subscription: a.Subscription, ResourceGroup: a.ResourceGroup, Server: a.Server, Cloud: a.Cloud}
		}
		if err := validateCloud(c); err != nil {
			why = err.Error()
		} else {
			*in = c
			return ""
		}
	}
	return p.Name + ": its cloud block is not used: " + why
}

// InventorySQL is the page's list read by both readers - the collector's (repo.Inventory) and serve's own
// (web/doorset.go): one statement, one scan, so a column the store adds reaches both.
// ST5a (0263): each instance's own settings beside it (admin_instance_settings(), SECURITY DEFINER as admin_inventory())
// The columns are bare (TestInventoryColumns reads them as words): USING (name) makes name one column, and
// admin_instance_settings() returns only name and settings.
const InventorySQL = `SELECT name, engine, platform, dsn_ref, tags, disabled, auth, options, generation, running_plans, host, aws, azure, settings FROM pgvigil.admin_inventory() i LEFT JOIN pgvigil.admin_instance_settings() s USING (name) ORDER BY name`

// InventoryRows is what ScanInventory reads (pgx.Rows is one)
type InventoryRows interface {
	Next() bool
	Scan(dest ...any) error
	Err() error
}

// ScanInventory reads InventorySQL's rows: the page's instances and the generation (one row of NULLs beside the
// generation when the list is empty). A cloud block the store holds is decoded into its page struct; one that does not
// decode is left off with nothing set (the store's CHECKs and its import function keep that from happening).
func ScanInventory(rows InventoryRows) ([]PageInstance, int64, error) {
	var out []PageInstance
	var gen int64
	for rows.Next() {
		var name, engine, platform, ref, auth, options, host *string
		var tags []string
		var disabled, runningPlans *bool
		var aws, azure, settings []byte
		if err := rows.Scan(&name, &engine, &platform, &ref, &tags, &disabled, &auth, &options, &gen, &runningPlans, &host, &aws, &azure, &settings); err != nil {
			return nil, 0, err
		}
		if name == nil {
			continue
		}
		p := PageInstance{Name: *name, Tags: tags, Engine: deref(engine), Platform: deref(platform), DSNRef: deref(ref),
			Auth: deref(auth), Options: deref(options), Host: deref(host), SettingsRaw: settings}
		if disabled != nil {
			p.Disabled = *disabled
		}
		if runningPlans != nil {
			p.RunningPlans = *runningPlans
		}
		if len(aws) > 0 {
			var a PageAWS
			if json.Unmarshal(aws, &a) == nil {
				p.AWS = &a
			}
		}
		if len(azure) > 0 {
			var a PageAzure
			if json.Unmarshal(azure, &a) == nil {
				p.Azure = &a
			}
		}
		out = append(out, p)
	}
	return out, gen, rows.Err()
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
