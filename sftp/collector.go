package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"os"
	"path"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/bmatcuk/doublestar"
	"github.com/pkg/sftp"
)

// Decisions recorded per entry in the manifest and counted in the statistics.
const (
	decisionUploaded    = "uploaded"
	decisionWouldUpload = "would-upload"
	decisionTooBig      = "too-big"
	decisionTooOld      = "too-old"
	decisionWrongType   = "wrong-type"
	decisionExcluded    = "excluded"
	decisionDirectory   = "directory"
	decisionSymlink     = "symlink"
	decisionIrregular   = "irregular"
	decisionError       = "error"
)

// Statistics counts what the run listed, read and sent. HeaderBytes and
// ContentBytes are file data requested from the source; the listing itself
// carries no file data.
type Statistics struct {
	DirectoriesListed int64   `json:"directories_listed"`
	FilesListed       int64   `json:"files_listed"`
	Symlinks          int64   `json:"symlinks"`
	Irregular         int64   `json:"irregular"`
	Excluded          int64   `json:"excluded"`
	TooBig            int64   `json:"too_big"`
	TooOld            int64   `json:"too_old"`
	WrongType         int64   `json:"wrong_type"`
	HeaderReads       int64   `json:"header_reads"`
	HeaderBytes       int64   `json:"header_bytes"`
	Selected          int64   `json:"selected"`
	Uploaded          int64   `json:"uploaded"`
	ContentBytes      int64   `json:"content_bytes"`
	FileErrors        int64   `json:"file_errors"`
	UploadErrors      int64   `json:"upload_errors"`
	RootErrors        int64   `json:"root_errors"`
	WalkErrors        int64   `json:"walk_errors"`
	DurationSeconds   float64 `json:"duration_seconds"`
}

// ErrorCount returns the failures that make the run unsuccessful, as in the Go
// collector: selected files that could not be read or sent, and roots that
// could not be read. Unreadable directories below a root are only reported.
func (s *Statistics) ErrorCount() int64 {
	return atomic.LoadInt64(&s.FileErrors) + atomic.LoadInt64(&s.UploadErrors) + atomic.LoadInt64(&s.RootErrors)
}

// manifestEntry describes one listed entry. All fields except the read
// counters and the hash come from the directory listing.
type manifestEntry struct {
	Path        string    `json:"path"`
	Mode        string    `json:"mode"`
	Size        int64     `json:"size"`
	UID         uint32    `json:"uid"`
	GID         uint32    `json:"gid"`
	Mtime       time.Time `json:"mtime"`
	Atime       time.Time `json:"atime"`
	Decision    string    `json:"decision"`
	HeaderBytes int64     `json:"header_bytes,omitempty"`
	ReadBytes   int64     `json:"read_bytes,omitempty"`
	SHA256      string    `json:"sha256,omitempty"`
	Error       string    `json:"error,omitempty"`
}

type manifestWriter struct {
	mutex   sync.Mutex
	file    *os.File
	buffer  *bufio.Writer
	encoder *json.Encoder
}

func newManifestWriter(filename string) (*manifestWriter, error) {
	file, err := os.Create(filename)
	if err != nil {
		return nil, err
	}
	buffer := bufio.NewWriter(file)
	return &manifestWriter{file: file, buffer: buffer, encoder: json.NewEncoder(buffer)}, nil
}

func (m *manifestWriter) write(entry manifestEntry) {
	if m == nil {
		return
	}
	m.mutex.Lock()
	defer m.mutex.Unlock()
	m.encoder.Encode(entry)
}

func (m *manifestWriter) Close() error {
	if m == nil {
		return nil
	}
	if err := m.buffer.Flush(); err != nil {
		m.file.Close()
		return err
	}
	return m.file.Close()
}

type candidate struct {
	path string
	info os.FileInfo
	// typeKnown is true when the listing already decided the type filter
	// (extension, execute bit or no type filter); otherwise the header decides.
	typeKnown bool
}

type Collector struct {
	Settings
	sftp     *sftp.Client
	client   *http.Client
	logger   *log.Logger
	manifest *manifestWriter
	Stats    Statistics

	magicLength int
	files       chan candidate
	workerGroup sync.WaitGroup
	retrySleep  func(time.Duration)
}

