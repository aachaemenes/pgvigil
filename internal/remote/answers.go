package remote

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// The repository's answers a SQL Server run asks beside its cursors (store.Reader). A remote collector has no repository
// and no Admin rows: each answer is its SQL function's with none, over the collector's own pgvigil.yaml. Admin's
// per-instance edits never reach a remote site (docs/remote-collector.md).

// settingsAnswers are the settings functions' answers with no Admin rows. import_mssql_security_parts (0159 L1-12 of its
// definition) reads mssql_security_settings, a view (0159 L540) that gives every rule its default when no config row
// sets it: a part is wanted when one of its rules is on by default (mssql_security_rule_defs.default_on, 0159 L314-360),
// auth always, logins also when owner_allow is on with no owner_allow list - so databases (owner_allow, owner_deny,
// cert_expired, cert_expiring, orphaned_user on), auth (auth_scheme) and logins (sa_exists, windows_login_disabled,
// windows_group_disabled, password_expiry) are wanted; registry, proxies and server_perms (every rule off) are not.
// TestAnswersAgainstSQL holds it to the function on a store: a default changed in a migration turns that row red.
var settingsAnswers = map[string]string{
	"import_mssql_security_parts": `{"parts": {"auth": true, "databases": true, "logins": true, "proxies": false, "registry": false, "server_perms": false}}`,
}

// MSSQLSettings answers a collection's settings function as the repository's would with no Admin rows.
func (s *Store) MSSQLSettings(_ context.Context, instanceID int, fn string) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := s.name(instanceID); err != nil {
		return nil, err
	}
	a, ok := settingsAnswers[fn]
	if !ok {
		return nil, fmt.Errorf("remote store: no remote answer for the settings function %q (internal/remote/answers.go)", fn)
	}
	return []byte(a), nil
}

type counterLayer struct {
	object, counter, inst, action, kind string
	level                               int
	blocked                             bool
}

// jsonText is a JSON value as PostgreSQL's ->> gives it: a string as it is, any other value as its JSON text, a null or
// a missing key as SQL NULL (ok false).
func jsonText(m map[string]any, k string) (string, bool) {
	v, ok := m[k]
	if !ok || v == nil {
		return "", false
	}
	if s, isStr := v.(string); isStr {
		return s, true
	}
	b, err := json.Marshal(v)
	return string(b), err == nil
}

// MSSQLCounterList answers the instance's counter list as pgvigil.import_mssql_counter_list does with no Admin rows
// (0152: mssql_counter_layers, mssql_counter_layers_won, mssql_counter_list): the defaults (level 1) and the yaml's
// root (2) and instance (5) lines; per object, counter (both without regard to case) and instance the highest level
// wins, a remove before an add, then the kind; a remove of a counter a page reads is blocked (it never wins); a won add
// is listed with its scope, its kind (else the nearest lower layer's of the same instance) and, for every instance,
// the instances a won remove takes out. The list is sorted by object, counter and instance byte-wise (the store sorts
// by its collation; the collector reads it as a set).
func (s *Store) MSSQLCounterList(_ context.Context, instanceID int, yaml []byte) ([]byte, error) {
	s.mu.Lock()
	name, err := s.name(instanceID)
	engine := s.ident[name].Engine
	s.mu.Unlock()
	if err != nil {
		return nil, err
	}
	if engine != "sqlserver" {
		return nil, fmt.Errorf("import_mssql_counter_list: instance %d is not a SQL Server instance", instanceID)
	}
	var layers []counterLayer
	for _, d := range counterDefaults {
		layers = append(layers, counterLayer{object: d[0], counter: d[1], action: "add", kind: d[2], level: 1})
	}
	var lines []map[string]any
	dec := json.NewDecoder(bytes.NewReader(yaml))
	dec.UseNumber()
	var raw any
	if len(bytes.TrimSpace(yaml)) > 0 && dec.Decode(&raw) == nil {
		if arr, ok := raw.([]any); ok {
			for _, e := range arr {
				if m, ok := e.(map[string]any); ok {
					lines = append(lines, m)
				}
			}
		}
	}
	trim := func(s string) string { return strings.Trim(s, " ") } // btrim
	for _, m := range lines {
		action, _ := jsonText(m, "action")
		layer, _ := jsonText(m, "layer")
		object, _ := jsonText(m, "object")
		counter, _ := jsonText(m, "counter")
		inst, _ := jsonText(m, "inst")
		kind, _ := jsonText(m, "kind")
		object, counter, inst = trim(object), trim(counter), trim(inst)
		if (action != "add" && action != "remove") || (layer != "root" && layer != "instance") || object == "" || counter == "" ||
			(kind != "" && kind != "count" && kind != "rate" && kind != "gauge") {
			continue
		}
		level := 2
		if layer == "instance" {
			level = 5
		}
		layers = append(layers, counterLayer{object: object, counter: counter, inst: inst, action: action, kind: kind, level: level})
	}
	for i := range layers {
		layers[i].blocked = layers[i].action == "remove" && mssql.CounterInUse(layers[i].object, layers[i].counter) != ""
	}
	type key struct {
		o, c, inst string
		blocked    bool
	}
	groups := map[key][]int{}
	var order []key
	for i, l := range layers {
		k := key{strings.ToLower(l.object), strings.ToLower(l.counter), l.inst, l.blocked}
		if _, seen := groups[k]; !seen {
			order = append(order, k)
		}
		groups[k] = append(groups[k], i)
	}
	var won []counterLayer
	for _, k := range order {
		if k.blocked {
			continue
		}
		idx := groups[k]
		sort.SliceStable(idx, func(a, b int) bool {
			x, y := layers[idx[a]], layers[idx[b]]
			if x.level != y.level {
				return x.level > y.level
			}
			if (x.action == "remove") != (y.action == "remove") {
				return x.action == "remove"
			}
			return x.kind < y.kind
		})
		won = append(won, layers[idx[0]])
	}
	except := map[[2]string][]string{}
	for _, w := range won {
		if w.action == "remove" && w.inst != "" {
			k := [2]string{strings.ToLower(w.object), strings.ToLower(w.counter)}
			except[k] = append(except[k], w.inst)
		}
	}
	type entry struct {
		Object  string   `json:"object"`
		Counter string   `json:"counter"`
		Inst    string   `json:"inst"`
		Scope   string   `json:"scope"`
		Kind    string   `json:"kind"`
		Except  []string `json:"except,omitempty"`
	}
	out := []entry{}
	for _, w := range won {
		if w.action != "add" {
			continue
		}
		e := entry{Object: w.object, Counter: w.counter, Inst: w.inst, Scope: "instance", Kind: w.kind}
		if lo := strings.ToLower(w.object); lo == "databases" || lo == "database replica" {
			e.Scope = "database"
		}
		if e.Kind == "" {
			best := 0
			for _, b := range layers {
				if strings.EqualFold(b.object, w.object) && strings.EqualFold(b.counter, w.counter) && b.inst == w.inst &&
					b.level < w.level && b.kind != "" && b.level > best {
					best, e.Kind = b.level, b.kind
				}
			}
		}
		if w.inst == "" {
			if x := except[[2]string{strings.ToLower(w.object), strings.ToLower(w.counter)}]; len(x) > 0 {
				e.Except = append([]string{}, x...)
				sort.Strings(e.Except)
			}
		}
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Object != out[j].Object {
			return out[i].Object < out[j].Object
		}
		if out[i].Counter != out[j].Counter {
			return out[i].Counter < out[j].Counter
		}
		return out[i].Inst < out[j].Inst
	})
	return json.Marshal(out)
}
