package mssql

import (
	"bufio"
	"context"
	"database/sql"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// readWindowsFixture reads testdata/properties-windows.txt (301c N5: what the lab's Windows VM answered to the code's own
// four statements) into the gate, the view's rows, xp_instance_regread's row and xp_regread's row. A view line that
// lacks its '|~' end was cut by sqlcmd at the NUL that ends the value (the fixture's header; inferred, not read byte by
// byte): its value gets that NUL back. A view value '<NULL>' is nil; '<not printed>' (the runner prints only what the rows
// are built from) on a value the code reads stops the test. IpAddress holds the runner's class of the address (ipv4,
// ipv6, loopback), never the address: the rows of this server (ListenOnAllIPs 1) do not read it.
// readByCode: the value names netFactsFromView reads
var readByCode = map[string]bool{"forceencryption": true, "forcestrict": true, "listenonallips": true, "enabled": true,
	"tcpport": true, "tcpdynamicports": true, "ipaddress": true}

func readWindowsFixture(t *testing.T, path string) (gate propGate, view []collect.Row, reg, prio collect.Row) {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = f.Close() }()
	num := func(s string) any {
		if s == "<NULL>" {
			return nil
		}
		n, err := strconv.ParseInt(s, 10, 64)
		if err != nil {
			t.Fatalf("the fixture's number %q: %v", s, err)
		}
		return n
	}
	str := func(s string) any {
		if s == "<NULL>" {
			return nil
		}
		return s
	}
	viewRows, done := -1, false
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, "N5|") {
			continue
		}
		whole := strings.HasSuffix(line, "|~")
		x := strings.Split(strings.TrimSuffix(strings.TrimPrefix(line, "N5|"), "|~"), "|")
		switch x[0] {
		case "gate":
			gate = propGate{read: true, registryView: x[1] == "1", instanceRegread: x[2] == "1", regread: x[3] == "1", login: "pgvigil_mon"}
		case "view":
			var v any = x[3]
			switch {
			case x[3] == "<NULL>":
				v = nil
			case x[3] == "<not printed>" && readByCode[strings.ToLower(x[2])]:
				t.Fatalf("the fixture's view line of %s has no value printed: the code reads it (%s)", x[2], line)
			case !whole:
				v = x[3] + "\x00"
			}
			view = append(view, collect.Row{"registry_key": x[1], "value_name": x[2], "value_data": v})
		case "view-rows":
			viewRows = int(num(x[1]).(int64))
		case "reg":
			reg = collect.Row{"force_encryption": num(x[1]), "force_strict_encryption": num(x[2]), "listen_all": num(x[3]), "tcp_enabled": num(x[4]),
				"np_enabled": num(x[5]), "sm_enabled": num(x[6]), "ipall_port": str(x[7]), "ipall_dynamic": str(x[8])}
		case "prio":
			prio = collect.Row{"priority_separation": num(x[1])}
		case "done":
			done = true
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	if !done || viewRows != len(view) || reg == nil || prio == nil || !gate.read {
		t.Fatalf("the fixture is not whole: done %t, view rows %d of %d, reg %v, prio %v, gate %+v", done, len(view), viewRows, reg, prio, gate)
	}
	return gate, view, reg, prio
}

// TestNetRowsOnWindowsFixture: the seven rows that readNetwork and netRows build from the lab's Windows VM's answers
// (SQL Server 2022, the default instance; the runner's own reads beside them: ForceEncryption 0 through
// xp_instance_regread and no value of the name ForceStrictEncryption - the fixture's reg line answered that name (the
// runner at 4c7701a2), not Microsoft's ForceStrict, so its NULL stands here for 'ForceStrict absent' (N5b; the VM's own
// ForceStrict waits for its turn); TCP/IP and Shared Memory on, Named Pipes off, IPAll's static
// port 1433 with dynamic ports off, ListenOnAllIPs 1, Win32PrioritySeparation 2, the listeners on 1433 for any address).
func TestNetRowsOnWindowsFixture(t *testing.T) {
	gate, view, reg, prio := readWindowsFixture(t, "testdata/properties-windows.txt")
	old := netQuery
	defer func() { netQuery = old }()
	netQuery = func(_ context.Context, _ *sql.Conn, q string, _ ...any) ([]collect.Row, error) {
		switch q {
		case propsNetViewSQL:
			return view, nil
		case propsNetRegSQL:
			return []collect.Row{reg}, nil
		case propsPrioritySQL:
			return []collect.Row{prio}, nil
		}
		return nil, fmt.Errorf("the fixture holds no answer to %.60q", q)
	}
	in, partial := readNetwork(context.Background(), nil, Info{Kind: KindServer, Major: 16}, "Windows", gate)
	if len(partial) != 0 {
		t.Errorf("partial rows: %v", partial)
	}
	got := netOf(in)
	want := map[string]string{
		keyTCPPort:        "1433 | ",
		keyTCPDynamic:     "no | ",
		keyListenAll:      "yes | ",
		keyForceEnc:       "no | ",
		keyForceStrictEnc: " | not set: the key holds no ForceStrict value",
		keyProtocols:      "Shared Memory, TCP/IP | ",
		keyPrioritySep:    "2 | ",
	}
	for k, w := range want {
		if got[k] != w {
			t.Errorf("%s: %q, want %q", k, got[k], w)
		}
	}
	if len(got) != len(want) {
		t.Errorf("%d rows, want %d: %v", len(got), len(want), got)
	}
}

