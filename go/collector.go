package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"mime/multipart"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/bmatcuk/doublestar/v3"
)

type CollectorConfig struct {
	ThresholdTime   time.Time
	RootPaths       []string
	FileExtensions  []string
	ExcludeGlobs    []string
	Server          string
	Sync            bool
	Debug           bool
	Threads         int
	MaxFileSize     int64
	Source          string
	MagicHeaders    [][]byte
	AllFilesystems  bool
	MinUploadPeriod time.Duration

	MinCacheFileSize int64
}

type Collector struct {
	CollectorConfig

	logger *log.Logger

	workerGroup   *sync.WaitGroup
	filesToUpload chan infoWithPath

	Statistics *CollectionStatistics

	magicHeaderExtractionLength int

	throttleMutex sync.Mutex
	lastScanTime  time.Time

	fileHashCache *sync.Map
}

type CollectionStatistics struct {
	uploadedFiles      int64
	skippedFiles       int64
	skippedDirectories int64
	uploadErrors       int64
	fileErrors         int64
}

func NewCollector(config CollectorConfig, logger *log.Logger) *Collector {
	collector := &Collector{
		CollectorConfig: config,
		logger:          logger,
		Statistics:      &CollectionStatistics{},
		fileHashCache:   &sync.Map{},
	}
	for _, header := range config.MagicHeaders {
		if len(header) > collector.magicHeaderExtractionLength {
			collector.magicHeaderExtractionLength = len(header)
		}
	}
	return collector
}

// debugf calls logger.Printf if and only if debugging is enabled.
// Arguments are handled in the manner of fmt.Printf.
func (c *Collector) debugf(format string, params ...interface{}) {
	if c.Debug {
		c.logger.Printf(format, params...)
	}
}

func (c *Collector) StartWorkers() {
	if c.Threads < 1 {
		panic("thread count must be > 0")
	}
	c.debugf("Starting %d threads for uploads", c.Threads)
	c.workerGroup = &sync.WaitGroup{}
	c.filesToUpload = make(chan infoWithPath)
	for i := 0; i < c.Threads; i++ {
		c.workerGroup.Add(1)
		go func() {
			for info := range c.filesToUpload {
				shouldRedo := true
				for shouldRedo {
					shouldRedo = c.uploadToThunderstorm(&info)
				}
			}
			c.workerGroup.Done()
		}()
	}
}

func (c *Collector) CheckThunderstormUp() error {
	c.debugf("Checking whether Thunderstorm at %s answers", c.Server)
	response, err := http.Get(fmt.Sprintf("%s/api/status", c.Server))
	if err != nil {
		if urlError, isUrlError := err.(*url.Error); isUrlError {
			if opError, isOpError := urlError.Err.(*net.OpError); isOpError {
				if opError.Op == "dial" {
					return fmt.Errorf("%w - did you enter host and port correctly", opError)
				}
			}
			return urlError.Err
		}
		return err
	}
	body, _ := ioutil.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != 200 {
		return fmt.Errorf("server didn't answer with an OK response code on status page, received code %d: %s", response.StatusCode, body)
	}
	c.debugf("Read status page from %s/api/status", c.Server)
	return nil
}

func (c *Collector) Collect() {
	for _, root := range c.CollectorConfig.RootPaths {
		c.collectPath(root)
	}
}

func (c *Collector) collectPath(root string) {
	c.logger.Printf("Walking through %s to find files to upload", root)
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		for _, glob := range c.ExcludeGlobs {
			if match, _ := doublestar.Match(glob, path); match {
				if info.IsDir() {
					c.logger.Printf("Skipping directory %s due to exclusion rule %s", path, glob)
					atomic.AddInt64(&c.Statistics.skippedDirectories, 1)
					return filepath.SkipDir
				} else {
					c.logger.Printf("Skipping file %s due to exclusion rule %s", path, glob)
					atomic.AddInt64(&c.Statistics.skippedFiles, 1)
					return nil
				}
			}
		}
		if !info.Mode().IsDir() {
			c.filesToUpload <- infoWithPath{info, path, 0}
		} else {
			if !c.AllFilesystems && SkipFilesystem(path) {
				c.logger.Printf("Skipping directory %s since it uses a pseudo or network filesystem", path)
				return filepath.SkipDir
			}
		}
		return nil
	})
	if err != nil {
		c.logger.Printf("Could not walk path %s: %v\n", root, err)
	}
	c.logger.Printf("Finished walking through %s", root)
}

func (c *Collector) Stop() {
	c.debugf("Waiting for pending uploads to finish...")
	close(c.filesToUpload)
	c.workerGroup.Wait()
	c.logger.Printf("Uploaded files: %d files", c.Statistics.uploadedFiles)
	c.logger.Printf("Failed to read files: %d files", c.Statistics.fileErrors)
	c.logger.Printf("Skipped files: %d files", c.Statistics.skippedFiles)
	c.logger.Printf("Skipped directories: %d directories", c.Statistics.skippedDirectories)
	c.logger.Printf("Failed uploads: %d files", c.Statistics.uploadErrors)
}

type infoWithPath struct {
	os.FileInfo
	path    string
	retries int
}

var MB int64 = 1024 * 1024

func (c *Collector) throttle() {
	if c.MinUploadPeriod > 0 {
		for {
			c.throttleMutex.Lock()
			currentTime := time.Now()
			timePassed := currentTime.Sub(c.lastScanTime)
			if timePassed >= c.MinUploadPeriod {
				c.lastScanTime = currentTime
				c.throttleMutex.Unlock()
				return
			} else {
				timeUntilNextUpload := c.MinUploadPeriod - timePassed
				c.throttleMutex.Unlock()
				time.Sleep(timeUntilNextUpload)
			}
		}
	}
}

