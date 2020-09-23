package main

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"time"
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

func main() {
	var config = ParseConfig()

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
	collector := NewCollector(config, logger)
	if err := collector.CheckThunderstormUp(); err != nil {
		logger.Print("Could not successfully connect to Thunderstorm")
		logger.Print(err)
		os.Exit(1)
	}
	collector.StartWorkers()
	for _, root := range config.RootPaths {
		collector.Collect(root)
	}
	collector.Stop()
}
