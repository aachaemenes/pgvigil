package config

import (
	"fmt"
	"regexp"
	"strings"
)

// baseSegment is one segment of web.base_path
var baseSegment = regexp.MustCompile(`^[A-Za-z0-9._~-]+$`)

// ValidBasePath holds web.base_path (and serve's -base-path) to one form: empty (the root), or a path that starts with
// '/', does not end with one, and whose every segment is ASCII letters, digits, '.', '_', '~' or '-', never '.' or
// '..' alone - the path a reverse proxy passes whole, so every link pgvigil writes can carry it as it is: a byte past
// ASCII or a ';' drops out of the session cookie's path (the browser never sends it back), and a '%' makes every
// request an invalid escape.
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
		if !baseSegment.MatchString(seg) {
			return fmt.Errorf("web.base_path %q: the segment %q holds a character other than ASCII letters, digits, '.', '_', '~' and '-'", p, seg)
		}
	}
	return nil
}
