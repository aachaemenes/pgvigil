package main

import (
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

// The -open switch of serve and demo: the UI in an app-mode browser window (the page in its own
// window, no address bar or tabs), which is the desktop face of pgvigil for a user who cannot
// install anything. Edge and Chrome both take --app=<url>; the user's own install under
// LocalAppData counts, so a standard user without admin rights gets the window too. When neither
// is found the default browser opens a tab, and when nothing can be started the server keeps
// running: the URL is in the log either way.

// browseURL is the address a browser on this machine reaches the bound listener at: an
// unspecified listen host (0.0.0.0, ::) becomes the loopback address of its family.
func browseURL(scheme string, addr net.Addr) string {
	host, port, err := net.SplitHostPort(addr.String())
	if err != nil {
		return scheme + "://" + addr.String() + "/"
	}
	if ip := net.ParseIP(host); host == "" || (ip != nil && ip.IsUnspecified()) {
		host = "127.0.0.1"
		if ip != nil && ip.To4() == nil {
			host = "::1"
		}
	}
	return fmt.Sprintf("%s://%s/", scheme, net.JoinHostPort(host, port))
}

// appWindowCandidates lists, in order, the programs that open a URL as an app-mode window on goos
// and the argument each takes; a bare name is looked up on PATH, a path is checked as a file.
// env reads an environment variable (os.Getenv outside the tests).
func appWindowCandidates(goos, url string, env func(string) string) [][]string {
	app := "--app=" + url
	switch goos {
	case "windows":
		var c [][]string
		for _, rel := range []string{`Microsoft\Edge\Application\msedge.exe`, `Google\Chrome\Application\chrome.exe`} {
			for _, root := range []string{env("ProgramFiles(x86)"), env("ProgramFiles"), env("LocalAppData")} {
				if root != "" {
					c = append(c, []string{filepath.Join(root, rel), app})
				}
			}
		}
		return append(c, []string{"msedge.exe", app}, []string{"chrome.exe", app})
	case "darwin":
		return [][]string{
			{"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", app},
			{"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge", app},
			{"/Applications/Chromium.app/Contents/MacOS/Chromium", app},
		}
	default:
		var c [][]string
		for _, name := range []string{"chromium", "chromium-browser", "google-chrome", "google-chrome-stable", "microsoft-edge", "microsoft-edge-stable", "brave-browser"} {
			c = append(c, []string{name, app})
		}
		return c
	}
}

// defaultBrowserCommand opens the URL with the OS's default handler: a tab in whatever browser
// the user has, the last resort when no app-mode browser is found.
func defaultBrowserCommand(goos, url string) []string {
	switch goos {
	case "windows":
		return []string{"rundll32", "url.dll,FileProtocolHandler", url}
	case "darwin":
		return []string{"open", url}
	default:
		return []string{"xdg-open", url}
	}
}

// openWindow starts the first candidate that exists, then the default browser; it returns the
// program started, or "" when none could be (logged as a warning, never an error: the server runs).
func openWindow(log *slog.Logger, url string) string {
	try := func(argv []string) bool {
		prog := argv[0]
		if filepath.IsAbs(prog) {
			if st, err := os.Stat(prog); err != nil || st.IsDir() {
				return false
			}
		} else if p, err := exec.LookPath(prog); err == nil {
			prog = p
		} else {
			return false
		}
		cmd := exec.Command(prog, argv[1:]...)
		detach(cmd)
		if err := cmd.Start(); err != nil {
			log.Warn("open: the browser did not start", "program", prog, "err", err)
			return false
		}
		go func() { _ = cmd.Wait() }() // reap it; an app-mode launch hands off to a running browser and exits at once
		return true
	}
	for _, argv := range appWindowCandidates(runtime.GOOS, url, os.Getenv) {
		if try(argv) {
			log.Info("open: app window", "program", argv[0], "url", url)
			return argv[0]
		}
	}
	if argv := defaultBrowserCommand(runtime.GOOS, url); try(argv) {
		log.Info("open: default browser (no Edge or Chrome found for an app window)", "program", argv[0], "url", url)
		return argv[0]
	}
	log.Warn("open: no browser could be started; open the URL yourself", "url", url)
	return ""
}
