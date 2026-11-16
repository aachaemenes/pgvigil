package demo

import (
	"testing"
	"time"
)

// TestSeedWindow: the seed's partitions are made from a minute before the grid's first point (SeedPooler's first read)
// to the month after the anchor's, the daily parent's days to two days after the anchor (N4 T7). Its behaviour's red
// row is the partition-deadlock proof's R8 (no partition made inside an import call during a seed over a month).
func TestSeedWindow(t *testing.T) {
	at := func(s string) time.Time {
		v, err := time.Parse("2006-01-02 15:04", s)
		if err != nil {
			t.Fatal(err)
		}
		return v.UTC()
	}
	for _, c := range []struct {
		name                   string
		end                    string
		days                   int
		from, monthsTo, daysTo string
	}{
		{"mid-month", "2026-11-15 12:34", 7, "2026-11-08 12:29", "2026-12-01 00:00", "2026-11-17 12:34"},
		{"a month's last minute", "2026-11-30 23:59", 1, "2026-11-29 23:54", "2026-12-01 00:00", "2026-12-02 23:59"},
		{"a grid from the first of a month: the minute before is the month before", "2026-12-08 00:00", 7,
			"2026-11-30 23:59", "2027-01-01 00:00", "2026-12-10 00:00"},
		{"over a year's end", "2027-01-03 08:00", 10, "2026-12-24 07:59", "2027-02-01 00:00", "2027-01-05 08:00"},
	} {
		end := at(c.end)
		from, monthsTo, daysTo := seedWindow(Grid(end, c.days), end)
		if !from.Equal(at(c.from)) || !monthsTo.Equal(at(c.monthsTo)) || !daysTo.Equal(at(c.daysTo)) {
			t.Errorf("%s: seedWindow = %s, %s, %s; want %s, %s, %s", c.name, from.Format(time.DateTime), monthsTo.Format(time.DateTime),
				daysTo.Format(time.DateTime), c.from, c.monthsTo, c.daysTo)
		}
	}
}

// TestHasEngine: the storage year's months are made for a fleet with a SQL Server instance only.
func TestHasEngine(t *testing.T) {
	specs := Specs("demo-", FleetSize)
	if !hasEngine(specs, EngineSQLServer) {
		t.Errorf("the default fleet of %d holds no %s instance", len(specs), EngineSQLServer)
	}
	var pg []Spec
	for _, s := range specs {
		if s.Engine == "" {
			pg = append(pg, s)
		}
	}
	if len(pg) == 0 || hasEngine(pg, EngineSQLServer) {
		t.Errorf("a PostgreSQL-only fleet of %d: hasEngine(%s) is not false", len(pg), EngineSQLServer)
	}
}
