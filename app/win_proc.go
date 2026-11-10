//go:build windows

package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"net/url"
	"os/exec"
	"strconv"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

const createNoWindow = 0x08000000

// serveJob holds every serve this app starts: closing its last handle (the app's exit, a crash
// included) ends them, so a serve never outlives the app that started it.
var serveJob windows.Handle

func newServeJob() (windows.Handle, error) {
	j, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return 0, err
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(j, windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
		_ = windows.CloseHandle(j)
		return 0, err
	}
	return j, nil
}

// prepareServe: no console window for the serve.
func prepareServe(cmd *exec.Cmd) error {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	return nil
}

// adoptServe puts the started serve in the job.
func adoptServe(cmd *exec.Cmd) error {
	if serveJob == 0 {
		j, err := newServeJob()
		if err != nil {
			return fmt.Errorf("job object: %w", err)
		}
		serveJob = j
	}
	h, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(cmd.Process.Pid))
	if err != nil {
		return fmt.Errorf("open the serve process: %w", err)
	}
	defer func() { _ = windows.CloseHandle(h) }()
	if err := windows.AssignProcessToJobObject(serveJob, h); err != nil {
		return fmt.Errorf("job object: %w", err)
	}
	return nil
}

// processGone says whether pid no longer runs.
func processGone(pid int) bool {
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.SYNCHRONIZE, false, uint32(pid))
	if err != nil {
		return true
	}
	defer func() { _ = windows.CloseHandle(h) }()
	ev, err := windows.WaitForSingleObject(h, 0)
	return err == nil && ev == windows.WAIT_OBJECT_0
}

var (
	iphlpapi                 = windows.NewLazySystemDLL("iphlpapi.dll")
	pGetExtendedTCPTable     = iphlpapi.NewProc("GetExtendedTcpTable")
	errNoListener            = errors.New("no process listens there")
	tcpTableOwnerPIDListener = 3
)

// listenerOwnedByMe says whether the process that listens on the loopback port of base runs as the
// signed-in user: on a shared host the app never shows (or types a password into) another user's
// serve, or a process that only answers like one.
func listenerOwnedByMe(base string) (bool, error) {
	u, err := url.Parse(base)
	if err != nil {
		return false, err
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil {
		return false, fmt.Errorf("attach address %s has no port", base)
	}
	pid, err := listenerPid(uint16(port), u.Hostname() == "::1")
	if err != nil {
		return false, err
	}
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return false, nil // another user's process (or a protected one): not ours
	}
	defer func() { _ = windows.CloseHandle(h) }()
	var tok windows.Token
	if err := windows.OpenProcessToken(h, windows.TOKEN_QUERY, &tok); err != nil {
		return false, nil
	}
	defer func() { _ = tok.Close() }()
	theirs, err := tok.GetTokenUser()
	if err != nil {
		return false, nil
	}
	mine, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return false, err
	}
	return windows.EqualSid(theirs.User.Sid, mine.User.Sid), nil
}

// listenerPid finds the pid that listens on the port (IPv4 loopback or any, or IPv6 with v6).
func listenerPid(port uint16, v6 bool) (uint32, error) {
	af := uint32(windows.AF_INET)
	rowSize := 24 // MIB_TCPROW_OWNER_PID: state, local addr, local port, remote addr, remote port, pid
	portAt := 8
	if v6 {
		af = windows.AF_INET6
		rowSize = 56 // MIB_TCP6ROW_OWNER_PID: local addr[16], scope, port, remote addr[16], scope, port, state, pid
		portAt = 20
	}
	var size uint32
	_, _, _ = pGetExtendedTCPTable.Call(0, uintptr(unsafe.Pointer(&size)), 0, uintptr(af), uintptr(tcpTableOwnerPIDListener), 0)
	if size == 0 {
		return 0, errors.New("GetExtendedTcpTable: no size")
	}
	buf := make([]byte, size+1024)
	size = uint32(len(buf))
	if r, _, _ := pGetExtendedTCPTable.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&size)), 0, uintptr(af), uintptr(tcpTableOwnerPIDListener), 0); r != 0 {
		return 0, fmt.Errorf("GetExtendedTcpTable: %d", r)
	}
	n := binary.LittleEndian.Uint32(buf[0:4])
	for i := uint32(0); i < n; i++ {
		row := buf[4+int(i)*rowSize : 4+int(i+1)*rowSize]
		// the port is in network byte order in the low two bytes of its DWORD
		p := uint16(row[portAt])<<8 | uint16(row[portAt+1])
		if p == port {
			return binary.LittleEndian.Uint32(row[rowSize-4:]), nil
		}
	}
	return 0, errNoListener
}
