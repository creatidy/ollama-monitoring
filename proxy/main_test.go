package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	prometheus "github.com/prometheus/client_golang/prometheus"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
	dto "github.com/prometheus/client_model/go"
)

func TestParseOpenAIChatCompletionsUsageNonStreaming(t *testing.T) {
	model, prompt, completion := parseOpenAIChatCompletionsUsage([]byte(`{
  "id": "chatcmpl-test",
  "model": "qwen3.8:27b-3090-q4km-160k",
  "choices": [{"message": {"content": "ok"}}],
  "usage": {"prompt_tokens": 21, "completion_tokens": 8, "total_tokens": 29}
}`))
	if model != "qwen3.8:27b-3090-q4km-160k" || prompt != 21 || completion != 8 {
		t.Fatalf("got model=%q prompt=%d completion=%d", model, prompt, completion)
	}
}

func TestParseOpenAIChatCompletionsUsageStreaming(t *testing.T) {
	data := []byte("data: {\"id\":\"chatcmpl-test\",\"model\":\"qwen3.8:27b-3090-q4km-160k\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n" +
		"data: {\"id\":\"chatcmpl-test\",\"model\":\"qwen3.8:27b-3090-q4km-160k\",\"choices\":[],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":7,\"total_tokens\":27}}\n\n" +
		"data: [DONE]\n\n")
	model, prompt, completion := parseOpenAIChatCompletionsUsage(data)
	if model != "qwen3.8:27b-3090-q4km-160k" || prompt != 20 || completion != 7 {
		t.Fatalf("got model=%q prompt=%d completion=%d", model, prompt, completion)
	}
}

func TestPrepareOpenAIChatRequestInjectsUsageWithoutChangingFields(t *testing.T) {
	input := []byte(`{"model":"qwen3.8:27b-3090-q4km-160k","stream":true,"messages":[{"role":"user","content":"hello"}],"temperature":0.25}`)
	got, stripUsage := prepareOpenAIChatRequest(input)
	if !stripUsage {
		t.Fatal("expected injected usage event to be stripped from client response")
	}

	var request map[string]json.RawMessage
	if err := json.Unmarshal(got, &request); err != nil {
		t.Fatal(err)
	}
	var options map[string]json.RawMessage
	if err := json.Unmarshal(request["stream_options"], &options); err != nil {
		t.Fatal(err)
	}
	var includeUsage bool
	if err := json.Unmarshal(options["include_usage"], &includeUsage); err != nil || !includeUsage {
		t.Fatalf("include_usage = %s, want true", options["include_usage"])
	}
	if string(request["model"]) != `"qwen3.8:27b-3090-q4km-160k"` || string(request["messages"]) != `[{"role":"user","content":"hello"}]` || string(request["temperature"]) != "0.25" {
		t.Fatalf("request fields changed: %s", got)
	}
}

func TestPrepareOpenAIChatRequestPreservesRequestedUsage(t *testing.T) {
	input := []byte(`{"model":"m","stream":true,"stream_options":{"include_usage":true,"custom":7}}`)
	got, stripUsage := prepareOpenAIChatRequest(input)
	if stripUsage || string(got) != string(input) {
		t.Fatalf("got body=%s stripUsage=%v, want original body and no stripping", got, stripUsage)
	}
}

func TestPrepareOpenAIChatRequestLeavesNonStreamingAlone(t *testing.T) {
	input := []byte(`{"model":"m","stream":false,"messages":[]}`)
	got, stripUsage := prepareOpenAIChatRequest(input)
	if stripUsage || string(got) != string(input) {
		t.Fatalf("got body=%s stripUsage=%v, want original body and no stripping", got, stripUsage)
	}
}

type captureWriter struct {
	header     http.Header
	mu         sync.Mutex
	body       bytes.Buffer
	firstWrite chan []byte
}

func (w *captureWriter) Header() http.Header {
	return w.header
}

func (w *captureWriter) WriteHeader(int) {}

func (w *captureWriter) Write(data []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.firstWrite != nil {
		w.firstWrite <- append([]byte(nil), data...)
		w.firstWrite = nil
	}
	return w.body.Write(data)
}

func (w *captureWriter) Flush() {}

func (w *captureWriter) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.body.String()
}

type gatedReader struct {
	first     []byte
	rest      []byte
	released  chan struct{}
	sentFirst bool
}

func (r *gatedReader) Read(data []byte) (int, error) {
	if !r.sentFirst {
		r.sentFirst = true
		n := copy(data, r.first)
		return n, nil
	}
	<-r.released
	n := copy(data, r.rest)
	r.rest = r.rest[n:]
	if len(r.rest) == 0 {
		return n, io.EOF
	}
	return n, nil
}

