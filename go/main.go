package main

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

func buildHttpTransport(config Config) *http.Transport {
	caPool := x509.NewCertPool()
	for _, ca := range config.CAs {
		f, err := os.Open(ca)
		if err != nil {
			if !caPool.AppendCertsFromPEM([]byte(ca)) {
				fmt.Println(err)
				os.Exit(1)
			}
			continue
		}
		b, err := ioutil.ReadAll(f)
		f.Close()
		if err != nil {
			fmt.Println(err)
			os.Exit(1)
		}
		if !caPool.AppendCertsFromPEM(b) {
			fmt.Fprintln(os.Stderr, "Could not add CA to certificate pool")
			os.Exit(1)
		}
	}
	tlsConfig := &tls.Config{
		InsecureSkipVerify: config.Insecure,
	}
	if len(config.CAs) > 0 {
		tlsConfig.RootCAs = caPool
	}

	transport := &http.Transport{
		DialContext: (&net.Dialer{
			Timeout:   30 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		MaxIdleConns:          config.Threads,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		TLSClientConfig:       tlsConfig,
	}
	if config.Proxy != "" {
		urlProxy, err := url.Parse(config.Proxy)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Could not parse proxy URL %s\n", config.Proxy)
			os.Exit(1)
		}
		transport.Proxy = http.ProxyURL(urlProxy)
	} else {
		transport.Proxy = http.ProxyFromEnvironment
	}
	return transport
}

func validateConfig(config Config) (cc CollectorConfig, err error) {
	cc = CollectorConfig{
		RootPaths:      config.RootPaths,
		FileExtensions: config.FileExtensions,
		Sync:           config.Sync,
		Debug:          config.Debug,
		Threads:        config.Threads,
		Source:         config.Source,
	}

	if config.Threads < 1 {
		return cc, errors.New("thread count must be > 0")
	}

	if config.MaxAgeInDays != "" {
		lastChar, _ := utf8.DecodeLastRune([]byte(config.MaxAgeInDays))
		var multiplier time.Duration
		if !unicode.IsLetter(lastChar) {
			multiplier = time.Hour * 24
		} else {
			switch lastChar {
			case 's':
				multiplier = time.Second
			case 'm':
				multiplier = time.Minute
			case 'h':
				multiplier = time.Hour
			case 'd':
				multiplier = time.Hour * 24
			default:
				return cc, fmt.Errorf("invalid suffix for maximum age: %s", config.MaxAgeInDays)
			}
			config.MaxAgeInDays = config.MaxAgeInDays[:len(config.MaxAgeInDays)-1]
		}
		number, err := strconv.Atoi(config.MaxAgeInDays)
		if err != nil {
			return cc, fmt.Errorf("could not parse maximum age %s: %w", config.MaxAgeInDays, err)
		}
		cc.ThresholdTime = time.Now().Add(-1 * multiplier * time.Duration(number))
	}

	if config.MaxFileSize < 1 {
		return cc, errors.New("maximum file size must be > 0")
	}
	cc.MaxFileSize = config.MaxFileSize * 1024 * 1024

	if config.Server == "" {
		return cc, errors.New("thunderstorm Server URL not specified")
	}
	if !(strings.HasPrefix(config.Server, "http://") || strings.HasPrefix(config.Server, "https://")) {
		return cc, errors.New("missing http:// or https:// prefix in Thunderstorm URL")
	}
	if _, err := url.Parse(config.Server); err != nil {
		return cc, errors.New("URL for Thunderstorm is invalid")
	}
	cc.Server = strings.TrimSuffix(config.Server, "/")

	whitespaceRegex := regexp.MustCompile(`\s`)
	for _, hexHeader := range config.MagicHeaders {
		hexHeader = whitespaceRegex.ReplaceAllString(hexHeader, "")
		magicHeader, err := hex.DecodeString(hexHeader)
		if err != nil {
			return cc, fmt.Errorf("could not parse magic header %s: %w", hexHeader, err)
		}
		cc.MagicHeaders = append(cc.MagicHeaders, magicHeader)
	}

	return cc, nil
}

func main() {

	fmt.Println(`   ________                __            __                `)
	fmt.Println(`  /_  __/ /  __ _____  ___/ /__ _______ / /____  ______ _  `)
	fmt.Println(`   / / / _ \/ // / _ \/ _  / -_) __(_-</ __/ _ \/ __/  ' \ `)
	fmt.Println(`  /_/ /_//_/\_,_/_//_/\_,_/\__/_/ /___/\__/\___/_/ /_/_/_/ `)
	fmt.Println(`    _____     ____        __                               `)
	fmt.Println(`   / ___/__  / / /__ ____/ /____  ____                     `)
	fmt.Println(`  / /__/ _ \/ / / -_) __/ __/ _ \/ __/                     `)
	fmt.Println(`  \___/\___/_/_/\__/\__/\__/\___/_/                        `)
	fmt.Println(`                                                           `)
	fmt.Println(`  Copyright by Nextron Systems GmbH, 2020                  `)
	fmt.Println(`                                                           `)

	var config = ParseConfig()

	collectorConfig, err := validateConfig(config)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error while parsing arguments: %v", err)
		os.Exit(1)
	}

	http.DefaultTransport = buildHttpTransport(config)

	var output io.Writer
	if config.Logfile != "" {
		logfile, err := os.Create(config.Logfile)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Could not open log file %s: %v", config.Logfile, err)
			os.Exit(1)
		}
		defer logfile.Close()
		output = io.MultiWriter(os.Stdout, logfile)
	} else {
		output = os.Stdout
	}
	logger := log.New(output, "", log.Ldate|log.Ltime)
	collector := NewCollector(collectorConfig, logger)
	if err := collector.CheckThunderstormUp(); err != nil {
		logger.Print("Could not successfully connect to Thunderstorm")
		logger.Print(err)
		os.Exit(1)
	}
	if config.Debug {
		if len(collectorConfig.FileExtensions) > 0 {
			logger.Println("Collecting the following extensions:", strings.Join(collectorConfig.FileExtensions, ", "))
		}
		logger.Println("Collecting files younger than", collectorConfig.ThresholdTime.Format("02.01.2006 15:04:05"))
	}
	collector.StartWorkers()
	for _, root := range config.RootPaths {
		collector.Collect(root)
	}
	collector.Stop()
}
