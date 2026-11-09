package web

import (
	"net/http"
)

// TagsUI is the config's ui: block as the tree reads it: GroupBy the folder levels (tag keys, in order; empty =
// one folder per tag), EnvOrder the values listed first in every level, in that order (prod first).
type TagsUI struct {
	GroupBy  []string `json:"group_by"`
	EnvOrder []string `json:"env_order"`
}

// sqlTagPairs is the fleet's merged tags (config and pgvigil tag overrides, 0032), one row per key and value.
const sqlTagPairs = `
SELECT p.instance_id, p.key, p.value, p.source
  FROM pgvigil.instance_tag_pairs p JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active
 ORDER BY p.instance_id, p.key, p.value`

// sqlTagKeys is every tag key in use, with how many instances carry it.
const sqlTagKeys = `
SELECT p.key, count(DISTINCT p.instance_id) AS instances, count(DISTINCT p.value) AS tag_values
  FROM pgvigil.instance_tag_pairs p JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active
 GROUP BY p.key
 ORDER BY p.key`

// Tags is GET /api/tags: the ui: block, the tag keys in use and the merged pairs per instance (each with its
// source, config or override). The instances read carries the same merge as the written tags list
// (instance_tags_merged); this read is what the tree groups by and the Summary filters and sorts on.
func (s *Server) Tags(ui TagsUI) http.HandlerFunc {
	if ui.GroupBy == nil {
		ui.GroupBy = []string{}
	}
	if ui.EnvOrder == nil {
		ui.EnvOrder = []string{}
	}
	return func(w http.ResponseWriter, r *http.Request) {
		out := struct {
			TagsUI
			Keys  *table `json:"keys"`
			Pairs *table `json:"pairs"`
		}{TagsUI: ui}
		var err error
		if out.Keys, err = s.query(r.Context(), sqlTagKeys); err != nil {
			s.reply(w, r, nil, err)
			return
		}
		out.Pairs, err = s.query(r.Context(), sqlTagPairs)
		s.reply(w, r, out, err)
	}
}
