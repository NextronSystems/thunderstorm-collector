package main

import (
	"io"
	"sync"
	"sync/atomic"
	"time"
)

// sftpWatchdog ends a run that waits on the source forever. The SSH and SFTP
// libraries put no deadline on a request: OpenSSH's sftp-server answers one
// request at a time, so a single READDIR or READ that hangs (a dead NFS mount on
// the source, a pseudo file that blocks) stops every walker and worker. The
// collector marks each SFTP call with begin and end; when a call is pending and
// the source has sent nothing for timeout, the watchdog calls onStall, which
// closes the connection so that every pending call fails.
type sftpWatchdog struct {
	// lastProgress is the UnixNano time of the last data from the source or of
	// the start of a call after an idle period. Accessed atomically.
	lastProgress int64
	active       int64
	timeout      time.Duration
	onStall      func()
	fired        int32
	stop         chan struct{}
	stopOnce     sync.Once
}

func newSFTPWatchdog(timeout time.Duration, onStall func()) *sftpWatchdog {
	w := &sftpWatchdog{timeout: timeout, onStall: onStall, stop: make(chan struct{})}
	atomic.StoreInt64(&w.lastProgress, time.Now().UnixNano())
	go w.run()
	return w
}

// reader wraps the stream that carries the source's SFTP answers.
func (w *sftpWatchdog) reader(r io.Reader) io.Reader {
	return &progressReader{reader: r, watchdog: w}
}

type progressReader struct {
	reader   io.Reader
	watchdog *sftpWatchdog
}

func (r *progressReader) Read(p []byte) (int, error) {
	n, err := r.reader.Read(p)
	if n > 0 {
		atomic.StoreInt64(&r.watchdog.lastProgress, time.Now().UnixNano())
	}
	return n, err
}

// begin marks the start of an SFTP call; a nil watchdog does nothing.
func (w *sftpWatchdog) begin() {
	if w == nil {
		return
	}
	if atomic.AddInt64(&w.active, 1) == 1 {
		atomic.StoreInt64(&w.lastProgress, time.Now().UnixNano())
	}
}

func (w *sftpWatchdog) end() {
	if w == nil {
		return
	}
	atomic.AddInt64(&w.active, -1)
}

// Fired reports whether the watchdog closed the connection.
func (w *sftpWatchdog) Fired() bool {
	return w != nil && atomic.LoadInt32(&w.fired) == 1
}

func (w *sftpWatchdog) Stop() {
	if w == nil {
		return
	}
	w.stopOnce.Do(func() { close(w.stop) })
}

func (w *sftpWatchdog) run() {
	interval := w.timeout / 10
	if interval < 50*time.Millisecond {
		interval = 50 * time.Millisecond
	}
	if interval > 5*time.Second {
		interval = 5 * time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-w.stop:
			return
		case <-ticker.C:
			idle := time.Since(time.Unix(0, atomic.LoadInt64(&w.lastProgress)))
			if atomic.LoadInt64(&w.active) > 0 && idle > w.timeout {
				atomic.StoreInt32(&w.fired, 1)
				w.onStall()
				return
			}
		}
	}
}
