package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"mime/multipart"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/textproto"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/bmatcuk/doublestar"
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
	// ResponseTimeout bounds the wait for Thunderstorm's answer once a request
	// has been sent. Zero selects defaultResponseTimeout or, with Sync,
	// defaultSyncResponseTimeout.
	ResponseTimeout time.Duration
	// ServerWait is how long the collector waits for Thunderstorm to come back
	// after outageThreshold files in a row could not be delivered, see
	// recordUndeliverable. Zero stops the collection at once.
	ServerWait time.Duration
}

type Collector struct {
	CollectorConfig

	logger *log.Logger

	// HTTP client for all requests to Thunderstorm. It never follows redirects,
	// see refuseRedirects.
	client *http.Client
	// markerClient sends collection markers. Like client, it never follows
	// redirects; unlike client, it gives up after markerTimeout.
	markerClient *http.Client

	// scanID is the run's ID from the begin marker answer, or empty. It is set
	// before the workers start and only read afterwards.
	scanID string
	// markersActive is 1 once the server accepted the begin marker.
	markersActive int32
	closingMutex  sync.Mutex
	closingSent   bool

	// Set before starting workers; default to time.Sleep and time.Now.
	retrySleep func(time.Duration)
	now        func() time.Time

	outage *outageState

	workerGroup   *sync.WaitGroup
	filesToUpload chan infoWithPath

	Statistics *CollectionStatistics

	magicHeaderExtractionLength int

	throttleMutex sync.Mutex
	lastScanTime  time.Time

	// reportedGlobs holds the exclude globs whose syntax error has been logged.
	// Only the walk uses it.
	reportedGlobs map[string]bool

	// progressStop ends the goroutine that logs progress lines; progressDone is
	// closed once it has ended. Both are nil until StartWorkers.
	progressStop chan struct{}
	progressDone chan struct{}

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
	// rootErrors counts scan roots that could not be read; they fail the run.
	rootErrors int64
	// walkErrors counts directories and entries below a root that could not be
	// read. They are reported but, like the permission-denied directories of any
	// full-disk scan, do not change the exit status.
	walkErrors int64
	// notSent counts selected files that were not sent because the collection
	// stopped after Thunderstorm stayed unreachable for ServerWait.
	notSent int64

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

// ErrorCount returns the number of failures that make the run unsuccessful:
// selected files that could not be read, accepted or sent, and scan roots that
// could not be read. Unreadable directories below a root are only reported, see
// walkErrors. Failed collection markers are ignored, see markers.go.
func (s *CollectionStatistics) ErrorCount() int64 {
	return atomic.LoadInt64(&s.fileErrors) + atomic.LoadInt64(&s.uploadErrors) + atomic.LoadInt64(&s.rootErrors) +
		atomic.LoadInt64(&s.notSent)
}

// outageState tracks whether Thunderstorm still accepts uploads. It is always
// allocated on its own, so its leading int64 is 64-bit aligned for atomic access
// on 32-bit platforms.
type outageState struct {
	// consecutiveFailures counts files in a row whose upload failed without an
	// answer from Thunderstorm (transport errors, or HTTP 503 until the retry
	// budget was used up). Any other answer resets it.
	consecutiveFailures int64
	// stopped is 1 once the collection was stopped because Thunderstorm stayed
	// unreachable.
	stopped int32
	// checking is held for writing while one worker polls /api/status; the other
	// workers wait for the outcome before they send anything.
	checking sync.RWMutex
}

// refuseRedirects makes the HTTP client hand a redirect response back to the
// caller instead of following it. Following a 301/302/303 replays the upload as
// a body-less GET, so a gateway that answers with a redirect to a login page
// would make the collector report a successful transfer for a sample that
// Thunderstorm never accepted.
func refuseRedirects(req *http.Request, via []*http.Request) error {
	return http.ErrUseLastResponse
}

// redirectHint describes an unfollowed redirect response, or returns an empty
// string for any other response.
func redirectHint(response *http.Response) string {
	if response.StatusCode < 300 || response.StatusCode > 399 {
		return ""
	}
	return fmt.Sprintf(" (redirect to %q, redirects are not followed; check --ssl, --port and any gateway or proxy in front of Thunderstorm)", response.Header.Get("Location"))
}

func NewCollector(config CollectorConfig, logger *log.Logger) *Collector {
	if config.ResponseTimeout <= 0 {
		if config.Sync {
			config.ResponseTimeout = defaultSyncResponseTimeout
		} else {
			config.ResponseTimeout = defaultResponseTimeout
		}
	}
	collector := &Collector{
		CollectorConfig: config,
		logger:          logger,
		client:          &http.Client{CheckRedirect: refuseRedirects},
		markerClient:    &http.Client{CheckRedirect: refuseRedirects, Timeout: markerTimeout},
		retrySleep:      time.Sleep,
		now:             time.Now,
		outage:          &outageState{},
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
	c.progressStop = make(chan struct{})
	c.progressDone = make(chan struct{})
	go c.reportProgress()
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

// progressInterval is the time between two progress lines. Without them a long
// run logs nothing between the start of the walk and the final statistics, and
// cannot be told from one that hangs. A variable so tests can shorten it.
var progressInterval = 5 * time.Minute

// reportProgress logs a progress line every progressInterval until Stop.
func (c *Collector) reportProgress() {
	defer close(c.progressDone)
	ticker := time.NewTicker(progressInterval)
	defer ticker.Stop()
	for {
		select {
		case <-c.progressStop:
			return
		case <-ticker.C:
			c.logProgress()
		}
	}
}

func (c *Collector) logProgress() {
	sent := "uploaded"
	if c.DryRun {
		sent = "would be sent (dry-run)"
	}
	c.logger.Printf("Progress after %v: %d files discovered, %d %s, %d errors",
		time.Since(c.startTime).Round(time.Second), atomic.LoadInt64(&c.Statistics.filesDiscovered),
		atomic.LoadInt64(&c.Statistics.uploadedFiles), sent, c.Statistics.ErrorCount())
}

func (c *Collector) CheckThunderstormUp() error {
	c.debugf("Checking whether Thunderstorm at %s answers", c.Server)
	timeout := c.ResponseTimeout
	if timeout > statusCheckTimeout {
		timeout = statusCheckTimeout
	}
	response, body, err := c.send("GET", fmt.Sprintf("%s/api/status", c.Server), "", nil, timeout)
	if err != nil {
		if urlError, isUrlError := err.(*url.Error); isUrlError {
			if opError, isOpError := urlError.Err.(*net.OpError); isOpError {
				if opError.Op == "dial" {
					return fmt.Errorf("%v - did you enter host and port correctly", opError)
				}
			}
			return urlError.Err
		}
		return err
	}
	if response.StatusCode != 200 {
		return fmt.Errorf("server didn't answer with an OK response code on status page, received code %d%s: %s", response.StatusCode, redirectHint(response), body)
	}
	c.debugf("Read status page from %s/api/status", c.Server)
	return nil
}

const (
	defaultResponseTimeout     = 2 * time.Minute
	defaultSyncResponseTimeout = 30 * time.Minute
	// maxResponseBytes bounds a response body; Thunderstorm answers with a small
	// JSON document, also when it reports scan results with --upload-synchronous.
	maxResponseBytes = 16 * 1024 * 1024
)

// statusCheckTimeout bounds a /api/status check, also when --response-timeout
// is longer: the status page answers at once, and a check during the server
// wait must not run far past --server-wait (with --upload-synchronous the
// response timeout is 30 minutes). A variable so tests can shorten it.
var statusCheckTimeout = 30 * time.Second

// connectTimeout bounds the wait for a connection to Thunderstorm: the dial,
// the CONNECT exchange with a proxy and the TLS handshake. The dial and the
// handshake have shorter limits of their own; the CONNECT exchange has none,
// so a proxy that accepts the connection but never answers would otherwise
// block the worker. A variable so tests can shorten it.
var connectTimeout = 60 * time.Second

// pendingDials collects the connections dialled for one request, so send() can
// close them when it stops waiting for a connection. Go 1.10 reads a proxy's
// answer to CONNECT without a deadline; cancelling the request frees the
// worker, but the dial would keep its goroutine and socket until the proxy
// hangs up.
type pendingDials struct {
	mutex  sync.Mutex
	conns  []net.Conn
	closed bool
}

type pendingDialsKey struct{}

// trackDial registers conn with the request that ctx belongs to, if any. The
// dial context carries the request's values in Go 1.10 and in current Go.
func trackDial(ctx context.Context, conn net.Conn) {
	if dials, ok := ctx.Value(pendingDialsKey{}).(*pendingDials); ok {
		dials.add(conn)
	}
}

func (d *pendingDials) add(conn net.Conn) {
	d.mutex.Lock()
	defer d.mutex.Unlock()
	if d.closed {
		// The request has already given up on this connection.
		conn.Close()
		return
	}
	d.conns = append(d.conns, conn)
}

func (d *pendingDials) closeAll() {
	d.mutex.Lock()
	defer d.mutex.Unlock()
	d.closed = true
	for _, conn := range d.conns {
		conn.Close()
	}
	d.conns = nil
}

// send performs one request to Thunderstorm and returns the response with its
// body, which has already been read and closed. The wait for a connection is
// bounded by connectTimeout, the wait for the answer by timeout: the timer starts once the request body has been
// handed to the connection (at once for a request without a body) and covers
// the response headers and the body. Writing the body is bounded by the write
// stall guard of the transport instead, so a large upload over a slow link is
// not cut off.
func (c *Collector) send(method string, target string, contentType string, body io.ReadCloser, timeout time.Duration) (*http.Response, []byte, error) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var timedOut, connectTimedOut int32
	var timerOnce sync.Once
	var timer *time.Timer
	var timerMutex sync.Mutex
	startTimer := func() {
		timerOnce.Do(func() {
			timerMutex.Lock()
			timer = time.AfterFunc(timeout, func() {
				atomic.StoreInt32(&timedOut, 1)
				cancel()
			})
			timerMutex.Unlock()
		})
	}
	defer func() {
		timerMutex.Lock()
		if timer != nil {
			timer.Stop()
		}
		timerMutex.Unlock()
	}()
	timeoutError := func(err error) error {
		if atomic.LoadInt32(&connectTimedOut) == 1 {
			return fmt.Errorf("no connection to Thunderstorm within %v: %v", connectTimeout, err)
		}
		if atomic.LoadInt32(&timedOut) == 1 {
			if timeout != c.ResponseTimeout {
				return fmt.Errorf("no answer from Thunderstorm within %v: %v", timeout, err)
			}
			return fmt.Errorf("no answer from Thunderstorm within %v (see --response-timeout): %v", timeout, err)
		}
		return err
	}

	var requestBody io.Reader
	if body == nil {
		startTimer()
	} else {
		// The transport does not always close the body, for example when the
		// server answers before reading all of it; closing it ends the goroutine
		// that produces it.
		defer body.Close()
		requestBody = &eofNotifier{reader: body, onEOF: startTimer}
	}
	request, err := http.NewRequest(method, target, requestBody)
	if err != nil {
		return nil, nil, err
	}
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	// The response timer starts only once the transport has a connection and has
	// read the body, so the time until then is bounded separately.
	dials := &pendingDials{}
	connectTimer := time.AfterFunc(connectTimeout, func() {
		atomic.StoreInt32(&connectTimedOut, 1)
		cancel()
		dials.closeAll()
	})
	defer connectTimer.Stop()
	trace := &httptrace.ClientTrace{GotConn: func(httptrace.GotConnInfo) { connectTimer.Stop() }}
	requestContext := httptrace.WithClientTrace(context.WithValue(ctx, pendingDialsKey{}, dials), trace)
	response, err := c.client.Do(request.WithContext(requestContext))
	if err != nil {
		if urlError, isUrlError := err.(*url.Error); isUrlError {
			urlError.Err = timeoutError(urlError.Err)
			return nil, nil, urlError
		}
		return nil, nil, timeoutError(err)
	}
	defer response.Body.Close()
	// The answer may come before the whole body was sent.
	startTimer()
	responseBody, err := ioutil.ReadAll(io.LimitReader(response.Body, maxResponseBytes+1))
	if err != nil {
		return response, nil, fmt.Errorf("could not read response body: %v", timeoutError(err))
	}
	if len(responseBody) > maxResponseBytes {
		return response, nil, fmt.Errorf("response body is larger than %d bytes", maxResponseBytes)
	}
	return response, responseBody, nil
}

// eofNotifier calls onEOF once its reader is exhausted.
type eofNotifier struct {
	reader io.Reader
	onEOF  func()
}

func (r *eofNotifier) Read(p []byte) (int, error) {
	n, err := r.reader.Read(p)
	if err == io.EOF {
		r.onEOF()
	}
	return n, err
}

func (c *Collector) Collect() {
	for _, root := range c.CollectorConfig.RootPaths {
		if c.collectionStopped() {
			break
		}
		c.collectPath(root)
	}
}

// outageThreshold is the number of files in a row that must fail without an
// answer from Thunderstorm before the collector stops sending and waits for it.
const outageThreshold = 3

// Delays between the /api/status polls while Thunderstorm is unreachable.
const (
	outageFirstPollDelay = 2 * time.Second
	outageMaxPollDelay   = 60 * time.Second
)

// errCollectionStopped ends the walk once the collection has been stopped.
var errCollectionStopped = errors.New("collection stopped because Thunderstorm is unreachable")

func (c *Collector) collectionStopped() bool {
	return atomic.LoadInt32(&c.outage.stopped) == 1
}

// recordAnswer notes that Thunderstorm answered an upload, so it is reachable.
func (c *Collector) recordAnswer() {
	atomic.StoreInt64(&c.outage.consecutiveFailures, 0)
}

// recordUndeliverable notes a file that could not be delivered because
// Thunderstorm did not answer or stayed busy. After outageThreshold such files
// in a row, the calling worker polls /api/status for up to ServerWait while the
// other workers wait. If Thunderstorm answers, the collection continues with
// the next file; otherwise it stops: the walk ends and queued files are counted
// as not sent.
func (c *Collector) recordUndeliverable() {
	if atomic.AddInt64(&c.outage.consecutiveFailures, 1) < outageThreshold {
		return
	}
	c.outage.checking.Lock()
	defer c.outage.checking.Unlock()
	// Another worker may have handled the outage while this one waited.
	if c.collectionStopped() || atomic.LoadInt64(&c.outage.consecutiveFailures) < outageThreshold {
		return
	}
	if c.waitForThunderstorm() {
		atomic.StoreInt64(&c.outage.consecutiveFailures, 0)
		return
	}
	atomic.StoreInt32(&c.outage.stopped, 1)
}

// waitForThunderstorm polls /api/status with growing delays until Thunderstorm
// answers or ServerWait has passed, and reports whether it answered.
func (c *Collector) waitForThunderstorm() bool {
	start := c.now()
	c.logger.Printf("Thunderstorm did not accept %d files in a row; checking %s/api/status for up to %v before sending more", outageThreshold, c.Server, c.ServerWait)
	delay := outageFirstPollDelay
	for {
		remaining := c.ServerWait - c.now().Sub(start)
		if remaining <= 0 {
			break
		}
		if delay > remaining {
			delay = remaining
		}
		c.retrySleep(delay)
		err := c.CheckThunderstormUp()
		if err == nil {
			c.logger.Printf("Thunderstorm answers again after %v; continuing with the next file", c.now().Sub(start).Round(time.Second))
			return true
		}
		c.debugf("Thunderstorm still does not answer: %v", err)
		delay *= 2
		if delay > outageMaxPollDelay {
			delay = outageMaxPollDelay
		}
	}
	c.logger.Printf("Thunderstorm unreachable for %v, stopping the collection; the remaining files are not sent", c.now().Sub(start).Round(time.Second))
	return false
}

// waitWhileThunderstormIsChecked blocks while another worker polls
// /api/status after an outage.
func (c *Collector) waitWhileThunderstormIsChecked() {
	c.outage.checking.RLock()
	c.outage.checking.RUnlock()
}

// countNotSent accounts for a file that is not sent because the collection
// stopped. A file that already had failed attempts counts as an upload error.
func (c *Collector) countNotSent(info *infoWithPath) {
	if info.retries > 0 {
		atomic.AddInt64(&c.Statistics.uploadErrors, 1)
		return
	}
	atomic.AddInt64(&c.Statistics.notSent, 1)
}

// reportWalkError logs and counts a path that filepath.Walk could not read. A
// scan root that cannot be read fails the run; a directory below it is only
// reported. An entry below the root that disappeared after its directory was
// listed is not an error of the collector and is only noted in debug output.
func (c *Collector) reportWalkError(root string, path string, err error) {
	if path == root {
		atomic.AddInt64(&c.Statistics.rootErrors, 1)
		c.logger.Printf("Could not read scan root '%s': %v", root, err)
		return
	}
	if os.IsNotExist(err) {
		c.debugf("Skipping '%s', it vanished during the walk: %v", path, err)
		return
	}
	atomic.AddInt64(&c.Statistics.walkErrors, 1)
	c.logger.Printf("Could not read '%s' while walking '%s': %v", path, root, err)
}

// resolveScanRoot returns the path to walk for a scan root. filepath.Walk does
// not follow symbolic links, also not for the root itself: a root such as /tmp
// or /var on macOS would be reported as one irregular file and nothing would be
// collected. A root that is a symbolic link is therefore replaced by its
// target. Links below the root are still not followed.
func resolveScanRoot(root string) (string, error) {
	info, err := os.Lstat(root)
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		// filepath.Walk reports a root that cannot be read.
		return root, nil
	}
	return filepath.EvalSymlinks(root)
}

// excludeMatches reports whether path matches an exclude glob. doublestar.Match
// knows only "/" as separator and reads "\" as an escape character, so with
// another separator (Windows) the glob and the path are converted to forward
// slashes first. A glob can then use either separator, and "\" does not escape.
func excludeMatches(glob string, path string, separator rune) (bool, error) {
	if separator != '/' {
		glob = strings.Replace(glob, string(separator), "/", -1)
		path = strings.Replace(path, string(separator), "/", -1)
	}
	return doublestar.Match(glob, path)
}

// reportBadGlob logs an exclude glob with a syntax error once. doublestar finds
// such an error only when a path reaches the faulty part of the pattern, so it
// cannot be checked at startup.
func (c *Collector) reportBadGlob(glob string, err error) {
	if c.reportedGlobs[glob] {
		return
	}
	if c.reportedGlobs == nil {
		c.reportedGlobs = make(map[string]bool)
	}
	c.reportedGlobs[glob] = true
	c.logger.Printf("Exclude glob '%s' is not valid and may exclude nothing: %v", glob, err)
}

// decidedByName reports whether the file name alone decides the content
// filter: extensions are configured and magic headers are not.
func (c *Collector) decidedByName() bool {
	return len(c.FileExtensions) > 0 && len(c.MagicHeaders) == 0
}

func (c *Collector) collectPath(scanRoot string) {
	root, err := resolveScanRoot(scanRoot)
	if err != nil {
		atomic.AddInt64(&c.Statistics.rootErrors, 1)
		c.logger.Printf("Could not read scan root '%s': %v", scanRoot, err)
		return
	}
	if root != scanRoot {
		c.logger.Printf("Scan root '%s' is a symbolic link, walking its target '%s'", scanRoot, root)
	}
	c.logger.Printf("Walking through '%s' to find files to upload", root)
	walkStart := time.Now()
	var submissionWait time.Duration
	err = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if c.collectionStopped() {
			return errCollectionStopped
		}
		if err != nil {
			c.reportWalkError(root, path, err)
			return nil
		}
		for _, glob := range c.ExcludeGlobs {
			match, err := excludeMatches(glob, path, os.PathSeparator)
			if err != nil {
				c.reportBadGlob(glob, err)
			}
			if match {
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
		} else if c.decidedByName() && !c.extensionWanted(path) {
			// Not queued, so a file that the name already rules out is never opened.
			c.debugf("Skipping file '%s' (%s)", path, SkipReasonWrongType.String())
			c.Statistics.incrementSkipReason(SkipReasonWrongType)
		} else {
			submissionStart := time.Now()
			c.filesToUpload <- infoWithPath{FileInfo: info, path: path}
			submissionWait += time.Since(submissionStart)
		}
		return nil
	})
	walkDuration := time.Since(walkStart) - submissionWait
	atomic.AddInt64(&c.Statistics.timeWalking, int64(walkDuration))
	if err == errCollectionStopped {
		c.logger.Printf("Stopped walking through '%s' because Thunderstorm is unreachable", root)
		return
	}
	if err != nil {
		c.logger.Printf("Could not walk path '%s': %v\n", root, err)
	}
	c.logger.Printf("Finished walking through '%s'", root)
}

