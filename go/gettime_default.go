//go:build !(aix || android || dragonfly || illumos || linux || solaris || openbsd || js || nacl || darwin || freebsd || netbsd || windows)
// +build !aix,!android,!dragonfly,!illumos,!linux,!solaris,!openbsd,!js,!nacl,!darwin,!freebsd,!netbsd,!windows

package main

import (
	"os"
	"time"
)

func getTimes(info os.FileInfo) []time.Time {
	return []time.Time{info.ModTime()}
}
