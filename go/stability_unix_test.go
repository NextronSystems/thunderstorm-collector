// +build darwin dragonfly freebsd linux netbsd openbsd

package main

import (
	"io/ioutil"
	"log"
	"os"
	"path/filepath"
	"syscall"
	"testing"
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
