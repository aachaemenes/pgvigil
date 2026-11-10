//go:build windows

package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"html"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
	"unsafe"

	webview2 "github.com/jchv/go-webview2"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// the window, the tray and the WebView2 controller live on the main thread; a DLL the process loads
// by name comes from System32 only: WebView2Loader.dll is not there, so the copy embedded in the
// binary is used, never one planted beside the app or in its working folder
func init() {
	runtime.LockOSThread()
	_ = windows.SetDefaultDllDirectories(windows.LOAD_LIBRARY_SEARCH_SYSTEM32)
}

const (
	trayClass = "pgvigil-app-tray"
	mutexName = `Local\pgvigil-app` // one app per user session
)

func main() { os.Exit(run(os.Args[1:])) }

func run(args []string) int {
	if len(args) > 0 {
		switch args[0] {
		case "install":
			attachConsole()
			return report(runInstall(args[1:]))
		case "uninstall":
			attachConsole()
			return report(runUninstall(args[1:]))
		}
	}
	fs := flag.NewFlagSet("pgvigil-app", flag.ContinueOnError)
	tray := fs.Bool("tray", false, "start in the tray with the window closed (the start-at-login entry)")
	quit := fs.Bool("quit", false, "ask the running app to quit")
	check := fs.Bool("check", false, "headless: attach or start the serve, read it, run the update check, stop what was started")
	cfg := fs.String("config", "", "the UI configuration the serve reads (default %LOCALAPPDATA%\\pgvigil\\pgvigil.yaml, then %ProgramData%\\pgvigil\\app\\pgvigil.yaml)")
	ver := fs.Bool("version", false, "print the version")
	if err := fs.Parse(args); err != nil || fs.NArg() > 0 {
		attachConsole()
		fmt.Fprintln(os.Stderr, "usage: pgvigil-app [-tray] [-config file] | -quit | -check [-config file] | install [-user] [-no-autostart] [-no-update-check] | uninstall [-user] [-purge] | -version")
		return 2
	}
	switch {
	case *ver:
		attachConsole()
		fmt.Println("pgvigil-app " + version)
		return 0
	case *quit:
		attachConsole()
		if h := findApp(); h != 0 {
			_, _, _ = pPostMessageW.Call(h, wmQuit, 0, 0)
			fmt.Println("asked the running app to quit")
			return 0
		}
		fmt.Println("no pgvigil app runs in this session")
		return 1
	case *check:
		attachConsole()
		return report(runCheck(*cfg))
	}
	return runApp(*cfg, *tray)
}

func report(err error) int {
	if err == nil {
		return 0
	}
	fmt.Fprintln(os.Stderr, "pgvigil-app:", err)
	var ec interface{ ExitCode() int }
	if errors.As(err, &ec) {
		return ec.ExitCode()
	}
	return 1
}

func findApp() uintptr {
	h, _, _ := pFindWindowW.Call(uintptr(unsafe.Pointer(u16(trayClass))), 0)
	return h
}

// appDir is the user's own folder: %LOCALAPPDATA%\pgvigil (the log, the WebView2 data, the per-user install).
func appDir() string {
	d := os.Getenv("LOCALAPPDATA")
	if d == "" {
		d = os.TempDir()
	}
	return filepath.Join(d, "pgvigil")
}

func openLog() io.Writer {
	dir := appDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return io.Discard
	}
	p := filepath.Join(dir, "app.log")
	if st, err := os.Stat(p); err == nil && st.Size() > 1<<20 {
		_ = os.Rename(p, p+".1")
	}
	f, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return io.Discard
	}
	return f
}

func exists(p string) bool { st, err := os.Stat(p); return err == nil && !st.IsDir() }

// settings merges the registry and the flag, and finds the serve binary beside the app.
func settings(cfgFlag string) (Settings, error) {
	s := Merge(readChoices())
	exe, err := os.Executable()
	if err != nil {
		return s, err
	}
	s.ServeExe = filepath.Join(filepath.Dir(exe), "pgvigil.exe")
	if !exists(s.ServeExe) {
		return s, fmt.Errorf("pgvigil.exe is not beside %s: the app starts the serve from its own folder", exe)
	}
	s.ConfigPath, s.ConfigFrom, err = ResolveConfig(cfgFlag, os.Getenv("LOCALAPPDATA"), os.Getenv("ProgramData"), exists)
	return s, err
}