func NewCollector(settings Settings, sftpClient *sftp.Client, httpClient *http.Client, logger *log.Logger, manifest *manifestWriter) *Collector {
	c := &Collector{
		Settings:   settings,
		sftp:       sftpClient,
		client:     httpClient,
		logger:     logger,
		manifest:   manifest,
		files:      make(chan candidate, settings.Threads),
		retrySleep: time.Sleep,
	}
	for _, header := range settings.MagicHeaders {
		if len(header) > c.magicLength {
			c.magicLength = len(header)
		}
	}
	return c
}

func (c *Collector) debugf(format string, args ...interface{}) {
	if c.Debug {
		c.logger.Printf("[DEBUG] "+format, args...)
	}
}

// Run lists every root, sends the candidates to the workers and returns when
// all of them are processed.
func (c *Collector) Run() {
	start := time.Now()
	for i := 0; i < c.Threads; i++ {
		c.workerGroup.Add(1)
		go func() {
			defer c.workerGroup.Done()
			for candidate := range c.files {
				c.process(candidate)
			}
		}()
	}
	queue := newDirectoryQueue()
	for _, root := range c.RootPaths {
		c.logger.Printf("Listing '%s' on the source", root)
		info, err := c.sftp.Lstat(root)
		if err != nil {
			atomic.AddInt64(&c.Stats.RootErrors, 1)
			c.logger.Printf("Could not read scan root '%s': %v", root, err)
			continue
		}
		if info.Mode()&os.ModeSymlink != 0 {
			c.logger.Printf("Scan root '%s' is a symlink and is not followed; give its target instead", root)
		}
		c.classify(queue, walkEntry{path: root, isRoot: true}, info)
	}
	var walkers sync.WaitGroup
	for i := 0; i < c.WalkThreads; i++ {
		walkers.Add(1)
		go func() {
			defer walkers.Done()
			c.walk(queue)
		}()
	}
	walkers.Wait()
	close(c.files)
	c.workerGroup.Wait()
	c.Stats.DurationSeconds = time.Since(start).Seconds()
}

type walkEntry struct {
	path   string
	isRoot bool
}

// directoryQueue holds the directories still to be listed. A fixed number of
// walkers take the most recently added one, so the queue grows with the depth
// of the tree rather than its width. A walker hands each selected file to the
// upload workers before it lists the next directory, so slow uploads hold back
// listing and at most walk-threads listings are in memory.
type directoryQueue struct {
	mutex   sync.Mutex
	ready   *sync.Cond
	pending []walkEntry
	active  int
}

func newDirectoryQueue() *directoryQueue {
	queue := &directoryQueue{}
	queue.ready = sync.NewCond(&queue.mutex)
	return queue
}

func (q *directoryQueue) push(directory walkEntry) {
	q.mutex.Lock()
	q.pending = append(q.pending, directory)
	q.mutex.Unlock()
	q.ready.Signal()
}

// next returns the next directory to list. It returns false once nothing is
// pending and no walker is listing, so nothing can be added any more.
func (q *directoryQueue) next() (walkEntry, bool) {
	q.mutex.Lock()
	defer q.mutex.Unlock()
	for len(q.pending) == 0 && q.active > 0 {
		q.ready.Wait()
	}
	if len(q.pending) == 0 {
		return walkEntry{}, false
	}
	directory := q.pending[len(q.pending)-1]
	q.pending = q.pending[:len(q.pending)-1]
	q.active++
	return directory, true
}

func (q *directoryQueue) done() {
	q.mutex.Lock()
	q.active--
	finished := q.active == 0 && len(q.pending) == 0
	q.mutex.Unlock()
	if finished {
		q.ready.Broadcast()
	}
}

func (c *Collector) walk(queue *directoryQueue) {
	for {
		directory, ok := queue.next()
		if !ok {
			return
		}
		c.listDirectory(queue, directory)
		queue.done()
	}
}

// listDirectory lists one directory. A READDIR reply carries the attributes of
// every entry (OpenSSH's sftp-server takes them with lstat), so no per-file
// STAT request is needed and symlinks are seen as links, never followed.
func (c *Collector) listDirectory(queue *directoryQueue, directory walkEntry) {
	entries, err := c.sftp.ReadDir(directory.path)
	if err != nil {
		if directory.isRoot {
			atomic.AddInt64(&c.Stats.RootErrors, 1)
			c.logger.Printf("Could not read scan root '%s': %v", directory.path, err)
		} else {
			atomic.AddInt64(&c.Stats.WalkErrors, 1)
			c.logger.Printf("Could not list '%s': %v", directory.path, err)
		}
		return
	}
	atomic.AddInt64(&c.Stats.DirectoriesListed, 1)
	for _, info := range entries {
		c.classify(queue, walkEntry{path: path.Join(directory.path, info.Name())}, info)
	}
}

