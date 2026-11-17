// +build darwin dragonfly freebsd linux netbsd openbsd

package main

import (
	"bytes"
	"io"
	"io/ioutil"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// A selected file can be replaced between the walk and the upload. A FIFO in
// its place must not block the worker, and a symbolic link or another file must
// not be sent in its place.
func TestReplacedSelectedFileIsNotSent(t *testing.T) {
	for _, test := range []struct {
		name    string
		replace func(t *testing.T, path string, dir string)
	}{
		{"fifo", func(t *testing.T, path string, dir string) {
			if err := syscall.Mkfifo(path, 0600); err != nil {
				t.Skipf("mkfifo: %v", err)
			}
		}},
		{"symlink", func(t *testing.T, path string, dir string) {
			target := filepath.Join(dir, "target")
			if err := ioutil.WriteFile(target, []byte("other"), 0600); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, path); err != nil {
				t.Fatal(err)
			}
		}},
		{"other file", func(t *testing.T, path string, dir string) {
			if err := ioutil.WriteFile(path, []byte("other"), 0600); err != nil {
				t.Fatal(err)
			}
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir, err := ioutil.TempDir("", "collector-replaced-")
			if err != nil {
				t.Fatal(err)
			}
			defer os.RemoveAll(dir)
			path := filepath.Join(dir, "sample.bin")
			if err := ioutil.WriteFile(path, []byte("sample"), 0600); err != nil {
				t.Fatal(err)
			}
			info, err := os.Lstat(path)
			if err != nil {
				t.Fatal(err)
			}
			// Keep the original inode alive so that a new file cannot reuse it.
			keep := path + ".orig"
			if err := os.Rename(path, keep); err != nil {
				t.Fatal(err)
			}
			test.replace(t, path, dir)
			c := NewCollector(CollectorConfig{Server: "http://127.0.0.1:1", Threads: 1}, log.New(ioutil.Discard, "", 0))
			selected := infoWithPath{FileInfo: info, path: path}

			finishesWithin(t, 5e9, "the upload", func() { c.uploadToThunderstorm(&selected) })

			if got := c.Statistics.fileErrors; got != 1 {
				t.Fatalf("expected one file error, got %d", got)
			}
			if got := c.Statistics.uploadErrors; got != 0 {
				t.Fatalf("the replaced file reached the upload (%d upload errors)", got)
			}
		})
	}
}

// fileIsOpen reports whether this process holds an open descriptor for path.
func fileIsOpen(t *testing.T, path string) bool {
	t.Helper()
	var want syscall.Stat_t
	if err := syscall.Stat(path, &want); err != nil {
		t.Fatal(err)
	}
	for fd := 0; fd < 1024; fd++ {
		var got syscall.Stat_t
		if err := syscall.Fstat(fd, &got); err != nil {
			continue
		}
		if uint64(got.Dev) == uint64(want.Dev) && uint64(got.Ino) == uint64(want.Ino) {
			return true
		}
	}
	return false
}

// A worker kept the file open while it waited before a retry, for up to two
// minutes per HTTP 503. On Windows the owner of the file cannot delete or
// rename it meanwhile.
func TestFileIsClosedWhileWaitingForARetry(t *testing.T) {
	var requests int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(ioutil.Discard, r.Body)
		if atomic.AddInt32(&requests, 1) == 1 {
			w.Header().Set("Retry-After", "7")
			http.Error(w, "busy", http.StatusServiceUnavailable)
			return
		}
		w.Write([]byte("{}"))
	}))
	defer server.Close()
	name, stat := newTestFile(t, "sample")
	defer os.Remove(name)

	held, err := os.Open(name)
	if err != nil {
		t.Fatal(err)
	}
	if !fileIsOpen(t, name) {
		t.Fatal("fileIsOpen does not see a file that is open")
	}
	held.Close()

	c := NewCollector(CollectorConfig{Server: server.URL, Threads: 1, MagicHeaders: [][]byte{[]byte("sa")}}, log.New(ioutil.Discard, "", 0))
	var waits []time.Duration
	c.retrySleep = func(delay time.Duration) {
		waits = append(waits, delay)
		if fileIsOpen(t, name) {
			t.Error("the file is still open while the worker waits before the retry")
		}
	}
	info := infoWithPath{FileInfo: stat, path: name}
	for c.uploadToThunderstorm(&info) {
	}
	if len(waits) != 1 || waits[0] != 7*time.Second {
		t.Errorf("expected one wait of 7s, got %v", waits)
	}
	if got := atomic.LoadInt64(&c.Statistics.uploadedFiles); got != 1 {
		t.Errorf("expected the retry to upload the file, got %d uploads", got)
	}
}

// filepath.Walk does not follow a symbolic link, also not as scan root: /tmp or
// /var on macOS were reported as one irregular file, with exit status 0.
func TestSymlinkedScanRootIsWalked(t *testing.T) {
	parent := tempDirectory(t)
	defer os.RemoveAll(parent)
	target := filepath.Join(parent, "target")
	if err := os.MkdirAll(filepath.Join(target, "sub"), 0755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"a.bin", filepath.Join("sub", "b.bin")} {
		if err := ioutil.WriteFile(filepath.Join(target, name), []byte("sample"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	// A link below the root is still not followed.
	if err := os.Symlink(target, filepath.Join(target, "sub", "loop")); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(parent, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}

	c, output := dryRunCollector(link)
	c.StartWorkers()
	c.Collect()
	c.Stop()
	if got := atomic.LoadInt64(&c.Statistics.uploadedFiles); got != 2 {
		t.Errorf("expected the 2 files below the link target, got %d: %s", got, output.String())
	}
	if got := c.Statistics.getSkipCount(SkipReasonIrregular); got != 1 {
		t.Errorf("expected the link below the root to be skipped as irregular, got %d", got)
	}
	if !strings.Contains(output.String(), "is a symbolic link, walking its target") {
		t.Errorf("log does not say that the root was resolved: %s", output.String())
	}
	if got := c.Statistics.ErrorCount(); got != 0 {
		t.Errorf("expected no errors, got %d", got)
	}
}

func TestDanglingSymlinkAsScanRootIsAnError(t *testing.T) {
	parent := tempDirectory(t)
	defer os.RemoveAll(parent)
	link := filepath.Join(parent, "link")
	if err := os.Symlink(filepath.Join(parent, "missing"), link); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	c := NewCollector(CollectorConfig{RootPaths: []string{link}, DryRun: true, Threads: 1}, log.New(&output, "", 0))
	c.StartWorkers()
	c.Collect()
	c.Stop()
	if got := atomic.LoadInt64(&c.Statistics.rootErrors); got != 1 {
		t.Errorf("expected one root error, got %d: %s", got, output.String())
	}
	if !strings.Contains(output.String(), "Could not read scan root") {
		t.Errorf("log does not mention the scan root: %s", output.String())
	}
}
