//go:build js || nacl
// +build js nacl

package main

import (
	"os"
	"syscall"
	"time"
)

func getTimes(info os.FileInfo) []time.Time {
	stat := info.Sys().(*syscall.Stat_t)
	mtime := time.Unix(stat.Mtime, stat.MtimeNsec)
	ctime := time.Unix(stat.Ctime, stat.CtimeNsec)
	return []time.Time{mtime, ctime}
}
