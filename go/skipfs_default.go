//go:build !aix && !android && !dragonfly && !linux && !darwin
// +build !aix,!android,!dragonfly,!linux,!darwin

package main

func SkipFilesystem(path string) bool {
	return false
}
