//go:build aix || android || dragonfly || illumos || linux || solaris || openbsd
// +build aix android dragonfly illumos linux solaris openbsd

package main

import (
	"os"
	"syscall"
	"time"
)

func getTimes(info os.FileInfo) []time.Time {
	stat := info.Sys().(*syscall.Stat_t)
	mtime := time.Unix(int64(stat.Mtim.Sec), int64(stat.Mtim.Nsec))
	ctime := time.Unix(int64(stat.Ctim.Sec), int64(stat.Ctim.Nsec))
	return []time.Time{mtime, ctime}
}
