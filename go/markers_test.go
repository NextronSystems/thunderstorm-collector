package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

// markerServer is a Thunderstorm stand-in that records collection markers and
// the query of every upload. answers holds the status and body for successive
// marker requests; the last one repeats.
type markerServer struct {
	*httptest.Server
	mutex   sync.Mutex
	answers []markerReply
	markers []map[string]interface{}
	uploads []string
}

type markerReply struct {
	status int
	body   string
}

func newMarkerServer(answers ...markerReply) *markerServer {
	s := &markerServer{answers: answers}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := ioutil.ReadAll(r.Body)
		s.mutex.Lock()
		defer s.mutex.Unlock()
		switch r.URL.Path {
		case "/api/collection":
			var marker map[string]interface{}
			if err := json.Unmarshal(body, &marker); err != nil || r.Header.Get("Content-Type") != "application/json" {
				marker = map[string]interface{}{"invalid": string(body)}
			}
			s.markers = append(s.markers, marker)
			reply := s.answers[len(s.answers)-1]
			if len(s.markers) <= len(s.answers) {
				reply = s.answers[len(s.markers)-1]
			}
			if reply.status >= 300 && reply.status <= 399 {
				w.Header().Set("Location", "/login")
			}
			w.WriteHeader(reply.status)
			w.Write([]byte(reply.body))
		case "/api/checkAsync":
			s.uploads = append(s.uploads, r.URL.RawQuery)
			w.Write([]byte(`{"id": 1}`))
		default:
			http.NotFound(w, r)
		}
	}))
	return s
}

func (s *markerServer) recorded() ([]map[string]interface{}, []string) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	return append([]map[string]interface{}(nil), s.markers...), append([]string(nil), s.uploads...)
}

