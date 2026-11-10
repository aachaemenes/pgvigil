package mssql

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// The shredder: Extended Events XML to rows, on the collector's side. The monitored server hands over text (a ring
// buffer's target_data in pieces, an event file's event_data row by row) and never runs an XQuery for pgvigil: a
// .nodes() shred of a large ring buffer costs the monitored server CPU and memory grants, and here it costs the
// collector's.

// xeValue is a <value>: its text for a scalar, its raw XML for a document (a deadlock graph, a blocked-process report).
type xeValue struct {
	Text  string `xml:",chardata"`
	Inner string `xml:",innerxml"`
}

// xeField is one <data> or <action> of an event. Text is the <text> beside a mapped value (a lock mode, a state).
type xeField struct {
	Name  string  `xml:"name,attr"`
	Value xeValue `xml:"value"`
	Text  string  `xml:"text"`
}

// xeEvent is one <event>.
type xeEvent struct {
	Name      string    `xml:"name,attr"`
	Timestamp string    `xml:"timestamp,attr"`
	Data      []xeField `xml:"data"`
	Actions   []xeField `xml:"action"`
	Inner     string    `xml:",innerxml"`
}

// xeRing is a ring_buffer target's target_data.
type xeRing struct {
	Truncated      int       `xml:"truncated,attr"`
	TotalProcessed int64     `xml:"totalEventsProcessed,attr"`
	EventCount     int64     `xml:"eventCount,attr"`
	DroppedCount   int64     `xml:"droppedCount,attr"`
	MemoryUsed     int64     `xml:"memoryUsed,attr"`
	Events         []xeEvent `xml:"event"`
}

// xeFileTarget is an event_file target's target_data: the buffers the target dropped and the file it writes now.
type xeFileTarget struct {
	Buffers struct {
		Logged  int64 `xml:"logged,attr"`
		Dropped int64 `xml:"dropped,attr"`
	} `xml:"Buffers"`
	File struct {
		Name string `xml:"name,attr"`
	} `xml:"File"`
}

// xeCounterTarget is an event_counter target's target_data.
type xeCounterTarget struct {
	Packages []struct {
		Events []struct {
			Name  string `xml:"name,attr"`
			Count int64  `xml:"count,attr"`
		} `xml:"Event"`
	} `xml:"Packages>Package"`
}

// decodeUTF16LE turns the bytes of an nvarchar value into a string. The ring buffer is read as varbinary pieces and
// joined before it is decoded, so a character outside the basic plane cut by a piece's edge is whole again.
func decodeUTF16LE(b []byte) string {
	u := make([]uint16, len(b)/2)
	for i := range u {
		u[i] = uint16(b[2*i]) | uint16(b[2*i+1])<<8
	}
	return string(utf16.Decode(u))
}

// xmlCharRef is a numeric character reference.
var xmlCharRef = regexp.MustCompile(`&#(x[0-9A-Fa-f]{1,8}|[0-9]{1,10});`)

// xmlLegal says whether XML 1.0 allows the character.
func xmlLegal(c rune) bool {
	return c == '\t' || c == '\n' || c == '\r' || (c >= 0x20 && c <= 0xD7FF) || (c >= 0xE000 && c <= 0xFFFD) || (c >= 0x10000 && c <= 0x10FFFF)
}

// xmlClean replaces what XML 1.0 forbids, written raw or as a character reference, with U+FFFD. Extended Events
// writes a statement's text as it came: a control character inside a literal (CHAR(1), a NUL) would otherwise fail
// the decoder for the whole document, which for a ring buffer is every event in it.
func xmlClean(doc string) string {
	if strings.IndexFunc(doc, func(c rune) bool { return !xmlLegal(c) }) >= 0 {
		doc = strings.Map(func(c rune) rune {
			if xmlLegal(c) {
				return c
			}
			return '\uFFFD'
		}, doc)
	}
	if !strings.Contains(doc, "&#") {
		return doc
	}
	return xmlCharRef.ReplaceAllStringFunc(doc, func(ref string) string {
		body, base := ref[2:len(ref)-1], 10
		if body[0] == 'x' {
			body, base = body[1:], 16
		}
		if n, err := strconv.ParseInt(body, base, 64); err == nil && n <= 0x10FFFF && xmlLegal(rune(n)) {
			return ref
		}
		return "\uFFFD"
	})
}

