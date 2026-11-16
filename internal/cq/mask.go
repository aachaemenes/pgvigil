package cq

import (
	"bytes"
	"encoding/json"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// MaskResult is a run's result as the repository stores it, with task 415's credential mask over every string in it
// (CQ-16: every text and XML cell is masked BEFORE it is stored). A value that reads as an XML document (a showplan, a
// deadlock graph, a blocked process report, sp_WhoIsActive's sql_text) takes collect.MaskXML, mssql.MaskPlanXML's own
// mask, so it stays XML; any other text takes collect.MaskCredentials (a sqlcmd, bcp or osql -P, PASSWORD = '...',
// SECRET = '...', a password-named @ parameter, a connection string's or a URI's password, ConvertTo-SecureString,
// net use). Every string at any depth is masked - a cell, a column name, a message, the run's own words; an object's
// keys are the result's field names and are kept. The value is read through its JSON form, the form it is stored in,
// with its numbers kept as written. The mask is idempotent, so a result whose runner masked its rows before its own
// size cut (the community kind's cqSets, MaskRows) comes through unchanged.
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

// maskJSON masks every string of a decoded JSON value in place and returns it.
func maskJSON(v any) any {
	switch x := v.(type) {
	case string:
		return collect.MaskStored(x)
	case map[string]any:
		for k, e := range x {
			x[k] = maskJSON(e)
		}
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
				r[j] = collect.MaskStored(s)
			}
		}
	}
}

// MaskStrings masks each string of ss in place (a set's column names).
func MaskStrings(ss []string) {
	for i, s := range ss {
		if s != "" {
			ss[i] = collect.MaskStored(s)
		}
	}
}
