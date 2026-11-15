package config

import (
	"fmt"
	"strings"
)

// CQ is the request queue's collector side (task CQ, 0200): with enabled a `pgvigil run` takes the requests serve
// writes into the repository for the instances it holds and runs them with the logins it already holds. Off by
// default: a collector loads no actions or explain login and opens no LISTEN connection until a person turns it on.
type CQ struct {
	// Enabled turns the worker on in this collector (cq: enabled: true). Off = every request for this collector's
	// instances is refused at the insert with 'no collector takes requests (cq.enabled in that collector's pgvigil.yaml)'.
	Enabled bool `yaml:"enabled"`
	// Workers is how many requests run at once (default 4, 1 to 16), plus one slot kept for kill, cancel, terminate and
	// job stop; at most 2 run on one instance at a time.
	Workers int `yaml:"workers"`
	// ResultKeep is how long a read's result stays in the repository: read (the default: until its asker has read it,
	// or 1 hour) or 7d. 7d opens every stored result to every pgvigil user for 7 days.
	ResultKeep string `yaml:"result_keep"`
}

// ActionsVia is serve's side: direct (the default; serve connects to the monitored servers itself, one host) or queue
// (serve writes each action and community run into the repository and a collector with cq.enabled runs it; serve
// then connects to nothing but the repository, as reader + auth + requester, never as the collector login).
type ActionsVia struct {
	Via string `yaml:"via"`
}

// Queue reports whether serve sends its actions through the repository queue.
func (a ActionsVia) Queue() bool { return a.Via == "queue" }

// CQWorkersMax is the most cq.workers may be.
const CQWorkersMax = 16

func (c *Config) validateCQ() error {
	switch c.Actions.Via {
	case "":
		c.Actions.Via = "direct"
	case "direct", "queue":
	default:
		return fmt.Errorf("actions.via must be direct or queue (got %q)", c.Actions.Via)
	}
	if c.CQ.Workers == 0 {
		c.CQ.Workers = 4
	}
	if c.CQ.Workers < 1 || c.CQ.Workers > CQWorkersMax {
		return fmt.Errorf("cq.workers must be 1 to %d (got %d)", CQWorkersMax, c.CQ.Workers)
	}
	switch c.CQ.ResultKeep {
	case "":
		c.CQ.ResultKeep = "read"
	case "read", "7d":
	default:
		return fmt.Errorf("cq.result_keep must be read or 7d (got %q)", c.CQ.ResultKeep)
	}
	for i := range c.Instances {
		in := &c.Instances[i]
		if err := checkAllowList(in.CommunityAllow, false); err != nil {
			return fmt.Errorf("instance %q: community_allow: %w", in.Name, err)
		}
		if err := checkAllowList(in.JobsAllow, true); err != nil {
			return fmt.Errorf("instance %q: jobs_allow: %w", in.Name, err)
		}
	}
	return nil
}

// checkAllowList: ST4's lists (DBA Dash's AllowedScripts / AllowedJobs). all or none alone; else names, and for jobs
// '*' and '-name' exclusions as DBA Dash's AllowedJobs.
func checkAllowList(l []string, jobs bool) error {
	for _, v := range l {
		t := strings.TrimSpace(v)
		switch {
		case t == "":
			return fmt.Errorf("an empty entry")
		case (t == "all" || t == "none") && len(l) > 1:
			return fmt.Errorf("%s stands alone", t)
		case !jobs && (t == "*" || strings.HasPrefix(t, "-")):
			return fmt.Errorf("%q: the community list takes all, none or tool names", t)
		case len(t) > 200:
			return fmt.Errorf("an entry over 200 characters")
		}
	}
	return nil
}

// Allowed reads an ST4 list for one name: unset = def; all / none; names (case-ignored); for jobs '*' allows every
// name not excluded by a '-name' entry. The second value is the words of a refusal, naming the key.
func Allowed(l []string, name, key string, def bool) (bool, string) {
	if len(l) == 0 {
		if def {
			return true, ""
		}
		return false, fmt.Sprintf("%s is not set for this instance (all, none or a list in pgvigil.yaml)", key)
	}
	n := strings.ToLower(strings.TrimSpace(name))
	star, named := false, false
	for _, v := range l {
		t := strings.ToLower(strings.TrimSpace(v))
		switch {
		case t == "all":
			return true, ""
		case t == "none":
			return false, fmt.Sprintf("%s is none for this instance", key)
		case strings.HasPrefix(t, "-") && t[1:] == n:
			return false, fmt.Sprintf("%s excludes %s for this instance", key, name)
		case t == "*":
			star = true
		case t == n:
			named = true
		}
	}
	if named || star {
		return true, ""
	}
	return false, fmt.Sprintf("%s is not in %s for this instance", name, key)
}
