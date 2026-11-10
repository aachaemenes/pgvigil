// Command pgvigil-app is the pgvigil desktop program for Windows: it starts (or attaches to) the
// collector's `pgvigil serve` on loopback and shows the UI in a WebView2 window with a tray icon.
//
//	pgvigil-app [-tray] [-config file]     run (-tray: start in the tray, the window closed)
//	pgvigil-app -quit                      ask the running app to quit (and stop the serve it started)
//	pgvigil-app -check [-config file]      headless: attach or start the serve, read it, run the update check, stop
//	pgvigil-app install [-user] [-no-autostart] [-no-update-check]
//	pgvigil-app uninstall [-user] [-purge]
//	pgvigil-app -version
//
// The portable parts (settings, the serve's start and attach, the update check) build and test on
// any system; the window, the tray, the registry and the installer are Windows only.
package main

import (
	"errors"
	"path/filepath"
	"strings"
)

// version is set by the build (-ldflags "-X main.version=...").
var version = "dev"

const (
	// DefaultAttachURL is where a serve another process runs is looked for first.
	DefaultAttachURL = "http://127.0.0.1:8080/"
	// DefaultFeed is the release feed of the update check (the latest release, as JSON).
	DefaultFeed = "https://api.github.com/repos/aachaemenes/pgvigil/releases/latest"
	// UIConfigName is the UI configuration the app's serve reads.
	UIConfigName = "pgvigil.yaml"
)

// Settings are the app's choices after the policy (HKLM\Software\Policies\pgvigil\App), the
// user's own (HKCU\Software\pgvigil\App) and the flags are merged.
type Settings struct {
	ConfigPath  string // the UI configuration the serve reads
	ConfigFrom  string // where it was found: flag, user, machine
	ServeExe    string // pgvigil.exe
	AttachURL   string // a serve to attach to before starting one
	NoLogin     bool   // start the serve with -no-login (the user's choice, unless the policy requires the login)
	UpdateCheck bool   // check the release feed once a day
	UpdateWhy   string // why the check is off, when it is
	UpdateFeed  string
	Width       int
	Height      int
	Maximized   bool
}

// Choices are the raw values read from the registry; nil = not set.
type Choices struct {
	PolicyUpdateCheck  *uint32
	PolicyUpdateFeed   string
	PolicyAttachURL    string
	PolicyRequireLogin *uint32
	UserUpdateCheck    *uint32
	UserAttachURL      string
	UserNoLogin        *uint32
	Width, Height      *uint32
	Maximized          *uint32
}

// Merge applies the precedence: the policy (the administrator's) over the user's over the defaults.
func Merge(c Choices) Settings {
	s := Settings{AttachURL: DefaultAttachURL, UpdateCheck: true, UpdateFeed: DefaultFeed, Width: 1280, Height: 800}
	switch {
	case c.PolicyUpdateCheck != nil && *c.PolicyUpdateCheck == 0:
		s.UpdateCheck, s.UpdateWhy = false, "turned off by the administrator (policy UpdateCheck = 0)"
	case c.UserUpdateCheck != nil && *c.UserUpdateCheck == 0:
		s.UpdateCheck, s.UpdateWhy = false, "turned off by the user"
	}
	if f := strings.TrimSpace(c.PolicyUpdateFeed); f != "" {
		s.UpdateFeed = f
	}
	if u := strings.TrimSpace(c.UserAttachURL); u != "" {
		s.AttachURL = u
	}
	if u := strings.TrimSpace(c.PolicyAttachURL); u != "" {
		s.AttachURL = u
	}
	if !strings.HasSuffix(s.AttachURL, "/") {
		s.AttachURL += "/"
	}
	s.NoLogin = c.UserNoLogin != nil && *c.UserNoLogin != 0 && (c.PolicyRequireLogin == nil || *c.PolicyRequireLogin == 0)
	if c.Width != nil && c.Height != nil && *c.Width >= 400 && *c.Height >= 300 && *c.Width <= 16384 && *c.Height <= 16384 {
		s.Width, s.Height = int(*c.Width), int(*c.Height)
	}
	s.Maximized = c.Maximized != nil && *c.Maximized != 0
	return s
}

// ResolveConfig finds the UI configuration: the flag, else the user's own (%LOCALAPPDATA%\pgvigil),
// else the machine's (%ProgramData%\pgvigil\app, written by the machine-wide installer).
func ResolveConfig(flagPath, localAppData, programData string, exists func(string) bool) (path, from string, err error) {
	if flagPath != "" {
		if !exists(flagPath) {
			return "", "", errors.New("-config " + flagPath + ": no such file")
		}
		return flagPath, "flag", nil
	}
	var tried []string
	if localAppData != "" {
		p := filepath.Join(localAppData, "pgvigil", UIConfigName)
		if exists(p) {
			return p, "user", nil
		}
		tried = append(tried, p)
	}
	if programData != "" {
		p := filepath.Join(programData, "pgvigil", "app", UIConfigName)
		if exists(p) {
			return p, "machine", nil
		}
		tried = append(tried, p)
	}
	return "", "", errors.New("no UI configuration: looked for " + strings.Join(tried, " and "))
}

// ConfigTemplate is the UI configuration an install writes when there is none: the repository
// login the UI reads with (pgvigil_reader + pgvigil_auth; the password in the user's pgpass.conf or a
// file: indirection, never in this file when other users can read it) and no instance.
func ConfigTemplate() string {
	return `# pgvigil desktop app: the repository login the UI reads with. The app runs
#   pgvigil serve -config <this file> -listen 127.0.0.1:<a free port>
# as the signed-in user. The login is IN ROLE pgvigil_reader, pgvigil_auth (see 'pgvigil roles').
# Keep the password out of this file when other users can read it: put it in the user's
# %APPDATA%\postgresql\pgpass.conf, or write the dsn as file:<a path only that user can read>.
repository:
  dsn: "host=<repository host> port=5432 dbname=pgvigil user=<ui login> sslmode=verify-full"
instances: []
`
}
