package collect

import (
	"strings"
	"testing"
	"unicode"

	"github.com/aachaemenes/pgvigil/internal/jobmask"
)

// s16RedGateCases are S16's Red Gate SQL Backup texts (scripts/proof-mssql-jobmask.sh rg1-rg6, its @@SUF@@ written
// out as Kq7v), each with its key.
var s16RedGateCases = []struct{ name, in, secret string }{
	{"rg1", `EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = ''/b/db1.sqb'' WITH PASSWORD = ''S16rg1Kq7v'', KEYSIZE = 256"'`, "S16rg1Kq7v"},
	{"rg2", `DECLARE @ReturnCode int EXECUTE @ReturnCode = dbo.sqlbackup N'-SQL "BACKUP DATABASE [db1] TO DISK = N''/b/db1.sqb'' WITH CHECKSUM, PASSWORD = N''S16rg2Kq7v''"' IF @ReturnCode <> 0 RAISERROR('Error performing SQLBackup backup.', 16, 1)`, "S16rg2Kq7v"},
	{"rg3", `EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = [rg S16rg3Kq7v] "'`, "S16rg3Kq7v"},
	{"rg4", `EXECUTE master..sqbutility 1032, N'db1', N'/b', 'D', '24h', 'S16rg4Kq7v'`, "S16rg4Kq7v"},
	{"rg5", `EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = [ab]]S16rg5Kq7v] "'`, "S16rg5Kq7v"},
	{"rg6", `EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = [ab,S16rg6Kq7v] "'`, "S16rg6Kq7v"},
}

// TestMaskJobTextComposed (J16 JOBMASK LEAK): MaskJobText composes two masks - package jobmask's job rules (S16 /
// S16b) and MaskCredentials (415) - and must hide everything either one hides alone, whatever each makes of the
// other's marks. The j16 candidate's resolution 9011e5ec ran MaskCredentials first: it masks only a prefix of a Red
// Gate value (a doubled value's N and opening quotes read as an empty literal, a bracketed value cut at its space or
// comma), and jobmask.Text then read the '<masked>' as a value already masked and left the key after it (j16d5's
// mssqljobmask rg2 / rg3 / rg6: the mark, then the key in its doubled quotes, or the key and its closing bracket after
// a space or a comma). The cases: S16's rg1-rg6 and 415's whole table (maskCredentialCases). Per case: none of its
// secret strings is in the output; no key follows a '<masked>' (the first word after each mark is not a word either
// mask alone takes out of the text); and no word either mask alone takes out is anywhere in the output. A word is a
// run of letters, digits and '_' of three characters or more (a literal's N or E prefix is no key).
func TestMaskJobTextComposed(t *testing.T) {
	type jobCase struct{ name, in, secret string }
	var cases []jobCase
	for _, c := range s16RedGateCases {
		cases = append(cases, jobCase{"S16 " + c.name, c.in, c.secret})
	}
	for _, c := range maskCredentialCases {
		cases = append(cases, jobCase{"415 " + c.name, c.in, c.secret})
	}
	for _, c := range cases {
		got := MaskJobText(c.in)
		if c.secret != "" && strings.Contains(got, c.secret) {
			t.Errorf("%s: the secret %q is in the output: %q", c.name, c.secret, got)
		}
		hidden := takenOut(c.in, jobmask.Text(c.in))
		for w := range takenOut(c.in, MaskCredentials(c.in)) {
			hidden[w] = true
		}
		for _, w := range wordsAfterMarks(got) {
			if hidden[w] {
				t.Errorf("%s: a key after '<masked>': %q in %q", c.name, w, got)
			}
		}
		for w := range textWords(got) {
			if hidden[w] {
				t.Errorf("%s: %q, which one mask alone takes out, is in the output: %q", c.name, w, got)
			}
		}
	}
}

// notWordRune: r is not part of a word (a letter, a digit or '_').
func notWordRune(r rune) bool { return !(unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_') }

// textWords is the set of s's words (runs of letters, digits and '_', three characters or more).
func textWords(s string) map[string]bool {
	ws := map[string]bool{}
	for _, w := range strings.FieldsFunc(s, notWordRune) {
		if len([]rune(w)) >= 3 {
			ws[w] = true
		}
	}
	return ws
}

// takenOut is the set of words of in that out no longer holds.
func takenOut(in, out string) map[string]bool {
	kept, gone := textWords(out), map[string]bool{}
	for w := range textWords(in) {
		if !kept[w] {
			gone[w] = true
		}
	}
	return gone
}

// wordsAfterMarks is the first word after each '<masked>' in s ("" when none follows).
func wordsAfterMarks(s string) []string {
	var after []string
	for i := strings.Index(s, "<masked>"); i >= 0; {
		rest := s[i+len("<masked>"):]
		w := ""
		for _, f := range strings.FieldsFunc(rest, notWordRune) {
			w = f
			break
		}
		after = append(after, w)
		j := strings.Index(rest, "<masked>")
		if j < 0 {
			break
		}
		i += len("<masked>") + j
	}
	return after
}
