package mssql

import "github.com/aachaemenes/pgvigil/internal/collect"

// Inert forms of mssql_funcstats' pieces, so that the rows of funcstats_test.go fail on what they assert.

var funcStatsViews = []struct{ kind, view string }{{"function", ""}, {"trigger", ""}}

func funcStatsQuery(kind, view string, names bool, have map[string]bool) string { return "" }

func unnamedTriggerDatabases(rows []collect.Row, server map[int64]string) []int64 { return nil }

func nameTriggers(rows []collect.Row, server map[int64]string, byDB map[int64]map[int64]string) {}
