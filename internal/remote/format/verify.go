package format

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"strings"
)

// Problem kinds. Missing and short may be a bundle still on its way (a copy that has not finished): the hub retries
// them until its settle time; the rest set a bundle aside with the kind as its reason.
const (
	KindMissing   = "missing"   // a file the manifest names is not there
	KindShort     = "short"     // a file is shorter than the manifest says
	KindChecksum  = "checksum"  // a file's or the sums file's sha256 is not the manifest's, or the two lists differ
	KindCount     = "count"     // the batches, rows or uncompressed bytes are not the manifest's
	KindExtra     = "extra"     // a file the manifest does not list
	KindMalformed = "malformed" // a line, a view entry or the batch numbers are not of the format
	KindTooBig    = "too_big"   // a view file uncompresses past the reader's cap
)

// Problem is why a bundle is not taken.
type Problem struct {
	Kind   string
	File   string
	Detail string
}

func (p *Problem) Error() string {
	if p.File == "" {
		return p.Kind + ": " + p.Detail
	}
	return p.Kind + ": " + p.File + ": " + p.Detail
}

func problem(kind, file, format string, a ...any) error {
	return &Problem{Kind: kind, File: file, Detail: fmt.Sprintf(format, a...)}
}

// Verify checks a bundle's folder (fsys rooted at it) against its manifest: no file it does not list, the sums
// file's sha256 and its list equal to the manifest's, each view file's size and sha256, and, uncompressed under
// maxRaw bytes each, its lines' batches and rows and the batch numbers 1..N across the bundle, each once. A nil
// result means every line of every file can be read as written. The signature is the caller's (it holds the keys).
func Verify(fsys fs.FS, m *Manifest, maxRaw int64) error {
	if err := m.checkFiles(); err != nil {
		return problem(KindMalformed, "", "%v", err)
	}
	listed := map[string]bool{ManifestFile: true, SumsFile: true, SigFile: true}
	for _, f := range m.Files {
		listed[f.Name] = true
	}
	entries, err := fs.ReadDir(fsys, ".")
	if err != nil {
		return problem(KindMissing, "", "the folder cannot be read: %v", err)
	}
	for _, e := range entries {
		if !listed[e.Name()] || e.IsDir() {
			return problem(KindExtra, e.Name(), "not a file the manifest lists")
		}
	}
	sums, err := fs.ReadFile(fsys, SumsFile)
	if err != nil {
		return problem(KindMissing, SumsFile, "%v", err)
	}
	if sha(sums) != m.SumsSHA256 {
		return problem(KindChecksum, SumsFile, "its sha256 is not the manifest's")
	}
	if err := sameSums(sums, m.Files); err != nil {
		return problem(KindChecksum, SumsFile, "%v", err)
	}
	numbers := map[int64]bool{}
	total := 0
	for _, f := range m.Files {
		if f.RawBytes > maxRaw {
			return problem(KindTooBig, f.Name, "%d bytes uncompressed, over the cap of %d", f.RawBytes, maxRaw)
		}
		b, err := fs.ReadFile(fsys, f.Name)
		switch {
		case errors.Is(err, fs.ErrNotExist):
			return problem(KindMissing, f.Name, "not there")
		case err != nil:
			return problem(KindMissing, f.Name, "%v", err)
		case int64(len(b)) < f.Bytes:
			return problem(KindShort, f.Name, "%d bytes of %d", len(b), f.Bytes)
		case int64(len(b)) > f.Bytes || sha(b) != f.SHA256:
			return problem(KindChecksum, f.Name, "its bytes are not the manifest's")
		}
		lines, raw, err := readLines(b, f.Name, maxRaw)
		if err != nil {
			return err
		}
		var rows int64
		for _, l := range lines {
			if numbers[l.N] {
				return problem(KindMalformed, f.Name, "batch number %d twice in the bundle", l.N)
			}
			numbers[l.N] = true
			n, err := countRows(l.Rows)
			if err != nil {
				return problem(KindMalformed, f.Name, "batch %d: %v", l.N, err)
			}
			rows += n
		}
		switch {
		case raw != f.RawBytes:
			return problem(KindCount, f.Name, "%d bytes uncompressed, the manifest says %d", raw, f.RawBytes)
		case len(lines) != f.Batches:
			return problem(KindCount, f.Name, "%d batches, the manifest says %d", len(lines), f.Batches)
		case rows != f.Rows:
			return problem(KindCount, f.Name, "%d rows, the manifest says %d", rows, f.Rows)
		}
		total += len(lines)
	}
	for n := int64(1); n <= int64(total); n++ {
		if !numbers[n] {
			return problem(KindMalformed, "", "the batch numbers are not 1..%d (no %d)", total, n)
		}
	}
	return nil
}

