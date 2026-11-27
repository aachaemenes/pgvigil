package mssql

import (
	"strings"
	"testing"
)

// The noise list follows sp_LogHunter's at DarlingData 6.12: an SPN line is noise when it names the Service Principal
// Name (the registration messages), never because 'spn' stands inside another word - a real error about a database
// named ASPNETDB is kept.
func TestErrorLogNoiseSPNIsTheRegistrationMessageAlone(t *testing.T) {
	for line, want := range map[string]bool{
		"The SQL Server Network Interface library could not register the Service Principal Name (SPN) [ MSSQLSvc/db01.example.local ] for the SQL Server service. Windows return code: 0x2098, state: 15.": true,
		"The SQL Server Network Interface library successfully registered the Service Principal Name (SPN) [ MSSQLSvc/db01.example.local:1433 ] for the SQL Server service.":                               true,
		"Database 'ASPNETDB' cannot be opened due to inaccessible files or insufficient memory or disk space.":                                                                                             false,
		"Could not open file D:\\data\\spnotes.mdf for file number 1. OS error: 2(The system cannot find the file specified.).":                                                                            false,
	} {
		if got := errorLogNoise(strings.ToLower(line)); got != want {
			t.Errorf("%q: noise %v, want %v", line, got, want)
		}
	}
}
