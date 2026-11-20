// Admin > Instances' Settings (the ServiceConfig takes, ST5a): an instance added in the page gets its own schedules - a
// collection's interval, or off - and its statement-text policy, as pgvigil.yaml gives its own instances schedules:,
// disabled: and query_text:.
//
//   - POST /api/admin/instances op 'settings' {name, settings: {schedules: {<collection>: <seconds, 0 = off>},
//     query_text}} (instanceSettings): serve judges the names, the engine and the 1-minute floor
//     (engines.CheckPageSettings, handed in by cmd/ as PageSettingsConfig.Check) and sends its verdict with the write;
//     import_admin_instance_settings (0263) stores it, or refuses with serve's or its own words, and audits either way.
//   - GET /api/admin/instances gains 'settings' (each page instance's stored settings), 'settings_catalogue' (per
//     engine the collections the panel lists) and 'settings_floor_s' (instanceSettingsView).
//   - Serve's stale check follows a page instance's own intervals: each door set carries every merged page instance's
//     (PageSettingsConfig.Intervals, cmd/'s rule for a file instance), and expectedNow() (doorset.go) answers with them.
//
// The calls into this file are the WIRING patch's (scripts/admin-settings-serve-wiring.patch: q_instances_admin.go, web.go and the
// door set are shared).

package web

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/jackc/pgx/v5"
)

// PageSettingsConfig is what cmd/ hands serve for the Settings (web does not import the engines).
type PageSettingsConfig struct {
	// Check judges a page instance's settings in the panel's words (engines.CheckPageSettings)
	Check func(engine string, ps config.PageSettings) error
	// Catalogue: per engine the collections the panel lists, sorted by name
	Catalogue map[string][]PageCollectionView
	// Intervals: an instance's effective interval of every collection in seconds (0 = off, or never there), the
	// stale check's rule for an instance of pgvigil.yaml
	Intervals func(in config.Instance) map[string]int
	// FloorS is config.PageScheduleFloor in seconds
	FloorS int
	// Thresholds: a SQL Server instance's thresholds as the panel lists them (engines.ThresholdCatalogue, ST5b)
	Thresholds []PageThresholdView
}

// PageThresholdView is one threshold as the panel lists it: the collector's default; Patterns = backup_exclude (a list
// of LIKE patterns, no default).
type PageThresholdView struct {
	Name     string  `json:"name"`
	Default  float64 `json:"default"`
	Patterns bool    `json:"patterns"`
}

// pageSettingsOf holds each server's config (serve's SetPageSettings; demo and mcp set none): a registry, as the door
// sets are, so this file builds without the wiring patch.
var pageSettingsOf sync.Map // *Server -> *PageSettingsConfig

// SetPageSettings gives serve its Settings (cmd/pgvigil serve, before the door watcher starts).
func (s *Server) SetPageSettings(c *PageSettingsConfig) {
	if c != nil {
		pageSettingsOf.Store(s.self(), c)
	}
}

// settingsConfig is this server's Settings config; nil = none set here.
func (s *Server) settingsConfig() *PageSettingsConfig {
	if v, ok := pageSettingsOf.Load(s.self()); ok {
		return v.(*PageSettingsConfig)
	}
	return nil
}

// PageCollectionView is one collection as the panel lists it.
type PageCollectionView struct {
	Name string `json:"name"`
	// DefaultS: what an instance added here runs it at with no value of its own (pgvigil.yaml's global schedules:,
	// else the collection's own); BuiltinS: the collection's own (0 = opt-in)
	DefaultS int    `json:"default_s"`
	BuiltinS int    `json:"builtin_s"`
	Box      bool   `json:"box"`   // the running plans box's: never set in the panel
	Never    string `json:"never"` // why it never runs on an instance added here ("" = it may)
}

// instanceSettingsView adds the Settings' parts to the page's answer; like the checks it never fails the page: a
// repository without migration 0263 says so in settings_error.
func (s *Server) instanceSettingsView(ctx context.Context, out map[string]any) {
	if ps := s.settingsConfig(); ps != nil {
		out["settings_catalogue"], out["settings_floor_s"] = ps.Catalogue, ps.FloorS
		out["settings_thresholds"] = ps.Thresholds
	}
	// the statement-text policy an instance with none of its own follows (pgvigil.yaml's query_text:)
	out["settings_default_qt"] = s.doorsNow().DefaultQT
	t, err := s.query(ctx, `SELECT a.name, a.settings::text AS settings FROM pgvigil.admin_instances a ORDER BY a.name`)
	if err != nil {
		s.log.Warn("admin instances: the settings were not read", "err", err)
		out["settings"], out["settings_error"] = nil, "the instances' settings were not read: "+err.Error()
		return
	}
	out["settings"] = t
}

