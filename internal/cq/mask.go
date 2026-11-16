package cq

import (
	"bytes"
	"encoding/json"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// MaskResult is a run's result as the repository stores it, with task 415's credential mask over every string in it
// (CQ-16: every text and XML cell is masked BEFORE it is stored). A value that reads as an XML document (a showplan, a
// deadlock graph, a blocked process report) takes collect.MaskXML, mssql.MaskPlanXML's own mask, so it stays XML; any
// other text takes collect.MaskCredentials (a sqlcmd, bcp or osql -P, PASSWORD = '...', SECRET = '...', a
// password-named @ parameter, a connection string's or a URI's password, ConvertTo-SecureString, net use, and the
// collector's other forms). MaskXML keeps a processing instruction as it stands, and the Darling Data and First
// Responder Kit procedures write their query text as one (sp_WhoIsActive's sql_text and sql_command:
// <?query --\r\n...\r\n--?>), so each processing instruction's text is masked as a text first (maskCell; a processing
// instruction may hold '<', so <masked> keeps the document XML). Every string at any depth is masked - a cell, a
// column name, an object's key, a message, the run's own words. The value is read through its JSON form, the form it
// is stored in, with its numbers kept as written. The mask is idempotent, so a result whose runner masked its rows
// before its own size cut (the community kind's cqSets, MaskRows) comes through unchanged.
func MaskResult(v any) (any, error) {
	if v == nil {
		return nil, nil
	}
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var x any
	if err := d.Decode(&x); err != nil {
		return nil, err
	}
	return maskJSON(x), nil
}

// MaskText is one stored text with the result store's mask (maskCell): a run's words (its outcome, its refusal) as
// the store keeps them.
func MaskText(s string) string { return maskCell(s) }

// maskCell is the mask of one stored string: collect.MaskStored (MaskXML for a value that reads as XML - a processing
// instruction's text too, sp_WhoIsActive's <?query -- ... --?> cell among them - MaskCredentials otherwise).
func maskCell(s string) string {
	if s == "" {
		return s
	}
	return collect.MaskStored(s)
}

// maskJSON masks every string of a decoded JSON value, its objects' keys included, and returns it.
func maskJSON(v any) any {
	switch x := v.(type) {
	case string:
		return maskCell(x)
	case map[string]any:
		m := make(map[string]any, len(x))
		for k, e := range x {
			m[maskCell(k)] = maskJSON(e)
		}
		return m
	case []any:
		for i, e := range x {
			x[i] = maskJSON(e)
		}
	}
	return v
}

// MaskRows masks the text cells of rows in place, so a runner's own size cut measures what is stored; a cell of any
// other type is MaskResult's at the store.
func MaskRows(rows [][]any) {
	for _, r := range rows {
		for j, c := range r {
			if s, ok := c.(string); ok && s != "" {
				r[j] = maskCell(s)
			}
		}
	}
}

// MaskStrings masks each string of ss in place (a set's column names).
func MaskStrings(ss []string) {
	for i, s := range ss {
		ss[i] = maskCell(s)
	}
}
