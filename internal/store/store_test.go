package store_test

import (
	"testing"

	"github.com/aachaemenes/pgvigil/internal/repo"
	"github.com/aachaemenes/pgvigil/internal/store"
)

// The repository is a Store: a method the collectors call that the repository renames, drops or changes the shape
// of fails this file's build, and so does a method added to Store that the repository lacks.
var _ store.Store = (*repo.Repo)(nil)

// The two halves are what a remote collector's bundle writer implements apart: what it writes and what it answers.
func TestStoreHalves(t *testing.T) {
	var s store.Store = (*repo.Repo)(nil)
	var w store.Writer = s
	var r store.Reader = s
	if w == nil || r == nil {
		t.Fatal("a Store is not its two halves")
	}
}
