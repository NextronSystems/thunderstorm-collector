package main

import (
	"bytes"
	"io"
	"io/ioutil"
	"log"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Regression tests: the collector must not report success for work that did not
// happen, and must not silently change which files it looks at.

func newTestFile(t *testing.T, content string) (string, os.FileInfo) {
	f, err := ioutil.TempFile("", "collector-failure-")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.Write([]byte(content)); err != nil {
		t.Fatal(err)
	}
	f.Close()
	stat, err := os.Stat(f.Name())
	if err != nil {
		t.Fatal(err)
	}
	return f.Name(), stat
}

// redirectingServer answers every request except /login with a redirect to
// /login, like a reverse proxy that demands a sign-in. loginHits counts the
// requests that a redirect-following client sends to /login.
func redirectingServer(loginHits *int32, redirectCode int) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/login" {
			atomic.AddInt32(loginHits, 1)
			w.Write([]byte("<html>please sign in</html>"))
			return
		}
		ioutil.ReadAll(r.Body)
		http.Redirect(w, r, "/login", redirectCode)
	}))
}

func TestRedirectedUploadIsNotCountedAsSuccess(t *testing.T) {
	for _, code := range []int{http.StatusMovedPermanently, http.StatusFound, http.StatusSeeOther, http.StatusTemporaryRedirect} {
		var loginHits int32
		server := redirectingServer(&loginHits, code)
		name, stat := newTestFile(t, "sample")
		var output bytes.Buffer
		c := NewCollector(CollectorConfig{Server: server.URL, Threads: 1}, log.New(&output, "", 0))
		info := infoWithPath{FileInfo: stat, path: name}

		redo := c.uploadToThunderstorm(&info)

		server.Close()
		os.Remove(name)
		if redo {
			t.Errorf("HTTP %d: a redirect must not be retried", code)
		}
		if got := atomic.LoadInt64(&c.Statistics.uploadedFiles); got != 0 {
			t.Errorf("HTTP %d: redirected upload counted as uploaded (%d)", code, got)
		}
		if got := atomic.LoadInt64(&c.Statistics.uploadErrors); got != 1 {
			t.Errorf("HTTP %d: expected one upload error, got %d", code, got)
		}
		if got := atomic.LoadInt32(&loginHits); got != 0 {
			t.Errorf("HTTP %d: the redirect was followed (%d request(s) to /login)", code, got)
		}
		if !strings.Contains(output.String(), "redirects are not followed") {
			t.Errorf("HTTP %d: log does not explain the redirect: %q", code, output.String())
		}
	}
}

func TestStatusCheckRejectsRedirect(t *testing.T) {
	var loginHits int32
	server := redirectingServer(&loginHits, http.StatusFound)
	defer server.Close()
	c := NewCollector(CollectorConfig{Server: server.URL, Threads: 1}, log.New(ioutil.Discard, "", 0))

	err := c.CheckThunderstormUp()

	if err == nil || !strings.Contains(err.Error(), "redirect") {
		t.Fatalf("expected a redirect error from the status check, got %v", err)
	}
	if got := atomic.LoadInt32(&loginHits); got != 0 {
		t.Fatalf("the status check followed the redirect (%d request(s) to /login)", got)
	}
}

func dryRunCollector(roots ...string) (*Collector, *bytes.Buffer) {
	var output bytes.Buffer
	c := NewCollector(CollectorConfig{RootPaths: roots, DryRun: true, Threads: 1}, log.New(&output, "", 0))
	return c, &output
}

