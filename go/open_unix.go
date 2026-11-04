// +build aix android darwin dragonfly freebsd linux netbsd openbsd solaris

package main

import (
	"os"
	"syscall"
)

// openSelectedFile opens a file that the walk selected. Between the walk and
// the upload the path can be replaced; O_NOFOLLOW refuses a symbolic link put in
// its place and O_NONBLOCK keeps the open of a FIFO or device from blocking, so
// that checkOpenedFile can reject them before anything is read.
func openSelectedFile(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
}

// sameFile reports whether the opened file is the one the walk saw.
func sameFile(walked os.FileInfo, opened os.FileInfo) bool {
	return os.SameFile(walked, opened)
}
