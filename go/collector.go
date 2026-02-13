package main

import (
	"bytes"
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

// SkipReason represents why a file was excluded from collection.
type SkipReason int

const (
	SkipReasonTooBig SkipReason = iota
	SkipReasonWrongType
	SkipReasonTooOld
	SkipReasonIrregular
	SkipReasonDirectory
	SkipReasonExcluded
)

// String returns a human-readable description of the skip reason.
func (r SkipReason) String() string {
	switch r {
	case SkipReasonTooBig:
		return "Too big (exceeds max-filesize)"
	case SkipReasonWrongType:
		return "Wrong type (no matching extension/magic)"
	case SkipReasonTooOld:
		return "Too old (exceeds max-age)"
	case SkipReasonIrregular:
		return "Irregular file type"
	case SkipReasonDirectory:
		return "Skipped directories"
	case SkipReasonExcluded:
		return "Excluded by glob pattern"
	default:
		return "Unknown"
	}
}

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

	// Timing
	startTime time.Time
}

type CollectionStatistics struct {
	// Note: The int64 fields for counting are accessed atomically thus MUST be
	// 64-bit aligned and MUST be kept as first words in this struct.
	// Info: "The first word in an allocated struct" is guaranteed to be 64-bit
	// aligned, see https://pkg.go.dev/sync/atomic#pkg-note-BUG . And so are all
	// consecutive fields of the struct, as long as they are also 64-bit in size.
	// Therefore, we keep all int64 fields at the top of the struct to ensure
	// proper alignment for atomic operations.

	// Discovery

	filesDiscovered int64

	// Processing

	uploadedFiles int64
	uploadErrors  int64
	fileErrors    int64

	// Timings (in nanoseconds, converted to seconds/milliseconds for display)

	// timeWalking measures the time spent walking the file system.
	timeWalking      int64
	// timeReading measures the time spent reading file metadata and performing checks (e.g., magic header check).
	timeReading      int64
	// timeTransmitting measures the time spent on reading file content and transmitting it to the server.
	timeTransmitting int64

	// Exclusions - using a map with mutex for thread-safe access.
	// We use a regular map with mutex instead of sync.Map because:
	// 1. sync.Map stores values as interface{}, requiring type assertions for atomic increments
	// 2. The map has a fixed small size (7 SkipReason values), so contention is minimal
	// 3. Increment operations (Load + Store) are simpler with a mutex than sync.Map

	skipReasons map[SkipReason]int64
	skipMutex   sync.Mutex
}

// incrementSkipReason safely increments the counter for a given skip reason.
func (s *CollectionStatistics) incrementSkipReason(reason SkipReason) {
	s.skipMutex.Lock()
	defer s.skipMutex.Unlock()
	s.skipReasons[reason]++
}

// getSkipCount safely retrieves the counter for a given skip reason.
func (s *CollectionStatistics) getSkipCount(reason SkipReason) int64 {
	s.skipMutex.Lock()
	defer s.skipMutex.Unlock()
	return s.skipReasons[reason]
}

func NewCollector(config CollectorConfig, logger *log.Logger) *Collector {
	collector := &Collector{
		CollectorConfig: config,
		logger:          logger,
		Statistics: &CollectionStatistics{
			skipReasons: make(map[SkipReason]int64),
		},
		startTime: time.Now(),
	}
	for _, header := range config.MagicHeaders {
		if len(header) > collector.magicHeaderExtractionLength {
			collector.magicHeaderExtractionLength = len(header)
		}
	}
	return collector
}

