package main

import (
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"mime"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
	"github.com/google/uuid"
)

type filedata struct {
	path    string
	content []byte
}

func (f filedata) String() string {
	return fmt.Sprintf("%s: %s", f.path, PrettyPrintBytes(f.content))
}

func PrettyPrintBytes(b []byte) string {
	const maxLen = 40
	var curLen = len(b)
	ellipsis := ""
	if len(b) > maxLen {
		ellipsis = "..."
		curLen = maxLen
	}
	return fmt.Sprintf("%[1]q%[2]s (%[1]v%[2]s)", b[:curLen], ellipsis)
}

func getFileName(file *multipart.Part) string {
	var fileName string
	disposition := file.Header.Get("Content-Disposition")
	_, dispositionParams, err := mime.ParseMediaType(disposition)
	if err == nil {
		fileName = dispositionParams["filename"]
	}
	return fileName
}
func collectSendAndReceive(cc CollectorConfig, t *testing.T) ([]filedata, CollectionStatistics) {
	receivedFiles := make([]filedata, 0)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reader, err := r.MultipartReader()
		if err != nil {
			t.Fatalf("No multipart form received")
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		part, err := reader.NextPart()
		if err == io.EOF {
			t.Fatalf("No file received")
			http.Error(w, "No file received", http.StatusBadRequest)
			return
		} else if err != nil {
			t.Fatalf("Invalid multipart form")
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if part.FormName() != "file" {
			t.Fatalf("Received upload with form name other than file")
			http.Error(w, "Please use \"file\" as name for your upload", http.StatusBadRequest)
			return
		}
		receivedFile := filedata{path: getFileName(part)}
		receivedFile.content, err = ioutil.ReadAll(part)
		if err != nil {
			t.Fatalf("Failed to read multipart file")
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		receivedFiles = append(receivedFiles, receivedFile)

		if err := json.NewEncoder(w).Encode(map[string]interface{}{"id": uuid.New().String()}); err != nil {
			t.Fatalf("Failed to write JSON response")
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}))
	defer ts.Close()

	logger := log.New(os.Stdout, "", log.Ldate|log.Ltime)
	cc.Server = ts.URL
	cc.Threads = 1
	cc.Debug = true
	c := NewCollector(cc, logger)
	c.StartWorkers()
	c.Collect()
	c.Stop()

	return receivedFiles, *c.Statistics
}

func TestUpload(t *testing.T) {
	testStartTime := time.Now()
	testRoot := "testdata"

	_ = os.Chtimes(filepath.Join(testRoot, "foo.txt"), time.Time{}, time.Now().Local()) // Touch

	testCases := []struct {
		name               string
		cc                 CollectorConfig
		expectedFilesFound []filedata
		expectedStats      CollectionStatistics
	}{
		{
			"with excludes",
			CollectorConfig{
				RootPaths:    []string{testRoot},
				ExcludeGlobs: []string{"**/sub?", "**/*.jpg"},
			},
			[]filedata{
				{"foo.txt", []byte("foo\n")},
			},
			CollectionStatistics{
				uploadedFiles:      1,
				skippedFiles:       1,
				skippedDirectories: 2,
			},
		},
		{
			"with extensions",
			CollectorConfig{
				RootPaths:      []string{testRoot},
				FileExtensions: []string{".nfo"},
			},
			[]filedata{
				{"sub2/bar.nfo", []byte("bar\n")},
			},
			CollectionStatistics{
				uploadedFiles: 1,
				skippedFiles:  3,
			},
		},
		{
			"with magic",
			CollectorConfig{
				RootPaths:    []string{testRoot},
				MagicHeaders: [][]byte{{0xff, 0xd8, 0xff}},
			},
			[]filedata{
				{"nextron250.jpg", func() []byte { b, _ := ioutil.ReadFile("testdata/nextron250.jpg"); return b }()},
			},
			CollectionStatistics{
				uploadedFiles: 1,
				skippedFiles:  3,
			},
		},
		{
			"with max age",
			CollectorConfig{
				RootPaths:     []string{testRoot},
				ThresholdTime: testStartTime,
			},
			[]filedata{
				{"foo.txt", []byte("foo\n")},
			},
			CollectionStatistics{
				uploadedFiles: 1,
				skippedFiles:  3,
			},
		},
		{
			"with max size",
			CollectorConfig{
				RootPaths:      []string{testRoot},
				FileExtensions: []string{".jpg"},
				MaxFileSize:    14670,
			},
			[]filedata{},
			CollectionStatistics{
				skippedFiles: 4,
			},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			receivedFiles, stats := collectSendAndReceive(tc.cc, t)

			if len(receivedFiles) != len(tc.expectedFilesFound) {
				t.Fatalf("Expected to receive %d files, but received %d", len(tc.expectedFilesFound), len(receivedFiles))
			}
			if diff := cmp.Diff(tc.expectedStats, stats, cmp.Exporter(func(_ reflect.Type) bool { return true })); diff != "" {
				t.Fatalf("Statistics mismatch: %s", diff)
			}
			for _, expected := range tc.expectedFilesFound {
				t.Run(fmt.Sprintf("File %s", expected.path), func(t *testing.T) {
					found := false
					expectedPathRel := filepath.Join(testRoot, expected.path)
					expectedPathAbs, _ := filepath.Abs(expectedPathRel)
					for _, received := range receivedFiles {
						if received.path == expectedPathAbs {
							if !cmp.Equal(received.content, expected.content) {
								t.Fatalf("Content mismatch for file %s.\nExpected: %s\nGot: %s", received.path, PrettyPrintBytes(expected.content), PrettyPrintBytes(received.content))
							}
							found = true
							break
						}
					}
					if !found {
						t.Fatalf("Expected file %s not found in: %s", expectedPathAbs, receivedFiles)
					}
				})
			}
		})
	}
}

func TestCollect(t *testing.T) {
	testRoot := "testdata"
	cc := CollectorConfig{
		RootPaths:    []string{testRoot},
		ExcludeGlobs: []string{"**/sub1", "**/*.jpg"},
	}
	expectedFilesFound := []string{
		"foo.txt",
		"sub2/bar.nfo",
	}
	logger := log.New(os.Stdout, "", log.Ldate|log.Ltime)
	c := NewCollector(cc, logger)
	c.filesToUpload = make(chan infoWithPath)

	var listenerThreadClosed = make(chan struct{})
	var collectedFiles []infoWithPath
	go func() {
		for incFile := range c.filesToUpload {
			collectedFiles = append(collectedFiles, incFile)
		}
		close(listenerThreadClosed)
	}()
	c.Collect()
	close(c.filesToUpload)
	<-listenerThreadClosed

	numFound := 0
	for _, collected := range collectedFiles {
		for _, expected := range expectedFilesFound {
			if collected.path == filepath.Join(testRoot, expected) {
				numFound++
			}
		}
	}
	if numFound != len(collectedFiles) {
		t.Fatalf("Expected to collect %d files, but collected %d. Expected: %v. Collected: %v", len(expectedFilesFound), len(collectedFiles), expectedFilesFound, collectedFiles)
	}
	if numFound != len(expectedFilesFound) {
		t.Fatalf("Expected to find %d files, but found %d. Expected: %v. Found: %v", len(expectedFilesFound), numFound, expectedFilesFound, collectedFiles)
	}
}
