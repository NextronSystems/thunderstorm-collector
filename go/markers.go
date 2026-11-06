package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"net/http"
	"os"
	"sync/atomic"
	"time"
)

// Collection markers tell Thunderstorm where a collection run begins and ends.
// The collector sends a begin marker to POST /api/collection before the first
// upload. If the server answers with a scan ID, every upload of the run carries
// it as the scan_id query parameter, and the run ends with an end marker, or
// with an interrupted marker after SIGINT or SIGTERM. The format is the one the
// script collectors use; docs/COLLECTION_MARKERS.md describes it.
//
// Markers never stop a collection. A server that answers begin with 404 or 501
// does not support them (THOR 10 and the current THOR 11 versions), and the run
// continues exactly as without markers. Any other failed marker is reported and
// makes the exit status 1, but the files are still uploaded: the /api/status
// check already established that Thunderstorm is reachable.

const (
	collectorLabel = "go"

	markerTimeout    = 10 * time.Second
	markerRetryDelay = 2 * time.Second
	maxMarkerAnswer  = 64 * 1024
	maxScanIDLength  = 256
)

type markerStats struct {
	Scanned        int64 `json:"scanned"`
	Submitted      int64 `json:"submitted"`
	Skipped        int64 `json:"skipped"`
	Failed         int64 `json:"failed"`
	ScanErrors     int64 `json:"scan_errors"`
	ElapsedSeconds int64 `json:"elapsed_seconds"`
}

type collectionMarker struct {
	Type      string       `json:"type"`
	Source    string       `json:"source"`
	Hostname  string       `json:"hostname,omitempty"`
	Collector string       `json:"collector"`
	Timestamp string       `json:"timestamp"`
	ScanID    string       `json:"scan_id,omitempty"`
	Stats     *markerStats `json:"stats,omitempty"`
}

// newMarker returns a marker of the given type with the fields every marker
// carries. The run's stats are added to end and interrupted markers.
func (c *Collector) newMarker(markerType string) collectionMarker {
	hostname, _ := os.Hostname()
	marker := collectionMarker{
		Type:      markerType,
		Source:    c.Source,
		Hostname:  hostname,
		Collector: collectorLabel,
		Timestamp: time.Now().UTC().Format("2006-01-02T15:04:05Z"),
		ScanID:    c.scanID,
	}
	if markerType != "begin" {
		marker.Stats = c.markerStats()
	}
	return marker
}

func (c *Collector) markerStats() *markerStats {
	s := c.Statistics
	var skipped int64
	for _, reason := range []SkipReason{SkipReasonTooBig, SkipReasonWrongType, SkipReasonTooOld, SkipReasonIrregular, SkipReasonExcluded} {
		skipped += s.getSkipCount(reason)
	}
	return &markerStats{
		Scanned:        atomic.LoadInt64(&s.filesDiscovered),
		Submitted:      atomic.LoadInt64(&s.uploadedFiles),
		Skipped:        skipped,
		Failed:         atomic.LoadInt64(&s.fileErrors) + atomic.LoadInt64(&s.uploadErrors),
		ScanErrors:     atomic.LoadInt64(&s.rootErrors) + atomic.LoadInt64(&s.walkErrors),
		ElapsedSeconds: int64(time.Since(c.startTime) / time.Second),
	}
}

// markerAnswer is the outcome of one marker request.
type markerAnswer struct {
	status int
	body   []byte
	// tooLarge is true when the body was longer than maxMarkerAnswer; body then
	// holds only the first maxMarkerAnswer bytes.
	tooLarge bool
	err      error
	// redirect describes an unfollowed redirect, see redirectHint.
	redirect string
}

func (a markerAnswer) succeeded() bool {
	return a.err == nil && a.status >= 200 && a.status <= 299
}

// unsupported reports whether the server said that it has no marker endpoint.
func (a markerAnswer) unsupported() bool {
	return a.err == nil && (a.status == http.StatusNotFound || a.status == http.StatusNotImplemented)
}

func (a markerAnswer) String() string {
	if a.err != nil {
		return a.err.Error()
	}
	return fmt.Sprintf("HTTP %d%s", a.status, a.redirect)
}

