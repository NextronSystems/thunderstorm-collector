package main

import "syscall"

// filesystemTypesDetected tells the startup summary whether SkipFilesystem can recognise
// pseudo and network filesystems on this platform.
var filesystemTypesDetected = true

// SkipFilesystem reports whether path lies on a pseudo or network filesystem.
// The filesystem type number that macOS reports in Statfs_t.Type has nothing in
// common with the Linux magic numbers that skipfs_unix.go compares against, so
// macOS is matched by filesystem type name instead.
func SkipFilesystem(path string) bool {
	var buf syscall.Statfs_t
	if err := syscall.Statfs(path, &buf); err != nil {
		return false
	}
	name := make([]byte, 0, len(buf.Fstypename))
	for _, c := range buf.Fstypename {
		if c == 0 {
			break
		}
		name = append(name, byte(c))
	}
	return skipFilesystemName(string(name))
}