func parseRing(doc string) (xeRing, error) {
	var r xeRing
	if strings.TrimSpace(doc) == "" {
		return r, nil
	}
	if err := xml.Unmarshal([]byte(xmlClean(doc)), &r); err != nil {
		return r, fmt.Errorf("the ring buffer's XML: %w", err)
	}
	return r, nil
}

func parseEvent(doc string) (xeEvent, error) {
	var e xeEvent
	if err := xml.Unmarshal([]byte(xmlClean(doc)), &e); err != nil {
		return e, fmt.Errorf("an event's XML: %w", err)
	}
	return e, nil
}

func (e *xeEvent) field(list []xeField, name string) *xeField {
	for i := range list {
		if list[i].Name == name {
			return &list[i]
		}
	}
	return nil
}

// str is a data field's value as text (nil when the event has no such field or it is empty).
func (e *xeEvent) str(name string) any { return fieldStr(e.field(e.Data, name)) }

// act is an action's value as text.
func (e *xeEvent) act(name string) any { return fieldStr(e.field(e.Actions, name)) }

// mapped is a data field's <text> (the name of a mapped value: OK, PRIMARY_NORMAL, commit), else its value.
func (e *xeEvent) mapped(name string) any {
	f := e.field(e.Data, name)
	if f == nil {
		return nil
	}
	if t := strings.TrimSpace(f.Text); t != "" {
		return t
	}
	return fieldStr(f)
}

// num is a data field as an integer (nil when absent or not a number).
func (e *xeEvent) num(name string) any { return fieldNum(e.field(e.Data, name)) }

// actNum is an action as an integer.
func (e *xeEvent) actNum(name string) any { return fieldNum(e.field(e.Actions, name)) }

// doc is a data field's raw XML (a deadlock graph, a blocked-process report).
func (e *xeEvent) doc(name string) string {
	f := e.field(e.Data, name)
	if f == nil {
		return ""
	}
	return strings.TrimSpace(f.Value.Inner)
}

func fieldStr(f *xeField) any {
	if f == nil {
		return nil
	}
	// PostgreSQL's text takes no NUL; a statement's text can carry one
	s := strings.ReplaceAll(f.Value.Text, "\x00", "")
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return s
}

func fieldNum(f *xeField) any {
	if f == nil {
		return nil
	}
	n, err := strconv.ParseInt(strings.TrimSpace(f.Value.Text), 10, 64)
	if err != nil {
		return nil
	}
	return n
}

// at is the event's time, which Extended Events writes in UTC.
func (e *xeEvent) at() (time.Time, bool) {
	t, err := time.Parse(time.RFC3339Nano, e.Timestamp)
	if err != nil {
		return time.Time{}, false
	}
	return t.UTC(), true
}

// seq is the event's package0.event_sequence action (0 when the session does not collect it).
func (e *xeEvent) seq() int64 {
	if n, ok := e.actNum("event_sequence").(int64); ok {
		return n
	}
	return 0
}

// xeKeyer gives each event its key: a hash of the event's own XML, and a counter for identical events of one block
// (two completions of one statement in one millisecond with the same numbers), so the same event read twice gets the
// same key and two different events never share one.
type xeKeyer struct{ seen map[string]int }

// reset starts a new block (an event file's buffer, one read of a ring buffer).
func (k *xeKeyer) reset() { k.seen = map[string]int{} }

func (k *xeKeyer) key(e *xeEvent) string {
	if k.seen == nil {
		k.reset()
	}
	sum := sha256.Sum256([]byte(e.Name + "|" + e.Timestamp + "|" + e.Inner))
	h := hex.EncodeToString(sum[:16])
	n := k.seen[h]
	k.seen[h] = n + 1
	return h + "-" + strconv.Itoa(n)
}

// deadlockKey is a deadlock's key: its time and its graph, nothing of the session that carried it. The same deadlock
// read from pgvigil's session and from system_health (after the product's session was stopped, or before it was
// created) differs in its actions and in the white space of its XML, never in the graph, so it is stored once.
func deadlockKey(e *xeEvent, graph string) string {
	g := strings.Map(func(c rune) rune {
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			return -1
		}
		return c
	}, graph)
	sum := sha256.Sum256([]byte("deadlock|" + e.Timestamp + "|" + g))
	return hex.EncodeToString(sum[:16]) + "-0"
}

