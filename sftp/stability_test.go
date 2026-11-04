package main

import (
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pkg/sftp"
)

// Regression tests: a source or a Thunderstorm that stops answering must not
// hang or silently shorten the run, and a file must not be sent beyond what was
// checked when it was opened.

// controlledSource serves the local filesystem over SFTP through pipes that
// the test can stall (the server stops reading requests) or cut (the server
// goes away after a number of reads).
type controlledSource struct {
	stalled   int32
	cutAfter  int32
	reads     int32
	release   chan struct{}
	closeOnce sync.Once
	closers   []func()
}

type gateReader struct {
	reader io.Reader
	source *controlledSource
}

func (g *gateReader) Read(p []byte) (int, error) {
	s := g.source
	if atomic.LoadInt32(&s.stalled) == 1 {
		<-s.release
		return 0, io.EOF
	}
	if limit := atomic.LoadInt32(&s.cutAfter); limit > 0 && atomic.AddInt32(&s.reads, 1) > limit {
		s.close()
		return 0, io.EOF
	}
	return g.reader.Read(p)
}

func (s *controlledSource) close() {
	s.closeOnce.Do(func() {
		for _, closer := range s.closers {
			closer()
		}
	})
}

// newControlledSource returns an SFTP client whose answers go through
// watchdog, unless it is nil.
func newControlledSource(t *testing.T, watchdog func(onStall func()) *sftpWatchdog) (*sftp.Client, *controlledSource, *sftpWatchdog) {
	t.Helper()
	clientReader, serverWriter := io.Pipe()
	serverReader, clientWriter := io.Pipe()
	source := &controlledSource{release: make(chan struct{})}
	server, err := sftp.NewServer(struct {
		io.Reader
		io.WriteCloser
	}{&gateReader{serverReader, source}, serverWriter})
	if err != nil {
		t.Fatal(err)
	}
	go server.Serve()
	closeClient := func() {
		clientReader.CloseWithError(io.EOF)
		clientWriter.CloseWithError(io.ErrClosedPipe)
	}
	source.closers = []func(){func() { serverWriter.CloseWithError(io.EOF) }, closeClient}
	var dog *sftpWatchdog
	var reader io.Reader = clientReader
	if watchdog != nil {
		dog = watchdog(source.close)
		reader = dog.reader(clientReader)
	}
	client, err := sftp.NewClientPipe(reader, clientWriter)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		close(source.release)
		source.close()
		server.Close()
		client.Close()
		dog.Stop()
	})
	return client, source, dog
}

func collectorFor(t *testing.T, settings Settings, client *sftp.Client, handler http.Handler) *Collector {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	settings.UploadURL = server.URL + "/api/checkAsync?source=test"
	settings.StatusURL = server.URL + "/api/status"
	if settings.MaxFileSize == 0 {
		settings.MaxFileSize = 64 << 20
	}
	if settings.Threads == 0 {
		settings.Threads = 1
	}
	if settings.WalkThreads == 0 {
		settings.WalkThreads = 1
	}
	httpClient, err := newHTTPClient(Config{}, settings.ResponseTimeout)
	if err != nil {
		t.Fatal(err)
	}
	collector := NewCollector(settings, client, httpClient, log.New(io.Discard, "", 0), nil)
	collector.retrySleep = func(time.Duration) {}
	return collector
}

func wideTree(t *testing.T, directories int) string {
	root := t.TempDir()
	for i := 0; i < directories; i++ {
		writeFile(t, filepath.Join(root, "dir"+strconv.Itoa(i), "file.txt"), "sample", 0o644, time.Now())
	}
	return root
}

func TestSourceThatStopsAnsweringEndsTheRun(t *testing.T) {
	root := wideTree(t, 3)
	client, source, dog := newControlledSource(t, func(onStall func()) *sftpWatchdog {
		return newSFTPWatchdog(300*time.Millisecond, onStall)
	})
	handler, _ := uploadRecorder()
	collector := collectorFor(t, Settings{RootPaths: []string{root}}, client, handler)
	collector.watchdog = dog
	// From now on the source reads no request, like an sftp-server blocked on a
	// dead NFS mount.
	atomic.StoreInt32(&source.stalled, 1)

	runWithin(t, collector, 10*time.Second)

	if !dog.Fired() {
		t.Error("the watchdog did not close the connection")
	}
	if collector.Stats.ConnectionErrors != 1 || collector.Stats.ErrorCount() == 0 {
		t.Errorf("connection errors %d, error count %d; want 1 and more than 0", collector.Stats.ConnectionErrors, collector.Stats.ErrorCount())
	}
}

