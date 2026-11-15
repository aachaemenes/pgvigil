package export

import (
	"crypto/sha256"
	"encoding/hex"
	"sort"
	"strings"
	"time"
)

// ContractVersion is the version of the file contract (docs/parquet-export.md): the layout, the manifest's fields
// and the rules a consumer reads by.
const ContractVersion = 1

// Hour is one clock hour: a window [From, To), UTC.
type Hour struct{ From, To time.Time }

func (w Hour) firstOfDay() bool { return w.From.UTC().Hour() == 0 }

func stamp(t time.Time) string  { return t.UTC().Format("20060102T1504Z") }
func isoUTC(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05Z") }

func windowName(name string, w Hour) string {
	return name + "__" + stamp(w.From) + "__" + stamp(w.To)
}

// manifestKey is a window's manifest; mark is "" or a subset run's __t<8 hex>.
func manifestKey(name string, w Hour, mark string) string {
	return "_manifests/" + windowName(name, w) + mark + ".json"
}

// finalKey marks a window whose final pass is done. It is written after the final manifest.
func finalKey(name string, w Hour) string { return "_manifests/_final/" + windowName(name, w) }

// fileBase is a table's file name for a window, without a part mark and without .parquet.
func fileBase(table, name string, w Hour, mark string) string {
	return table + "__" + windowName(name, w) + mark
}

// subsetMark names a run of some tables only, so that neither its manifest nor its files replace a full run's.
func subsetMark(tables []string) string {
	t := append([]string(nil), tables...)
	sort.Strings(t)
	s := sha256.Sum256([]byte(strings.Join(t, ",")))
	return "__t" + hex.EncodeToString(s[:4])
}

// windowOfKey reads a window back from a manifest's or a marker's key; ok false for a subset manifest and for
// anything that is not this repository's.
func windowOfKey(key, name string) (Hour, bool) {
	base := key[strings.LastIndex(key, "/")+1:]
	base = strings.TrimSuffix(base, ".json")
	parts := strings.Split(base, "__")
	if len(parts) != 3 || parts[0] != name {
		return Hour{}, false
	}
	from, err1 := time.Parse("20060102T1504Z", parts[1])
	to, err2 := time.Parse("20060102T1504Z", parts[2])
	if err1 != nil || err2 != nil || !to.Equal(from.Add(time.Hour)) {
		return Hour{}, false
	}
	return Hour{from.UTC(), to.UTC()}, true
}

// Manifest is a window's manifest. contract_version is its first key.
type Manifest struct {
	ContractVersion  int             `json:"contract_version"`
	Repository       string          `json:"repository"`
	Window           ManifestWindow  `json:"window"`
	Pass             any             `json:"pass"` // 1, or "final" for the pass that re-exports a window once it is old enough
	Gap              bool            `json:"gap,omitempty"`
	PgvigilVersion   string          `json:"pgvigil_version"`
	SchemaMigrations int             `json:"schema_migrations"`
	StartedAt        string          `json:"started_at"`
	FinishedAt       string          `json:"finished_at"`
	Tables           []ManifestTable `json:"tables"`
	Skipped          []SkippedTable  `json:"skipped"`
	Failed           []FailedTable   `json:"failed"`
	DroppedColumns   []DroppedColumn `json:"dropped_columns"`
	FilteredRows     []FilteredRows  `json:"filtered_rows"`
}

// ManifestWindow is the hour, UTC.
type ManifestWindow struct {
	FromUTC string `json:"from_utc"`
	ToUTC   string `json:"to_utc"`
}

// ManifestTable is one table of a window. A table with no row in the window has row_count 0 and no file.
type ManifestTable struct {
	Table       string           `json:"table"`
	Kind        string           `json:"kind"`
	TimeColumn  string           `json:"time_column,omitempty"`
	KeyColumns  []string         `json:"key_columns"` // the primary key: a consumer keeps one row per key within a window
	OutputFiles []OutputFile     `json:"output_files"`
	RowCount    int64            `json:"row_count"`
	ByteSize    int64            `json:"byte_size"`
	Columns     []ManifestColumn `json:"columns"`
	ReadMS      int64            `json:"read_ms"`
	Note        string           `json:"note,omitempty"`
}

// ManifestColumn is a column of a file.
type ManifestColumn struct {
	Name        string `json:"name"`
	PgType      string `json:"pg_type"`
	ParquetType string `json:"parquet_type"`
	Note        string `json:"note,omitempty"`
}

// SkippedTable is a table not exported under this configuration, and why.
type SkippedTable struct {
	Table  string `json:"table"`
	Reason string `json:"reason"`
}

// FailedTable is a table whose read failed on three runs: the window is complete without it.
type FailedTable struct {
	Table string `json:"table"`
	Error string `json:"error"`
}

// FilteredRows names rows of a table left behind, and why.
type FilteredRows struct {
	Table  string `json:"table"`
	Rows   string `json:"rows"` // the predicate, over the table's own columns
	Reason string `json:"reason"`
}

// DroppedColumn is a column left behind, and why.
type DroppedColumn struct {
	Table  string `json:"table"`
	Column string `json:"column"`
	Reason string `json:"reason"`
}
