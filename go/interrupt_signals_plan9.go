// +build plan9

package main

import "os"

// interruptSignals end a run with an interrupted collection marker. Plan 9 has
// no SIGTERM.
var interruptSignals = []os.Signal{os.Interrupt}
