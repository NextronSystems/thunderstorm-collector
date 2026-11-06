package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sync/atomic"
	"time"
)

// Collection markers tell Thunderstorm where a collection run begins and ends,
// in the format of the Go and script collectors (docs/COLLECTION_MARKERS.md).
// The begin marker goes to POST /api/collection once the source is connected.
// If the server answers with a scan ID, every upload of the run carries it as
// the scan_id query parameter. A run that lists everything ends with an end
// marker; a run that stops early (a signal, Thunderstorm unreachable for
// server-wait, or a lost source connection) ends with an interrupted marker.
//
// Markers never stop a collection. A server that answers begin with 404 or 501
// does not support them (THOR 10 and the current THOR 11 versions), and the run
// continues exactly as without markers. A begin or end marker that a server
// supporting them does not accept is reported and makes the exit status 1.

const (
	collectorLabel = "sftp"

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
	Type   string `json:"type"`
	Source string `json:"source"`
	// Hostname is the system that runs this collector, not the SFTP source.
	Hostname  string       `json:"hostname,omitempty"`
	Collector string       `json:"collector"`
	Timestamp string       `json:"timestamp"`
	ScanID    string       `json:"scan_id,omitempty"`
	Stats     *markerStats `json:"stats,omitempty"`
}

func (c *Collector) newMarker(markerType string) collectionMarker {
	hostname, _ := os.Hostname()
	marker := collectionMarker{
		Type:      markerType,
		Source:    c.Source,
		Hostname:  hostname,
		Collector: collectorLabel,
		Timestamp: c.now().UTC().Format("2006-01-02T15:04:05Z"),
		ScanID:    c.scanID,
	}
	if markerType != "begin" {
		s := &c.Stats
		marker.Stats = &markerStats{
			Scanned:   atomic.LoadInt64(&s.FilesListed) + atomic.LoadInt64(&s.Symlinks) + atomic.LoadInt64(&s.Irregular),
			Submitted: atomic.LoadInt64(&s.Uploaded),
			Skipped: atomic.LoadInt64(&s.TooBig) + atomic.LoadInt64(&s.TooOld) + atomic.LoadInt64(&s.WrongType) +
				atomic.LoadInt64(&s.Excluded) + atomic.LoadInt64(&s.Symlinks) + atomic.LoadInt64(&s.Irregular),
			Failed:         atomic.LoadInt64(&s.FileErrors) + atomic.LoadInt64(&s.UploadErrors),
			ScanErrors:     atomic.LoadInt64(&s.RootErrors) + atomic.LoadInt64(&s.WalkErrors) + atomic.LoadInt64(&s.ConnectionErrors),
			ElapsedSeconds: int64(c.now().Sub(c.startTime) / time.Second),
		}
	}
	return marker
}

// markerAnswer is the outcome of one marker request.
type markerAnswer struct {
	status   int
	body     []byte
	tooLarge bool
	location string
	err      error
}

func (a markerAnswer) succeeded() bool {
	return a.err == nil && a.status >= 200 && a.status <= 299
}

// unsupported reports whether the server said that it has no marker endpoint.
func (a markerAnswer) unsupported() bool {
	return a.err == nil && (a.status == http.StatusNotFound || a.status == http.StatusNotImplemented)
}

func (a markerAnswer) String() string {
	switch {
	case a.err != nil:
		return a.err.Error()
	case a.status >= 300 && a.status <= 399:
		return fmt.Sprintf("HTTP %d (redirect to %q, redirects are not followed)", a.status, a.location)
	}
	return fmt.Sprintf("HTTP %d", a.status)
}

// sendMarker posts one marker. It does not use the run's context, so that the
// interrupted marker still goes out after the run was cancelled.
func (c *Collector) sendMarker(marker collectionMarker) markerAnswer {
	payload, err := json.Marshal(marker)
	if err != nil {
		return markerAnswer{err: err}
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.markerTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, c.CollectionURL, bytes.NewReader(payload))
	if err != nil {
		return markerAnswer{err: err}
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := c.client.Do(request)
	if err != nil {
		return markerAnswer{err: err}
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, maxMarkerAnswer+1))
	if err != nil {
		return markerAnswer{err: fmt.Errorf("could not read the answer: %v", err)}
	}
	answer := markerAnswer{status: response.StatusCode, body: body, location: response.Header.Get("Location")}
	if len(body) > maxMarkerAnswer {
		answer.body, answer.tooLarge = body[:maxMarkerAnswer], true
	}
	return answer
}

// BeginRun sends the begin marker and, if the server returns a usable scan ID,
// adds it to the upload URL. A failed begin is tried once more after
// markerRetryDelay. Call it before Run.
func (c *Collector) BeginRun() {
	for attempt := 1; ; attempt++ {
		answer := c.sendMarker(c.newMarker("begin"))
		if answer.succeeded() {
			c.markersActive = true
			scanID, problem := parseScanID(answer)
			if problem != "" {
				c.logger.Printf("Thunderstorm accepted the collection begin marker, but %s; uploads carry no scan ID", problem)
				return
			}
			c.scanID = scanID
			c.UploadURL += "&scan_id=" + url.QueryEscape(scanID)
			c.logger.Printf("Thunderstorm assigned scan ID %s to this collection run", scanID)
			return
		}
		if answer.unsupported() {
			c.logger.Printf("Thunderstorm does not support collection markers (%s); continuing without a scan ID", answer)
			return
		}
		if attempt == 2 {
			atomic.AddInt64(&c.Stats.MarkerErrors, 1)
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

// FinishRun sends the closing marker after Run: end for a run that listed
// everything, interrupted for one that stopped early. Only a run whose begin
// marker was accepted is closed. A refused end fails the run; a refused
// interrupted marker is only logged, since the run fails anyway.
func (c *Collector) FinishRun() {
	if !c.markersActive {
		return
	}
	markerType := "end"
	if c.isStopped() {
		markerType = "interrupted"
	}
	answer := c.sendMarker(c.newMarker(markerType))
	switch {
	case answer.succeeded(), answer.unsupported():
		c.debugf("Thunderstorm answered the collection %s marker with HTTP %d", markerType, answer.status)
	case markerType == "end":
		atomic.AddInt64(&c.Stats.MarkerErrors, 1)
		c.logger.Printf("Could not send the collection end marker to Thunderstorm: %s", answer)
	default:
		c.logger.Printf("Could not send the collection %s marker to Thunderstorm: %s", markerType, answer)
	}
}
