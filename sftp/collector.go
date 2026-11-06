package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net"
	"net/http"
	"net/textproto"
	"net/url"
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
	decisionNotSent     = "not-sent"
)

// Statistics counts what the run listed, read and sent. HeaderBytes and
// ContentBytes are file data requested from the source; the listing itself
// carries no file data.
type Statistics struct {
	DirectoriesListed int64 `json:"directories_listed"`
	FilesListed       int64 `json:"files_listed"`
	Symlinks          int64 `json:"symlinks"`
	Irregular         int64 `json:"irregular"`
	Excluded          int64 `json:"excluded"`
	TooBig            int64 `json:"too_big"`
	TooOld            int64 `json:"too_old"`
	WrongType         int64 `json:"wrong_type"`
	HeaderReads       int64 `json:"header_reads"`
	HeaderBytes       int64 `json:"header_bytes"`
	Selected          int64 `json:"selected"`
	Uploaded          int64 `json:"uploaded"`
	ContentBytes      int64 `json:"content_bytes"`
	FileErrors        int64 `json:"file_errors"`
	UploadErrors      int64 `json:"upload_errors"`
	RootErrors        int64 `json:"root_errors"`
	WalkErrors        int64 `json:"walk_errors"`
	// ConnectionErrors is 1 when the SSH connection to the source was lost or
	// closed because the source stopped answering: the listing is incomplete.
	ConnectionErrors int64 `json:"connection_errors"`
	// NotSent counts selected files that were not sent because the run stopped
	// (Thunderstorm unreachable for server-wait, or an interruption).
	NotSent     int64 `json:"not_sent"`
	Interrupted int64 `json:"interrupted"`
	// MarkerErrors counts collection markers that a server supporting them did
	// not accept, see markers.go.
	MarkerErrors    int64   `json:"marker_errors"`
	DurationSeconds float64 `json:"duration_seconds"`
}

// ErrorCount returns the failures that make the run unsuccessful, as in the Go
// collector: selected files that could not be read or sent, roots that could
// not be read, a lost connection, an interrupted run and collection markers
// that were not accepted. Unreadable directories below a root are only
// reported.
func (s *Statistics) ErrorCount() int64 {
	return atomic.LoadInt64(&s.FileErrors) + atomic.LoadInt64(&s.UploadErrors) + atomic.LoadInt64(&s.RootErrors) +
		atomic.LoadInt64(&s.ConnectionErrors) + atomic.LoadInt64(&s.NotSent) + atomic.LoadInt64(&s.Interrupted) +
		atomic.LoadInt64(&s.MarkerErrors)
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
	now         func() time.Time

	// watchdog marks pending SFTP calls; nil when the client has none.
	watchdog *sftpWatchdog
	// closeSource closes the connection to the source on an interruption.
	closeSource func()
	queue       *directoryQueue

	// ctx ends pending uploads and retry waits when the run is interrupted.
	ctx    context.Context
	cancel context.CancelFunc

	// stopped is 1 once no more files are sent: Thunderstorm stayed
	// unreachable, the run was interrupted or the connection was lost.
	stopped        int32
	connectionLost int32
	// undelivered counts files in a row that got no answer from Thunderstorm
	// (transport errors, or 503 until the retries were used up).
	undelivered atomic.Int64
	checking    sync.RWMutex

	// pseudoDirectories are skipped below a root of /: listing /proc or reading
	// its files can block or stream without end, and their sizes are not real.
	pseudoDirectories map[string]bool
	// rootAliases maps a root given as a symbolic link to its target, so that
	// excludes written for the given path still apply below the target.
	rootAliases []rootAlias

	// Collection markers, see markers.go. scanID and markersActive are set by
	// BeginRun before Run and only read afterwards.
	startTime     time.Time
	markerTimeout time.Duration
	scanID        string
	markersActive bool
}

type rootAlias struct {
	resolved string
	given    string
}

