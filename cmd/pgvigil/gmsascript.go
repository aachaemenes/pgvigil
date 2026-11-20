package main

import (
	"errors"
	"fmt"
	"strings"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// gmsaScript is the PowerShell a domain admin runs to make the group Managed Service Account pgvigil's service runs
// as (RELNOTES L142; DBA Dash 3.25's 'Script to create service account'). pgvigil prints it and runs none of it.
// hosts are the principals allowed to use the account: computers as NAME$, a group by its name.
func gmsaScript(user string, hosts []string) (string, error) {
	u := strings.TrimSpace(user)
	if !config.IsGMSAName(u) {
		return "", fmt.Errorf(`-print-gmsa: -user %q must be the gMSA to make, DOMAIN\name$`, u)
	}
	if len(hosts) == 0 {
		return "", errors.New("-print-gmsa: -host names no computer or group to use the account")
	}
	quoted := make([]string, 0, len(hosts))
	for _, h := range hosts {
		h = strings.TrimSpace(h)
		switch {
		case h == "":
			return "", errors.New("-print-gmsa: -host holds an empty name")
		case strings.ContainsAny(h, "'\"`;\\/[]:|=,+*?<>") || strings.IndexFunc(h, func(r rune) bool { return r < 0x20 }) >= 0:
			return "", fmt.Errorf("-print-gmsa: -host %q holds a character an account name cannot", h)
		}
		quoted = append(quoted, "'"+h+"'")
	}
	_, name, _ := strings.Cut(u, `\`)
	sam := strings.TrimSuffix(name, "$")
	// a name inside PowerShell's single quotes doubles its own ' (an apostrophe is a sAMAccountName character)
	psq := func(v string) string { return strings.ReplaceAll(v, "'", "''") }
	var b strings.Builder
	fmt.Fprintf(&b, "# The group Managed Service Account %s for the pgvigil service, printed by 'pgvigil install -print-gmsa':\n", u)
	b.WriteString("# pgvigil runs none of it. A gMSA has no password anyone types or keeps: the domain changes it itself.\n#\n")
	b.WriteString("# 1. A domain admin, on a machine with the ActiveDirectory PowerShell module (RSAT):\n")
	b.WriteString("#    the domain makes every gMSA password from a KDS root key - when this lists none, add one first (other\n")
	b.WriteString("#    domain controllers take up to 10 hours to see it; read your directory team's rule before adding one)\n")
	b.WriteString("Get-KdsRootKey\n")
	b.WriteString("# Add-KdsRootKey -EffectiveImmediately\n")
	fmt.Fprintf(&b, "New-ADServiceAccount -Name '%s' -DNSHostName ('%s.' + (Get-ADDomain).DNSRoot) -PrincipalsAllowedToRetrieveManagedPassword %s -KerberosEncryptionType AES128,AES256\n", psq(sam), psq(sam), strings.Join(quoted, ","))
	b.WriteString("#    a computer added to a group above uses the account after its next restart (its group membership)\n#\n")
	b.WriteString("# 2. On the pgvigil host, as an administrator (the same module): True = this host may use the account\n")
	fmt.Fprintf(&b, "Test-ADServiceAccount -Identity '%s'\n#\n", psq(sam))
	b.WriteString("# 3. Install the service as it (its 'Log on as a service' right is granted by the install):\n")
	fmt.Fprintf(&b, "pgvigil install -user '%s'\n#\n", psq(u))
	b.WriteString("# 4. On each SQL Server pgvigil reads, as a sysadmin, then the login's rights (docs/sqlserver.md, the login):\n")
	fmt.Fprintf(&b, "CREATE LOGIN [%s] FROM WINDOWS;\n", u)
	return b.String(), nil
}