func TestLostConnectionFailsTheRun(t *testing.T) {
	root := wideTree(t, 40)
	client, source, _ := newControlledSource(t, nil)
	handler, _ := uploadRecorder()
	// No file matches, so nothing is in flight when the connection drops.
	collector := collectorFor(t, Settings{RootPaths: []string{root}, Extensions: []string{".nomatch"}}, client, handler)
	atomic.StoreInt32(&source.cutAfter, 40)

	runWithin(t, collector, 10*time.Second)

	stats := collector.Stats
	if stats.DirectoriesListed >= 41 {
		t.Fatalf("all %d directories were listed; the connection was not cut", stats.DirectoriesListed)
	}
	if stats.ConnectionErrors != 1 || stats.ErrorCount() == 0 {
		t.Errorf("connection errors %d, error count %d, walk errors %d; want 1, more than 0 and any",
			stats.ConnectionErrors, stats.ErrorCount(), stats.WalkErrors)
	}
}

func TestHTTPSUploadsUseHTTP1(t *testing.T) {
	var major int32
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.StoreInt32(&major, int32(r.ProtoMajor))
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	client, err := newHTTPClient(Config{SSL: true, Insecure: true}, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	response, err := client.Get(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	// Over HTTP/2 a stalled flow-control window blocks the upload without a
	// blocked write, which the stall guard would not notice.
	if got := atomic.LoadInt32(&major); got != 1 {
		t.Fatalf("the request used HTTP/%d, want HTTP/1.1", got)
	}
}

func TestFileThatGrewPastTheLimitIsNotSent(t *testing.T) {
	root := t.TempDir()
	name := writeFile(t, filepath.Join(root, "growing.log"), "listed", 0o644, time.Now())
	listed, err := os.Stat(name)
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(name, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatal(err)
	}
	f.Write(make([]byte, 100))
	f.Close()
	handler, received := uploadRecorder()
	collector := collectorFor(t, Settings{RootPaths: []string{root}, MaxFileSize: 50}, sftpClientFor(t), handler)

	collector.process(candidate{path: name, info: listed, typeKnown: true})

	if got := received(); len(got) != 0 {
		t.Fatalf("a file over the size limit was sent: %v", got)
	}
	if collector.Stats.TooBig != 1 || collector.Stats.ErrorCount() != 0 {
		t.Errorf("too big %d, error count %d; want 1 and 0", collector.Stats.TooBig, collector.Stats.ErrorCount())
	}
}

func TestCopyBeyondTheOpenedSizeFails(t *testing.T) {
	var sink []byte
	writer := &boundedWriter{writer: writerFunc(func(p []byte) (int, error) { sink = append(sink, p...); return len(p), nil }), remaining: 4}
	if _, err := writer.Write([]byte("abcd")); err != nil {
		t.Fatalf("a write within the size failed: %v", err)
	}
	if _, err := writer.Write([]byte("e")); err != errBeyondSize {
		t.Fatalf("a write beyond the size returned %v, want errBeyondSize", err)
	}
	if string(sink) != "abcd" {
		t.Fatalf("written %q", sink)
	}
}

type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(p []byte) (int, error) { return f(p) }

func TestRootGivenAsSymlinkIsListed(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "target")
	writeFile(t, filepath.Join(target, "a.txt"), "a", 0o644, time.Now())
	writeFile(t, filepath.Join(target, "sub", "b.txt"), "b", 0o644, time.Now())
	link := filepath.Join(root, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	handler, received := uploadRecorder()
	// The target is also given directly; it is listed once.
	collector := collectorFor(t, Settings{RootPaths: []string{link, target}}, sftpClientFor(t), handler)

	runWithin(t, collector, 10*time.Second)

	if got := len(received()); got != 2 {
		t.Fatalf("uploaded %d files, want the 2 below the linked root once", got)
	}
}

// outageServer drops uploads without an answer while down is set and answers
// /api/status with 503 until statusDown polls have been made.
type outageServer struct {
	down       int32
	statusDown int32
	polls      int32
	posts      int32
	uploads    int32
}

func (o *outageServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/api/status" {
		if atomic.AddInt32(&o.polls, 1) <= atomic.LoadInt32(&o.statusDown) {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		atomic.StoreInt32(&o.down, 0)
		return
	}
	atomic.AddInt32(&o.posts, 1)
	io.Copy(io.Discard, r.Body)
	if atomic.LoadInt32(&o.down) == 1 {
		conn, _, err := w.(http.Hijacker).Hijack()
		if err == nil {
			conn.Close()
		}
		return
	}
	atomic.AddInt32(&o.uploads, 1)
	w.Write([]byte(`{"id": 1}`))
}

type fakeClock struct {
	mutex   sync.Mutex
	current time.Time
}

func (f *fakeClock) now() time.Time {
	f.mutex.Lock()
	defer f.mutex.Unlock()
	return f.current
}

func (f *fakeClock) sleep(d time.Duration) {
	f.mutex.Lock()
	f.current = f.current.Add(d)
	f.mutex.Unlock()
}

func outageCollector(t *testing.T, files int, server *outageServer, wait time.Duration) *Collector {
	root := t.TempDir()
	for i := 0; i < files; i++ {
		writeFile(t, filepath.Join(root, "f"+strconv.Itoa(i)+".bin"), "sample", 0o644, time.Now())
	}
	collector := collectorFor(t, Settings{RootPaths: []string{root}, ServerWait: wait}, sftpClientFor(t), server)
	clock := &fakeClock{current: time.Unix(0, 0)}
	collector.now = clock.now
	collector.retrySleep = clock.sleep
	return collector
}

func TestRunStopsWhenThunderstormStaysAway(t *testing.T) {
	server := &outageServer{down: 1, statusDown: 1000}
	collector := outageCollector(t, 6, server, 10*time.Second)

	runWithin(t, collector, 30*time.Second)

	stats := collector.Stats
	if stats.UploadErrors != outageThreshold || stats.Uploaded != 0 || stats.ErrorCount() == 0 {
		t.Errorf("upload errors %d, uploaded %d, error count %d; want %d, 0 and more than 0",
			stats.UploadErrors, stats.Uploaded, stats.ErrorCount(), outageThreshold)
	}
	if got := atomic.LoadInt32(&server.posts); got != outageThreshold*(maxRetries+1) {
		t.Errorf("%d upload attempts, want %d: files after the stop must not be tried", got, outageThreshold*(maxRetries+1))
	}
	if atomic.LoadInt32(&server.polls) == 0 {
		t.Error("the status page was not polled")
	}
}

func TestRunContinuesWhenThunderstormComesBack(t *testing.T) {
	server := &outageServer{down: 1, statusDown: 1}
	collector := outageCollector(t, 5, server, 10*time.Minute)

	runWithin(t, collector, 30*time.Second)

	stats := collector.Stats
	if stats.UploadErrors != outageThreshold || stats.Uploaded != 2 || stats.NotSent != 0 {
		t.Errorf("upload errors %d, uploaded %d, not sent %d; want %d, 2 and 0", stats.UploadErrors, stats.Uploaded, stats.NotSent, outageThreshold)
	}
	if got := atomic.LoadInt32(&server.polls); got != 2 {
		t.Errorf("%d status polls, want 2", got)
	}
}

func TestInterruptEndsTheRun(t *testing.T) {
	root := wideTree(t, 5)
	started := make(chan struct{}, 10)
	release := make(chan struct{})
	defer close(release)
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		started <- struct{}{}
		select {
		case <-release:
		case <-r.Context().Done():
		}
	})
	collector := collectorFor(t, Settings{RootPaths: []string{root}}, sftpClientFor(t), handler)
	go func() {
		<-started
		collector.Interrupt()
	}()

	runWithin(t, collector, 10*time.Second)

	if collector.Stats.Interrupted != 1 || collector.Stats.Uploaded != 0 || collector.Stats.ErrorCount() == 0 {
		t.Errorf("interrupted %d, uploaded %d, error count %d; want 1, 0 and more than 0",
			collector.Stats.Interrupted, collector.Stats.Uploaded, collector.Stats.ErrorCount())
	}
}
