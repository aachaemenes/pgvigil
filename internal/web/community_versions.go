package web

// The community tools' versions (DBA Dash's Check Versions): each installed procedure's version read from its own text
// - a window of its definition around the version line, never the procedure run - against the version pgvigil was
// tested with, a word for the difference, and the install script printed for the DBA. pgvigil deploys nothing.

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// testedVersions: per catalogue group, the release pgvigil's proofs and lab ran (its date and the words the printed
// script names it by) and dbatools' installer for it. A kit's procedures carry versions of their own (Darling Data's
// release of 2026-11-01 holds sp_PressureDetector 6.11 beside sp_HealthParser 3.11): each procedure is compared with
// its own version in that release (testedProc).
var testedVersions = map[string]struct{ Date, Words, Install string }{
	"First Responder Kit": {"2026-07-02", "the First Responder Kit 8.34 (2026-07-02)", "Install-DbaFirstResponderKit"},
	"Darling Data":        {"2026-11-01", "Darling Data's release of 2026-11-01", "Install-DbaDarlingData"},
	"sp_WhoIsActive":      {"2026-04-09", "sp_WhoIsActive 2200.20260409 (2026-04-09)", "Install-DbaWhoIsActive"},
}

// testedProc: each catalogue procedure's version in its group's tested release, as the release files' own version
// lines give it (lower-case names)
var testedProc = map[string]string{
	"sp_blitz": "8.34", "sp_blitzfirst": "8.34", "sp_blitzcache": "8.34", "sp_blitzindex": "8.34", "sp_blitzlock": "8.34", "sp_blitzwho": "8.34",
	"sp_pressuredetector": "6.11", "sp_quickiestore": "6.11", "sp_humaneventsblockviewer": "5.11", "sp_healthparser": "3.11",
	"sp_loghunter": "3.11", "sp_indexcleanup": "2.11",
	"sp_whoisactive": "2200.20260409",
}

// testedOf: a procedure's version in the tested release ("" = not a catalogue procedure)
func testedOf(name string) string { return testedProc[strings.ToLower(name)] }

// the groups in the script's order
var testedOrder = []string{"First Responder Kit", "Darling Data", "sp_WhoIsActive"}

// toolVersion is what a procedure's text says of its version ("" = no version line in it, or the text not readable).
type toolVersion struct{ Version, Date string }

var (
	reVersion = regexp.MustCompile(`(?i)@version\s*=\s*'([0-9][0-9.]*)'`)
	reVerDate = regexp.MustCompile(`(?i)@version_?date\s*=\s*'([0-9]{8})'`)
	// sp_WhoIsActive's header: 'v2200.20260409' (its date in the version) or the older 'v12.00 (2021-11-10)'
	reWhoIs = regexp.MustCompile(`Who Is Active\? v([0-9]+)\.([0-9]+)(?: \(([0-9]{4}-[0-9]{2}-[0-9]{2})\))?`)
)

// parseVersion reads a version and its date from the windows of a procedure's text.
func parseVersion(windows ...string) toolVersion {
	var v toolVersion
	for _, w := range windows {
		if m := reWhoIs.FindStringSubmatch(w); m != nil && v.Version == "" {
			v.Version = m[1] + "." + m[2]
			if len(m[2]) == 8 {
				v.Date = m[2][:4] + "-" + m[2][4:6] + "-" + m[2][6:]
			} else {
				v.Date = m[3]
			}
		}
		if m := reVersion.FindStringSubmatch(w); m != nil && v.Version == "" {
			v.Version = m[1]
		}
		if m := reVerDate.FindStringSubmatch(w); m != nil && v.Date == "" {
			v.Date = m[1][:4] + "-" + m[1][4:6] + "-" + m[1][6:]
		}
	}
	return v
}

// compareVersions compares dotted numbers part by part (8.4 < 8.34: each part a number); 0 for equal.
func compareVersions(a, b string) int {
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var x, y int
		if i < len(pa) {
			x, _ = strconv.Atoi(pa[i])
		}
		if i < len(pb) {
			y, _ = strconv.Atoi(pb[i])
		}
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}

// versionWord: the word for an installed procedure's version against its own version in the tested release.
func versionWord(installed bool, v toolVersion, name string) string {
	t := testedOf(name)
	switch {
	case !installed:
		return "not installed"
	case v.Version == "" || t == "":
		return "version not read"
	}
	switch compareVersions(v.Version, t) {
	case 0:
		return "the tested version"
	case -1:
		return "older than tested"
	}
	return "newer than tested (not tested by pgvigil)"
}

