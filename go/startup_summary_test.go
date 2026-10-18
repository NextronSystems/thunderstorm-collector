package main

import (
	"bytes"
	"io"
	"io/ioutil"
	"log"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

const summaryTestMaxFileSize = 100 * 1024 * 1024

func summaryTestConfig() CollectorConfig {
	return CollectorConfig{
		RootPaths:   []string{"/"},
		MaxFileSize: summaryTestMaxFileSize,
		Threads:     1,
		Server:      "http://thunderstorm.example:8080",
		Source:      "host1",
	}
}

func containsLine(lines []string, want string) bool {
	for _, line := range lines {
		if line == want {
			return true
		}
	}
	return false
}

func TestStartupSummaryWithoutFilters(t *testing.T) {
	got := buildStartupSummary(summaryTestConfig())
	want := []string{
		"=== Collection Settings ===",
		"  - Scan roots: '/'",
		"  - Max file size: 100 MiB",
		"  - Max age: no age limit",
		"  - Extensions: all file types",
		"  - Magic headers: none",
		"  - Exclude globs: none",
		defaultFilesystemsLine(),
		"  - Upload mode: asynchronous",
		"  - Threads: 1",
		"  - Destination: http://thunderstorm.example:8080",
		"  - Source: host1",
		"No extension, magic-header or age filter is active: every regular file up to 100 MiB under the scan roots will be uploaded",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Unexpected summary.\nGot:\n%s\nWant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestStartupSummaryWithAllSettings(t *testing.T) {
	cc := summaryTestConfig()
	cc.RootPaths = []string{"/var/www", "/home/some user"}
	cc.MaxFileSize = 64 * 1024 * 1024
	cc.ThresholdTime = time.Date(2026, time.September, 17, 13, 45, 0, 0, time.UTC)
	cc.FileExtensions = []string{".exe", ".dll", ".ps1"}
	cc.MagicHeaders = [][]byte{{0x4d, 0x5a}, {0x7f, 0x45}}
	cc.ExcludeGlobs = []string{"**/node_modules/**", "/proc"}
	cc.Sync = true
	cc.Threads = 4
	cc.Server = "https://thunderstorm.example:443"
	cc.MinUploadPeriod = 2 * time.Second
	got := buildStartupSummary(cc)
	want := []string{
		"=== Collection Settings ===",
		"  - Scan roots: '/var/www', '/home/some user'",
		"  - Max file size: 64 MiB",
		"  - Max age: files newer than 2026/09/17 13:45:00",
		"  - Extensions: 3 (.exe, .dll, .ps1)",
		"  - Magic headers: 2 (a file matching an extension or a magic header is selected)",
		"  - Exclude globs: 2 ('**/node_modules/**', '/proc')",
		defaultFilesystemsLine(),
		"  - Upload mode: synchronous",
		"  - Threads: 4",
		"  - Destination: https://thunderstorm.example:443",
		"  - Source: host1",
		"  - Upload rate limit: 30 uploads per minute",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Unexpected summary.\nGot:\n%s\nWant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestStartupSummaryVariants(t *testing.T) {
	const everythingPrefix = "No extension, magic-header or age filter is active: "
	threshold := time.Date(2026, time.September, 17, 13, 45, 0, 0, time.UTC)
	testCases := []struct {
		name      string
		change    func(cc *CollectorConfig)
		wantLines []string
		// Substrings that must not appear in any line
		absent []string
	}{
		{
			name:   "dry-run",
			change: func(cc *CollectorConfig) { cc.DryRun = true; cc.Server = "dry-run://localhost" },
			wantLines: []string{
				"  - Destination: DRY-RUN (no files are sent)",
				everythingPrefix + "every regular file up to 100 MiB under the scan roots would be uploaded (dry-run)",
			},
			absent: []string{"dry-run://", "will be uploaded"},
		},
		{
			name:      "synchronous uploads",
			change:    func(cc *CollectorConfig) { cc.Sync = true },
			wantLines: []string{"  - Upload mode: synchronous"},
			absent:    []string{"asynchronous"},
		},
		{
			name:      "thread count",
			change:    func(cc *CollectorConfig) { cc.Threads = 8 },
			wantLines: []string{"  - Threads: 8"},
		},
		{
			name:      "age limit",
			change:    func(cc *CollectorConfig) { cc.ThresholdTime = threshold },
			wantLines: []string{"  - Max age: files newer than 2026/09/17 13:45:00"},
			absent:    []string{"no age limit", everythingPrefix},
		},
		{
			name:   "extensions only",
			change: func(cc *CollectorConfig) { cc.FileExtensions = []string{".php"} },
			wantLines: []string{
				"  - Extensions: 1 (.php)",
				"  - Magic headers: none",
			},
			absent: []string{"all file types", everythingPrefix},
		},
		{
			name:   "magic headers only",
			change: func(cc *CollectorConfig) { cc.MagicHeaders = [][]byte{{0x23, 0x21}} },
			wantLines: []string{
				"  - Extensions: no filter",
				"  - Magic headers: 1 (only files starting with one of them are selected)",
			},
			absent: []string{"all file types", everythingPrefix},
		},
		{
			name: "extensions and magic headers",
			change: func(cc *CollectorConfig) {
				cc.FileExtensions = []string{".php"}
				cc.MagicHeaders = [][]byte{{0x23, 0x21}, {0x4d, 0x5a}, {0x7f, 0x45}}
			},
			wantLines: []string{
				"  - Extensions: 1 (.php)",
				"  - Magic headers: 3 (a file matching an extension or a magic header is selected)",
			},
			absent: []string{everythingPrefix},
		},
		{
			name:   "excludes without filters",
			change: func(cc *CollectorConfig) { cc.ExcludeGlobs = []string{"**/sub?", "**/*.jpg"} },
			wantLines: []string{
				"  - Exclude globs: 2 ('**/sub?', '**/*.jpg')",
				everythingPrefix + "every regular file up to 100 MiB under the scan roots will be uploaded, except paths matching an exclude glob",
			},
		},
		{
			name:      "upload rate limit",
			change:    func(cc *CollectorConfig) { cc.MinUploadPeriod = time.Minute / 7 },
			wantLines: []string{"  - Upload rate limit: 7 uploads per minute"},
		},
		{
			name:      "all filesystems",
			change:    func(cc *CollectorConfig) { cc.AllFilesystems = true },
			wantLines: []string{"  - Filesystems: all filesystem types are scanned (--all-filesystems)"},
			absent:    []string{"skipped"},
		},
		{
			name:      "no source label",
			change:    func(cc *CollectorConfig) { cc.Source = "" },
			wantLines: []string{"  - Source: not set"},
		},
		{
			name:   "size limit that is not a whole number of MiB",
			change: func(cc *CollectorConfig) { cc.MaxFileSize = 14670 },
			wantLines: []string{
				"  - Max file size: 14670 bytes",
				everythingPrefix + "every regular file up to 14670 bytes under the scan roots will be uploaded",
			},
		},
		{
			name:   "no size limit",
			change: func(cc *CollectorConfig) { cc.MaxFileSize = 0 },
			wantLines: []string{
				"  - Max file size: no limit",
				everythingPrefix + "every regular file under the scan roots will be uploaded",
			},
		},
		{
			name:      "no scan roots",
			change:    func(cc *CollectorConfig) { cc.RootPaths = nil },
			wantLines: []string{"  - Scan roots: none (nothing will be collected)"},
			absent:    []string{everythingPrefix},
		},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			cc := summaryTestConfig()
			tc.change(&cc)
			lines := buildStartupSummary(cc)
			joined := strings.Join(lines, "\n")
			for _, want := range tc.wantLines {
				if !containsLine(lines, want) {
					t.Errorf("Missing line %q in summary:\n%s", want, joined)
				}
			}
			for _, unwanted := range tc.absent {
				if strings.Contains(joined, unwanted) {
					t.Errorf("Unexpected %q in summary:\n%s", unwanted, joined)
				}
			}
		})
	}
}

// The summary has to show what the collector will actually run with, so build it
// from the output of validateConfig like main does.
func TestStartupSummaryReflectsValidatedConfig(t *testing.T) {
	config := DefaultConfig
	config.RootPaths = []string{"/data"}
	config.Server = "thunderstorm.example"
	config.Port = 8443
	config.Ssl = true
	config.MaxFileSizeMB = 5
	config.MaxAgeInDays = "10h"
	config.Threads = 4
	config.UploadsPerMinute = 7
	config.Sync = true
	config.FileExtensions = []string{".exe"}
	config.MagicHeaders = []string{"4d 5a"}
	config.Source = "my source"

	cc, err := validateConfig(config)
	if err != nil {
		t.Fatal(err)
	}
	lines := buildStartupSummary(cc)
	for _, want := range []string{
		"  - Scan roots: '/data'",
		"  - Max file size: 5 MiB",
		"  - Max age: files newer than " + cc.ThresholdTime.Format(summaryTimeLayout),
		"  - Extensions: 1 (.exe)",
		"  - Magic headers: 1 (a file matching an extension or a magic header is selected)",
		"  - Upload mode: synchronous",
		"  - Threads: 4",
		"  - Destination: https://thunderstorm.example:8443",
		"  - Source: my source",
		"  - Upload rate limit: 7 uploads per minute",
	} {
		if !containsLine(lines, want) {
			t.Errorf("Missing line %q in summary:\n%s", want, strings.Join(lines, "\n"))
		}
	}

	for _, perMinute := range []int{1, 3, 7, 60, 1000} {
		config.UploadsPerMinute = perMinute
		cc, err := validateConfig(config)
		if err != nil {
			t.Fatal(err)
		}
		want := "  - Upload rate limit: " + strconv.Itoa(perMinute) + " uploads per minute"
		if lines := buildStartupSummary(cc); !containsLine(lines, want) {
			t.Errorf("--uploads-per-minute %d: missing line %q in summary:\n%s", perMinute, want, strings.Join(lines, "\n"))
		}
	}

	config.UploadsPerMinute = 0
	config.Threads = 0 // all CPU cores
	config.DryRun = true
	cc, err = validateConfig(config)
	if err != nil {
		t.Fatal(err)
	}
	lines = buildStartupSummary(cc)
	for _, want := range []string{
		"  - Threads: " + strconv.Itoa(runtime.NumCPU()),
		"  - Destination: DRY-RUN (no files are sent)",
	} {
		if !containsLine(lines, want) {
			t.Errorf("Missing line %q in summary:\n%s", want, strings.Join(lines, "\n"))
		}
	}
	if strings.Contains(strings.Join(lines, "\n"), "Upload rate limit") {
		t.Errorf("Rate limit reported although --uploads-per-minute is not set:\n%s", strings.Join(lines, "\n"))
	}
}

func TestConfigSourceDescribe(t *testing.T) {
	missing := &os.PathError{Op: "open", Path: "config.yml", Err: os.ErrNotExist}
	denied := &os.PathError{Op: "open", Path: "config.yml", Err: os.ErrPermission}
	testCases := []struct {
		name   string
		source ConfigSource
		want   []string
	}{
		{
			name:   "default file loaded",
			source: ConfigSource{Path: "/srv/collector/config.yml", Loaded: true},
			want:   []string{"Configuration file loaded: '/srv/collector/config.yml'", "default config.yml"},
		},
		{
			name:   "explicit file loaded",
			source: ConfigSource{Path: "/srv/profiles/netscaler.yml", Explicit: true, Loaded: true},
			want:   []string{"Configuration file loaded: '/srv/profiles/netscaler.yml'", "-t/--template"},
		},
		{
			name:   "default file absent",
			source: ConfigSource{Path: "/var/spool/cron/config.yml", OpenErr: missing},
			want: []string{
				"No configuration file found at '/var/spool/cron/config.yml'",
				"current working directory",
				"using built-in defaults",
				"https://github.com/NextronSystems/thunderstorm-collector",
				"go/config.yml",
				"release packages ship it as config.yml",
				"-t/--template",
			},
		},
		{
			name:   "default file not readable",
			source: ConfigSource{Path: "/srv/collector/config.yml", OpenErr: denied},
			want:   []string{"'/srv/collector/config.yml' could not be opened (permission denied)", "using built-in defaults"},
		},
		{
			name:   "nothing read",
			source: ConfigSource{},
			want:   []string{"No configuration file was read", "using built-in defaults"},
		},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			got := tc.source.Describe()
			if strings.Contains(got, "\n") {
				t.Errorf("Expected a single line, got %q", got)
			}
			for _, want := range tc.want {
				if !strings.Contains(got, want) {
					t.Errorf("Expected %q in %q", want, got)
				}
			}
		})
	}
}

func TestLogStartupSummary(t *testing.T) {
	source := ConfigSource{Path: "/srv/collector/config.yml", Loaded: true}
	for _, dryRun := range []bool{false, true} {
		cc := summaryTestConfig()
		cc.DryRun = dryRun
		// Same wiring as main: one logger that writes to the console and the log file
		var console, logfile bytes.Buffer
		logger := log.New(io.MultiWriter(&console, &logfile), "", 0)
		logStartupSummary(logger, source, cc)

		want := append([]string{source.Describe()}, buildStartupSummary(cc)...)
		for name, output := range map[string]*bytes.Buffer{"console": &console, "log file": &logfile} {
			got := strings.Split(strings.TrimSuffix(output.String(), "\n"), "\n")
			if !reflect.DeepEqual(got, want) {
				t.Errorf("dry-run=%t: unexpected %s output.\nGot:\n%s\nWant:\n%s", dryRun, name, strings.Join(got, "\n"), strings.Join(want, "\n"))
			}
		}
	}
}

// commandLine runs fn with dir as working directory and args as os.Args, which is
// what ReadTemplateFile looks at, and restores everything afterwards.
func commandLine(t *testing.T, dir string, args []string, fn func()) {
	t.Helper()
	oldDir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	oldArgs, oldSource := os.Args, configSource
	defer func() {
		os.Args, configSource = oldArgs, oldSource
		if err := os.Chdir(oldDir); err != nil {
			t.Errorf("Could not restore working directory: %v", err)
		}
	}()
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	os.Args = args
	fn()
}

func tempDirectory(t *testing.T) string {
	t.Helper()
	dir, err := ioutil.TempDir("", "collector-config-")
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

func assertSameFile(t *testing.T, got, want string) {
	t.Helper()
	if !filepath.IsAbs(got) {
		t.Errorf("Expected an absolute path, got %q", got)
	}
	gotInfo, err := os.Stat(got)
	if err != nil {
		t.Errorf("Recorded path %q does not exist: %v", got, err)
		return
	}
	wantInfo, err := os.Stat(want)
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(gotInfo, wantInfo) {
		t.Errorf("Recorded path %q is not %q", got, want)
	}
}

func TestReadTemplateFileRecordsConfigSource(t *testing.T) {
	t.Run("default config.yml present", func(t *testing.T) {
		dir := tempDirectory(t)
		defer os.RemoveAll(dir)
		configFile := filepath.Join(dir, "config.yml")
		if err := ioutil.WriteFile(configFile, []byte("max-filesize: 7\n"), 0644); err != nil {
			t.Fatal(err)
		}
		var config Config
		var err error
		var source ConfigSource
		commandLine(t, dir, []string{"collector"}, func() {
			err = ReadTemplateFile(defaultConfigFile, &config)
			source = configSource
		})
		if err != nil {
			t.Fatalf("Unexpected error: %v", err)
		}
		if config.MaxFileSizeMB != 7 {
			t.Errorf("Configuration file was not applied, max-filesize = %d", config.MaxFileSizeMB)
		}
		if !source.Loaded || source.Explicit || source.OpenErr != nil {
			t.Errorf("Unexpected source: %+v", source)
		}
		assertSameFile(t, source.Path, configFile)
		if !strings.Contains(source.Describe(), "Configuration file loaded: '"+source.Path+"'") {
			t.Errorf("Unexpected description: %s", source.Describe())
		}
	})

	t.Run("default config.yml absent is not an error", func(t *testing.T) {
		dir := tempDirectory(t)
		defer os.RemoveAll(dir)
		var config Config
		var err error
		var source ConfigSource
		commandLine(t, dir, []string{"collector"}, func() {
			err = ReadTemplateFile(defaultConfigFile, &config)
			source = configSource
		})
		if err != nil {
			t.Fatalf("A missing default config.yml must not be an error, got: %v", err)
		}
		if !reflect.DeepEqual(config, Config{}) {
			t.Errorf("Configuration was modified although no file exists: %+v", config)
		}
		if source.Loaded || source.Explicit || !os.IsNotExist(source.OpenErr) {
			t.Errorf("Unexpected source: %+v", source)
		}
		if filepath.Base(source.Path) != defaultConfigFile {
			t.Errorf("Expected the looked up path to end in %s, got %q", defaultConfigFile, source.Path)
		}
		// The directory of the looked up path is the working directory
		assertSameFile(t, filepath.Dir(source.Path), dir)
		if description := source.Describe(); !strings.Contains(description, "No configuration file found at '"+source.Path+"'") {
			t.Errorf("Unexpected description: %s", description)
		}
	})

	t.Run("default config.yml that cannot be parsed is still an error", func(t *testing.T) {
		dir := tempDirectory(t)
		defer os.RemoveAll(dir)
		if err := ioutil.WriteFile(filepath.Join(dir, "config.yml"), []byte("no-such-setting: 1\n"), 0644); err != nil {
			t.Fatal(err)
		}
		var config Config
		var err error
		var source ConfigSource
		commandLine(t, dir, []string{"collector"}, func() {
			err = ReadTemplateFile(defaultConfigFile, &config)
			source = configSource
		})
		if err == nil || !strings.Contains(err.Error(), "could not be parsed") {
			t.Errorf("Expected a parse error, got: %v", err)
		}
		if source.Loaded {
			t.Errorf("A file that failed to parse must not be reported as loaded: %+v", source)
		}
	})

	t.Run("default config.yml that cannot be opened", func(t *testing.T) {
		if runtime.GOOS == "windows" || os.Geteuid() == 0 {
			t.Skip("file permissions do not prevent reading here")
		}
		dir := tempDirectory(t)
		defer os.RemoveAll(dir)
		configFile := filepath.Join(dir, "config.yml")
		if err := ioutil.WriteFile(configFile, []byte("max-filesize: 7\n"), 0644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(configFile, 0); err != nil {
			t.Fatal(err)
		}
		var config Config
		var err error
		var source ConfigSource
		commandLine(t, dir, []string{"collector"}, func() {
			err = ReadTemplateFile(defaultConfigFile, &config)
			source = configSource
		})
		if err != nil {
			t.Fatalf("Unexpected error: %v", err)
		}
		if source.Loaded || source.OpenErr == nil || os.IsNotExist(source.OpenErr) {
			t.Errorf("Unexpected source: %+v", source)
		}
		if description := source.Describe(); !strings.Contains(description, "could not be opened (permission denied)") || strings.Contains(description, "No configuration file found") {
			t.Errorf("Unexpected description: %s", description)
		}
	})

	t.Run("explicit template present", func(t *testing.T) {
		configDir, workDir := tempDirectory(t), tempDirectory(t)
		defer os.RemoveAll(configDir)
		defer os.RemoveAll(workDir)
		configFile := filepath.Join(configDir, "profile.yml")
		if err := ioutil.WriteFile(configFile, []byte("max-filesize: 9\n"), 0644); err != nil {
			t.Fatal(err)
		}
		// A config.yml in the working directory must not be used when -t is given
		if err := ioutil.WriteFile(filepath.Join(workDir, "config.yml"), []byte("max-filesize: 1\n"), 0644); err != nil {
			t.Fatal(err)
		}
		var config Config
		var err error
		var source ConfigSource
		commandLine(t, workDir, []string{"collector", "-t", configFile}, func() {
			err = ReadTemplateFile(defaultConfigFile, &config)
			source = configSource
		})
		if err != nil {
			t.Fatalf("Unexpected error: %v", err)
		}
		if config.MaxFileSizeMB != 9 {
			t.Errorf("Explicit template was not applied, max-filesize = %d", config.MaxFileSizeMB)
		}
		if !source.Loaded || !source.Explicit || source.OpenErr != nil {
			t.Errorf("Unexpected source: %+v", source)
		}
		assertSameFile(t, source.Path, configFile)
		if !strings.Contains(source.Describe(), "(selected with -t/--template)") {
			t.Errorf("Unexpected description: %s", source.Describe())
		}
	})

	t.Run("explicit template absent is still an error", func(t *testing.T) {
		dir := tempDirectory(t)
		defer os.RemoveAll(dir)
		// The default file exists, but an explicit template must not fall back to it
		if err := ioutil.WriteFile(filepath.Join(dir, "config.yml"), []byte("max-filesize: 1\n"), 0644); err != nil {
			t.Fatal(err)
		}
		var config Config
		var err error
		var source ConfigSource
		commandLine(t, dir, []string{"collector", "--template", "missing.yml"}, func() {
			err = ReadTemplateFile(defaultConfigFile, &config)
			source = configSource
		})
		if err == nil {
			t.Fatal("Expected an error for a missing explicit template")
		}
		if !strings.Contains(err.Error(), "missing.yml") || !strings.Contains(err.Error(), "could not be opened") {
			t.Errorf("Unexpected error: %v", err)
		}
		if config.MaxFileSizeMB != 0 {
			t.Errorf("Default file was applied although -t was given: %+v", config)
		}
		if source.Loaded || !source.Explicit {
			t.Errorf("Unexpected source: %+v", source)
		}
	})
}

// defaultFilesystemsLine is the Filesystems line of a run without --all-filesystems on the platform running the tests.
func defaultFilesystemsLine() string {
	if filesystemTypesDetected {
		return "  - Filesystems: network and pseudo filesystems are skipped (--all-filesystems includes them)"
	}
	return "  - Filesystems: all filesystem types are scanned (network and pseudo filesystems cannot be recognised on this platform)"
}

func TestStartupSummaryDoesNotClaimFilesystemSkippingWithoutDetection(t *testing.T) {
	previous := filesystemTypesDetected
	defer func() { filesystemTypesDetected = previous }()

	filesystemTypesDetected = false
	want := "  - Filesystems: all filesystem types are scanned (network and pseudo filesystems cannot be recognised on this platform)"
	if got := summaryLine(buildStartupSummary(summaryTestConfig()), "  - Filesystems:"); got != want {
		t.Errorf("platform without filesystem detection: got %q, want %q", got, want)
	}

	filesystemTypesDetected = true
	want = "  - Filesystems: network and pseudo filesystems are skipped (--all-filesystems includes them)"
	if got := summaryLine(buildStartupSummary(summaryTestConfig()), "  - Filesystems:"); got != want {
		t.Errorf("platform with filesystem detection: got %q, want %q", got, want)
	}

	cc := summaryTestConfig()
	cc.AllFilesystems = true
	filesystemTypesDetected = false
	want = "  - Filesystems: all filesystem types are scanned (--all-filesystems)"
	if got := summaryLine(buildStartupSummary(cc), "  - Filesystems:"); got != want {
		t.Errorf("--all-filesystems must win on every platform: got %q, want %q", got, want)
	}
}

func summaryLine(lines []string, prefix string) string {
	for _, line := range lines {
		if strings.HasPrefix(line, prefix) {
			return line
		}
	}
	return ""
}