// TestNetRowsOnWindowsFixtureWithoutRegread: the same answers for a login without EXECUTE on xp_instance_regread - the
// two encryption rows name the GRANT, the procedure is never sent, the other rows stand on the view alone.
func TestNetRowsOnWindowsFixtureWithoutRegread(t *testing.T) {
	gate, view, _, prio := readWindowsFixture(t, "testdata/properties-windows.txt")
	gate.instanceRegread = false
	old := netQuery
	defer func() { netQuery = old }()
	netQuery = func(_ context.Context, _ *sql.Conn, q string, _ ...any) ([]collect.Row, error) {
		switch q {
		case propsNetViewSQL:
			return view, nil
		case propsPrioritySQL:
			return []collect.Row{prio}, nil
		}
		t.Errorf("sent without the right: %.60q", q)
		return nil, fmt.Errorf("no right")
	}
	in, partial := readNetwork(context.Background(), nil, Info{Kind: KindServer, Major: 16}, "Windows", gate)
	if len(partial) != 0 {
		t.Errorf("partial rows: %v", partial)
	}
	got := netOf(in)
	why := " | not read: sys.dm_server_registry holds no ForceEncryption or ForceStrict value here; no right: EXECUTE on master.dbo.xp_instance_regread - in master, CREATE USER [pgvigil_mon]"
	for _, k := range []string{keyForceEnc, keyForceStrictEnc} {
		if !strings.HasPrefix(got[k], why) {
			t.Errorf("%s: %q, want it to start %q", k, got[k], why)
		}
	}
	for k, w := range map[string]string{keyTCPPort: "1433 | ", keyTCPDynamic: "no | ", keyListenAll: "yes | ", keyProtocols: "Shared Memory, TCP/IP | ", keyPrioritySep: "2 | "} {
		if got[k] != w {
			t.Errorf("%s: %q, want %q", k, got[k], w)
		}
	}
}

// fixtureNet runs readNetwork and netRows over the fixture's answers with the view's rows given and xp_instance_regread
// answering regAns (nil = never sent: a call fails the test); it says the rows, the partial rows and the calls.
func fixtureNet(t *testing.T, view []collect.Row, major int, gate propGate, regAns func() ([]collect.Row, error)) (map[string]string, []collect.Row, int) {
	t.Helper()
	_, _, _, prio := readWindowsFixture(t, "testdata/properties-windows.txt")
	old := netQuery
	defer func() { netQuery = old }()
	calls := 0
	netQuery = func(_ context.Context, _ *sql.Conn, q string, _ ...any) ([]collect.Row, error) {
		switch q {
		case propsNetViewSQL:
			return view, nil
		case propsNetRegSQL:
			calls++
			if regAns == nil {
				t.Errorf("xp_instance_regread sent where it is not needed")
				return nil, fmt.Errorf("not expected")
			}
			return regAns()
		case propsPrioritySQL:
			return []collect.Row{prio}, nil
		}
		return nil, fmt.Errorf("the fixture holds no answer to %.60q", q)
	}
	in, partial := readNetwork(context.Background(), nil, Info{Kind: KindServer, Major: major}, "Windows", gate)
	return netOf(in), partial, calls
}