func (c *Collector) Stop() {
	c.debugf("Waiting for pending uploads to finish...")
	close(c.filesToUpload)
	c.workerGroup.Wait()
	if c.progressStop != nil {
		close(c.progressStop)
		<-c.progressDone
	}

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
	uploadLabel := "uploaded"
	if c.DryRun {
		uploadLabel = "would be sent (dry-run)"
	}
	c.logger.Printf("  - Successfully %s: %d", uploadLabel, atomic.LoadInt64(&c.Statistics.uploadedFiles))
	c.logger.Printf("  - Read/transmission errors: %d", atomic.LoadInt64(&c.Statistics.fileErrors)+atomic.LoadInt64(&c.Statistics.uploadErrors))
	if c.collectionStopped() {
		c.logger.Printf("  - Not sent, the collection stopped because Thunderstorm was unreachable: %d", atomic.LoadInt64(&c.Statistics.notSent))
	}
	c.logger.Printf("  - Paths that could not be read during the walk: %d", atomic.LoadInt64(&c.Statistics.rootErrors)+atomic.LoadInt64(&c.Statistics.walkErrors))
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
	// selected is set once the content filters accepted the file; a retry does
	// not check them again.
	selected bool
}

const (
	maxRetries     = 3               // Maximum number of retry attempts for failed uploads
	baseRetryDelay = 4 * time.Second // Base delay for exponential backoff

	defaultRetryAfter = 30  // Seconds to wait after HTTP 503 without a usable Retry-After header
	maxRetryAfter     = 120 // Upper bound in seconds for a server-supplied Retry-After, so one header cannot stall a worker for hours
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
// The wait before a retry happens here, after attemptUpload has closed the file.
func (c *Collector) uploadToThunderstorm(info *infoWithPath) (redo bool) {
	redo, retryDelay := c.attemptUpload(info)
	if redo {
		c.retrySleep(retryDelay)
	}
	return redo
}

// isGatewayError reports whether the status says that a gateway or proxy in
// front of Thunderstorm could not reach it.
func isGatewayError(status int) bool {
	return status == http.StatusBadGateway || status == http.StatusGatewayTimeout
}

// attemptUpload makes one attempt to select and send a file. It returns whether
// the file should be tried again and how long to wait before that.
//
// The file is open only while it is checked and while it is sent, never during
// a wait (server check, rate limit, retry delay): on Windows an open file
// cannot be deleted or renamed by its owner.
func (c *Collector) attemptUpload(info *infoWithPath) (redo bool, retryDelay time.Duration) {
	if c.collectionStopped() {
		c.countNotSent(info)
		return false, 0
	}
	if !info.selected {
		if !c.selectFile(info) {
			return false, 0
		}
		info.selected = true
		// Dry-run mode: skip actual upload
		if c.DryRun {
			c.debugf("File '%s' would be sent (DRY-RUN)", info.path)
			atomic.AddInt64(&c.Statistics.uploadedFiles, 1)
			return false, 0
		}
	}

	c.waitWhileThunderstormIsChecked()
	if c.collectionStopped() {
		c.countNotSent(info)
		return false, 0
	}
	c.throttle()

	readStart := time.Now()
	f, size, ok := c.openSelected(info)
	if !ok {
		return false, 0
	}
	defer f.Close()
	atomic.AddInt64(&c.Statistics.timeReading, int64(time.Since(readStart)))

	transmitStart := time.Now()
	contentType, formData, readError := c.getFileContentAsFormData(f, info.path, size)
	response, responseBody, err := c.send("POST", c.thunderstormUrl(), contentType, formData, c.ResponseTimeout)
	if fileErr := readError.get(); fileErr != nil {
		// The file changed or could not be read while it was sent; Thunderstorm is
		// not to blame, so this is neither retried nor counted as an outage.
		c.logger.Printf("Could not read file '%s' while sending it: %v", info.path, fileErr)
		atomic.AddInt64(&c.Statistics.fileErrors, 1)
		return false, 0
	}
	// No answer from Thunderstorm itself: a transport error, or a gateway that
	// could not reach it (HTTP 502 or 504).
	var undelivered error
	if err != nil && response == nil {
		undelivered = err
	} else if isGatewayError(response.StatusCode) {
		undelivered = fmt.Errorf("a gateway in front of Thunderstorm answered HTTP %d", response.StatusCode)
	}
	if undelivered != nil {
		if info.retries < maxRetries {
			c.logger.Printf("Could not send file '%s' to thunderstorm, will try again: %v", info.path, undelivered)
			info.retries++
			return true, baseRetryDelay * time.Duration(1<<(info.retries-1))
		}
		c.logger.Printf("Could not send file '%s' to thunderstorm, canceling it: %v", info.path, undelivered)
		atomic.AddInt64(&c.Statistics.uploadErrors, 1)
		c.recordUndeliverable()
		return false, 0
	}
	if response.StatusCode == http.StatusServiceUnavailable {
		if info.retries >= maxRetries {
			c.logger.Printf("Thunderstorm has no free capacities for file '%s', canceling it after %d retries", info.path, maxRetries)
			atomic.AddInt64(&c.Statistics.uploadErrors, 1)
			c.recordUndeliverable()
			return false, 0
		}
		info.retries++
		retryAfter := response.Header.Get("Retry-After")
		retryTime, err := strconv.Atoi(retryAfter)
		if err != nil || retryTime < 0 {
			retryTime = defaultRetryAfter
		}
		if retryTime > maxRetryAfter {
			retryTime = maxRetryAfter
		}
		c.logger.Printf("Thunderstorm has no free capacities for file '%s', retrying in %d seconds", info.path, retryTime)
		return true, time.Second * time.Duration(retryTime)
	}
	c.recordAnswer()
	if err != nil {
		c.logger.Printf("Could not read response body for file '%s': %v", info.path, err)
		atomic.AddInt64(&c.Statistics.uploadErrors, 1)
		return false, 0
	}
	if response.StatusCode != http.StatusOK {
		atomic.AddInt64(&c.Statistics.uploadErrors, 1)
		c.logger.Printf("Received error from Thunderstorm for file '%s': %d%s %v\n", info.path, response.StatusCode, redirectHint(response), string(responseBody))
		return false, 0
	}
	transmitDuration := time.Since(transmitStart)
	atomic.AddInt64(&c.Statistics.timeTransmitting, int64(transmitDuration))

	atomic.AddInt64(&c.Statistics.uploadedFiles, 1)
	if c.Sync {
		c.logger.Printf("Response to file '%s': %s", info.path, string(responseBody))
	}

	c.debugf("File '%s' processed successfully", info.path)
	return false, 0
}

// selectFile applies the content filters (extension and magic header) and
// reports whether the file is to be sent. It opens the file only to read a
// magic header or, in a dry run, to show that the file can be read; a skipped
// or unreadable file is logged and counted here.
func (c *Collector) selectFile(info *infoWithPath) bool {
	readStart := time.Now()
	defer func() {
		atomic.AddInt64(&c.Statistics.timeReading, int64(time.Since(readStart)))
	}()
	var f *os.File
	needsHeader := len(c.MagicHeaders) > 0 && !c.extensionWanted(info.path)
	if needsHeader || c.DryRun {
		var ok bool
		if f, _, ok = c.openSelected(info); !ok {
			return false
		}
		defer f.Close()
	}
	if skipReason, excluded := c.checkFileContent(info, f); excluded {
		c.debugf("Skipping file '%s' (%s)", info.path, skipReason.String())
		c.Statistics.incrementSkipReason(skipReason)
		return false
	}
	return true
}

// openSelected opens a file that the walk selected and checks it against what
// the walk saw, see checkOpenedFile. It returns the open file and the size to
// send. Otherwise the reason is logged and counted here: a file that vanished
// is only noted in debug output, one that grew past the size limit is skipped,
// anything else is a file error.
func (c *Collector) openSelected(info *infoWithPath) (*os.File, int64, bool) {
	f, err := openSelectedFile(info.path)
	if err != nil {
		if os.IsNotExist(err) {
			c.debugf("Skipping '%s', it vanished before it could be read: %v", info.path, err)
			return nil, 0, false
		}
		c.logger.Printf("Could not open file '%s': %v\n", info.path, err)
		atomic.AddInt64(&c.Statistics.fileErrors, 1)
		return nil, 0, false
	}
	size, skipReason, excluded, err := c.checkOpenedFile(info, f)
	if err != nil {
		f.Close()
		c.logger.Printf("Could not read file '%s': %v\n", info.path, err)
		atomic.AddInt64(&c.Statistics.fileErrors, 1)
		return nil, 0, false
	}
	if excluded {
		f.Close()
		c.debugf("Skipping file '%s' (%s)", info.path, skipReason.String())
		c.Statistics.incrementSkipReason(skipReason)
		return nil, 0, false
	}
	return f, size, true
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
	extensionWanted := c.extensionWanted(info.path)

	var magicHeaderWanted bool
	// Only check magic headers if:
	// 1. Magic headers are configured, AND
	// 2. Either no extensions matched, OR no extensions are configured
	if len(c.MagicHeaders) > 0 && !extensionWanted {
		headerBuffer := make([]byte, c.magicHeaderExtractionLength)
		// A file shorter than the longest magic header ends the read with io.EOF;
		// what was read can still start with a shorter header.
		readLength, err := f.ReadAt(headerBuffer, 0)
		if err != nil && err != io.EOF {
			c.debugf("Could not read magic header for file '%s': %v", info.path, err)
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

// extensionWanted reports whether the path ends in one of the configured
// extensions. Extensions are matched case-insensitively: Windows (and the
// default macOS filesystem) treat RUN.EXE and run.exe as the same file type.
func (c *Collector) extensionWanted(path string) bool {
	lowerPath := strings.ToLower(path)
	for _, extension := range c.FileExtensions {
		if strings.HasSuffix(lowerPath, strings.ToLower(extension)) {
			return true
		}
	}
	return false
}

func (c *Collector) thunderstormUrl() string {
	var urlParams = url.Values{}
	if c.Source != "" {
		urlParams.Add("source", c.Source)
	}
	if c.scanID != "" {
		urlParams.Add("scan_id", c.scanID)
	}

	var apiEndpoint string
	if c.Sync {
		apiEndpoint = "api/check"
	} else {
		apiEndpoint = "api/checkAsync"
	}

	return fmt.Sprintf("%s/%s?%s", c.Server, apiEndpoint, urlParams.Encode())
}

// headerParamEscaper escapes a value placed inside a quoted MIME header parameter.
// Backslash and double quote use backslash escapes. CR and LF are percent-encoded,
// which is what CreateFormFile does since Go 1.26; earlier toolchains, including
// the Go 1.10 used for most release binaries, leave them untouched, so a file name
// containing them would inject MIME headers or end the part header early. The
// other control characters (except TAB) and DEL are percent-encoded as well:
// Go's multipart parser rejects such a header with "malformed MIME header line",
// so the server would answer HTTP 400 and the file would never be collected. File
// names on a host under investigation are untrusted.
var headerParamEscaper = newHeaderParamEscaper()

func newHeaderParamEscaper() *strings.Replacer {
	pairs := []string{"\\", "\\\\", `"`, "\\\""}
	for c := 0; c < 0x20; c++ {
		if c != '\t' {
			pairs = append(pairs, string(rune(c)), fmt.Sprintf("%%%02X", c))
		}
	}
	return strings.NewReplacer(append(pairs, "\x7f", "%7F")...)
}

// formFileHeader returns the header of the multipart part that carries a file.
func formFileHeader(fieldName string, fileName string) textproto.MIMEHeader {
	h := make(textproto.MIMEHeader)
	h.Set("Content-Disposition",
		fmt.Sprintf(`form-data; name="%s"; filename="%s"`,
			headerParamEscaper.Replace(fieldName), headerParamEscaper.Replace(fileName)))
	h.Set("Content-Type", "application/octet-stream")
	return h
}

// checkOpenedFile checks the opened file against what the walk selected: it
// must still be the same regular file, and its current size, which bounds what
// is sent, must still be within the size limit. A file that grew past the limit
// is skipped; anything else that changed is an error.
func (c *Collector) checkOpenedFile(info *infoWithPath, f *os.File) (size int64, reason SkipReason, excluded bool, err error) {
	current, err := f.Stat()
	if err != nil {
		return 0, 0, false, err
	}
	if !current.Mode().IsRegular() {
		return 0, 0, false, fmt.Errorf("it is no longer a regular file (%v)", current.Mode())
	}
	if !sameFile(info.FileInfo, current) {
		return 0, 0, false, errors.New("it was replaced after the walk selected it")
	}
	if c.MaxFileSize > 0 && current.Size() > c.MaxFileSize {
		return 0, SkipReasonTooBig, true, nil
	}
	return current.Size(), 0, false, nil
}

// fileReadError records why the file content could not be produced for an
// upload. It is set by the goroutine that writes the form data.
type fileReadError struct {
	mutex sync.Mutex
	err   error
}

func (e *fileReadError) set(err error) {
	e.mutex.Lock()
	e.err = err
	e.mutex.Unlock()
}

func (e *fileReadError) get() error {
	e.mutex.Lock()
	defer e.mutex.Unlock()
	return e.err
}

// getFileContentAsFormData creates multipart form data from a file for HTTP upload.
// It sends exactly size bytes, the size checked after opening: a file that grows
// meanwhile is sent up to that size, and a file that shrinks fails the upload.
// Returns the Content-Type header value (including boundary), a PipeReader for
// the form data and the place where a read error of the file is recorded.
func (c *Collector) getFileContentAsFormData(f *os.File, filename string, size int64) (string, *io.PipeReader, *fileReadError) {
	multipartReader, multipartWriter := io.Pipe()
	w := multipart.NewWriter(multipartWriter)
	readError := &fileReadError{}
	abspath, err := filepath.Abs(filename)
	if err != nil {
		abspath = filename
	}
	go func() {
		fw, err := w.CreatePart(formFileHeader("file", abspath))
		if err != nil {
			multipartWriter.CloseWithError(fmt.Errorf("could not create form file: %v", err))
			return
		}
		written, err := io.Copy(fw, &fileReader{io.LimitReader(f, size)})
		if err == nil && written < size {
			err = fileError{fmt.Errorf("the file shrank from %d to %d bytes while it was read", size, written)}
		}
		if err != nil {
			if fileErr, isFileErr := err.(fileError); isFileErr {
				readError.set(fileErr.err)
			}
			multipartWriter.CloseWithError(fmt.Errorf("could not copy file content: %v", err))
			return
		}
		if err := w.Close(); err != nil {
			multipartWriter.CloseWithError(fmt.Errorf("could not close multipart writer: %v", err))
			return
		}
		multipartWriter.Close()
	}()
	return w.FormDataContentType(), multipartReader, readError
}

// fileError marks an error that came from reading the file, as opposed to
// writing to the connection.
type fileError struct {
	err error
}

func (e fileError) Error() string {
	return e.err.Error()
}

// fileReader wraps read errors of the file in fileError.
type fileReader struct {
	reader io.Reader
}

func (r *fileReader) Read(p []byte) (int, error) {
	n, err := r.reader.Read(p)
	if err != nil && err != io.EOF {
		err = fileError{err}
	}
	return n, err
}
