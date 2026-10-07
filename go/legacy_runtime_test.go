package main

import (
	"bytes"
	"io/ioutil"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
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