// The fixture's view with other answers (the N5 fix's review): the view holding both encryption values sends no
// xp_instance_regread; a failed read names its error in both rows and leaves one partial row; SQL Server 2019 reads
// ForceEncryption alone; a view holding ForceEncryption only, with no right to the procedure, names the one it lacks.
func TestNetRowsOnWindowsFixtureOtherAnswers(t *testing.T) {
	gate, view, reg, _ := readWindowsFixture(t, "testdata/properties-windows.txt")
	withBare := append(append([]collect.Row{}, view...), viewRow("", "ForceEncryption", "1"), viewRow("", "ForceStrict", "0"))
	if got, partial, calls := fixtureNet(t, withBare, 16, gate, nil); got[keyForceEnc] != "yes | " || got[keyForceStrictEnc] != "no | " || calls != 0 || len(partial) != 0 {
		t.Errorf("the view holding both: force %q, strict %q, %d call(s), partial %v", got[keyForceEnc], got[keyForceStrictEnc], calls, partial)
	}
	got, partial, calls := fixtureNet(t, view, 16, gate, func() ([]collect.Row, error) { return nil, fmt.Errorf("Msg 22001, xp_instance_regread failed") })
	if got[keyForceEnc] != " | not read: Msg 22001, xp_instance_regread failed" || got[keyForceStrictEnc] != got[keyForceEnc] || calls != 1 ||
		len(partial) != 1 || partial[0]["source"] != "xp_instance_regread" {
		t.Errorf("the read failing: force %q, strict %q, %d call(s), partial %v", got[keyForceEnc], got[keyForceStrictEnc], calls, partial)
	}
	if got[keyTCPPort] != "1433 | " {
		t.Errorf("the read failing: tcp_port %q (the view's rows stand)", got[keyTCPPort])
	}
	got, _, calls = fixtureNet(t, view, 15, gate, func() ([]collect.Row, error) { return []collect.Row{reg}, nil })
	if got[keyForceEnc] != "no | " || got[keyForceStrictEnc] != " | not on this version: strict encryption came with SQL Server 2022" || calls != 1 {
		t.Errorf("SQL Server 2019: force %q, strict %q, %d call(s)", got[keyForceEnc], got[keyForceStrictEnc], calls)
	}
	noRight := gate
	noRight.instanceRegread = false
	// the view holding ForceEncryption without ForceStrict is not taken as whole (N5b's review F1): xp_instance_regread
	// is asked, and its NULL is 'not set'; without the right the row names it
	withEnc := append(append([]collect.Row{}, view...), viewRow("", "ForceEncryption", "0"))
	got, _, calls = fixtureNet(t, withEnc, 16, gate, func() ([]collect.Row, error) { return []collect.Row{reg}, nil })
	if got[keyForceEnc] != "no | " || got[keyForceStrictEnc] != " | not set: the key holds no ForceStrict value" || calls != 1 {
		t.Errorf("ForceEncryption alone in the view: force %q, strict %q, %d call(s)", got[keyForceEnc], got[keyForceStrictEnc], calls)
	}
	got, _, calls = fixtureNet(t, withEnc, 16, noRight, nil)
	if got[keyForceEnc] != "no | " || !strings.HasPrefix(got[keyForceStrictEnc], " | not read: sys.dm_server_registry holds no ForceStrict value here; no right: EXECUTE on master.dbo.xp_instance_regread") || calls != 0 {
		t.Errorf("ForceEncryption alone in the view, no right: force %q, strict %q, %d call(s)", got[keyForceEnc], got[keyForceStrictEnc], calls)
	}
	// xp_instance_regread answering ForceStrict 0 where the view holds no bare-key row: no
	reg0 := collect.Row{}
	for k, v := range reg {
		reg0[k] = v
	}
	reg0["force_strict_encryption"] = int64(0)
	got, _, calls = fixtureNet(t, view, 16, gate, func() ([]collect.Row, error) { return []collect.Row{reg0}, nil })
	if got[keyForceEnc] != "no | " || got[keyForceStrictEnc] != "no | " || calls != 1 {
		t.Errorf("ForceStrict 0 through xp_instance_regread: force %q, strict %q, %d call(s)", got[keyForceEnc], got[keyForceStrictEnc], calls)
	}
	// neither value anywhere (the key unread): not read, never 'not set'
	regNone := collect.Row{}
	for k, v := range reg {
		regNone[k] = v
	}
	regNone["force_encryption"] = nil
	got, _, _ = fixtureNet(t, view, 16, gate, func() ([]collect.Row, error) { return []collect.Row{regNone}, nil })
	if got[keyForceEnc] != " | not read: xp_instance_regread holds no ForceEncryption value" || got[keyForceStrictEnc] != " | not read: xp_instance_regread holds no ForceStrict value" {
		t.Errorf("neither value: force %q, strict %q", got[keyForceEnc], got[keyForceStrictEnc])
	}
}
