package config

import "strings"

// LookupName is the name LookupAccountName is given for a service account as pgvigil, its installer and the service
// manager write it: '.\user' (this computer's user, the service manager's form - the lookup does not read the dot)
// becomes '<computer>\user', and 'LocalSystem' (the service manager's name for SYSTEM) 'NT AUTHORITY\SYSTEM'; any
// other name is the trimmed name. computer is this host's NetBIOS name ("" = not read: '.\user' stays as it is).
func LookupName(account, computer string) string {
	a := strings.TrimSpace(account)
	if strings.EqualFold(a, "LocalSystem") {
		return `NT AUTHORITY\SYSTEM`
	}
	if rest, ok := strings.CutPrefix(a, `.\`); ok && computer != "" {
		return computer + `\` + rest
	}
	return a
}
