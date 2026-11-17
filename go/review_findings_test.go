package main

import (
	"bytes"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Regression tests for the stability, reliability, usability and performance
// review of the Go collector.

// On Windows the walk yields paths with "\", which doublestar.Match reads as an
// escape character: no exclude glob matched there, not even the two examples of
// the help text.
func TestExcludeGlobsMatchWindowsPaths(t *testing.T) {
	for _, test := range []struct {
		glob, path string
		separator  rune
		want       bool
	}{
		{`C:\tools`, `C:\tools`, '\\', true},
		{`C:\Users\**\.git\**`, `C:\Users\bob\.git\config`, '\\', true},
		{`C:/Users/**/.git/**`, `C:\Users\bob\.git\config`, '\\', true},
		{`**\node_modules\**`, `C:\src\node_modules\x.js`, '\\', true},
		{`**/node_modules/**`, `C:\src\node_modules\x.js`, '\\', true},
		{`**/*.jpg`, `C:\data\photo.jpg`, '\\', true},
		{`C:\tools`, `C:\toolsmith`, '\\', false},
		{`**\.git\**`, `C:\src\main.go`, '\\', false},
		{`**/node_modules/**`, `/src/node_modules/x.js`, '/', true},
		{`/data/a\*b`, `/data/a*b`, '/', true}, // "\" still escapes on Unix
		{`/data/a\*b`, `/data/axb`, '/', false},
	} {
		got, err := excludeMatches(test.glob, test.path, test.separator)
		if err != nil || got != test.want {
			t.Errorf("excludeMatches(%q, %q, %q) = %v, %v; want %v", test.glob, test.path, test.separator, got, err, test.want)
		}
	}
}

func TestInvalidExcludeGlobIsReportedOnce(t *testing.T) {
	c, output := dryRunCollector("testdata")
	c.ExcludeGlobs = []string{"[]a]"}
	c.StartWorkers()
	c.Collect()
	c.Stop()
	if got := strings.Count(output.String(), "is not valid"); got != 1 {
		t.Fatalf("expected one log line about the invalid glob, got %d: %q", got, output.String())
	}
}

// A gateway in front of Thunderstorm answers 502 or 504 while Thunderstorm is
// down. Such a file was failed at once and reset the outage count, so the
// collector ran through the whole tree failing every file.
func TestGatewayErrorsAreRetriedAndCountAsOutage(t *testing.T) {
	for _, status := range []int{http.StatusBadGateway, http.StatusGatewayTimeout} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			var requests int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				io.Copy(ioutil.Discard, r.Body)
				atomic.AddInt32(&requests, 1)
				http.Error(w, "upstream unavailable", status)
			}))
			defer server.Close()
			name, stat := newTestFile(t, "sample")
			defer os.Remove(name)

			var output bytes.Buffer
			c := NewCollector(CollectorConfig{Server: server.URL, Threads: 1}, log.New(&output, "", 0))
			var delays []time.Duration
			c.retrySleep = func(delay time.Duration) { delays = append(delays, delay) }
			info := infoWithPath{FileInfo: stat, path: name}
			for c.uploadToThunderstorm(&info) {
			}

			if want := []time.Duration{4 * time.Second, 8 * time.Second, 16 * time.Second}; !reflect.DeepEqual(delays, want) {
				t.Errorf("retry delays = %v, want %v", delays, want)
			}
			if got := atomic.LoadInt32(&requests); got != 4 {
				t.Errorf("expected 4 attempts, got %d", got)
			}
			if got := atomic.LoadInt64(&c.Statistics.uploadErrors); got != 1 {
				t.Errorf("expected one upload error, got %d", got)
			}
			if got := atomic.LoadInt64(&c.outage.consecutiveFailures); got != 1 {
				t.Errorf("a gateway error must count towards the outage, count is %d", got)
			}
			if !strings.Contains(output.String(), fmt.Sprintf("gateway in front of Thunderstorm answered HTTP %d", status)) {
				t.Errorf("log does not name the gateway error: %q", output.String())
			}
		})
	}
}

// With more than two workers the default of two idle connections per host made
// the transport close and reopen connections all the time; a negative --threads
// value closed every connection after one request.
func TestTransportKeepsOneConnectionPerWorker(t *testing.T) {
	for _, threads := range []int{-2, 0, 1, 8} {
		transport := buildHttpTransport(Config{Threads: threads})
		want := effectiveThreads(threads) + 1
		if transport.MaxIdleConns != want || transport.MaxIdleConnsPerHost != want {
			t.Errorf("--threads %d: MaxIdleConns=%d MaxIdleConnsPerHost=%d, want %d for both",
				threads, transport.MaxIdleConns, transport.MaxIdleConnsPerHost, want)
		}
	}
}

