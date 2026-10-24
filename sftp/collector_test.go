package main

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log"
	"mime"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/pkg/sftp"
)

// sftpClientFor serves directory over an in-process SFTP server, so the
// tests exercise the real protocol without SSH.
func sftpClientFor(t *testing.T) *sftp.Client {
	t.Helper()
	clientReader, serverWriter := io.Pipe()
	serverReader, clientWriter := io.Pipe()
	server, err := sftp.NewServer(struct {
		io.Reader
		io.WriteCloser
	}{serverReader, serverWriter})
	if err != nil {
		t.Fatal(err)
	}
	go server.Serve()
	client, err := sftp.NewClientPipe(clientReader, clientWriter)
	if err != nil {
		t.Fatal(err)
	}
	// The server must go first: the client waits for its reader, which only
	// ends when the server closes its side of the pipe.
	t.Cleanup(func() { server.Close(); client.Close() })
	return client
}

type receivedSample struct {
	path   string
	sha256 string
}

// uploadRecorder is a Thunderstorm stand-in that records every upload.
func uploadRecorder() (http.Handler, func() []receivedSample) {
	var mutex sync.Mutex
	var samples []receivedSample
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		file, header, err := r.FormFile("file")
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		hasher := sha256.New()
		io.Copy(hasher, file)
		// header.Filename is reduced to the base name; Thunderstorm needs the
		// full path, so read it from the raw header.
		_, params, err := mime.ParseMediaType(header.Header.Get("Content-Disposition"))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		mutex.Lock()
		samples = append(samples, receivedSample{params["filename"], hex.EncodeToString(hasher.Sum(nil))})
		mutex.Unlock()
		w.Write([]byte(`{"id": 1}`))
	})
	return handler, func() []receivedSample {
		mutex.Lock()
		defer mutex.Unlock()
		sort.Slice(samples, func(i, j int) bool { return samples[i].path < samples[j].path })
		return append([]receivedSample(nil), samples...)
	}
}

// thunderstorm runs an upload recorder as an HTTP server.
func thunderstorm(t *testing.T) (*httptest.Server, func() []receivedSample) {
	handler, received := uploadRecorder()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return server, received
}

