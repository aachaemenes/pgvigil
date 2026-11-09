//go:build !windows

package main

import (
	"os/exec"
	"syscall"
)

// detach puts the browser in its own process group: a Ctrl-C in pgvigil's terminal goes to the
// foreground group, and a browser pgvigil started as its first instance would die with it (and
// take the user's other tabs along). The hand-off case (a browser already running) is unaffected.
func detach(cmd *exec.Cmd) { cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} }
