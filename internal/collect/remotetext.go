package collect

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"regexp"

	"github.com/aachaemenes/pgvigil/internal/logparse"
)

// The remote collector's text rule (R5, client promise 3: no statement text leaves a remote collector). A remote
// collector stores query_text hash (its default) or none; the text policy (applyTextPolicy) rewrites the keys it knows,
// and RemoteDeny - run by the remote store on every batch before it reaches a bundle - denies by default: per view the
// fields of remotePass pass as they are, every other string is the hex SHA-256 of its normalized form (hash) or NULL
// (none). remoteTextKeys are the fields reviewed as text (statements, plans, messages, definitions, results); they
// never pass, and internal/remote's import scan makes every key an import reads either pass or one of these.

// remoteTextKeys are text in every view that reads them.
var remoteTextKeys = map[string]bool{
	"query": true, "statement": true, "blocked_statement": true, "plan_text": true,
	"detail": true, "warning_detail": true, "validation_detail": true,
	"message": true, "last_message": true, "return_message": true, "status_message": true,
	"error": true, "error_message": true, "error_text": true, "last_connect_error_text": true, "status_text": true,
	"definition": true, "filter_definition": true, "script": true, "sql": true,
	"graph": true, "report": true, "shape": true, "output": true, "parameters": true, "predicate": true,
	"rec_details": true, "text": true, "text1": true, "text2": true,
	"processes": true, "resources": true, "problems": true, "pgvigil_blocked_reports": true, "checks": true,
}

// remoteTextByView are text in the named views only, where the same name elsewhere is no text: a job step's command
// (jobs, mssql_jobs, mssql_maintenance's CommandLog; elsewhere a statement's tag, SELECT or INSERT), an Extended Events
// result (job_steps' result is a step's result code), a custom report's rows (statements' rows is a count).
var remoteTextByView = map[[2]string]bool{
	{"jobs", "command"}: true, {"mssql_jobs", "command"}: true, {"mssql_maintenance", "command"}: true,
	{"mssql_xe", "result"}: true, {"custom", "rows"}: true, {"mssql_custom", "rows"}: true,
}

var hashedRE = regexp.MustCompile(`^[0-9a-f]{64}$`)

// RemotePassList is a view's list of fields that pass as they are; ok false for a view with none.
func RemotePassList(view string) ([]string, bool) {
	l, ok := remotePass[view]
	return l, ok
}

// RemoteTextKey says whether a field of a view is reviewed as text.
func RemoteTextKey(view, key string) bool {
	return remoteTextKeys[key] || remoteTextByView[[2]string{view, key}]
}

// RemotePasses says whether a field of a view passes as it is.
func RemotePasses(view, key string) bool {
	for _, k := range remotePass[view] {
		if k == key {
			return !RemoteTextKey(view, key)
		}
	}
	return false
}

// remoteHash is a text's fingerprint: the hex SHA-256 of its normalized form (a message by its shape); a value already
// in that form (the text policy's own) stays as it is.
func remoteHash(key, s string) string {
	if hashedRE.MatchString(s) {
		return s
	}
	n := normalizeSQL(s)
	if key == "message" || key == "last_message" || key == "return_message" || key == "status_message" {
		n = logparse.MessageShape(s)
	}
	h := sha256.Sum256([]byte(n))
	return hex.EncodeToString(h[:])
}

// RemoteDeny applies the remote text rule to a batch of a view, in place: a listed field passes as it is (a listed list
// or object is walked: its own fields follow the same list), any other string - or a list or an object not listed - is
// hashed (a list or an object by its JSON text) or nulled; numbers, booleans and times pass. A view with no list, or a
// mode but hash or none, is refused in words.
func RemoteDeny(view string, rows []map[string]any, mode string) error {
	if mode != "hash" && mode != "none" {
		return fmt.Errorf("remote text: query_text %q on a remote collector (hash or none): no statement text leaves a remote collector", mode)
	}
	list, ok := remotePass[view]
	if !ok {
		return fmt.Errorf("remote text: no remote text list for the view %s (internal/collect/remotetext_pass.go): its rows do not leave a remote collector", view)
	}
	pass := map[string]bool{}
	for _, k := range list {
		if !RemoteTextKey(view, k) {
			pass[k] = true
		}
	}
	for _, r := range rows {
		denyMap(r, pass, mode)
	}
	return nil
}

func denyMap(m map[string]any, pass map[string]bool, mode string) {
	for k, v := range m {
		m[k] = denyValue(k, v, pass[k], pass, mode)
	}
}

func denyValue(key string, v any, passed bool, pass map[string]bool, mode string) any {
	switch x := v.(type) {
	case nil:
		return nil
	case string:
		if passed {
			return x
		}
		if mode == "none" {
			return nil
		}
		return remoteHash(key, x)
	case []byte:
		if passed {
			return x
		}
		if mode == "none" {
			return nil
		}
		return remoteHash(key, string(x))
	case map[string]any:
		if passed {
			denyMap(x, pass, mode)
			return x
		}
	case []any:
		if passed {
			for i, e := range x {
				if s, isStr := e.(string); isStr {
					x[i] = s
					continue
				}
				x[i] = denyValue(key, e, true, pass, mode)
			}
			return x
		}
	case []string:
		if passed {
			return x
		}
	case []map[string]any:
		if passed {
			for _, e := range x {
				denyMap(e, pass, mode)
			}
			return x
		}
	default:
		return v // numbers, booleans, times
	}
	if mode == "none" {
		return nil
	}
	b, err := json.Marshal(v)
	if err != nil {
		return nil
	}
	return remoteHash(key, string(b))
}