// readVersions reads, for the catalogue's procedures installed in db, a window of each one's text around its version
// line (sys.sql_modules: VIEW DEFINITION, which the read login has; a NULL definition reads as no version). azure:
// the database the connection opens (no three-part name).
func readVersions(ctx context.Context, conn *sql.Conn, db string, azure bool, names []string) (map[string]toolVersion, error) {
	pre := msQuote(db) + "."
	if azure {
		pre = ""
	}
	win := func(pats ...string) string {
		parts := make([]string, 0, len(pats))
		for _, p := range pats {
			// under a case-insensitive collation: the definition's own (a case-sensitive database or server) would
			// miss the Kit's '@Version' against the pattern's '@version'
			parts = append(parts, "NULLIF(PATINDEX(N'"+p+"', m.definition COLLATE Latin1_General_100_CI_AS), 0)")
		}
		return "SUBSTRING(m.definition, COALESCE(" + strings.Join(parts, ", ") + ", 0), 120)"
	}
	q := `SELECT p.name, ` + win(`%@version = ''[0-9]%`, `%@version=''[0-9]%`) + `, ` + win(`%@version[_]date = ''[0-9]%`, `%@versiondate = ''[0-9]%`, `%@version[_]date=''[0-9]%`, `%@versiondate=''[0-9]%`) + `,
       ` + win(`%Who Is Active? v[0-9]%`) + `
  FROM ` + pre + `sys.procedures AS p JOIN ` + pre + `sys.schemas AS s ON s.schema_id = p.schema_id
  LEFT JOIN ` + pre + `sys.sql_modules AS m ON m.object_id = p.object_id
 WHERE s.name = N'dbo' AND p.name IN (` + strings.Join(names, ", ") + `)`
	rows, err := conn.QueryContext(ctx, q)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	out := map[string]toolVersion{}
	for rows.Next() {
		var n string
		var a, b, c sql.NullString
		if err := rows.Scan(&n, &a, &b, &c); err != nil {
			return nil, err
		}
		out[strings.ToLower(n)] = parseVersion(a.String, b.String, c.String)
	}
	return out, rows.Err()
}

// msServerOf: the server part of a SQL Server connection string for the printed script ('host,port' / 'host\name'),
// never its login or password; "" when it cannot be read.
func msServerOf(dsn string) string {
	if u, err := url.Parse(dsn); err == nil && u.Scheme == "sqlserver" && u.Host != "" {
		// with a port the connection goes to it (the driver ignores the instance name then): 'host,port' alone;
		// without one, 'host\instance'
		h := u.Hostname()
		if p := u.Port(); p != "" {
			return h + "," + p
		}
		if inst := strings.Trim(u.Path, "/"); inst != "" {
			h += `\` + inst
		}
		return h
	}
	for _, kv := range strings.Split(dsn, ";") {
		k, v, ok := strings.Cut(kv, "=")
		if ok && strings.EqualFold(strings.TrimSpace(k), "server") || ok && strings.EqualFold(strings.TrimSpace(k), "data source") {
			return strings.TrimPrefix(strings.TrimSpace(v), "tcp:")
		}
	}
	return ""
}

// psQuote is a PowerShell single-quoted string: PowerShell ends one at the ASCII quote and at the four single quotation
// marks U+2018-U+201B as well, so each is doubled
var psQuoter = strings.NewReplacer("'", "''", "\u2018", "\u2018\u2018", "\u2019", "\u2019\u2019", "\u201a", "\u201a\u201a", "\u201b", "\u201b\u201b")

func psQuote(s string) string { return "'" + psQuoter.Replace(s) + "'" }

// installScript: the script a DBA runs to install what is missing, older than tested or of no readable version in db
// (a newer one is left as it is), with dbatools; pgvigil runs none of it. notes: a group's procedures at different
// releases.
func installScript(name, server, db string, tools []toolState) (script string, notes []string) {
	need, seen := map[string]bool{}, map[string]map[string][]string{}
	for _, t := range tools {
		if t.Kind != "proc" || t.Installed == nil {
			continue
		}
		switch t.VersionWord {
		case "not installed", "older than tested", "version not read":
			need[t.Group] = true
		}
		if t.Version != nil {
			// a kit's release is its date (Darling Data's procedures differ in version within one release)
			rel, label := t.VersionDate, t.Name+" "+*t.Version
			if rel == "" {
				rel = "v" + *t.Version
			} else {
				label += " of " + t.VersionDate
			}
			if seen[t.Group] == nil {
				seen[t.Group] = map[string][]string{}
			}
			seen[t.Group][rel] = append(seen[t.Group][rel], label)
		}
	}
	for _, g := range testedOrder {
		if len(seen[g]) > 1 {
			vs := make([]string, 0, len(seen[g]))
			for _, ns := range seen[g] {
				sort.Strings(ns)
				vs = append(vs, strings.Join(ns, ", "))
			}
			sort.Strings(vs)
			notes = append(notes, g+": mixed versions ("+strings.Join(vs, "; ")+")")
		}
	}
	var b strings.Builder
	if len(need) == 0 {
		fmt.Fprintf(&b, "# There is nothing to install: every community procedure pgvigil reads is in %s at the tested version or newer.\n", db)
		return b.String(), notes
	}
	if server == "" {
		server = "<the server>"
	}
	fmt.Fprintf(&b, "# pgvigil printed this script and runs none of it. Run it yourself in PowerShell with dbatools (https://dbatools.io),\n")
	fmt.Fprintf(&b, "# as a login that may create procedures in %s.\n", db)
	fmt.Fprintf(&b, "# dbatools fetches each tool's newest release. pgvigil was tested with")
	for i, g := range testedOrder {
		sep := ","
		if i == len(testedOrder)-1 {
			sep = ":"
		} else if i == len(testedOrder)-2 {
			sep = " and"
		}
		fmt.Fprintf(&b, " %s%s", testedVersions[g].Words, sep)
	}
	fmt.Fprintf(&b, "\n# to install those, download their release files and add -LocalFile <the file> to each line.\n")
	fmt.Fprintf(&b, "$SqlInstance = %s   # %s in pgvigil\n", psQuote(server), name)
	for _, g := range testedOrder {
		if need[g] {
			fmt.Fprintf(&b, "%s -SqlInstance $SqlInstance -Database %s\n", testedVersions[g].Install, psQuote(db))
		}
	}
	return b.String(), notes
}
