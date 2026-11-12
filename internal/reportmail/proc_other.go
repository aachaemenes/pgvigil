//go:build !unix

package reportmail

import "os/exec"

// group: no process group here (Windows): the browser is killed by its own process and WaitDelay ends the wait
func group(*exec.Cmd) {}

// killGroup kills the browser
func killGroup(cmd *exec.Cmd) {
	if cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
}
