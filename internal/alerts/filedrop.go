package alerts

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// FileDrop is a channel's file: block, the channel of an air-gapped site: one JSON file per alert in a directory the
// site's own tooling picks up. Each file is written under a temporary name and renamed, so a reader never sees half a
// file; the name sorts by time: <UTC time>-<event>-<channel>-<key>.json.
type FileDrop struct {
	Dir string `yaml:"dir"`
}

type fileSender struct{ dir string }

func (f *FileDrop) build() (sender, error) {
	d := strings.TrimSpace(f.Dir)
	if d == "" {
		return nil, errors.New("file.dir is required")
	}
	if !filepath.IsAbs(d) {
		return nil, fmt.Errorf("file.dir must be an absolute path (got %q)", d)
	}
	return &fileSender{dir: filepath.Clean(d)}, nil
}

func (s *fileSender) destination() string { return "file:" + s.dir }

func (s *fileSender) perAlert() bool { return true }

func (s *fileSender) send(_ context.Context, m Message) error {
	st, err := os.Stat(s.dir)
	if err != nil {
		return err
	}
	if !st.IsDir() {
		return fmt.Errorf("%s is not a directory", s.dir)
	}
	for _, a := range m.Alerts {
		b, err := json.MarshalIndent(struct {
			Source  string `json:"source"`
			Channel string `json:"channel"`
			SentAt  string `json:"sent_at"`
			Alert
		}{"pgvigil", m.Channel, m.SentAt.UTC().Format("2006-01-02T15:04:05.000Z"), a}, "", "  ")
		if err != nil {
			return err
		}
		key := a.FindingKey
		if len(key) > 12 {
			key = key[:12]
		}
		name := fmt.Sprintf("%s-%s-%s-%s.json", m.SentAt.UTC().Format("20060102T150405.000Z"), a.Event, m.Channel, key)
		tmp, err := os.CreateTemp(s.dir, ".pgvigil-alert-*.tmp")
		if err != nil {
			return err
		}
		_, werr := tmp.Write(append(b, '\n'))
		cerr := tmp.Close()
		if werr == nil {
			werr = cerr
		}
		if werr == nil {
			werr = os.Chmod(tmp.Name(), 0o640)
		}
		if werr == nil {
			werr = os.Rename(tmp.Name(), filepath.Join(s.dir, name))
		}
		if werr != nil {
			_ = os.Remove(tmp.Name())
			return werr
		}
	}
	return nil
}
