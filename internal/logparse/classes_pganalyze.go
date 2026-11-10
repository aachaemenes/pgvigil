package logparse

import (
	"regexp"
	"strings"
)

// The log line classes taken from the pganalyze collector's logs/analyze.go (github.com/pganalyze/collector), used
// under its licence:
//
//	Copyright (c) 2016, pganalyze Team <team@pganalyze.com>. All rights reserved. BSD 3-Clause License:
//	redistribution and use in source and binary forms, with or without modification, are permitted provided that
//	the conditions of the licence are met (the full text is in THIRD-PARTY-NOTICES.md).
//
// What was taken: the message prefixes (and, where a prefix alone is ambiguous, the regexp) of the classes below,
// which identify a server log message whatever its log_line_prefix; pganalyze's class name is kept beside each.
// What was not: its secret marking and redaction, its detail and hint matching, its per-class field extraction,
// and the classes pgvigil does not store (connection received / authorized / disconnected, checkpoint progress,
// the SQL error classes such as syntax errors and constraint violations; pgvigil's reader already has slow
// statements, lock waits, deadlocks and failed logins, and the corruption messages are the corruption reader's).
//
// Each class maps to one pgvigil event kind; ClassifyMore is called for a message no other rule of the reader
// classified. The kinds this file adds to log_events (the join's CHECK must list them): see Kinds.

// The kinds of event the pganalyze classes add.
const (
	ConnectionLimit      Kind = "connection_limit"      // out of connection slots, a role's or a database's limit
	ConnectionLost       Kind = "connection_lost"       // the client went away with a transaction open
	Timeout              Kind = "timeout"               // a statement or lock timeout cancelled a statement
	Canceled             Kind = "canceled"              // a statement cancelled on request (pg_cancel_backend, a driver)
	AutovacuumCancel     Kind = "autovacuum_cancel"     // an autovacuum task cancelled to give way to a lock
	VacuumSkipped        Kind = "vacuum_skipped"        // VACUUM / ANALYZE skipped a table it could not lock
	Wraparound           Kind = "wraparound"            // the transaction ID wraparound warning or the stop
	CheckpointFrequent   Kind = "checkpoint_frequent"   // checkpoints closer than checkpoint_warning
	Crash                Kind = "crash"                 // a backend died of a signal and the server restarted the others
	OutOfMemory          Kind = "out_of_memory"         // an allocation failed, or the kernel killed a backend
	ArchiveFailed        Kind = "archive_failed"        // archive_command failed (WAL piles up)
	StandbyConflict      Kind = "standby_conflict"      // a query on a standby cancelled by a replay conflict
	SerializationFailure Kind = "serialization_failure" // a repeatable read / serializable transaction must retry
	TempFile             Kind = "temp_file"             // a temporary file at or above log_temp_files
)

// Kinds lists every kind this file adds, in order.
var Kinds = []Kind{ConnectionLimit, ConnectionLost, Timeout, Canceled, AutovacuumCancel, VacuumSkipped, Wraparound,
	CheckpointFrequent, Crash, OutOfMemory, ArchiveFailed, StandbyConflict, SerializationFailure, TempFile}

// Class is one pganalyze log line class as pgvigil takes it.
type Class struct {
	Name     string         // pganalyze's classification name
	Kind     Kind           // the pgvigil event kind
	Prefixes []string       // the message starts with one of these
	Match    *regexp.Regexp // and, when set, matches this too
}

