package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// L232: the files a start names, the hand-over to the running app, the parts the page joins, and the Open with entries.

func TestOpenPathsL232(t *testing.T) {
	abs := func(p string) (string, error) {
		if strings.HasPrefix(p, "/") {
			return p, nil
		}
		return "/work/" + p, nil
	}
	paths, refused := OpenPaths([]string{"a.sqlplan", "/x/b.xdl"}, abs)
	if strings.Join(paths, ",") != "/work/a.sqlplan,/x/b.xdl" || len(refused) != 0 {
		t.Errorf("two files made absolute: %v %v", paths, refused)
	}
	var many []string
	for i := 0; i < MaxOpenFiles+1; i++ {
		many = append(many, fmt.Sprintf("p%d.sqlplan", i))
	}
	paths, refused = OpenPaths(many, abs)
	if len(paths) != MaxOpenFiles || len(refused) != 1 || refused[0].Name != fmt.Sprintf("p%d.sqlplan", MaxOpenFiles) || !strings.Contains(refused[0].Why, "at most 15 files") {
		t.Errorf("the 16th file is refused in words: %d paths, %+v", len(paths), refused)
	}
	if paths, refused := OpenPaths(nil, abs); len(paths) != 0 || len(refused) != 0 {
		t.Errorf("no file: %v %v", paths, refused)
	}
}

func TestReadOpenL232(t *testing.T) {
	dir := t.TempDir()
	write := func(name string, b []byte) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, b, 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	// SSMS saves a plan as UTF-16 LE with a byte-order mark: the bytes go to the page as they are (its decode reads the mark)
	plan := append([]byte{0xff, 0xfe}, []byte("<\x00S\x00")...)
	if f := ReadOpen(write("a.sqlplan", plan)); f.Why != "" || f.Name != "a.sqlplan" || !bytes.Equal(f.Data, plan) {
		t.Errorf("a plan is read whole: %+v", f)
	}
	if f := ReadOpen(write("B.XDL", []byte("<deadlock/>"))); f.Why != "" || f.Name != "B.XDL" {
		t.Errorf("the kind is read from the extension in any case: %+v", f)
	}
	if f := ReadOpen(write("c.txt", []byte("x"))); f.Why == "" || !strings.Contains(f.Why, ".sqlplan") || !strings.Contains(f.Why, ".xdl") || f.Data != nil {
		t.Errorf("another kind is refused in words, nothing read: %+v", f)
	}
	if f := ReadOpen(filepath.Join(dir, "gone.sqlplan")); f.Why == "" || f.Name != "gone.sqlplan" {
		t.Errorf("a missing file is refused with why: %+v", f)
	}
	// the limit: the page's own (filedrop.ts MAX_BYTES), read from the size first, so a large file is never read
	big := filepath.Join(dir, "big.sqlplan")
	fh, err := os.Create(big)
	if err != nil {
		t.Fatal(err)
	}
	if err := fh.Truncate(MaxOpenBytes + 1); err != nil {
		t.Fatal(err)
	}
	_ = fh.Close()
	if f := ReadOpen(big); f.Why == "" || !strings.Contains(f.Why, "64 MB") || f.Data != nil {
		t.Errorf("a file over 64 MB is refused before it is read: %+v", f.Why)
	}
	if MaxOpenBytes != 64*1024*1024 {
		t.Errorf("the limit is the page's 64 MB: %d", MaxOpenBytes)
	}
	// a smaller limit: one byte over it refused, the limit exactly read
	if f := readOpen(write("grow.sqlplan", []byte("0123456789A")), 10); f.Why == "" || f.Data != nil {
		t.Errorf("a read past the limit is refused: %+v", f)
	}
	if f := readOpen(write("ten.sqlplan", []byte("0123456789")), 10); f.Why != "" || len(f.Data) != 10 {
		t.Errorf("a file of the limit exactly is read: %+v", f)
	}
}