func TestWorkersReuseTheirConnections(t *testing.T) {
	const threads, files = 8, 160
	var connections int32
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(ioutil.Discard, r.Body)
		time.Sleep(2 * time.Millisecond)
		w.Write([]byte("{}"))
	}))
	server.Config.ConnState = func(conn net.Conn, state http.ConnState) {
		if state == http.StateNew {
			atomic.AddInt32(&connections, 1)
		}
	}
	server.Start()
	defer server.Close()

	dir := tempDirectory(t)
	defer os.RemoveAll(dir)
	for i := 0; i < files; i++ {
		if err := ioutil.WriteFile(filepath.Join(dir, fmt.Sprintf("%03d.bin", i)), []byte("sample"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	c := NewCollector(CollectorConfig{Server: server.URL, RootPaths: []string{dir}, Threads: threads}, log.New(ioutil.Discard, "", 0))
	c.client.Transport = buildHttpTransport(Config{Threads: threads})
	c.StartWorkers()
	c.Collect()
	c.Stop()

	if got := atomic.LoadInt64(&c.Statistics.uploadedFiles); got != files {
		t.Fatalf("expected %d uploads, got %d", files, got)
	}
	if got := atomic.LoadInt32(&connections); got > threads {
		t.Errorf("%d workers opened %d connections for %d uploads; each should keep its own", threads, got, files)
	}
}

// With extensions and no magic headers the name decides. Such a file was
// queued, opened and only then skipped: a full-disk run opened every file.
func TestExtensionOnlyFilterDecidesDuringTheWalk(t *testing.T) {
	queuedPaths := func(cc CollectorConfig) ([]string, *Collector) {
		c := NewCollector(cc, log.New(ioutil.Discard, "", 0))
		c.filesToUpload = make(chan infoWithPath)
		var queued []string
		done := make(chan struct{})
		go func() {
			for file := range c.filesToUpload {
				queued = append(queued, filepath.ToSlash(file.path))
			}
			close(done)
		}()
		c.Collect()
		close(c.filesToUpload)
		<-done
		return queued, c
	}

	queued, c := queuedPaths(CollectorConfig{RootPaths: []string{"testdata"}, FileExtensions: []string{".TXT"}})
	if want := []string{"testdata/foo.txt"}; !reflect.DeepEqual(queued, want) {
		t.Errorf("extension-only filter queued %v, want %v", queued, want)
	}
	if got := c.Statistics.getSkipCount(SkipReasonWrongType); got == 0 {
		t.Error("files with another extension must be counted as wrong type")
	}

	// A magic header can still select a file with another extension, so the
	// decision needs the file content.
	queued, _ = queuedPaths(CollectorConfig{RootPaths: []string{"testdata"}, FileExtensions: []string{".txt"}, MagicHeaders: [][]byte{{0xff, 0xd8}}})
	if len(queued) < 2 {
		t.Errorf("with magic headers every candidate must be queued, got %v", queued)
	}
}

// A file shorter than the longest configured magic header could not match any
// header, also not a shorter one.
func TestMagicHeaderMatchesFileShorterThanTheLongestHeader(t *testing.T) {
	c := NewCollector(CollectorConfig{MagicHeaders: [][]byte{[]byte("#!"), []byte("On Error Resume")}}, log.New(ioutil.Discard, "", 0))
	for content, wanted := range map[string]bool{
		"#!/bin/sh\n":              true,
		"#!":                       true,
		"On Error Resume Next\r\n": true,
		"#":                        false,
		"":                         false,
		"plain text":               false,
	} {
		name, _ := newTestFile(t, content)
		f, err := os.Open(name)
		if err != nil {
			t.Fatal(err)
		}
		_, excluded := c.checkFileContent(&infoWithPath{path: name}, f)
		f.Close()
		os.Remove(name)
		if excluded == wanted {
			t.Errorf("content %q: wanted=%v but excluded=%v", content, wanted, excluded)
		}
	}
}

// pflag's string slice splits a value at commas, which broke paths and globs
// that contain one.
func TestPathExcludeAndCAOptionsKeepCommas(t *testing.T) {
	config := DefaultConfig
	config.RootPaths = []string{"/configured"}
	flags := CreateFlagset(&config)
	err := flags.Parse([]string{"collector",
		"-p", "/data/Smith, John", "--path", "/other",
		"--exclude", "**/{cache,tmp}/**",
		"--ca", "/etc/ssl/a,b.pem",
		"-e", ".exe,.dll", "--magic", "4d5a,cffa"})
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"/data/Smith, John", "/other"}; !reflect.DeepEqual(config.RootPaths, want) {
		t.Errorf("paths = %q, want %q (the first -p replaces the configured roots)", config.RootPaths, want)
	}
	if want := []string{"**/{cache,tmp}/**"}; !reflect.DeepEqual(config.ExcludeGlobs, want) {
		t.Errorf("excludes = %q, want %q", config.ExcludeGlobs, want)
	}
	if want := []string{"/etc/ssl/a,b.pem"}; !reflect.DeepEqual(config.CAs, want) {
		t.Errorf("CAs = %q, want %q", config.CAs, want)
	}
	// Extensions and magic headers cannot contain a comma and keep the list form.
	if want := []string{".exe", ".dll"}; !reflect.DeepEqual(config.FileExtensions, want) {
		t.Errorf("extensions = %q, want %q", config.FileExtensions, want)
	}
	if want := []string{"4d5a", "cffa"}; !reflect.DeepEqual(config.MagicHeaders, want) {
		t.Errorf("magic headers = %q, want %q", config.MagicHeaders, want)
	}

	usage := flags.FlagUsages()
	for _, want := range []string{"-p, --path strings", "--exclude strings", "(default [/configured])"} {
		if !strings.Contains(usage, want) {
			t.Errorf("help does not contain %q:\n%s", want, usage)
		}
	}
}

// A negative age put the cutoff into the future and a very large one overflowed
// time.Duration; both skipped every file as too old.
func TestMaxAgeRejectsNegativeAndOverflowingValues(t *testing.T) {
	for _, value := range []string{"-5", "-1h", "999999", "999999d", "2562048h"} {
		config := DefaultConfig
		config.DryRun = true
		config.MaxAgeInDays = value
		if _, err := validateConfig(config); err == nil || !strings.Contains(err.Error(), "max-age") {
			t.Errorf("--max-age %s: expected a validation error, got %v", value, err)
		}
	}
	for _, value := range []string{"0", "30", "10h", "90s", "36500", "2562047h"} {
		config := DefaultConfig
		config.DryRun = true
		config.MaxAgeInDays = value
		cc, err := validateConfig(config)
		if err != nil {
			t.Errorf("--max-age %s: unexpected error %v", value, err)
		} else if cc.ThresholdTime.After(time.Now()) {
			t.Errorf("--max-age %s: cutoff %v is in the future", value, cc.ThresholdTime)
		}
	}
}

func TestServerMustBeAHostNameOrAddress(t *testing.T) {
	for server, valid := range map[string]bool{
		"thunderstorm.example.internal": true,
		"10.0.0.5":                      true,
		"::1":                           true,
		"fe80::1":                       true,
		"http://thunderstorm.example":   false,
		"thunderstorm.example:8080":     false,
		"thunderstorm.example/api":      false,
	} {
		config := DefaultConfig
		config.Server = server
		_, err := validateConfig(config)
		if valid && err != nil {
			t.Errorf("server %q: unexpected error %v", server, err)
		}
		if !valid && (err == nil || !strings.Contains(err.Error(), "thunderstorm-server")) {
			t.Errorf("server %q: expected a thunderstorm-server error, got %v", server, err)
		}
	}
}

// Without --debug a run logged nothing between the start of the walk and the
// final statistics.
func TestProgressIsLoggedDuringALongRun(t *testing.T) {
	oldInterval := progressInterval
	progressInterval = 5 * time.Millisecond
	defer func() { progressInterval = oldInterval }()

	c, output := dryRunCollector("testdata")
	c.StartWorkers()
	c.Collect()
	time.Sleep(100 * time.Millisecond)
	c.Stop()
	if !strings.Contains(output.String(), "Progress after") || !strings.Contains(output.String(), "would be sent (dry-run)") {
		t.Fatalf("no progress line in the log: %q", output.String())
	}
}

// --logfile truncated the file, so a scheduled run erased the log of the run
// before it.
func TestLogfileIsAppendedTo(t *testing.T) {
	dir := tempDirectory(t)
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "collector.log")
	for _, line := range []string{"first run\n", "second run\n"} {
		logfile, err := openLogfile(path)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := logfile.Write([]byte(line)); err != nil {
			t.Fatal(err)
		}
		logfile.Close()
	}
	content, err := ioutil.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "first run\nsecond run\n" {
		t.Fatalf("log file holds %q", content)
	}
}
