package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// At startup the collector says which configuration file it loaded (or that it
// found none) and what the run is going to collect. Without a config.yml in the
// working directory the broad built-in defaults apply, so a run started from
// cron or by absolute path must not fall back to them silently.

const (
	configRepositoryURL = "https://github.com/NextronSystems/thunderstorm-collector"
	summaryTimeLayout   = "2006/01/02 15:04:05" // same layout as the log prefix
	bytesPerMiB         = 1024 * 1024
)

// ConfigSource records which configuration file a run used. ReadTemplateFile
// fills it in while the command line is parsed; main logs it once the log file
// is open.
type ConfigSource struct {
	Path     string // absolute path of the file that was loaded or looked up
	Explicit bool   // selected with -t/--template instead of the implicit default
	Loaded   bool   // the file was found and applied
	OpenErr  error  // why an implicit file was not used, if it could not be opened
}

var configSource ConfigSource

func absolutePath(path string) string {
	if abs, err := filepath.Abs(path); err == nil {
		return abs
	}
	return path
}

// Describe returns the log line that says where the configuration came from.
func (s ConfigSource) Describe() string {
	switch {
	case s.Path == "":
		return "No configuration file was read, using built-in defaults"
	case s.Loaded && s.Explicit:
		return fmt.Sprintf("Configuration file loaded: '%s' (selected with -t/--template)", s.Path)
	case s.Loaded:
		return fmt.Sprintf("Configuration file loaded: '%s' (default config.yml in the current working directory)", s.Path)
	case s.OpenErr != nil && !os.IsNotExist(s.OpenErr):
		return fmt.Sprintf("Configuration file '%s' could not be opened (%s), using built-in defaults", s.Path, openFailureReason(s.OpenErr))
	default:
		return fmt.Sprintf("No configuration file found at '%s' (config.yml is read from the current working directory), using built-in defaults. "+
			"Ready-made configuration files are available in the GitHub repository %s (go/config.yml; release packages ship it as config.yml) "+
			"and are selected with -t/--template", s.Path, configRepositoryURL)
	}
}

func openFailureReason(err error) string {
	if pathErr, ok := err.(*os.PathError); ok {
		return pathErr.Err.Error()
	}
	return err.Error()
}

// logStartupSummary tells the operator which configuration the run uses and
// what it is going to collect. It writes to the collector's logger so that the
// lines also reach --logfile.
func logStartupSummary(logger *log.Logger, source ConfigSource, cc CollectorConfig) {
	logger.Print(source.Describe())
	for _, line := range buildStartupSummary(cc) {
		logger.Print(line)
	}
}

// buildStartupSummary lists the settings that decide what a run collects and
// where the files go. It only formats cc, so it can be tested without running a
// collection.
func buildStartupSummary(cc CollectorConfig) []string {
	lines := []string{"=== Collection Settings ==="}
	add := func(label, value string) {
		lines = append(lines, "  - "+label+": "+value)
	}

	hasExtensions := len(cc.FileExtensions) > 0
	hasMagicHeaders := len(cc.MagicHeaders) > 0
	hasAgeLimit := !cc.ThresholdTime.IsZero()

	if len(cc.RootPaths) > 0 {
		add("Scan roots", quotedList(cc.RootPaths))
	} else {
		add("Scan roots", "none (nothing will be collected)")
	}
	add("Max file size", sizeLimit(cc.MaxFileSize))
	if hasAgeLimit {
		add("Max age", "files newer than "+cc.ThresholdTime.Format(summaryTimeLayout))
	} else {
		add("Max age", "no age limit")
	}
	switch {
	case hasExtensions:
		add("Extensions", fmt.Sprintf("%d (%s)", len(cc.FileExtensions), strings.Join(cc.FileExtensions, ", ")))
	case hasMagicHeaders:
		add("Extensions", "no filter")
	default:
		add("Extensions", "all file types")
	}
	switch {
	case !hasMagicHeaders:
		add("Magic headers", "none")
	case hasExtensions:
		add("Magic headers", fmt.Sprintf("%d (a file matching an extension or a magic header is selected)", len(cc.MagicHeaders)))
	default:
		add("Magic headers", fmt.Sprintf("%d (only files starting with one of them are selected)", len(cc.MagicHeaders)))
	}
	if len(cc.ExcludeGlobs) > 0 {
		add("Exclude globs", fmt.Sprintf("%d (%s)", len(cc.ExcludeGlobs), quotedList(cc.ExcludeGlobs)))
	} else {
		add("Exclude globs", "none")
	}
	switch {
	case cc.AllFilesystems:
		add("Filesystems", "all filesystem types are scanned (--all-filesystems)")
	case !filesystemTypesDetected:
		add("Filesystems", "all filesystem types are scanned (network and pseudo filesystems cannot be recognised on this platform)")
	default:
		add("Filesystems", "network and pseudo filesystems are skipped (--all-filesystems includes them)")
	}
	if cc.Sync {
		add("Upload mode", "synchronous")
	} else {
		add("Upload mode", "asynchronous")
	}
	add("Threads", strconv.Itoa(cc.Threads))
	if cc.DryRun {
		add("Destination", "DRY-RUN (no files are sent)")
	} else {
		add("Destination", cc.Server)
	}
	if cc.Source != "" {
		add("Source", cc.Source)
	} else {
		add("Source", "not set")
	}
	if cc.MinUploadPeriod > 0 {
		// MinUploadPeriod is a minute divided by --uploads-per-minute.
		add("Upload rate limit", fmt.Sprintf("%d uploads per minute", int64(time.Minute/cc.MinUploadPeriod)))
	}

	if len(cc.RootPaths) > 0 && !hasExtensions && !hasMagicHeaders && !hasAgeLimit {
		verb := "will be uploaded"
		if cc.DryRun {
			verb = "would be uploaded (dry-run)"
		}
		line := "No extension, magic-header or age filter is active: every regular file"
		if cc.MaxFileSize > 0 {
			line += " up to " + sizeLimit(cc.MaxFileSize)
		}
		line += " under the scan roots " + verb
		if len(cc.ExcludeGlobs) > 0 {
			line += ", except paths matching an exclude glob"
		}
		lines = append(lines, line)
	}
	return lines
}

func quotedList(items []string) string {
	quoted := make([]string, len(items))
	for i, item := range items {
		quoted[i] = "'" + item + "'"
	}
	return strings.Join(quoted, ", ")
}

func sizeLimit(bytes int64) string {
	switch {
	case bytes <= 0:
		return "no limit"
	case bytes%bytesPerMiB == 0:
		return fmt.Sprintf("%d MiB", bytes/bytesPerMiB)
	default:
		return fmt.Sprintf("%d bytes", bytes)
	}
}
