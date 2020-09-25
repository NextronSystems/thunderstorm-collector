//+build plan9

package main

import (
	"os"
	"time"
)

func getTimes(info os.FileInfo) []time.Time {
	return []time.Time{info.ModTime()}
}
