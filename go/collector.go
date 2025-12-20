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
	DryRun          bool

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

	fileHashCache      *sync.Map
	fileHashCacheCount int64 // Atomic counter for cache size

	// Timing
	startTime time.Time
}

type CollectionStatistics struct {
	// Discovery
	filesDiscovered int64

	// Exclusions
	skippedTooBig          int64
	skippedWrongType       int64
	skippedTooOld          int64
	skippedIrregular       int64
	skippedDuplicate       int64
	skippedDirectories     int64
	skippedExcluded        int64

	// Processing
	uploadedFiles          int64
	uploadErrors           int64
	fileErrors             int64

	// Timing (in nanoseconds, converted to seconds/milliseconds for display)
	timeWalking            int64
	timeReading            int64
	timeHashing            int64
	timeTransmitting       int64
}

func NewCollector(config CollectorConfig, logger *log.Logger) *Collector {
	collector := &Collector{
		CollectorConfig: config,
		logger:          logger,
		Statistics:      &CollectionStatistics{},
		fileHashCache:   &sync.Map{},
		startTime:       time.Now(),
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
	body, err := ioutil.ReadAll(response.Body)
	response.Body.Close()
	if err != nil {
		return fmt.Errorf("could not read response body: %w", err)
	}
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
	walkStart := time.Now()
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		for _, glob := range c.ExcludeGlobs {
			if match, _ := doublestar.Match(glob, path); match {
				if info.IsDir() {
					if c.Debug {
						c.logger.Printf("[DEBUG] Skipping directory %s due to exclusion rule %s", path, glob)
					}
					atomic.AddInt64(&c.Statistics.skippedDirectories, 1)
					return filepath.SkipDir
				} else {
					if c.Debug {
						c.logger.Printf("[DEBUG] Skipping file %s due to exclusion rule %s", path, glob)
					}
					atomic.AddInt64(&c.Statistics.skippedExcluded, 1)
					return nil
				}
			}
		}
		if !info.Mode().IsDir() {
			atomic.AddInt64(&c.Statistics.filesDiscovered, 1)
			// Quick metadata check before queuing to avoid unnecessary work
			if !c.isFileExcludedDueToMetadataQuick(info) {
				c.filesToUpload <- infoWithPath{info, path, 0}
			} else {
				// File was excluded in metadata check - already counted in skippedFiles
				// but we need to track the specific reason
			}
		} else {
			if !c.AllFilesystems && SkipFilesystem(path) {
				if c.Debug {
					c.logger.Printf("[DEBUG] Skipping directory %s since it uses a pseudo or network filesystem", path)
				}
				return filepath.SkipDir
			}
		}
		return nil
	})
	walkDuration := time.Since(walkStart)
	atomic.AddInt64(&c.Statistics.timeWalking, int64(walkDuration))
	if err != nil {
		c.logger.Printf("Could not walk path %s: %v\n", root, err)
	}
	c.logger.Printf("Finished walking through %s", root)
}

func (c *Collector) Stop() {
	c.debugf("Waiting for pending uploads to finish...")
	close(c.filesToUpload)
	c.workerGroup.Wait()

	totalDuration := time.Since(c.startTime)

	c.logger.Printf("")
	c.logger.Printf("=== Collection Statistics ===")
	if c.DryRun {
		c.logger.Printf("Mode: DRY-RUN (no files were actually sent)")
	}
	c.logger.Printf("")
	c.logger.Printf("Files discovered during walk: %d", atomic.LoadInt64(&c.Statistics.filesDiscovered))
	c.logger.Printf("")
	c.logger.Printf("Exclusions:")
	c.logger.Printf("  - Too big (exceeds max-filesize): %d", atomic.LoadInt64(&c.Statistics.skippedTooBig))
	c.logger.Printf("  - Wrong type (no matching extension/magic): %d", atomic.LoadInt64(&c.Statistics.skippedWrongType))
	c.logger.Printf("  - Too old (exceeds max-age): %d", atomic.LoadInt64(&c.Statistics.skippedTooOld))
	c.logger.Printf("  - Irregular file type: %d", atomic.LoadInt64(&c.Statistics.skippedIrregular))
	c.logger.Printf("  - Duplicate (same content hash): %d", atomic.LoadInt64(&c.Statistics.skippedDuplicate))
	c.logger.Printf("  - Excluded by glob pattern: %d", atomic.LoadInt64(&c.Statistics.skippedExcluded))
	c.logger.Printf("  - Skipped directories: %d", atomic.LoadInt64(&c.Statistics.skippedDirectories))
	c.logger.Printf("")
	c.logger.Printf("Processing:")
	c.logger.Printf("  - Successfully %s: %d", map[bool]string{true: "would be sent (dry-run)", false: "uploaded"}[c.DryRun], atomic.LoadInt64(&c.Statistics.uploadedFiles))
	c.logger.Printf("  - Read/transmission errors: %d", atomic.LoadInt64(&c.Statistics.fileErrors)+atomic.LoadInt64(&c.Statistics.uploadErrors))
	c.logger.Printf("")
	c.logger.Printf("Timing:")
	walkTime := time.Duration(atomic.LoadInt64(&c.Statistics.timeWalking))
	readTime := time.Duration(atomic.LoadInt64(&c.Statistics.timeReading))
	hashTime := time.Duration(atomic.LoadInt64(&c.Statistics.timeHashing))
	transmitTime := time.Duration(atomic.LoadInt64(&c.Statistics.timeTransmitting))
	c.logger.Printf("  - File system walk: %v", walkTime.Round(time.Millisecond))
	c.logger.Printf("  - Reading files: %v", readTime.Round(time.Millisecond))
	c.logger.Printf("  - Hashing files: %v", hashTime.Round(time.Millisecond))
	if !c.DryRun {
		c.logger.Printf("  - Transmitting files: %v", transmitTime.Round(time.Millisecond))
	}
	c.logger.Printf("  - Total time: %v", totalDuration.Round(time.Millisecond))
	c.logger.Printf("")
}