func TestStreamOpenAIChatResponseFlushesBeforeCompletionAndStripsInjectedUsage(t *testing.T) {
	first := []byte("data: {\"model\":\"m\",\"choices\":[{\"delta\":{\"content\":\"first\"}}]}\n\n")
	rest := []byte("data: {\"model\":\"m\",\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2}}\n\n" +
		"data: [DONE]\n\n")
	released := make(chan struct{})
	firstWrite := make(chan []byte, 1)
	writer := &captureWriter{header: make(http.Header), firstWrite: firstWrite}
	reader := &gatedReader{first: first, rest: rest, released: released}
	result := make(chan struct {
		model             string
		prompt, generated int
	}, 1)
	go func() {
		model, prompt, generated := streamOpenAIChatResponse(writer, reader, true)
		result <- struct {
			model             string
			prompt, generated int
		}{model, prompt, generated}
	}()

	select {
	case got := <-firstWrite:
		if string(got) != string(first) {
			t.Fatalf("first client-visible event = %q, want %q", got, first)
		}
	case <-time.After(time.Second):
		t.Fatal("first SSE event was not forwarded before the stream completed")
	}
	close(released)

	select {
	case got := <-result:
		if got.model != "m:latest" || got.prompt != 4 || got.generated != 2 {
			t.Fatalf("got model=%q prompt=%d generated=%d", got.model, got.prompt, got.generated)
		}
		if body := writer.String(); body != string(first)+"data: [DONE]\n\n" {
			t.Fatalf("client-visible stream = %q, want usage event removed", body)
		}
	case <-time.After(time.Second):
		t.Fatal("stream did not complete")
	}
}

// inflightSum returns the sum of all ollama_inflight_requests gauge children
// (0 when no labeled series exists yet).
func inflightSum() float64 {
	var total float64
	ch := make(chan prometheus.Metric, 8)
	go func() {
		inflightRequests.Collect(ch)
		close(ch)
	}()
	for m := range ch {
		var decoded dto.Metric
		if err := m.Write(&decoded); err == nil {
			total += decoded.GetGauge().GetValue()
		}
	}
	return total
}

