// Package versions holds PostgreSQL's release table: every minor release of the majors pgvigil reads, with
// its date, and each major's first release and end of life. It answers "how far behind is this server"
// (minors behind the newest of its major), "how old is its minor" and "how long until its major is out of
// support" without a network call.
//
// The table is static and is updated at each pgvigil release (README, "Release table"): add the release
// day to releaseDays (every supported major's new minor ships on the same day) and a new major to majors.
// AsOf says when it was last brought up to date; a server newer than the table shows as "newer than the
// table", never as behind.
//
// Source: postgresql.org/support/versioning (first and final release per major) and the release notes
// pages postgresql.org/docs/release/<version> (each minor's release date), read 2026-11-09.
package versions

import (
	"sort"
	"time"
)

// AsOf is the day the table was last checked against postgresql.org.
var AsOf = day("2026-11-09")

// Major is one major version's support window.
type Major struct {
	Major int
	First time.Time // x.0
	EOL   time.Time // the final minor's planned (or past) release: no fixes after it
}

// majors: postgresql.org/support/versioning, 2026-11-09. 19 had a release candidate (2026-10-15), no release.
var majors = []Major{
	{12, day("2019-10-03"), day("2024-11-21")},
	{13, day("2020-09-24"), day("2025-11-13")},
	{14, day("2021-09-30"), day("2026-11-12")},
	{15, day("2022-10-13"), day("2027-11-11")},
	{16, day("2023-09-14"), day("2028-11-09")},
	{17, day("2024-09-26"), day("2029-11-08")},
	{18, day("2025-09-25"), day("2030-11-14")},
}

// releaseDays: the minors released together on each day, newest first, from 14.0 on (12 and 13 from
// 2023-11-09 on: older minors of an out-of-support major count toward "behind" by number, without a date).
// 18.5 was never released (the release index goes 18.4, 18.6).
var releaseDays = []struct {
	date     string
	versions []string
}{
	{"2026-08-13", []string{"18.6", "17.11", "16.15", "15.19", "14.24"}},
	{"2026-05-14", []string{"18.4", "17.10", "16.14", "15.18", "14.23"}},
	{"2026-02-26", []string{"18.3", "17.9", "16.13", "15.17", "14.22"}},
	{"2026-02-12", []string{"18.2", "17.8", "16.12", "15.16", "14.21"}},
	{"2025-11-13", []string{"18.1", "17.7", "16.11", "15.15", "14.20", "13.23"}},
	{"2025-09-25", []string{"18.0"}},
	{"2025-08-14", []string{"17.6", "16.10", "15.14", "14.19", "13.22"}},
	{"2025-05-08", []string{"17.5", "16.9", "15.13", "14.18", "13.21"}},
	{"2025-02-20", []string{"17.4", "16.8", "15.12", "14.17", "13.20"}},
	{"2025-02-13", []string{"17.3", "16.7", "15.11", "14.16", "13.19"}},
	{"2024-11-21", []string{"17.2", "16.6", "15.10", "14.15", "13.18", "12.22"}},
	{"2024-11-14", []string{"17.1", "16.5", "15.9", "14.14", "13.17", "12.21"}},
	{"2024-09-26", []string{"17.0"}},
	{"2024-08-08", []string{"16.4", "15.8", "14.13", "13.16", "12.20"}},
	{"2024-05-09", []string{"16.3", "15.7", "14.12", "13.15", "12.19"}},
	{"2024-02-08", []string{"16.2", "15.6", "14.11", "13.14", "12.18"}},
	{"2023-11-09", []string{"16.1", "15.5", "14.10", "13.13", "12.17"}},
	{"2023-09-14", []string{"16.0"}},
	{"2023-08-10", []string{"15.4", "14.9"}},
	{"2023-05-11", []string{"15.3", "14.8"}},
	{"2023-02-09", []string{"15.2", "14.7"}},
	{"2022-11-10", []string{"15.1", "14.6"}},
	{"2022-10-13", []string{"15.0"}},
	{"2022-08-11", []string{"14.5"}},
	{"2022-06-16", []string{"14.4"}},
	{"2022-05-12", []string{"14.3"}},
	{"2022-02-10", []string{"14.2"}},
	{"2021-11-11", []string{"14.1"}},
	{"2021-09-30", []string{"14.0"}},
}

