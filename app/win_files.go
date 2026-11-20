//go:build windows

package main

import (
	"fmt"
	"log"
	"net/url"
	"path/filepath"
	"runtime"
	"strings"
	"time"
	"unsafe"
)

// Files opened in the app (openfiles.go): a start's own file arguments, or a second start's handed over by
// WM_COPYDATA, wait in a.waiting until the page asks for them (its bound pgvigilAppFiles, when its viewer is ready, and
// again after each file); each is read off the main thread, one at a time, and posted to the page in parts by Eval.

// copyDataStruct is COPYDATASTRUCT.
type copyDataStruct struct {
	dwData uintptr
	cbData uint32
	lpData unsafe.Pointer
}

// readyFile is a read file's scripts, handed from the reading goroutine to the main thread.
type readyFile struct {
	name    string
	size    int
	why     string
	scripts []string
}

const (
	handOverWait    = 10 * time.Second // a first start's window, when Explorer starts several at once
	smtoAbortIfHung = 0x0002
	pageAsk         = "window.pgvigilAppPing&&window.pgvigilAppPing()"
)

// handOver sends a second start's files to the app already running in this session and ends.
func handOver(args []string) int {
	paths, refused := OpenPaths(args, filepath.Abs)
	if len(refused) > 0 {
		var w []string
		for _, r := range refused {
			w = append(w, r.Why)
		}
		messageBox(strings.Join(w, "\n"), mbOK|mbIconWarning)
	}
	if len(paths) == 0 {
		return 2
	}
	b, err := EncodeCopyData(paths)
	if err != nil {
		messageBox("pgvigil could not hand the files to its running window: "+err.Error(), mbOK|mbIconError)
		return 2
	}
	cds := copyDataStruct{dwData: CopyDataMagic, cbData: uint32(len(b)), lpData: unsafe.Pointer(&b[0])}
	deadline := time.Now().Add(handOverWait)
	for {
		if h := findApp(); h != 0 {
			// the running app may bring its window forward: Windows lets only the foreground process (this start, which
			// Explorer made) hand that on
			var pid uint32
			_, _, _ = pGetWindowThreadProcessID.Call(h, uintptr(unsafe.Pointer(&pid)))
			if pid != 0 {
				_, _, _ = pAllowSetForegroundWindow.Call(uintptr(pid))
			}
			var res uintptr
			r, _, callErr := pSendMessageTimeoutW.Call(h, wmCopyData, 0, uintptr(unsafe.Pointer(&cds)), smtoAbortIfHung, uintptr(handOverWait/time.Millisecond), uintptr(unsafe.Pointer(&res)))
			runtime.KeepAlive(b)
			if r != 0 && res != 0 {
				return 0
			}
			why := "it refused them: an older pgvigil runs, or it is closing - quit it from its tray icon and open the file(s) again"
			if r == 0 {
				why = callErr.Error() // a hung app, or one started elevated (Windows keeps a lower start's messages from it)
			}
			messageBox(fmt.Sprintf("pgvigil is running but did not take the file(s) (%s): %s", why, strings.Join(paths, ", ")), mbOK|mbIconError)
			return 1
		}
		if time.Now().After(deadline) {
			messageBox("pgvigil is starting but its window did not appear within 10 seconds: open the file(s) again in a moment.", mbOK|mbIconWarning)
			return 1
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// onCopyData takes a second start's paths. Its data is valid only while the message is handled: copied out first.
func (a *app) onCopyData(lp uintptr) uintptr {
	cds := *(**copyDataStruct)(unsafe.Pointer(&lp))
	if cds == nil || cds.dwData != CopyDataMagic {
		return 0 // another program's WM_COPYDATA: not read
	}
	if a.isQuitting() { // taken now they would be lost: the second start says so instead
		log.Printf("files: a hand-over refused: the app is quitting")
		return 0
	}
	if cds.cbData == 0 || cds.cbData > MaxCopyData || cds.lpData == nil {
		log.Printf("files: a hand-over of %d bytes refused", cds.cbData)
		return 0
	}
	b := append([]byte(nil), unsafe.Slice((*byte)(cds.lpData), cds.cbData)...)
	paths, err := DecodeCopyData(cds.dwData, b)
	if err != nil {
		log.Printf("files: a hand-over refused: %v", err)
		return 0
	}
	// the window (and WebView2 with its own message loop) is made after the sender has its answer, never inside its send
	a.handed = append(a.handed, paths...)
	_, _, _ = pPostMessageW.Call(a.tray, wmFilesAdd, 0, 0)
	return 1
}

func (a *app) onFilesAdd() {
	paths := a.handed
	a.handed = nil
	if len(paths) > 0 {
		a.addFiles(paths, nil, "handed over by a second start")
	}
}

// addFiles queues files for the page, opens the window and asks the page to fetch them. Without WebView2 (read before
// any window or browser opens) the files go the browser's way: noWVFiles.
func (a *app) addFiles(paths []string, refused []OpenFile, from string) {
	log.Printf("files: %d %s", len(paths)+len(refused), from)
	if !a.noWV && a.hwnd == 0 && !a.creating && webView2Version() == "" {
		a.noWV = true
		log.Printf("WebView2 is not installed: the browser shows the UI")
	}
	var names []string
	for _, p := range paths {
		names = append(names, filepath.Base(p))
	}
	for _, f := range refused {
		names = append(names, f.Name)
	}
	if a.noWV {
		a.noWVFiles(names, true)
		return
	}
	for _, p := range paths {
		a.waiting = append(a.waiting, OpenFile{Path: p, Name: filepath.Base(p)})
	}
	a.waiting = append(a.waiting, refused...)
	a.show()
	if a.noWV { // the window failed to start just now (show said so and opened the browser)
		var left []string
		for _, f := range a.waiting {
			left = append(left, f.Name)
		}
		a.waiting = nil
		a.noWVFiles(left, false)
		return
	}
	a.ping()
}

// noWVFiles tells, one box at a time, which files the browser's page cannot be handed: the names that come while a box
// is on screen (its loop lets the next start's files in) go in the next box, never a box each; the browser opens once
// for them.
func (a *app) noWVFiles(names []string, openBrowser bool) {
	a.noWVNames = append(a.noWVNames, names...)
	if a.noWVBox {
		return
	}
	a.noWVBox = true
	if openBrowser {
		a.mu.Lock()
		sv := a.serve
		a.mu.Unlock()
		if sv != nil {
			openExternal(sv.URL)
		}
	}
	for len(a.noWVNames) > 0 {
		batch := a.noWVNames
		a.noWVNames = nil
		messageBox("pgvigil's window could not start (the WebView2 runtime is missing), so it cannot show "+strings.Join(batch, ", ")+": open them from the Tools menu of the page in your browser.", mbOK|mbIconWarning)
	}
	a.noWVBox = false
}

// origin is the serve's own origin (scheme://host:port), "" before it is known: every script the app sends the page is
// guarded by it (PageGuard).
func (a *app) origin() string {
	a.mu.Lock()
	sv := a.serve
	a.mu.Unlock()
	if sv == nil {
		return ""
	}
	u, err := url.Parse(sv.URL)
	if err != nil {
		return ""
	}
	return u.Scheme + "://" + u.Host
}

// ping asks the page for the waiting files; a page without the viewer (the start page) does nothing, and the page asks
// itself once its viewer is ready. Before the serve is known there is no page of its own to ask.
func (a *app) ping() {
	if o := a.origin(); a.wv != nil && len(a.waiting) > 0 && o != "" {
		a.wv.Eval(PageGuard(o) + pageAsk)
	}
}

// bindFiles gives the page its two calls. Their promises are never resolved (go-webview2 resolves a binding through its
// own Run loop, which this app does not run), so the page never waits on them; each call only posts to the tray.
func (a *app) bindFiles() {
	if err := a.wv.Bind("pgvigilAppFiles", func() { _, _, _ = pPostMessageW.Call(a.tray, wmFilesAsk, 0, 0) }); err != nil {
		log.Printf("files: bind: %v", err)
	}
	if err := a.wv.Bind("pgvigilAppOpened", func(name, title string) { log.Printf("files: the page opened %q as %q", clip(name), clip(title)) }); err != nil {
		log.Printf("files: bind: %v", err)
	}
}

// deliverNext starts reading the next waiting file, one at a time: a file of 64 MB is about 150 MB with its scripts.
func (a *app) deliverNext() {
	if a.inFlight || len(a.waiting) == 0 || a.wv == nil {
		return
	}
	f := a.waiting[0]
	a.waiting = a.waiting[1:]
	a.inFlight = true
	a.nextFile++
	id := a.nextFile
	origin := a.origin()
	go func() {
		if f.Why == "" {
			f = ReadOpen(f.Path)
		}
		r := &readyFile{name: f.Name, size: len(f.Data), why: f.Why, scripts: GuardScripts(origin, PageScripts(id, f, PartBytes))}
		a.mu.Lock()
		a.ready = r
		a.mu.Unlock()
		_, _, _ = pPostMessageW.Call(a.tray, wmFilesRead, 0, 0)
	}()
}

// postRead posts a read file's parts to the page; the page asks for the next once it has opened this one (or failed
// to): one file in the page at a time, never a queue of them.
func (a *app) postRead() {
	a.mu.Lock()
	r := a.ready
	a.ready = nil
	a.mu.Unlock()
	a.inFlight = false
	if r == nil {
		return
	}
	if a.wv != nil {
		for _, s := range r.scripts {
			a.wv.Eval(s)
		}
	}
	if r.why != "" {
		log.Printf("files: %s refused: %s", r.name, r.why)
	} else {
		log.Printf("files: %s posted to the page in %d parts (%d bytes)", r.name, len(r.scripts), r.size)
	}
}

// clip bounds a page-given string in the log (200 characters).
func clip(s string) string {
	if r := []rune(s); len(r) > 200 {
		return string(r[:200]) + "..."
	}
	return s
}
