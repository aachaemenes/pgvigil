package main

import "bytes"

// The rows of GetExtendedTcpTable's TCP_TABLE_OWNER_PID_LISTENER table (Windows; read here as bytes
// so the matching is tested anywhere):
//
//	MIB_TCPROW_OWNER_PID  (24 bytes): state, local addr [4], local port, remote addr, remote port, pid
//	MIB_TCP6ROW_OWNER_PID (56 bytes): local addr [16], scope, local port, remote addr [16], scope, port, state, pid
const (
	tcp4RowSize, tcp4AddrAt, tcp4PortAt = 24, 4, 8
	tcp6RowSize, tcp6AddrAt, tcp6PortAt = 56, 0, 20
)

var (
	ip4Loopback = []byte{127, 0, 0, 1}
	ip4Any      = []byte{0, 0, 0, 0}
	ip6Loopback = append(make([]byte, 15), 1)
	ip6Any      = make([]byte, 16)
)

// listenerRowMatches says whether one row is a listener on the port that a loopback client reaches:
// bound to loopback or to every address. A listener of the same port on a LAN address is another
// socket (and maybe another user's): never taken for the serve at 127.0.0.1.
func listenerRowMatches(row []byte, v6 bool, port uint16) bool {
	addrAt, portAt, n, lo, all := tcp4AddrAt, tcp4PortAt, 4, ip4Loopback, ip4Any
	if v6 {
		addrAt, portAt, n, lo, all = tcp6AddrAt, tcp6PortAt, 16, ip6Loopback, ip6Any
	}
	// the port is in network byte order in the low two bytes of its DWORD
	if uint16(row[portAt])<<8|uint16(row[portAt+1]) != port {
		return false
	}
	a := row[addrAt : addrAt+n]
	return bytes.Equal(a, lo) || bytes.Equal(a, all)
}
