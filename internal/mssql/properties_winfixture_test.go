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
// lacks its '|~' end was cut by sqlcmd at the NUL that ends the value (the fixture's header): its value gets that NUL back.
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
			v := x[3]
			if !whole {
				v += "\x00"
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
// (SQL Server 2022, the default instance; the runner's own reads beside them: ForceEncryption 0 and no
// ForceStrictEncryption value through xp_instance_regread, TCP/IP and Shared Memory on, Named Pipes off, IPAll's static
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
		keyForceStrictEnc: " | not read: xp_instance_regread holds no ForceStrictEncryption value",
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