var httpClient = &http.Client{Timeout: 20 * time.Second}

// ensureServe attaches to a serve on the attach URL, or starts one.
func ensureServe(ctx context.Context, s Settings, logw io.Writer) (*Serve, error) {
	if Probe(ctx, httpClient, s.AttachURL) {
		mine, err := listenerOwnedByMe(s.AttachURL)
		if mine {
			return &Serve{URL: s.AttachURL}, nil
		}
		log.Printf("serve: a pgvigil serve answers at %s but runs as another user (%v): not attached, starting this user's own", s.AttachURL, err)
	}
	if s.ConfigPath == "" {
		return nil, errors.New("no serve answers at " + s.AttachURL + " and there is no UI configuration to start one")
	}
	return StartServe(ctx, s.ServeExe, ServeArgs(s.ConfigPath, s.NoLogin), logw, prepareServe, adoptServe)
}

// runCheck is the headless proof path: everything but the window.
func runCheck(cfgFlag string) error {
	ctx := context.Background()
	s, err := settings(cfgFlag)
	if err != nil && !strings.HasPrefix(err.Error(), "no UI configuration") {
		return err
	}
	fmt.Printf("check: version %s, config %q (%s), attach %s, webview2 %q\n", version, s.ConfigPath, s.ConfigFrom, s.AttachURL, webView2Version())
	sv, err := ensureServe(ctx, s, io.Discard)
	if err != nil {
		return err
	}
	if sv.Started {
		fmt.Printf("check: started %s pid %d login %v\n", sv.URL, sv.Pid(), !s.NoLogin)
	} else {
		fmt.Printf("check: attached %s\n", sv.URL)
	}
	for _, p := range []string{"", "api/health"} {
		resp, err := httpClient.Get(sv.URL + p)
		if err != nil {
			_ = sv.Stop()
			return err
		}
		n, _ := io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
		fmt.Printf("check: GET /%s %d (%d bytes)\n", p, resp.StatusCode, n)
	}
	switch {
	case !s.UpdateCheck:
		fmt.Printf("check: update check off: %s\n", s.UpdateWhy)
	default:
		rel, newer, err := CheckUpdate(ctx, httpClient, s.UpdateFeed, version)
		switch {
		case err != nil:
			fmt.Printf("check: update check %s: %v\n", s.UpdateFeed, err)
		case newer:
			fmt.Printf("check: update available %s %s\n", rel.Tag, rel.URL)
		default:
			fmt.Printf("check: update check %s: latest %s, this build %s: no notice (not newer, or this build is not a release)\n", s.UpdateFeed, rel.Tag, version)
		}
	}
	if sv.Started {
		pid := sv.Pid()
		if err := sv.Stop(); err != nil {
			return err
		}
		if !processGone(pid) {
			return fmt.Errorf("the serve pid %d still runs after the stop", pid)
		}
		fmt.Printf("check: stopped the serve pid %d\n", pid)
	}
	return nil
}

// app is the running program's state; every field is touched on the main thread only, except
// those the serve and update goroutines hand over through the posted messages.
type app struct {
	set      Settings
	setErr   error
	logw     io.Writer
	tray     uintptr // the hidden window that owns the tray icon
	icon     uintptr
	wv       webview2.WebView
	hwnd     uintptr // the WebView2 window (0 until first opened)
	oldProc  uintptr
	noWV     bool // WebView2 could not start: the browser shows the UI
	taskbar  uint32
	exe      string
	quitting bool
	// creating: WebView2 is being made; its creation runs a message loop of its own, which can call
	// show and quit again (a tray double-click, -quit): show waits it out, a quit is kept for after
	creating    bool
	pendingQuit bool

	mu       sync.Mutex
	serve    *Serve
	serveErr error
	release  *Release
}

var the *app

