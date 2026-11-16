package export

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// OUTBOX H GETMAX (relw2c-s2 13:3x): a bounded read - GetMax(ctx, key, max) reads at most max + 1 bytes and refuses an
// object past max with ErrTooBig, naming the object and the cap; the folder, S3 (a Range of max + 1) and Azure Blob (a
// ranged download of max + 1) implement it; export.GetMax uses it when the destination has it, else Get + a length check.

func checkTooBig(t *testing.T, what string, err error, key string, max int64) {
	t.Helper()
	if !errors.Is(err, ErrTooBig) {
		t.Errorf("%s: %v, want ErrTooBig", what, err)
		return
	}
	if !strings.Contains(err.Error(), key) || !strings.Contains(err.Error(), strconv.FormatInt(max, 10)) {
		t.Errorf("%s: %q does not name the object %s and the cap %d", what, err, key, max)
	}
}

func TestFolderGetMax(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	d := NewFolder(root)
	if err := os.MkdirAll(filepath.Join(root, "s", "b"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "s", "b", "f"), []byte("0123456789"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "s", "b", "empty"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	g, ok := d.(interface {
		GetMax(context.Context, string, int64) ([]byte, error)
	})
	if !ok {
		t.Fatal("the folder destination has no GetMax")
	}
	if b, err := g.GetMax(ctx, "s/b/f", 10); err != nil || string(b) != "0123456789" {
		t.Errorf("at its cap: %q, %v", b, err)
	}
	_, err := g.GetMax(ctx, "s/b/f", 9)
	checkTooBig(t, "one byte past", err, "s/b/f", 9)
	if b, err := g.GetMax(ctx, "s/b/empty", 4); err != nil || len(b) != 0 {
		t.Errorf("an empty file: %q, %v", b, err)
	}
	if _, err := g.GetMax(ctx, "s/b/none", 4); !errors.Is(err, errAbsent) {
		t.Errorf("an absent file: %v, want errAbsent", err)
	}
}

// getOnly: a destination with Get alone (another branch's fake): the helper falls back to Get + a length check
type getOnly struct{ objs map[string][]byte }

func (g getOnly) Get(_ context.Context, key string) ([]byte, error) {
	b, ok := g.objs[key]
	if !ok {
		return nil, errAbsent
	}
	return b, nil
}

func TestGetMaxHelper(t *testing.T) {
	ctx := context.Background()
	g := getOnly{objs: map[string][]byte{"k": []byte("abcd")}}
	if b, err := GetMax(ctx, g, "k", 4); err != nil || string(b) != "abcd" {
		t.Errorf("fallback at its cap: %q, %v", b, err)
	}
	_, err := GetMax(ctx, g, "k", 3)
	checkTooBig(t, "fallback one byte past", err, "k", 3)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "k"), []byte("abcd"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err = GetMax(ctx, NewFolder(root), "k", 3)
	checkTooBig(t, "the folder through the helper", err, "k", 3)
}

// fakeStore: one HTTP server standing in for S3 (path style: /<bucket>/<key>) or Azure Blob (/<container>/<blob>);
// it records the range each GET asks for and answers 206 with that slice, 416 InvalidRange for an empty object
type fakeStore struct {
	mu     sync.Mutex
	objs   map[string][]byte // the path after the bucket or container
	ranges []string
	azure  bool
}

func (f *fakeStore) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	parts := strings.SplitN(strings.TrimPrefix(r.URL.Path, "/"), "/", 2)
	key := ""
	if len(parts) == 2 {
		key = parts[1]
	}
	rg := r.Header.Get("Range")
	if f.azure {
		if x := r.Header.Get("x-ms-range"); x != "" {
			rg = x
		}
	}
	f.mu.Lock()
	f.ranges = append(f.ranges, rg)
	body, ok := f.objs[key]
	f.mu.Unlock()
	fail := func(status int, code string) {
		if f.azure {
			w.Header().Set("x-ms-error-code", code)
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(status)
			fmt.Fprintf(w, `<?xml version="1.0" encoding="utf-8"?><Error><Code>%s</Code><Message>%s</Message></Error>`, code, code)
			return
		}
		w.Header().Set("Content-Type", "application/xml")
		w.WriteHeader(status)
		fmt.Fprintf(w, `<?xml version="1.0" encoding="UTF-8"?><Error><Code>%s</Code><Message>%s</Message></Error>`, code, code)
	}
	if !ok {
		if f.azure {
			fail(http.StatusNotFound, "BlobNotFound")
		} else {
			fail(http.StatusNotFound, "NoSuchKey")
		}
		return
	}
	if f.azure {
		w.Header().Set("x-ms-blob-type", "BlockBlob")
		w.Header().Set("ETag", `"0x1"`)
		w.Header().Set("Last-Modified", "Mon, 16 Nov 2026 21:00:00 GMT")
	}
	from, to := int64(0), int64(len(body))-1
	if rg != "" {
		spec := strings.TrimPrefix(rg, "bytes=")
		a, b, _ := strings.Cut(spec, "-")
		from, _ = strconv.ParseInt(a, 10, 64)
		if b != "" {
			to, _ = strconv.ParseInt(b, 10, 64)
		}
		if len(body) == 0 || from >= int64(len(body)) {
			fail(http.StatusRequestedRangeNotSatisfiable, "InvalidRange")
			return
		}
		if to >= int64(len(body)) {
			to = int64(len(body)) - 1
		}
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", from, to, len(body)))
		w.Header().Set("Content-Length", strconv.FormatInt(to-from+1, 10))
		w.WriteHeader(http.StatusPartialContent)
		_, _ = w.Write(body[from : to+1])
		return
	}
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

func (f *fakeStore) lastRange() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.ranges) == 0 {
		return ""
	}
	return f.ranges[len(f.ranges)-1]
}