// runWithMarkers runs a collection of one small file against server, as main
// does, and returns the collector and its log.
func runWithMarkers(t *testing.T, server *markerServer, debug bool) (*Collector, string) {
	dir, err := ioutil.TempDir("", "collector-run-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	if err := ioutil.WriteFile(filepath.Join(dir, "sample.txt"), []byte("sample"), 0600); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	c := NewCollector(CollectorConfig{Server: server.URL, Threads: 1, RootPaths: []string{dir}, Source: "web 01&x", Debug: debug}, log.New(&output, "", 0))
	var slept []time.Duration
	c.retrySleep = func(d time.Duration) { slept = append(slept, d) }
	c.BeginRun()
	c.StartWorkers()
	c.Collect()
	c.Stop()
	c.EndRun()
	if len(slept) > 1 || (len(slept) == 1 && slept[0] != markerRetryDelay) {
		t.Errorf("unexpected retry waits %v", slept)
	}
	return c, output.String()
}

// markerLog returns the log lines that mention collection markers or scan IDs.
func markerLog(output string) []string {
	var lines []string
	for _, line := range strings.Split(output, "\n") {
		lower := strings.ToLower(line)
		if strings.Contains(lower, "marker") || strings.Contains(lower, "scan id") {
			lines = append(lines, line)
		}
	}
	return lines
}

// checkSilentUnlessDebug runs a collection against a fresh server from
// newServer twice. Without --debug, the log must not mention markers; with
// --debug, it must contain debugText. Neither run may count an error.
func checkSilentUnlessDebug(t *testing.T, label string, newServer func() *markerServer, debugText string) {
	for _, debug := range []bool{false, true} {
		server := newServer()
		c, output := runWithMarkers(t, server, debug)
		server.Close()
		if got := c.Statistics.ErrorCount(); got != 0 {
			t.Errorf("%s (debug=%v): a marker failure must not fail the run, got %d error(s)\n%s", label, debug, got, output)
		}
		lines := markerLog(output)
		if !debug && len(lines) != 0 {
			t.Errorf("%s: without --debug the log must not mention markers, got %q", label, lines)
		}
		if debug && !strings.Contains(output, "[DEBUG] ") || debug && !strings.Contains(output, debugText) {
			t.Errorf("%s: --debug log does not contain %q:\n%s", label, debugText, output)
		}
	}
}

func TestMarkersUnsupportedServerIsHandledGracefully(t *testing.T) {
	// THOR 10 and the current THOR 11 versions answer 404; 501 means the same.
	for _, status := range []int{http.StatusNotFound, http.StatusNotImplemented} {
		server := newMarkerServer(markerReply{status, "404 page not found"})
		c, _ := runWithMarkers(t, server, false)
		server.Close()
		markers, uploads := server.recorded()

		if len(markers) != 1 || markers[0]["type"] != "begin" {
			t.Errorf("HTTP %d: expected only the begin marker, got %v", status, markers)
		}
		if len(uploads) != 1 || strings.Contains(uploads[0], "scan_id") {
			t.Errorf("HTTP %d: expected one upload without scan_id, got %v", status, uploads)
		}
		if c.MarkersActive() {
			t.Errorf("HTTP %d: markers must be inactive after begin was refused", status)
		}
		checkSilentUnlessDebug(t, fmt.Sprintf("HTTP %d", status), func() *markerServer {
			return newMarkerServer(markerReply{status, "404 page not found"})
		}, "does not support collection markers")
	}
}

func TestMarkersRunWithScanID(t *testing.T) {
	scanID := "6f1c2a9e-3b7d-4e55-9a0c-1d2e3f405162"
	server := newMarkerServer(markerReply{200, `{"scan_id": "` + scanID + `", "other": 1}`}, markerReply{200, "{}"})
	defer server.Close()
	c, output := runWithMarkers(t, server, false)
	markers, uploads := server.recorded()

	if got := c.Statistics.ErrorCount(); got != 0 {
		t.Fatalf("expected no errors, got %d\n%s", got, output)
	}
	if len(uploads) != 1 || uploads[0] != "scan_id="+scanID+"&source=web+01%26x" {
		t.Errorf("upload query does not carry the scan ID: %v", uploads)
	}
	if len(markers) != 2 {
		t.Fatalf("expected begin and end, got %v", markers)
	}
	hostname, _ := os.Hostname()
	timestamp := regexp.MustCompile(`^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$`)
	for i, want := range []string{"begin", "end"} {
		m := markers[i]
		if m["type"] != want || m["source"] != "web 01&x" || m["collector"] != collectorLabel {
			t.Errorf("marker %d: unexpected fields %v", i, m)
		}
		if hostname != "" && m["hostname"] != hostname {
			t.Errorf("marker %d: hostname %v, want %q", i, m["hostname"], hostname)
		}
		if ts, _ := m["timestamp"].(string); !timestamp.MatchString(ts) {
			t.Errorf("marker %d: timestamp %q is not UTC in whole seconds", i, ts)
		}
	}
	if _, present := markers[0]["scan_id"]; present {
		t.Errorf("begin must not carry scan_id: %v", markers[0])
	}
	if _, present := markers[0]["stats"]; present {
		t.Errorf("begin must not carry stats: %v", markers[0])
	}
	end := markers[1]
	if end["scan_id"] != scanID {
		t.Errorf("end carries scan_id %v, want %s", end["scan_id"], scanID)
	}
	stats, _ := end["stats"].(map[string]interface{})
	want := map[string]float64{"scanned": 1, "submitted": 1, "skipped": 0, "failed": 0, "scan_errors": 0, "elapsed_seconds": 0}
	if len(stats) != len(want) {
		t.Errorf("end stats %v, want the keys of %v", stats, want)
	}
	for key, value := range want {
		if stats[key] != value {
			t.Errorf("end stats %s = %v, want %v", key, stats[key], value)
		}
	}
	if !strings.Contains(output, "assigned scan ID "+scanID) {
		t.Errorf("log does not name the scan ID:\n%s", output)
	}
}

func TestMarkersUnusableScanIDKeepsMarkers(t *testing.T) {
	for _, body := range []string{
		``, `[]`, `null`, `"abc"`, `{}`, `{"scan_id": null}`, `{"scan_id": 42}`, `{"scan_id": ""}`,
		`{"data": {"scan_id": "nested"}}`, `{"scan_id": "a\u0007b"}`,
		`{"scan_id": "` + strings.Repeat("x", maxScanIDLength+1) + `"}`,
		`{"scan_id": "ok", "pad": "` + strings.Repeat("x", maxMarkerAnswer) + `"}`,
	} {
		server := newMarkerServer(markerReply{200, body})
		_, _ = runWithMarkers(t, server, false)
		server.Close()
		markers, uploads := server.recorded()
		label := body
		if len(label) > 40 {
			label = label[:40] + "..."
		}

		if len(uploads) != 1 || strings.Contains(uploads[0], "scan_id") {
			t.Errorf("%s: expected one upload without scan_id, got %v", label, uploads)
		}
		if len(markers) != 2 || markers[1]["type"] != "end" {
			t.Errorf("%s: a server that accepted begin must get end, got %v", label, markers)
		} else if _, present := markers[1]["scan_id"]; present {
			t.Errorf("%s: end must not carry a scan_id, got %v", label, markers[1])
		}
		reply := markerReply{200, body}
		checkSilentUnlessDebug(t, label, func() *markerServer { return newMarkerServer(reply) }, "uploads carry no scan ID")
	}
}

func TestMarkersFailedBeginIsRetriedOnce(t *testing.T) {
	server := newMarkerServer(markerReply{503, "busy"}, markerReply{200, `{"scan_id": "abc"}`}, markerReply{200, ""})
	defer server.Close()
	c, output := runWithMarkers(t, server, false)
	markers, uploads := server.recorded()

	if len(markers) != 3 || markers[0]["type"] != "begin" || markers[1]["type"] != "begin" || markers[2]["type"] != "end" {
		t.Errorf("expected begin, begin, end; got %v", markers)
	}
	if len(uploads) != 1 || !strings.Contains(uploads[0], "scan_id=abc") {
		t.Errorf("expected the upload to carry the scan ID of the retried begin, got %v", uploads)
	}
	if got := c.Statistics.ErrorCount(); got != 0 {
		t.Errorf("a begin that succeeded on the retry is not an error, got %d\n%s", got, output)
	}
	if lines := markerLog(output); len(lines) != 1 || !strings.Contains(lines[0], "assigned scan ID abc") {
		t.Errorf("without --debug only the scan ID may be logged, got %q", lines)
	}
}

func TestMarkersFailedBeginIsIgnored(t *testing.T) {
	for _, status := range []int{400, 403, 405, 500, 503, http.StatusFound} {
		server := newMarkerServer(markerReply{status, "no"})
		_, _ = runWithMarkers(t, server, false)
		server.Close()
		markers, uploads := server.recorded()

		if len(markers) != 2 || markers[0]["type"] != "begin" || markers[1]["type"] != "begin" {
			t.Errorf("HTTP %d: expected two begin attempts and no end, got %v", status, markers)
		}
		if len(uploads) != 1 || strings.Contains(uploads[0], "scan_id") {
			t.Errorf("HTTP %d: the file must still be uploaded, without scan_id: %v", status, uploads)
		}
		debugText := fmt.Sprintf("Could not send the collection begin marker to Thunderstorm: HTTP %d", status)
		if status == http.StatusFound {
			debugText = "redirects are not followed"
		}
		reply := markerReply{status, "no"}
		checkSilentUnlessDebug(t, fmt.Sprintf("HTTP %d", status), func() *markerServer { return newMarkerServer(reply) }, debugText)
	}
}

func TestMarkersUnreachableBeginDoesNotStopTheRun(t *testing.T) {
	server := newMarkerServer(markerReply{200, ""})
	server.Close()
	var output bytes.Buffer
	c := NewCollector(CollectorConfig{Server: server.URL, Threads: 1}, log.New(&output, "", 0))
	c.retrySleep = func(time.Duration) {}
	c.BeginRun()
	if c.MarkersActive() || c.Statistics.ErrorCount() != 0 || output.Len() != 0 {
		t.Errorf("expected inactive markers, no error and no log, got active=%v errors=%d\n%s", c.MarkersActive(), c.Statistics.ErrorCount(), output.String())
	}
}

func TestMarkersFailedEndIsIgnored(t *testing.T) {
	server := newMarkerServer(markerReply{200, `{"scan_id": "abc"}`}, markerReply{500, "oops"})
	defer server.Close()
	c, output := runWithMarkers(t, server, false)
	markers, _ := server.recorded()

	if len(markers) != 2 || markers[1]["type"] != "end" {
		t.Errorf("expected begin and a single end, got %v", markers)
	}
	if got := c.Statistics.ErrorCount(); got != 0 {
		t.Errorf("a refused end must not fail the run, got %d error(s)", got)
	}
	if lines := markerLog(output); len(lines) != 1 || !strings.Contains(lines[0], "assigned scan ID abc") {
		t.Errorf("without --debug only the scan ID may be logged, got %q", lines)
	}

	debugServer := newMarkerServer(markerReply{200, `{"scan_id": "abc"}`}, markerReply{500, "oops"})
	defer debugServer.Close()
	_, debugOutput := runWithMarkers(t, debugServer, true)
	if !strings.Contains(debugOutput, "[DEBUG] Could not send the collection end marker to Thunderstorm: HTTP 500") {
		t.Errorf("--debug log does not report the failed end:\n%s", debugOutput)
	}
}

func TestMarkersEndAnswered404IsAccepted(t *testing.T) {
	server := newMarkerServer(markerReply{200, `{"scan_id": "abc"}`}, markerReply{404, ""})
	defer server.Close()
	c, _ := runWithMarkers(t, server, false)
	if got := c.Statistics.ErrorCount(); got != 0 {
		t.Errorf("404 on end means unsupported, not failed; got %d error(s)", got)
	}
}

func TestMarkersInterruptedIsSentOnce(t *testing.T) {
	server := newMarkerServer(markerReply{200, `{"scan_id": "abc"}`}, markerReply{500, ""})
	defer server.Close()
	var output bytes.Buffer
	c := NewCollector(CollectorConfig{Server: server.URL, Threads: 1, Source: "host", Debug: true}, log.New(&output, "", 0))
	c.BeginRun()
	c.InterruptRun()
	c.EndRun()
	markers, _ := server.recorded()

	if len(markers) != 2 || markers[1]["type"] != "interrupted" || markers[1]["scan_id"] != "abc" {
		t.Fatalf("expected begin and one interrupted marker, got %v", markers)
	}
	if _, present := markers[1]["stats"]; !present {
		t.Errorf("interrupted must carry stats: %v", markers[1])
	}
	if got := c.Statistics.ErrorCount(); got != 0 {
		t.Errorf("a failed interrupted marker is not counted; got %d", got)
	}
	if !strings.Contains(output.String(), "[DEBUG] Could not send the collection interrupted marker") {
		t.Errorf("--debug log does not report the failed interrupted marker:\n%s", output.String())
	}
}

func TestMarkersAreNotSentWithoutBegin(t *testing.T) {
	// A dry run never calls BeginRun, so EndRun and InterruptRun send nothing.
	server := newMarkerServer(markerReply{200, `{"scan_id": "abc"}`})
	defer server.Close()
	c := NewCollector(CollectorConfig{Server: server.URL, Threads: 1}, log.New(ioutil.Discard, "", 0))
	c.EndRun()
	c.InterruptRun()
	if markers, _ := server.recorded(); len(markers) != 0 {
		t.Errorf("expected no markers, got %v", markers)
	}
}

func TestMarkerRequestTimesOut(t *testing.T) {
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-release
	}))
	defer server.Close()
	defer close(release)
	c := NewCollector(CollectorConfig{Server: server.URL, Threads: 1}, log.New(ioutil.Discard, "", 0))
	c.markerClient.Timeout = 50 * time.Millisecond
	answer := c.sendMarker(c.newMarker("begin"))
	if answer.err == nil {
		t.Fatalf("expected a timeout, got %v", answer)
	}
}
