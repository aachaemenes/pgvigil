//go:build !linux && !windows

package main

// hasPosixACL: off Linux no POSIX access list is read here.
func hasPosixACL(string, bool) bool { return false }
