package remote

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// stateFile is the remote collector's state in its state folder.
const stateFile = "state.json"

// State is what a remote collector keeps between runs (docs/remote-bundle-format.md): its stream, each instance's
// local id, the bundle seqs and how far each source was read. Every change is written whole (a temp file synced,
// renamed, the folder synced) before the call returns. The order that keeps a restart from sending a line twice or
// skipping one: Reserve the seq before the bundle opens; Close the bundle (renamed whole); Commit the seq with the
// cursors the bundle carried. A crash before the rename leaves the seq reserved and its interval is read again under
// it; a crash between the rename and the commit is mended by Recover from the bundle's own manifest.
type State struct {
	mu        sync.Mutex
	dir       string
	Stream    string                    `json:"stream"`
	Instances map[string]*InstanceState `json:"instances"`
}

// InstanceState is one instance's part of the state.
type InstanceState struct {
	ID         int                      `json:"id"`
	Done       uint64                   `json:"done"`     // the newest seq closed and committed
	Reserved   uint64                   `json:"reserved"` // the open bundle's seq; 0 = none
	Cursors    map[string]format.Cursor `json:"cursors"`
	FailStreak int                      `json:"fail_streak"`
}

// LoadState reads the state folder's state, or starts a new stream when the folder holds none (fresh is then true:
// the caller logs it, and the hub starts the instance's seq again at 1 under the new stream). A file that cannot be
// read is an error, never a silent new stream.
func LoadState(dir string) (s *State, fresh bool, err error) {
	s = &State{dir: dir, Instances: map[string]*InstanceState{}}
	b, err := os.ReadFile(filepath.Join(dir, stateFile))
	switch {
	case errors.Is(err, os.ErrNotExist):
		var id [16]byte
		if _, err := rand.Read(id[:]); err != nil {
			return nil, false, err
		}
		s.Stream = hex.EncodeToString(id[:])
		return s, true, s.save()
	case err != nil:
		return nil, false, fmt.Errorf("state: %w", err)
	}
	if err := json.Unmarshal(b, s); err != nil {
		return nil, false, fmt.Errorf("state: %s cannot be read (%v): move it aside to start a new stream", filepath.Join(dir, stateFile), err)
	}
	if len(s.Stream) != 32 {
		return nil, false, fmt.Errorf("state: %s holds no stream", filepath.Join(dir, stateFile))
	}
	if s.Instances == nil {
		s.Instances = map[string]*InstanceState{}
	}
	return s, false, nil
}

// inst returns an instance's part, made with the next free id on its first use.
func (s *State) inst(name string) *InstanceState {
	if is, ok := s.Instances[name]; ok {
		if is.Cursors == nil {
			is.Cursors = map[string]format.Cursor{}
		}
		return is
	}
	id := 0
	for _, is := range s.Instances {
		id = max(id, is.ID)
	}
	is := &InstanceState{ID: id + 1, Cursors: map[string]format.Cursor{}}
	s.Instances[name] = is
	return is
}

// InstanceID is the instance's local id (stable while the state folder lives).
func (s *State) InstanceID(name string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, known := s.Instances[name]
	is := s.inst(name)
	if !known {
		_ = s.save() // a lost id is made again with the next number: no row depends on the local id at the hub
	}
	return is.ID
}

// Reserve returns the seq for the instance's next bundle and stores it before the bundle opens; a seq reserved and
// never committed is returned again.
func (s *State) Reserve(name string) (uint64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	is := s.inst(name)
	if is.Reserved == 0 {
		is.Reserved = is.Done + 1
		if err := s.save(); err != nil {
			is.Reserved = 0
			return 0, err
		}
	}
	return is.Reserved, nil
}

// Commit records a closed bundle: its seq done and the cursors it carried (by source, the newest written over).
func (s *State) Commit(name string, seq uint64, cursors []format.Cursor) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	is := s.inst(name)
	if is.Reserved == 0 || seq != is.Reserved {
		return fmt.Errorf("state: %s: commit of seq %d, the reserved seq is %d", name, seq, is.Reserved)
	}
	for _, c := range cursors {
		is.Cursors[c.Source] = c
	}
	is.Done, is.Reserved = seq, 0
	return s.save()
}

// Cursor returns how far an instance's source was read when its last bundle was committed.
func (s *State) Cursor(name, source string) (format.Cursor, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	is, ok := s.Instances[name]
	if !ok {
		return format.Cursor{}, false
	}
	c, ok := is.Cursors[source]
	return c, ok
}

// Recover commits every reserved seq whose bundle is finished in the outbox (a crash between the rename and the
// commit), with the cursors from its manifest; it returns how many it mended.
func (s *State) Recover(outbox, site, collector string) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	names := make([]string, 0, len(s.Instances))
	for n := range s.Instances {
		names = append(names, n)
	}
	sort.Strings(names)
	mended := 0
	for _, name := range names {
		is := s.inst(name)
		if is.Reserved == 0 {
			continue
		}
		pattern := filepath.Join(outbox, site, collector, format.InstanceKey(name), "*", fmt.Sprintf("%010d-*", is.Reserved))
		dirs, err := filepath.Glob(pattern)
		if err != nil {
			return mended, err
		}
		for _, d := range dirs {
			if strings.HasSuffix(d, format.PartExt) {
				continue
			}
			b, err := os.ReadFile(filepath.Join(d, format.ManifestFile))
			if err != nil {
				continue // a folder with no manifest is no finished bundle
			}
			m, err := format.DecodeManifest(b)
			if err != nil {
				return mended, fmt.Errorf("state: %s: %w", d, err)
			}
			if m.Stream != s.Stream || m.Seq != is.Reserved {
				continue
			}
			for _, c := range m.Cursors {
				is.Cursors[c.Source] = c
			}
			is.Done, is.Reserved = m.Seq, 0
			mended++
			break
		}
	}
	if mended > 0 {
		return mended, s.save()
	}
	return 0, nil
}

// save writes the state whole: a temp file synced, renamed over state.json, the folder synced.
func (s *State) save() error {
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return fmt.Errorf("state: %w", err)
	}
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return fmt.Errorf("state: %w", err)
	}
	tmp := filepath.Join(s.dir, stateFile+".tmp")
	_ = os.Remove(tmp)
	if err := writeSynced(tmp, append(b, '\n')); err != nil {
		return err
	}
	if err := os.Rename(tmp, filepath.Join(s.dir, stateFile)); err != nil {
		return fmt.Errorf("state: %w", err)
	}
	return syncDir(s.dir)
}
