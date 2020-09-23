package main

import (
	"fmt"
	"os"
	"runtime"
	"strings"
)

type Config struct {
	MaxAgeInDays   int      `yaml:"max-age" description:"Max age of collected files; older files are ignored." shorthand:"a"`
	RootPaths      []string `yaml:"path" description:"Root paths from where files should be collected." shorthand:"p"`
	FileExtensions []string `yaml:"extensions" description:"File extensions that should be collected. If left empty, all files are collected." shorthand:"e"`
	Server         string   `yaml:"thunderstorm-server" description:"Thunderstorm URL to which files should be uploaded." shorthand:"s"`
	Sync           bool     `yaml:"upload-synchronous" description:"Whether files should be uploaded synchronously to Thunderstorm."`
	Debug          bool     `yaml:"debug" description:"Print debugging information." hidden:"true"`
	Threads        int      `yaml:"threads" description:"How many threads should upload information simultaneously." shorthand:"r"`
	MaxFileSize    int64    `yaml:"max-filesize" description:"Maximum file size up to which files should be uploaded (in MB)." shorthand:"m"`
	Proxy          string   `yaml:"http-proxy" description:"Proxy that should be used for the connection to Thunderstorm.\nIf left empty, the proxy is filled from the HTTP_PROXY and HTTPS_PROXY environment variables."`
	CAs            []string `yaml:"ca" description:"Path to a PEM CA certificate that signed the HTTPS certificate of the Thunderstorm server."`
	Insecure       bool     `yaml:"insecure" description:"Don't verify the Thunderstorm certificate if HTTPS is used."`
	Logfile        string   `yaml:"logfile" description:"Write the log to this file as well." shorthand:"l"`
	Template       string   `flag:"template" description:"Process default scan parameters from this YAML file." shorthand:"t"`
	Help           bool     `flag:"help" description:"Show this help." shorthand:"h"`
}

var DefaultConfig = Config{
	Threads:     1,
	MaxFileSize: 100,
	RootPaths:   []string{getRootPath()},
}

func getRootPath() string {
	if runtime.GOOS == "windows" {
		return "C:"
	} else {
		return "/"
	}
}

func ParseConfig() Config {
	var config = DefaultConfig
	err := ReadTemplateFile(&config)
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
	if config.Help {
		flags.Usage()
		os.Exit(0)
	}
	if config.Server == "" {
		fmt.Fprintln(os.Stderr, "Thunderstorm Server URL not specified")
		os.Exit(1)
	}
	if config.Threads < 1 {
		fmt.Fprintln(os.Stderr, "Thread count must be > 0")
		os.Exit(1)
	}
	if config.MaxAgeInDays < 0 {
		fmt.Fprintln(os.Stderr, "Maximum file age must be >= 0")
		os.Exit(1)
	}
	if config.MaxFileSize < 1 {
		fmt.Fprintln(os.Stderr, "Maximum file size must be >= 0")
		flags.Usage()
		os.Exit(1)
	}
	config.Server = strings.TrimSuffix(config.Server, "/")
	return config
}
