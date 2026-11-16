// Package store is what a collector run needs of the place its rows go. A collector that connects to a
// pgvigil repository gives it *repo.Repo; a remote collector (docs/remote-collector.md) gives it the bundle
// writer of internal/remote, which writes interval bundles for a hub to ingest. The collectors take a Store and
// never the concrete repository, so both run the same collector code.
//
// The method set is the one the collectors call today (internal/collect, internal/mssql, internal/engines), with
// the repository's signatures; store_test.go holds *repo.Repo to it.
package store

import (
	"context"
	"time"
)

// Writer is what a run hands over: the instance's identity, its rows and how each collection ended. The bundle
// writer puts each call into the interval's bundle (the identity and the run records into its manifest, the rows
// into one line of the collection's view file); the repository writes them through its import functions.
type Writer interface {
	// EnsureInstance and EnsureInstanceEngine return the instance's id, made on its first call.
	EnsureInstance(ctx context.Context, name, platform, serverVersion string, versionNum int, isReplica bool, tags []string) (int, error)
	EnsureInstanceEngine(ctx context.Context, engine, name, platform, serverVersion string, versionNum int, isReplica bool, tags []string) (int, error)
	// Import hands over one batch of a collection's rows (pgvigil.import_<collection>).
	Import(ctx context.Context, instanceID int, collection string, snapshotAt time.Time, rows []map[string]any) error
	// LogCollection and LogCollectionStage record one run of a collection and how it ended.
	LogCollection(ctx context.Context, instanceID int, collection string, snapshotAt time.Time, d time.Duration, status, note string) error
	LogCollectionStage(ctx context.Context, instanceID int, collection string, snapshotAt time.Time, d time.Duration, status, note, stage string) error
	// LogConnectFailure, LogSecretFailure and LogRunFailure record a run that never reached its rows.
	LogConnectFailure(ctx context.Context, name, engine, platform string, tags []string, collection string, at time.Time, d time.Duration, cause error) error
	LogSecretFailure(ctx context.Context, name, engine, platform string, tags []string, collection string, at time.Time, d time.Duration, cause error) error
	LogRunFailure(ctx context.Context, name, engine, collection string, at time.Time, d time.Duration, cause error) error
}

// Reader is what a run asks before it reads: how far each log or cursor source was read, and the three answers the
// repository computes for a SQL Server run. The repository answers from its tables; a remote collector answers the
// cursors from its local state and the three answers by local rules (the settings and the counter list as the
// repository's functions answer them with no Admin rows, schema due by 0267's rule over its state).
type Reader interface {
	LogCursor(ctx context.Context, instanceID int, source string) (time.Time, bool, error)
	MSSQLCursor(ctx context.Context, instanceID int, source string) (fileName string, fileOffset int64, lastEventAt time.Time, lastSeq int64, found bool, err error)
	MSSQLSeqCursor(ctx context.Context, instanceID int, source string) (int64, bool, error)
	MSSQLSettings(ctx context.Context, instanceID int, fn string) ([]byte, error)
	MSSQLCounterList(ctx context.Context, instanceID int, yaml []byte) ([]byte, error)
	MSSQLSchemaDue(ctx context.Context, instanceID int, snapshotAt time.Time, payload []byte) ([]byte, error)
}

// Store is both halves: what every collector run takes.
type Store interface {
	Writer
	Reader
}
