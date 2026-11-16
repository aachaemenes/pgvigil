package ingest

import (
	"context"
	"fmt"
	"net/url"
	"path/filepath"
	"strings"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/export"
)

// OpenDrop opens a site's drop read-only through internal/export (ingest calls only its Get and List): its keys
// rooted at the drop's prefix (no name). A bucket or container drop needs its prefix: at the bucket's root the
// bundles would mix with anything else kept there, so it is refused in words.
func OpenDrop(ctx context.Context, d config.ExportDestination) (Drop, error) {
	switch d.Type {
	case "s3", "azure_blob":
		p := strings.Trim(d.Prefix, "/")
		if p == "" {
			return nil, fmt.Errorf("a %s drop needs its prefix: the folder of the bucket or container the site's bundles land in (at the root they would mix with anything else kept there)", d.Type)
		}
		if d.Type == "s3" {
			return export.NewS3(ctx, export.S3Options{Bucket: d.Bucket, Prefix: p, Region: d.Region, Endpoint: d.Endpoint, Profile: d.Profile})
		}
		return export.NewAzureBlob(export.BlobOptions{AccountURL: d.AccountURL, Container: d.Container, Prefix: p,
			ConnectionString: d.ConnectionString(), SASURL: d.SASURL()})
	}
	return export.NewFolder(d.Path), nil
}

// blobAccount: the storage account an azure_blob drop reads - its account_url's host, else its SAS URL's host, else its
// connection string's AccountName (a SAS or a connection string drop names no account_url) - lower case
func blobAccount(d config.ExportDestination) string {
	host := func(raw string) string {
		if u, err := url.Parse(strings.TrimSpace(raw)); err == nil && u.Host != "" {
			return strings.ToLower(u.Host)
		}
		return ""
	}
	if h := host(d.AccountURL); h != "" {
		return h
	}
	if h := host(d.SASURL()); h != "" {
		return h
	}
	for _, part := range strings.Split(d.ConnectionString(), ";") {
		if k, v, ok := strings.Cut(strings.TrimSpace(part), "="); ok && strings.EqualFold(k, "AccountName") {
			return strings.ToLower(v) + ".blob.core.windows.net"
		}
	}
	return ""
}

// dropID names the place a drop reads, so two sites never read one
func dropID(d config.ExportDestination) string {
	switch d.Type {
	case "s3":
		return "s3 " + strings.TrimRight(d.Endpoint, "/") + " " + d.Bucket + "/" + strings.Trim(d.Prefix, "/")
	case "azure_blob":
		return "azure_blob " + blobAccount(d) + " " + d.Container + "/" + strings.Trim(d.Prefix, "/")
	}
	return "folder " + filepath.Clean(d.Path)
}

// Sites opens remote_sites: for the loop, one Site each (open builds a drop's reader: OpenDrop). Two sites that read
// one drop would load each other's bundles under the wrong names: refused, in words.
func Sites(ctx context.Context, cfg []config.RemoteSite, open func(context.Context, config.ExportDestination) (Drop, error)) ([]Site, error) {
	seen := map[string]string{}
	out := make([]Site, 0, len(cfg))
	for _, s := range cfg {
		id := dropID(s.Drop)
		if other, ok := seen[id]; ok {
			return nil, fmt.Errorf("remote_sites: sites %s and %s read one drop (%s): each site needs its own drop and its own read key", other, s.Name, id)
		}
		seen[id] = s.Name
		d, err := open(ctx, s.Drop)
		if err != nil {
			return nil, fmt.Errorf("remote_sites: site %s: %w", s.Name, err)
		}
		site := Site{Name: s.Name, Drop: d, Tags: s.Tags, ExpectedEvery: s.ExpectedEvery.Duration, GapWait: s.GapWait.Duration, Collectors: map[string][][]byte{}}
		for _, c := range s.Collectors {
			var keys [][]byte
			for _, k := range c.Keys {
				b, err := config.Ed25519Key(k)
				if err != nil {
					return nil, fmt.Errorf("remote_sites: site %s, collector %s: %w", s.Name, c.Name, err)
				}
				keys = append(keys, b)
			}
			site.Collectors[c.Name] = keys
		}
		out = append(out, site)
	}
	return out, nil
}