// each cloud destination asks for max + 1 bytes (never the whole object), answers an object within the cap whole,
// refuses one past it, reads a 0-byte object as empty and an absent one as errAbsent
func TestCloudGetMax(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	t.Setenv("AWS_CONFIG_FILE", filepath.Join(dir, "none"))
	t.Setenv("AWS_SHARED_CREDENTIALS_FILE", filepath.Join(dir, "none"))
	t.Setenv("AWS_PROFILE", "")
	t.Setenv("AWS_EC2_METADATA_DISABLED", "true")
	t.Setenv("AWS_REGION", "us-east-1")
	t.Setenv("AWS_ACCESS_KEY_ID", "AKIDTEST")
	t.Setenv("AWS_SECRET_ACCESS_KEY", "secret")
	for _, azure := range []bool{false, true} {
		f := &fakeStore{azure: azure, objs: map[string][]byte{"drop/s/b/f": []byte("0123456789"), "drop/s/b/empty": {}}}
		srv := httptest.NewServer(f)
		var d Destination
		var err error
		name := "s3"
		if azure {
			name = "azure_blob"
			// sas_url is the storage account's address with the SAS token (docs/remote-collector.md): the container follows
			d, err = NewAzureBlob(BlobOptions{SASURL: srv.URL + "/?sv=2024-01-01&sig=x", Container: "c", Prefix: "drop"})
		} else {
			d, err = NewS3(ctx, S3Options{Endpoint: srv.URL, Bucket: "b", Prefix: "drop"})
		}
		if err != nil {
			srv.Close()
			t.Fatalf("%s: %v", name, err)
		}
		g, ok := d.(interface {
			GetMax(context.Context, string, int64) ([]byte, error)
		})
		if !ok {
			srv.Close()
			t.Fatalf("the %s destination has no GetMax", name)
		}
		if b, err := g.GetMax(ctx, "s/b/f", 10); err != nil || string(b) != "0123456789" {
			t.Errorf("%s at its cap: %q, %v", name, b, err)
		}
		if got := f.lastRange(); got != "bytes=0-10" {
			t.Errorf("%s asked for %q, want bytes=0-10 (max + 1 bytes)", name, got)
		}
		_, err = g.GetMax(ctx, "s/b/f", 4)
		checkTooBig(t, name+" past its cap", err, "s/b/f", 4)
		if got := f.lastRange(); got != "bytes=0-4" {
			t.Errorf("%s asked for %q, want bytes=0-4 (never the whole object)", name, got)
		}
		if b, err := g.GetMax(ctx, "s/b/empty", 4); err != nil || len(b) != 0 {
			t.Errorf("%s an empty object: %q, %v", name, b, err)
		}
		if _, err := g.GetMax(ctx, "s/b/none", 4); !errors.Is(err, errAbsent) {
			t.Errorf("%s an absent object: %v, want errAbsent", name, err)
		}
		srv.Close()
	}
}
