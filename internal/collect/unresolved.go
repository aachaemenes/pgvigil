package collect

import "fmt"

// UnresolvedRefError is a connect whose connection string reference resolved to nothing - an env: variable not set, a
// file: not read, a dpapi: seal that does not open on this host (a host move): the server was not asked. It is no
// connect attempt (InstanceConnect adds no streak for it, so 'server unreachable' never counts it) and the run is
// recorded by Repo.LogReferenceFailure, which the instance's own finding 'connection string unresolved' reads
// (0497). Ref is the reference as written (env:X, file:..., dpapi:...), never its value; Why is its reason.
type UnresolvedRefError struct {
	Instance, Ref, Why string
}

func (e *UnresolvedRefError) Error() string {
	return fmt.Sprintf("connect %s: dsn %q resolved to an empty string (%s)", e.Instance, e.Ref, e.Why)
}
