package main

import (
	"regexp"
	"strings"
	"testing"
)

// The MSI workflow builds two packages, the previous version and this one, from one project folder: each build has an
// intermediate folder of its own and no incremental build, or the second finds the first's outputs up to date in the
// one obj\Release, links no package and fails its copy (MSB3030 after a fraction of a second).
func TestMSIWorkflowBuildsEachVersionApart(t *testing.T) {
	wf := readRepoFile(t, ".github/workflows/msi.yml")
	builds := regexp.MustCompile(`(?m)^.*dotnet build packaging/msi/pgvigil\.wixproj.*$`).FindAllString(wf, -1)
	if len(builds) == 0 {
		t.Fatal("msi.yml has no 'dotnet build packaging/msi/pgvigil.wixproj' line")
	}
	for _, b := range builds {
		if !strings.Contains(b, `"-p:IntermediateOutputPath=obj/$ver/"`) || !strings.Contains(b, "--no-incremental") {
			t.Errorf("msi.yml builds a version without its own intermediate folder and --no-incremental: %s", strings.TrimSpace(b))
		}
	}
}
