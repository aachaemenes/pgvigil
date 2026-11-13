package collect

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs"
	dms "github.com/aws/aws-sdk-go-v2/service/databasemigrationservice"
	"github.com/aws/aws-sdk-go-v2/service/rds"
)

// The AWS door has to work in every partition, AWS GovCloud (US) included: pgvigil writes no endpoint, no
// partition and no "arn:aws:" prefix of its own; the region in the instance's aws: block is the only
// input and the SDK's endpoint resolver picks the host. This resolves every service pgvigil calls for the
// two GovCloud regions and one commercial region and checks the host the SDK picked.
func TestAWSEndpointsFollowThePartition(t *testing.T) {
	ctx := context.Background()
	cases := []struct{ region, want string }{
		{"us-gov-west-1", ".us-gov-west-1.amazonaws.com"},
		{"us-gov-east-1", ".us-gov-east-1.amazonaws.com"},
		{"us-east-2", ".us-east-2.amazonaws.com"},
	}
	for _, c := range cases {
		r := aws.String(c.region)
		hosts := map[string]string{}
		if e, err := cloudwatchlogs.NewDefaultEndpointResolverV2().ResolveEndpoint(ctx, cloudwatchlogs.EndpointParameters{Region: r}); err != nil {
			t.Fatalf("%s logs: %v", c.region, err)
		} else {
			hosts["logs."] = e.URI.Host
		}
		if e, err := cloudwatch.NewDefaultEndpointResolverV2().ResolveEndpoint(ctx, cloudwatch.EndpointParameters{Region: r}); err != nil {
			t.Fatalf("%s cloudwatch: %v", c.region, err)
		} else {
			hosts["monitoring."] = e.URI.Host
		}
		if e, err := dms.NewDefaultEndpointResolverV2().ResolveEndpoint(ctx, dms.EndpointParameters{Region: r}); err != nil {
			t.Fatalf("%s dms: %v", c.region, err)
		} else {
			hosts["dms."] = e.URI.Host
		}
		if e, err := rds.NewDefaultEndpointResolverV2().ResolveEndpoint(ctx, rds.EndpointParameters{Region: r}); err != nil {
			t.Fatalf("%s rds: %v", c.region, err)
		} else {
			hosts["rds."] = e.URI.Host
		}
		for prefix, host := range hosts {
			if !strings.HasPrefix(host, prefix) || !strings.HasSuffix(host, c.want) {
				t.Errorf("%s: the SDK resolved %s to %q, want %s*%s", c.region, strings.TrimSuffix(prefix, "."), host, prefix, c.want)
			}
		}
	}
}

// A DMS CloudWatch dimension is the tail of the task's or instance's ARN, whatever its partition.
func TestDMSResourceIDIsPartitionFree(t *testing.T) {
	for _, c := range []struct{ arn, want string }{
		{"arn:aws:dms:us-east-2:123456789012:task:ABCDEFGHIJKLMNOPQRSTUVWXYZ012345", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"},
		{"arn:aws-us-gov:dms:us-gov-west-1:123456789012:task:GOVTASK1234567890ABCDEFGHIJKLMN", "GOVTASK1234567890ABCDEFGHIJKLMN"},
		{"arn:aws-us-gov:dms:us-gov-east-1:123456789012:rep:GOVINSTANCE1234567890ABCDEFGHI", "GOVINSTANCE1234567890ABCDEFGHI"},
		{"arn:aws-cn:dms:cn-north-1:123456789012:task:CNTASK", "CNTASK"},
	} {
		if got := dmsResourceID(c.arn); got != c.want {
			t.Errorf("dmsResourceID(%q) = %q, want %q", c.arn, got, c.want)
		}
	}
}

// No Go source of pgvigil and no migration names an AWS endpoint, a partition or a region: a government fleet's
// regions come from the config alone, and a name table moved into SQL is the same knowledge (task 205's review). The
// scan covers every non-test .go file under the module root except internal/demo, whose synthetic fleet carries
// example ARNs and regions as data, and every .sql file under internal/repo/sql (web/, docs/ and the built
// internal/web/dist hold neither; the skips are by path, so internal/web's Go is scanned).
func TestNoHardCodedAWSPartition(t *testing.T) {
	hits, err := hardCodedAWS(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) > 0 {
		t.Fatalf("AWS partition, endpoint or region written into the code:\n  %s", strings.Join(hits, "\n  "))
	}
}

// The scan itself finds what it is for: a planted migration and a planted Go file are hits, a test file and a
// demo file are not.
func TestHardCodedAWSScanFinds(t *testing.T) {
	root := t.TempDir()
	plant := func(rel, text string) {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	plant("internal/repo/sql/0999_x.sql", "SELECT CASE WHEN r LIKE 'us-gov-%' THEN 1 END;\n")
	plant("internal/x/x.go", "package x\n\nconst host = \".amazonaws.com\"\n")
	plant("internal/x/x_test.go", "package x\n\nconst r = \"us-east-1\"\n")
	plant("internal/demo/d.go", "package demo\n\nconst r = \"us-east-2\"\n")
	hits, err := hardCodedAWS(root)
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Join(hits, "; ")
	if len(hits) != 2 || !strings.Contains(got, "0999_x.sql: us-gov-") || !strings.Contains(got, "x.go: .amazonaws.com") {
		t.Fatalf("the scan found %q, want the planted migration's us-gov- and x.go's .amazonaws.com only", got)
	}
}

// hardCodedAWS lists each scanned file under root that holds a forbidden name, as "<path>: <name>".
func hardCodedAWS(root string) ([]string, error) {
	forbidden := []string{"arn:aws:", "arn:aws-us-gov:", ".amazonaws.com", "us-east-1", "us-east-2", "us-west-", "us-gov-"}
	var hits []string
	err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			rel, _ := filepath.Rel(root, p)
			rel = filepath.ToSlash(rel)
			if n := d.Name(); n == ".git" || n == "node_modules" || rel == "web" || rel == "docs" || rel == "internal/demo" || rel == "internal/web/dist" {
				return filepath.SkipDir
			}
			return nil
		}
		rel, _ := filepath.Rel(root, p)
		sqlFile := strings.HasSuffix(p, ".sql") && filepath.ToSlash(filepath.Dir(rel)) == "internal/repo/sql"
		if !sqlFile && (!strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go")) {
			return nil
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		for _, f := range forbidden {
			if strings.Contains(string(b), f) {
				hits = append(hits, p+": "+f)
			}
		}
		return nil
	})
	return hits, err
}
