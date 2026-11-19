package config

import (
	"fmt"
	"strings"
)

// ValidBasePath holds web.base_path (and serve's -base-path) to one form: empty (the root), or a path that starts with
// '/', does not end with one, and has no empty, '.' or '..' segment, no query, fragment, space or backslash - the
// path a reverse proxy passes whole, so every link pgvigil writes can carry it as it is.
func ValidBasePath(p string) error {
	if p == "" {
		return nil
	}
	if !strings.HasPrefix(p, "/") || strings.HasSuffix(p, "/") {
		return fmt.Errorf("web.base_path %q: write it with a leading '/' and no trailing one (e.g. /pgvigil), or leave it empty for the root", p)
	}
	if strings.ContainsAny(p, "?#\\ \t") {
		return fmt.Errorf("web.base_path %q: a path only - no query, fragment, space or backslash", p)
	}
	for _, seg := range strings.Split(p[1:], "/") {
		if seg == "" || seg == "." || seg == ".." {
			return fmt.Errorf("web.base_path %q: an empty, '.' or '..' segment", p)
		}
	}
	return nil
}
