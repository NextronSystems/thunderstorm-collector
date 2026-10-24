// Command thunderstorm-sftp-collector is a prototype of a pull-mode collector.
// It runs on the Thunderstorm host or on a system between the source and
// Thunderstorm, lists the source's filesystem over SFTP, selects files by the
// metadata the listing already carries (path, extension, size, modification
// time, permissions) and by a ranged read of the first bytes, and streams only
// the selected files to THOR Thunderstorm. Nothing is installed or run on the
// source besides its SFTP server.
package main

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

func main() {
	config, err := parseConfig(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	settings, err := validateConfig(config)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error while parsing arguments: %v\n", err)
		os.Exit(1)
	}
	logger := log.New(os.Stdout, "", log.Ldate|log.Ltime)

	httpClient, err := newHTTPClient(config)
	if err != nil {
		logger.Print(err)
		os.Exit(1)
	}
	if !settings.DryRun {
		if err := checkThunderstorm(httpClient, settings.StatusURL); err != nil {
			logger.Printf("Could not successfully connect to Thunderstorm: %v", err)
			os.Exit(1)
		}
	}

	sshClient, sftpClient, err := connect(config)
	if err != nil {
		logger.Print(err)
		os.Exit(1)
	}
	defer sshClient.Close()
	defer sftpClient.Close()

	var manifest *manifestWriter
	if config.Manifest != "" {
		if manifest, err = newManifestWriter(config.Manifest); err != nil {
			logger.Printf("Could not create manifest: %v", err)
			os.Exit(1)
		}
	}

	logger.Printf("Collecting from %s@%s:%d as source '%s'", config.SFTPUser, config.SFTPHost, config.SFTPPort, config.Source)
	logger.Printf("Roots: %s; excludes: %d; extensions: %d; magic headers: %d; execute bit: %t; max size: %d MB; max age: %s",
		strings.Join(settings.RootPaths, ", "), len(settings.ExcludeGlobs), len(settings.Extensions), len(settings.MagicHeaders),
		settings.Executable, config.MaxFileSizeMB, orNone(config.MaxAge))
	if settings.DryRun {
		logger.Print("DRY-RUN mode: files are selected but not sent to Thunderstorm")
	}

	collector := NewCollector(settings, sftpClient, httpClient, logger, manifest)
	collector.Run()
	if err := manifest.Close(); err != nil {
		logger.Printf("Could not write manifest: %v", err)
		collector.Stats.FileErrors++
	}
	printStatistics(logger, &collector.Stats, settings.DryRun)
	if config.StatsJSON != "" {
		data, _ := json.MarshalIndent(&collector.Stats, "", "  ")
		if err := os.WriteFile(config.StatsJSON, append(data, '\n'), 0o644); err != nil {
			logger.Printf("Could not write statistics: %v", err)
		}
	}
	if errorCount := collector.Stats.ErrorCount(); errorCount > 0 {
		logger.Printf("Collection finished with %d error(s), exiting with status 1", errorCount)
		os.Exit(1)
	}
}

func orNone(value string) string {
	if value == "" {
		return "none"
	}
	return value
}

func newHTTPClient(config Config) (*http.Client, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if config.SSL {
		tlsConfig := &tls.Config{InsecureSkipVerify: config.Insecure}
		if len(config.CAs) > 0 {
			pool := x509.NewCertPool()
			for _, ca := range config.CAs {
				pem, err := os.ReadFile(ca)
				if err != nil {
					return nil, fmt.Errorf("could not read CA %s: %v", ca, err)
				}
				if !pool.AppendCertsFromPEM(pem) {
					return nil, fmt.Errorf("no certificate found in %s", ca)
				}
			}
			tlsConfig.RootCAs = pool
		}
		transport.TLSClientConfig = tlsConfig
	}
	// Redirects are refused for the reason the Go collector gives: following
	// one replays the upload as a body-less GET.
	return &http.Client{
		Transport:     transport,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}, nil
}

func checkThunderstorm(client *http.Client, statusURL string) error {
	response, err := client.Get(statusURL)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("status page answered %d: %s", response.StatusCode, body)
	}
	return nil
}

func printStatistics(logger *log.Logger, s *Statistics, dryRun bool) {
	sentLabel := "Uploaded"
	if dryRun {
		sentLabel = "Would be sent (dry-run)"
	}
	logger.Print("")
	logger.Print("=== Collection Statistics ===")
	logger.Printf("Directories listed: %d", s.DirectoriesListed)
	logger.Printf("Files listed: %d (symlinks: %d, other non-regular: %d, excluded entries: %d)", s.FilesListed, s.Symlinks, s.Irregular, s.Excluded)
	logger.Printf("Skipped by listing: too big %d, too old %d", s.TooBig, s.TooOld)
	logger.Printf("Header checks: %d reads, %d bytes", s.HeaderReads, s.HeaderBytes)
	logger.Printf("Skipped as wrong type: %d", s.WrongType)
	logger.Printf("Selected: %d", s.Selected)
	logger.Printf("%s: %d files, %d content bytes read from the source", sentLabel, s.Uploaded, s.ContentBytes)
	logger.Printf("Errors: %d file, %d upload, %d root; unreadable directories: %d", s.FileErrors, s.UploadErrors, s.RootErrors, s.WalkErrors)
	logger.Printf("Total time: %v", (time.Duration(s.DurationSeconds * float64(time.Second))).Round(time.Millisecond))
}
