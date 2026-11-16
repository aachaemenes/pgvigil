package ingest

import (
	"context"
	"fmt"
	"path"
	"path/filepath"
	"strings"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/export"
)

// OpenDrop opens a site's drop read-only through internal/export (ingest calls only its Get and List). A bucket or
// container drop needs a prefix: internal/export roots its keys at '<prefix>/<name>/', so the prefix's last part is
// the name and the bundles' folders start under it.
func OpenDrop(ctx context.Context, d config.ExportDestination) (Drop, error) {
	switch d.Type {
	case "s3", "azure_blob":
		p := strings.Trim(d.Prefix, "/")
		if p == "" {
			return nil, fmt.Errorf("a %s drop needs its prefix: the folder of the bucket or container the site's bundles land in", d.Type)
		}
		dir, name := path.Split(p)
		if d.Type == "s3" {
			return export.NewS3(ctx, export.S3Options{Bucket: d.Bucket, Prefix: strings.Trim(dir, "/"), Region: d.Region, Endpoint: d.Endpoint, Profile: d.Profile, Name: name})
		}
		return export.NewAzureBlob(export.BlobOptions{AccountURL: d.AccountURL, Container: d.Container, Prefix: strings.Trim(dir, "/"),
			ConnectionString: d.ConnectionString(), SASURL: d.SASURL(), Name: name})
	}
	return export.NewFolder(d.Path), nil
}

// dropID names the place a drop reads, so two sites never read one
func dropID(d config.ExportDestination) string {
	switch d.Type {
	case "s3":
		return "s3 " + strings.TrimRight(d.Endpoint, "/") + " " + d.Bucket + "/" + strings.Trim(d.Prefix, "/")
	case "azure_blob":
		return "azure_blob " + strings.ToLower(strings.TrimRight(d.AccountURL, "/")) + " " + d.Container + "/" + strings.Trim(d.Prefix, "/")
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