func NewCollector(settings Settings, sftpClient *sftp.Client, httpClient *http.Client, logger *log.Logger, manifest *manifestWriter) *Collector {
	ctx, cancel := context.WithCancel(context.Background())
	c := &Collector{
		Settings:   settings,
		sftp:       sftpClient,
		client:     httpClient,
		logger:     logger,
		manifest:   manifest,
		files:      make(chan candidate, settings.Threads),
		retrySleep: time.Sleep,
		now:        time.Now,
		ctx:        ctx,
		cancel:     cancel,

		startTime:     time.Now(),
		markerTimeout: markerTimeout,
	}
	for _, root := range settings.RootPaths {
		if path.Clean(root) == "/" {
			c.pseudoDirectories = map[string]bool{"/proc": true, "/sys": true, "/dev": true}
		}
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
	c.queue = queue
	if c.pseudoDirectories != nil {
		c.logger.Print("Below the root /, the pseudo filesystems /proc, /sys and /dev are skipped; give them as roots to list them")
	}
	walked := make(map[string]string)
	for _, root := range c.RootPaths {
		if c.isStopped() {
			break
		}
		c.logger.Printf("Listing '%s' on the source", root)
		if glob := c.exclusion(root); glob != "" {
			c.logger.Printf("Scan root '%s' is excluded by %s", root, glob)
			atomic.AddInt64(&c.Stats.Excluded, 1)
			continue
		}
		resolved, key, info, err := c.resolveRoot(root)
		if err != nil {
			if !c.noteConnectionLoss(err) {
				atomic.AddInt64(&c.Stats.RootErrors, 1)
			}
			c.logger.Printf("Could not read scan root '%s': %v", root, err)
			continue
		}
		if earlier, seen := walked[key]; seen {
			c.logger.Printf("Scan root '%s' is the same as '%s'; it is listed once", root, earlier)
			continue
		}
		walked[key] = root
		if resolved != path.Clean(root) && info.IsDir() {
			c.rootAliases = append(c.rootAliases, rootAlias{resolved: resolved, given: root})
		}
		c.classify(queue, walkEntry{path: resolved, isRoot: true}, info)
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

// resolveRoot returns the path to list for a root and its attributes. A root
// that is a symbolic link is followed (READLINK, as servers differ in whether
// REALPATH resolves links); otherwise only its name would be recorded and
// nothing below it collected. key identifies the directory for duplicates.
func (c *Collector) resolveRoot(root string) (resolved string, key string, info os.FileInfo, err error) {
	resolved = path.Clean(root)
	for links := 0; ; links++ {
		if err := c.call(func() (err error) { info, err = c.sftp.Lstat(resolved); return }); err != nil {
			return "", "", nil, err
		}
		if info.Mode()&os.ModeSymlink == 0 {
			break
		}
		if links == 40 {
			return "", "", nil, errors.New("too many levels of symbolic links")
		}
		var target string
		if err := c.call(func() (err error) { target, err = c.sftp.ReadLink(resolved); return }); err != nil {
			return "", "", nil, fmt.Errorf("could not read the symbolic link %s: %w", resolved, err)
		}
		if !path.IsAbs(target) {
			target = path.Join(path.Dir(resolved), target)
		}
		resolved = path.Clean(target)
	}
	if resolved != path.Clean(root) {
		c.logger.Printf("Scan root '%s' is a symbolic link to '%s'; listing '%s'", root, resolved, resolved)
	}
	key = resolved
	if canonical, err := c.sftp.RealPath(resolved); err == nil {
		key = canonical
	}
	return resolved, key, info, nil
}

// call runs one SFTP call under the watchdog.
func (c *Collector) call(f func() error) error {
	c.watchdog.begin()
	defer c.watchdog.end()
	return f()
}

// isConnectionLoss reports whether err means the SSH connection is gone, as
// opposed to an SFTP status such as permission denied.
func isConnectionLoss(err error) bool {
	var status *sftp.StatusError
	var urlErr *url.Error
	if errors.As(err, &status) || errors.As(err, &urlErr) {
		return false
	}
	var netErr net.Error
	return errors.Is(err, sftp.ErrSSHFxConnectionLost) || errors.Is(err, io.EOF) ||
		errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, io.ErrClosedPipe) ||
		errors.Is(err, net.ErrClosed) || errors.As(err, &netErr)
}

// noteConnectionLoss records a lost connection once and stops the run, since
// every further SFTP call fails. It reports whether err was such a loss.
func (c *Collector) noteConnectionLoss(err error) bool {
	if !isConnectionLoss(err) {
		return false
	}
	if atomic.CompareAndSwapInt32(&c.connectionLost, 0, 1) {
		if atomic.LoadInt64(&c.Stats.Interrupted) == 0 {
			atomic.StoreInt64(&c.Stats.ConnectionErrors, 1)
			c.logger.Printf("The SFTP connection to the source was lost (%v); the collection is incomplete", err)
		}
		c.stop()
	}
	return true
}

func (c *Collector) isStopped() bool {
	return atomic.LoadInt32(&c.stopped) == 1
}

// stop ends listing and sending; queued files are counted as not sent.
func (c *Collector) stop() {
	atomic.StoreInt32(&c.stopped, 1)
	if c.queue != nil {
		c.queue.abort()
	}
}

// Interrupt stops the run after SIGINT or SIGTERM: pending uploads and waits
// end, and closing the source connection fails every pending SFTP call.
func (c *Collector) Interrupt() {
	atomic.StoreInt64(&c.Stats.Interrupted, 1)
	c.stop()
	c.cancel()
	if c.closeSource != nil {
		c.closeSource()
	}
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
	aborted bool
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
	for len(q.pending) == 0 && q.active > 0 && !q.aborted {
		q.ready.Wait()
	}
	if len(q.pending) == 0 || q.aborted {
		return walkEntry{}, false
	}
	directory := q.pending[len(q.pending)-1]
	q.pending = q.pending[:len(q.pending)-1]
	q.active++
	return directory, true
}

// abort makes next return false from now on.
func (q *directoryQueue) abort() {
	q.mutex.Lock()
	q.aborted = true
	q.mutex.Unlock()
	q.ready.Broadcast()
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
	var entries []os.FileInfo
	err := c.call(func() (err error) { entries, err = c.sftp.ReadDir(directory.path); return })
	if err != nil {
		if c.noteConnectionLoss(err) {
			return
		}
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
		if c.isStopped() {
			return
		}
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
	case mode.IsDir() && !entry.isRoot && c.pseudoDirectories[entry.path]:
		c.debugf("Skipping '%s', a pseudo filesystem below the root /", entry.path)
		atomic.AddInt64(&c.Stats.Excluded, 1)
		c.record(entry.path, info, decisionExcluded, nil)
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
	candidates := []string{entryPath}
	for _, alias := range c.rootAliases {
		if entryPath == alias.resolved || strings.HasPrefix(entryPath, strings.TrimSuffix(alias.resolved, "/")+"/") {
			candidates = append(candidates, path.Join(alias.given, strings.TrimPrefix(entryPath, alias.resolved)))
		}
	}
	for _, glob := range c.ExcludeGlobs {
		for _, candidate := range candidates {
			if match, _ := doublestar.Match(glob, candidate); match {
				return glob
			}
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
	if c.isStopped() {
		c.notSent(candidate)
		return
	}
	var file *sftp.File
	if !candidate.typeKnown || !c.DryRun {
		err := c.call(func() (err error) { file, err = c.sftp.Open(candidate.path); return })
		if err != nil {
			c.fileError(candidate, "Could not open", 0, err)
			return
		}
		defer c.call(file.Close)
	}

	var headerBytes int64
	if !candidate.typeKnown {
		// One READ request for exactly the bytes the longest header needs. A
		// shorter file ends with io.EOF; any other error is a failed check.
		header := make([]byte, c.magicLength)
		var n int
		err := c.call(func() (err error) { n, err = file.ReadAt(header, 0); return })
		headerBytes = int64(n)
		atomic.AddInt64(&c.Stats.HeaderReads, 1)
		atomic.AddInt64(&c.Stats.HeaderBytes, headerBytes)
		if err != nil && err != io.EOF {
			c.fileError(candidate, "Could not read the header of", headerBytes, err)
			return
		}
		if !c.headerWanted(header[:n]) {
			c.skip(candidate.path, candidate.info, decisionWrongType, &c.Stats.WrongType)
			return
		}
	}

	if c.DryRun {
		atomic.AddInt64(&c.Stats.Selected, 1)
		c.debugf("File '%s' would be sent (DRY-RUN)", candidate.path)
		atomic.AddInt64(&c.Stats.Uploaded, 1)
		c.record(candidate.path, candidate.info, decisionWouldUpload, func(e *manifestEntry) { e.HeaderBytes = headerBytes })
		return
	}

	// The listing may be stale: check the open file itself. Exactly its current
	// size is sent, so a growing file cannot exceed the limit and a pseudo file
	// that lists as empty cannot stream without end.
	var current os.FileInfo
	if err := c.call(func() (err error) { current, err = file.Stat(); return }); err != nil {
		c.fileError(candidate, "Could not read the attributes of", headerBytes, err)
		return
	}
	if !current.Mode().IsRegular() {
		c.fileError(candidate, "Not sending", headerBytes, fmt.Errorf("it is no longer a regular file (%v)", current.Mode()))
		return
	}
	if current.Size() > c.MaxFileSize {
		c.skip(candidate.path, candidate.info, decisionTooBig, &c.Stats.TooBig)
		return
	}
	atomic.AddInt64(&c.Stats.Selected, 1)

	c.waitWhileThunderstormIsChecked()
	if c.isStopped() {
		c.notSent(candidate)
		return
	}
	result, err := c.uploadWithRetries(file, candidate.path, current.Size())
	if err != nil {
		if c.ctx.Err() != nil || (result.readFailed && c.noteConnectionLoss(err)) {
			c.notSent(candidate)
			return
		}
		c.logger.Printf("Could not send '%s' to Thunderstorm: %v", candidate.path, err)
		if result.readFailed {
			atomic.AddInt64(&c.Stats.FileErrors, 1)
		} else {
			atomic.AddInt64(&c.Stats.UploadErrors, 1)
		}
		c.record(candidate.path, candidate.info, decisionError, func(e *manifestEntry) {
			e.HeaderBytes, e.ReadBytes, e.Error = headerBytes, result.bytes, err.Error()
		})
		if result.undeliverable {
			c.recordUndeliverable()
		} else if !result.readFailed {
			c.recordAnswer()
		}
		return
	}
	c.recordAnswer()
	atomic.AddInt64(&c.Stats.Uploaded, 1)
	if c.Sync {
		c.logger.Printf("Response to '%s': %s", candidate.path, result.response)
	}
	c.debugf("File '%s' sent (%d bytes)", candidate.path, result.bytes)
	c.record(candidate.path, candidate.info, decisionUploaded, func(e *manifestEntry) {
		e.HeaderBytes, e.ReadBytes, e.SHA256 = headerBytes, result.bytes, result.sha256
	})
}

// fileError counts a file that could not be read; after a lost connection
// the file is only counted as not sent.
func (c *Collector) fileError(candidate candidate, action string, headerBytes int64, err error) {
	if c.noteConnectionLoss(err) {
		c.notSent(candidate)
		return
	}
	c.logger.Printf("%s '%s': %v", action, candidate.path, err)
	atomic.AddInt64(&c.Stats.FileErrors, 1)
	c.record(candidate.path, candidate.info, decisionError, func(e *manifestEntry) {
		e.HeaderBytes, e.Error = headerBytes, err.Error()
	})
}

func (c *Collector) notSent(candidate candidate) {
	atomic.AddInt64(&c.Stats.NotSent, 1)
	c.record(candidate.path, candidate.info, decisionNotSent, nil)
}

// outageThreshold is the number of files in a row that must get no answer
// from Thunderstorm before the collector stops sending and waits for it.
const outageThreshold = 3

// Delays between the /api/status polls while Thunderstorm is unreachable.
const (
	outageFirstPollDelay = 2 * time.Second
	outageMaxPollDelay   = 60 * time.Second
)

func (c *Collector) recordAnswer() {
	c.undelivered.Store(0)
}

// recordUndeliverable notes a file that got no answer from Thunderstorm. After
// outageThreshold such files in a row, this worker polls /api/status for up to
// ServerWait while the others wait; then the run continues with the next file
// or stops.
func (c *Collector) recordUndeliverable() {
	if c.undelivered.Add(1) < outageThreshold {
		return
	}
	c.checking.Lock()
	defer c.checking.Unlock()
	if c.isStopped() || c.undelivered.Load() < outageThreshold {
		return
	}
	if c.waitForThunderstorm() {
		c.undelivered.Store(0)
		return
	}
	c.stop()
}

func (c *Collector) waitForThunderstorm() bool {
	start := c.now()
	c.logger.Printf("Thunderstorm did not accept %d files in a row; checking %s for up to %v before sending more", outageThreshold, c.StatusURL, c.ServerWait)
	delay := outageFirstPollDelay
	for c.ctx.Err() == nil {
		remaining := c.ServerWait - c.now().Sub(start)
		if remaining <= 0 {
			break
		}
		if delay > remaining {
			delay = remaining
		}
		c.retrySleep(delay)
		if c.ctx.Err() != nil {
			break
		}
		err := checkThunderstorm(c.client, c.StatusURL)
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
	if c.ctx.Err() == nil {
		c.logger.Printf("Thunderstorm unreachable for %v, stopping the collection; the remaining files are not sent", c.now().Sub(start).Round(time.Second))
	}
	return false
}

func (c *Collector) waitWhileThunderstormIsChecked() {
	c.checking.RLock()
	c.checking.RUnlock()
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
	// undeliverable is set when no attempt got an answer from Thunderstorm
	// other than 503 (busy).
	undeliverable bool
}

// permanentError marks an upload failure that a retry would only repeat.
type permanentError struct{ error }

// uploadWithRetries sends the file and retries like the Go collector: network
// errors with exponential backoff, HTTP 503 after Retry-After. Each attempt
// reads the file again from the start and sends exactly size bytes.
func (c *Collector) uploadWithRetries(file *sftp.File, remotePath string, size int64) (uploadResult, error) {
	undeliverable := true
	for attempt := uint(0); ; attempt++ {
		if _, err := file.Seek(0, io.SeekStart); err != nil {
			return uploadResult{readFailed: true}, err
		}
		result, status, retryAfter, err := c.upload(file, remotePath, size)
		if status != 0 && status != http.StatusServiceUnavailable {
			undeliverable = false
		}
		result.undeliverable = undeliverable && !result.readFailed
		var permanent permanentError
		switch {
		case result.readFailed, errors.As(err, &permanent):
			return result, err
		case c.ctx.Err() != nil:
			return result, fmt.Errorf("interrupted: %v", err)
		case err != nil && attempt < maxRetries:
			c.logger.Printf("Could not send '%s', will try again: %v", remotePath, err)
			c.sleep(baseRetryDelay << attempt)
		case err != nil:
			return result, err
		case status == http.StatusServiceUnavailable && attempt < maxRetries:
			c.logger.Printf("Thunderstorm has no free capacity for '%s', retrying in %d seconds", remotePath, retryAfter)
			c.sleep(time.Duration(retryAfter) * time.Second)
		case status != http.StatusOK:
			return result, fmt.Errorf("Thunderstorm answered %d: %s", status, result.response)
		default:
			return result, nil
		}
	}
}

// sleep waits for d unless the run is interrupted.
func (c *Collector) sleep(d time.Duration) {
	if c.ctx.Err() != nil {
		return
	}
	c.retrySleep(d)
}

// errBeyondSize ends a copy that would send more than the size checked after
// opening the file.
var errBeyondSize = errors.New("the file has more data than its size when it was opened")

// boundedWriter fails a write that would exceed limit bytes in total.
type boundedWriter struct {
	writer    io.Writer
	remaining int64
}

func (w *boundedWriter) Write(p []byte) (int, error) {
	if int64(len(p)) > w.remaining {
		return 0, errBeyondSize
	}
	n, err := w.writer.Write(p)
	w.remaining -= int64(n)
	return n, err
}

// upload streams one file as multipart form data: SFTP reads go straight into
// the request body, nothing is staged on disk. The remote path is the file
// name Thunderstorm reports. Exactly size bytes must be sent.
func (c *Collector) upload(file *sftp.File, remotePath string, size int64) (result uploadResult, status int, retryAfter int, err error) {
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
			destination := &boundedWriter{writer: io.MultiWriter(part, hasher, counter), remaining: size}
			c.watchdog.begin()
			sent.bytes, err = io.Copy(destination, file)
			c.watchdog.end()
			switch {
			case errors.Is(err, errBeyondSize):
				// The file grew or is a pseudo file: what was sent is not the file.
				sent.readFailed = true
			case err == nil && sent.bytes != size:
				err = fmt.Errorf("the file shrank from %d to %d bytes while it was read", size, sent.bytes)
				sent.readFailed = true
			default:
				// A closed pipe means the HTTP side stopped reading; anything
				// else is a failed read on the source.
				sent.readFailed = err != nil && !errors.Is(err, io.ErrClosedPipe)
			}
		}
		if err == nil {
			err = form.Close()
		}
		sent.copyErr = err
		bodyWriter.CloseWithError(err)
	}()

	request, err := http.NewRequestWithContext(c.ctx, http.MethodPost, c.UploadURL, body)
	if err != nil {
		body.Close()
		<-copied
		return result, 0, 0, permanentError{err}
	}
	request.Header.Set("Content-Type", form.FormDataContentType())
	response, postErr := c.client.Do(request)
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
		return result, status, retryAfter, fmt.Errorf("could not read file after %d bytes: %w", result.bytes, sent.copyErr)
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