// Classes is the taken list, in pganalyze's order.
var Classes = []Class{
	{"AUTOVACUUM_CANCEL", AutovacuumCancel, []string{"canceling autovacuum task"}, nil},
	{"SKIPPING_ANALYZE_LOCK_NOT_AVAILABLE", VacuumSkipped, []string{"skipping analyze of"}, regexp.MustCompile(`^skipping analyze of "([^"]+)" --- lock not available`)},
	{"SKIPPING_VACUUM_LOCK_NOT_AVAILABLE", VacuumSkipped, []string{"skipping vacuum of"}, regexp.MustCompile(`^skipping vacuum of "([^"]+)" --- lock not available`)},
	{"CHECKPOINT_TOO_FREQUENT", CheckpointFrequent, []string{"checkpoints"}, regexp.MustCompile(`^checkpoints are occurring too frequently \((\d+) seconds? apart\)`)},
	{"CONNECTION_LOST_OPEN_TX", ConnectionLost, []string{"unexpected EOF on client connection with an open transaction"}, nil},
	{"OUT_OF_CONNECTIONS", ConnectionLimit, []string{"remaining connection slots are reserved for non-replication superuser connections", "sorry, too many clients already",
		// PostgreSQL 16 and later word the reserved-slots message by role attribute
		"remaining connection slots are reserved for"}, nil},
	{"TOO_MANY_CONNECTIONS_ROLE", ConnectionLimit, []string{"too many connections for role"}, regexp.MustCompile(`^too many connections for role "([^"]+)"`)},
	{"TOO_MANY_CONNECTIONS_DATABASE", ConnectionLimit, []string{"too many connections for database"}, regexp.MustCompile(`^too many connections for database "([^"]+)"`)},
	{"WAL_ARCHIVE_COMMAND_FAILED", ArchiveFailed, []string{"archive command"}, regexp.MustCompile(`^archive command (?:failed with exit code (\d+)|was terminated by signal (\d+)(: [\w ]+)?)`)},
	{"WAL_ARCHIVE_COMMAND_FAILED", ArchiveFailed, []string{"archiver process"}, regexp.MustCompile(`^archiver process \(PID \d+\) exited with exit code \d+`)},
	{"LOCK_TIMEOUT", Timeout, []string{"canceling statement due to lock timeout"}, nil},
	{"TXID_WRAPAROUND_WARNING", Wraparound, []string{"database"}, regexp.MustCompile(`^database (with OID (\d+)|"(.+?)") must be vacuumed within (\d+) transactions`)},
	{"TXID_WRAPAROUND_ERROR", Wraparound, []string{"database is not accepting commands to avoid wraparound data loss in database"}, nil},
	{"SERVER_CRASHED", Crash, []string{"server process"}, regexp.MustCompile(`^server process \(PID (\d+)\) was terminated by signal (6|11)(: [\w ]+)?`)},
	{"SERVER_CRASHED", Crash, []string{"terminating any other active server processes", "all server processes terminated; reinitializing"}, nil},
	{"SERVER_OUT_OF_MEMORY", OutOfMemory, []string{"out of memory"}, nil},
	{"SERVER_OUT_OF_MEMORY", OutOfMemory, []string{"server process"}, regexp.MustCompile(`^server process \(PID (\d+)\) was terminated by signal (9)(: [\w ]+)?`)},
	{"SERVER_TEMP_FILE_CREATED", TempFile, []string{"temporary file: path "}, regexp.MustCompile(`^temporary file: path "(.+?)", size (\d+)`)},
	{"STANDBY_STATEMENT_CANCELED", StandbyConflict, []string{"canceling statement due to conflict with recovery"}, nil},
	{"COULD_NOT_SERIALIZE_REPEATABLE_READ", SerializationFailure, []string{"could not serialize access due to concurrent update"}, nil},
	{"COULD_NOT_SERIALIZE_SERIALIZABLE", SerializationFailure, []string{"could not serialize access due to read/write dependencies among transactions"}, nil},
	{"STATEMENT_CANCELED_TIMEOUT", Timeout, []string{"canceling statement due to statement timeout"}, nil},
	{"STATEMENT_CANCELED_USER", Canceled, []string{"canceling statement due to user request"}, nil},
}

// ClassifyMore returns the kind and pganalyze class of a message no other rule classified. The level is the
// entry's (LOG, ERROR, FATAL, PANIC, WARNING); DETAIL / HINT / CONTEXT / STATEMENT continuation entries never reach it.
func ClassifyMore(level, msg string) (Kind, string, bool) {
	switch level {
	case "LOG", "WARNING", "ERROR", "FATAL", "PANIC":
	default:
		return "", "", false
	}
	for _, c := range Classes {
		for _, p := range c.Prefixes {
			if strings.HasPrefix(msg, p) && (c.Match == nil || c.Match.MatchString(msg)) {
				return c.Kind, c.Name, true
			}
		}
	}
	return "", "", false
}
