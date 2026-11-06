// +build !plan9

package main

import (
	"os"
	"syscall"
)

// interruptSignals end a run with an interrupted collection marker.
var interruptSignals = []os.Signal{os.Interrupt, syscall.SIGTERM}
