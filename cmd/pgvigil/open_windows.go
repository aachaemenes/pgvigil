//go:build windows

package main

import "os/exec"

// detach: nothing to do on Windows; msedge.exe, chrome.exe and rundll32.exe are GUI-subsystem
// programs with no console of pgvigil's to share, so a Ctrl-C in pgvigil's window never reaches them.
func detach(cmd *exec.Cmd) {}
