package main

import (
	"bytes"
	"io/ioutil"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// On Windows the walk yields backslash paths; doublestar.Match splits on '/'
// and reads a backslash as an escape, so excludes never matched there.
func TestExcludeGlobsMatchWindowsPaths(t *testing.T) {
	for _, test := range []struct {
		glob  string
		path  string
		match bool
	}{
		{`C:\tools`, `C:\tools`, true},
		{`C:\tools\**`, `C:\tools\bin\x.exe`, true},
		{`C:\Users\**\.git\**`, `C:\Users\bob\proj\.git\config`, true},
		{`**/node_modules/**`, `C:\Users\bob\app\node_modules\pkg\index.js`, true},
		{`c:\TOOLS\**`, `C:\Tools\x.exe`, true},
		{`**\*.jpg`, `D:\data\photo.JPG`, true},
		{`\\server\share\**`, `\\server\share\dir\file.txt`, true},
		{`C:\tools\**`, `C:\toolsx\file.exe`, false},
		{`C:\Users\**\.git\**`, `C:\Users\bob\proj\src\main.go`, false},
	} {
		if got := matchExclude(test.glob, test.path, '\\', true); got != test.match {
			t.Errorf("glob %q, path %q: match=%t, want %t", test.glob, test.path, got, test.match)
		}
	}
}

func TestExcludeGlobsOnUnixAreUnchanged(t *testing.T) {
	for _, test := range []struct {
		glob  string
		path  string
		match bool
	}{
		{`/var/cache/**`, `/var/cache/apt/x.deb`, true},
		{`**/node_modules/**`, `/srv/app/node_modules/pkg/index.js`, true},
		{`**/*.jpg`, `/data/photo.JPG`, false},
		{`/data/\*`, `/data/*`, true},
		{`/data/\*`, `/data/x`, false},
	} {
		if got := matchExclude(test.glob, test.path, '/', false); got != test.match {
			t.Errorf("glob %q, path %q: match=%t, want %t", test.glob, test.path, got, test.match)
		}
	}
}

// symlinkedTree creates a directory with two files and a symbolic link to it.
func symlinkedTree(t *testing.T) (dir string, link string, cleanup func()) {
	base, err := ioutil.TempDir("", "collector-root-")
	if err != nil {
		t.Fatal(err)
	}
	dir = filepath.Join(base, "real")
	if err := os.MkdirAll(filepath.Join(dir, "sub"), 0755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"a.bin", filepath.Join("sub", "b.bin")} {
		if err := ioutil.WriteFile(filepath.Join(dir, name), []byte("sample"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	link = filepath.Join(base, "link")
	if err := os.Symlink(dir, link); err != nil {
		os.RemoveAll(base)
		t.Skipf("cannot create a symbolic link here: %v", err)
	}
	return dir, link, func() { os.RemoveAll(base) }
}

func TestScanRootGivenAsSymlinkIsWalked(t *testing.T) {
	_, link, cleanup := symlinkedTree(t)
	defer cleanup()
	c, output := dryRunCollector(link)

	c.StartWorkers()
	c.Collect()
	c.Stop()

	if got := atomic.LoadInt64(&c.Statistics.uploadedFiles); got != 2 {
		t.Fatalf("expected the 2 files below the linked root, got %d; log:\n%s", got, output.String())
	}
	if !strings.Contains(output.String(), "is a symbolic link to") {
		t.Errorf("log does not say that the root was resolved:\n%s", output.String())
	}
}

func TestScanRootGivenTwiceIsWalkedOnce(t *testing.T) {
	dir, link, cleanup := symlinkedTree(t)
	defer cleanup()
	c, output := dryRunCollector(dir, link, dir+string(os.PathSeparator))

	c.StartWorkers()
	c.Collect()
	c.Stop()

	if got := atomic.LoadInt64(&c.Statistics.uploadedFiles); got != 2 {
		t.Fatalf("expected each file once, got %d; log:\n%s", got, output.String())
	}
}

func TestExcludeWrittenForTheLinkedRootApplies(t *testing.T) {
	_, link, cleanup := symlinkedTree(t)
	defer cleanup()
	var output bytes.Buffer
	c := NewCollector(CollectorConfig{
		RootPaths:    []string{link},
		ExcludeGlobs: []string{filepath.ToSlash(filepath.Join(link, "sub")) + "/**"},
		DryRun:       true,
		Threads:      1,
	}, log.New(&output, "", 0))
	if os.PathSeparator == '\\' {
		c.ExcludeGlobs = []string{filepath.Join(link, "sub")}
	}

	c.StartWorkers()
	c.Collect()
	c.Stop()

	if got := atomic.LoadInt64(&c.Statistics.uploadedFiles); got != 1 {
		t.Fatalf("expected the excluded subdirectory to be skipped, got %d files; log:\n%s", got, output.String())
	}
}

func TestDanglingSymlinkRootIsARootError(t *testing.T) {
	_, link, cleanup := symlinkedTree(t)
	defer cleanup()
	dangling := link + "-dangling"
	if err := os.Symlink(filepath.Join(filepath.Dir(link), "missing"), dangling); err != nil {
		t.Skipf("cannot create a symbolic link here: %v", err)
	}
	c, output := dryRunCollector(dangling)

	c.StartWorkers()
	c.Collect()
	c.Stop()

	if got := c.Statistics.ErrorCount(); got != 1 {
		t.Fatalf("expected one root error, got %d; log:\n%s", got, output.String())
	}
}