// hash16 is a short stable key of a text (a statement shape, a head statement).
func hash16(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:8])
}

// hashHex prints an Extended Events query_hash or query_plan_hash action (an unsigned 64-bit number as decimal text)
// the way sys.dm_exec_query_stats and Query Store print the same hash: 0x and sixteen upper-case hex digits. Zero
// (the action found no statement) is no hash.
func hashHex(v any) any {
	s, ok := v.(string)
	if !ok {
		return nil
	}
	n, err := strconv.ParseUint(strings.TrimSpace(s), 10, 64)
	if err != nil || n == 0 {
		return nil
	}
	return fmt.Sprintf("0x%016X", n)
}

// policyText applies the instance's query-text policy to a text nested inside a row, where the emit's rewrite of
// the top-level statement columns does not reach.
func policyText(s string, mode string) any {
	s = strings.ReplaceAll(strings.TrimSpace(s), "\x00", "")
	if s == "" {
		return nil
	}
	rows := []collect.Row{{"statement": s}}
	collect.ApplyTextPolicy(rows, mode)
	return rows[0]["statement"]
}

// fullText is a document that carries statement text whole (a deadlock graph, a blocked-process report): kept under
// the full policy only.
func fullText(s string, mode string) any {
	if s == "" || (mode != "" && mode != "full") {
		return nil
	}
	return strings.ReplaceAll(s, "\x00", "")
}

// sqlShape is a T-SQL text with its literals replaced by ? and its white space folded: the statement's shape, by
// which the Slow queries tab groups and a blocking chain's head statement is recognised again.
func sqlShape(s string) string {
	var b strings.Builder
	r := []rune(s)
	space := false
	put := func(x string) {
		if space && b.Len() > 0 {
			b.WriteByte(' ')
		}
		space = false
		b.WriteString(x)
	}
	isWord := func(c rune) bool {
		return c == '_' || c == '@' || c == '#' || c == '$' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c > 127
	}
	for i := 0; i < len(r); {
		c := r[i]
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r':
			space = true
			i++
		case c == '-' && i+1 < len(r) && r[i+1] == '-':
			for i < len(r) && r[i] != '\n' {
				i++
			}
			space = true
		case c == '/' && i+1 < len(r) && r[i+1] == '*':
			// T-SQL block comments nest
			depth := 1
			i += 2
			for i < len(r) && depth > 0 {
				switch {
				case r[i] == '/' && i+1 < len(r) && r[i+1] == '*':
					depth++
					i += 2
				case r[i] == '*' && i+1 < len(r) && r[i+1] == '/':
					depth--
					i += 2
				default:
					i++
				}
			}
			space = true
		case c == '\'' || ((c == 'N' || c == 'n') && i+1 < len(r) && r[i+1] == '\''):
			if c != '\'' {
				i++
			}
			i++
			for i < len(r) {
				if r[i] == '\'' {
					if i+1 < len(r) && r[i+1] == '\'' {
						i += 2
						continue
					}
					break
				}
				i++
			}
			i++
			put("?")
		case c == '[' || c == '"':
			end := ']'
			if c == '"' {
				end = '"'
			}
			j := i + 1
			for j < len(r) && r[j] != end {
				j++
			}
			if j < len(r) {
				j++
			}
			put(string(r[i:j]))
			i = j
		case (c >= '0' && c <= '9') || (c == '$' && i+1 < len(r) && r[i+1] >= '0' && r[i+1] <= '9'):
			j := i + 1
			for j < len(r) && (isWord(r[j]) || r[j] == '.') {
				j++
			}
			put("?")
			i = j
		case isWord(c):
			j := i
			for j < len(r) && isWord(r[j]) {
				j++
			}
			put(string(r[i:j]))
			i = j
		default:
			put(string(c))
			i++
		}
	}
	out := b.String()
	if len(out) > 2000 {
		out = strings.ToValidUTF8(out[:2000], "")
	}
	return out
}

// xeContext is what a parser knows beside the event: where it was read and the instance's text policy.
type xeContext struct {
	source    string // product | system_health | AlwaysOn_health
	session   string
	queryText string
}

func (c xeContext) textKept() bool { return c.queryText != "none" }

