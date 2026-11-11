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
// and, for a number, a boolean or an enum the server knows, as pg_settings.setting would show it (value:
// dbSettingBase) - a number in the setting's base unit, 'on' / 'off' for a boolean, the enum name PostgreSQL shows.
// PostgreSQL keeps the text as it was typed ('work_mem=256MB', 'jit=true', 'log_statement=ALL'); the rules of
// pgvigil.setting_rules (0099) compare in the base unit, so migration 0104 grades an override by the same rule as the
// server's value only through this column. A string is not read (value_read false): PostgreSQL rewrites some of them
// (TimeZone, DateStyle, client_encoding) and no rule reads one that a session can set.
// The name is the one pg_settings shows (TimeZone, DateStyle: PostgreSQL stores that spelling), matched case-blind.
// known is false where pg_settings does not list the name to this login: a placeholder (an extension's setting not
// loaded, a custom name such as app.tenant) or a setting hidden from it (role; session_preload_libraries without
// pg_read_all_settings); its value is kept as written. The read ends with one {kind:'read'} row, so a server without
// any override still replaces what an earlier read stored.
type dbsettingsCollector struct{}

func init() { Register(dbsettingsCollector{}) }

func (dbsettingsCollector) Name() string                   { return "dbsettings" }
func (dbsettingsCollector) DefaultInterval() time.Duration { return time.Hour }
func (dbsettingsCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}

// dbsettingsSQL: one row per name=value of every pg_db_role_setting row. The name is matched to pg_settings case-blind
// (two placeholders that differ in case are two entries, as PostgreSQL keeps them); pg_settings lists the session's own
// value: only its name, type, unit, context, enum values and compiled-in default (boot_val, in the base unit) are read
// from it, never its setting.
const dbsettingsSQL = `
WITH o AS (
  SELECT CASE WHEN s.setdatabase <> 0 AND s.setrole <> 0 THEN 'role in database' WHEN s.setrole <> 0 THEN 'role'
              WHEN s.setdatabase <> 0 THEN 'database' ELSE 'all roles' END AS scope,
         s.setdatabase::bigint AS dbid, coalesce(d.datname::text, '') AS datname,
         s.setrole::bigint AS roleid, coalesce(r.rolname::text, '') AS rolname,
         split_part(c.cfg, '=', 1) AS name, substr(c.cfg, strpos(c.cfg, '=') + 1) AS setting
    FROM pg_db_role_setting s
    CROSS JOIN LATERAL unnest(s.setconfig) c(cfg)
    LEFT JOIN pg_database d ON d.oid = s.setdatabase
    LEFT JOIN pg_roles r ON r.oid = s.setrole
), m AS (
  SELECT scope, dbid, datname, roleid, rolname, name, ` + settingValueSQL + ` AS raw_value FROM o
)
SELECT 'setting' AS kind, m.scope, m.dbid, m.datname, m.roleid, m.rolname, coalesce(p.name::text, m.name) AS name, m.raw_value,
       p.vartype::text AS vartype, p.unit::text AS unit, p.context::text AS context, p.boot_val::text AS boot_val,
       p.enumvals::text[] AS enumvals, p.name IS NOT NULL AS known
  FROM m
  LEFT JOIN pg_settings p ON lower(p.name) = lower(m.name)
 ORDER BY m.scope, m.datname, m.rolname, 7`

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
		name, _ := r["name"].(string)
		v, ok := dbSettingBase(name, raw, vartype, unit, stringsOf(r["enumvals"]))
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

// dbSettingBase is a value as ALTER ... SET wrote it, as pg_settings.setting shows it once in force (PostgreSQL 13 to
// 18, guc.c): a number as parse_int / parse_real read it, in the setting's base unit (unit: pg_settings.unit, such as
// kB, 8kB, MB, ms, s, min), an integer rounded with rint and held to the int range, a real printed as C's %g; 'on' /
// 'off' for a boolean (every spelling parse_bool takes: true, yes, 1, a unique prefix); for an enum the name pg_settings
// shows - the first entry of the setting's table with the same value, so an alias PostgreSQL hides or lists after its
// canonical name comes back as that name (enumAliases; the hidden boolean spellings of an enum that has on and off).
// ok is false when the text is not such a value (masked, a placeholder, a string, an alias not known here): the text
// comes back unchanged and 0104 leaves it out of the rules.
func dbSettingBase(name, raw, vartype, unit string, enumvals []string) (string, bool) {
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
		if a, ok := enumAliases[strings.ToLower(name)][l]; ok && has(enumvals, a) {
			return a, true
		}
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
	case "integer":
		f, ok := pgNumber(s, unit, true)
		if !ok {
			return raw, false
		}
		return strconv.FormatInt(int64(f), 10), true
	case "real":
		f, ok := pgNumber(s, unit, false)
		if !ok {
			return raw, false
		}
		return strconv.FormatFloat(f, 'g', 6, 64), true
	}
	return raw, false
}

