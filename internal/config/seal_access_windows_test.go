//go:build windows

package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

// TestSealAccessIsProtectedL9 (rn-l9 B1): a seal beside a configuration whose folder lets every local account read
// (System32's own inheritable 'Users read' entry, set here on a test folder) is not readable to them: secrets/ gets a
// protected list - SYSTEM and the Administrators, and no Users entry.
func TestSealAccessIsProtectedL9(t *testing.T) {
	dir := t.TempDir()
	sd, err := windows.SecurityDescriptorFromString("D:(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;GR;;;BU)")
	if err != nil {
		t.Fatal(err)
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		t.Fatal(err)
	}
	if err := windows.SetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, dacl, nil); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(dir, "pgvigil.yaml")
	if err := os.WriteFile(cfg, []byte("instances: []\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := SealFileSecret(cfg, "pg1", "host=h password=zz", ""); err != nil {
		t.Fatal(err)
	}
	got, err := windows.GetNamedSecurityInfo(filepath.Join(dir, "secrets"), windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		t.Fatal(err)
	}
	s := got.String()
	if !strings.Contains(s, "D:P") || strings.Contains(s, ";;;BU)") {
		t.Errorf("secrets/'s list %s: want a protected list without the Users entry", s)
	}
}
