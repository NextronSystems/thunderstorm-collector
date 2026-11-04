package main

import (
	"bytes"
	"io"
	"io/ioutil"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Regression tests: a server that stops answering or reading must not hang the
// collector, a file must not be sent beyond what was checked, and a server that
// goes away must not make every remaining file run through its retries.

// silentServer accepts connections and never answers. With read set it drains
// what the client sends, otherwise it never reads either.
func silentServer(t *testing.T, read bool) (string, func()) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mutex sync.Mutex
	var conns []net.Conn
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			mutex.Lock()
			conns = append(conns, conn)
			mutex.Unlock()
			if read {
				go io.Copy(ioutil.Discard, conn)
			}
		}
	}()
	return "http://" + listener.Addr().String(), func() {
		listener.Close()
		mutex.Lock()
		for _, conn := range conns {
			conn.Close()
		}
		mutex.Unlock()
	}
}

// finishesWithin runs f and fails the test if it does not return within limit.
func finishesWithin(t *testing.T, limit time.Duration, what string, f func()) {
	done := make(chan struct{})
	go func() {
		f()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(limit):
		t.Fatalf("%s did not finish within %v", what, limit)
	}
}

func TestStatusCheckDoesNotWaitForeverForAnAnswer(t *testing.T) {
	server, stop := silentServer(t, true)
	defer stop()
	c := NewCollector(CollectorConfig{Server: server, Threads: 1, ResponseTimeout: 200 * time.Millisecond}, log.New(ioutil.Discard, "", 0))

	var err error
	finishesWithin(t, 10*time.Second, "the status check", func() { err = c.CheckThunderstormUp() })

	if err == nil || !strings.Contains(err.Error(), "no answer from Thunderstorm") {
		t.Fatalf("expected a response timeout from the status check, got %v", err)
	}
}

func TestUploadDoesNotWaitForeverForAnAnswer(t *testing.T) {
	server, stop := silentServer(t, true)
	defer stop()
	name, stat := newTestFile(t, "sample")
	defer os.Remove(name)
	var output bytes.Buffer
	c := NewCollector(CollectorConfig{Server: server, Threads: 1, ResponseTimeout: 200 * time.Millisecond, ServerWait: time.Hour}, log.New(&output, "", 0))
	c.retrySleep = func(time.Duration) {}
	info := infoWithPath{FileInfo: stat, path: name}

	finishesWithin(t, 20*time.Second, "the upload", func() {
		for c.uploadToThunderstorm(&info) {
		}
	})

	if got := atomic.LoadInt64(&c.Statistics.uploadErrors); got != 1 {
		t.Fatalf("expected one upload error, got %d; log:\n%s", got, output.String())
	}
	if !strings.Contains(output.String(), "no answer from Thunderstorm") {
		t.Errorf("log does not name the missing answer:\n%s", output.String())
	}
}

func TestUploadToServerThatStopsReadingIsBounded(t *testing.T) {
	saved := writeStallTimeout
	writeStallTimeout = 200 * time.Millisecond
	defer func() { writeStallTimeout = saved }()
	server, stop := silentServer(t, false)
	defer stop()
	// Larger than the socket buffers of both ends, so the writes have to stall.
	name, stat := newTestFile(t, strings.Repeat("x", 32*1024*1024))
	defer os.Remove(name)
	c := NewCollector(CollectorConfig{Server: server, Threads: 1, MaxFileSize: 64 * 1024 * 1024, ServerWait: time.Hour}, log.New(ioutil.Discard, "", 0))
	transport := buildHttpTransport(Config{Threads: 1})
	defer transport.CloseIdleConnections()
	c.client = &http.Client{Transport: transport, CheckRedirect: refuseRedirects}
	c.retrySleep = func(time.Duration) {}
	info := infoWithPath{FileInfo: stat, path: name}

	finishesWithin(t, 30*time.Second, "the upload", func() {
		for c.uploadToThunderstorm(&info) {
		}
	})

	if got := atomic.LoadInt64(&c.Statistics.uploadErrors); got != 1 {
		t.Fatalf("expected one upload error, got %d", got)
	}
}

func TestOversizedResponseIsRejected(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		chunk := make([]byte, 1024*1024)
		for i := 0; i <= maxResponseBytes/len(chunk); i++ {
			if _, err := w.Write(chunk); err != nil {
				return
			}
		}
	}))
	defer server.Close()
	c := NewCollector(CollectorConfig{Server: server.URL, Threads: 1}, log.New(ioutil.Discard, "", 0))

	err := c.CheckThunderstormUp()

	if err == nil || !strings.Contains(err.Error(), "larger than") {
		t.Fatalf("expected an error for the oversized status response, got %v", err)
	}
}

