package collect

import "github.com/aachaemenes/pgvigil/internal/config"

// The lead's WIRING of task 302: the read_tools opt-in of an instance's backups: block opens the tool reads.
func init() {
	backupReadTools = func(in config.Instance) bool { return in.Backups != nil && in.Backups.ReadTools }
}
