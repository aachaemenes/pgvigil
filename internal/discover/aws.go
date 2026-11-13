// Package discover finds the database servers of a cloud account (task 205; task 103 part 2) and hands each to
// Admin > Instances as a proposal (config.Proposal) a click approves: nothing is created, changed or connected to
// in the cloud - every call is a read (AWS Describe*, Azure Resource Graph's query endpoint, GCP list calls).
//
//   - AWS (aws.go): RDS and Aurora DB instances, PostgreSQL and SQL Server, each by its own endpoint, in the regions
//     the source keeps (swept at its first read: rds:DescribeSourceRegions from the configuration's region and, when
//     granted, ec2:DescribeRegions: the account's enabled regions).
//   - Azure (azure.go): Azure SQL Database (each user database: one database is the instance), Azure SQL Managed
//     Instance and Azure Database for PostgreSQL flexible server, through Resource Graph.
//   - GCP (gcp.go): Cloud SQL (PostgreSQL and SQL Server) and AlloyDB, through the Cloud SQL Admin and AlloyDB APIs.
//
// Each answers a Read: the proposals, the notes of what it could not read (a region not enabled, an API not enabled,
// a permission missing, a region that did not answer) and the key prefixes of what it could not see, never failing
// the whole read for one of those unless nothing at all was read. The read-only rights each needs are in
// docs/discovery.md.
package discover

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// Read is one cloud read: the proposals, the notes (what it could not see, and why) and Unseen, the server key
// prefixes it could not see (a region, a subscription, a project's API that did not answer or refused): a proposal
// under one of them is kept as it was, never marked gone - a server not seen is not a server gone. Regions are the
// AWS regions that answered (a sweep stores them in the source), Scopes the Azure subscriptions a complete read saw,
// TagKeys the resource tag keys seen (the page offers them for the source's allow-list).
type Read struct {
	Proposals []config.Proposal
	Notes     []string
	Unseen    []string
	Regions   []string
	Scopes    []string
	TagKeys   []string
	// Swept: an AWS sweep that listed the partition's regions (only then are Regions the source's from now on);
	// Partition: the AWS credentials' partition, from sts:GetCallerIdentity's ARN (a region's partition is never
	// told from its name: the notes say the credentials')
	Swept     bool
	Partition string
	// Asked: the AWS regions this read asked or ruled out by the account's region list (a note about one of them
	// replaces its older note; a kept region not asked - Skip - keeps its note: task 205 D4 / D5)
	Asked []string
}

// AWSOptions names the credentials and the regions: Profile "" = the default chain (the environment, the shared
// files' default profile, an EC2 / ECS role). Regions empty = a sweep from the configuration's own region (the
// profile's, or AWS_REGION): rds:DescribeSourceRegions there lists its partition's regions (used when granted, never
// required). pgvigil names no region, partition or endpoint of its own (the join's TestNoHardCodedAWSPartition):
// GovCloud and the China regions are read exactly as the commercial ones, from the configuration (NOT PROVEN: no lab).
type AWSOptions struct {
	Profile string
	Regions []string
	// Start is the region a sweep starts from when the configuration names none (a source's first kept region)
	Start string
	// Keep are the regions the source keeps: a sweep reads them too, so one that cannot list loses none of them
	Keep []string
	// Skip are kept regions not asked this read (silent since the last sweep, task 205 D5): their servers are not
	// seen (never gone) and their notes are kept; a sweep asks them again
	Skip []string
	// client makes the RDS reader of a region (tests stand one in)
	client func(ctx context.Context, region string) (rdsAPI, error)
	// identity answers the credentials' account and partition (sts:GetCallerIdentity, which needs no right)
	identity func(ctx context.Context) (account, partition string, err error)
	// regionList answers the partition's regions as the account has them, true = enabled (ec2:DescribeRegions,
	// AllRegions; an optional right); nil = not asked (the tests that stand in no list)
	regionList func(ctx context.Context, region string) (map[string]bool, error)
	// seed is the configuration's own region (tests set it; else the loaded configuration's)
	seed string
	// callWait bounds each Describe call (awsCallWait when 0; tests shorten it)
	callWait time.Duration
}