func runApp(cfgFlag string, startInTray bool) int {
	m, err := windows.CreateMutex(nil, false, u16(mutexName))
	if errors.Is(err, windows.ERROR_ALREADY_EXISTS) {
		if h := findApp(); h != 0 && !startInTray { // a start-at-login launch never opens the running app's window
			_, _, _ = pPostMessageW.Call(h, wmShow, 0, 0) // the running app shows its window
		}
		return 0
	}
	if m != 0 {
		defer func() { _ = windows.CloseHandle(m) }()
	}
	// per-monitor DPI: a sharp window and a size kept in real pixels (Windows 10 1703+; on older ones, Server 2016
	// among them, the call does not exist and the default stays: Find first, as Call would panic)
	if pSetProcessDpiAwarenessContext.Find() == nil {
		_, _, _ = pSetProcessDpiAwarenessContext.Call(^uintptr(3)) // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
	}
	a := &app{logw: openLog()}
	the = a
	log.SetOutput(a.logw)
	a.exe, _ = os.Executable()
	a.set, a.setErr = settings(cfgFlag)
	log.Printf("pgvigil-app %s starting: config %q (%s), attach %s, update check %v %s", version, a.set.ConfigPath, a.set.ConfigFrom, a.set.AttachURL, a.set.UpdateCheck, a.set.UpdateWhy)
	if err := a.makeTray(); err != nil {
		messageBox("pgvigil could not start its tray icon: "+err.Error(), mbOK|mbIconError)
		return 1
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go a.startServe(ctx)
	if a.set.UpdateCheck {
		go a.updateLoop(ctx)
	}
	if !startInTray {
		a.show()
	}
	a.loop()
	a.shutdown()
	return 0
}

func (a *app) startServe(ctx context.Context) {
	var sv *Serve
	err := a.setErr
	if err == nil || strings.HasPrefix(err.Error(), "no UI configuration") {
		sv, err = ensureServe(ctx, a.set, a.logw)
	}
	a.mu.Lock()
	a.serve, a.serveErr = sv, err
	a.mu.Unlock()
	if err != nil {
		log.Printf("serve: %v", err)
	} else {
		log.Printf("serve: %s (started here: %v, pid %d)", sv.URL, sv.Started, sv.Pid())
	}
	_, _, _ = pPostMessageW.Call(a.tray, wmServe, 0, 0)
	if err == nil && sv.Started {
		<-sv.Done()
		if !a.isQuitting() {
			log.Printf("serve: the started serve exited:\n%s", sv.Tail())
			_, _, _ = pPostMessageW.Call(a.tray, wmServeGone, 0, 0)
		}
	}
}

func (a *app) isQuitting() bool { a.mu.Lock(); defer a.mu.Unlock(); return a.quitting }

func (a *app) updateLoop(ctx context.Context) {
	select {
	case <-time.After(30 * time.Second): // after the start, not in its way
	case <-ctx.Done():
		return
	}
	for {
		if DueForCheck(lastUpdateCheck(), time.Now()) {
			rel, newer, err := CheckUpdate(ctx, httpClient, a.set.UpdateFeed, version)
			_ = setLastUpdateCheck(time.Now().Unix())
			switch {
			case err != nil:
				log.Printf("update check: %v", err)
			case newer:
				log.Printf("update check: %s is available", rel.Tag)
				a.mu.Lock()
				a.release = &rel
				a.mu.Unlock()
				_, _, _ = pPostMessageW.Call(a.tray, wmUpdate, 0, 0)
			default:
				log.Printf("update check: %s is current", version)
			}
		}
		select {
		case <-time.After(time.Hour):
		case <-ctx.Done():
			return
		}
	}
}

func (a *app) loop() {
	var m msg
	for {
		r, _, _ := pGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 { // WM_QUIT, or an error
			return
		}
		_, _, _ = pTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		_, _, _ = pDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
}

func (a *app) shutdown() {
	a.removeTray()
	a.mu.Lock()
	sv := a.serve
	a.mu.Unlock()
	if sv != nil && sv.Started {
		pid := sv.Pid()
		if err := sv.Stop(); err != nil {
			log.Printf("serve stop: %v", err)
		} else {
			log.Printf("serve: stopped the started serve pid %d", pid)
		}
	}
	log.Printf("pgvigil-app quit")
}

// quit saves the window, closes it and ends the loop (the window's own WM_DESTROY posts WM_QUIT).
func (a *app) quit() {
	if a.creating { // WebView2's own loop would swallow WM_QUIT: quit once it is made
		a.pendingQuit = true
		return
	}
	a.mu.Lock()
	a.quitting = true
	a.mu.Unlock()
	if a.hwnd != 0 {
		a.saveWindow()
		_, _, _ = pDestroyWindow.Call(a.hwnd)
		return
	}
	_, _, _ = pPostQuitMessage.Call(0)
}

func (a *app) saveWindow() {
	if a.hwnd == 0 {
		return
	}
	if r, _, _ := pIsIconic.Call(a.hwnd); r != 0 {
		return
	}
	zoomed, _, _ := pIsZoomed.Call(a.hwnd)
	if zoomed != 0 {
		_ = saveWindow(0, 0, true) // the restored size stays as it was
		return
	}
	var rc rect
	if r, _, _ := pGetWindowRect.Call(a.hwnd, uintptr(unsafe.Pointer(&rc))); r == 0 {
		return
	}
	w, h := int(rc.right-rc.left), int(rc.bottom-rc.top)
	if err := saveWindow(w, h, false); err != nil {
		log.Printf("window size not saved: %v", err)
	} else {
		log.Printf("window size saved: %dx%d", w, h)
	}
}

// show opens the window (made on first use), or the browser when WebView2 cannot run.
func (a *app) show() {
	a.mu.Lock()
	sv := a.serve
	a.mu.Unlock()
	if a.noWV {
		if sv != nil {
			openExternal(sv.URL)
		}
		return
	}
	if a.creating {
		return // the window is on its way
	}
	if a.hwnd == 0 {
		set := Merge(readChoices()) // the size as last saved
		if webView2Version() != "" {
			a.creating = true
			a.wv = webview2.NewWithOptions(webview2.WebViewOptions{
				DataPath:      filepath.Join(appDir(), "WebView2"),
				AutoFocus:     true,
				WindowOptions: webview2.WindowOptions{Title: "pgvigil", Width: uint(set.Width), Height: uint(set.Height), Center: true},
			})
			a.creating = false
			if a.wv == nil {
				discardFailedWindow()
			}
		}
		if a.wv == nil {
			a.noWV = true
			log.Printf("WebView2 could not start (the Evergreen runtime is missing or broken): the browser shows the UI")
			if a.pendingQuit {
				a.quit()
				return
			}
			messageBox("The Microsoft Edge WebView2 runtime is missing or could not start, so pgvigil opens in your browser instead.", mbOK|mbIconWarning)
			if sv != nil {
				openExternal(sv.URL)
			}
			return
		}
		a.hwnd = uintptr(a.wv.Window())
		_, _, _ = pSendMessageW.Call(a.hwnd, wmSetIcon, 0, a.icon)
		_, _, _ = pSendMessageW.Call(a.hwnd, wmSetIcon, 1, a.icon)
		a.oldProc, _, _ = pSetWindowLongPtrW.Call(a.hwnd, gwlpWndProc, windows.NewCallback(windowProc))
		if set.Maximized {
			_, _, _ = pShowWindow.Call(a.hwnd, swMaximize)
		}
		// the serve's state is read again here: its ready message can be handled while WebView2 is
		// still being made (the creation pumps messages), when there was no window to navigate yet
		a.mu.Lock()
		sv, serr := a.serve, a.serveErr
		a.mu.Unlock()
		switch {
		case sv != nil:
			a.wv.Navigate(sv.URL)
		case serr != nil:
			a.wv.SetHtml(errorPage("pgvigil serve did not start", serr.Error(), a.set.ConfigPath))
		default:
			a.wv.SetHtml(page("Starting pgvigil", "<p>Starting the pgvigil serve on this machine...</p>"))
		}
		log.Printf("window opened %dx%d", set.Width, set.Height)
		if a.pendingQuit {
			a.quit()
		}
		return
	}
	if v, _, _ := pIsIconic.Call(a.hwnd); v != 0 {
		_, _, _ = pShowWindow.Call(a.hwnd, swRestore)
	} else {
		_, _, _ = pShowWindow.Call(a.hwnd, swShow)
	}
	_, _, _ = pSetForegroundWindow.Call(a.hwnd)
}

// discardFailedWindow removes the window go-webview2 made and showed before WebView2 failed: it is
// left open and its own procedure would end the app when it is closed. Its procedure becomes
// DefWindowProc, then it is destroyed.
func discardFailedWindow() {
	h, _, _ := pFindWindowW.Call(uintptr(unsafe.Pointer(u16("webview"))), uintptr(unsafe.Pointer(u16("pgvigil"))))
	if h == 0 {
		return
	}
	_, _, _ = pSetWindowLongPtrW.Call(h, gwlpWndProc, pDefWindowProcW.Addr())
	_, _, _ = pDestroyWindow.Call(h)
}

// windowProc subclasses the WebView2 window: closing it hides it (the app stays in the tray); the size
// is kept after every move or resize too (a sign-out sends no WM_CLOSE).
func windowProc(hwnd, m, wp, lp uintptr) uintptr {
	a := the
	if m == wmClose && !a.isQuitting() {
		a.saveWindow()
		_, _, _ = pShowWindow.Call(hwnd, swHide)
		return 0
	}
	if m == wmExitSizeMove {
		a.saveWindow()
	}
	r, _, _ := pCallWindowProcW.Call(a.oldProc, hwnd, m, wp, lp)
	return r
}

func (a *app) onServe() {
	a.mu.Lock()
	sv, err := a.serve, a.serveErr
	a.mu.Unlock()
	switch {
	case a.wv == nil:
		if a.noWV && sv != nil {
			openExternal(sv.URL)
		}
	case err != nil:
		a.wv.SetHtml(errorPage("pgvigil serve did not start", err.Error(), a.set.ConfigPath))
	default:
		a.wv.Navigate(sv.URL)
	}
	if err != nil {
		a.balloon("pgvigil serve did not start", "Open the window for the reason.")
	}
}

func (a *app) onServeGone() {
	a.mu.Lock()
	sv := a.serve
	a.mu.Unlock()
	if a.wv != nil && sv != nil {
		a.wv.SetHtml(errorPage("pgvigil serve stopped", sv.Tail(), a.set.ConfigPath))
	}
	a.balloon("pgvigil serve stopped", "Quit pgvigil and start it again; the window shows the serve's last lines.")
}

func page(title, body string) string {
	return `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>` + html.EscapeString(title) + `</title>
<style>body{font:15px system-ui,sans-serif;margin:2rem;color:#1f2937;background:#fff}pre{white-space:pre-wrap;background:#f3f4f6;padding:1rem;border-radius:6px}
@media (prefers-color-scheme: dark){body{color:#e5e7eb;background:#111827}pre{background:#1f2937}}</style></head><body><h1>` +
		html.EscapeString(title) + `</h1>` + body + `</body></html>`
}

func errorPage(title, detail, cfg string) string {
	where := "<p>The app found no UI configuration. Make " + html.EscapeString(filepath.Join(appDir(), UIConfigName)) +
		" (yours) or ask the administrator for the machine's; 'pgvigil-app install -user' writes a template.</p>"
	if cfg != "" {
		where = "<p>The serve reads <code>" + html.EscapeString(cfg) + "</code>: check its repository login and that the repository answers.</p>"
	}
	return page(title, where+"<pre>"+html.EscapeString(detail)+"</pre>")
}

// --- the tray ---

func (a *app) makeTray() error {
	hinst, _, _ := kernel32.NewProc("GetModuleHandleW").Call(0)
	wc := wndClassEx{lpfnWndProc: windows.NewCallback(trayProc), hInstance: hinst, lpszClassName: u16(trayClass)}
	wc.cbSize = uint32(unsafe.Sizeof(wc))
	if r, _, err := pRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc))); r == 0 {
		return fmt.Errorf("register the tray class: %v", err)
	}
	h, _, err := pCreateWindowExW.Call(0, uintptr(unsafe.Pointer(u16(trayClass))), uintptr(unsafe.Pointer(u16("pgvigil"))), 0, 0, 0, 0, 0, 0, 0, hinst, 0)
	if h == 0 {
		return fmt.Errorf("the tray window: %v", err)
	}
	a.tray = h
	tc, _, _ := pRegisterWindowMessageW.Call(uintptr(unsafe.Pointer(u16("TaskbarCreated"))))
	a.taskbar = uint32(tc)
	sm, _, _ := pGetSystemMetrics.Call(49) // SM_CXSMICON
	a.icon = makeIcon(int(sm) * 2)
	return a.addIcon()
}

