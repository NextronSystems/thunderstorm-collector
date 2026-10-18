package main

import (
	"io/ioutil"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestSkipFilesystemName(t *testing.T) {
	for name, want := range map[string]bool{
		"devfs": true, "fdesc": true, "volfs": true, "autofs": true,
		"nfs": true, "smbfs": true, "afpfs": true, "webdav": true, "ftp": true,
		// local storage must never be skipped
		"apfs": false, "hfs": false, "msdos": false, "exfat": false, "ntfs": false,
		"udf": false, "cd9660": false, "": false,
	} {
		if got := skipFilesystemName(name); got != want {
			t.Errorf("skipFilesystemName(%q) = %v, want %v", name, got, want)
		}
	}
}

// macOS reports filesystem type numbers that differ from Linux, so the default
// "skip pseudo and network filesystems" behaviour must be verified on a real Mac.
func TestSkipFilesystemOnMacOS(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS filesystem type names")
	}
	if !SkipFilesystem("/dev") {
		t.Error("/dev (devfs) must be skipped")
	}
	dir, err := ioutil.TempDir("", "skipfs-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	if SkipFilesystem(dir) {
		t.Error("a directory on local storage must not be skipped")
	}
	if SkipFilesystem(filepath.Join(dir, "missing")) {
		t.Error("a path that cannot be inspected must not be skipped")
	}
}

func TestCollectionSkipsPseudoFilesystemsOnMacOS(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS filesystem type names")
	}
	c := NewCollector(CollectorConfig{RootPaths: []string{"/dev"}, DryRun: true, Threads: 1}, log.New(ioutil.Discard, "", 0))
	c.StartWorkers()
	c.Collect()
	c.Stop()
	if got := c.Statistics.filesDiscovered; got != 0 {
		t.Fatalf("/dev was walked: %d entries discovered", got)
	}
}