func TestMissingScanRootIsReported(t *testing.T) {
	parent, err := ioutil.TempDir("", "collector-walk-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(parent)
	c, output := dryRunCollector(filepath.Join(parent, "does-not-exist"))

	c.StartWorkers()
	c.Collect()
	c.Stop()

	if got := c.Statistics.ErrorCount(); got != 1 {
		t.Fatalf("expected one error for the missing root, got %d", got)
	}
	if !strings.Contains(output.String(), "Could not read scan root") {
		t.Fatalf("log does not mention the missing root: %q", output.String())
	}
}

func TestUnreadableDirectoryIsReportedButDoesNotFailTheRun(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("directory permissions are not enforced for this user or platform")
	}
	root, err := ioutil.TempDir("", "collector-walk-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	locked := filepath.Join(root, "locked")
	if err := os.Mkdir(locked, 0755); err != nil {
		t.Fatal(err)
	}
	if err := ioutil.WriteFile(filepath.Join(locked, "hidden.txt"), []byte("hidden"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := ioutil.WriteFile(filepath.Join(root, "visible.txt"), []byte("visible"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(locked, 0); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(locked, 0755) // allow the deferred RemoveAll to succeed
	c, output := dryRunCollector(root)

	c.StartWorkers()
	c.Collect()
	c.Stop()

	if got := atomic.LoadInt64(&c.Statistics.uploadedFiles); got != 1 {
		t.Errorf("expected the readable file to be collected, got %d", got)
	}
	if got := atomic.LoadInt64(&c.Statistics.walkErrors); got != 1 {
		t.Errorf("expected the unreadable directory to be counted, got %d", got)
	}
	// Permission-denied directories are routine on a full scan: reported, not fatal.
	if got := c.Statistics.ErrorCount(); got != 0 {
		t.Errorf("an unreadable directory must not change the exit status, got %d error(s)", got)
	}
	if !strings.Contains(output.String(), "Could not read '"+locked+"'") {
		t.Errorf("log does not mention the unreadable directory: %q", output.String())
	}
	if !strings.Contains(output.String(), "Paths that could not be read during the walk: 1") {
		t.Errorf("statistics do not mention the unreadable directory: %q", output.String())
	}
}

func TestVanishedEntryIsNotAnError(t *testing.T) {
	c, _ := dryRunCollector("root")
	c.reportWalkError("root", filepath.Join("root", "gone.txt"), &os.PathError{Op: "lstat", Path: "gone.txt", Err: os.ErrNotExist})
	if got := atomic.LoadInt64(&c.Statistics.walkErrors); got != 0 {
		t.Fatalf("an entry that vanished during the walk was counted as unreadable (%d)", got)
	}
	if got := c.Statistics.ErrorCount(); got != 0 {
		t.Fatalf("an entry that vanished during the walk was counted as an error (%d)", got)
	}
	// ... but a missing scan root is always an error.
	c.reportWalkError("root", "root", &os.PathError{Op: "lstat", Path: "root", Err: os.ErrNotExist})
	if got := c.Statistics.ErrorCount(); got != 1 {
		t.Fatalf("a missing scan root must be counted as an error, got %d", got)
	}
}

func TestErrorCountCoversFilesUploadsAndRootsButNotSubdirectories(t *testing.T) {
	c, _ := dryRunCollector()
	atomic.AddInt64(&c.Statistics.fileErrors, 1)
	atomic.AddInt64(&c.Statistics.uploadErrors, 2)
	atomic.AddInt64(&c.Statistics.rootErrors, 4)
	atomic.AddInt64(&c.Statistics.walkErrors, 8)
	if got := c.Statistics.ErrorCount(); got != 7 {
		t.Fatalf("expected 7, got %d", got)
	}
}

func TestRetryAfterIsCapped(t *testing.T) {
	var attempts int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ioutil.ReadAll(r.Body)
		atomic.AddInt32(&attempts, 1)
		w.Header().Set("Retry-After", "100000")
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()
	name, stat := newTestFile(t, "sample")
	defer os.Remove(name)
	c := NewCollector(CollectorConfig{Server: server.URL, Threads: 1}, log.New(ioutil.Discard, "", 0))
	var slept []time.Duration
	c.retrySleep = func(d time.Duration) { slept = append(slept, d) }
	info := infoWithPath{FileInfo: stat, path: name}

	if redo := c.uploadToThunderstorm(&info); !redo {
		t.Fatal("HTTP 503 must be retried")
	}
	if len(slept) != 1 || slept[0] != maxRetryAfter*time.Second {
		t.Fatalf("expected one wait of %d seconds, got %v", maxRetryAfter, slept)
	}
}

func TestExtensionsAreMatchedCaseInsensitively(t *testing.T) {
	c := NewCollector(CollectorConfig{FileExtensions: []string{".exe", ".PS1"}}, log.New(ioutil.Discard, "", 0))
	for path, wanted := range map[string]bool{
		"dir/run.exe":     true,
		"dir/RUN.EXE":     true,
		"dir/Run.Exe":     true,
		"dir/script.ps1":  true,
		"dir/script.PS1":  true,
		"dir/script.txt":  false,
		"dir/exe":         false,
		"dir/run.exe.bak": false,
	} {
		_, excluded := c.checkFileContent(&infoWithPath{path: path}, nil)
		if excluded == wanted {
			t.Errorf("%s: wanted=%v but excluded=%v", path, wanted, excluded)
		}
	}
}

func TestStrayArgumentsAreDetected(t *testing.T) {
	for _, tc := range []struct {
		args  []string
		extra []string
	}{
		{[]string{"collector"}, nil},
		{[]string{"collector", "-s", "host", "-p", "/data"}, nil},
		{[]string{"collector", "-s", "host", "/data"}, []string{"/data"}},
		{[]string{"collector", "-p", "C:\\Program", "Files"}, []string{"Files"}},
		{[]string{"collector", "-s", "host", "--", "/data"}, []string{"/data"}},
	} {
		config := DefaultConfig
		flags := CreateFlagset(&config)
		if err := flags.Parse(tc.args); err != nil {
			t.Fatalf("%v: %v", tc.args, err)
		}
		got := unexpectedArguments(flags)
		if strings.Join(got, "|") != strings.Join(tc.extra, "|") {
			t.Errorf("%v: expected %v, got %v", tc.args, tc.extra, got)
		}
	}
}

// A file name is attacker-controlled on a host under investigation. Toolchains
// before the one that percent-encodes CR and LF in multipart.Writer.CreateFormFile
// (Go 1.10 builds most release binaries) would let it inject MIME headers into
// the upload or end the part header early.
func TestUploadFileNameCannotInjectPartHeaders(t *testing.T) {
	hostile := "/data/evil\r\nContent-Transfer-Encoding: quoted-printable\r\nX-Injected: yes\r\n\r\nfake-body\"name\\x.exe\x1b[2K\x01\x7f\ttab"
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	fw, err := w.CreatePart(formFileHeader("file", hostile))
	if err != nil {
		t.Fatal(err)
	}
	fw.Write([]byte("REAL-CONTENT"))
	w.Close()

	r := multipart.NewReader(&buf, w.Boundary())
	part, err := r.NextPart()
	if err != nil {
		t.Fatalf("the part did not parse: %v", err)
	}
	if len(part.Header) != 2 || part.Header.Get("Content-Type") != "application/octet-stream" {
		t.Errorf("expected exactly Content-Disposition and Content-Type, got %v", part.Header)
	}
	if part.Header.Get("X-Injected") != "" || part.Header.Get("Content-Transfer-Encoding") != "" {
		t.Errorf("file name injected MIME headers: %v", part.Header)
	}
	want := "/data/evil%0D%0AContent-Transfer-Encoding: quoted-printable%0D%0AX-Injected: yes%0D%0A%0D%0Afake-body\"name\\x.exe%1B[2K%01%7F\ttab"
	// Parse Content-Disposition directly: Part.FileName() reduces the name to its
	// base name in current Go versions but not in older ones.
	if got := getFileName(part); got != want {
		t.Errorf("file name did not survive escaping:\n got %q\nwant %q", got, want)
	}
	body, err := ioutil.ReadAll(part)
	if err != nil || string(body) != "REAL-CONTENT" {
		t.Errorf("payload changed: %q (%v)", body, err)
	}
	if _, err := r.NextPart(); err != io.EOF {
		t.Errorf("expected exactly one part, next part error: %v", err)
	}
}
