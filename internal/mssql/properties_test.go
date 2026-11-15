package mssql

import (
	"context"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// the network rows of task 301c: their keys are fixed (the checks of task 409 judge the stored rows by them)
func TestNetworkKeysAreFixed(t *testing.T) {
	got := strings.Join([]string{keyTCPPort, keyTCPDynamic, keyListenAll, keyForceEnc, keyForceStrictEnc, keyProtocols, keyPrioritySep}, ",")
	if want := "tcp_port,tcp_port_dynamic,tcp_listen_all_ips,force_encryption,force_strict_encryption,protocols_enabled,win32_priority_separation"; got != want {
		t.Fatalf("the network keys changed: %s\nwant %s (task 409 judges the rows by these names)", got, want)
	}
}

// viewRow is one row of sys.dm_server_registry as a default instance of SQL Server 2022 names it.
func viewRow(sub, name, value string) collect.Row {
	key := `HKLM\Software\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer\SuperSocketNetLib`
	if sub != "" {
		key += `\` + sub
	}
	return collect.Row{"registry_key": key, "value_name": name, "value_data": value}
}

// netOf builds the seven rows and returns them by key as "value | note".
func netOf(in netRowsInput) map[string]string {
	p := &propList{}
	netRows(p, in)
	out := map[string]string{}
	for _, r := range p.rows {
		v, _ := r["value"].(string)
		n, _ := r["note"].(string)
		out[r["name"].(string)] = v + " | " + n
	}
	return out
}

func TestNetworkRows(t *testing.T) {
	gate := propGate{read: true, registryView: true, instanceRegread: true, regread: true, login: "mon"}
	win := func(rows ...collect.Row) netRowsInput {
		f := netFactsFromView(rows)
		return netRowsInput{kind: KindServer, major: 16, platform: "Windows", gate: gate, facts: &f, priority: int64(2)}
	}
	base := []collect.Row{viewRow("", "ForceEncryption", "0"), viewRow("", "ForceStrict", "0"), viewRow("Tcp", "ListenOnAllIPs", "1"),
		viewRow("Tcp", "Enabled", "1"), viewRow("Np", "Enabled", "0"), viewRow("Sm", "Enabled", "1")}
	for _, c := range []struct {
		name string
		in   netRowsInput
		want map[string]string
	}{
		{"Windows, a static port on IPAll", win(append(base, viewRow(`Tcp\IPAll`, "TcpPort", "1433"), viewRow(`Tcp\IPAll`, "TcpDynamicPorts", ""))...),
			map[string]string{keyTCPPort: "1433 | ", keyTCPDynamic: "no | ", keyListenAll: "yes | ", keyForceEnc: "no | ", keyForceStrictEnc: "no | ",
				keyProtocols: "Shared Memory, TCP/IP | ", keyPrioritySep: "2 | "}},
		{"Windows, a dynamic port only", win(append(base, viewRow(`Tcp\IPAll`, "TcpPort", ""), viewRow(`Tcp\IPAll`, "TcpDynamicPorts", "49823"))...),
			map[string]string{keyTCPPort: "49823 | a dynamic port: SQL Server chose it at its start and may choose another at the next", keyTCPDynamic: "yes | "}},
		{"Windows, ListenOnAllIPs off: the enabled IPn entries", win(viewRow("Tcp", "ListenOnAllIPs", "0"), viewRow("Tcp", "Enabled", "1"),
			viewRow(`Tcp\IPAll`, "TcpPort", "1433"),
			viewRow(`Tcp\IP1`, "Enabled", "1"), viewRow(`Tcp\IP1`, "IpAddress", "10.0.0.5"), viewRow(`Tcp\IP1`, "TcpPort", "1533"),
			viewRow(`Tcp\IP2`, "Enabled", "0"), viewRow(`Tcp\IP2`, "IpAddress", "10.0.0.6"), viewRow(`Tcp\IP2`, "TcpPort", "1600"),
			viewRow(`Tcp\IP3`, "Enabled", "1"), viewRow(`Tcp\IP3`, "IpAddress", "127.0.0.1"), viewRow(`Tcp\IP3`, "TcpDynamicPorts", "50001")),
			map[string]string{keyTCPPort: "1533, 50001 | ListenOnAllIPs is off: IP1 10.0.0.5: 1533; IP3 127.0.0.1: 50001", keyTCPDynamic: "yes | ",
				keyListenAll: "no | ", keyProtocols: "TCP/IP | ", keyForceEnc: " | not read: sys.dm_server_registry holds no ForceEncryption value"}},
		{"Windows, two static ports on IPAll", win(append(base, viewRow(`Tcp\IPAll`, "TcpPort", "1533,1433"))...),
			map[string]string{keyTCPPort: "1433, 1533 | ", keyTCPDynamic: "no | "}},
		{"Windows, IPAll a static port and a dynamic one: both listen", win(append(base, viewRow(`Tcp\IPAll`, "TcpPort", "1433"), viewRow(`Tcp\IPAll`, "TcpDynamicPorts", "51234"))...),
			map[string]string{keyTCPPort: "1433, 51234 | a static port and a dynamic one: TcpDynamicPorts is set, so the instance listens on both; the dynamic one may change at the next start",
				keyTCPDynamic: "yes | "}},
		{"Windows, IPAll a static port and dynamic 0", win(append(base, viewRow(`Tcp\IPAll`, "TcpPort", "1433"), viewRow(`Tcp\IPAll`, "TcpDynamicPorts", "0"))...),
			map[string]string{keyTCPPort: "1433 | dynamic ports are on as well (TcpDynamicPorts 0): SQL Server chooses one at its next start besides the static port", keyTCPDynamic: "yes | "}},
		{"Windows, dynamic 0 alone", win(append(base, viewRow(`Tcp\IPAll`, "TcpDynamicPorts", "0"))...),
			map[string]string{keyTCPPort: " | dynamic ports are on and none is chosen yet (TcpDynamicPorts 0: SQL Server chooses it at its next start)", keyTCPDynamic: "yes | "}},
		{"Windows, TCP/IP disabled: no port listens", win(viewRow("Tcp", "ListenOnAllIPs", "1"), viewRow("Tcp", "Enabled", "0"), viewRow("Np", "Enabled", "1"),
			viewRow(`Tcp\IPAll`, "TcpPort", "1433")),
			map[string]string{keyTCPPort: " | not listening: TCP/IP is disabled, so the instance listens on no TCP port",
				keyTCPDynamic: " | not listening: TCP/IP is disabled, so the instance listens on no TCP port", keyProtocols: "Named Pipes | "}},
		{"Linux, ListenOnAllIPs 0 in the registry: IPAll's port all the same", func() netRowsInput {
			f := netFactsFromRegread(collect.Row{"force_encryption": int64(0), "listen_all": int64(0), "ipall_port": "1433"})
			return netRowsInput{kind: KindServer, major: 16, platform: "Linux", gate: gate, facts: &f}
		}(), map[string]string{keyTCPPort: "1433 | SQL Server on Linux: mssql-conf network.tcpport, read through its registry", keyTCPDynamic: "no | "}},
		{"Windows, SQL Server 2019: no strict encryption", func() netRowsInput {
			in := win(append(base, viewRow(`Tcp\IPAll`, "TcpPort", "1433"))...)
			in.major = 15
			return in
		}(), map[string]string{keyForceStrictEnc: " | not on this version: strict encryption came with SQL Server 2022"}},
		{"Windows, through xp_instance_regread: no IPn entries", func() netRowsInput {
			f := netFactsFromRegread(collect.Row{"force_encryption": int64(1), "listen_all": int64(0), "tcp_enabled": int64(1), "np_enabled": int64(1),
				"sm_enabled": int64(0), "ipall_port": "1433"})
			return netRowsInput{kind: KindServer, major: 16, platform: "Windows", gate: gate, facts: &f, priority: int64(38)}
		}(), map[string]string{keyTCPPort: " | not read: ListenOnAllIPs is off and the IPn entries need sys.dm_server_registry (VIEW SERVER STATE)",
			keyTCPDynamic: " | not read: ListenOnAllIPs is off and the IPn entries need sys.dm_server_registry (VIEW SERVER STATE)",
			keyForceEnc:   "yes | ", keyProtocols: "Named Pipes, TCP/IP | ", keyPrioritySep: "38 | ",
			keyForceStrictEnc: " | not set (strict encryption off unless it is set)"}},
		{"Linux, mssql-conf through the registry", func() netRowsInput {
			f := netFactsFromRegread(collect.Row{"force_encryption": int64(1), "listen_all": int64(1), "np_enabled": int64(0), "ipall_port": "1500"})
			return netRowsInput{kind: KindServer, major: 16, platform: "Linux", gate: gate, facts: &f}
		}(), map[string]string{keyTCPPort: "1500 | SQL Server on Linux: mssql-conf network.tcpport, read through its registry", keyTCPDynamic: "no | ",
			keyListenAll: " | not on Linux: mssql-conf network.ipaddress chooses the address",
			keyForceEnc:  "yes | SQL Server on Linux: mssql-conf network.forceencryption, read through its registry",
			keyProtocols: "TCP/IP | met: Linux serves TCP only", keyPrioritySep: " | not on Linux: a Windows scheduler setting"}},
		{"no right to the procedure", netRowsInput{kind: KindServer, major: 16, platform: "Linux", gate: propGate{read: true, login: "a]b"},
			factsWhy: propGate{login: "a]b"}.noRight("xp_instance_regread")},
			map[string]string{keyTCPPort: " | no right: EXECUTE on master.dbo.xp_instance_regread - in master, CREATE USER [a]]b] FOR LOGIN [a]]b] when it has none, then GRANT EXECUTE ON dbo.xp_instance_regread TO [a]]b]", keyForceEnc: " | no right: EXECUTE on master.dbo.xp_instance_regread - in master, CREATE USER [a]]b] FOR LOGIN [a]]b] when it has none, then GRANT EXECUTE ON dbo.xp_instance_regread TO [a]]b]",
				keyProtocols: "TCP/IP | met: Linux serves TCP only", keyListenAll: " | not on Linux: mssql-conf network.ipaddress chooses the address",
				keyPrioritySep: " | not on Linux: a Windows scheduler setting"}},
		{"Amazon RDS", netRowsInput{kind: KindRDS, platform: "Windows"},
			map[string]string{keyTCPPort: " | not applicable: Amazon RDS runs the host", keyPrioritySep: " | not applicable: Amazon RDS runs the host"}},
		{"Managed Instance", netRowsInput{kind: KindAzureMI}, map[string]string{keyForceEnc: " | not applicable: Azure SQL Managed Instance runs the host"}},
		{"Cloud SQL", netRowsInput{kind: KindCloudSQL, platform: "Linux"}, map[string]string{keyProtocols: " | not applicable: Google Cloud SQL runs the host"}},
		{"the host not read", netRowsInput{kind: KindServer, hostWhy: "not read: VIEW SERVER PERFORMANCE STATE was denied"},
			map[string]string{keyTCPPort: " | not read: the host's platform is not known (VIEW SERVER PERFORMANCE STATE was denied)"}},
	} {
		got := netOf(c.in)
		if len(got) != 7 {
			t.Errorf("%s: %d rows, want the seven", c.name, len(got))
		}
		for k, w := range c.want {
			if got[k] != w {
				t.Errorf("%s: %s = %q, want %q", c.name, k, got[k], w)
			}
		}
	}
}

// Windows without the right to xp_regread: the power plan and Win32PrioritySeparation name the GRANT, and the
// procedure is not called (conn is nil: a call would panic)
func TestPowerPlanGate(t *testing.T) {
	g := propGate{read: true, login: "pgvigil_mon"}
	v, note := powerPlan(context.Background(), nil, Info{Kind: KindServer}, "Windows", true, "", g)
	nrReg := "no right: EXECUTE on master.dbo.xp_regread - in master, CREATE USER [pgvigil_mon] FOR LOGIN [pgvigil_mon] when it has none, then GRANT EXECUTE ON dbo.xp_regread TO [pgvigil_mon]"
	if v != nil || note != nrReg {
		t.Errorf("power plan without the right: %v | %s", v, note)
	}
	in, partial := readNetwork(context.Background(), nil, Info{Kind: KindServer, Major: 16}, "Windows", g)
	if len(partial) != 0 || in.facts != nil || !strings.HasPrefix(in.factsWhy, "no right: EXECUTE on master.dbo.xp_instance_regread - in master, CREATE USER [pgvigil_mon]") ||
		!strings.HasSuffix(in.factsWhy, "(or GRANT VIEW SERVER STATE TO [pgvigil_mon], which reads sys.dm_server_registry)") || in.prioWhy != nrReg {
		t.Errorf("no rights: %+v %v", in, partial)
	}
}
