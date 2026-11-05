// +build !aix,!android,!darwin,!dragonfly,!freebsd,!linux,!netbsd,!openbsd,!solaris

package main

import "os"

// openSelectedFile opens a file that the walk selected. On these platforms the
// walk does not meet FIFOs or devices in place of regular files, and
// checkOpenedFile still requires a regular file within the size limit.
func openSelectedFile(path string) (*os.File, error) {
	return os.Open(path)
}

// sameFile does not compare identities here: the check is made on Unix, where
// FIFOs, devices and symbolic links can take the place of a selected file.
func sameFile(walked os.FileInfo, opened os.FileInfo) bool {
	return true
}
