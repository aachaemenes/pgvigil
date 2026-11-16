package config

// AgentsConfig is the agents: block (docs/agents.md): the agent door on serve's pages - the Investigate button on a
// finding, the Ask box and the Investigations page - is off until enabled. pgvigil holds no agent, no model and no key:
// the site's own agent claims the requests through `pgvigil mcp` on a login IN ROLE pgvigil_reader, pgvigil_agent.
type AgentsConfig struct {
	Enabled bool `yaml:"enabled"`
}