// waitForInflight polls the summed ollama_inflight_requests gauge until it
// equals want (or the deadline passes) and returns the last observed value.
func waitForInflight(t *testing.T, want float64, timeout time.Duration) float64 {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var got float64
	for {
		got = inflightSum()
		if got == want {
			return got
		}
		if time.Now().After(deadline) {
			return got
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// streamChat sends a streaming /v1/chat/completions request through the proxy
// in a goroutine that drains the whole response. The first forwarded SSE event
// is delivered on the returned channel.
func streamChat(t *testing.T, proxyURL, model string) <-chan string {
	t.Helper()
	firstEvent := make(chan string, 1)
	go func() {
		resp, err := http.Post(proxyURL+"/v1/chat/completions", "application/json",
			strings.NewReader(fmt.Sprintf(`{"model":%q,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, model)))
		if err != nil {
			close(firstEvent)
			return
		}
		defer resp.Body.Close()
		reader := bufio.NewReader(resp.Body)
		var event []byte
		sent := false
		for {
			line, err := reader.ReadBytes('\n')
			if len(line) > 0 {
				event = append(event, line...)
				if len(bytes.TrimSpace(line)) == 0 {
					if !sent {
						firstEvent <- string(event)
						sent = true
					}
					event = event[:0]
				}
			}
			if err != nil {
				break
			}
		}
		if !sent {
			close(firstEvent)
		}
	}()
	return firstEvent
}

func TestInflightGaugeLifecycleStreaming(t *testing.T) {
	released := make(chan struct{})
	var once sync.Once
	release := func() { once.Do(func() { close(released) }) }
	defer release()

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		flusher := w.(http.Flusher)
		fmt.Fprint(w, "data: {\"model\":\"inflight-m\",\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n")
		flusher.Flush()
		<-released
		fmt.Fprint(w, "data: {\"model\":\"inflight-m\",\"choices\":[],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3}}\n\n")
		fmt.Fprint(w, "data: [DONE]\n\n")
		flusher.Flush()
	}))
	defer upstream.Close()

	proxy := httptest.NewServer(newMux(upstream.URL))
	defer proxy.Close()

	if got := inflightSum(); got != 0 {
		t.Fatalf("inflight = %v before request, want 0", got)
	}

	firstEvent := streamChat(t, proxy.URL, "inflight-m")
	select {
	case event, ok := <-firstEvent:
		if !ok {
			t.Fatal("stream closed before the first SSE event")
		}
		if !strings.Contains(event, `"content":"hi"`) {
			t.Fatalf("first SSE event = %q, want forwarded content delta", event)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("first SSE event was not forwarded")
	}

	if got := waitForInflight(t, 1, 2*time.Second); got != 1 {
		t.Fatalf("inflight during active stream = %v, want 1", got)
	}

	release()
	if got := waitForInflight(t, 0, 5*time.Second); got != 0 {
		t.Fatalf("inflight after stream completed = %v, want 0", got)
	}
	if got := testutil.ToFloat64(generatedTokens.WithLabelValues("inflight-m:latest")); got != 3 {
		t.Fatalf("generated tokens for inflight-m:latest = %v, want 3 (recorded at completion)", got)
	}
	if got := testutil.ToFloat64(promptTokens.WithLabelValues("inflight-m:latest")); got != 7 {
		t.Fatalf("prompt tokens for inflight-m:latest = %v, want 7 (recorded at completion)", got)
	}
}

func TestInflightGaugeUpstreamError(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer upstream.Close()

	proxy := httptest.NewServer(newMux(upstream.URL))
	defer proxy.Close()

	resp, err := http.Post(proxy.URL+"/v1/chat/completions", "application/json",
		strings.NewReader(`{"model":"inflight-err","stream":true,"messages":[]}`))
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)

	if resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("proxy status = %d, want forwarded 500", resp.StatusCode)
	}
	if got := waitForInflight(t, 0, 5*time.Second); got != 0 {
		t.Fatalf("inflight after upstream error = %v, want 0", got)
	}
}

func TestInflightGaugeClientDisconnect(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		flusher := w.(http.Flusher)
		for i := 0; ; i++ {
			fmt.Fprintf(w, "data: {\"model\":\"inflight-disc\",\"choices\":[{\"delta\":{\"content\":\"tick %d\"}}]}\n\n", i)
			flusher.Flush()
			select {
			case <-r.Context().Done():
				return
			case <-time.After(20 * time.Millisecond):
			}
		}
	}))
	defer upstream.Close()

	proxy := httptest.NewServer(newMux(upstream.URL))
	defer proxy.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, proxy.URL+"/v1/chat/completions",
		strings.NewReader(`{"model":"inflight-disc","stream":true,"messages":[]}`))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	buf := make([]byte, 128)
	if _, err := resp.Body.Read(buf); err != nil {
		t.Fatalf("did not receive first event before disconnect: %v", err)
	}
	if got := waitForInflight(t, 1, 2*time.Second); got != 1 {
		t.Fatalf("inflight during active stream = %v, want 1", got)
	}

	cancel()
	_, _ = io.Copy(io.Discard, resp.Body)
	resp.Body.Close()

	if got := waitForInflight(t, 0, 5*time.Second); got != 0 {
		t.Fatalf("inflight after client disconnect = %v, want 0 (gauge must not get stuck)", got)
	}
}

func TestInflightGaugeNativeGenerateAndUnmeteredPaths(t *testing.T) {
	released := make(chan struct{})
	var once sync.Once
	release := func() { once.Do(func() { close(released) }) }
	defer release()

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/generate":
			w.Header().Set("Content-Type", "application/x-ndjson")
			fmt.Fprint(w, "{\"model\":\"inflight-native\",\"response\":\"par\",\"done\":false}\n")
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
			<-released
			fmt.Fprint(w, "{\"model\":\"inflight-native\",\"response\":\"tial\",\"done\":true,\"prompt_eval_count\":5,\"eval_count\":2,\"eval_duration\":100000000}\n")
		default:
			fmt.Fprint(w, "{\"models\":[]}")
		}
	}))
	defer upstream.Close()

	proxy := httptest.NewServer(newMux(upstream.URL))
	defer proxy.Close()

	resp, err := http.Post(proxy.URL+"/api/generate", "application/json",
		strings.NewReader(`{"model":"inflight-native","prompt":"hi","stream":true}`))
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	reader := bufio.NewReader(resp.Body)
	if _, err := reader.ReadString('\n'); err != nil {
		t.Fatalf("did not receive first native chunk: %v", err)
	}
	if got := waitForInflight(t, 1, 2*time.Second); got != 1 {
		t.Fatalf("inflight during /api/generate = %v, want 1", got)
	}
	release()
	_, _ = io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if got := waitForInflight(t, 0, 5*time.Second); got != 0 {
		t.Fatalf("inflight after /api/generate = %v, want 0", got)
	}
	if got := testutil.ToFloat64(generatedTokens.WithLabelValues("inflight-native:latest")); got != 2 {
		t.Fatalf("generated tokens for inflight-native:latest = %v, want 2", got)
	}

	seriesBefore := testutil.CollectAndCount(inflightRequests, "ollama_inflight_requests")

	// Unmetered pass-through endpoints must not create inflight series.
	tagsResp, err := http.Post(proxy.URL+"/api/tags", "application/json", strings.NewReader("{}"))
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer tagsResp.Body.Close()
	_, _ = io.Copy(io.Discard, tagsResp.Body)
	if got := waitForInflight(t, 0, time.Second); got != 0 {
		t.Fatalf("inflight after unmetered request = %v, want 0", got)
	}
	if seriesAfter := testutil.CollectAndCount(inflightRequests, "ollama_inflight_requests"); seriesAfter != seriesBefore {
		t.Fatalf("inflight series count = %d after unmetered request, want unchanged %d", seriesAfter, seriesBefore)
	}
}
