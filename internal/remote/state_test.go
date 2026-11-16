package remote

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// A new state folder starts a new stream; the same folder keeps it, with its instance ids and cursors.
func TestStateStreamAndReload(t *testing.T) {
	dir := t.TempDir()
	s, fresh, err := LoadState(dir)
	if err != nil || !fresh {
		t.Fatalf("new: %v, fresh %v", err, fresh)
	}
	if !regexp.MustCompile(`^[0-9a-f]{32}$`).MatchString(s.Stream) {
		t.Errorf("stream %q", s.Stream)
	}
	a, b := s.InstanceID(`HOST\INST`), s.InstanceID("pg1")
	if a == b || s.InstanceID(`HOST\INST`) != a {
		t.Errorf("ids %d %d", a, b)
	}
	seq, err := s.Reserve(`HOST\INST`)
	if err != nil || seq != 1 {
		t.Fatalf("reserve: %d %v", seq, err)
	}
	at := t0
	if err := s.Commit(`HOST\INST`, 1, []format.Cursor{{Source: "errorlog", Kind: "mssql", FileName: "ERRORLOG", FileOffset: 10, LastEventAt: &at}}); err != nil {
		t.Fatal(err)
	}
	s2, fresh, err := LoadState(dir)
	if err != nil || fresh || s2.Stream != s.Stream || s2.InstanceID(`HOST\INST`) != a || s2.InstanceID("pg1") != b {
		t.Fatalf("reload: %v fresh %v %+v", err, fresh, s2)
	}
	c, ok := s2.Cursor(`HOST\INST`, "errorlog")
	if !ok || c.FileOffset != 10 || !c.LastEventAt.Equal(t0) {
		t.Errorf("cursor after reload: %+v %v", c, ok)
	}
	if seq, _ := s2.Reserve(`HOST\INST`); seq != 2 {
		t.Errorf("next seq %d", seq)
	}
}

// A seq reserved and never committed (a crash before the rename) is reused: nothing of that bundle left.
func TestStateReserveReusedAfterCrash(t *testing.T) {
	dir := t.TempDir()
	s, _, _ := LoadState(dir)
	if seq, _ := s.Reserve("pg1"); seq != 1 {
		t.Fatal(seq)
	}
	s2, _, err := LoadState(dir)
	if err != nil {
		t.Fatal(err)
	}
	if seq, _ := s2.Reserve("pg1"); seq != 1 {
		t.Errorf("after a crash the reserved seq is %d, want 1 again", seq)
	}
	// a commit of another seq than the reserved one is refused
	if err := s2.Commit("pg1", 2, nil); err == nil {
		t.Errorf("a commit of an unreserved seq")
	}
}

// A crash after the rename and before the commit: Recover reads the finished bundle's manifest and commits its seq
// and its cursors, so the next bundle neither repeats a line nor skips one.
func TestStateRecoverAfterRename(t *testing.T) {
	stateDir, out := t.TempDir(), t.TempDir()
	s, _, _ := LoadState(stateDir)
	seq, _ := s.Reserve(`HOST\INST`)
	o := opts(out)
	o.Seq, o.Stream = seq, s.Stream
	b, err := OpenBundle(o)
	if err != nil {
		t.Fatal(err)
	}
	at := t1
	if _, err := b.Close(t1, nil, []format.Cursor{{Source: "errorlog", Kind: "mssql", FileName: "ERRORLOG", FileOffset: 99, LastEventAt: &at}}, format.Heartbeat{Host: "h", Started: t0, At: t1}); err != nil {
		t.Fatal(err)
	}
	// the crash: no Commit; a fresh process loads the state and recovers
	s2, _, _ := LoadState(stateDir)
	n, err := s2.Recover(out, "site1", "coll1")
	if err != nil || n != 1 {
		t.Fatalf("Recover: %d %v", n, err)
	}
	if c, ok := s2.Cursor(`HOST\INST`, "errorlog"); !ok || c.FileOffset != 99 {
		t.Errorf("cursor from the manifest: %+v", c)
	}
	if next, _ := s2.Reserve(`HOST\INST`); next != seq+1 {
		t.Errorf("next seq %d, want %d", next, seq+1)
	}
	// nothing to recover twice
	if n, err := s2.Recover(out, "site1", "coll1"); err != nil || n != 0 {
		t.Errorf("a second Recover: %d %v", n, err)
	}
}

// A reserved seq whose bundle was never finished (only a .part, cleaned) stays reserved for its re-read.
func TestStateRecoverLeavesAnUnfinishedSeq(t *testing.T) {
	stateDir, out := t.TempDir(), t.TempDir()
	s, _, _ := LoadState(stateDir)
	seq, _ := s.Reserve(`HOST\INST`)
	o := opts(out)
	o.Seq = seq
	b, _ := OpenBundle(o)
	b.Abandon()
	if _, err := CleanParts(out); err != nil {
		t.Fatal(err)
	}
	if n, err := s.Recover(out, "site1", "coll1"); err != nil || n != 0 {
		t.Fatalf("Recover: %d %v", n, err)
	}
	if again, _ := s.Reserve(`HOST\INST`); again != seq {
		t.Errorf("reserve after an unfinished bundle: %d, want %d", again, seq)
	}
}

// A state file that cannot be read is refused in words (a person decides), never silently a new stream.
func TestStateRefusesADamagedFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, stateFile), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := LoadState(dir); err == nil {
		t.Errorf("a damaged state.json was taken")
	}
	// the file is written whole: no temp file left beside it after a save
	dir2 := t.TempDir()
	s, _, _ := LoadState(dir2)
	if _, err := s.Reserve("x"); err != nil {
		t.Fatal(err)
	}
	ents, _ := os.ReadDir(dir2)
	if len(ents) != 1 || ents[0].Name() != stateFile {
		t.Errorf("the state folder holds %v", ents)
	}
	_ = time.Second
}