// classify applies the exclusions and the entry type to a root or a listed
// entry alike: directories are queued, regular files considered, symlinks and
// other entries only recorded.
func (c *Collector) classify(queue *directoryQueue, entry walkEntry, info os.FileInfo) {
	if glob := c.exclusion(entry.path); glob != "" {
		c.debugf("Skipping '%s' due to exclusion rule %s", entry.path, glob)
		atomic.AddInt64(&c.Stats.Excluded, 1)
		c.record(entry.path, info, decisionExcluded, nil)
		return
	}
	switch mode := info.Mode(); {
	case mode.IsDir():
		c.record(entry.path, info, decisionDirectory, nil)
		queue.push(entry)
	case mode&os.ModeSymlink != 0:
		atomic.AddInt64(&c.Stats.Symlinks, 1)
		c.record(entry.path, info, decisionSymlink, nil)
	case mode.IsRegular():
		c.consider(entry.path, info)
	default:
		atomic.AddInt64(&c.Stats.Irregular, 1)
		c.record(entry.path, info, decisionIrregular, nil)
	}
}

func (c *Collector) exclusion(entryPath string) string {
	for _, glob := range c.ExcludeGlobs {
		if match, _ := doublestar.Match(glob, entryPath); match {
			return glob
		}
	}
	return ""
}

// consider applies the filters that the listing answers: size, modification
// time, extension and execute bit. Only a file that still needs its header
// checked, or is selected, goes to a worker.
func (c *Collector) consider(filePath string, info os.FileInfo) {
	atomic.AddInt64(&c.Stats.FilesListed, 1)
	if info.Size() > c.MaxFileSize {
		c.skip(filePath, info, decisionTooBig, &c.Stats.TooBig)
		return
	}
	if !c.Threshold.IsZero() && !info.ModTime().After(c.Threshold) {
		c.skip(filePath, info, decisionTooOld, &c.Stats.TooOld)
		return
	}
	typeKnown := c.typeFromListing(filePath, info)
	if !typeKnown && len(c.MagicHeaders) == 0 {
		c.skip(filePath, info, decisionWrongType, &c.Stats.WrongType)
		return
	}
	c.files <- candidate{path: filePath, info: info, typeKnown: typeKnown}
}

func (c *Collector) typeFromListing(filePath string, info os.FileInfo) bool {
	if len(c.Extensions) == 0 && len(c.MagicHeaders) == 0 && !c.Executable {
		return true
	}
	lowerPath := strings.ToLower(filePath)
	for _, extension := range c.Extensions {
		if strings.HasSuffix(lowerPath, extension) {
			return true
		}
	}
	return c.Executable && info.Mode().Perm()&0111 != 0
}

func (c *Collector) skip(filePath string, info os.FileInfo, decision string, counter *int64) {
	c.debugf("Skipping '%s' (%s)", filePath, decision)
	atomic.AddInt64(counter, 1)
	c.record(filePath, info, decision, nil)
}

func (c *Collector) record(entryPath string, info os.FileInfo, decision string, update func(*manifestEntry)) {
	if c.manifest == nil {
		return
	}
	entry := manifestEntry{
		Path:     entryPath,
		Mode:     info.Mode().String(),
		Size:     info.Size(),
		Mtime:    info.ModTime().UTC(),
		Decision: decision,
	}
	if stat, ok := info.Sys().(*sftp.FileStat); ok {
		entry.UID, entry.GID = stat.UID, stat.GID
		entry.Atime = time.Unix(int64(stat.Atime), 0).UTC()
	}
	if update != nil {
		update(&entry)
	}
	c.manifest.write(entry)
}