// xeParser turns one event into its row; nil = the event is not stored (an error of no family).
type xeParser func(e *xeEvent, c xeContext) collect.Row

// xeParsers is every event name the reader stores. The session script names its events from the same lists
// (xeCaptureEvents), and a test holds that each event the script adds has a parser: a misspelt name fails the test
// instead of dropping every event of that kind.
var xeParsers = map[string]xeParser{
	"xml_deadlock_report":                       parseDeadlock,
	"database_xml_deadlock_report":              parseDeadlock,
	"blocked_process_report":                    parseBlocked,
	"rpc_completed":                             parseSlow,
	"sql_batch_completed":                       parseSlow,
	"sql_statement_completed":                   parseSlow,
	"sp_statement_completed":                    parseSlow,
	"attention":                                 parseAttention,
	"availability_replica_state_change":         parseAG,
	"availability_replica_manager_state_change": parseAG,
	"availability_group_lease_expired":          parseAG,
	"alwayson_ddl_executed":                     parseAG,
	"error_reported":                            parseAG,
	"lock_redo_blocked":                         parseAG,
}

// base starts an event's row; ok is false for an event without a readable time.
func xeBase(kind string, e *xeEvent, c xeContext) (collect.Row, bool) {
	t, ok := e.at()
	if !ok {
		return nil, false
	}
	return collect.Row{"kind": kind, "event_at": t.Format(time.RFC3339Nano), "event_name": e.Name, "session_name": c.session}, true
}

// --- deadlocks

type dlRef struct {
	ID   string `xml:"id,attr"`
	Mode string `xml:"mode,attr"`
}

type dlFrame struct {
	ProcName string `xml:"procname,attr"`
	Text     string `xml:",chardata"`
}

type dlProcess struct {
	ID          string    `xml:"id,attr"`
	Spid        string    `xml:"spid,attr"`
	Login       string    `xml:"loginname,attr"`
	Host        string    `xml:"hostname,attr"`
	Program     string    `xml:"clientapp,attr"`
	Database    string    `xml:"currentdbname,attr"`
	Isolation   string    `xml:"isolationlevel,attr"`
	Status      string    `xml:"status,attr"`
	TranCount   string    `xml:"trancount,attr"`
	WaitRes     string    `xml:"waitresource,attr"`
	WaitTime    string    `xml:"waittime,attr"`
	LockMode    string    `xml:"lockMode,attr"`
	Transaction string    `xml:"transactionname,attr"`
	LogUsed     string    `xml:"logused,attr"`
	LastBatch   string    `xml:"lastbatchstarted,attr"`
	Frames      []dlFrame `xml:"executionStack>frame"`
	InputBuf    string    `xml:"inputbuf"`
}

type dlResource struct {
	XMLName xml.Name
	Attrs   []xml.Attr `xml:",any,attr"`
	Owners  []dlRef    `xml:"owner-list>owner"`
	Waiters []dlRef    `xml:"waiter-list>waiter"`
}

type dlGraph struct {
	Victims   []dlRef     `xml:"victim-list>victimProcess"`
	Processes []dlProcess `xml:"process-list>process"`
	Resources struct {
		Items []dlResource `xml:",any"`
	} `xml:"resource-list"`
}

func (r dlResource) attr(name string) string {
	for _, a := range r.Attrs {
		if a.Name.Local == name {
			return a.Value
		}
	}
	return ""
}

func atoiOrNil(s string) any {
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil {
		return nil
	}
	return n
}

func strOrNil(s string) any {
	if s = strings.TrimSpace(strings.ReplaceAll(s, "\x00", "")); s == "" {
		return nil
	}
	return s
}

// statement is what a process ran: its input buffer, else the first frame of its stack that has text.
func (p dlProcess) statement() string {
	if s := strings.TrimSpace(p.InputBuf); s != "" {
		return s
	}
	for _, f := range p.Frames {
		if s := strings.TrimSpace(f.Text); s != "" && s != "unknown" {
			return s
		}
	}
	return ""
}

func (p dlProcess) proc() any {
	for _, f := range p.Frames {
		if f.ProcName != "" && f.ProcName != "adhoc" && f.ProcName != "unknown" {
			return f.ProcName
		}
	}
	return nil
}

