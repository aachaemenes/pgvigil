package logparse

import (
	"regexp"
	"strings"
)

// The log line classes taken from the pganalyze collector's logs/analyze.go (github.com/pganalyze/collector), used
// under its licence:
//
//	Copyright (c) 2016, pganalyze Team <team@pganalyze.com>
//	All rights reserved.
//	Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
//	following conditions are met:
//	* Redistributions of source code must retain the above copyright notice, this list of conditions and the following
//	  disclaimer.
//	* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the
//	  following disclaimer in the documentation and/or other materials provided with the distribution.
//	* Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote
//	  products derived from this software without specific prior written permission.
//	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
//	INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//	DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
//	SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//	SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
//	WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//	OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// What was taken: the message prefixes (and, where a prefix alone is ambiguous, the regexp) of the classes below
// (pgvigil's changes are marked in the list: the PostgreSQL 18 wordings and the MultiXact forms),
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
// messageDetail: the kinds whose detail is the server's own message, never statement text (the corruption
// reader's and these classes'); the collector's text policy keeps such a detail whole and governs the statement.
var messageDetail = func() map[Kind]bool {
	m := map[Kind]bool{Corruption: true}
	for _, k := range Kinds {
		m[k] = true
	}
	return m
}()

// DetailIsMessage reports whether an event of this kind carries the server's own message as its detail.
func DetailIsMessage(k Kind) bool { return messageDetail[k] }

// AllKinds lists every kind the two readers emit, the base kinds first, then the pganalyze classes' (the Logs API
// accepts exactly these as a filter).
func AllKinds() []Kind {
	return append([]Kind{Slow, LockWait, Deadlock, AuthFail, Plan, Corruption}, Kinds...)
}

// KnownKind reports whether s names a kind the readers emit.
func KnownKind(s string) bool {
	for _, k := range AllKinds() {
		if string(k) == s {
			return true
		}
	}
	return false
}

// Kinds lists the event kinds the pganalyze classes add, one per class; the join's log_events CHECK lists them.
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
	// pgvigil: the MultiXact form of the warning too
	{"TXID_WRAPAROUND_WARNING", Wraparound, []string{"database"}, regexp.MustCompile(`^database (with OID (\d+)|"(.+?)") must be vacuumed (within (\d+) transactions|before (\d+) more MultiXactIds are used)`)},
	// pgvigil: every wording of the stop - before PostgreSQL 18 "... commands to avoid wraparound data loss ...", from 18
	// "... commands that assign new transaction IDs (or MultiXactIds) to avoid wraparound data loss ...", and the older
	// MultiXact "... commands that generate new MultiXactIds ..."
	{"TXID_WRAPAROUND_ERROR", Wraparound, []string{"database is not accepting commands"}, regexp.MustCompile(`^database is not accepting commands [a-zA-Z ]*?to avoid (?:multixact )?wraparound data loss in database`)},
	// pgvigil: PostgreSQL 18 names the backend type ("client backend (PID 83) was terminated by signal 11") where
	// earlier releases say "server process"
	{"SERVER_CRASHED", Crash, []string{""}, regexp.MustCompile(`^(?:server process|[a-z][a-z ]*(?:backend|worker|process|sender|receiver)) \(PID (\d+)\) was terminated by signal (6|11)(: [\w ]+)?`)},
	{"SERVER_CRASHED", Crash, []string{"terminating any other active server processes", "all server processes terminated; reinitializing"}, nil},
	{"SERVER_OUT_OF_MEMORY", OutOfMemory, []string{"out of memory"}, nil},
	{"SERVER_OUT_OF_MEMORY", OutOfMemory, []string{""}, regexp.MustCompile(`^(?:server process|[a-z][a-z ]*(?:backend|worker|process|sender|receiver)) \(PID (\d+)\) was terminated by signal (9)(: [\w ]+)?`)},
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