// awsCallWait is how long one call (one page) may take: a region whose endpoint does not answer (seen: a connect
// timeout from one network, an answer from another) is a note after it. A read makes sts:GetCallerIdentity, a sweep
// rds:DescribeSourceRegions (its pages), then reads the regions all at once, each with two Describe calls (their
// pages) one after the other: on a slow network that can pass the 50 s of a read done while "Add the source" waits,
// and such a read is cut (nothing marked gone); the hourly read has 3 minutes.
const awsCallWait = 20 * time.Second

// awsListWait bounds the account's region list (ec2:DescribeRegions, optional): it is asked beside RDS's replication
// list on every read, so an EC2 host an egress-restricted collector cannot reach costs each read this, not a call's
// full wait (task 205's review).
const awsListWait = 5 * time.Second

// firstAsked is the first region a read asks: the first of regions not skipped (a region silent since the last sweep
// is not where STS and the region list go), else the first.
func firstAsked(regions []string, skip map[string]bool) string {
	for _, r := range regions {
		if !skip[r] {
			return r
		}
	}
	if len(regions) > 0 {
		return regions[0]
	}
	return ""
}

// errSilent is a Describe call that got no answer within its wait.
var errSilent = errors.New("no answer")

type rdsAPI interface {
	DescribeDBClusters(context.Context, *rds.DescribeDBClustersInput, ...func(*rds.Options)) (*rds.DescribeDBClustersOutput, error)
	DescribeDBInstances(context.Context, *rds.DescribeDBInstancesInput, ...func(*rds.Options)) (*rds.DescribeDBInstancesOutput, error)
	DescribeSourceRegions(context.Context, *rds.DescribeSourceRegionsInput, ...func(*rds.Options)) (*rds.DescribeSourceRegionsOutput, error)
}

// engineOf maps an RDS engine to pgvigil's; "" = not one pgvigil collects (MySQL, MariaDB, Oracle, Db2).
func engineOf(e string) string {
	switch {
	case e == "postgres" || e == "aurora-postgresql":
		return config.EnginePostgres
	case strings.HasPrefix(e, "sqlserver-"):
		return config.EngineSQLServer
	}
	return ""
}

var tagKeyBad = regexp.MustCompile(`[^a-z0-9_.-]+`)

// ReservedTagKeys are pgvigil's own tag keys on a cloud proposal: never taken from a resource's tags (a resource
// tag 'region' would otherwise add a second region, and alert rules are scoped by tags).
var ReservedTagKeys = map[string]bool{"cloud": true, "region": true, "account": true, "subscription": true, "resource-group": true,
	"project": true, "cluster": true, "role": true, "source-instance": true, "source-cluster": true}

// TagKey is a cloud tag key as pgvigil writes it: lower-cased, other characters as '-', 40 at most ("" = none).
func TagKey(k string) string {
	key := strings.Trim(tagKeyBad.ReplaceAllString(strings.ToLower(strings.TrimSpace(k)), "-"), "-")
	if len(key) > 40 {
		key = key[:40]
	}
	return key
}

// cloudTag makes a cloud tag a pgvigil tag (config.ParseTag's rule): the key by TagKey; the value without a comma
// or a control character, 100 at most. "" when nothing is left of the key or the value.
func cloudTag(k, v string) string {
	key := TagKey(k)
	if key == "" || key == "tag" {
		return ""
	}
	val := strings.TrimSpace(strings.Map(func(r rune) rune {
		if r == ',' || r < 0x20 || r == 0x7f {
			return ' '
		}
		return r
	}, v))
	val = strings.ToValidUTF8(val, "")
	for len(val) > 100 { // config.ParseTag counts bytes: cut at a character boundary, never inside one
		_, n := utf8.DecodeLastRuneInString(val)
		val = strings.TrimSpace(val[:len(val)-n])
	}
	if val == "" {
		return ""
	}
	return key + ":" + val
}