// ReadLines reads one view file's lines (call it after Verify: it checks only that each line is of the format).
func ReadLines(fsys fs.FS, f File, maxRaw int64) ([]Line, error) {
	b, err := fs.ReadFile(fsys, f.Name)
	if err != nil {
		return nil, problem(KindMissing, f.Name, "%v", err)
	}
	lines, _, err := readLines(b, f.Name, maxRaw)
	return lines, err
}

// readLines uncompresses a view file under maxRaw bytes and decodes each line strictly; it returns the lines and the
// uncompressed size. The whole file is held (it is capped), so a long line needs no scanner buffer.
func readLines(gz []byte, name string, maxRaw int64) ([]Line, int64, error) {
	zr, err := gzip.NewReader(bytes.NewReader(gz))
	if err != nil {
		return nil, 0, problem(KindMalformed, name, "not gzip: %v", err)
	}
	raw, err := io.ReadAll(io.LimitReader(zr, maxRaw+1))
	if err != nil {
		return nil, 0, problem(KindMalformed, name, "gzip: %v", err)
	}
	if int64(len(raw)) > maxRaw {
		return nil, 0, problem(KindTooBig, name, "uncompresses past the cap of %d bytes", maxRaw)
	}
	if len(raw) == 0 || raw[len(raw)-1] != '\n' {
		return nil, 0, problem(KindMalformed, name, "the last line does not end")
	}
	var lines []Line
	for i, text := range bytes.Split(raw[:len(raw)-1], []byte{'\n'}) {
		d := json.NewDecoder(bytes.NewReader(text))
		d.DisallowUnknownFields()
		d.UseNumber()
		var l Line
		if err := d.Decode(&l); err != nil || d.More() {
			return nil, 0, problem(KindMalformed, name, "line %d is not {n, at, rows}: %v", i+1, err)
		}
		if l.N < 1 || l.At.IsZero() || len(l.Rows) == 0 || l.Rows[0] != '[' {
			return nil, 0, problem(KindMalformed, name, "line %d: n from 1, a time and a list of rows", i+1)
		}
		lines = append(lines, l)
	}
	return lines, int64(len(raw)), nil
}

// countRows counts a line's rows: a JSON list of objects.
func countRows(rows json.RawMessage) (int64, error) {
	var list []json.RawMessage
	if err := json.Unmarshal(rows, &list); err != nil {
		return 0, fmt.Errorf("rows: %v", err)
	}
	for i, r := range list {
		if len(r) == 0 || r[0] != '{' {
			return 0, fmt.Errorf("row %d is not an object", i+1)
		}
	}
	return int64(len(list)), nil
}

// sameSums holds the sums file (sha256sum's lines: '<hex>  <name>') to the manifest's files, one line each.
func sameSums(sums []byte, files []File) error {
	want := map[string]string{}
	for _, f := range files {
		want[f.Name] = f.SHA256
	}
	got := 0
	sc := bufio.NewScanner(bytes.NewReader(sums))
	for sc.Scan() {
		hexSum, name, ok := strings.Cut(sc.Text(), "  ")
		if !ok || !hex64RE.MatchString(hexSum) {
			return fmt.Errorf("line %q is not '<sha256>  <name>'", sc.Text())
		}
		if s, listed := want[name]; !listed || s != hexSum {
			return fmt.Errorf("%s: not the manifest's file or not its sum", name)
		}
		delete(want, name)
		got++
	}
	if err := sc.Err(); err != nil {
		return err
	}
	if len(want) > 0 {
		return fmt.Errorf("%d of the manifest's files are not in it", len(want))
	}
	return nil
}

func sha(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }
