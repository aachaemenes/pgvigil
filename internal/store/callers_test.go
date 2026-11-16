package store_test

import (
	"context"
	"log/slog"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/engines"
	"github.com/aachaemenes/pgvigil/internal/mssql"
	"github.com/aachaemenes/pgvigil/internal/store"
)

// fake is a Store that is not the repository: what a remote collector's bundle writer will be.
type fake struct{}

func (fake) EnsureInstance(context.Context, string, string, string, int, bool, []string) (int, error) {
	return 1, nil
}
func (fake) EnsureInstanceEngine(context.Context, string, string, string, string, int, bool, []string) (int, error) {
	return 1, nil
}
func (fake) Import(context.Context, int, string, time.Time, []map[string]any) error { return nil }
func (fake) LogCollection(context.Context, int, string, time.Time, time.Duration, string, string) error {
	return nil
}
func (fake) LogCollectionStage(context.Context, int, string, time.Time, time.Duration, string, string, string) error {
	return nil
}
func (fake) LogConnectFailure(context.Context, string, string, string, []string, string, time.Time, time.Duration, error) error {
	return nil
}
func (fake) LogSecretFailure(context.Context, string, string, string, []string, string, time.Time, time.Duration, error) error {
	return nil
}
func (fake) LogRunFailure(context.Context, string, string, string, time.Time, time.Duration, error) error {
	return nil
}
func (fake) LogCursor(context.Context, int, string) (time.Time, bool, error) {
	return time.Time{}, false, nil
}
func (fake) MSSQLCursor(context.Context, int, string) (string, int64, time.Time, int64, bool, error) {
	return "", 0, time.Time{}, 0, false, nil
}
func (fake) MSSQLSeqCursor(context.Context, int, string) (int64, bool, error) { return 0, false, nil }
func (fake) MSSQLSettings(context.Context, int, string) ([]byte, error)       { return []byte("{}"), nil }
func (fake) MSSQLCounterList(context.Context, int, []byte) ([]byte, error)    { return []byte("[]"), nil }
func (fake) MSSQLSchemaDue(context.Context, int, time.Time, []byte) ([]byte, error) {
	return []byte("{}"), nil
}

// Every collector entry point takes a Store: this file builds only when none of them asks for *repo.Repo, so a
// remote collector runs the same collector code. (The calls are built, not run: a run needs a server.)
func TestCollectorsTakeAStore(t *testing.T) {
	var s store.Store = fake{}
	calls := []func(context.Context){
		func(ctx context.Context) { collect.RunOnce(ctx, slog.Default(), s, config.Instance{}, "activity") },
		func(ctx context.Context) { engines.RunOnce(ctx, slog.Default(), s, config.Instance{}, "activity") },
		func(ctx context.Context) { mssql.RunOnce(ctx, slog.Default(), s, config.Instance{}, "mssql_activity") },
		func(ctx context.Context) { _ = mssql.StoreHADRThresholds(ctx, s, 1, "mssql_ag", time.Time{}, nil) },
	}
	if len(calls) != 4 {
		t.Fatal("the entry points")
	}
	// the thresholds go through Import alone: no server, so this one runs
	if err := mssql.StoreHADRThresholds(context.Background(), s, 1, "mssql_ag", time.Now(), nil); err != nil {
		t.Errorf("StoreHADRThresholds through a Store: %v", err)
	}
}
