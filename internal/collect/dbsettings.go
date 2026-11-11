package collect

import (
	"context"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// dbsettingsCollector reads the setting overrides of pg_db_role_setting, every hour (task 163): ALTER DATABASE ... SET
// (scope 'database'), ALTER ROLE ... SET ('role'), ALTER ROLE ... IN DATABASE ... SET ('role in database') and ALTER
// ROLE ALL SET ('all roles'). ALTER ROLE ALL IN DATABASE ... SET is stored as ALTER DATABASE's is and reads as scope
// 'database'. pg_db_role_setting is readable by every login.
//
// Each value is sent as written (raw_value, masked as the instance read masks the server's values: settingValueSQL)
// and, for a setting the server knows, as pg_settings.setting would show it (value: dbSettingBase) - in the setting's
// base unit, 'on' / 'off' for a boolean, an enum's own lower-case name. PostgreSQL keeps the text as it was typed
// ('work_mem=256MB', 'jit=true', 'log_statement=ALL'); the rules of pgvigil.setting_rules (0099) compare in the base
// unit, so migration 0104 grades an override by the same rule as the server's value only through this column.
// A placeholder (an extension's setting not loaded, a custom name such as app.tenant) has no pg_settings row: known
// false, its value as written. The read ends with one {kind:'read'} row, so a server without any override still
// replaces what an earlier read stored.
type dbsettingsCollector struct{}

func init() { Register(dbsettingsCollector{}) }

func (dbsettingsCollector) Name() string                   { return "dbsettings" }
func (dbsettingsCollector) DefaultInterval() time.Duration { return time.Hour }
func (dbsettingsCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}

// dbsettingsSQL: one row per name=value of every pg_db_role_setting row. The name is lower-cased (setting names are
// case-blind) and matched to pg_settings, which lists the session's own value: only its type, unit, context, enum
// values and compiled-in default (boot_val, in the base unit) are read from it, never its setting.
const dbsettingsSQL = `
WITH o AS (
  SELECT CASE WHEN s.setdatabase <> 0 AND s.setrole <> 0 THEN 'role in database' WHEN s.setrole <> 0 THEN 'role'
              WHEN s.setdatabase <> 0 THEN 'database' ELSE 'all roles' END AS scope,
         s.setdatabase::bigint AS dbid, coalesce(d.datname::text, '') AS datname,
         s.setrole::bigint AS roleid, coalesce(r.rolname::text, '') AS rolname,
         lower(split_part(c.cfg, '=', 1)) AS name, substr(c.cfg, strpos(c.cfg, '=') + 1) AS setting
    FROM pg_db_role_setting s
    CROSS JOIN LATERAL unnest(s.setconfig) c(cfg)
    LEFT JOIN pg_database d ON d.oid = s.setdatabase
    LEFT JOIN pg_roles r ON r.oid = s.setrole
), m AS (
  SELECT scope, dbid, datname, roleid, rolname, name, ` + settingValueSQL + ` AS raw_value FROM o
)
SELECT 'setting' AS kind, m.scope, m.dbid, m.datname, m.roleid, m.rolname, m.name, m.raw_value,
       p.vartype::text AS vartype, p.unit::text AS unit, p.context::text AS context, p.boot_val::text AS boot_val,
       p.enumvals::text[] AS enumvals, p.name IS NOT NULL AS known
  FROM m
  LEFT JOIN pg_settings p ON p.name = m.name
 ORDER BY m.scope, m.datname, m.rolname, m.name`

func (dbsettingsCollector) Run(ctx context.Context, conn *pgx.Conn, _ platform.Info) ([]Row, error) {
	rows, err := conn.Query(ctx, dbsettingsSQL)
	if err != nil {
		return nil, err
	}
	out, err := rowsToMaps(rows)
	if err != nil {
		return nil, err
	}
	for _, r := range out {
		raw, _ := r["raw_value"].(string)
		vartype, _ := r["vartype"].(string)
		unit, _ := r["unit"].(string)
		v, ok := dbSettingBase(raw, vartype, unit, stringsOf(r["enumvals"]))
		r["value"] = v
		r["value_read"] = ok
		delete(r, "enumvals")
	}
	return append(out, Row{"kind": "read"}), nil
}

// stringsOf turns a text[] as pgx returns it ([]any of strings, or []string) into []string.
func stringsOf(v any) []string {
	switch x := v.(type) {
	case []string:
		return x
	case []any:
		out := make([]string, 0, len(x))
		for _, e := range x {
			if s, ok := e.(string); ok {
				out = append(out, s)
			}
		}
		return out
	}
	return nil
}

// dbSettingBase is a value as ALTER ... SET wrote it, as pg_settings.setting shows it once in force: the number in the
// setting's base unit (unit: pg_settings.unit, such as kB, 8kB, MB, ms, s, min), rounded to an integer for an integer
// setting as PostgreSQL rounds it; 'on' / 'off' for a boolean (every spelling PostgreSQL accepts: true, yes, 1, a
// unique prefix); an enum's name in lower case (an enum's hidden boolean spellings as on / off where the enum has
// them). ok is false when the text is not such a value (masked, a placeholder, a value of another shape): the text
// comes back unchanged and the rules that compare a number do not read it.
func dbSettingBase(raw, vartype, unit string, enumvals []string) (string, bool) {
	s := strings.TrimSpace(raw)
	switch vartype {
	case "bool":
		if b, ok := pgBool(s); ok {
			if b {
				return "on", true
			}
			return "off", true
		}
		return raw, false
	case "enum":
		l := strings.ToLower(s)
		for _, e := range enumvals {
			if strings.ToLower(e) == l {
				return l, true
			}
		}
		if has(enumvals, "on") && has(enumvals, "off") {
			switch l {
			case "true", "yes", "1":
				return "on", true
			case "false", "no", "0":
				return "off", true
			}
		}
		return raw, false
	case "integer", "real":
		f, ok := pgNumber(s, unit, vartype == "integer")
		if !ok {
			return raw, false
		}
		if vartype == "integer" {
			return strconv.FormatInt(int64(f), 10), true
		}
		return strconv.FormatFloat(f, 'f', -1, 64), true
	case "string":
		return raw, true
	}
	return raw, false
}

func has(list []string, s string) bool {
	for _, e := range list {
		if strings.EqualFold(e, s) {
			return true
		}
	}
	return false
}

// pgBool is PostgreSQL's parse_bool: true, yes, on, 1 and false, no, off, 0, case-blind, and any unique prefix of the
// words (o alone is not: on or off).
func pgBool(s string) (bool, bool) {
	l := strings.ToLower(s)
	if l == "" {
		return false, false
	}
	pre := func(word string) bool { return len(l) <= len(word) && word[:len(l)] == l }
	switch l[0] {
	case 't':
		return true, pre("true")
	case 'y':
		return true, pre("yes")
	case 'f':
		return false, pre("false")
	case 'n':
		return false, pre("no")
	case 'o':
		if len(l) < 2 {
			return false, false
		}
		if pre("on") {
			return true, true
		}
		return false, pre("off")
	case '1':
		return true, l == "1"
	case '0':
		return false, l == "0"
	}
	return false, false
}

// a number as PostgreSQL's parse_int / parse_real read it: an integer may be hexadecimal (0x..) or octal (a leading
// 0), as strtol with base 0 reads it; a fraction or an exponent makes it a real; then an optional unit
var (
	reHexOct = regexp.MustCompile(`^([+-]?)(0[xX][0-9a-fA-F]+|0[0-7]+)\s*([a-zA-Z]*)$`)
	reDec    = regexp.MustCompile(`^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)\s*([a-zA-Z]*)$`)
)

// the units PostgreSQL accepts after a number, case-sensitive: memory in bytes, time in milliseconds
var memUnits = map[string]float64{"B": 1, "kB": 1024, "MB": 1024 * 1024, "GB": 1024 * 1024 * 1024, "TB": 1024 * 1024 * 1024 * 1024}
var timeUnits = map[string]float64{"us": 0.001, "ms": 1, "s": 1000, "min": 60000, "h": 3600000, "d": 86400000}

// baseUnit splits pg_settings.unit ('8kB', '16MB', 'kB', 'ms', 'min') into its multiple and its unit's size, and says
// which table the unit is from (memory or time); an empty unit = none
func baseUnit(unit string) (size float64, units map[string]float64, ok bool) {
	if unit == "" {
		return 1, nil, true
	}
	i := 0
	for i < len(unit) && unit[i] >= '0' && unit[i] <= '9' {
		i++
	}
	mult := 1.0
	if i > 0 {
		n, err := strconv.Atoi(unit[:i])
		if err != nil || n <= 0 {
			return 0, nil, false
		}
		mult = float64(n)
	}
	if f, isMem := memUnits[unit[i:]]; isMem {
		return mult * f, memUnits, true
	}
	if f, isTime := timeUnits[unit[i:]]; isTime {
		return mult * f, timeUnits, true
	}
	return 0, nil, false
}

// pgNumber reads a number with an optional unit into the setting's base unit (an integer setting rounded half to
// even, as rint rounds); a unit the setting does not take, or a unit on a unitless setting, is not a value
func pgNumber(s, unit string, integer bool) (float64, bool) {
	var num float64
	var valUnit string
	if m := reHexOct.FindStringSubmatch(s); m != nil && integer {
		n, err := strconv.ParseInt(m[2], 0, 64)
		if err != nil {
			return 0, false
		}
		num = float64(n)
		if m[1] == "-" {
			num = -num
		}
		valUnit = m[3]
	} else if m := reDec.FindStringSubmatch(s); m != nil {
		f, err := strconv.ParseFloat(m[1], 64)
		if err != nil {
			return 0, false
		}
		num, valUnit = f, m[2]
	} else {
		return 0, false
	}
	if valUnit != "" {
		size, units, ok := baseUnit(unit)
		if !ok || units == nil {
			return 0, false
		}
		f, known := units[valUnit]
		if !known {
			return 0, false
		}
		num = num * f / size
	}
	if integer {
		num = math.RoundToEven(num)
	}
	if math.IsInf(num, 0) || math.IsNaN(num) {
		return 0, false
	}
	return num, true
}
