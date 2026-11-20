package scriptlint

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// dockerRm finds a container removal: 'docker rm' or 'docker container rm', its flags after it.
var dockerRm = regexp.MustCompile(`\bdocker\s+(?:container\s+)?rm((?:\s+-[-A-Za-z]+)*)`)

// forcedWithoutVolumes reports whether a removal's flags force it without removing the container's anonymous
// volumes: '-f' / '--force' with no '-v' / '--volumes' (short flags may be joined: -fv, -vf).
func forcedWithoutVolumes(flags string) bool {
	force, volumes := false, false
	for _, f := range strings.Fields(flags) {
		switch {
		case f == "--force":
			force = true
		case f == "--volumes":
			volumes = true
		case strings.HasPrefix(f, "-") && !strings.HasPrefix(f, "--"):
			force = force || strings.Contains(f, "f")
			volumes = volumes || strings.Contains(f, "v")
		}
	}
	return force && !volumes
}

// TestDockerRmRemovesAnonymousVolumes: every script under scripts/ that force-removes a container also removes its
// anonymous volumes ('docker rm -fv'). A 'docker rm -f' leaves each image's anonymous data volume (postgres, mssql)
// behind on the box at every run (VOLLEAK: 22.8 GB of them on one lab machine). -v removes anonymous volumes
// only; a named volume or a bind mount is never touched by it.
func TestDockerRmRemovesAnonymousVolumes(t *testing.T) {
	var bad []string
	err := filepath.WalkDir("../../scripts", func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if name := d.Name(); name == "node_modules" || strings.HasPrefix(name, ".") && path != "../../scripts" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".sh") {
			return nil
		}
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer func() { _ = f.Close() }()
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1024*1024), 1024*1024)
		for n := 1; sc.Scan(); n++ {
			line := sc.Text()
			if strings.HasPrefix(strings.TrimSpace(line), "#") {
				continue
			}
			for _, m := range dockerRm.FindAllStringSubmatch(line, -1) {
				if forcedWithoutVolumes(m[1]) {
					bad = append(bad, strings.TrimPrefix(path, "../../")+":"+strconv.Itoa(n))
				}
			}
		}
		return sc.Err()
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(bad) > 0 {
		t.Errorf("%d 'docker rm -f' without -v (each run leaves the container's anonymous volumes on the box; use 'docker rm -fv'):\n  %s",
			len(bad), strings.Join(bad, "\n  "))
	}
}

func TestForcedWithoutVolumes(t *testing.T) {
	for flags, want := range map[string]bool{
		" -f": true, " --force": true, " -fv": false, " -vf": false, " -f -v": false, " --force --volumes": false,
		" -v": false, "": false, " -f --volumes": false,
	} {
		if got := forcedWithoutVolumes(flags); got != want {
			t.Errorf("forcedWithoutVolumes(%q) = %v, want %v", flags, got, want)
		}
	}
	for line, want := range map[string]bool{
		`docker rm -f "$CT" >/dev/null 2>&1`: true, `docker ps -aq | xargs -r docker rm -f >/dev/null`: true,
		`docker rm -f`: true, `docker container rm -f x`: true, `docker rm -fv "$CT"`: false, `docker rm -f -v "$CT"`: false,
	} {
		m := dockerRm.FindStringSubmatch(line)
		if got := m != nil && forcedWithoutVolumes(m[1]); got != want {
			t.Errorf("%q: flagged %v, want %v", line, got, want)
		}
	}
}
