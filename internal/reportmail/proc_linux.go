//go:build linux

package reportmail

import (
	"os/exec"
	"syscall"
)

// group puts the browser in a process group of its own, killed with it, and ends it when the server dies
func group(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGKILL}
}

// killGroup kills the browser and every process of its group (its renderer, GPU and crash handler children)
func killGroup(cmd *exec.Cmd) {
	if cmd.Process != nil {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		_ = cmd.Process.Kill()
	}
}
