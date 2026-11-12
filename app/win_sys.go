//go:build windows

package main

import (
	"os"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The Win32 calls the window, the tray and the installer use (user32, shell32, gdi32, kernel32).
var (
	user32   = windows.NewLazySystemDLL("user32.dll")
	shell32  = windows.NewLazySystemDLL("shell32.dll")
	gdi32    = windows.NewLazySystemDLL("gdi32.dll")
	kernel32 = windows.NewLazySystemDLL("kernel32.dll")

	pRegisterClassExW              = user32.NewProc("RegisterClassExW")
	pCreateWindowExW               = user32.NewProc("CreateWindowExW")
	pDefWindowProcW                = user32.NewProc("DefWindowProcW")
	pGetMessageW                   = user32.NewProc("GetMessageW")
	pTranslateMessage              = user32.NewProc("TranslateMessage")
	pDispatchMessageW              = user32.NewProc("DispatchMessageW")
	pPostMessageW                  = user32.NewProc("PostMessageW")
	pPostQuitMessage               = user32.NewProc("PostQuitMessage")
	pShowWindow                    = user32.NewProc("ShowWindow")
	pSetForegroundWindow           = user32.NewProc("SetForegroundWindow")
	pDestroyWindow                 = user32.NewProc("DestroyWindow")
	pGetWindowRect                 = user32.NewProc("GetWindowRect")
	pIsZoomed                      = user32.NewProc("IsZoomed")
	pIsIconic                      = user32.NewProc("IsIconic")
	pSetWindowLongPtrW             = user32.NewProc("SetWindowLongPtrW")
	pCallWindowProcW               = user32.NewProc("CallWindowProcW")
	pSendMessageW                  = user32.NewProc("SendMessageW")
	pCreatePopupMenu               = user32.NewProc("CreatePopupMenu")
	pAppendMenuW                   = user32.NewProc("AppendMenuW")
	pTrackPopupMenu                = user32.NewProc("TrackPopupMenu")
	pDestroyMenu                   = user32.NewProc("DestroyMenu")
	pGetCursorPos                  = user32.NewProc("GetCursorPos")
	pMessageBoxW                   = user32.NewProc("MessageBoxW")
	pFindWindowW                   = user32.NewProc("FindWindowW")
	pGetWindowThreadProcessID      = user32.NewProc("GetWindowThreadProcessId")
	pRegisterWindowMessageW        = user32.NewProc("RegisterWindowMessageW")
	pSetProcessDpiAwarenessContext = user32.NewProc("SetProcessDpiAwarenessContext")
	pCreateIconIndirect            = user32.NewProc("CreateIconIndirect")
	pGetSystemMetrics              = user32.NewProc("GetSystemMetrics")
	pGetSystemMetricsForDpi        = user32.NewProc("GetSystemMetricsForDpi") // Windows 10 1607 and later
	pGetDpiForWindow               = user32.NewProc("GetDpiForWindow")        // Windows 10 1607 and later
	pDestroyIcon                   = user32.NewProc("DestroyIcon")
	pShellNotifyIconW              = shell32.NewProc("Shell_NotifyIconW")
	pShellExecuteW                 = shell32.NewProc("ShellExecuteW")
	pCreateDIBSection              = gdi32.NewProc("CreateDIBSection")
	pCreateBitmap                  = gdi32.NewProc("CreateBitmap")
	pDeleteObject                  = gdi32.NewProc("DeleteObject")
	pAttachConsole                 = kernel32.NewProc("AttachConsole")
)

const (
	wmDestroy       = 0x0002
	wmEndSession    = 0x0016
	wmExitSizeMove  = 0x0232
	wmDpiChanged    = 0x02E0
	wmClose         = 0x0010
	wmSetIcon       = 0x0080
	wmContextMenu   = 0x007B
	wmCommand       = 0x0111
	wmLButtonUp     = 0x0202
	wmLButtonDblClk = 0x0203
	wmRButtonUp     = 0x0205
	wmApp           = 0x8000
	// the app's own messages; WM_APP itself is go-webview2's dispatch queue, never used here
	wmTray      = wmApp + 1 // the tray icon's callback
	wmShow      = wmApp + 2 // another launch asks for the window
	wmServe     = wmApp + 3 // the serve is ready (or failed)
	wmQuit      = wmApp + 4 // pgvigil-app -quit
	wmUpdate    = wmApp + 5 // the update check found a newer release
	wmServeGone = wmApp + 6 // a serve this app started has exited

	ninBalloonUserClick = 0x0405

	swHide     = 0
	swShow     = 5
	swMaximize = 3
	swRestore  = 9

	nimAdd        = 0
	nimModify     = 1
	nimDelete     = 2
	nimSetVersion = 4
	nifMessage    = 0x1
	nifIcon       = 0x2
	nifTip        = 0x4
	nifInfo       = 0x10
	nifShowTip    = 0x80
	niifInfo      = 0x1

	mfString    = 0x0
	mfGrayed    = 0x1
	mfChecked   = 0x8
	mfSeparator = 0x800
	tpmRetCmd   = 0x100
	tpmRightBtn = 0x2

	mbOK          = 0x0
	mbIconError   = 0x10
	mbIconWarning = 0x30

	gwlpWndProc = ^uintptr(3) // -4
)

type wndClassEx struct {
	cbSize        uint32
	style         uint32
	lpfnWndProc   uintptr
	cbClsExtra    int32
	cbWndExtra    int32
	hInstance     uintptr
	hIcon         uintptr
	hCursor       uintptr
	hbrBackground uintptr
	lpszMenuName  *uint16
	lpszClassName *uint16
	hIconSm       uintptr
}

type point struct{ x, y int32 }

type msg struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	pt      point
	private uint32
}

