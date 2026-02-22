package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

const (
	envRunBinarySubmissionTest = "THUNDERSTORM_RUN_BINARY_SUBMISSION_TEST"
	envTestServerURL           = "THUNDERSTORM_TEST_SERVER_URL"
	envSampleURL               = "THUNDERSTORM_TEST_SAMPLE_URL"
	envExpectedRule            = "THUNDERSTORM_EXPECTED_RULE"

	defaultSampleURL  = "https://github.com/TwoSevenOneT/EDR-Freeze/releases/download/v1.0-fbd43cf/EDRFreeze-msvc.exe"
	defaultRuleName   = "SIGNATURE_BASE_HKTL_EDR_Freeze_Sep25_2"
	defaultSourceName = "collector-binary-e2e"
)

// TestBinarySubmissionEDRFreeze is an opt-in end-to-end test that verifies:
// 1. The collector can download and submit a real-world PE binary intact
// 2. The server-side scan response references the expected rule name
// 3. The response includes the uploaded file's SHA-256
//
// This test is skipped by default. Enable it with:
// THUNDERSTORM_RUN_BINARY_SUBMISSION_TEST=1
// THUNDERSTORM_TEST_SERVER_URL=http://127.0.0.1:8080
func TestBinarySubmissionEDRFreeze(t *testing.T) {
	if os.Getenv(envRunBinarySubmissionTest) != "1" {
		t.Skipf("Set %s=1 to run this external integration test", envRunBinarySubmissionTest)
	}

	serverURL := os.Getenv(envTestServerURL)
	if serverURL == "" {
		t.Skipf("Set %s (e.g. http://127.0.0.1:8080)", envTestServerURL)
	}

	sampleURL := os.Getenv(envSampleURL)
	if sampleURL == "" {
		sampleURL = defaultSampleURL
	}
	expectedRule := os.Getenv(envExpectedRule)
	if expectedRule == "" {
		expectedRule = defaultRuleName
	}

	workDir, err := ioutil.TempDir("", "collector-binary-submission-*")
	if err != nil {
		t.Fatalf("Could not create temp directory: %v", err)
	}
	defer os.RemoveAll(workDir)

	samplePath := filepath.Join(workDir, "EDRFreeze-msvc.exe")
	sampleSHA256, err := downloadFileWithSHA256(sampleURL, samplePath)
	if err != nil {
		t.Fatalf("Could not download sample from %s: %v", sampleURL, err)
	}

	var logs bytes.Buffer
	logger := log.New(&logs, "", 0)
	collector := NewCollector(CollectorConfig{
		RootPaths:      []string{workDir},
		FileExtensions: []string{".exe"},
		Server:         serverURL,
		Sync:           true,
		Threads:        1,
		Source:         defaultSourceName,
	}, logger)

	collector.StartWorkers()
	collector.Collect()
	collector.Stop()

	uploaded := atomic.LoadInt64(&collector.Statistics.uploadedFiles)
	uploadErrors := atomic.LoadInt64(&collector.Statistics.uploadErrors)
	fileErrors := atomic.LoadInt64(&collector.Statistics.fileErrors)

	if uploaded != 1 {
		t.Fatalf("Expected one uploaded file, got %d\nLogs:\n%s", uploaded, logs.String())
	}
	if uploadErrors != 0 || fileErrors != 0 {
		t.Fatalf("Expected zero upload/read errors, got uploadErrors=%d fileErrors=%d\nLogs:\n%s", uploadErrors, fileErrors, logs.String())
	}

	logOutput := strings.ToLower(logs.String())
	if !strings.Contains(logOutput, strings.ToLower(expectedRule)) {
		t.Fatalf("Expected server response to contain rule %q\nLogs:\n%s", expectedRule, logs.String())
	}
	if !strings.Contains(logOutput, strings.ToLower(sampleSHA256)) {
		t.Fatalf("Expected server response to contain sample SHA-256 %q\nLogs:\n%s", sampleSHA256, logs.String())
	}
}

func downloadFileWithSHA256(sampleURL, destination string) (string, error) {
	resp, err := http.Get(sampleURL)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("unexpected status code %d", resp.StatusCode)
	}

	targetFile, err := os.Create(destination)
	if err != nil {
		return "", err
	}
	defer targetFile.Close()

	hash := sha256.New()
	writer := io.MultiWriter(targetFile, hash)
	if _, err := io.Copy(writer, resp.Body); err != nil {
		return "", err
	}

	return hex.EncodeToString(hash.Sum(nil)), nil
}

