// +build !aix,!android,!dragonfly,!linux,!darwin

package main

// Pseudo and network filesystems are not recognised on this platform: SkipFilesystem never skips.
var filesystemTypesDetected = false

func SkipFilesystem(path string) bool {
	return false
}
