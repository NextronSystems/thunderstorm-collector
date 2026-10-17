package main

// skippedFilesystemNames lists filesystem type names, on platforms that identify
// a filesystem by name (macOS: Statfs_t.Fstypename), that do not hold local files
// worth collecting: pseudo filesystems, automount triggers and network shares.
var skippedFilesystemNames = map[string]bool{
	// pseudo filesystems and automount triggers
	"devfs":  true,
	"fdesc":  true,
	"volfs":  true,
	"autofs": true,
	// network filesystems
	"nfs":    true,
	"smbfs":  true,
	"afpfs":  true,
	"webdav": true,
	"ftp":    true,
}

func skipFilesystemName(name string) bool {
	return skippedFilesystemNames[name]
}
