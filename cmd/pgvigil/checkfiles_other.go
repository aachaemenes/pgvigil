//go:build !windows

package main

import "os"

// judgeHost judges one path by its mode (judgeMode).
func judgeHost(path string, isDir bool) (string, string, error) {
	st, err := os.Lstat(path)
	if err != nil {
		return "", "", err
	}
	level, words := judgeMode(path, st.Mode(), isDir)
	return level, words, nil
}