func (a *app) nid() notifyIconData {
	n := notifyIconData{hWnd: a.tray, uID: 1, uFlags: nifMessage | nifIcon | nifTip | nifShowTip, uCallbackMessage: wmTray, hIcon: a.icon}
	n.cbSize = uint32(unsafe.Sizeof(n))
	copyU16(n.szTip[:], "pgvigil")
	return n
}

func (a *app) addIcon() error {
	n := a.nid()
	if r, _, err := pShellNotifyIconW.Call(nimAdd, uintptr(unsafe.Pointer(&n))); r == 0 {
		return fmt.Errorf("Shell_NotifyIcon: %v", err)
	}
	n.uVersion = 4 // NOTIFYICON_VERSION_4: the event in LOWORD(lParam)
	_, _, _ = pShellNotifyIconW.Call(nimSetVersion, uintptr(unsafe.Pointer(&n)))
	return nil
}

func (a *app) removeTray() {
	if a.tray == 0 {
		return
	}
	n := a.nid()
	_, _, _ = pShellNotifyIconW.Call(nimDelete, uintptr(unsafe.Pointer(&n)))
}

func (a *app) balloon(title, text string) {
	n := a.nid()
	n.uFlags |= nifInfo
	n.dwInfoFlags = niifInfo
	copyU16(n.szInfoTitle[:], title)
	copyU16(n.szInfo[:], text)
	_, _, _ = pShellNotifyIconW.Call(nimModify, uintptr(unsafe.Pointer(&n)))
}

