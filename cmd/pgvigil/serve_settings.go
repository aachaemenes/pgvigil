package main

import (
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/engines"
	"github.com/aachaemenes/pgvigil/internal/web"
)

// pageSettingsConfig is Admin > Instances' Settings for serve (the ServiceConfig takes, ST5a): the engines' judgement
// of what the panel sends, the panel's catalogue with this file's global schedules:, and the stale check's rule for a
// page instance (the same as for an instance of the file).
func pageSettingsConfig(cfg *config.Config) *web.PageSettingsConfig {
	cat := map[string][]web.PageCollectionView{}
	for _, e := range []string{config.EnginePostgres, config.EngineSQLServer} {
		for _, c := range engines.PageCatalogue(e) {
			cat[e] = append(cat[e], web.PageCollectionView{Name: c.Name, DefaultS: int(cfg.Interval(config.Instance{}, c.Name, c.Default) / time.Second),
				BuiltinS: int(c.Default / time.Second), Box: c.Box, Never: c.Never})
		}
	}
	return &web.PageSettingsConfig{Check: engines.CheckPageSettings, Catalogue: cat, FloorS: int(config.PageScheduleFloor / time.Second),
		Intervals: func(in config.Instance) map[string]int { return instanceIntervals(cfg, in) }}
}

// instanceIntervals is an instance's effective interval of every collection in seconds: 0 where it is off, or the
// collection is another engine's or gated off by the instance's config (no aws: block), so the stale check never
// flags a row an earlier build left behind.
func instanceIntervals(cfg *config.Config, in config.Instance) map[string]int {
	m := map[string]int{}
	for _, c := range engines.AllSpecs() {
		if skip, _ := engines.Gated(in, c.Name); skip {
			m[c.Name] = 0
			continue
		}
		m[c.Name] = int(cfg.Interval(in, c.Name, c.Default) / time.Second)
	}
	return m
}
