package ingest

import (
	"context"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestSitesRefuseASharedDrop (H4): two sites reading one drop (the same folder, bucket and prefix, or container and
// prefix) would load each other's bundles under the wrong names: refused at start in words; two drops apart are taken.
func TestSitesRefuseASharedDrop(t *testing.T) {
	open := func(context.Context, config.ExportDestination) (Drop, error) { return nil, nil }
	site := func(name string, d config.ExportDestination) config.RemoteSite {
		return config.RemoteSite{Name: name, Drop: d, Collectors: []config.RemoteCollector{{Name: "c1"}}}
	}
	for _, c := range []struct {
		name string
		a, b config.ExportDestination
		bad  bool
	}{
		{"one folder", config.ExportDestination{Type: "folder", Path: "/drop"}, config.ExportDestination{Type: "folder", Path: "/drop/"}, true},
		{"two folders", config.ExportDestination{Type: "folder", Path: "/drop/a"}, config.ExportDestination{Type: "folder", Path: "/drop/b"}, false},
		{"one bucket and prefix", config.ExportDestination{Type: "s3", Bucket: "b", Prefix: "x"}, config.ExportDestination{Type: "s3", Bucket: "b", Prefix: "x/"}, true},
		{"one bucket, two prefixes", config.ExportDestination{Type: "s3", Bucket: "b", Prefix: "x"}, config.ExportDestination{Type: "s3", Bucket: "b", Prefix: "y"}, false},
		{"one container", config.ExportDestination{Type: "azure_blob", AccountURL: "https://a.blob.core.windows.net", Container: "c"},
			config.ExportDestination{Type: "azure_blob", AccountURL: "https://a.blob.core.windows.net/", Container: "c"}, true},
	} {
		_, err := Sites(context.Background(), []config.RemoteSite{site("s1", c.a), site("s2", c.b)}, open)
		if c.bad && (err == nil || !strings.Contains(err.Error(), "one drop")) {
			t.Errorf("%s: %v, want a refusal naming 'one drop'", c.name, err)
		}
		if !c.bad && err != nil {
			t.Errorf("%s: %v", c.name, err)
		}
	}
}

// a bucket or container drop with no prefix is refused in words (at the root its bundles would mix with anything else)
func TestOpenDropNeedsAPrefix(t *testing.T) {
	for _, typ := range []string{"s3", "azure_blob"} {
		if _, err := OpenDrop(context.Background(), config.ExportDestination{Type: typ, Bucket: "b", Container: "c", Prefix: "/"}); err == nil || !strings.Contains(err.Error(), "needs its prefix") {
			t.Errorf("%s with no prefix: %v, want 'needs its prefix'", typ, err)
		}
	}
}
