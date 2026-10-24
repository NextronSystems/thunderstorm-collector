package main

import (
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/pflag"
	"gopkg.in/yaml.v3"
)

// Config holds the options. The filter and Thunderstorm keys use the names of
// the Go collector's config.yml, so its bundled profile loads with -t; keys
// that only make sense on the source system (all-filesystems, logfile, ...)
// are ignored.
type Config struct {
	SFTPHost   string `yaml:"sftp-host"`
	SFTPPort   int    `yaml:"sftp-port"`
	SFTPUser   string `yaml:"sftp-user"`
	SFTPKey    string `yaml:"sftp-key"`
	KnownHosts string `yaml:"known-hosts"`

	RootPaths      []string `yaml:"path"`
	FileExtensions []string `yaml:"extension"`
	MagicHeaders   []string `yaml:"magic"`
	Executable     bool     `yaml:"executable"`
	ExcludeGlobs   []string `yaml:"exclude"`
	MaxFileSizeMB  int64    `yaml:"max-filesize"`
	MaxAge         string   `yaml:"max-age"`

	Server   string   `yaml:"thunderstorm-server"`
	Port     int      `yaml:"port"`
	SSL      bool     `yaml:"ssl"`
	CAs      []string `yaml:"ca"`
	Insecure bool     `yaml:"insecure"`
	Source   string   `yaml:"source"`
	Sync     bool     `yaml:"upload-synchronous"`

	Threads     int    `yaml:"threads"`
	WalkThreads int    `yaml:"walk-threads"`
	DryRun      bool   `yaml:"dry-run"`
	Debug       bool   `yaml:"debug"`
	Manifest    string `yaml:"manifest"`
	StatsJSON   string `yaml:"stats-json"`
}

func defaultConfig() Config {
	config := Config{
		SFTPPort:      22,
		SFTPUser:      os.Getenv("USER"),
		RootPaths:     []string{"/"},
		MaxFileSizeMB: 100,
		Port:          8080,
		Threads:       4,
		WalkThreads:   4,
	}
	if home, err := os.UserHomeDir(); err == nil {
		config.KnownHosts = filepath.Join(home, ".ssh", "known_hosts")
	}
	return config
}

// templateArgument returns the value of -t/--template, which must be read
// before the other flags so that command-line values override the file.
func templateArgument(args []string) string {
	for i, arg := range args {
		switch {
		case (arg == "-t" || arg == "--template") && i+1 < len(args):
			return args[i+1]
		case strings.HasPrefix(arg, "--template="):
			return strings.TrimPrefix(arg, "--template=")
		}
	}
	return ""
}

func parseConfig(args []string) (Config, error) {
	config := defaultConfig()
	if template := templateArgument(args); template != "" {
		data, err := os.ReadFile(template)
		if err != nil {
			return config, fmt.Errorf("could not read template: %v", err)
		}
		if err := yaml.Unmarshal(data, &config); err != nil {
			return config, fmt.Errorf("could not parse template %s: %v", template, err)
		}
	}

	flags := pflag.NewFlagSet("thunderstorm-sftp-collector", pflag.ContinueOnError)
	flags.SortFlags = false
	var template string
	var help bool
	flags.StringVarP(&template, "template", "t", "", "Load options from this YAML file (the Go collector's config.yml keys are accepted).")
	flags.StringVar(&config.SFTPHost, "sftp-host", config.SFTPHost, "Host name or IP of the system to collect from.")
	flags.IntVar(&config.SFTPPort, "sftp-port", config.SFTPPort, "SSH port of that system.")
	flags.StringVar(&config.SFTPUser, "sftp-user", config.SFTPUser, "SSH user.")
	flags.StringVar(&config.SFTPKey, "sftp-key", config.SFTPKey, "Private key file (unencrypted). Without it, keys from ssh-agent (SSH_AUTH_SOCK) are used.")
	flags.StringVar(&config.KnownHosts, "known-hosts", config.KnownHosts, "known_hosts file used to verify the host key. Unknown or changed keys abort the run.")
	flags.StringArrayVarP(&config.RootPaths, "path", "p", config.RootPaths, "Remote root path to collect from. Repeat for several paths.")
	flags.StringArrayVarP(&config.FileExtensions, "extension", "e", config.FileExtensions, "Collect files with this extension, e.g. -e .php. Repeat for several.")
	flags.StringArrayVar(&config.MagicHeaders, "magic", config.MagicHeaders, "Collect files whose first bytes match this hex value, e.g. --magic 7f454c46. Repeat for several.")
	flags.BoolVar(&config.Executable, "executable", config.Executable, "Collect files with an execute permission bit set, whatever their extension or header.")
	flags.StringArrayVar(&config.ExcludeGlobs, "exclude", config.ExcludeGlobs, "Remote path to exclude, with ?, * and ** globbing. Repeat for several.")
	flags.Int64VarP(&config.MaxFileSizeMB, "max-filesize", "m", config.MaxFileSizeMB, "Maximum file size in MB.")
	flags.StringVarP(&config.MaxAge, "max-age", "a", config.MaxAge, "Only collect files modified within this time. Suffix s, m, h or d; default unit is days. SFTP reports the modification time only.")
	flags.StringVarP(&config.Server, "thunderstorm-server", "s", config.Server, "Thunderstorm server host name or IP.")
	flags.IntVar(&config.Port, "port", config.Port, "Thunderstorm server port.")
	flags.BoolVar(&config.SSL, "ssl", config.SSL, "Use HTTPS for Thunderstorm.")
	flags.StringArrayVar(&config.CAs, "ca", config.CAs, "PEM CA certificate for the Thunderstorm HTTPS certificate. Repeat for several.")
	flags.BoolVar(&config.Insecure, "insecure", config.Insecure, "Don't verify the Thunderstorm HTTPS certificate.")
	flags.StringVarP(&config.Source, "source", "o", config.Source, "Source name reported to Thunderstorm (default: the SFTP host).")
	flags.BoolVar(&config.Sync, "upload-synchronous", config.Sync, "Use /api/check and log each result instead of /api/checkAsync.")
	flags.IntVarP(&config.Threads, "threads", "r", config.Threads, "Parallel header checks and uploads.")
	flags.IntVar(&config.WalkThreads, "walk-threads", config.WalkThreads, "Parallel directory listings.")
	flags.BoolVar(&config.DryRun, "dry-run", config.DryRun, "Select files but upload nothing.")
	flags.BoolVar(&config.Debug, "debug", config.Debug, "Log the decision for every file.")
	flags.StringVar(&config.Manifest, "manifest", config.Manifest, "Write every listed entry with its metadata and decision to this JSONL file.")
	flags.StringVar(&config.StatsJSON, "stats-json", config.StatsJSON, "Write the run statistics to this JSON file.")
	flags.BoolVarP(&help, "help", "h", false, "Show this help.")
	if err := flags.Parse(args); err != nil {
		return config, err
	}
	if help {
		fmt.Fprintf(os.Stderr, "Usage: thunderstorm-sftp-collector --sftp-host HOST -s THUNDERSTORM [OPTION]...\n")
		flags.PrintDefaults()
		os.Exit(0)
	}
	if extra := flags.Args(); len(extra) > 0 {
		return config, fmt.Errorf("unexpected argument(s): %s", strings.Join(extra, " "))
	}
	if config.Source == "" {
		config.Source = config.SFTPHost
	}
	return config, nil
}

