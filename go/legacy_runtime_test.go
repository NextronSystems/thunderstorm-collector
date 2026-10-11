package main

import (
	"bytes"
	"io/ioutil"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"sync/atomic"
	"testing"
	"time"
)

func TestPackagedConfiguration(t *testing.T) {
	config := DefaultConfig
	if err := ReadTemplateFile("config.yml", &config); err != nil {
		t.Fatal(err)
	}
	config.DryRun = true
	validated, err := validateConfig(config)
	if err != nil {
		t.Fatal(err)
	}
	if validated.MaxFileSize != 64*1024*1024 || len(validated.FileExtensions) == 0 || len(validated.MagicHeaders) == 0 {
		t.Fatal("Packaged configuration lost collection filters")
	}
}

func TestServiceUnavailableRetriesAreBounded(t *testing.T) {
	var attempts int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ioutil.ReadAll(r.Body)
		atomic.AddInt32(&attempts, 1)
		w.Header().Set("Retry-After", "0")
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()
	f, err := ioutil.TempFile("", "legacy-retry-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(f.Name())
	f.Write([]byte("synthetic"))
	f.Close()
	stat, err := os.Stat(f.Name())
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	c := NewCollector(CollectorConfig{Server: server.URL, Threads: 1}, log.New(&output, "", 0))
	info := infoWithPath{FileInfo: stat, path: f.Name()}
	for i := 0; ; i++ {
		redo := c.uploadToThunderstorm(&info)
		if !redo {
			break
		}
		if i >= maxRetries {
			t.Fatal("Retries exceed the configured limit")
		}
	}
	if atomic.LoadInt32(&attempts) != maxRetries+1 || info.retries != maxRetries || c.Statistics.uploadErrors != 1 || c.Statistics.uploadedFiles != 0 {
		t.Fatalf("Incorrect bounded retry result: attempts=%d retries=%d stats=%+v", attempts, info.retries, c.Statistics)
	}
	if !bytes.Contains(output.Bytes(), []byte("canceling it after 3 retries")) {
		t.Fatal("Missing useful terminal error")
	}
}

func TestLegacyTransportVerifiesTLS(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) }))
	defer server.Close()
	transport := buildHttpTransport(Config{Threads: 1})
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	response, err := client.Get(server.URL)
	if err == nil {
		response.Body.Close()
		t.Fatal("Untrusted TLS certificate unexpectedly accepted")
	}
}

func TestTransportErrorBackoff(t *testing.T) {
	for _, test := range []struct {
		name           string
		failedAttempts int32
		wantUploaded   int64
		wantErrors     int64
	}{
		{"exhausted", 4, 0, 1},
		{"recovered", 3, 1, 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			var attempts int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				attempt := atomic.AddInt32(&attempts, 1)
				if _, err := ioutil.ReadAll(r.Body); err != nil {
					t.Errorf("Read upload body: %v", err)
					return
				}
				if attempt <= test.failedAttempts {
					// Closing without an HTTP response exercises the transport-error path.
					conn, _, err := w.(http.Hijacker).Hijack()
					if err != nil {
						t.Errorf("Hijack connection: %v", err)
						return
					}
					conn.Close()
					return
				}
				w.WriteHeader(http.StatusOK)
			}))
			defer server.Close()

			f, err := ioutil.TempFile("", "legacy-transport-retry-")
			if err != nil {
				t.Fatal(err)
			}
			defer os.Remove(f.Name())
			if _, err := f.Write([]byte("synthetic")); err != nil {
				f.Close()
				t.Fatal(err)
			}
			if err := f.Close(); err != nil {
				t.Fatal(err)
			}
			stat, err := os.Stat(f.Name())
			if err != nil {
				t.Fatal(err)
			}
			c := NewCollector(CollectorConfig{Server: server.URL, Threads: 1}, log.New(ioutil.Discard, "", 0))
			var delays []time.Duration
			c.retrySleep = func(delay time.Duration) { delays = append(delays, delay) }
			info := infoWithPath{FileInfo: stat, path: f.Name()}
			for attempt := 1; attempt <= 4; attempt++ {
				if redo := c.uploadToThunderstorm(&info); redo != (attempt < 4) {
					t.Fatalf("Attempt %d: retry=%t, want %t", attempt, redo, attempt < 4)
				}
			}
			wantDelays := []time.Duration{4 * time.Second, 8 * time.Second, 16 * time.Second}
			if !reflect.DeepEqual(delays, wantDelays) {
				t.Errorf("Retry delays = %v, want %v", delays, wantDelays)
			}
			if got := atomic.LoadInt32(&attempts); got != 4 || info.retries != 3 {
				t.Errorf("Attempts=%d retries=%d, want 4 attempts and 3 retries", got, info.retries)
			}
			if c.Statistics.uploadedFiles != test.wantUploaded || c.Statistics.uploadErrors != test.wantErrors || c.Statistics.fileErrors != 0 {
				t.Errorf("Incorrect transport retry statistics: %+v", c.Statistics)
			}
		})
	}
}