const (
	cmdOpen = iota + 1
	cmdBrowser
	cmdLogin
	cmdUpdate
	cmdQuit
)

func (a *app) menu() {
	h, _, _ := pCreatePopupMenu.Call()
	if h == 0 {
		return
	}
	defer func() { _, _, _ = pDestroyMenu.Call(h) }()
	add := func(flags uintptr, id int, text string) {
		_, _, _ = pAppendMenuW.Call(h, flags, uintptr(id), uintptr(unsafe.Pointer(u16(text))))
	}
	a.mu.Lock()
	sv, rel := a.serve, a.release
	a.mu.Unlock()
	add(mfString, cmdOpen, "Open pgvigil")
	if sv != nil {
		add(mfString, cmdBrowser, "Open in the browser")
	}
	machine, user := startAtLogin()
	switch {
	case machine:
		add(mfString|mfChecked|mfGrayed, cmdLogin, "Start at login (set for every user)")
	case user:
		add(mfString|mfChecked, cmdLogin, "Start at login")
	default:
		add(mfString, cmdLogin, "Start at login")
	}
	if rel != nil && rel.URL != "" {
		add(mfString, cmdUpdate, "pgvigil "+rel.Tag+" is available...")
	}
	add(mfSeparator, 0, "")
	add(mfString, cmdQuit, "Quit")
	var pt point
	_, _, _ = pGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	_, _, _ = pSetForegroundWindow.Call(a.tray)
	id, _, _ := pTrackPopupMenu.Call(h, tpmRetCmd|tpmRightBtn, uintptr(pt.x), uintptr(pt.y), 0, a.tray, 0)
	switch int(id) {
	case cmdOpen:
		a.show()
	case cmdBrowser:
		openExternal(sv.URL)
	case cmdLogin:
		if !machine {
			if err := setRun(registry.CURRENT_USER, a.exe, !user); err != nil {
				messageBox("Start at login could not be changed: "+err.Error(), mbOK|mbIconError)
			}
		}
	case cmdUpdate:
		openExternal(rel.URL)
	case cmdQuit:
		a.quit()
	}
}

