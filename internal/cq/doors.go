package cq

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// doorRow is one row of import_cq_doors' array.
type doorRow struct {
	Instance string `json:"instance"`
	Kind     string `json:"kind"`
	Name     string `json:"name,omitempty"`
	Open     bool   `json:"open"`
	Why      string `json:"why,omitempty"`
}

// engineFits: a kind of one engine has no door on an instance of the other.
func engineFits(k Kind, in config.Instance) bool {
	if k.Engine == "any" {
		return true
	}
	eng := in.Engine
	if eng == "" {
		eng = config.EnginePostgres
	}
	return k.Engine == eng
}

// doorRows is every door of every registered kind on every held instance, from this collector's configuration alone:
// the kind's own door (Name "") and its named doors (a tool, a job). An instance of the other engine gets none.
func doorRows(base Env, held map[string]config.Instance) []doorRow {
	var out []doorRow
	for _, kind := range registered() {
		k, r := Kinds[kind], runnerOf(kind)
		for _, in := range held {
			if !engineFits(k, in) {
				continue
			}
			env := base
			env.Instance = in
			for _, d := range r.Doors(&env) {
				out = append(out, doorRow{Instance: in.Name, Kind: kind, Name: d.Name, Open: d.Open, Why: d.Why})
			}
		}
	}
	return out
}

// publishDoors replaces this worker's doors whole in the repository.
func publishDoors(ctx context.Context, pool *pgxpool.Pool, id string, rows []doorRow) error {
	if rows == nil {
		rows = []doorRow{}
	}
	b, err := json.Marshal(rows)
	if err != nil {
		return err
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_cq_doors($1, $2::jsonb)`, id, string(b)); err != nil {
		return fmt.Errorf("cq: the doors: %w", err)
	}
	return nil
}

// doorNow re-checks a claimed request's doors on this collector at the run (the published row may be stale): the
// kind's own door, then the named door of the request's tool or job. "" = open; else the collector's words.
func doorNow(env *Env, r Request, run Runner) string {
	k := Kinds[r.Kind]
	if !engineFits(k, env.Instance) {
		return fmt.Sprintf("%s is a %s kind and %s is not", r.Kind, k.Engine, env.Instance.Name)
	}
	name := ""
	if k.DoorField != "" {
		name = doorName(r.Payload, k.DoorField)
	}
	own := false // a name with no door of its own follows the kind's door
	for _, d := range run.Doors(env) {
		switch {
		case d.Name == "":
			if !d.Open {
				return d.Why
			}
			own = true
		case name != "" && d.Name == name && !d.Open:
			return d.Why
		}
	}
	if !own {
		return fmt.Sprintf("%s is not through the queue yet on %s", r.Kind, env.Instance.Name)
	}
	return ""
}

// doorName is the value of a payload's door field.
func doorName(p any, field string) string {
	b, err := json.Marshal(p)
	if err != nil {
		return ""
	}
	m := map[string]any{}
	if json.Unmarshal(b, &m) != nil {
		return ""
	}
	s, _ := m[field].(string)
	return s
}
