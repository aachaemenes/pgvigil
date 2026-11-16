package web

// livemask.go (CQ-LIVEMASK), RED STAGE: the calls stand where the mask goes (communityExec, auditRun, cqAuditRow);
// the mask itself is the next commit, so its rows run red against this one first.

func maskRun(run *instanceRun) { _ = run }

func maskAudit(row map[string]any) { _ = row }

func maskText(s string) string { return s }