// debugf calls logger.Printf with [DEBUG] prefix if and only if debugging is enabled.
// Arguments are handled in the manner of fmt.Printf.
func (c *Collector) debugf(format string, params ...interface{}) {
	if c.Debug {
		c.logger.Printf("[DEBUG] "+format, params...)
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
	defer response.Body.Close()
	body, err := ioutil.ReadAll(response.Body)
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
	c.logger.Printf("Walking through '%s' to find files to upload", root)
	walkStart := time.Now()
	var submissionWait time.Duration
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		for _, glob := range c.ExcludeGlobs {
			if match, _ := doublestar.Match(glob, path); match {
				if info.IsDir() {
					c.debugf("Skipping directory '%s' due to exclusion rule %s", path, glob)
					c.Statistics.incrementSkipReason(SkipReasonDirectory)
					return filepath.SkipDir
				} else {
					c.debugf("Skipping file '%s' due to exclusion rule %s", path, glob)
					c.Statistics.incrementSkipReason(SkipReasonExcluded)
					return nil
				}
			}
		}
		// Check directory first to reduce nesting
		if info.Mode().IsDir() {
			if !c.AllFilesystems && SkipFilesystem(path) {
				c.debugf("Skipping directory '%s' since it uses a pseudo or network filesystem", path)
				return filepath.SkipDir
			}
			return nil
		}

		// Process regular files
		atomic.AddInt64(&c.Statistics.filesDiscovered, 1)

		// Quick metadata check before queuing to avoid unnecessary work
		if reason, excluded := c.quickMetadataCheck(info); excluded {
			c.debugf("Skipping file '%s' (%s)", path, reason.String())
			c.Statistics.incrementSkipReason(reason)
		} else {
			submissionStart := time.Now()
			c.filesToUpload <- infoWithPath{info, path, 0}
			submissionWait += time.Since(submissionStart)
		}
		return nil
	})
	walkDuration := time.Since(walkStart) - submissionWait
	atomic.AddInt64(&c.Statistics.timeWalking, int64(walkDuration))
	if err != nil {
		c.logger.Printf("Could not walk path '%s': %v\n", root, err)
	}
	c.logger.Printf("Finished walking through '%s'", root)
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
	// Print skip reasons in a consistent order
	skipReasonOrder := []SkipReason{
		SkipReasonTooBig,
		SkipReasonWrongType,
		SkipReasonTooOld,
		SkipReasonIrregular,
		SkipReasonExcluded,
		SkipReasonDirectory,
	}
	for _, reason := range skipReasonOrder {
		count := c.Statistics.getSkipCount(reason)
		c.logger.Printf("  - %s: %d", reason.String(), count)
	}
	c.logger.Printf("")
	c.logger.Printf("Processing:")
	c.logger.Printf("  - Successfully %s: %d", map[bool]string{true: "would be sent (dry-run)", false: "uploaded"}[c.DryRun], atomic.LoadInt64(&c.Statistics.uploadedFiles))
	c.logger.Printf("  - Read/transmission errors: %d", atomic.LoadInt64(&c.Statistics.fileErrors)+atomic.LoadInt64(&c.Statistics.uploadErrors))
	c.logger.Printf("")
	c.logger.Printf("Timing:")
	walkTime := time.Duration(atomic.LoadInt64(&c.Statistics.timeWalking))
	readTime := time.Duration(atomic.LoadInt64(&c.Statistics.timeReading))
	transmitTime := time.Duration(atomic.LoadInt64(&c.Statistics.timeTransmitting))
	c.logger.Printf("  - File system walk: %v", walkTime.Round(time.Millisecond))
	c.logger.Printf("  - File metadata analysis: %v", readTime.Round(time.Millisecond))
	if !c.DryRun {
		c.logger.Printf("  - File read and transmission: %v", transmitTime.Round(time.Millisecond))
	}
	c.logger.Printf("  - Total time: %v", totalDuration.Round(time.Millisecond))
	c.logger.Printf("")
}

type infoWithPath struct {
	os.FileInfo
	path    string
	retries uint
}