// skipped are minor numbers that were never released.
var skipped = map[int]map[int]bool{18: {5: true}}

// Status is one server version read against the table.
type Status struct {
	Major, Minor   int
	Known          bool      // the major is in the table
	Latest         int       // the newest minor of the major in the table
	LatestDate     time.Time // its release date
	BehindBy       int       // minors released after this one (the skipped ones not counted); 0 when current or newer
	Newer          bool      // the server is newer than the table (the table is out of date)
	ReleasedAt     time.Time // this minor's release date; zero when the table has no date for it
	EOL            time.Time
	EOLPassed      bool
	EOLInMonths    int // whole months from now to the EOL; negative once past
	ReleasedDaysAgo int // days since this minor's release; -1 when unknown
}

type minor struct {
	n    int
	date time.Time
}

var byMajor = func() map[int][]minor {
	m := map[int][]minor{}
	for _, d := range releaseDays {
		t := day(d.date)
		for _, v := range d.versions {
			maj, mi := split(v)
			m[maj] = append(m[maj], minor{mi, t})
		}
	}
	for k := range m {
		sort.Slice(m[k], func(i, j int) bool { return m[k][i].n < m[k][j].n })
	}
	return m
}()

// Majors returns the support table, oldest first.
func Majors() []Major { return append([]Major(nil), majors...) }

// Lookup reads server_version_num (180006 = 18.6) against the table at now.
func Lookup(versionNum int, now time.Time) Status {
	// the table's dates are UTC days: compare dates, so "passed" and the month count agree on the EOL day
	u := now.UTC()
	now = time.Date(u.Year(), u.Month(), u.Day(), 0, 0, 0, 0, time.UTC)
	s := Status{Major: versionNum / 10000, Minor: versionNum % 10000, ReleasedDaysAgo: -1}
	var mj *Major
	for i := range majors {
		if majors[i].Major == s.Major {
			mj = &majors[i]
		}
	}
	ms := byMajor[s.Major]
	if versionNum < 100000 || mj == nil || len(ms) == 0 {
		return s
	}
	s.Known = true
	s.EOL = mj.EOL
	s.EOLPassed = !now.Before(mj.EOL)
	s.EOLInMonths = monthsBetween(now, mj.EOL)
	last := ms[len(ms)-1]
	s.Latest, s.LatestDate = last.n, last.date
	if s.Minor > last.n {
		s.Newer = true
	}
	for n := s.Minor + 1; n <= last.n; n++ {
		if !skipped[s.Major][n] {
			s.BehindBy++
		}
	}
	for _, m := range ms {
		if m.n == s.Minor {
			s.ReleasedAt = m.date
			s.ReleasedDaysAgo = int(now.Sub(m.date).Hours() / 24)
		}
	}
	return s
}

// monthsBetween counts whole months from a to b (negative when b is before a).
func monthsBetween(a, b time.Time) int {
	if b.Before(a) {
		return -monthsBetween(b, a)
	}
	n := (b.Year()-a.Year())*12 + int(b.Month()) - int(a.Month())
	if b.Day() < a.Day() {
		n--
	}
	return n
}

func split(v string) (int, int) {
	maj, mi, dot := 0, 0, false
	for _, c := range v {
		switch {
		case c == '.':
			dot = true
		case !dot:
			maj = maj*10 + int(c-'0')
		default:
			mi = mi*10 + int(c-'0')
		}
	}
	return maj, mi
}

func day(s string) time.Time {
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		panic("versions: bad date " + s)
	}
	return t
}
