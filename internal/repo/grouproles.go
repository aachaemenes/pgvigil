package repo

import (
	"regexp"
	"sync"
)

// groupRoleRe is how a migration makes a cluster-wide group role (each inside its own IF NOT EXISTS block)
var groupRoleRe = regexp.MustCompile(`CREATE ROLE (pgvigil_[a-z_]+) NOLOGIN`)

// GroupRoles are the cluster-wide group roles this build's migrations make ('CREATE ROLE pgvigil_<name> NOLOGIN'), in
// the order the files first make them - what 'uninstall -drop-repository' may drop, read from the files themselves so a
// group a later migration adds is never left behind by a second, hand-kept list.
var GroupRoles = sync.OnceValues(func() ([]string, error) {
	names, err := migrationNames()
	if err != nil {
		return nil, err
	}
	var out []string
	seen := map[string]bool{}
	for _, n := range names {
		b, err := migrations.ReadFile("sql/" + n)
		if err != nil {
			return nil, err
		}
		for _, m := range groupRoleRe.FindAllSubmatch(b, -1) {
			if g := string(m[1]); !seen[g] {
				seen[g] = true
				out = append(out, g)
			}
		}
	}
	return out, nil
})
