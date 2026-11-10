//go:build !windows

package main

import (
	"fmt"
	"os"
)

// The app is a Windows program; elsewhere 'pgvigil serve -open' opens the UI in its own window.
func main() {
	fmt.Fprintln(os.Stderr, "pgvigil-app "+version+" is a Windows program; here use: pgvigil serve -open")
	os.Exit(2)
}
