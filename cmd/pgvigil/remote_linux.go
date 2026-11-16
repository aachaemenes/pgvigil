//go:build linux

package main

import "fmt"

// install --remote's names on Linux (the lead's 11:4x ask; task 11's installer and the docs take the same): its own unit,
// account, config and folders, so a box can run a hub collector beside it.
const (
	remoteUnitPath = "/etc/systemd/system/pgvigil-remote.service"
	remoteBin      = "/usr/local/bin/pgvigil"
	remoteConfig   = "/etc/pgvigil-remote/pgvigil-remote.yaml"
	remoteEnvFile  = "/etc/pgvigil-remote/pgvigil-remote.env"
	remoteAccount  = "pgvigil-remote"
	remoteOutbox   = "/var/lib/pgvigil-remote/outbox"
	remoteStateDir = "/var/lib/pgvigil-remote/state"
)

// renderRemoteUnit is the remote collector's systemd unit (R14): the hub collector's hardening (renderUnit) with write
// access to its outbox and its state folder only - the file system stays read only everywhere else.
func renderRemoteUnit(bin, cfg, envFile, account, outbox, stateDir string) string {
	return fmt.Sprintf(`[Unit]
Description=pgvigil remote collector (writes interval bundles for a pgvigil hub)
Documentation=https://github.com/aachaemenes/pgvigil
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=%[4]s
EnvironmentFile=%[3]s
ExecStart=%[1]s run -config %[2]s
Restart=on-failure
RestartSec=10s
RestartPreventExitStatus=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=%[5]s %[6]s
PrivateTmp=yes
PrivateDevices=yes
DevicePolicy=closed
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
ProcSubset=pid
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=yes
MemoryDenyWriteExecute=yes
RemoveIPC=yes
UMask=0077
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged

[Install]
WantedBy=multi-user.target
`, bin, cfg, envFile, account, outbox, stateDir)
}