func (c *Collector) uploadToThunderstorm(info *infoWithPath) (redo bool) {
	if c.isFileExcludedDueToMetadata(info) {
		atomic.AddInt64(&c.Statistics.skippedFiles, 1)
		return
	}

	f, err := os.Open(info.path)
	if err != nil {
		c.logger.Printf("Could not open file %s: %v\n", info.path, err)
		atomic.AddInt64(&c.Statistics.fileErrors, 1)
		return
	}
	defer f.Close()

	if c.isFileExcludedDueToContent(info, f) {
		atomic.AddInt64(&c.Statistics.skippedFiles, 1)
		return
	}

	c.throttle()

	contentType, formData := c.getFileContentAsFormData(f, info.path)
	response, err := http.Post(c.thunderstormUrl(), contentType, formData)
	if err != nil {
		if info.retries < 3 {
			c.logger.Printf("Could not send file %s to thunderstorm, will try again: %v", info.path, err)
			info.retries++
			time.Sleep(time.Second)
			return true
		} else {
			c.logger.Printf("Could not send file %s to thunderstorm, canceling it.", info.path)
			atomic.AddInt64(&c.Statistics.uploadErrors, 1)
			return false
		}
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusServiceUnavailable {
		retryAfter := response.Header.Get("Retry-After")
		retryTime, err := strconv.Atoi(retryAfter)
		if err != nil {
			retryTime = 30 // Default to 30 seconds cooldown time
		}
		c.logger.Printf("Thunderstorm has no free capacities for file %s, retrying in %d seconds", info.path, retryTime)
		time.Sleep(time.Second * time.Duration(retryTime))
		return true
	}
	responseBody, _ := ioutil.ReadAll(response.Body)
	if response.StatusCode != http.StatusOK {
		atomic.AddInt64(&c.Statistics.uploadErrors, 1)
		c.logger.Printf("Received error from Thunderstorm for file %s: %d %v\n", info.path, response.StatusCode, string(responseBody))
		return
	}
	atomic.AddInt64(&c.Statistics.uploadedFiles, 1)
	if c.Sync {
		c.logger.Printf("Response to file %s: %s", info.path, string(responseBody))
	}

	if c.Debug {
		c.debugf("File %s processed successfully", info.path)
	}
	return
}

func (c *Collector) isFileExcludedDueToMetadata(info *infoWithPath) bool {
	if !info.Mode().IsRegular() {
		c.debugf("Skipping irregular file %s", info.path)
		return true
	}
	isTooOld := true
	for _, time := range getTimes(info.FileInfo) {
		if time.After(c.ThresholdTime) {
			isTooOld = false
			break
		}
	}
	if isTooOld {
		c.debugf("Skipping old file %s", info.path)
		return true
	}
	if c.MaxFileSize > 0 &&
		c.MaxFileSize < info.Size() {
		c.debugf("Skipping big file %s", info.path)
		return true
	}
	return false
}

func (c *Collector) isFileExcludedDueToContent(info *infoWithPath, f *os.File) bool {
	var extensionWanted bool
	for _, extension := range c.FileExtensions {
		if strings.HasSuffix(info.path, extension) {
			extensionWanted = true
			break
		}
	}

	var magicHeaderWanted bool
	if len(c.MagicHeaders) > 0 && !extensionWanted {
		headerBuffer := make([]byte, c.magicHeaderExtractionLength)
		readLength, err := f.ReadAt(headerBuffer, 0)
		if err != nil {
			c.debugf("Could not read magic header for file %s", info.path)
		} else {
			headerBuffer = headerBuffer[:readLength]
			for _, magicHeader := range c.MagicHeaders {
				if bytes.HasPrefix(headerBuffer, magicHeader) {
					magicHeaderWanted = true
					break
				}
			}
		}
	}

	if !extensionWanted && !magicHeaderWanted && (len(c.MagicHeaders) > 0 || len(c.FileExtensions) > 0) {
		c.debugf("Skipping file %s with unwanted extension and magic header", info.path)
		return true
	}

	if info.Size() > c.MinCacheFileSize {
		hashCalculator := sha256.New()
		if _, err := io.Copy(hashCalculator, f); err == nil {
			fileHash := string(hashCalculator.Sum(nil))
			if _, alreadyExists := c.fileHashCache.LoadOrStore(fileHash, true); alreadyExists {
				c.debugf("Skipping file %s since a file with the same content was processed previously", info.path)
				return true
			}
		} else {
			c.debugf("Could not calculate hash for file %s: %v", info.path, err)
		}
		// Reset file descriptor after hash calculation
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			c.debugf("Could not reset file descriptor for file %s: %v", info.path, err)
		}
	}
	return false
}

func (c *Collector) thunderstormUrl() string {
	var urlParams = url.Values{}
	if c.Source != "" {
		urlParams.Add("source", c.Source)
	}

	var apiEndpoint string
	if c.Sync {
		apiEndpoint = "api/check"
	} else {
		apiEndpoint = "api/checkAsync"
	}

	return fmt.Sprintf("%s/%s?%s", c.Server, apiEndpoint, urlParams.Encode())
}

func (c *Collector) getFileContentAsFormData(f *os.File, filename string) (string, *io.PipeReader) {
	multipartReader, multipartWriter := io.Pipe()
	w := multipart.NewWriter(multipartWriter)
	abspath, err := filepath.Abs(filename)
	if err != nil {
		abspath = filename
	}
	go func() {
		fw, err := w.CreateFormFile("file", abspath)
		if err == nil {
			if _, err := io.Copy(fw, f); err != nil {
				c.debugf("Could not copy file content of %s to form writer: %v", filename, err)
			}
		}
		w.Close()
		multipartWriter.Close()
	}()
	return w.FormDataContentType(), multipartReader
}