func (c *Collector) sendMarker(marker collectionMarker) markerAnswer {
	payload, err := json.Marshal(marker)
	if err != nil {
		return markerAnswer{err: err}
	}
	request, err := http.NewRequest(http.MethodPost, c.Server+"/api/collection", bytes.NewReader(payload))
	if err != nil {
		return markerAnswer{err: err}
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := c.markerClient.Do(request)
	if err != nil {
		return markerAnswer{err: err}
	}
	defer response.Body.Close()
	body, err := ioutil.ReadAll(io.LimitReader(response.Body, maxMarkerAnswer+1))
	if err != nil {
		return markerAnswer{err: fmt.Errorf("could not read the answer: %v", err)}
	}
	answer := markerAnswer{status: response.StatusCode, body: body, redirect: redirectHint(response)}
	if len(body) > maxMarkerAnswer {
		answer.body, answer.tooLarge = body[:maxMarkerAnswer], true
	}
	return answer
}

// BeginRun sends the begin marker and, if the server returns a usable scan ID,
// stores it for the uploads. A failed begin is tried once more after
// markerRetryDelay.
func (c *Collector) BeginRun() {
	for attempt := 1; ; attempt++ {
		answer := c.sendMarker(c.newMarker("begin"))
		if answer.succeeded() {
			atomic.StoreInt32(&c.markersActive, 1)
			scanID, problem := parseScanID(answer)
			if problem != "" {
				c.logger.Printf("Thunderstorm accepted the collection begin marker, but %s; uploads carry no scan ID", problem)
				return
			}
			c.scanID = scanID
			c.logger.Printf("Thunderstorm assigned scan ID %s to this collection run", scanID)
			return
		}
		if answer.unsupported() {
			c.logger.Printf("Thunderstorm does not support collection markers (%s); continuing without a scan ID", answer)
			return
		}
		if attempt == 2 {
			atomic.AddInt64(&c.Statistics.markerErrors, 1)
			c.logger.Printf("Could not send the collection begin marker to Thunderstorm: %s; uploading without a scan ID", answer)
			return
		}
		c.logger.Printf("Could not send the collection begin marker to Thunderstorm, will try again in %v: %s", markerRetryDelay, answer)
		c.retrySleep(markerRetryDelay)
	}
}

// parseScanID returns the scan ID from a successful begin answer, or a
// description of why the answer holds none. Only a non-empty top-level string
// field scan_id counts. IDs that could not be passed on safely are refused.
func parseScanID(answer markerAnswer) (string, string) {
	if answer.tooLarge {
		return "", fmt.Sprintf("its answer is larger than %d bytes", maxMarkerAnswer)
	}
	var object map[string]interface{}
	if err := json.Unmarshal(answer.body, &object); err != nil || object == nil {
		return "", "its answer is not a JSON object"
	}
	value, present := object["scan_id"]
	if !present {
		return "", "its answer has no scan_id"
	}
	scanID, isString := value.(string)
	if !isString || scanID == "" {
		return "", "its scan_id is not a non-empty string"
	}
	if len(scanID) > maxScanIDLength {
		return "", fmt.Sprintf("its scan_id is longer than %d bytes", maxScanIDLength)
	}
	for _, r := range scanID {
		if r < 0x20 || r == 0x7f {
			return "", "its scan_id contains control characters"
		}
	}
	return scanID, ""
}

// EndRun sends the end marker after the last upload. Only a run whose begin
// marker was accepted is ended.
func (c *Collector) EndRun() {
	c.sendClosingMarker("end")
}

// InterruptRun sends the interrupted marker; the caller exits afterwards. The
// answer is logged, not counted: an interrupted run fails anyway.
func (c *Collector) InterruptRun() {
	c.sendClosingMarker("interrupted")
}

// MarkersActive reports whether the server accepted the begin marker.
func (c *Collector) MarkersActive() bool {
	return atomic.LoadInt32(&c.markersActive) == 1
}

// sendClosingMarker sends at most one end or interrupted marker per run, also
// when a signal arrives while the end marker is being sent.
func (c *Collector) sendClosingMarker(markerType string) {
	c.closingMutex.Lock()
	defer c.closingMutex.Unlock()
	if !c.MarkersActive() || c.closingSent {
		return
	}
	c.closingSent = true
	answer := c.sendMarker(c.newMarker(markerType))
	switch {
	case answer.succeeded(), answer.unsupported():
		c.debugf("Thunderstorm answered the collection %s marker with HTTP %d", markerType, answer.status)
	case markerType == "end":
		atomic.AddInt64(&c.Statistics.markerErrors, 1)
		c.logger.Printf("Could not send the collection end marker to Thunderstorm: %s", answer)
	default:
		c.logger.Printf("Could not send the collection %s marker to Thunderstorm: %s", markerType, answer)
	}
}