func joinDistinct(vals []string) any {
	seen := map[string]bool{}
	var out []string
	for _, v := range vals {
		if v = strings.TrimSpace(v); v != "" && !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	if len(out) == 0 {
		return nil
	}
	sort.Strings(out)
	return strings.Join(out, ", ")
}

func parseDeadlock(e *xeEvent, c xeContext) collect.Row {
	row, ok := xeBase("deadlock", e, c)
	if !ok {
		return nil
	}
	graph := e.doc("xml_report")
	if graph == "" {
		return nil
	}
	row["event_key"] = deadlockKey(e, graph)
	var g dlGraph
	if err := xml.Unmarshal([]byte(graph), &g); err != nil {
		// a graph the reader cannot take apart is still a deadlock: stored whole, unparsed
		row["source"], row["graph"] = c.source, fullText(graph, c.queryText)
		return row
	}
	victims := map[string]bool{}
	for _, v := range g.Victims {
		victims[v.ID] = true
	}
	spidOf := map[string]any{}
	for _, p := range g.Processes {
		spidOf[p.ID] = atoiOrNil(p.Spid)
	}
	type wait struct{ object, mode string }
	waits := map[string]wait{}
	resources := make([]map[string]any, 0, len(g.Resources.Items))
	var objects, dbs []string
	for _, r := range g.Resources.Items {
		object := r.attr("objectname")
		objects = append(objects, object)
		refs := func(list []dlRef) []map[string]any {
			out := make([]map[string]any, 0, len(list))
			for _, x := range list {
				out = append(out, map[string]any{"spid": spidOf[x.ID], "process": x.ID, "mode": strOrNil(x.Mode)})
			}
			return out
		}
		for _, w := range r.Waiters {
			if _, has := waits[w.ID]; !has {
				waits[w.ID] = wait{object, w.Mode}
			}
		}
		resources = append(resources, map[string]any{
			"type": r.XMLName.Local, "object": strOrNil(object), "index": strOrNil(r.attr("indexname")), "mode": strOrNil(r.attr("mode")),
			"owners": refs(r.Owners), "waiters": refs(r.Waiters),
		})
	}
	processes := make([]map[string]any, 0, len(g.Processes))
	var victim *dlProcess
	for i := range g.Processes {
		p := g.Processes[i]
		if victims[p.ID] && victim == nil {
			victim = &g.Processes[i]
		}
		dbs = append(dbs, p.Database)
		w := waits[p.ID]
		processes = append(processes, map[string]any{
			"process": p.ID, "spid": atoiOrNil(p.Spid), "victim": victims[p.ID], "login": strOrNil(p.Login), "host": strOrNil(p.Host),
			"program": strOrNil(p.Program), "database": strOrNil(p.Database), "isolation": strOrNil(p.Isolation),
			"status": strOrNil(p.Status), "trancount": atoiOrNil(p.TranCount), "wait_resource": strOrNil(p.WaitRes),
			"wait_ms": atoiOrNil(p.WaitTime), "lock_mode": strOrNil(p.LockMode), "transaction": strOrNil(p.Transaction),
			"log_used": atoiOrNil(p.LogUsed), "last_batch": strOrNil(p.LastBatch), "proc": p.proc(),
			"statement": policyText(p.statement(), c.queryText), "waits_on": strOrNil(w.object), "waits_mode": strOrNil(w.mode),
		})
	}
	row["source"] = c.source
	row["process_count"], row["victim_count"] = len(g.Processes), len(g.Victims)
	row["database_names"], row["object_names"] = joinDistinct(dbs), joinDistinct(objects)
	row["processes"], row["resources"] = processes, resources
	row["graph"] = fullText(graph, c.queryText)
	if victim != nil {
		row["victim_spid"], row["victim_login"], row["victim_program"] = atoiOrNil(victim.Spid), strOrNil(victim.Login), strOrNil(victim.Program)
		row["statement"] = strOrNil(victim.statement())
	}
	return row
}

// --- blocked-process reports

type bpReport struct {
	Blocked  dlProcess `xml:"blocked-process>process"`
	Blocking dlProcess `xml:"blocking-process>process"`
}

func parseBlocked(e *xeEvent, c xeContext) collect.Row {
	row, ok := xeBase("blocked", e, c)
	if !ok {
		return nil
	}
	report := e.doc("blocked_process")
	var r bpReport
	if report != "" {
		if err := xml.Unmarshal([]byte(report), &r); err != nil {
			r = bpReport{}
		}
	}
	row["database_name"], row["lock_mode"] = e.str("database_name"), e.mapped("lock_mode")
	if us, ok := e.num("duration").(int64); ok {
		row["wait_ms"] = us / 1000
	} else {
		row["wait_ms"] = atoiOrNil(r.Blocked.WaitTime)
	}
	row["wait_resource"] = strOrNil(r.Blocked.WaitRes)
	row["blocked_spid"], row["blocked_login"], row["blocked_host"] = atoiOrNil(r.Blocked.Spid), strOrNil(r.Blocked.Login), strOrNil(r.Blocked.Host)
	row["blocked_program"] = strOrNil(r.Blocked.Program)
	row["blocked_statement"] = policyText(r.Blocked.statement(), c.queryText)
	row["blocking_spid"], row["blocking_status"] = atoiOrNil(r.Blocking.Spid), strOrNil(r.Blocking.Status)
	row["blocking_trancount"], row["blocking_last_batch"] = atoiOrNil(r.Blocking.TranCount), strOrNil(r.Blocking.LastBatch)
	row["blocking_login"], row["blocking_host"], row["blocking_program"] = strOrNil(r.Blocking.Login), strOrNil(r.Blocking.Host), strOrNil(r.Blocking.Program)
	// the head's side: the blocking process's input buffer is its last statement
	head := r.Blocking.statement()
	row["statement"] = strOrNil(head)
	if c.textKept() {
		if head == "" {
			row["head_key"] = hash16(fmt.Sprintf("(no input buffer) %v %v", row["blocking_login"], row["blocking_program"]))
		} else {
			row["head_key"] = hash16(strings.ToLower(sqlShape(head)))
		}
	}
	row["report"] = fullText(report, c.queryText)
	return row
}

// --- slow completions

// rpcWrappers are the procedures a driver calls to run a statement: the statement, not the wrapper, is the shape.
var rpcWrappers = map[string]bool{"sp_executesql": true, "sp_prepexec": true, "sp_execute": true, "sp_prepare": true, "sp_cursoropen": true, "sp_cursorprepexec": true, "sp_cursorexecute": true}

// wrappedStatement is the statement inside a driver's wrapper call (exec sp_executesql N'<statement>', N'@p int',
// @p = 5; exec sp_prepexec @h output, N'@p int', N'<statement>', 5): the first string literal of the call that is
// not a parameter declaration, with its doubled quotes undone. "" when the call carries no statement.
func wrappedStatement(call string) string {
	r := []rune(call)
	for i := 0; i < len(r); i++ {
		if r[i] != '\'' {
			continue
		}
		var b strings.Builder
		j := i + 1
		for j < len(r) {
			if r[j] == '\'' {
				if j+1 < len(r) && r[j+1] == '\'' {
					b.WriteRune('\'')
					j += 2
					continue
				}
				break
			}
			b.WriteRune(r[j])
			j++
		}
		if lit := strings.TrimSpace(b.String()); lit != "" && !strings.HasPrefix(lit, "@") {
			return lit
		}
		i = j
	}
	return ""
}

func parseSlow(e *xeEvent, c xeContext) collect.Row {
	row, ok := xeBase("slow", e, c)
	if !ok {
		return nil
	}
	row["duration_us"], row["cpu_us"] = e.num("duration"), e.num("cpu_time")
	row["logical_reads"], row["physical_reads"], row["writes"], row["row_count"] = e.num("logical_reads"), e.num("physical_reads"), e.num("writes"), e.num("row_count")
	row["result"] = e.mapped("result")
	stmt, _ := e.str("batch_text").(string)
	if stmt == "" {
		stmt, _ = e.str("statement").(string)
	}
	object, _ := e.str("object_name").(string)
	row["statement"], row["object_name"] = strOrNil(stmt), strOrNil(object)
	row["login_name"] = e.act("server_principal_name")
	if row["login_name"] == nil {
		row["login_name"] = e.act("username")
	}
	row["host_name"], row["program_name"], row["database_name"] = e.act("client_hostname"), e.act("client_app_name"), e.act("database_name")
	row["session_id"] = e.actNum("session_id")
	row["query_hash_hex"], row["query_plan_hash_hex"] = hashHex(e.act("query_hash")), hashHex(e.act("query_plan_hash"))
	// the shape: a procedure call is its procedure; anything else its text without literals. Under the 'none'
	// policy no statement text is stored, so only a procedure's name is a shape.
	switch {
	case object != "" && !rpcWrappers[strings.ToLower(object)]:
		row["shape"] = object
	case object != "" && c.textKept():
		// a driver's wrapper: the shape is the statement it carries; a call by handle (sp_execute) carries none
		if inner := wrappedStatement(stmt); inner != "" {
			row["shape"] = sqlShape(inner)
		}
	case stmt != "" && c.textKept():
		row["shape"] = sqlShape(stmt)
	}
	if s, ok := row["shape"].(string); ok && s != "" {
		row["shape_key"] = hash16(strings.ToLower(s))
	} else {
		row["shape"] = nil
	}
	return row
}

// --- attentions

func parseAttention(e *xeEvent, c xeContext) collect.Row {
	row, ok := xeBase("attention", e, c)
	if !ok {
		return nil
	}
	row["session_id"], row["request_id"] = e.actNum("session_id"), e.num("request_id")
	// the event's duration is the time the interrupt itself took (microseconds), not how long the request ran
	row["interrupt_us"] = e.num("duration")
	row["statement"] = e.act("sql_text")
	row["login_name"] = e.act("server_principal_name")
	if row["login_name"] == nil {
		row["login_name"] = e.act("username")
	}
	row["host_name"], row["program_name"], row["database_name"] = e.act("client_hostname"), e.act("client_app_name"), e.act("database_name")
	return row
}

// --- AlwaysOn_health

// agErrorFamily names the family of an error AlwaysOn_health reported (the numbers and their texts are
// sys.messages'): the lease between the group and the cluster, the connection between replicas, a role change, data
// movement suspended or resumed.
func agErrorFamily(n int64) string {
	switch n {
	case 19407, 19419, 19421, 19422, 19423, 19424:
		return "lease"
	case 35201, 35202, 35206:
		return "connection"
	case 1480, 19406:
		return "role"
	case 35264, 35265:
		return "data movement"
	}
	return "other"
}

func parseAG(e *xeEvent, c xeContext) collect.Row {
	row, ok := xeBase("ag_event", e, c)
	if !ok {
		return nil
	}
	delete(row, "session_name")
	row["ag_name"], row["replica_name"] = e.str("availability_group_name"), e.str("availability_replica_name")
	failover := false
	switch e.Name {
	case "availability_replica_state_change":
		prev, _ := e.mapped("previous_state").(string)
		cur, _ := e.mapped("current_state").(string)
		row["previous_state"], row["current_state"] = strOrNil(prev), strOrNil(cur)
		// a secondary told to take over, or a primary that lost its role. A start of the instance goes NOT_AVAILABLE,
		// RESOLVING, PRIMARY or SECONDARY and is neither.
		failover = (prev == "SECONDARY_NORMAL" && cur == "RESOLVING_PENDING_FAILOVER") || (prev == "PRIMARY_NORMAL" && strings.HasPrefix(cur, "RESOLVING"))
	case "availability_replica_manager_state_change":
		row["current_state"] = e.mapped("current_state")
	case "alwayson_ddl_executed":
		stmt, _ := e.str("statement").(string)
		phase, _ := e.mapped("ddl_phase").(string)
		row["ddl_action"], row["ddl_phase"], row["statement"] = e.mapped("ddl_action"), strOrNil(phase), strOrNil(stmt)
		failover = phase == "commit" && strings.Contains(strings.ToUpper(stmt), "FAILOVER")
	case "error_reported":
		n, _ := e.num("error_number").(int64)
		sev, _ := e.num("severity").(int64)
		fam := agErrorFamily(n)
		if fam == "other" && sev < 16 {
			return nil // the session reports every server message of its categories; the informational rest is not kept
		}
		row["error_number"], row["severity"], row["family"], row["message"] = n, sev, fam, e.str("message")
	case "availability_group_lease_expired":
		row["family"] = "lease"
		row["current_state"] = e.mapped("current_state")
	case "lock_redo_blocked":
		row["message"] = "redo is blocked by a reader on the secondary"
	}
	row["is_failover"] = failover
	return row
}
