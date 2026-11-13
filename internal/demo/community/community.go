// Package community holds the demo's stored samples of the community tools (B3, the Community tools page on a demo
// instance): each tool's answer as it came back from a run on a test server built for the capture, so a demo instance,
// which has no server behind it, can show what the tool returns - marked as a sample of that test server, never as the
// demo instance's own data. The files are written by scripts/capture-community-samples.sh through the pack command
// (internal/demo/community/pack: the rig's names scrubbed, plan XML left out, gzipped JSON) and never edited by hand.
//
// What is stored: the result sets a procedure or a pgvigil read returned (the findings' words and links of a kit are
// the kit's own: THIRD-PARTY-NOTICES.md names each), the parameters the run passed, the parameter names of the
// procedure (with their help text for the MIT kits only), the kit, its version, the capture's date and the test
// server's version. Nothing of a procedure's code, and nothing of sp_WhoIsActive's own help text, is stored.
package community

import (
	"bytes"
	"compress/gzip"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"sort"
	"strings"
	"sync"
	"time"
)

// Dir is the folder of the samples inside this package (the pack writes there).
const Dir = "samples"

//go:embed samples
var files embed.FS

// Set is one result set as pgvigil's grid draws it (internal/web resultSet's shape).
type Set struct {
	Columns   []string `json:"columns"`
	Types     []string `json:"types"`
	Rows      [][]any  `json:"rows"`
	Truncated bool     `json:"truncated,omitempty"`
}

// ParamDoc is one parameter of the procedure as the test server's copy declared it; Help only for an MIT kit.
type ParamDoc struct {
	Name string `json:"name"`
	Type string `json:"type"`
	Help string `json:"help,omitempty"`
}

// Sample is one tool's stored answer.
type Sample struct {
	Tool        string            `json:"tool"`
	Engine      string            `json:"engine"`       // sqlserver | postgres
	Kit         string            `json:"kit"`          // First Responder Kit | DarlingData | sp_WhoIsActive | pgvigil
	Version     string            `json:"version"`      // the kit's (or the procedure's) version as its source states it
	VersionDate string            `json:"version_date"` // the version's date, YYYY-MM-DD ("" when the source gives none)
	CapturedAt  time.Time         `json:"captured_at"`
	Server      string            `json:"server"` // the test server's engine and version, e.g. SQL Server 2022 16.0.4295.3
	Database    string            `json:"database,omitempty"`
	Params      map[string]string `json:"params"`              // what the capture's run passed (empty = the tool's defaults)
	ParamDoc    []ParamDoc        `json:"param_doc,omitempty"` // the procedure's parameters (none for a pgvigil read)
	Dropped     []string          `json:"dropped,omitempty"`   // columns left out, with why (plan XML)
	Cut         []string          `json:"cut,omitempty"`       // sets cut to the stored rows, and cells cut, with how many
	Scrubbed    []string          `json:"scrubbed,omitempty"`  // the test server's own names replaced, by the word put in
	Sets        []Set             `json:"sets"`
}

var (
	mu    sync.Mutex
	cache = map[string]*Sample{}
)

// ErrNone: the tool has no stored sample.
var ErrNone = errors.New("no stored sample for this tool")

func fileOf(tool string) string { return Dir + "/" + tool + ".json.gz" }

// Get returns the tool's stored sample (decoded once, kept).
func Get(tool string) (*Sample, error) {
	if tool == "" || strings.ContainsAny(tool, "/\\.") {
		return nil, ErrNone
	}
	mu.Lock()
	defer mu.Unlock()
	if s := cache[tool]; s != nil {
		return s, nil
	}
	b, err := files.ReadFile(fileOf(tool))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, ErrNone
	}
	if err != nil {
		return nil, err
	}
	s, err := Decode(b)
	if err != nil {
		return nil, fmt.Errorf("the sample of %s: %w", tool, err)
	}
	if s.Tool != tool {
		return nil, fmt.Errorf("the file of %s holds the sample of %q", tool, s.Tool)
	}
	cache[tool] = s
	return s, nil
}

// Has: the tool has a stored sample.
func Has(tool string) bool {
	_, err := files.ReadFile(fileOf(tool))
	return err == nil
}

// Tools lists the tools with a stored sample.
func Tools() []string {
	ents, _ := files.ReadDir(Dir)
	var out []string
	for _, e := range ents {
		if n, ok := strings.CutSuffix(e.Name(), ".json.gz"); ok {
			out = append(out, n)
		}
	}
	sort.Strings(out)
	return out
}

// Raw returns a sample file's bytes as stored (gzipped) and its JSON text, for the tests.
func Raw(tool string) (gz, text []byte, err error) {
	gz, err = files.ReadFile(fileOf(tool))
	if err != nil {
		return nil, nil, err
	}
	text, err = gunzip(gz)
	return gz, text, err
}

func gunzip(b []byte) ([]byte, error) {
	zr, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	defer zr.Close()
	return io.ReadAll(io.LimitReader(zr, 64<<20))
}

// Decode reads one stored file (gzipped JSON).
func Decode(b []byte) (*Sample, error) {
	text, err := gunzip(b)
	if err != nil {
		return nil, err
	}
	d := json.NewDecoder(bytes.NewReader(text))
	d.UseNumber()
	var s Sample
	if err := d.Decode(&s); err != nil {
		return nil, err
	}
	return &s, nil
}

// Encode writes one sample as the stored file (gzipped JSON, best compression).
func Encode(s *Sample) ([]byte, error) {
	text, err := json.Marshal(s)
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	zw, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if err != nil {
		return nil, err
	}
	if _, err := zw.Write(text); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// Rows counts the rows of every set.
func (s *Sample) Rows() int {
	n := 0
	for _, x := range s.Sets {
		n += len(x.Rows)
	}
	return n
}
