package main

import (
	"bytes"
	"encoding/json"
	"io"
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
// the query of every upload. replies holds the status and body for successive
// marker requests; the last one repeats. block, if set, holds every upload
// until it is closed.
type markerServer struct {
	*httptest.Server
	mutex   sync.Mutex
	replies []markerReply
	markers []map[string]interface{}
	uploads []string
	block   chan struct{}
	arrived chan struct{}
}

type markerReply struct {
	status int
	body   string
}

func newMarkerServer(t *testing.T, replies ...markerReply) *markerServer {
	s := &markerServer{replies: replies, arrived: make(chan struct{}, 100)}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		switch r.URL.Path {
		case "/api/collection":
			s.mutex.Lock()
			var marker map[string]interface{}
			if err := json.Unmarshal(body, &marker); err != nil || r.Header.Get("Content-Type") != "application/json" {
				marker = map[string]interface{}{"invalid": string(body)}
			}
			s.markers = append(s.markers, marker)
			reply := s.replies[len(s.replies)-1]
			if len(s.markers) <= len(s.replies) {
				reply = s.replies[len(s.markers)-1]
			}
			s.mutex.Unlock()
			w.WriteHeader(reply.status)
			w.Write([]byte(reply.body))
		case "/api/checkAsync":
			s.mutex.Lock()
			s.uploads = append(s.uploads, r.URL.RawQuery)
			s.mutex.Unlock()
			s.arrived <- struct{}{}
			if s.block != nil {
				select {
				case <-s.block:
				case <-r.Context().Done():
					return
				}
			}
			w.Write([]byte(`{"id": 1}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(s.Server.Close)
	return s
}

func (s *markerServer) recorded() ([]map[string]interface{}, []string) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	return append([]map[string]interface{}(nil), s.markers...), append([]string(nil), s.uploads...)
}

func markerTypes(markers []map[string]interface{}) []string {
	var types []string
	for _, marker := range markers {
		types = append(types, marker["type"].(string))
	}
	return types
}

// markerCollector returns a collector for a source with two small files that
// sends everything to server, with the begin marker already sent.
func markerCollector(t *testing.T, server *markerServer) (*Collector, *bytes.Buffer) {
	t.Helper()
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "a.txt"), "first", 0o644, time.Now())
	writeFile(t, filepath.Join(root, "b.txt"), "second", 0o644, time.Now())
	client, err := newHTTPClient(Config{}, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	settings := Settings{
		RootPaths:     []string{root},
		MaxFileSize:   1 << 20,
		Threads:       1,
		WalkThreads:   1,
		Source:        "src 01&x",
		UploadURL:     server.URL + "/api/checkAsync?source=src+01%26x",
		CollectionURL: server.URL + "/api/collection",
	}
	var output bytes.Buffer
	collector := NewCollector(settings, sftpClientFor(t), client, log.New(&output, "", 0), nil)
	collector.retrySleep = func(time.Duration) {}
	collector.BeginRun()
	return collector, &output
}

func TestMarkersUnsupportedServerIsHandledGracefully(t *testing.T) {
	// THOR 10 and the current THOR 11 versions answer 404; 501 means the same.
	for _, status := range []int{http.StatusNotFound, http.StatusNotImplemented} {
		server := newMarkerServer(t, markerReply{status, "404 page not found"})
		collector, output := markerCollector(t, server)
		runWithin(t, collector, 10*time.Second)
		collector.FinishRun()
		markers, uploads := server.recorded()

		if got := markerTypes(markers); len(got) != 1 || got[0] != "begin" {
			t.Errorf("HTTP %d: expected only the begin marker, got %v", status, got)
		}
		if len(uploads) != 2 || strings.Contains(strings.Join(uploads, " "), "scan_id") {
			t.Errorf("HTTP %d: expected two uploads without scan_id, got %v", status, uploads)
		}
		if got := collector.Stats.ErrorCount(); got != 0 {
			t.Errorf("HTTP %d: an unsupported marker endpoint must not fail the run, got %d error(s)", status, got)
		}
		if !strings.Contains(output.String(), "does not support collection markers") {
			t.Errorf("HTTP %d: unexpected log:\n%s", status, output)
		}
	}
}

func TestMarkersRunWithScanID(t *testing.T) {
	scanID := "6f1c2a9e-3b7d-4e55-9a0c-1d2e3f405162"
	server := newMarkerServer(t, markerReply{200, `{"scan_id": "` + scanID + `"}`}, markerReply{200, "{}"})
	collector, output := markerCollector(t, server)
	runWithin(t, collector, 10*time.Second)
	collector.FinishRun()
	markers, uploads := server.recorded()

	if got := collector.Stats.ErrorCount(); got != 0 {
		t.Fatalf("expected no errors, got %d\n%s", got, output)
	}
	for _, query := range uploads {
		if query != "source=src+01%26x&scan_id="+scanID {
			t.Errorf("upload query does not carry the scan ID: %s", query)
		}
	}
	if got := markerTypes(markers); strings.Join(got, ",") != "begin,end" {
		t.Fatalf("expected begin and end, got %v", got)
	}
	hostname, _ := os.Hostname()
	timestamp := regexp.MustCompile(`^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$`)
	for i, m := range markers {
		if m["source"] != "src 01&x" || m["collector"] != "sftp" {
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
	end := markers[1]
	if end["scan_id"] != scanID {
		t.Errorf("end carries scan_id %v, want %s", end["scan_id"], scanID)
	}
	stats, _ := end["stats"].(map[string]interface{})
	want := map[string]float64{"scanned": 2, "submitted": 2, "skipped": 0, "failed": 0, "scan_errors": 0, "elapsed_seconds": 0}
	if len(stats) != len(want) {
		t.Errorf("end stats %v, want the keys of %v", stats, want)
	}
	for key, value := range want {
		if stats[key] != value {
			t.Errorf("end stats %s = %v, want %v", key, stats[key], value)
		}
	}
}

func TestMarkersFailedBeginDoesNotStopUploads(t *testing.T) {
	for _, status := range []int{400, 403, 500, 503, http.StatusFound} {
		server := newMarkerServer(t, markerReply{status, "no"})
		collector, output := markerCollector(t, server)
		runWithin(t, collector, 10*time.Second)
		collector.FinishRun()
		markers, uploads := server.recorded()

		if got := markerTypes(markers); strings.Join(got, ",") != "begin,begin" {
			t.Errorf("HTTP %d: expected two begin attempts and no closing marker, got %v", status, got)
		}
		if len(uploads) != 2 || strings.Contains(strings.Join(uploads, " "), "scan_id") {
			t.Errorf("HTTP %d: the files must still be sent, without scan_id: %v", status, uploads)
		}
		if got := collector.Stats.ErrorCount(); got != 1 || collector.Stats.MarkerErrors != 1 {
			t.Errorf("HTTP %d: a refused begin must fail the run once, got %d error(s)", status, got)
		}
		if !strings.Contains(output.String(), "Could not send the collection begin marker") {
			t.Errorf("HTTP %d: log does not report the failed begin:\n%s", status, output)
		}
	}
}

func TestMarkersBeginRetrySucceeds(t *testing.T) {
	server := newMarkerServer(t, markerReply{503, "busy"}, markerReply{200, `{"scan_id": "abc"}`}, markerReply{200, ""})
	collector, _ := markerCollector(t, server)
	runWithin(t, collector, 10*time.Second)
	collector.FinishRun()
	markers, uploads := server.recorded()

	if got := markerTypes(markers); strings.Join(got, ",") != "begin,begin,end" {
		t.Errorf("expected begin, begin, end; got %v", got)
	}
	if len(uploads) != 2 || !strings.HasSuffix(uploads[0], "&scan_id=abc") {
		t.Errorf("expected uploads with the scan ID of the retried begin, got %v", uploads)
	}
	if got := collector.Stats.ErrorCount(); got != 0 {
		t.Errorf("a begin that succeeded on the retry is not an error, got %d", got)
	}
}

func TestMarkersFailedEndFailsTheRun(t *testing.T) {
	server := newMarkerServer(t, markerReply{200, `{"scan_id": "abc"}`}, markerReply{500, "oops"})
	collector, output := markerCollector(t, server)
	runWithin(t, collector, 10*time.Second)
	collector.FinishRun()

	if got := collector.Stats.MarkerErrors; got != 1 {
		t.Errorf("a refused end must fail the run, got %d marker error(s)", got)
	}
	if !strings.Contains(output.String(), "Could not send the collection end marker to Thunderstorm: HTTP 500") {
		t.Errorf("log does not report the failed end:\n%s", output)
	}
}

func TestMarkersInterruptedRunSendsInterrupted(t *testing.T) {
	server := newMarkerServer(t, markerReply{200, `{"scan_id": "abc"}`}, markerReply{500, ""})
	server.block = make(chan struct{})
	defer close(server.block)
	collector, output := markerCollector(t, server)
	go func() {
		<-server.arrived
		collector.Interrupt()
	}()
	runWithin(t, collector, 10*time.Second)
	collector.FinishRun()
	markers, _ := server.recorded()

	if got := markerTypes(markers); strings.Join(got, ",") != "begin,interrupted" {
		t.Fatalf("expected begin and interrupted, got %v", got)
	}
	if markers[1]["scan_id"] != "abc" || markers[1]["stats"] == nil {
		t.Errorf("interrupted must carry scan_id and stats: %v", markers[1])
	}
	if collector.Stats.MarkerErrors != 0 {
		t.Errorf("a refused interrupted marker is logged, not counted")
	}
	if !strings.Contains(output.String(), "Could not send the collection interrupted marker") {
		t.Errorf("log does not report the failed interrupted marker:\n%s", output)
	}
}

func TestMarkersAreNotSentWithoutBegin(t *testing.T) {
	// A dry run never calls BeginRun, so FinishRun sends nothing.
	server := newMarkerServer(t, markerReply{200, `{"scan_id": "abc"}`})
	collector := NewCollector(Settings{CollectionURL: server.URL + "/api/collection"}, nil, server.Client(), log.New(io.Discard, "", 0), nil)
	collector.FinishRun()
	if markers, _ := server.recorded(); len(markers) != 0 {
		t.Errorf("expected no markers, got %v", markers)
	}
}

func TestMarkerRequestTimesOut(t *testing.T) {
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-release }))
	defer server.Close()
	defer close(release)
	collector := NewCollector(Settings{CollectionURL: server.URL + "/api/collection"}, nil, server.Client(), log.New(io.Discard, "", 0), nil)
	collector.markerTimeout = 50 * time.Millisecond
	if answer := collector.sendMarker(collector.newMarker("begin")); answer.err == nil {
		t.Fatalf("expected a timeout, got %v", answer)
	}
}

func TestParseScanID(t *testing.T) {
	for body, want := range map[string]string{
		`{"scan_id": "abc", "other": 1}`:  "abc",
		``:                                "",
		`[]`:                              "",
		`null`:                            "",
		`"abc"`:                           "",
		`{}`:                              "",
		`{"scan_id": null}`:               "",
		`{"scan_id": 42}`:                 "",
		`{"scan_id": ""}`:                 "",
		`{"data": {"scan_id": "nested"}}`: "",
		`{"scan_id": "a\u0007b"}`:         "",
		`{"scan_id": "` + strings.Repeat("x", maxScanIDLength) + `"}`:   strings.Repeat("x", maxScanIDLength),
		`{"scan_id": "` + strings.Repeat("x", maxScanIDLength+1) + `"}`: "",
	} {
		got, problem := parseScanID(markerAnswer{status: 200, body: []byte(body)})
		if got != want || (want == "") != (problem != "") {
			t.Errorf("%.40s: got %q (%s), want %q", body, got, problem, want)
		}
	}
	if got, problem := parseScanID(markerAnswer{status: 200, body: []byte(`{"scan_id": "abc"}`), tooLarge: true}); got != "" || problem == "" {
		t.Errorf("an oversized answer must not give an ID, got %q", got)
	}
}
