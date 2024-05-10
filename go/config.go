package main

import (
	"fmt"
	"os"
	"runtime"
)

type Config struct {
	MaxAgeInDays     string   `yaml:"max-age" description:"Max age of collected files. Files with older modification date are ignored.\nUnit can be specified using a suffix: s for seconds, m for minutes, h for hour, d for day and defaults to days.\nExample: --max-age 10h" shorthand:"a"`
	RootPaths        []string `yaml:"path" description:"Root paths from where files should be collected.\nSpecify multiple root paths by using this flag multiple times." shorthand:"p"`
	FileExtensions   []string `yaml:"extension" description:"File extensions that should be collected. If left empty, file extensions are ignored.\nSpecify multiple extensions by using this flag multiple times.\nExample: -e .exe -e .dll" shorthand:"e"`
	ExcludeGlobs     []string `yaml:"exclude" description:"Paths that should be excluded. Supports globbing with ?, * and **.\nSpecify multiple excludes by using this flag multiple times.\nExample: --exclude C:\\tools --exclude C:\\Users\\**\\.git\\**"`
	Server           string   `yaml:"thunderstorm-server" shorthand:"s" description:"FQDN or IP of the Thunderstorm Server to which files should be uploaded.\nExamples: --thunderstorm-server my.thunderstorm, --thunderstorm-server 127.0.0.1"`
	Port             int      `yaml:"port" description:"Port on the Thunderstorm Server to which files should be uploaded."`
	Ssl              bool     `yaml:"ssl" description:"If true, connect to the Thunderstorm Server using HTTPS instead of HTTP."`
	Sync             bool     `yaml:"upload-synchronous" description:"Whether files should be uploaded synchronously to Thunderstorm. If yes, the collector takes longer, but displays the results of all scanned files."`
	Debug            bool     `yaml:"debug" description:"Print debugging information."`
	Threads          int      `yaml:"threads" description:"How many threads should upload files simultaneously." shorthand:"r"`
	MaxFileSize      int64    `yaml:"max-filesize" description:"Maximum file size up to which files should be uploaded (in MB)." shorthand:"m"`
	Proxy            string   `yaml:"http-proxy" description:"Proxy that should be used for the connection to Thunderstorm.\nIf left empty, the proxy is filled from the HTTP_PROXY and HTTPS_PROXY environment variables."`
	CAs              []string `yaml:"ca" description:"Path to a PEM CA certificate that signed the HTTPS certificate of the Thunderstorm server.\nSpecify multiple CAs by using this flag multiple times."`
	Insecure         bool     `yaml:"insecure" description:"Don't verify the Thunderstorm certificate if HTTPS is used."`
	Logfile          string   `yaml:"logfile" description:"Write the log to this file as well as to the console." shorthand:"l"`
	Source           string   `yaml:"source" description:"Name for this device in the Thunderstorm log messages." shorthand:"o"`
	MagicHeaders     []string `yaml:"magic" description:"Magic Header (bytes at file start) that should be collected, written as hex bytes. If left empty, magic headers are ignored.\nSpecify multiple wanted Magic Headers by using this flag multiple times.\nExample: --magic 4d5a --magic cffa"`
	AllFilesystems   bool     `yaml:"all-filesystems" description:"Ignore filesystem types. By default, the collector doesn't collect files from network mounts or special filesystems; with this flag, files are collected regardless of the underlying filesystem type.'"`
	UploadsPerMinute int      `yaml:"uploads-per-minute" description:"Delay uploads to only upload samples with the given frequency of uploads per minute. Zero means no delays."`
	MinCacheFileSize int64    `yaml:"min-cache-file-size" description:"Upload files with at least the given size (in MB) only once, skipping them when re-encountering them."`
	Template         string   `flag:"template" description:"Process default scan parameters from this YAML file." shorthand:"t"`
	Help             bool     `flag:"help" description:"Show this help." shorthand:"h"`
}

var DefaultConfig = Config{
	Threads:          1,
	MaxFileSize:      100,
	Port:             8080,
	RootPaths:        []string{getRootPath()},
	Source:           HostnameOrBlank(),
	MinCacheFileSize: 100,
	Template:         defaultConfigFile,
}

func HostnameOrBlank() string {
	hostname, _ := os.Hostname()
	return hostname
}

func getRootPath() string {
	if runtime.GOOS == "windows" {
		return "C:\\"
	} else {
		return "/"
	}
}

var defaultConfigFile = "config.yml"

func ParseConfig() Config {
	var config = DefaultConfig
	err := ReadTemplateFile(DefaultConfig.Template, &config)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	flags := CreateFlagset(&config)
	flags.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: %s [OPTION]...\n", os.Args[0])
		flags.PrintDefaults()
	}
	err = flags.Parse(os.Args)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		flags.Usage()
		os.Exit(1)
	}
	if config.Help || (len(os.Args) == 1 && config.Server == "") {
		flags.Usage()
		os.Exit(0)
	}
	return config
}