func TestCopyDataL232(t *testing.T) {
	in := []string{"/plans/a.sqlplan", "/plans/\u00dcn\u00efcode plan.sqlplan", "/d/b.xdl"}
	b, err := EncodeCopyData(in)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	out, err := DecodeCopyData(CopyDataMagic, b)
	if err != nil || strings.Join(out, "|") != strings.Join(in, "|") {
		t.Errorf("the paths read back equal: %v %v", out, err)
	}
	if _, err := DecodeCopyData(CopyDataMagic+1, b); err == nil {
		t.Error("another program's WM_COPYDATA (its dwData) is refused")
	}
	rel, _ := EncodeCopyData([]string{"/a.sqlplan"})
	rel = append(rel, 0)
	rel = append(rel, []byte("relative.sqlplan")...)
	if _, err := DecodeCopyData(CopyDataMagic, rel); err == nil {
		t.Error("a path that is not absolute is refused (the running app has its own working folder)")
	}
	if _, err := EncodeCopyData([]string{"/a\x00b.sqlplan"}); err == nil {
		t.Error("a NUL inside a path is refused")
	}
	var many []string
	for i := 0; i < MaxOpenFiles+1; i++ {
		many = append(many, fmt.Sprintf("/p%d.sqlplan", i))
	}
	if _, err := EncodeCopyData(many); err == nil {
		t.Error("more than 15 paths are refused at the send")
	}
	all := []byte(strings.Join(many, "\x00"))
	if _, err := DecodeCopyData(CopyDataMagic, all); err == nil {
		t.Error("more than 15 paths are refused at the receipt")
	}
	if _, err := DecodeCopyData(CopyDataMagic, nil); err == nil {
		t.Error("an empty payload is refused")
	}
	if _, err := DecodeCopyData(CopyDataMagic, bytes.Repeat([]byte("/"), MaxCopyData+1)); err == nil {
		t.Error("a payload over its bound is refused before it is split")
	}
}

func TestPageScriptsL232(t *testing.T) {
	data := bytes.Repeat([]byte("0123456789"), 900_000) // 9 MB: three parts of at most 4 MB
	name := `q"</script>` + "\u2028" + `.sqlplan`
	scripts := PageScripts(7, OpenFile{Name: name, Data: data}, 4<<20)
	if len(scripts) != 3 {
		t.Fatalf("three parts, got %d", len(scripts))
	}
	var joined []byte
	for i, s := range scripts {
		if !strings.HasPrefix(s, PageScriptPrefix) || !strings.HasSuffix(s, ")") {
			t.Fatalf("part %d is a guarded call: %.60q", i, s)
		}
		if strings.Contains(s, "\u2028") {
			t.Errorf("part %d carries a raw U+2028 (a line end to older script engines)", i)
		}
		var p PagePart
		if err := json.Unmarshal([]byte(strings.TrimSuffix(strings.TrimPrefix(s, PageScriptPrefix), ")")), &p); err != nil {
			t.Fatalf("part %d: %v", i, err)
		}
		if p.ID != 7 || p.Name != name || p.Part != i || p.Parts != 3 || p.Error != "" {
			t.Errorf("part %d: %+v", i, p)
		}
		raw, err := base64.StdEncoding.DecodeString(p.Data)
		if err != nil || len(raw) > 4<<20 {
			t.Errorf("part %d: %d bytes, %v", i, len(raw), err)
		}
		joined = append(joined, raw...)
	}
	if !bytes.Equal(joined, data) {
		t.Error("the parts join back to the file")
	}
	ref := PageScripts(8, OpenFile{Name: "c.txt", Why: "not a plan"}, 4<<20)
	var p PagePart
	if len(ref) != 1 || json.Unmarshal([]byte(strings.TrimSuffix(strings.TrimPrefix(ref[0], PageScriptPrefix), ")")), &p) != nil || p.Error != "not a plan" || p.Data != "" || p.Parts != 1 {
		t.Errorf("a refusal is one part with its words and no data: %v", ref)
	}
	if empty := PageScripts(9, OpenFile{Name: "e.xdl", Data: []byte{}}, 4<<20); len(empty) != 1 {
		t.Errorf("an empty file is one part: %d", len(empty))
	}
}