// enumAliases: per setting, a spelling PostgreSQL takes and the name it shows for it (guc_tables.c / guc.c, 13 to 18):
// wal_compression (an enum from 15; a boolean before) shows on and its boolean spellings as pglz, the entry listed
// first with that value; the message levels take a hidden 'debug' for debug2. Used only where the server lists the
// target name among the setting's values.
var enumAliases = map[string]map[string]string{
	"wal_compression":         {"on": "pglz", "true": "pglz", "yes": "pglz", "1": "pglz", "false": "off", "no": "off", "0": "off"},
	"log_min_messages":        {"debug": "debug2"},
	"client_min_messages":     {"debug": "debug2"},
	"log_min_error_statement": {"debug": "debug2"},
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

var (
	// strtol with base 0: 0x.. hexadecimal, a leading 0 octal (as far as the octal digits go), else decimal
	reStrtol = regexp.MustCompile(`^[+-]?(?:0[xX][0-9a-fA-F]+|0[0-7]*|[1-9][0-9]*)`)
	// strtod's decimal form (its hexadecimal floats, inf and nan are not read here: ok false)
	reStrtod = regexp.MustCompile(`^[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?`)
)

// the unit tables of guc.c, largest first: memory in bytes, time in milliseconds. A fractional value is rounded to the
// next smaller unit of its table before the base unit takes it (convert_to_base_unit), as PostgreSQL 13 to 18 do.
var memOrder = []string{"TB", "GB", "MB", "kB", "B"}
var memBytes = map[string]float64{"B": 1, "kB": 1024, "MB": 1024 * 1024, "GB": 1024 * 1024 * 1024, "TB": 1024 * 1024 * 1024 * 1024}
var timeOrder = []string{"d", "h", "min", "s", "ms", "us"}
var timeMs = map[string]float64{"us": 0.001, "ms": 1, "s": 1000, "min": 60000, "h": 3600000, "d": 86400000}

// baseUnit splits pg_settings.unit ('8kB', '16MB', 'kB', 'ms', 'min') into its size in the table's measure and the
// table (order and sizes) it belongs to; an empty unit = none
func baseUnit(unit string) (size float64, order []string, sizes map[string]float64, ok bool) {
	if unit == "" {
		return 1, nil, nil, true
	}
	i := 0
	for i < len(unit) && unit[i] >= '0' && unit[i] <= '9' {
		i++
	}
	mult := 1.0
	if i > 0 {
		n, err := strconv.Atoi(unit[:i])
		if err != nil || n <= 0 {
			return 0, nil, nil, false
		}
		mult = float64(n)
	}
	if f, isMem := memBytes[unit[i:]]; isMem {
		return mult * f, memOrder, memBytes, true
	}
	if f, isTime := timeMs[unit[i:]]; isTime {
		return mult * f, timeOrder, timeMs, true
	}
	return 0, nil, nil, false
}

// pgNumber is parse_int (integer) or parse_real: the number, then an optional unit after optional white space; the
// value converted to the base unit; an integer rounded with rint (half to even) and refused outside the int range. A
// unit the setting does not take, a unit on a unitless setting or anything after the unit is not a value.
func pgNumber(s, unit string, integer bool) (float64, bool) {
	var num float64
	var rest string
	if integer {
		m := reStrtol.FindString(s)
		next := ""
		if len(m) < len(s) {
			next = s[len(m) : len(m)+1]
		}
		if m != "" && next != "." && next != "e" && next != "E" {
			sign := 1.0
			digits := m
			if digits[0] == '+' || digits[0] == '-' {
				if digits[0] == '-' {
					sign = -1
				}
				digits = digits[1:]
			}
			// base 0 reads 0x.. as hexadecimal and a leading 0 as octal, as strtol does; the match holds no underscore
			n, err := strconv.ParseInt(digits, 0, 64)
			if err != nil {
				return 0, false
			}
			num, rest = sign*float64(n), s[len(m):]
		} else {
			m = reStrtod.FindString(s)
			if m == "" {
				return 0, false
			}
			f, err := strconv.ParseFloat(m, 64)
			if err != nil {
				return 0, false
			}
			num, rest = f, s[len(m):]
		}
	} else {
		m := reStrtod.FindString(s)
		if m == "" {
			return 0, false
		}
		f, err := strconv.ParseFloat(m, 64)
		if err != nil {
			return 0, false
		}
		num, rest = f, s[len(m):]
	}
	if u := strings.TrimSpace(rest); u != "" {
		size, order, sizes, ok := baseUnit(unit)
		if !ok || order == nil {
			return 0, false
		}
		f, known := sizes[u]
		if !known {
			return 0, false
		}
		num = num * f / size
		// rounded to the nearest multiple of the next smaller unit of the table, where there is one
		for i, name := range order {
			if name == u && i+1 < len(order) {
				step := sizes[order[i+1]] / size
				num = math.RoundToEven(num/step) * step
				break
			}
		}
	}
	if integer {
		num = math.RoundToEven(num)
		if num > math.MaxInt32 || num < math.MinInt32 {
			return 0, false
		}
	}
	if math.IsInf(num, 0) || math.IsNaN(num) {
		return 0, false
	}
	return num, true
}