// TagsWith is a proposal's tags: pgvigil's own, plus the resource tags whose keys the source allows (task 205's
// design pass: an allow-list, none by default; a reserved key never from a resource).
func TagsWith(p config.Proposal, allow []string) []string {
	out := append([]string{}, p.Tags...)
	ok := map[string]bool{}
	for _, k := range allow {
		if k = TagKey(k); k != "" && !ReservedTagKeys[k] {
			ok[k] = true
		}
	}
	for k, v := range p.CloudTags {
		if ok[TagKey(k)] {
			if t := cloudTag(k, v); t != "" {
				out = append(out, t)
			}
		}
	}
	sort.Strings(out)
	return slices.Compact(out)
}

// tagKeysOf lists the resource tag keys the proposals carry (as TagKey writes them; reserved and empty left out).
func tagKeysOf(ps []config.Proposal) []string {
	seen := map[string]bool{}
	for _, p := range ps {
		for k := range p.CloudTags {
			if k = TagKey(k); k != "" && k != "tag" && !ReservedTagKeys[k] {
				seen[k] = true
			}
		}
	}
	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// sortedTags sorts pgvigil's own tags (the empty left out).
func sortedTags(l ...string) []string {
	out := make([]string, 0, len(l))
	for _, t := range l {
		if t != "" && !strings.HasSuffix(t, ":") {
			out = append(out, t)
		}
	}
	sort.Strings(out)
	return slices.Compact(out)
}

// unlistedNote is the standing note of a read without the account's region list
const unlistedNote = "the account's enabled regions were not checked: a region outside RDS's replication list is not read"

// refusedCode is the code of a call a policy refused ("" for any other error): the text holds "api error <code>:".
func refusedCode(err error) string {
	for _, code := range []string{"UnauthorizedOperation", "AccessDeniedException", "AccessDenied"} {
		if strings.Contains(err.Error(), "api error "+code+":") {
			return code
		}
	}
	return ""
}

// ec2Regions reads the partition's regions with the account's opt-in status (ec2:DescribeRegions, AllRegions: one
// call, no pages): opt-in-not-required and opted-in are enabled, not-opted-in is not.
func ec2Regions(ctx context.Context, c regionsAPI) (map[string]bool, error) {
	out, err := c.DescribeRegions(ctx, &ec2.DescribeRegionsInput{AllRegions: aws.Bool(true)})
	if err != nil {
		return nil, err
	}
	m := map[string]bool{}
	for _, r := range out.Regions {
		if n := aws.ToString(r.RegionName); n != "" {
			m[n] = aws.ToString(r.OptInStatus) != "not-opted-in"
		}
	}
	if len(m) == 0 {
		return nil, errors.New("ec2:DescribeRegions listed no region")
	}
	return m, nil
}

// regionsAPI is the one EC2 call discovery makes (an optional right: every partition has EC2, the account service
// only two - task 205, the lead's 12:28).
type regionsAPI interface {
	DescribeRegions(context.Context, *ec2.DescribeRegionsInput, ...func(*ec2.Options)) (*ec2.DescribeRegionsOutput, error)
}

// regionRefusal names why a region refused the read when it is the account's own rule, "" otherwise: an opt-in
// region the account has not enabled, or one of another partition than the credentials' (sts:GetCallerIdentity
// answered first, so the key itself is good), answers a token error; one a policy (an SCP, the identity's own) does
// not allow answers AccessDenied. listed: the account's region list said the region is enabled, so a token error
// there is the token's (a session token of the global STS endpoint is valid only in the regions enabled by default).
// A credential fault in the call ("get identity", "failed to refresh cached credentials") stays an error. The code
// is in the text ("api error <code>: ...").
// tokenThere is regionRefusal's word for a token error in a region the account's list says is enabled: the token's
// fault, not the region's, so the region is kept (any other refusal - a policy's AccessDenied - is not kept).
const tokenThere = "the token is not valid there (a session token of the global STS endpoint is valid only in the regions enabled by default)"

func regionRefusal(partition string, err error, listed bool) string {
	if err == nil {
		return ""
	}
	m := err.Error()
	for _, w := range []string{"get identity", "failed to refresh cached credentials", "failed to retrieve credentials", "operation error STS"} {
		if strings.Contains(m, w) {
			return ""
		}
	}
	for _, code := range []string{"InvalidClientTokenId", "UnrecognizedClientException", "AuthFailure", "OptInRequired"} {
		if strings.Contains(m, "api error "+code) {
			if listed {
				return tokenThere
			}
			return "not enabled for these credentials, or not a region of their partition (" + partition + ")"
		}
	}
	for _, code := range []string{"AccessDenied", "AccessDeniedException", "UnauthorizedOperation"} {
		if strings.Contains(m, "api error "+code+":") {
			return "not allowed for these credentials (" + code + ")"
		}
	}
	return ""
}

// AWS reads each region's DB instances, one proposal per instance by its own endpoint (task 205's design pass: a
// cluster, reader, Multi-AZ reader, custom or proxy endpoint joins several servers' counters, and after a failover the
// cluster endpoint is another server), PostgreSQL and SQL Server, an Aurora or Multi-AZ DB cluster member tagged
// role:writer / role:reader and cluster:<id>, a read replica role:replica and source-instance:<id>. The key carries
// the account (aws:<account>:<region>:instance:<id>), the proposal the instance's DbiResourceId.
func AWS(ctx context.Context, o AWSOptions) (Read, error) {
	wait := o.callWait
	if wait <= 0 {
		wait = awsCallWait
	}
	mk, ident, seed, list := o.client, o.identity, o.seed, o.regionList
	skip := map[string]bool{}
	for _, r := range o.Skip {
		skip[r] = true
	}
	if mk == nil || ident == nil {
		var opts []func(*awsconfig.LoadOptions) error
		if o.Profile != "" {
			opts = append(opts, awsconfig.WithSharedConfigProfile(o.Profile))
		}
		// the configuration's own region signs STS and starts a sweep; with none, the first region named and not skipped
		base, err := awsconfig.LoadDefaultConfig(ctx, opts...)
		if err == nil && base.Region == "" {
			first := o.Start
			if len(o.Regions) > 0 {
				first = firstAsked(o.Regions, skip)
			}
			if first != "" {
				base, err = awsconfig.LoadDefaultConfig(ctx, append(opts, awsconfig.WithRegion(first))...)
			}
		}
		if err != nil {
			return Read{}, fmt.Errorf("the AWS credentials: %w", err)
		}
		if base.Region == "" {
			return Read{}, errors.New("no AWS region: name the regions to read, or give the profile its region (or AWS_REGION) to start a sweep from")
		}
		seed = base.Region
		if mk == nil {
			mk = func(_ context.Context, region string) (rdsAPI, error) {
				return rds.NewFromConfig(base, func(x *rds.Options) { x.Region = region }), nil
			}
		}
		if list == nil {
			list = func(ctx context.Context, region string) (map[string]bool, error) {
				return ec2Regions(ctx, ec2.NewFromConfig(base, func(x *ec2.Options) { x.Region = region }))
			}
		}
		if ident == nil {
			ident = func(ctx context.Context) (string, string, error) {
				out, err := sts.NewFromConfig(base).GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
				if err != nil {
					return "", "", err
				}
				p, err := partitionOf(aws.ToString(out.Arn))
				return aws.ToString(out.Account), p, err
			}
		}
	}
	if seed == "" {
		seed = o.Start
	}
	ictx, cancel := context.WithTimeout(ctx, wait)
	account, partition, err := ident(ictx)
	silent := errors.Is(ictx.Err(), context.DeadlineExceeded) && ctx.Err() == nil
	cancel()
	switch {
	case err != nil && silent:
		return Read{}, fmt.Errorf("sts:GetCallerIdentity did not answer within %s: the configuration region's STS endpoint must be reachable", wait)
	case err != nil:
		return Read{}, fmt.Errorf("the AWS credentials (sts:GetCallerIdentity): %w", err)
	}
	rd := Read{Partition: partition}
	if len(o.Regions) == 0 && seed == "" {
		return Read{}, errors.New("no AWS region: name the regions to read, or give the profile its region (or AWS_REGION) to start a sweep from")
	}
	// the account's regions (optional), asked beside RDS's replication list (neither waits on the other) within
	// awsListWait: a region it has not enabled, or not of these credentials' partition, is noted and never read;
	// without the list a region outside RDS's replication list is not swept (a standing note)
	type listAnswer struct {
		m      map[string]bool
		err    error
		silent bool
	}
	lwait := min(wait, awsListWait)
	answer := make(chan listAnswer, 1)
	if list != nil {
		at := seed
		if at == "" {
			at = firstAsked(o.Regions, skip)
		}
		go func() {
			lctx, lcancel := context.WithTimeout(ctx, lwait)
			defer lcancel()
			m, lerr := list(lctx, at)
			answer <- listAnswer{m: m, err: lerr, silent: errors.Is(lctx.Err(), context.DeadlineExceeded) && ctx.Err() == nil}
		}()
	}
	var srcList []string
	var srcErr error
	if len(o.Regions) == 0 {
		srcList, srcErr = awsSourceRegions(ctx, mk, seed, wait)
	}
	enabled, listed := map[string]bool(nil), false
	if list != nil {
		a := <-answer
		switch {
		case a.err == nil:
			enabled, listed = a.m, true
		case a.silent:
			rd.Notes = append(rd.Notes, fmt.Sprintf("ec2:DescribeRegions not answered within %s: %s", lwait, unlistedNote))
		case refusedCode(a.err) != "":
			rd.Notes = append(rd.Notes, fmt.Sprintf("ec2:DescribeRegions not granted (%s): %s", refusedCode(a.err), unlistedNote))
		default:
			why := a.err.Error()
			if len(why) > 160 {
				why = why[:160]
			}
			rd.Notes = append(rd.Notes, fmt.Sprintf("ec2:DescribeRegions not answered (%s): %s", why, unlistedNote))
		}
	}
	regions := o.Regions
	if len(regions) == 0 {
		l, lerr := srcList, srcErr
		set := map[string]bool{seed: true}
		for _, r := range l {
			set[r] = true
		}
		listedOn := 0
		for r, on := range enabled {
			if on && !set[r] {
				set[r] = true
				listedOn++
			}
		}
		kept := 0
		for _, r := range o.Keep {
			if !set[r] {
				set[r] = true
				kept++
			}
		}
		for r := range set {
			regions = append(regions, r)
		}
		sort.Strings(regions)
		also := ""
		if kept > 0 {
			also = fmt.Sprintf(" and %d region(s) the source kept", kept)
		}
		if listed {
			also += fmt.Sprintf(" and %d enabled region(s) ec2:DescribeRegions adds", listedOn)
		}
		switch {
		case lerr == nil:
			rd.Swept = true
			outside := "; a region outside them is not read: name it in the source"
			if listed {
				outside = " but a region the account has not enabled (noted, not read)"
			}
			rd.Notes = append(rd.Notes, fmt.Sprintf("rds:DescribeSourceRegions in %s: %d regions (%s and those RDS there lists as its replication sources)%s, each read%s",
				seed, len(l), seed, also, outside))
		case listed:
			// the account's own list stands in for RDS's: every enabled region is swept
			rd.Swept = true
			why := lerr.Error()
			if len(why) > 160 {
				why = why[:160]
			}
			rd.Notes = append(rd.Notes, fmt.Sprintf("rds:DescribeSourceRegions not answered in %s (%s): the account's enabled regions (ec2:DescribeRegions) swept instead%s", seed, why, also))
		default:
			why := lerr.Error()
			if len(why) > 160 {
				why = why[:160]
			}
			rd.Notes = append(rd.Notes, fmt.Sprintf("rds:DescribeSourceRegions not answered in %s (%s): %s%s read, nothing new swept - name the other regions in the source", seed, why, seed, also))
		}
	}
	prefix := "aws:" + account + ":"
	refusals := map[string]int{}
	skipped := 0
	// every region is sorted before any is read (no goroutine runs while these writes do): the account's list first
	// (its answer is in hand: a skipped region it rules out is noted so and its silent note replaced), then Skip
	var toRead []string
	for _, region := range regions {
		if listed {
			// the account's list says the region cannot be read: noted, its servers unseen, never read nor kept
			if on, known := enabled[region]; !known || !on {
				why := "not enabled for this account"
				if !known {
					why = "not a region of these credentials' partition (" + partition + ")"
				}
				rd.Asked = append(rd.Asked, region)
				rd.Notes = append(rd.Notes, region+": "+why)
				rd.Unseen = append(rd.Unseen, prefix+region+":")
				refusals[why]++
				continue
			}
		}
		if skip[region] {
			// silent at an earlier read: left out until the next sweep (its note kept), its servers unseen
			rd.Unseen = append(rd.Unseen, prefix+region+":")
			rd.Regions = append(rd.Regions, region)
			skipped++
			continue
		}
		rd.Asked = append(rd.Asked, region)
		toRead = append(toRead, region)
	}
	var mu sync.Mutex
	var faults []string
	read := 0
	var wg sync.WaitGroup
	for _, region := range toRead {
		wg.Add(1)
		go func(region string) {
			defer wg.Done()
			ps, notes, err := awsRegion(ctx, mk, account, region, wait)
			mu.Lock()
			defer mu.Unlock()
			rd.Notes = append(rd.Notes, notes...)
			if err != nil {
				rd.Unseen = append(rd.Unseen, prefix+region+":")
			}
			switch why := regionRefusal(partition, err, listed); {
			case why != "":
				rd.Notes = append(rd.Notes, region+": "+why)
				refusals[why]++
				if why == tokenThere {
					// enabled for the account (the list said so) and a token error: the token's fault, not the
					// region's - kept; a policy's refusal is not (the review's part c)
					rd.Regions = append(rd.Regions, region)
				}
			case errors.Is(err, errSilent):
				// kept: a region silent now is still the source's (its servers unseen, never gone)
				rd.Notes = append(rd.Notes, region+": not reachable (no answer within "+wait.String()+")")
				rd.Regions = append(rd.Regions, region)
			case err != nil:
				rd.Notes = append(rd.Notes, region+": "+err.Error())
				rd.Regions = append(rd.Regions, region)
				faults = append(faults, err.Error())
			default:
				read++
				rd.Regions = append(rd.Regions, region)
				rd.Proposals = append(rd.Proposals, ps...)
			}
		}(region)
	}
	wg.Wait()
	sort.Strings(rd.Notes)
	sort.Strings(rd.Unseen)
	sort.Strings(rd.Regions)
	sort.Strings(rd.Asked)
	sort.Slice(rd.Proposals, func(i, j int) bool { return rd.Proposals[i].Server < rd.Proposals[j].Server })
	rd.TagKeys = tagKeysOf(rd.Proposals)
	// a read that reads no region keeps Asked: its regions' notes are keyed by region (a lone silent region is left
	// out of the next read, D5), and Unseen (nothing is marked gone by a failed read anyway)
	failed := Read{Notes: rd.Notes, Unseen: rd.Unseen, Asked: rd.Asked}
	if err := ctx.Err(); err != nil {
		return failed, fmt.Errorf("the AWS read was cut: %w", err)
	}
	if read == 0 && skipped == len(regions) {
		return failed, fmt.Errorf("every region the source keeps (%d) has not answered since its last sweep: \"Read the regions again\" asks them", skipped)
	}
	if read == 0 {
		also := ""
		if skipped > 0 {
			also = fmt.Sprintf("; %d region(s) not asked: silent since the last sweep (\"Read the regions again\" asks them)", skipped)
		}
		if len(faults) == 0 && len(refusals) == 1 { // one refusal everywhere (no RDS right at all) is said once
			var once error
			for why, n := range refusals {
				once = fmt.Errorf("no region could be read: each of the %d regions: %s%s", n, why, also)
			}
			return failed, once
		}
		if len(faults) > 0 { // the same fault in every region (a credential refused) is said once
			sort.Strings(faults)
			return failed, fmt.Errorf("no region could be read: %s%s", strings.Join(slices.Compact(faults), "; "), also)
		}
		return failed, fmt.Errorf("no region could be read (%s)%s", strings.Join(rd.Notes, "; "), also)
	}
	return rd, nil
}

// partitionOf reads the partition from an ARN (its second field).
func partitionOf(arn string) (string, error) {
	parts := strings.SplitN(arn, ":", 3)
	if len(parts) < 3 || parts[0] != "arn" || parts[1] == "" {
		return "", fmt.Errorf("an identity ARN without a partition: %q", arn)
	}
	return parts[1], nil
}

// awsSourceRegions lists the partition's regions as RDS in the seed region knows them (rds:DescribeSourceRegions,
// every page), the seed among them.
func awsSourceRegions(ctx context.Context, mk func(context.Context, string) (rdsAPI, error), seed string, wait time.Duration) ([]string, error) {
	c, err := mk(ctx, seed)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{seed: true}
	var marker *string
	for page := 0; page < 20; page++ {
		cctx, cancel := context.WithTimeout(ctx, wait)
		r, err := c.DescribeSourceRegions(cctx, &rds.DescribeSourceRegionsInput{Marker: marker})
		cancel()
		if err != nil {
			return nil, err
		}
		for _, x := range r.SourceRegions {
			if n := aws.ToString(x.RegionName); n != "" {
				seen[n] = true
			}
		}
		if marker = r.Marker; marker == nil {
			break
		}
	}
	out := make([]string, 0, len(seen))
	for n := range seen {
		out = append(out, n)
	}
	sort.Strings(out)
	return out, nil
}

// awsMember is a DB instance's cluster as DescribeDBClusters tells it.
type awsMember struct {
	cluster, master, db, serverless string
	writer, pause                   bool
	tags                            map[string]string
}

// awsRegion reads one region; each Describe call (each page) gets wait to answer (errSilent when it does not, the
// parent context still live). The notes name what it left out of a region it read.
func awsRegion(ctx context.Context, mk func(context.Context, string) (rdsAPI, error), account, region string, wait time.Duration) ([]config.Proposal, []string, error) {
	c, err := mk(ctx, region)
	if err != nil {
		return nil, nil, err
	}
	call := func(f func(context.Context) error) error {
		cctx, cancel := context.WithTimeout(ctx, wait)
		defer cancel()
		err := f(cctx)
		if err != nil && errors.Is(cctx.Err(), context.DeadlineExceeded) && ctx.Err() == nil {
			return errSilent
		}
		return err
	}
	var out []config.Proposal
	var notes []string
	members := map[string]awsMember{}
	var marker *string
	for {
		var r *rds.DescribeDBClustersOutput
		if err := call(func(cctx context.Context) (e error) {
			r, e = c.DescribeDBClusters(cctx, &rds.DescribeDBClustersInput{Marker: marker})
			return e
		}); err != nil {
			return nil, nil, err
		}
		for _, cl := range r.DBClusters {
			if engineOf(aws.ToString(cl.Engine)) == "" {
				continue
			}
			id := aws.ToString(cl.DBClusterIdentifier)
			if len(cl.DBClusterMembers) == 0 {
				notes = append(notes, region+" cluster "+id+": no instance (nothing to propose)")
			}
			sv, pause := "", false
			if v := cl.ServerlessV2ScalingConfiguration; v != nil && v.MinCapacity != nil {
				lo, hi := aws.ToFloat64(v.MinCapacity), aws.ToFloat64(v.MaxCapacity)
				sv = fmt.Sprintf("Aurora Serverless v2, %g to %g ACU", lo, hi)
				if lo == 0 {
					pause = true
					sv += fmt.Sprintf(", pauses after %d s idle", aws.ToInt32(v.SecondsUntilAutoPause))
				}
			}
			for _, m := range cl.DBClusterMembers {
				members[aws.ToString(m.DBInstanceIdentifier)] = awsMember{cluster: id, master: aws.ToString(cl.MasterUsername), db: aws.ToString(cl.DatabaseName),
					serverless: sv, writer: aws.ToBool(m.IsClusterWriter), pause: pause, tags: awsTags(cl.TagList)}
			}
		}
		if marker = r.Marker; marker == nil {
			break
		}
	}
	marker = nil
	for {
		var r *rds.DescribeDBInstancesOutput
		if err := call(func(cctx context.Context) (e error) {
			r, e = c.DescribeDBInstances(cctx, &rds.DescribeDBInstancesInput{Marker: marker})
			return e
		}); err != nil {
			return nil, nil, err
		}
		for _, in := range r.DBInstances {
			eng := engineOf(aws.ToString(in.Engine))
			if eng == "" {
				continue
			}
			id := aws.ToString(in.DBInstanceIdentifier)
			if in.Endpoint == nil || aws.ToString(in.Endpoint.Address) == "" {
				notes = append(notes, region+" instance "+id+": no endpoint yet ("+aws.ToString(in.DBInstanceStatus)+")")
				continue
			}
			tags := []string{"cloud:aws", "region:" + region, "account:" + account}
			cloud := map[string]string{}
			m, inCluster := members[id]
			role := ""
			switch {
			case inCluster:
				for k, v := range m.tags {
					cloud[k] = v
				}
				role = "reader"
				if m.writer {
					role = "writer"
				}
				tags = append(tags, "cluster:"+m.cluster)
			case aws.ToString(in.ReadReplicaSourceDBInstanceIdentifier) != "":
				role = "replica"
				src := aws.ToString(in.ReadReplicaSourceDBInstanceIdentifier)
				tags = append(tags, "source-instance:"+src[strings.LastIndex(src, ":")+1:])
			case aws.ToString(in.ReadReplicaSourceDBClusterIdentifier) != "": // a replica of a Multi-AZ DB cluster
				role = "replica"
				src := aws.ToString(in.ReadReplicaSourceDBClusterIdentifier)
				tags = append(tags, "source-cluster:"+src[strings.LastIndex(src, ":")+1:])
			}
			display := id
			if role != "" {
				tags = append(tags, "role:"+role)
				display += " (" + role + ")"
			}
			for k, v := range awsTags(in.TagList) {
				cloud[k] = v
			}
			master, db := aws.ToString(in.MasterUsername), aws.ToString(in.DBName)
			if master == "" {
				master = m.master
			}
			if db == "" {
				db = m.db
			}
			sv, pause := "", false
			if aws.ToString(in.DBInstanceClass) == "db.serverless" {
				sv, pause = m.serverless, m.pause
				if sv == "" {
					sv = "Aurora Serverless v2"
				}
			}
			out = append(out, config.Proposal{Server: "aws:" + account + ":" + region + ":instance:" + id, Engine: eng, Host: aws.ToString(in.Endpoint.Address),
				Port: int(aws.ToInt32(in.Endpoint.Port)), DBName: db, DisplayName: display, MasterUser: master, ResourceID: aws.ToString(in.DbiResourceId),
				Tags: sortedTags(tags...), CloudTags: cloud, Serverless: sv, AutoPause: pause})
		}
		if marker = r.Marker; marker == nil {
			break
		}
	}
	return out, notes, nil
}

func awsTags(l []rdstypes.Tag) map[string]string {
	m := map[string]string{}
	for _, t := range l {
		m[aws.ToString(t.Key)] = aws.ToString(t.Value)
	}
	return m
}