// countingServer accepts uploads and records the received file sizes.
func countingServer(sizes *[]int, mutex *sync.Mutex) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/status" {
			return
		}
		reader, err := r.MultipartReader()
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		part, err := reader.NextPart()
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		content, _ := ioutil.ReadAll(part)
		mutex.Lock()
		*sizes = append(*sizes, len(content))
		mutex.Unlock()
	}))
}

func TestFileThatGrewPastTheLimitAfterTheWalkIsNotSent(t *testing.T) {
	var sizes []int
	var mutex sync.Mutex
	server := countingServer(&sizes, &mutex)
	defer server.Close()
	name, stat := newTestFile(t, strings.Repeat("a", 10))
	defer os.Remove(name)
	appendTo(t, name, strings.Repeat("b", 20))
	c := NewCollector(CollectorConfig{Server: server.URL, Threads: 1, MaxFileSize: 20}, log.New(ioutil.Discard, "", 0))
	info := infoWithPath{FileInfo: stat, path: name}

	if redo := c.uploadToThunderstorm(&info); redo {
		t.Fatal("unexpected retry")
	}

	if len(sizes) != 0 {
		t.Fatalf("a file over the size limit was sent: %v", sizes)
	}
	if got := c.Statistics.getSkipCount(SkipReasonTooBig); got != 1 {
		t.Fatalf("expected the file to be skipped as too big, got %d", got)
	}
	if got := c.Statistics.ErrorCount(); got != 0 {
		t.Fatalf("expected no error, got %d", got)
	}
}

func TestFileThatShrankWhileBeingSentIsAFileError(t *testing.T) {
	name, _ := newTestFile(t, "0123456789")
	defer os.Remove(name)
	f, err := os.Open(name)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	c := NewCollector(CollectorConfig{Threads: 1}, log.New(ioutil.Discard, "", 0))

	// The size checked after opening was 20 bytes; only 10 are left to read.
	_, body, readError := c.getFileContentAsFormData(f, name, 20)
	_, copyErr := ioutil.ReadAll(body)

	if copyErr == nil || readError.get() == nil || !strings.Contains(readError.get().Error(), "shrank") {
		t.Fatalf("expected a shrink error, got body error %v and file error %v", copyErr, readError.get())
	}
}

func TestVanishedFileIsNotAnError(t *testing.T) {
	name, stat := newTestFile(t, "sample")
	os.Remove(name)
	c := NewCollector(CollectorConfig{Server: "http://127.0.0.1:1", Threads: 1}, log.New(ioutil.Discard, "", 0))
	info := infoWithPath{FileInfo: stat, path: name}

	c.uploadToThunderstorm(&info)

	if got := c.Statistics.ErrorCount(); got != 0 {
		t.Fatalf("a file that vanished before it was read counted as %d error(s)", got)
	}
}

