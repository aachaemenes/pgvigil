package web

import (
	"runtime"
	"testing"
)

// A list source's path: a network (UNC) or device path is refused on every system (serve would open it over SMB as
// its machine account), on Windows anything but a drive letter; a path on this server's disk is taken.
func TestListPathOK(t *testing.T) {
	a := &InstancesAdmin{}
	refuse := []string{`\\host\share\list.txt`, `//host/share/list.txt`}
	take := []string{"/srv/lists/servers.txt"}
	if runtime.GOOS == "windows" {
		refuse = append(refuse, `/\host\share\list.txt`, `\/host\share\list.txt`, `\??\UNC\host\share\list.txt`, `\\?\UNC\host\share\list.txt`)
		take = []string{`C:\lists\servers.txt`, `D:/lists/servers.txt`}
	}
	for _, p := range refuse {
		if err := a.listPathOK(p); err == nil {
			t.Errorf("%s was taken as a list path", p)
		}
	}
	for _, p := range take {
		if err := a.listPathOK(p); err != nil {
			t.Errorf("%s was refused: %v", p, err)
		}
	}
}
