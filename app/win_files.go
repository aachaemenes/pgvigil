//go:build windows

package main

import (
	"fmt"
	"log"
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
			var res uintptr
			r, _, callErr := pSendMessageTimeoutW.Call(h, wmCopyData, 0, uintptr(unsafe.Pointer(&cds)), smtoAbortIfHung, uintptr(handOverWait/time.Millisecond), uintptr(unsafe.Pointer(&res)))
			runtime.KeepAlive(b)
			if r != 0 && res != 0 {
				return 0
			}
			why := "it refused them"
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

// addFiles queues files for the page, opens the window and asks the page to fetch them.
func (a *app) addFiles(paths []string, refused []OpenFile, from string) {
	for _, p := range paths {
		a.waiting = append(a.waiting, OpenFile{Path: p, Name: filepath.Base(p)})
	}
	a.waiting = append(a.waiting, refused...)
	log.Printf("files: %d %s", len(paths)+len(refused), from)
	a.show()
	if a.noWV { // the browser shows the UI: a file cannot be handed to it
		var names []string
		for _, f := range a.waiting {
			names = append(names, f.Name)
		}
		a.waiting = nil
		messageBox("pgvigil's window could not start, so it cannot show "+strings.Join(names, ", ")+": open them from the Tools menu of the page in your browser.", mbOK|mbIconWarning)
		return
	}
	a.ping()
}

// ping asks the page for the waiting files; a page without the viewer (the start page) does nothing, and the page asks
// itself once its viewer is ready.
func (a *app) ping() {
	if a.wv != nil && len(a.waiting) > 0 {
		a.wv.Eval(pageAsk)
	}
}

// bindFiles gives the page its two calls. Their promises are never resolved (go-webview2 resolves a binding through its
// own Run loop, which this app does not run), so the page never waits on them; each call only posts to the tray.
func (a *app) bindFiles() {
	if err := a.wv.Bind("pgvigilAppFiles", func() { _, _, _ = pPostMessageW.Call(a.tray, wmFilesAsk, 0, 0) }); err != nil {
		log.Printf("files: bind: %v", err)
	}
	if err := a.wv.Bind("pgvigilAppOpened", func(name, title string) { log.Printf("files: the page opened %q as %q", name, title) }); err != nil {
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
	go func() {
		if f.Why == "" {
			f = ReadOpen(f.Path)
		}
		r := &readyFile{name: f.Name, size: len(f.Data), why: f.Why, scripts: PageScripts(id, f, PartBytes)}
		a.mu.Lock()
		a.ready = r
		a.mu.Unlock()
		_, _, _ = pPostMessageW.Call(a.tray, wmFilesRead, 0, 0)
	}()
}

// postRead posts a read file's parts to the page, then asks for the next.
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
	a.ping()
}