// instanceSettings is op 'settings'. pay is the write's payload as InstancesAdminWrite began it (op, ui_user, client,
// name, file_names).
func (s *Server) instanceSettings(w http.ResponseWriter, r *http.Request, user string, in map[string]any, pay map[string]any) {
	ctx := r.Context()
	name := str(in, "name")
	verdict := ""
	var ps config.PageSettings
	set, isObject := in["settings"].(map[string]any)
	raw, _ := json.Marshal(in["settings"])
	switch {
	case s.settingsConfig() == nil:
		verdict = "this server does not set an instance's settings (pgvigil serve does)"
	case !isObject:
		verdict = "settings must be an object"
	default:
		var err error
		if ps, err = config.ParsePageSettings(raw); err != nil {
			verdict = "the settings do not parse: " + err.Error()
		}
	}
	if verdict == "" {
		// the engine is the stored row's; a name with no row is the import's to refuse (with its words)
		have, err := s.pageInstance(ctx, name)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err)
			return
		}
		if have != nil {
			if err := s.settingsConfig().Check(have.Engine, ps); err != nil {
				verdict = err.Error()
			}
		}
	}
	// the settings as the editor read them (ST5b): 0266 refuses a write over a change made since
	if exp, ok := in["expect"].(map[string]any); ok {
		pay["expect"] = exp
	}
	if verdict == "" {
		pay["settings"] = ps.Stored()
	} else {
		pay["verdict"] = verdict
		if isObject {
			pay["settings"] = set
		}
	}
	ans, rawAns, err := s.callImport(ctx, "import_admin_instance_settings", pay)
	if err != nil {
		s.log.Error("admin instance: settings not written", "user", user, "name", name, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	s.log.Info("admin instance", "op", "settings", "name", name, "user", user, "outcome", ans.Outcome, "detail", ans.Detail)
	extra := map[string]any{}
	if ans.Outcome == "done" {
		// the collector reads the change within its poll (15 s) and restarts this instance's loops alone; this
		// serve's stale check follows as soon as its watcher has read it
		extra["takes_effect"] = "the collector takes the change within 15 s and restarts this instance's collections alone"
		// the thresholds' words only where 0266 says the save changed them (a schedule-only save keeps them as they
		// were; a save that takes them all away waits for the same read)
		var changed struct {
			Thresholds bool `json:"thresholds_changed"`
		}
		if json.Unmarshal(rawAns, &changed) == nil && changed.Thresholds {
			extra["takes_effect"] = extra["takes_effect"].(string) + "; its thresholds are stored at the instance's next HA/DR, jobs or backups read"
		}
		s.nudgeDoors()
	}
	s.answer(w, ans, rawAns, extra)
}

// nudgeDoors asks this serve's watcher to read the list at once (no wait: where no watcher runs it does nothing).
func (s *Server) nudgeDoors() {
	if v, ok := doorWake.Load(s.self()); ok {
		select {
		case v.(chan struct{}) <- struct{}{}:
		default: // a wake is already pending
		}
	}
}

// collectionsSettingsParts is what the tree's two dialogs need beside /api/instance/collections' rows (ST5b, the design
// pass's F4): "source" ("file", or "page" for an instance added in Admin > Instances that no pgvigil.yaml entry
// shadows); for a page instance its stored settings (read through admin_instance_settings(), the reader's grant), the
// catalogue entry of each of its engine's collections (box, never), the floor and the 30-day ceiling, and writable /
// why_not (the dialogs' Save is the panel's op).
func (s *Server) collectionsSettingsParts(ctx context.Context, name, engine string) map[string]any {
	out := map[string]any{"source": "file"}
	if a := s.instAdmin(); a != nil && slicesContains(a.fileNames(), name) {
		return out
	}
	var raw []byte
	err := s.pool.QueryRow(ctx, `SELECT s.settings FROM pgvigil.admin_instance_settings() s WHERE s.name = $1`, name).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return out
	}
	out["source"] = "page"
	why := s.instancesOff()
	ps := s.settingsConfig()
	if why == "" && ps == nil {
		why = "this server does not set an instance's settings (pgvigil serve does)"
	}
	if err != nil {
		s.log.Warn("instance collections: the settings were not read", "instance", name, "err", err)
		why, raw = "this server could not read the instance's settings: "+err.Error(), nil
	}
	out["writable"], out["why_not"] = why == "", why
	if raw != nil {
		out["settings"] = json.RawMessage(raw)
	}
	if ps != nil {
		cat := map[string]PageCollectionView{}
		for _, c := range ps.Catalogue[engine] {
			cat[c.Name] = c
		}
		out["catalogue"], out["settings_floor_s"] = cat, ps.FloorS
	}
	out["settings_ceiling_s"] = int(config.PageScheduleCeiling / time.Second)
	return out
}
