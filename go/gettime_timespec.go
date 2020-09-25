//+build darwin freebsd netbsd

package main

import (
	"os"
	"syscall"
	"time"
)

func getTimes(info os.FileInfo) []time.Time {
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		mtime := time.Unix(int64(stat.Mtimespec.Sec), int64(stat.Mtimespec.Nsec))
		ctime := time.Unix(int64(stat.Ctimespec.Sec), int64(stat.Ctimespec.Nsec))
		btime := time.Unix(int64(stat.Birthtimespec.Sec), int64(stat.Birthtimespec.Nsec))
		return []time.Time{mtime, ctime, btime}
	} else {
		return []time.Time{info.ModTime()}
	}
}
