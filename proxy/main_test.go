package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"sync"
	"testing"
	"time"
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