func appendTo(t *testing.T, name string, content string) {
	f, err := os.OpenFile(name, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.Write([]byte(content)); err != nil {
		t.Fatal(err)
	}
}

// fakeClock advances only when the collector sleeps.
type fakeClock struct {
	mutex   sync.Mutex
	current time.Time
	slept   []time.Duration
	onSleep func(time.Duration)
}

func (f *fakeClock) now() time.Time {
	f.mutex.Lock()
	defer f.mutex.Unlock()
	return f.current
}

func (f *fakeClock) sleep(d time.Duration) {
	f.mutex.Lock()
	f.current = f.current.Add(d)
	f.slept = append(f.slept, d)
	onSleep := f.onSleep
	f.mutex.Unlock()
	if onSleep != nil {
		onSleep(d)
	}
}

func sampleTree(t *testing.T, count int) string {
	dir, err := ioutil.TempDir("", "collector-outage-")
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < count; i++ {
		if err := ioutil.WriteFile(filepath.Join(dir, string(rune('a'+i))+".bin"), []byte("sample"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestCollectionStopsWhenThunderstormStaysUnreachable(t *testing.T) {
	// A port that refuses connections.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := "http://" + listener.Addr().String()
	listener.Close()
	dir := sampleTree(t, 6)
	defer os.RemoveAll(dir)
	var output bytes.Buffer
	c := NewCollector(CollectorConfig{Server: server, RootPaths: []string{dir}, Threads: 1, ServerWait: 10 * time.Second}, log.New(&output, "", 0))
	clock := &fakeClock{current: time.Unix(0, 0)}
	c.now = clock.now
	c.retrySleep = clock.sleep

	finishesWithin(t, 60*time.Second, "the collection", func() {
		c.StartWorkers()
		c.Collect()
		c.Stop()
	})

	if !c.collectionStopped() {
		t.Fatalf("the collection did not stop; log:\n%s", output.String())
	}
	if got := atomic.LoadInt64(&c.Statistics.uploadErrors); got != outageThreshold {
		t.Errorf("expected %d upload errors before the stop, got %d", outageThreshold, got)
	}
	// The walker may already have queued the next file when the collection
	// stopped; that file is counted as not sent, and the walk ends after it.
	if got := atomic.LoadInt64(&c.Statistics.notSent); got > 1 {
		t.Errorf("expected at most the one queued file to be counted as not sent, got %d", got)
	}
	if got := atomic.LoadInt64(&c.Statistics.filesDiscovered); got > outageThreshold+1 {
		t.Errorf("the walk went on after the collection stopped: %d files discovered", got)
	}
	if got := atomic.LoadInt64(&c.Statistics.uploadedFiles); got != 0 {
		t.Errorf("expected no upload, got %d", got)
	}
	// 3 files x 3 retry delays, then status polls of 2, 4 and the remaining 4 s.
	var polls []time.Duration
	for _, d := range clock.slept[3*maxRetries:] {
		polls = append(polls, d)
	}
	if len(clock.slept) != 3*maxRetries+3 || polls[0] != 2*time.Second || polls[1] != 4*time.Second || polls[2] != 4*time.Second {
		t.Errorf("unexpected waits: %v", clock.slept)
	}
	for _, want := range []string{"did not accept 3 files in a row", "unreachable for 10s, stopping the collection", "Not sent"} {
		if !strings.Contains(output.String(), want) {
			t.Errorf("log lacks %q:\n%s", want, output.String())
		}
	}
}

func TestCollectionContinuesWhenThunderstormComesBack(t *testing.T) {
	var down int32 = 1
	var statusChecks int32
	var uploads int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/status" {
			if atomic.AddInt32(&statusChecks, 1) < 2 {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			atomic.StoreInt32(&down, 0)
			return
		}
		ioutil.ReadAll(r.Body)
		if atomic.LoadInt32(&down) == 1 {
			// Closing without an HTTP response is a transport error.
			conn, _, err := w.(http.Hijacker).Hijack()
			if err == nil {
				conn.Close()
			}
			return
		}
		atomic.AddInt32(&uploads, 1)
	}))
	defer server.Close()
	dir := sampleTree(t, 5)
	defer os.RemoveAll(dir)
	var output bytes.Buffer
	c := NewCollector(CollectorConfig{Server: server.URL, RootPaths: []string{dir}, Threads: 1, ServerWait: 10 * time.Minute}, log.New(&output, "", 0))
	clock := &fakeClock{current: time.Unix(0, 0)}
	c.now = clock.now
	c.retrySleep = clock.sleep

	finishesWithin(t, 60*time.Second, "the collection", func() {
		c.StartWorkers()
		c.Collect()
		c.Stop()
	})

	if c.collectionStopped() {
		t.Fatalf("the collection stopped although Thunderstorm came back; log:\n%s", output.String())
	}
	if got := atomic.LoadInt64(&c.Statistics.uploadErrors); got != outageThreshold {
		t.Errorf("expected %d upload errors, got %d", outageThreshold, got)
	}
	if got := atomic.LoadInt64(&c.Statistics.uploadedFiles); got != 2 || atomic.LoadInt32(&uploads) != 2 {
		t.Errorf("expected the 2 remaining files to be uploaded, got %d (server saw %d)", got, atomic.LoadInt32(&uploads))
	}
	if !strings.Contains(output.String(), "answers again") {
		t.Errorf("log does not report the recovery:\n%s", output.String())
	}
}

func TestAnsweredUploadResetsTheOutageCount(t *testing.T) {
	c := NewCollector(CollectorConfig{Server: "http://127.0.0.1:1", Threads: 1}, log.New(ioutil.Discard, "", 0))
	c.recordUndeliverable()
	c.recordUndeliverable()
	c.recordAnswer()
	c.recordUndeliverable()
	c.recordUndeliverable()

	if c.collectionStopped() {
		t.Fatal("files that failed with an answered upload in between must not stop the collection")
	}
}
