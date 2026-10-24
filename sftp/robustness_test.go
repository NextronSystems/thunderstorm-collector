package main

import (
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// newTestCollector serves the local filesystem over SFTP and sends uploads to
// handler through the collector's own HTTP client. Retries do not sleep.
func newTestCollector(t *testing.T, settings Settings, handler http.Handler) *Collector {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	settings.UploadURL = server.URL + "/api/checkAsync?source=test"
	if settings.MaxFileSize == 0 {
		settings.MaxFileSize = 64 << 20
	}
	if settings.Threads == 0 {
		settings.Threads = 2
	}
	if settings.WalkThreads == 0 {
		settings.WalkThreads = 2
	}
	client, err := newHTTPClient(Config{}, settings.ResponseTimeout)
	if err != nil {
		t.Fatal(err)
	}
	collector := NewCollector(settings, sftpClientFor(t), client, log.New(io.Discard, "", 0), nil)
	collector.retrySleep = func(time.Duration) {}
	return collector
}

// runWithin fails the test if the run does not finish in time.
func runWithin(t *testing.T, collector *Collector, limit time.Duration) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		collector.Run()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(limit):
		t.Fatalf("the run did not finish within %v", limit)
	}
}

func uploadedPaths(samples []receivedSample) []string {
	var paths []string
	for _, sample := range samples {
		paths = append(paths, sample.path)
	}
	return paths
}

func TestRootsFollowTheEntryRules(t *testing.T) {
	root := sourceTree(t)
	other := t.TempDir()
	link := filepath.Join(other, "link-to-www")
	if err := os.Symlink(filepath.Join(root, "www"), link); err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(other, "fifo")
	if err := syscall.Mkfifo(fifo, 0o644); err != nil {
		t.Fatal(err)
	}
	handler, received := uploadRecorder()
	implant := filepath.Join(root, "tmp", "implant")
	collector := newTestCollector(t, Settings{
		RootPaths:    []string{filepath.Join(root, "www"), link, fifo, implant},
		ExcludeGlobs: []string{filepath.Join(root, "www")},
	}, handler)
	// Opening the FIFO would block the run.
	runWithin(t, collector, 10*time.Second)

	if got := uploadedPaths(received()); !reflect.DeepEqual(got, []string{implant}) {
		t.Errorf("uploads = %v, want only %s", got, implant)
	}
	stats := collector.Stats
	if stats.Excluded != 1 || stats.Symlinks != 1 || stats.Irregular != 1 {
		t.Errorf("excluded %d, symlinks %d, irregular %d; want 1 each", stats.Excluded, stats.Symlinks, stats.Irregular)
	}
}

func TestOneWalkerListsADeepAndWideTree(t *testing.T) {
	root := t.TempDir()
	var want []string
	for i := 0; i < 12; i++ {
		directory := filepath.Join(root, "level"+strings.Repeat("/sub", i), "branch")
		for j := 0; j < 4; j++ {
			name := filepath.Join(directory+string(rune('a'+j)), "file.txt")
			want = append(want, writeFile(t, name, name, 0o644, time.Now()))
		}
	}
	handler, received := uploadRecorder()
	collector := newTestCollector(t, Settings{RootPaths: []string{root}, Threads: 1, WalkThreads: 1}, handler)
	runWithin(t, collector, 30*time.Second)
	if got := len(received()); got != len(want) {
		t.Errorf("uploaded %d files, want %d", got, len(want))
	}
}