func TestAssocLinesL232(t *testing.T) {
	exe := `C:\Program Files\pgvigil\pgvigil-app.exe`
	lines := AssocLines(exe)
	got := map[string]RegLine{}
	for _, l := range lines {
		if !strings.HasPrefix(l.Key, `Software\Classes\`) {
			t.Errorf("only under Software\\Classes (HKCU or HKLM): %+v", l)
		}
		if (l.Key == `Software\Classes\.sqlplan` || l.Key == `Software\Classes\.xdl`) && l.Name == "" {
			t.Errorf("the extension's default (its default handler) is never written: %+v", l)
		}
		got[l.Key+"|"+l.Name] = l
	}
	for _, c := range []struct{ ext, progid string }{{".sqlplan", "pgvigil.sqlplan.1"}, {".xdl", "pgvigil.xdl.1"}} {
		if l, ok := got[`Software\Classes\`+c.ext+`\OpenWithProgids|`+c.progid]; !ok || l.Kind != RegNone || l.Value != "" {
			t.Errorf("%s lists %s in OpenWithProgids as an empty REG_NONE: %+v", c.ext, c.progid, l)
		}
		pk := `Software\Classes\` + c.progid
		if l, ok := got[pk+"|AllowSilentDefaultTakeOver"]; !ok || l.Kind != RegNone {
			t.Errorf("%s never takes the default: %+v", c.progid, l)
		}
		if l := got[pk+`\shell\open\command|`]; l.Kind != RegSz || l.Value != `"`+exe+`" "%1"` {
			t.Errorf("%s's command: %+v", c.progid, l)
		}
		if l := got[pk+`\shell\open|MultiSelectModel`]; l.Value != "Document" {
			t.Errorf("%s's selection model (a start per file, Explorer's 15): %+v", c.progid, l)
		}
		if l := got[pk+`\DefaultIcon|`]; l.Value != exe+",0" {
			t.Errorf("%s's icon: %+v", c.progid, l)
		}
	}
	if len(lines) != 10 {
		t.Errorf("ten lines, got %d: %+v", len(lines), lines)
	}
}

func TestAssocRemovalL232(t *testing.T) {
	keys, values := AssocRemoval()
	// a key goes only after its subkeys (RegDeleteKey removes a key with none), and only pgvigil's own ProgID trees
	seen := map[string]bool{}
	for i, k := range keys {
		if !strings.HasPrefix(k, `Software\Classes\pgvigil.`) {
			t.Errorf("only pgvigil's ProgIDs are deleted: %s", k)
		}
		for _, later := range keys[i+1:] {
			if strings.HasPrefix(later, k+`\`) {
				t.Errorf("%s comes after its parent %s", later, k)
			}
		}
		seen[k] = true
	}
	for _, want := range []string{`Software\Classes\pgvigil.sqlplan.1`, `Software\Classes\pgvigil.xdl.1`, `Software\Classes\pgvigil.sqlplan.1\shell\open\command`} {
		if !seen[want] {
			t.Errorf("%s is deleted", want)
		}
	}
	// the extensions' OpenWithProgids keys stay (other programs list themselves there); only pgvigil's values go
	if len(values) != 2 {
		t.Fatalf("two values: %+v", values)
	}
	for _, v := range values {
		if !strings.HasSuffix(v.Key, `\OpenWithProgids`) || !strings.HasPrefix(v.Name, "pgvigil.") {
			t.Errorf("only pgvigil's OpenWithProgids value: %+v", v)
		}
	}
	// every key the install writes is removed by the uninstall
	for _, l := range AssocLines(`C:\x\pgvigil-app.exe`) {
		if strings.HasSuffix(l.Key, `\OpenWithProgids`) {
			continue
		}
		if !seen[l.Key] {
			t.Errorf("written, never removed: %s", l.Key)
		}
	}
}