const (
	maxRetries     = 3               // Maximum number of retry attempts for failed uploads
	baseRetryDelay = 4 * time.Second // Base delay for exponential backoff
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

// uploadToThunderstorm uploads a file to the Thunderstorm server.
// Returns true if the upload should be retried (e.g., due to transient errors or rate limiting),
// or false if the upload completed (successfully or with a permanent error).
func (c *Collector) uploadToThunderstorm(info *infoWithPath) (redo bool) {
	readStart := time.Now()

	f, err := os.Open(info.path)
	if err != nil {
		c.logger.Printf("Could not open file '%s': %v\n", info.path, err)
		atomic.AddInt64(&c.Statistics.fileErrors, 1)
		return
	}
	defer f.Close()

	if skipReason, excluded := c.checkFileContent(info, f); excluded {
		c.debugf("Skipping file '%s' (%s)", info.path, skipReason.String())
		c.Statistics.incrementSkipReason(skipReason)
		return
	}

	readDuration := time.Since(readStart)
	atomic.AddInt64(&c.Statistics.timeReading, int64(readDuration))

	// Dry-run mode: skip actual upload
	if c.DryRun {
		c.debugf("File '%s' would be sent (DRY-RUN)", info.path)
		atomic.AddInt64(&c.Statistics.uploadedFiles, 1)
		return
	}

	c.throttle()

	transmitStart := time.Now()
	contentType, formData := c.getFileContentAsFormData(f, info.path)
	response, err := http.Post(c.thunderstormUrl(), contentType, formData)
	if err != nil {
		if info.retries < maxRetries {
			c.logger.Printf("Could not send file '%s' to thunderstorm, will try again: %v", info.path, err)
			info.retries++
			time.Sleep(baseRetryDelay * time.Duration(1<<info.retries))
			return true
		} else {
			c.logger.Printf("Could not send file '%s' to thunderstorm, canceling it.", info.path)
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
		c.logger.Printf("Thunderstorm has no free capacities for file '%s', retrying in %d seconds", info.path, retryTime)
		time.Sleep(time.Second * time.Duration(retryTime))
		return true
	}
	responseBody, err := ioutil.ReadAll(response.Body)
	if err != nil {
		c.logger.Printf("Could not read response body for file '%s': %v", info.path, err)
		atomic.AddInt64(&c.Statistics.uploadErrors, 1)
		return
	}
	if response.StatusCode != http.StatusOK {
		atomic.AddInt64(&c.Statistics.uploadErrors, 1)
		c.logger.Printf("Received error from Thunderstorm for file '%s': %d %v\n", info.path, response.StatusCode, string(responseBody))
		return
	}
	transmitDuration := time.Since(transmitStart)
	atomic.AddInt64(&c.Statistics.timeTransmitting, int64(transmitDuration))

	atomic.AddInt64(&c.Statistics.uploadedFiles, 1)
	if c.Sync {
		c.logger.Printf("Response to file '%s': %s", info.path, string(responseBody))
	}

	c.debugf("File '%s' processed successfully", info.path)
	return
}

// quickMetadataCheck performs a quick metadata check without opening the file.
// It checks if the file is a regular file, within the age threshold, and within the size limit.
// Returns (SkipReason, true) if the file should be excluded, or (0, false) if it should be processed.
// Note: Debug logging for skip reasons is done by the caller, not this function.
func (c *Collector) quickMetadataCheck(info os.FileInfo) (SkipReason, bool) {
	if !info.Mode().IsRegular() {
		return SkipReasonIrregular, true
	}

	isTooOld := true
	for _, fileTime := range getTimes(info) {
		if fileTime.After(c.ThresholdTime) {
			isTooOld = false
			break
		}
	}
	if isTooOld {
		return SkipReasonTooOld, true
	}

	if c.MaxFileSize > 0 && c.MaxFileSize < info.Size() {
		return SkipReasonTooBig, true
	}

	return 0, false
}

// checkFileContent checks if a file should be excluded based on its content (extension and magic header).
// Returns (SkipReason, true) if the file should be excluded, or (0, false) if it should be processed.
// Note: Debug logging for skip reasons is done by the caller, not this function.
//
// Extension and magic header filtering logic:
//   - If file extensions are specified and the file matches an extension, it's included.
//   - If extensions are specified but don't match, and magic headers are specified, check magic headers.
//   - If neither extensions nor magic headers match (and at least one is specified), exclude the file.
//   - If no extensions or magic headers are specified, all files pass content filtering.
func (c *Collector) checkFileContent(info *infoWithPath, f *os.File) (SkipReason, bool) {
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
			c.debugf("Could not read magic header for file '%s'", info.path)
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
		return SkipReasonWrongType, true
	}

	return 0, false
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

// getFileContentAsFormData creates multipart form data from a file for HTTP upload.
// Returns the Content-Type header value (including boundary) and a PipeReader for the form data.
func (c *Collector) getFileContentAsFormData(f *os.File, filename string) (string, *io.PipeReader) {
	multipartReader, multipartWriter := io.Pipe()
	w := multipart.NewWriter(multipartWriter)
	abspath, err := filepath.Abs(filename)
	if err != nil {
		abspath = filename
	}
	go func() {
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
		multipartWriter.Close()
	}()
	return w.FormDataContentType(), multipartReader
}