func TestHeaderReadErrorIsAFileError(t *testing.T) {
	root := t.TempDir()
	directory := filepath.Join(root, "not-a-file")
	if err := os.Mkdir(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	short := writeFile(t, filepath.Join(root, "short"), "MZ", 0o644, time.Now())
	handler, _ := uploadRecorder()
	collector := newTestCollector(t, Settings{RootPaths: []string{root}, MagicHeaders: [][]byte{[]byte("\x7fELF")}}, handler)

	info, err := os.Stat(directory)
	if err != nil {
		t.Fatal(err)
	}
	// Opening a directory works, reading it fails: a failed read, not a
	// nonmatching header.
	collector.process(candidate{path: directory, info: info})
	if collector.Stats.FileErrors != 1 || collector.Stats.WrongType != 0 {
		t.Errorf("unreadable header: file errors %d, wrong type %d; want 1 and 0", collector.Stats.FileErrors, collector.Stats.WrongType)
	}

	// A file shorter than the header is a normal mismatch.
	info, err = os.Stat(short)
	if err != nil {
		t.Fatal(err)
	}
	collector.process(candidate{path: short, info: info})
	if collector.Stats.FileErrors != 1 || collector.Stats.WrongType != 1 {
		t.Errorf("short file: file errors %d, wrong type %d; want 1 and 1", collector.Stats.FileErrors, collector.Stats.WrongType)
	}
}

func TestAnswerBeforeTheUploadEndsIsAFailure(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "large.bin"), string(make([]byte, 8<<20)), 0o644, time.Now())
	var requests int32
	// Answers 200 without reading the sample.
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&requests, 1)
		w.Write([]byte(`{"id": 1}`))
	})
	collector := newTestCollector(t, Settings{RootPaths: []string{root}}, handler)
	runWithin(t, collector, 30*time.Second)
	if collector.Stats.Uploaded != 0 || collector.Stats.UploadErrors != 1 {
		t.Errorf("uploaded %d, upload errors %d; want 0 and 1", collector.Stats.Uploaded, collector.Stats.UploadErrors)
	}
	if got := atomic.LoadInt32(&requests); got != maxRetries+1 {
		t.Errorf("%d requests, want %d (the first try and every retry)", got, maxRetries+1)
	}
}

func TestOversizedAnswerIsAPermanentFailure(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "sample.txt"), "sample", 0o644, time.Now())
	var requests int32
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&requests, 1)
		io.Copy(io.Discard, r.Body)
		w.Write(make([]byte, maxResponseBytes+1))
	})
	collector := newTestCollector(t, Settings{RootPaths: []string{root}}, handler)
	runWithin(t, collector, 30*time.Second)
	if collector.Stats.Uploaded != 0 || collector.Stats.UploadErrors != 1 {
		t.Errorf("uploaded %d, upload errors %d; want 0 and 1", collector.Stats.Uploaded, collector.Stats.UploadErrors)
	}
	if got := atomic.LoadInt32(&requests); got != 1 {
		t.Errorf("%d requests, want 1: an oversized answer is not retried", got)
	}
}

func TestSilentThunderstormTimesOut(t *testing.T) {
	for _, test := range []struct {
		name         string
		sendHeaders  bool
		wantRequests int32
	}{
		{"no response headers", false, maxRetries + 1},
		{"no response body", true, 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			writeFile(t, filepath.Join(root, "sample.txt"), "sample", 0o644, time.Now())
			var requests int32
			handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				atomic.AddInt32(&requests, 1)
				io.Copy(io.Discard, r.Body)
				if test.sendHeaders {
					w.WriteHeader(http.StatusOK)
					w.(http.Flusher).Flush()
				}
				time.Sleep(time.Second)
			})
			collector := newTestCollector(t, Settings{RootPaths: []string{root}, ResponseTimeout: 100 * time.Millisecond}, handler)
			runWithin(t, collector, 30*time.Second)
			if collector.Stats.Uploaded != 0 || collector.Stats.UploadErrors != 1 {
				t.Errorf("uploaded %d, upload errors %d; want 0 and 1", collector.Stats.Uploaded, collector.Stats.UploadErrors)
			}
			if got := atomic.LoadInt32(&requests); got != test.wantRequests {
				t.Errorf("%d requests, want %d", got, test.wantRequests)
			}
		})
	}
}