type rect struct{ left, top, right, bottom int32 }

type notifyIconData struct {
	cbSize           uint32
	hWnd             uintptr
	uID              uint32
	uFlags           uint32
	uCallbackMessage uint32
	hIcon            uintptr
	szTip            [128]uint16
	dwState          uint32
	dwStateMask      uint32
	szInfo           [256]uint16
	uVersion         uint32
	szInfoTitle      [64]uint16
	dwInfoFlags      uint32
	guidItem         windows.GUID
	hBalloonIcon     uintptr
}

type iconInfo struct {
	fIcon    int32
	xHotspot uint32
	yHotspot uint32
	hbmMask  uintptr
	hbmColor uintptr
}

type bitmapInfoHeader struct {
	biSize          uint32
	biWidth         int32
	biHeight        int32
	biPlanes        uint16
	biBitCount      uint16
	biCompression   uint32
	biSizeImage     uint32
	biXPelsPerMeter int32
	biYPelsPerMeter int32
	biClrUsed       uint32
	biClrImportant  uint32
}

func u16(s string) *uint16 { p, _ := windows.UTF16PtrFromString(s); return p }

func copyU16(dst []uint16, s string) {
	w, _ := windows.UTF16FromString(s)
	if len(w) > len(dst) {
		w = w[:len(dst)]
		w[len(w)-1] = 0
	}
	copy(dst, w)
}

func messageBox(text string, flags uintptr) {
	_, _, _ = pMessageBoxW.Call(0, uintptr(unsafe.Pointer(u16(text))), uintptr(unsafe.Pointer(u16("pgvigil"))), flags)
}

// openExternal opens an http(s) URL in the default browser (the release page, the UI as a fallback).
func openExternal(u string) {
	_, _, _ = pShellExecuteW.Call(0, uintptr(unsafe.Pointer(u16("open"))), uintptr(unsafe.Pointer(u16(u))), 0, 0, swShow)
}

// attachConsole gives a subcommand (install, -check) its parent's console: the app is a GUI program,
// which has none. Under a pipe (SSH, a captured run) the handles are already there.
func attachConsole() {
	if h, err := windows.GetStdHandle(windows.STD_OUTPUT_HANDLE); err == nil && h != 0 && h != windows.InvalidHandle {
		return
	}
	if r, _, _ := pAttachConsole.Call(uintptr(^uint32(0))); r == 0 {
		return
	}
	if f, err := os.OpenFile("CONOUT$", os.O_WRONLY, 0); err == nil {
		os.Stdout, os.Stderr = f, f
	}
}

// makeIcon draws the app's icon (mark E, iconPixel) at n x n pixels for the tray and the window: no resource file,
// no image decoder.
func makeIcon(n int) uintptr {
	if n < 16 {
		n = 16
	}
	bi := bitmapInfoHeader{biWidth: int32(n), biHeight: -int32(n), biPlanes: 1, biBitCount: 32}
	bi.biSize = uint32(unsafe.Sizeof(bi))
	var bits unsafe.Pointer
	color, _, _ := pCreateDIBSection.Call(0, uintptr(unsafe.Pointer(&bi)), 0, uintptr(unsafe.Pointer(&bits)), 0, 0)
	if color == 0 || bits == nil {
		return 0
	}
	px := unsafe.Slice((*uint32)(bits), n*n)
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			px[y*n+x] = iconPixel(x, y, n)
		}
	}
	mask, _, _ := pCreateBitmap.Call(uintptr(n), uintptr(n), 1, 1, 0)
	ii := iconInfo{fIcon: 1, hbmMask: mask, hbmColor: color}
	h, _, _ := pCreateIconIndirect.Call(uintptr(unsafe.Pointer(&ii)))
	_, _, _ = pDeleteObject.Call(color)
	_, _, _ = pDeleteObject.Call(mask)
	return h
}
