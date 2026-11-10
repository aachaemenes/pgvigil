//go:build windows

package main

import (
	"fmt"
	"os/exec"
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
