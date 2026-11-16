// Package textnow holds the statement-text policy's rule AT READ for the findings that quote a statement (TEXT-NOW):
// a finding's detail or value built from stored statement text follows the instance's query_text policy as it is
// now, not as the text was stored. The web replies (internal/web/textread.go) and the alert sends (internal/alerts)
// both use it.
package textnow

import (
	"regexp"
	"strings"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// findRule: where a finding's detail and value quote a statement (the text from the match's end on); nil = none quoted.
type findRule struct{ detail, value *regexp.Regexp }

// findText: the findings arms that put stored statement text into a detail or a value (the inventory of TEXT-NOW;
// the views of 0029, 0054, 0061, 0064, 0065, 0114, 0119, 0124, 0145), by their check name.
var findText = map[string]findRule{
	"temp-file spills": {detail: regexp.MustCompile(`did not fit work_mem\. `)},
	"a blocking chain": {detail: regexp.MustCompile(`Its last statement: `)},
	"a session idle in a transaction over an hour holding locks": {detail: regexp.MustCompile(`Its last batch: `)},
	"a request running over an hour":                             {detail: regexp.MustCompile(`Statement: `)},
	"blocked-process reports naming the same head statement":     {value: regexp.MustCompile(`^`)},
	"an availability replica changed role or state":              {detail: regexp.MustCompile(`in the last hour(?:, a failover among them)?; `)},
	"an implicit transaction blocking":                           {detail: regexp.MustCompile(`Its (?:last batch|statement): `)},
	"a lead blocker":                                             {detail: regexp.MustCompile(`The statement: `)},
	"a transaction open for a long time":                         {detail: regexp.MustCompile(`its last statement: `)},
	"a memory grant over 15 % of max workspace":                  {detail: regexp.MustCompile(`over 15 %\)(?: in [^:]*)?: `)},
	"the version store grows while cleanup is at zero":           {detail: regexp.MustCompile(`last statement: `)},
	"the version store over a third of tempdb":                   {detail: regexp.MustCompile(`last statement: `)},
}

var (
	findPlanDetail   = regexp.MustCompile(`; the worst: plan \d+ \([^)]*\): `)
	findPlanFilter   = regexp.MustCompile(`removed by Filter: `)
	findCompareCheck = regexp.MustCompile(`^statement -?\d+$`)
	findCompareText  = regexp.MustCompile(`ms in all \(.*?\): `)
)

// findRuleOf is the rule of a finding's check: findText's, a plan finding's ('plan: <rule>': its worst plan's query,
// and the Filter a 'filter removes most rows' value quotes) or a compare finding's ('statement <queryid>').
func findRuleOf(check string) (findRule, bool) {
	if fr, ok := findText[check]; ok {
		return fr, true
	}
	if rule, ok := strings.CutPrefix(check, "plan: "); ok {
		fr := findRule{detail: findPlanDetail}
		if rule == "filter removes most rows" {
			fr.value = findPlanFilter
		}
		return fr, true
	}
	if findCompareCheck.MatchString(check) {
		return findRule{detail: findCompareText}, true
	}
	return findRule{}, false
}

// textCut is what stands for a statement a finding quoted, under none.
const textCut = "(not shown: this instance's query_text policy is none)"

// cutStmt keeps a finding's words up to where it quotes a statement and puts the statement under the policy: none =
// textCut in its place, normalized = its normalized form; no quote found = the text as it is.
func cutStmt(s string, re *regexp.Regexp, pol string) string {
	if re == nil {
		return s
	}
	loc := re.FindStringIndex(s)
	if loc == nil {
		return s
	}
	head, tail := s[:loc[1]], s[loc[1]:]
	if pol == "none" {
		return head + textCut
	}
	return head + collect.NormalizeSQL(tail)
}

// Finding is a finding's value and detail under the instance's policy mode (full | normalized | none) now: a check
// that quotes no statement, or the policy full, gives them back as they are.
func Finding(check, value, detail, mode string) (string, string) {
	fr, ok := findRuleOf(check)
	if !ok || mode == "" || mode == "full" {
		return value, detail
	}
	return cutStmt(value, fr.value, mode), cutStmt(detail, fr.detail, mode)
}

// Listed reports whether a finding's check quotes a statement.
func Listed(check string) bool {
	_, ok := findRuleOf(check)
	return ok
}

// SummaryLine is one line of the SQL Server Summary's cell ("<check>: <value> - <detail>", q_mssql_summary.go)
// under the policy mode: a check whose value is the statement cuts after "<check>: ", one that quotes it in its
// detail cuts at the detail's quote.
func SummaryLine(line, mode string) string {
	if mode == "" || mode == "full" {
		return line
	}
	for check, fr := range findText {
		rest, ok := strings.CutPrefix(line, check)
		if !ok {
			continue
		}
		if fr.value != nil {
			if v, ok := strings.CutPrefix(rest, ": "); ok {
				return check + ": " + cutStmt(v, fr.value, mode)
			}
			return line
		}
		return check + cutStmt(rest, fr.detail, mode)
	}
	return line
}
