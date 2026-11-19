package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// FileRef is one env: / file: / dpapi: value of a configuration file and where it sits ('reports_dsn',
// 'instances[pg1].actions_dsn', 'alerts.channels[0].webhook').
type FileRef struct {
	Where string
	Raw   string
}

// IsReference says whether a whole value is an env:, file: or dpapi: reference (Resolve's forms).
func IsReference(v string) bool {
	v = strings.TrimSpace(v)
	return strings.HasPrefix(v, "env:") || strings.HasPrefix(v, "file:") || strings.HasPrefix(v, "dpapi:")
}

// FileReferences lists every reference of the file in its order, whatever block holds it (RELNOTES L241: 'pgvigil
// check' tests each), read from the YAML itself so a block another package reads (alerts:, export:) is in it too.
func FileReferences(path string) ([]FileRef, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(b, &doc); err != nil {
		return nil, fmt.Errorf("config %s: %w", path, err)
	}
	var out []FileRef
	var walk func(n *yaml.Node, where string)
	walk = func(n *yaml.Node, where string) {
		switch n.Kind {
		case yaml.DocumentNode:
			for _, c := range n.Content {
				walk(c, where)
			}
		case yaml.MappingNode:
			for i := 0; i+1 < len(n.Content); i += 2 {
				k := n.Content[i].Value
				if where != "" {
					k = where + "." + k
				}
				walk(n.Content[i+1], k)
			}
		case yaml.SequenceNode:
			for i, c := range n.Content {
				walk(c, where+"["+itemLabel(c, i)+"]")
			}
		case yaml.ScalarNode:
			if IsReference(n.Value) {
				out = append(out, FileRef{Where: where, Raw: strings.TrimSpace(n.Value)})
			}
		}
		// an alias repeats its anchor, which is read where it stands
	}
	walk(&doc, "")
	return out, nil
}

// itemLabel names a list item by its name: key when it has one (an instance), else by its index.
func itemLabel(n *yaml.Node, i int) string {
	if n.Kind == yaml.MappingNode {
		for j := 0; j+1 < len(n.Content); j += 2 {
			if n.Content[j].Value == "name" && n.Content[j+1].Kind == yaml.ScalarNode && strings.TrimSpace(n.Content[j+1].Value) != "" {
				return strings.TrimSpace(n.Content[j+1].Value)
			}
		}
	}
	return strconv.Itoa(i)
}
