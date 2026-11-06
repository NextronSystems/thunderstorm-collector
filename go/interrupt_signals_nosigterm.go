// +build plan9 nacl

package main

import "os"

// interruptSignals end a run with an interrupted collection marker. Plan 9 and
// Native Client (a Go 1.10 release target) have no SIGTERM.
var interruptSignals = []os.Signal{os.Interrupt}