func trayProc(hwnd, m, wp, lp uintptr) uintptr {
	a := the
	switch {
	case m == wmTray:
		switch lp & 0xFFFF {
		case wmLButtonUp, wmLButtonDblClk:
			a.show()
		case wmRButtonUp, wmContextMenu:
			a.menu()
		case ninBalloonUserClick:
			a.mu.Lock()
			rel := a.release
			a.mu.Unlock()
			if rel != nil && rel.URL != "" {
				openExternal(rel.URL)
			} else {
				a.show()
			}
		}
		return 0
	case m == wmShow:
		a.show()
		return 0
	case m == wmServe:
		a.onServe()
		return 0
	case m == wmServeGone:
		a.onServeGone()
		return 0
	case m == wmQuit:
		a.quit()
		return 0
	case m == wmEndSession && wp != 0: // sign-out or shutdown: no WM_CLOSE comes, the process ends after this
		a.saveWindow()
		a.mu.Lock()
		a.quitting = true
		a.mu.Unlock()
		a.shutdown()
		return 0
	case m == wmUpdate:
		a.mu.Lock()
		rel := a.release
		a.mu.Unlock()
		if rel != nil {
			a.balloon("pgvigil "+rel.Tag+" is available", "Click to open the release page. Nothing is downloaded by itself.")
		}
		return 0
	case a.taskbar != 0 && uint32(m) == a.taskbar: // Explorer restarted: the icon is gone
		_ = a.addIcon()
		return 0
	}
	r, _, _ := pDefWindowProcW.Call(hwnd, m, wp, lp)
	return r
}