func writeFile(t *testing.T, name string, content string, mode os.FileMode, mtime time.Time) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(name, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(name, mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(name, mtime, mtime); err != nil {
		t.Fatal(err)
	}
	return name
}

func digest(content string) string {
	sum := sha256.Sum256([]byte(content))
	return hex.EncodeToString(sum[:])
}

// sourceTree creates a small source filesystem and returns its root.
func sourceTree(t *testing.T) string {
	root := t.TempDir()
	old := time.Now().Add(-30 * 24 * time.Hour)
	recent := time.Now().Add(-time.Minute)
	writeFile(t, filepath.Join(root, "www", "shell.php"), "<?php eval($_POST['c']); ?>", 0o644, recent)
	writeFile(t, filepath.Join(root, "www", "logo.png"), "\x89PNG\r\n\x1a\nimage", 0o644, old)
	writeFile(t, filepath.Join(root, "tmp", "implant"), "\x7fELF\x02\x01\x01binary", 0o644, old)
	writeFile(t, filepath.Join(root, "bin", "update"), "plain text, but executable", 0o755, recent)
	writeFile(t, filepath.Join(root, "var", "backup.tar.gz"), string(make([]byte, 3*1024*1024)), 0o644, old)
	writeFile(t, filepath.Join(root, "proc", "kcore.php"), "<?php excluded ?>", 0o644, recent)
	if err := os.Symlink(filepath.Join(root, "www", "shell.php"), filepath.Join(root, "www", "link.php")); err != nil {
		t.Fatal(err)
	}
	return root
}

func runCollector(t *testing.T, settings Settings) (*Collector, []receivedSample) {
	t.Helper()
	server, received := thunderstorm(t)
	settings.UploadURL = server.URL + "/api/checkAsync?source=test"
	if settings.MaxFileSize == 0 {
		settings.MaxFileSize = 2 * 1024 * 1024
	}
	settings.Threads, settings.WalkThreads = 2, 2
	collector := NewCollector(settings, sftpClientFor(t), server.Client(), log.New(io.Discard, "", 0), nil)
	collector.Run()
	return collector, received()
}

func TestSelectionByListingAndHeader(t *testing.T) {
	root := sourceTree(t)
	collector, received := runCollector(t, Settings{
		RootPaths:    []string{root},
		Extensions:   []string{".php"},
		MagicHeaders: [][]byte{{0x7f, 'E', 'L', 'F'}},
		Executable:   true,
		ExcludeGlobs: []string{filepath.Join(root, "proc")},
	})

	want := []receivedSample{
		{filepath.Join(root, "bin", "update"), digest("plain text, but executable")},
		{filepath.Join(root, "tmp", "implant"), digest("\x7fELF\x02\x01\x01binary")},
		{filepath.Join(root, "www", "shell.php"), digest("<?php eval($_POST['c']); ?>")},
	}
	if !reflect.DeepEqual(want, received) {
		t.Errorf("uploads = %v, want %v", received, want)
	}
	stats := collector.Stats
	// Only implant and logo.png need their header: shell.php matches by name,
	// update by its execute bit, and the backup is too big to be considered.
	if stats.HeaderReads != 2 || stats.HeaderBytes != 8 {
		t.Errorf("header reads = %d (%d bytes), want 2 (8 bytes)", stats.HeaderReads, stats.HeaderBytes)
	}
	if stats.TooBig != 1 || stats.WrongType != 1 || stats.Symlinks != 1 || stats.Excluded != 1 {
		t.Errorf("too big %d, wrong type %d, symlinks %d, excluded %d; want 1 each", stats.TooBig, stats.WrongType, stats.Symlinks, stats.Excluded)
	}
	if stats.ErrorCount() != 0 {
		t.Errorf("error count = %d, want 0", stats.ErrorCount())
	}
}

func TestMaxAgeUsesModificationTime(t *testing.T) {
	root := sourceTree(t)
	_, received := runCollector(t, Settings{
		RootPaths:    []string{root},
		Threshold:    time.Now().Add(-time.Hour),
		ExcludeGlobs: []string{filepath.Join(root, "proc")},
	})
	var paths []string
	for _, sample := range received {
		paths = append(paths, sample.path)
	}
	want := []string{filepath.Join(root, "bin", "update"), filepath.Join(root, "www", "shell.php")}
	if !reflect.DeepEqual(want, paths) {
		t.Errorf("uploads = %v, want %v", paths, want)
	}
}

func TestDryRunWithoutMagicReadsNoFileData(t *testing.T) {
	root := sourceTree(t)
	collector, received := runCollector(t, Settings{RootPaths: []string{root}, DryRun: true})
	if len(received) != 0 {
		t.Errorf("dry run uploaded %d files", len(received))
	}
	if collector.Stats.HeaderReads != 0 || collector.Stats.ContentBytes != 0 {
		t.Errorf("dry run read %d headers and %d content bytes, want none", collector.Stats.HeaderReads, collector.Stats.ContentBytes)
	}
	// Every regular file except the backup, which is too big.
	if collector.Stats.Uploaded != 5 {
		t.Errorf("dry run selected %d files, want 5", collector.Stats.Uploaded)
	}
}

func TestParseMaxAge(t *testing.T) {
	for value, want := range map[string]time.Duration{"30": 30 * 24 * time.Hour, "2d": 48 * time.Hour, "6h": 6 * time.Hour, "15m": 15 * time.Minute, "90s": 90 * time.Second} {
		threshold, err := parseMaxAge(value)
		if err != nil {
			t.Errorf("parseMaxAge(%q): %v", value, err)
			continue
		}
		if got := time.Since(threshold); got < want || got > want+time.Minute {
			t.Errorf("parseMaxAge(%q) is %v ago, want %v", value, got, want)
		}
	}
	for _, value := range []string{"5x", "d", "1.5h"} {
		if _, err := parseMaxAge(value); err == nil {
			t.Errorf("parseMaxAge(%q) succeeded, want an error", value)
		}
	}
}
