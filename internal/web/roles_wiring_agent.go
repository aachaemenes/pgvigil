package web

// B24f's join wiring for rel-agent / rel-agent-fold (read first): an investigation request sets the
// site's agent to work on a monitored server's finding or a question (operator, as a community run); its close is an
// operator's, as an acknowledgement's end; Run is the answered ask's stored SELECT on the repository through reports_dsn
// (operator: each run is a row of the request's record - docs/roles.md's needs table). The refusal words, beside roles.go's
// routeWhat in a file of their own.
func init() {
	routeWhat["POST /api/investigations"] = "asking the agent for an investigation"
	routeWhat["POST /api/investigations/close"] = "closing an investigation"
	routeWhat["POST /api/investigations/run"] = "running an answered ask"
}
