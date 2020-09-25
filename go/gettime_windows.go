package main

import (
	"os"
	"syscall"
	"time"
)

func getTimes(info os.FileInfo) []time.Time {
	stat := info.Sys().(*syscall.Win32FileAttributeData)
	return []time.Time{info.ModTime(), time.Unix(0, int64(stat.CreationTime.Nanoseconds()))}
}