// process runs in a worker: it checks the header if the listing could not
// decide the type, then streams the file to Thunderstorm. A dry run of a file
// the listing already selected opens nothing.
func (c *Collector) process(candidate candidate) {
	var file *sftp.File
	if !candidate.typeKnown || !c.DryRun {
		var err error
		if file, err = c.sftp.Open(candidate.path); err != nil {
			c.logger.Printf("Could not open '%s': %v", candidate.path, err)
			atomic.AddInt64(&c.Stats.FileErrors, 1)
			c.record(candidate.path, candidate.info, decisionError, func(e *manifestEntry) { e.Error = err.Error() })
			return
		}
		defer file.Close()
	}

	var headerBytes int64
	if !candidate.typeKnown {
		// One READ request for exactly the bytes the longest header needs. A
		// shorter file ends with io.EOF; any other error is a failed check.
		header := make([]byte, c.magicLength)
		n, err := file.ReadAt(header, 0)
		headerBytes = int64(n)
		atomic.AddInt64(&c.Stats.HeaderReads, 1)
		atomic.AddInt64(&c.Stats.HeaderBytes, headerBytes)
		if err != nil && err != io.EOF {
			c.logger.Printf("Could not read the header of '%s': %v", candidate.path, err)
			atomic.AddInt64(&c.Stats.FileErrors, 1)
			c.record(candidate.path, candidate.info, decisionError, func(e *manifestEntry) {
				e.HeaderBytes, e.Error = headerBytes, err.Error()
			})
			return
		}
		if !c.headerWanted(header[:n]) {
			c.skip(candidate.path, candidate.info, decisionWrongType, &c.Stats.WrongType)
			return
		}
	}
	atomic.AddInt64(&c.Stats.Selected, 1)

	if c.DryRun {
		c.debugf("File '%s' would be sent (DRY-RUN)", candidate.path)
		atomic.AddInt64(&c.Stats.Uploaded, 1)
		c.record(candidate.path, candidate.info, decisionWouldUpload, func(e *manifestEntry) { e.HeaderBytes = headerBytes })
		return
	}

	result, err := c.uploadWithRetries(file, candidate.path)
	if err != nil {
		c.logger.Printf("Could not send '%s' to Thunderstorm: %v", candidate.path, err)
		if result.readFailed {
			atomic.AddInt64(&c.Stats.FileErrors, 1)
		} else {
			atomic.AddInt64(&c.Stats.UploadErrors, 1)
		}
		c.record(candidate.path, candidate.info, decisionError, func(e *manifestEntry) {
			e.HeaderBytes, e.ReadBytes, e.Error = headerBytes, result.bytes, err.Error()
		})
		return
	}
	atomic.AddInt64(&c.Stats.Uploaded, 1)
	if c.Sync {
		c.logger.Printf("Response to '%s': %s", candidate.path, result.response)
	}
	c.debugf("File '%s' sent (%d bytes)", candidate.path, result.bytes)
	c.record(candidate.path, candidate.info, decisionUploaded, func(e *manifestEntry) {
		e.HeaderBytes, e.ReadBytes, e.SHA256 = headerBytes, result.bytes, result.sha256
	})
}

func (c *Collector) headerWanted(header []byte) bool {
	for _, magic := range c.MagicHeaders {
		if bytes.HasPrefix(header, magic) {
			return true
		}
	}
	return false
}

const (
	maxRetries        = 3
	baseRetryDelay    = 4 * time.Second
	defaultRetryAfter = 30
	maxRetryAfter     = 120
)

// maxResponseBytes bounds a Thunderstorm answer. An asynchronous answer is a
// short JSON object; a synchronous one lists the results for one sample.
const maxResponseBytes = 16 << 20

type uploadResult struct {
	bytes      int64
	sha256     string
	response   string
	readFailed bool
	// copyErr is set when the request body was not sent completely, because
	// the file could not be read or because the HTTP side stopped reading.
	copyErr error
}

// permanentError marks an upload failure that a retry would only repeat.
type permanentError struct{ error }

// uploadWithRetries sends the file and retries like the Go collector: network
// errors with exponential backoff, HTTP 503 after Retry-After. Each attempt
// reads the file again from the start.
func (c *Collector) uploadWithRetries(file *sftp.File, remotePath string) (uploadResult, error) {
	for attempt := uint(0); ; attempt++ {
		if _, err := file.Seek(0, io.SeekStart); err != nil {
			return uploadResult{readFailed: true}, err
		}
		result, status, retryAfter, err := c.upload(file, remotePath)
		var permanent permanentError
		switch {
		case result.readFailed, errors.As(err, &permanent):
			return result, err
		case err != nil && attempt < maxRetries:
			c.logger.Printf("Could not send '%s', will try again: %v", remotePath, err)
			c.retrySleep(baseRetryDelay << attempt)
		case err != nil:
			return result, err
		case status == http.StatusServiceUnavailable && attempt < maxRetries:
			c.logger.Printf("Thunderstorm has no free capacity for '%s', retrying in %d seconds", remotePath, retryAfter)
			c.retrySleep(time.Duration(retryAfter) * time.Second)
		case status != http.StatusOK:
			return result, fmt.Errorf("Thunderstorm answered %d: %s", status, result.response)
		default:
			return result, nil
		}
	}
}