type infoWithPath struct {
	os.FileInfo
	path    string
	retries int
}

const (
	maxRetries       = 3               // Maximum number of retry attempts for failed uploads
	baseRetryDelay   = 4 * time.Second // Base delay for exponential backoff
	maxHashCacheSize = 10000           // Maximum number of entries in file hash cache before clearing
)

// throttle ensures uploads respect the minimum period between uploads.
// It uses a mutex to coordinate between goroutines, ensuring only one upload
// proceeds at a time when rate limiting is enabled. The sleep happens outside
// the mutex to avoid blocking other goroutines unnecessarily.
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
	readStart := time.Now()
	excluded, reason := c.isFileExcludedDueToMetadata(info)
	if excluded {
		if c.Debug {
			c.logger.Printf("[DEBUG] File %s would be skipped: %s", info.path, reason)
		}
		return
	}

	f, err := os.Open(info.path)
	if err != nil {
		c.logger.Printf("Could not open file %s: %v\n", info.path, err)
		atomic.AddInt64(&c.Statistics.fileErrors, 1)
		return
	}
	defer f.Close()

	excluded, reason = c.isFileExcludedDueToContent(info, f)
	if excluded {
		if c.Debug {
			c.logger.Printf("[DEBUG] File %s would be skipped: %s", info.path, reason)
		}
		return
	}

	readDuration := time.Since(readStart)
	atomic.AddInt64(&c.Statistics.timeReading, int64(readDuration))

	if c.Debug {
		c.logger.Printf("[DEBUG] File %s would be sent%s", info.path, map[bool]string{true: " (DRY-RUN)", false: ""}[c.DryRun])
	}

	// Dry-run mode: skip actual upload
	if c.DryRun {
		atomic.AddInt64(&c.Statistics.uploadedFiles, 1)
		if c.Sync {
			c.logger.Printf("[DRY-RUN] Would send file %s", info.path)
		}
		return
	}

	c.throttle()

	transmitStart := time.Now()
	contentType, formData := c.getFileContentAsFormData(f, info.path)
	response, err := http.Post(c.thunderstormUrl(), contentType, formData)
	if err != nil {
		if info.retries < maxRetries {
			c.logger.Printf("Could not send file %s to thunderstorm, will try again: %v", info.path, err)
			info.retries++
			time.Sleep(baseRetryDelay * time.Duration(1<<info.retries))
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
	responseBody, err := ioutil.ReadAll(response.Body)
	if err != nil {
		c.logger.Printf("Could not read response body for file %s: %v", info.path, err)
		atomic.AddInt64(&c.Statistics.uploadErrors, 1)
		return
	}
	if response.StatusCode != http.StatusOK {
		atomic.AddInt64(&c.Statistics.uploadErrors, 1)
		c.logger.Printf("Received error from Thunderstorm for file %s: %d %v\n", info.path, response.StatusCode, string(responseBody))
		return
	}
	transmitDuration := time.Since(transmitStart)
	atomic.AddInt64(&c.Statistics.timeTransmitting, int64(transmitDuration))

	atomic.AddInt64(&c.Statistics.uploadedFiles, 1)
	if c.Sync {
		c.logger.Printf("Response to file %s: %s", info.path, string(responseBody))
	}

	if c.Debug {
		c.debugf("File %s processed successfully", info.path)
	}
	return
}

// isFileExcludedDueToMetadataQuick performs a quick metadata check without creating an infoWithPath
func (c *Collector) isFileExcludedDueToMetadataQuick(info os.FileInfo) bool {
	if !info.Mode().IsRegular() {
		atomic.AddInt64(&c.Statistics.skippedIrregular, 1)
		return true
	}
	isTooOld := true
	for _, fileTime := range getTimes(info) {
		if fileTime.After(c.ThresholdTime) {
			isTooOld = false
			break
		}
	}
	if isTooOld {
		atomic.AddInt64(&c.Statistics.skippedTooOld, 1)
		return true
	}
	if c.MaxFileSize > 0 && c.MaxFileSize < info.Size() {
		atomic.AddInt64(&c.Statistics.skippedTooBig, 1)
		return true
	}
	return false
}

func (c *Collector) isFileExcludedDueToMetadata(info *infoWithPath) (excluded bool, reason string) {
	if !info.Mode().IsRegular() {
		if c.Debug {
			c.logger.Printf("[DEBUG] Skipping irregular file %s (not a regular file)", info.path)
		}
		atomic.AddInt64(&c.Statistics.skippedIrregular, 1)
		return true, "irregular file"
	}
	isTooOld := true
	for _, fileTime := range getTimes(info.FileInfo) {
		if fileTime.After(c.ThresholdTime) {
			isTooOld = false
			break
		}
	}
	if isTooOld {
		if c.Debug {
			c.logger.Printf("[DEBUG] Skipping old file %s (older than threshold)", info.path)
		}
		atomic.AddInt64(&c.Statistics.skippedTooOld, 1)
		return true, "too old"
	}
	if c.MaxFileSize > 0 && c.MaxFileSize < info.Size() {
		if c.Debug {
			c.logger.Printf("[DEBUG] Skipping big file %s (size: %d bytes, max: %d bytes)", info.path, info.Size(), c.MaxFileSize)
		}
		atomic.AddInt64(&c.Statistics.skippedTooBig, 1)
		return true, "too big"
	}
	return false, ""
}

// isFileExcludedDueToContent checks if a file should be excluded based on its content.
// The logic is:
//   - If file extensions are specified and the file matches an extension, it's included
//   - If extensions are specified but don't match, and magic headers are specified, check magic headers
//   - If neither extensions nor magic headers match (and at least one is specified), exclude the file
//   - If no extensions or magic headers are specified, include all files (content-based filtering disabled)
func (c *Collector) isFileExcludedDueToContent(info *infoWithPath, f *os.File) (excluded bool, reason string) {
	var extensionWanted bool
	for _, extension := range c.FileExtensions {
		if strings.HasSuffix(info.path, extension) {
			extensionWanted = true
			break
		}
	}

	var magicHeaderWanted bool
	// Only check magic headers if:
	// 1. Magic headers are configured, AND
	// 2. Either no extensions matched, OR no extensions are configured
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

	// Exclude file if filters are configured but neither extension nor magic header matched
	if !extensionWanted && !magicHeaderWanted && (len(c.MagicHeaders) > 0 || len(c.FileExtensions) > 0) {
		if c.Debug {
			c.logger.Printf("[DEBUG] Skipping file %s (wrong type: no matching extension or magic header)", info.path)
		}
		atomic.AddInt64(&c.Statistics.skippedWrongType, 1)
		return true, "wrong type"
	}

	if info.Size() > c.MinCacheFileSize {
		hashStart := time.Now()
		// Always reset file position after hash calculation, regardless of success/failure
		defer func() {
			if _, err := f.Seek(0, io.SeekStart); err != nil {
				c.debugf("Could not reset file descriptor for file %s: %v", info.path, err)
			}
		}()
		hashCalculator := sha256.New()
		if _, err := io.Copy(hashCalculator, f); err == nil {
			hashDuration := time.Since(hashStart)
			atomic.AddInt64(&c.Statistics.timeHashing, int64(hashDuration))
			fileHash := string(hashCalculator.Sum(nil))
			if _, alreadyExists := c.fileHashCache.LoadOrStore(fileHash, true); alreadyExists {
				if c.Debug {
					c.logger.Printf("[DEBUG] Skipping file %s (duplicate: same content hash)", info.path)
				}
				atomic.AddInt64(&c.Statistics.skippedDuplicate, 1)
				return true, "duplicate"
			}
			// Check cache size and clear if too large
			cacheSize := atomic.AddInt64(&c.fileHashCacheCount, 1)
			if cacheSize > maxHashCacheSize {
				// Clear cache if it exceeds maximum size
				// Use CompareAndSwap to ensure only one goroutine clears
				if atomic.CompareAndSwapInt64(&c.fileHashCacheCount, cacheSize, 0) {
					c.fileHashCache = &sync.Map{}
					c.debugf("Cleared file hash cache (exceeded %d entries)", maxHashCacheSize)
				}
			}
		} else {
			c.debugf("Could not calculate hash for file %s: %v", info.path, err)
		}
	}
	return false, ""
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
		defer multipartWriter.Close()
		fw, err := w.CreateFormFile("file", abspath)
		if err != nil {
			multipartWriter.CloseWithError(fmt.Errorf("could not create form file: %w", err))
			return
		}
		if _, err := io.Copy(fw, f); err != nil {
			multipartWriter.CloseWithError(fmt.Errorf("could not copy file content: %w", err))
			return
		}
		if err := w.Close(); err != nil {
			multipartWriter.CloseWithError(fmt.Errorf("could not close multipart writer: %w", err))
			return
		}
	}()
	return w.FormDataContentType(), multipartReader
}