// Settings is the validated form of Config used by the collector.
type Settings struct {
	RootPaths    []string
	Extensions   []string
	MagicHeaders [][]byte
	Executable   bool
	ExcludeGlobs []string
	MaxFileSize  int64
	Threshold    time.Time
	Threads      int
	WalkThreads  int
	DryRun       bool
	Debug        bool
	Sync         bool
	UploadURL    string
	StatusURL    string
}

var whitespace = regexp.MustCompile(`\s+`)

func validateConfig(config Config) (Settings, error) {
	var settings Settings
	if config.SFTPHost == "" {
		return settings, errors.New("sftp-host: not specified")
	}
	if config.Server == "" && !config.DryRun {
		return settings, errors.New("thunderstorm-server: not specified (required unless using --dry-run)")
	}
	if config.MaxFileSizeMB < 1 {
		return settings, errors.New("max-filesize: must be > 0")
	}
	if config.Threads < 1 || config.WalkThreads < 1 {
		return settings, errors.New("threads and walk-threads: must be > 0")
	}
	if len(config.RootPaths) == 0 {
		return settings, errors.New("path: no root path given")
	}
	if config.MaxAge != "" {
		threshold, err := parseMaxAge(config.MaxAge)
		if err != nil {
			return settings, err
		}
		settings.Threshold = threshold
	}
	for _, extension := range config.FileExtensions {
		settings.Extensions = append(settings.Extensions, strings.ToLower(extension))
	}
	for _, hexHeader := range config.MagicHeaders {
		header, err := hex.DecodeString(whitespace.ReplaceAllString(hexHeader, ""))
		if err != nil || len(header) == 0 {
			return settings, fmt.Errorf("could not parse magic header %q", hexHeader)
		}
		settings.MagicHeaders = append(settings.MagicHeaders, header)
	}
	settings.RootPaths = config.RootPaths
	settings.Executable = config.Executable
	settings.ExcludeGlobs = config.ExcludeGlobs
	settings.MaxFileSize = config.MaxFileSizeMB * 1024 * 1024
	settings.Threads = config.Threads
	settings.WalkThreads = config.WalkThreads
	settings.DryRun = config.DryRun
	settings.Debug = config.Debug
	settings.Sync = config.Sync

	scheme := "http"
	if config.SSL {
		scheme = "https"
	}
	base := fmt.Sprintf("%s://%s", scheme, net.JoinHostPort(config.Server, strconv.Itoa(config.Port)))
	endpoint := "checkAsync"
	if config.Sync {
		endpoint = "check"
	}
	settings.UploadURL = fmt.Sprintf("%s/api/%s?source=%s", base, endpoint, url.QueryEscape(config.Source))
	settings.StatusURL = base + "/api/status"
	return settings, nil
}

// parseMaxAge follows the Go collector: a number with an optional s, m, h or d
// suffix, in days without one.
func parseMaxAge(value string) (time.Time, error) {
	units := map[byte]time.Duration{'s': time.Second, 'm': time.Minute, 'h': time.Hour, 'd': 24 * time.Hour}
	suffix := value[len(value)-1]
	number, multiplier := value, 24*time.Hour
	if unit, ok := units[suffix]; ok {
		number, multiplier = value[:len(value)-1], unit
	} else if suffix < '0' || suffix > '9' {
		return time.Time{}, fmt.Errorf("max-age: invalid suffix '%c' in %s (supported: s, m, h, d)", suffix, value)
	}
	count, err := strconv.Atoi(number)
	if err != nil {
		return time.Time{}, fmt.Errorf("max-age: could not parse number from %s: %v", value, err)
	}
	return time.Now().Add(-time.Duration(count) * multiplier), nil
}