// upload streams one file as multipart form data: SFTP reads go straight into
// the request body, nothing is staged on disk. The remote path is the file
// name Thunderstorm reports.
func (c *Collector) upload(file *sftp.File, remotePath string) (result uploadResult, status int, retryAfter int, err error) {
	body, bodyWriter := io.Pipe()
	form := multipart.NewWriter(bodyWriter)
	hasher := sha256.New()
	counter := &countingWriter{total: &c.Stats.ContentBytes}
	copied := make(chan uploadResult, 1)
	go func() {
		var sent uploadResult
		defer func() { copied <- sent }()
		part, err := form.CreatePart(formFileHeader("file", remotePath))
		if err == nil {
			// *sftp.File implements io.WriterTo, so io.Copy keeps several READ
			// requests in flight instead of one round trip per 32 KiB.
			sent.bytes, err = io.Copy(io.MultiWriter(part, hasher, counter), file)
			// A closed pipe means the HTTP side stopped reading; anything
			// else is a failed read on the source.
			sent.readFailed = err != nil && !errors.Is(err, io.ErrClosedPipe)
		}
		if err == nil {
			err = form.Close()
		}
		sent.copyErr = err
		bodyWriter.CloseWithError(err)
	}()

	response, postErr := c.client.Post(c.UploadURL, form.FormDataContentType(), body)
	if postErr == nil {
		status = response.StatusCode
		responseBody, readErr := c.readResponse(response.Body)
		if readErr != nil {
			postErr = permanentError{readErr}
		}
		result.response = string(responseBody)
		if location := response.Header.Get("Location"); status >= 300 && status <= 399 {
			result.response += fmt.Sprintf(" (redirect to %q, redirects are not followed)", location)
		}
		if status == http.StatusServiceUnavailable {
			var parseErr error
			retryAfter, parseErr = strconv.Atoi(response.Header.Get("Retry-After"))
			if parseErr != nil || retryAfter < 0 {
				retryAfter = defaultRetryAfter
			}
			if retryAfter > maxRetryAfter {
				retryAfter = maxRetryAfter
			}
		}
	}
	body.Close()
	sent := <-copied
	result.bytes, result.readFailed, result.copyErr = sent.bytes, sent.readFailed, sent.copyErr
	result.sha256 = hex.EncodeToString(hasher.Sum(nil))
	switch {
	case result.readFailed:
		return result, status, retryAfter, fmt.Errorf("could not read file after %d bytes: %v", result.bytes, sent.copyErr)
	case postErr == nil && status == http.StatusOK && sent.copyErr != nil:
		// A 200 counts only for a sample that was sent completely.
		postErr = fmt.Errorf("Thunderstorm answered before the upload was complete (%d bytes read): %v", result.bytes, sent.copyErr)
	}
	return result, status, retryAfter, postErr
}

// readResponse reads an answer within the size limit and, when set, the
// response timeout; closing the body ends a read that does not finish.
func (c *Collector) readResponse(body io.ReadCloser) ([]byte, error) {
	defer body.Close()
	var timedOut int32
	if c.ResponseTimeout > 0 {
		timer := time.AfterFunc(c.ResponseTimeout, func() {
			atomic.StoreInt32(&timedOut, 1)
			body.Close()
		})
		defer timer.Stop()
	}
	data, err := io.ReadAll(io.LimitReader(body, maxResponseBytes+1))
	switch {
	case err != nil && atomic.LoadInt32(&timedOut) == 1:
		return data, fmt.Errorf("no complete response within %v", c.ResponseTimeout)
	case err != nil:
		return data, fmt.Errorf("could not read the response: %v", err)
	case len(data) > maxResponseBytes:
		return data[:maxResponseBytes], fmt.Errorf("the response exceeds %d bytes", maxResponseBytes)
	}
	return data, nil
}

type countingWriter struct{ total *int64 }

func (w *countingWriter) Write(p []byte) (int, error) {
	atomic.AddInt64(w.total, int64(len(p)))
	return len(p), nil
}

// headerParamEscaper and formFileHeader are the Go collector's: remote file
// names are untrusted and must not inject MIME headers.
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

func formFileHeader(fieldName string, fileName string) textproto.MIMEHeader {
	h := make(textproto.MIMEHeader)
	h.Set("Content-Disposition",
		fmt.Sprintf(`form-data; name="%s"; filename="%s"`,
			headerParamEscaper.Replace(fieldName), headerParamEscaper.Replace(fileName)))
	h.Set("Content-Type", "application/octet-stream")
	return h
}
