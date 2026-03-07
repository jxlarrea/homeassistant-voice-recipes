package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// ─── Config ─────────────────────────────────────────────────────────────────

var (
	listenAddr   = envOr("PROXY_LISTEN", ":8080")
	upstreamAddr = envOr("PROXY_UPSTREAM", "http://127.0.0.1:8081")
	dashAddr     = envOr("PROXY_DASH", ":9090")
	maxEntries   = 100
)

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// ─── Ring Buffer ────────────────────────────────────────────────────────────

type RequestLog struct {
	ID              int      `json:"id"`
	Timestamp       string   `json:"timestamp"`
	LatencyMs       int64    `json:"latency_ms"`
	UserMessage     string   `json:"user_message"`
	UserContext     string   `json:"user_context"`
	SystemPrompt    string   `json:"system_prompt"`
	History         []Turn   `json:"history"`
	ToolName        string   `json:"tool_name"`
	ToolArgs        string   `json:"tool_args"`
	ToolResult      string   `json:"tool_result"`
	Content         string   `json:"content"`
	FinishReason    string   `json:"finish_reason"`
	PromptTokens    int      `json:"prompt_tokens"`
	CacheTokens     int      `json:"cache_tokens"`
	CompletTokens   int      `json:"completion_tokens"`
	PromptTPS       float64  `json:"prompt_tps"`
	PredictedTPS    float64  `json:"predicted_tps"`
	DraftAcceptRate float64  `json:"draft_accept_rate"`
	Model           string   `json:"model"`
	StatusCode      int      `json:"status_code"`
}

type Turn struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type RingBuffer struct {
	mu      sync.RWMutex
	entries []RequestLog
	nextID  int
}

func NewRingBuffer(size int) *RingBuffer {
	return &RingBuffer{entries: make([]RequestLog, 0, size)}
}

func (rb *RingBuffer) Add(entry RequestLog) {
	rb.mu.Lock()
	defer rb.mu.Unlock()
	rb.nextID++
	entry.ID = rb.nextID
	if len(rb.entries) >= maxEntries {
		rb.entries = rb.entries[1:]
	}
	rb.entries = append(rb.entries, entry)
}

func (rb *RingBuffer) GetAll() []RequestLog {
	rb.mu.RLock()
	defer rb.mu.RUnlock()
	result := make([]RequestLog, len(rb.entries))
	copy(result, rb.entries)
	// Reverse so newest first
	for i, j := 0, len(result)-1; i < j; i, j = i+1, j-1 {
		result[i], result[j] = result[j], result[i]
	}
	return result
}

var buffer = NewRingBuffer(maxEntries)

// ─── Proxy Handler ──────────────────────────────────────────────────────────

func proxyHandler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	// Read request body (limit to 1MB to prevent issues)
	reqBody, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	r.Body.Close()
	if err != nil {
		http.Error(w, "Failed to read request", http.StatusBadRequest)
		return
	}

	// Extract user message and tool result from request
	userMsg := ""
	toolResult := ""
	userContext := ""
	systemPrompt := ""
	var history []Turn

	// Debug: log request headers to find device/satellite identifiers
	log.Printf("DEBUG headers: %v", r.Header)

	// Debug: log top-level JSON keys (not messages)
	if len(reqBody) > 0 && reqBody[0] == '{' {
		var topLevel map[string]json.RawMessage
		if err := json.Unmarshal(reqBody, &topLevel); err == nil {
			keys := make([]string, 0, len(topLevel))
			for k := range topLevel {
				if k != "messages" && k != "tools" {
					v := string(topLevel[k])
					if len(v) > 100 { v = v[:100] + "..." }
					keys = append(keys, k+"="+v)
				}
			}
			log.Printf("DEBUG request fields: %v", keys)
		}
	}

	if len(reqBody) > 0 && reqBody[0] == '{' {
		userMsg, toolResult, userContext, systemPrompt, history = extractMessages(reqBody)
		if userMsg == "" && toolResult == "" {
			log.Printf("extractMessages: got empty from body (len=%d, first 200 bytes: %s)", len(reqBody), string(reqBody[:minInt(200, len(reqBody))]))
		}
	} else {
		log.Printf("proxyHandler: non-JSON request body (len=%d, path=%s)", len(reqBody), r.URL.Path)
	}

	// Forward to upstream
	upReq, err := http.NewRequest(r.Method, upstreamAddr+r.URL.Path, bytes.NewReader(reqBody))
	if err != nil {
		http.Error(w, "Failed to create upstream request", http.StatusInternalServerError)
		return
	}
	// Copy headers, but remove Accept-Encoding so upstream sends plain text
	for k, vv := range r.Header {
		if k == "Accept-Encoding" {
			continue
		}
		for _, v := range vv {
			upReq.Header.Add(k, v)
		}
	}
	upReq.Header.Set("Accept-Encoding", "identity")

	// Use a transport that doesn't auto-decompress so we control it
	transport := &http.Transport{
		DisableCompression: true,
	}
	client := &http.Client{Transport: transport}

	resp, err := client.Do(upReq)
	if err != nil {
		http.Error(w, "Upstream error: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// Check if this is an SSE streaming response
	isSSE := strings.Contains(resp.Header.Get("Content-Type"), "text/event-stream")

	if isSSE {
		// Stream SSE responses through to the client in real-time
		for k, vv := range resp.Header {
			for _, v := range vv {
				w.Header().Add(k, v)
			}
		}
		w.WriteHeader(resp.StatusCode)

		flusher, canFlush := w.(http.Flusher)
		var capture bytes.Buffer

		buf := make([]byte, 4096)
		for {
			n, readErr := resp.Body.Read(buf)
			if n > 0 {
				capture.Write(buf[:n])
				w.Write(buf[:n])
				if canFlush {
					flusher.Flush()
				}
			}
			if readErr != nil {
				break
			}
		}

		respBody := capture.Bytes()
		if bytes.HasPrefix(respBody, []byte("data:")) {
			respBody = parseSSEResponse(respBody)
		}

		latency := time.Since(start).Milliseconds()
		go func() {
			entry := RequestLog{
				Timestamp:    time.Now().Format("2006-01-02 15:04:05"),
				LatencyMs:    latency,
				UserMessage:  userMsg,
				UserContext:  userContext,
				SystemPrompt: systemPrompt,
				History:      history,
				ToolResult:   toolResult,
				StatusCode:   resp.StatusCode,
			}
			parseResponse(respBody, &entry)
			if entry.CompletTokens > 0 || entry.ToolName != "" {
				buffer.Add(entry)
			}
		}()
	} else {
		// Non-streaming: read full response, then forward
		rawBody, err := io.ReadAll(resp.Body)
		if err != nil {
			http.Error(w, "Failed to read upstream response", http.StatusBadGateway)
			return
		}

		for k, vv := range resp.Header {
			for _, v := range vv {
				w.Header().Add(k, v)
			}
		}
		w.WriteHeader(resp.StatusCode)
		w.Write(rawBody)

		// Decompress for parsing if needed
		respBody := rawBody
		if resp.Header.Get("Content-Encoding") == "gzip" {
			gz, err := gzip.NewReader(bytes.NewReader(rawBody))
			if err == nil {
				decompressed, err := io.ReadAll(gz)
				gz.Close()
				if err == nil {
					respBody = decompressed
				}
			}
		}

		// Handle SSE-like responses that weren't detected by Content-Type
		if bytes.HasPrefix(respBody, []byte("data:")) {
			respBody = parseSSEResponse(respBody)
		}

		latency := time.Since(start).Milliseconds()
		go func() {
			entry := RequestLog{
				Timestamp:    time.Now().Format("2006-01-02 15:04:05"),
				LatencyMs:    latency,
				UserMessage:  userMsg,
				UserContext:  userContext,
				SystemPrompt: systemPrompt,
				History:      history,
				ToolResult:   toolResult,
				StatusCode:   resp.StatusCode,
			}
			parseResponse(respBody, &entry)
			if entry.CompletTokens > 0 || entry.ToolName != "" {
				buffer.Add(entry)
			}
		}()
	}
}

// ─── JSON Parsing ───────────────────────────────────────────────────────────

// parseSSEResponse reconstructs a complete response from SSE stream chunks.
// SSE format: "data: {json}\n\n" repeated, ending with "data: [DONE]\n\n"
// We accumulate: content, tool_calls, usage, model from the streamed deltas.
func parseSSEResponse(body []byte) []byte {
	var (
		model           string
		content         strings.Builder
		toolName        string
		toolArgs        strings.Builder
		finishReason    string
		promptTok       int
		completTok      int
		contentChunks   int
		toolArgChunks   int
		timingsData     map[string]interface{}
	)

	lines := strings.Split(string(body), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		data := strings.TrimPrefix(line, "data: ")
		if data == "[DONE]" {
			continue
		}

		var chunk map[string]interface{}
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			continue
		}

		if m, ok := chunk["model"].(string); ok && m != "" {
			model = m
		}

		// Usage (often in the last chunk)
		if usage, ok := chunk["usage"].(map[string]interface{}); ok {
			if v, ok := usage["prompt_tokens"].(float64); ok {
				promptTok = int(v)
			}
			if v, ok := usage["completion_tokens"].(float64); ok {
				completTok = int(v)
			}
		}

		// Timings (llama.cpp includes this in the last SSE chunk)
		if t, ok := chunk["timings"].(map[string]interface{}); ok {
			timingsData = t
		}

		// Choices
		choices, ok := chunk["choices"].([]interface{})
		if !ok || len(choices) == 0 {
			continue
		}
		choice, ok := choices[0].(map[string]interface{})
		if !ok {
			continue
		}

		if fr, ok := choice["finish_reason"].(string); ok && fr != "" {
			finishReason = fr
		}

		delta, ok := choice["delta"].(map[string]interface{})
		if !ok {
			continue
		}

		if c, ok := delta["content"].(string); ok && c != "" {
			content.WriteString(c)
			contentChunks++
		}

		// Tool calls in streaming come as deltas
		if tcs, ok := delta["tool_calls"].([]interface{}); ok && len(tcs) > 0 {
			if tc, ok := tcs[0].(map[string]interface{}); ok {
				if fn, ok := tc["function"].(map[string]interface{}); ok {
					if name, ok := fn["name"].(string); ok && name != "" {
						toolName = name
					}
					if args, ok := fn["arguments"].(string); ok {
						toolArgs.WriteString(args)
						toolArgChunks++
					}
				}
			}
		}
	}

	// Estimate completion tokens from chunks if usage not provided
	if completTok == 0 {
		completTok = contentChunks + toolArgChunks
	}

	// Reconstruct a fake non-streaming response for the parser
	result := map[string]interface{}{
		"model": model,
		"choices": []interface{}{
			map[string]interface{}{
				"finish_reason": finishReason,
				"message": map[string]interface{}{
					"content": content.String(),
				},
			},
		},
		"usage": map[string]interface{}{
			"prompt_tokens":     promptTok,
			"completion_tokens": completTok,
		},
	}

	// Include timings if found
	if timingsData != nil {
		result["timings"] = timingsData
	}

	// Add tool calls if present
	if toolName != "" {
		choices := result["choices"].([]interface{})
		msg := choices[0].(map[string]interface{})["message"].(map[string]interface{})
		msg["tool_calls"] = []interface{}{
			map[string]interface{}{
				"function": map[string]interface{}{
					"name":      toolName,
					"arguments": toolArgs.String(),
				},
			},
		}
	}

	out, _ := json.Marshal(result)
	return out
}

func extractMessages(body []byte) (userMsg string, toolResult string, userContext string, systemPrompt string, history []Turn) {
	var req map[string]interface{}
	if err := json.Unmarshal(body, &req); err != nil {
		log.Printf("extractMessages: unmarshal error: %v", err)
		return "", "", "", "", nil
	}
	messages, ok := req["messages"].([]interface{})
	if !ok || len(messages) == 0 {
		log.Printf("extractMessages: no messages array found")
		return "", "", "", "", nil
	}

	// Extract system prompt (first message)
	if first, ok := messages[0].(map[string]interface{}); ok {
		if role, _ := first["role"].(string); role == "system" {
			systemPrompt = msgContent(first)
		}
	}

	// Check the last message to determine the request type
	lastMsg, _ := messages[len(messages)-1].(map[string]interface{})
	lastRole, _ := lastMsg["role"].(string)

	// Only capture tool result if the last message IS a tool result
	// (meaning this is a follow-up after tool execution, not context injection)
	if lastRole == "tool" {
		c := msgContent(lastMsg)
		if !strings.Contains(c, "Contextual information") {
			toolResult = c
			if len(toolResult) > 1000 {
				toolResult = toolResult[:1000] + "..."
			}
		}
	}

	// Find the last user message (the actual command)
	for i := len(messages) - 1; i >= 0; i-- {
		msg, ok := messages[i].(map[string]interface{})
		if !ok {
			continue
		}
		role, _ := msg["role"].(string)
		if role == "user" {
			userMsg = msgContent(msg)
			if len(userMsg) > 500 {
				userMsg = userMsg[:500] + "..."
			}

			// Check the message right before this user message for context
			if i > 0 {
				prevMsg, _ := messages[i-1].(map[string]interface{})
				prevContent := msgContent(prevMsg)
				if strings.Contains(prevContent, "Contextual information") || strings.Contains(prevContent, "current date") {
					userContext = prevContent
					if len(userContext) > 2000 {
						userContext = userContext[:2000] + "..."
					}
				}
			}
			break
		}
	}

	// Extract conversation history (everything between system prompt and current turn)
	// Skip: msg[0] (system), last user msg, context tool msg before last user
	lastUserIdx := -1
	for i := len(messages) - 1; i >= 0; i-- {
		msg, _ := messages[i].(map[string]interface{})
		role, _ := msg["role"].(string)
		if role == "user" {
			lastUserIdx = i
			break
		}
	}
	for i := 1; i < len(messages); i++ {
		msg, ok := messages[i].(map[string]interface{})
		if !ok {
			continue
		}
		role, _ := msg["role"].(string)
		content := msgContent(msg)

		// Skip the current turn (last user + context tool before it)
		if i >= lastUserIdx-1 {
			break
		}

		// Skip empty content
		if content == "" {
			continue
		}

		// Truncate long content for history
		if len(content) > 500 {
			content = content[:500] + "..."
		}

		history = append(history, Turn{Role: role, Content: content})
	}

	return userMsg, toolResult, userContext, systemPrompt, history
}

// msgContent extracts text content from a message, handling string and array formats
func msgContent(msg map[string]interface{}) string {
	switch c := msg["content"].(type) {
	case string:
		return c
	case []interface{}:
		for _, block := range c {
			if b, ok := block.(map[string]interface{}); ok {
				if t, ok := b["text"].(string); ok {
					return t
				}
			}
		}
	}
	return ""
}

func parseResponse(body []byte, entry *RequestLog) {
	var resp map[string]interface{}
	if err := json.Unmarshal(body, &resp); err != nil {
		log.Printf("parseResponse: unmarshal error: %v (body len=%d)", err, len(body))
		return
	}

	if model, ok := resp["model"].(string); ok {
		entry.Model = model
	}

	// Usage
	if usage, ok := resp["usage"].(map[string]interface{}); ok {
		if v, ok := usage["prompt_tokens"].(float64); ok {
			entry.PromptTokens = int(v)
		}
		if v, ok := usage["completion_tokens"].(float64); ok {
			entry.CompletTokens = int(v)
		}
	}

	// Timings (llama.cpp specific — more accurate than usage)
	if timings, ok := resp["timings"].(map[string]interface{}); ok {
		if v, ok := timings["prompt_n"].(float64); ok && v > 0 {
			entry.PromptTokens = int(v)
		}
		if v, ok := timings["cache_n"].(float64); ok && v > 0 {
			entry.CacheTokens = int(v)
		}
		if v, ok := timings["predicted_n"].(float64); ok && v > 0 {
			entry.CompletTokens = int(v)
		}
		if v, ok := timings["prompt_per_second"].(float64); ok {
			entry.PromptTPS = v
		}
		if v, ok := timings["predicted_per_second"].(float64); ok {
			entry.PredictedTPS = v
		}
		draftN, hasN := timings["draft_n"].(float64)
		draftAccepted, hasA := timings["draft_n_accepted"].(float64)
		if hasN && hasA && draftN > 0 {
			entry.DraftAcceptRate = draftAccepted / draftN
		}
	}

	// Choices
	choices, ok := resp["choices"].([]interface{})
	if !ok || len(choices) == 0 {
		return
	}
	choice, ok := choices[0].(map[string]interface{})
	if !ok {
		return
	}

	if fr, ok := choice["finish_reason"].(string); ok {
		entry.FinishReason = fr
	}

	message, ok := choice["message"].(map[string]interface{})
	if !ok {
		return
	}

	if content, ok := message["content"].(string); ok {
		entry.Content = content
	}

	// Tool calls
	if toolCalls, ok := message["tool_calls"].([]interface{}); ok && len(toolCalls) > 0 {
		if tc, ok := toolCalls[0].(map[string]interface{}); ok {
			if fn, ok := tc["function"].(map[string]interface{}); ok {
				if name, ok := fn["name"].(string); ok {
					entry.ToolName = name
				}
				if args, ok := fn["arguments"].(string); ok {
					entry.ToolArgs = args
				}
			}
		}
	}
}

// ─── Dashboard ──────────────────────────────────────────────────────────────

func dashAPIHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	json.NewEncoder(w).Encode(buffer.GetAll())
}

func dashHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html")
	fmt.Fprint(w, dashboardHTML)
}


const dashboardHTML = `
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>llama-proxy</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=DM+Mono:wght@400;500&family=Outfit:wght@300;400;500;600&display=swap');
  * { margin: 0; padding: 0; box-sizing: border-box; }
  :root {
    --bg: #08080c; --surface: #0f0f16; --card: #13131d; --border: #1c1c2e;
    --text: #d8d8e8; --dim: #5a5a72; --muted: #3a3a50;
    --green: #34d399; --yellow: #fbbf24; --red: #f87171; --blue: #60a5fa;
    --purple: #a78bfa;
  }
  body { font-family: 'Outfit', sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; }

  /* ── Top Bar ── */
  .topbar {
    display: flex; align-items: center; justify-content: space-between;
    padding: 16px 20px; border-bottom: 1px solid var(--border);
    background: var(--surface);
  }
  .topbar .brand {
    font-family: 'DM Mono', monospace; font-size: 13px; font-weight: 500;
    color: var(--green); letter-spacing: 0.5px;
    display: flex; align-items: center; gap: 8px;
  }
  .topbar .brand .dot { width: 6px; height: 6px; border-radius: 50%; background: var(--green); animation: pulse 2s infinite; }
  @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.3; } }
  .topbar .metrics {
    display: flex; gap: 24px; font-family: 'DM Mono', monospace; font-size: 11px; color: var(--dim);
  }
  .topbar .metrics .val { color: var(--text); font-weight: 500; }

  /* ── Sparkline ── */
  .sparkline-wrap { padding: 12px 20px; border-bottom: 1px solid var(--border); background: var(--surface); }
  .sparkline-wrap .label { font-family: 'DM Mono', monospace; font-size: 10px; color: var(--muted); text-transform: uppercase; letter-spacing: 1px; margin-bottom: 6px; }
  .sparkline { display: flex; align-items: flex-end; gap: 1px; height: 40px; }
  .spark-bar {
    flex: 1; border-radius: 1px 1px 0 0; min-width: 2px; max-width: 8px;
    transition: height 0.2s, opacity 0.15s; opacity: 0.65; cursor: pointer;
  }
  .spark-bar:hover { opacity: 1; }

  /* ── Controls ── */
  .controls {
    display: flex; align-items: center; gap: 10px;
    padding: 10px 20px; border-bottom: 1px solid var(--border);
  }
  .search {
    flex: 1; font-family: 'DM Mono', monospace; font-size: 12px;
    padding: 7px 12px; background: var(--card); border: 1px solid var(--border);
    border-radius: 6px; color: var(--text); outline: none; max-width: 320px;
  }
  .search:focus { border-color: var(--green); }
  .pill {
    font-family: 'DM Mono', monospace; font-size: 10px; padding: 5px 12px;
    border: 1px solid var(--border); border-radius: 20px; background: transparent;
    color: var(--dim); cursor: pointer; transition: all 0.15s;
  }
  .pill:hover { border-color: var(--text); color: var(--text); }
  .pill.on { background: var(--green); color: var(--bg); border-color: var(--green); }

  /* ── Feed ── */
  .feed { padding: 12px 20px; display: flex; flex-direction: column; gap: 6px; }

  .entry {
    background: var(--card); border: 1px solid var(--border); border-radius: 8px;
    overflow: hidden; transition: border-color 0.15s;
  }
  .entry:hover { border-color: #2a2a42; }
  .entry.has-tool { border-left: 2px solid var(--blue); }
  .entry.has-content { border-left: 2px solid var(--purple); }

  .entry-head {
    display: grid; grid-template-columns: 70px 64px 1fr auto; align-items: center;
    gap: 12px; padding: 10px 14px; cursor: pointer; user-select: none;
  }
  .entry-time { font-family: 'DM Mono', monospace; font-size: 11px; color: var(--dim); }
  .entry-latency { font-family: 'DM Mono', monospace; font-size: 12px; font-weight: 500; }
  .entry-latency.fast { color: var(--green); }
  .entry-latency.med { color: var(--yellow); }
  .entry-latency.slow { color: var(--red); }

  .entry-summary {
    font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  .entry-summary .user-msg { color: var(--text); }
  .entry-summary .arrow { color: var(--muted); margin: 0 6px; }
  .entry-summary .tool-badge {
    font-family: 'DM Mono', monospace; font-size: 11px;
    background: rgba(96,165,250,0.12); color: var(--blue);
    padding: 2px 7px; border-radius: 4px;
  }
  .entry-summary .content-preview { color: var(--dim); font-style: italic; }

  .entry-tags { display: flex; gap: 6px; flex-shrink: 0; }
  .tag {
    font-family: 'DM Mono', monospace; font-size: 9px; padding: 2px 6px;
    border-radius: 3px; white-space: nowrap;
  }
  .tag.tokens { background: rgba(216,216,232,0.06); color: var(--dim); }
  .tag.speed { background: rgba(52,211,153,0.1); color: var(--green); }
  .tag.cache { background: rgba(251,191,36,0.1); color: var(--yellow); }
  .tag.draft { background: rgba(167,139,250,0.1); color: var(--purple); }

  /* ── Expanded Detail ── */
  .entry-detail {
    display: none; padding: 0 14px 12px 14px;
    border-top: 1px solid var(--border); margin-top: 0;
  }
  .entry.open .entry-detail { display: block; }
  .detail-grid {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 10px; margin-top: 10px;
  }
  .detail-item .dl { font-family: 'DM Mono', monospace; font-size: 10px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 2px; }
  .detail-item .dv { font-family: 'DM Mono', monospace; font-size: 12px; color: var(--text); word-break: break-all; }
  .detail-item .dv.dim { color: var(--dim); }

  .empty-state {
    text-align: center; padding: 80px 20px; color: var(--muted);
    font-family: 'DM Mono', monospace; font-size: 13px;
  }
</style>
</head>
<body>

<div class="topbar">
  <div class="brand"><div class="dot"></div> llama-proxy</div>
  <div class="metrics" id="metrics">
    <span>requests <span class="val" id="m-count">0</span></span>
    <span>avg <span class="val" id="m-avg">-</span></span>
    <span>p95 <span class="val" id="m-p95">-</span></span>
    <span>tools <span class="val" id="m-tools">0</span></span>
    <span>draft <span class="val" id="m-draft">-</span></span>
    <span>cache <span class="val" id="m-cache">-</span></span>
  </div>
</div>

<div class="sparkline-wrap">
  <div class="label">latency</div>
  <div class="sparkline" id="sparkline"></div>
</div>

<div class="controls">
  <input class="search" id="search" placeholder="Filter..." />
  <button class="pill on" id="btnAuto">auto</button>
  <button class="pill" onclick="fetchData()">refresh</button>
</div>

<div class="feed" id="feed"></div>
<div class="empty-state" id="empty">Waiting for requests...</div>

<script>
let autoRefresh = true, allData = [], openEntries = new Set(), openPrompts = new Set(), openHistory = new Set();

document.getElementById('btnAuto').addEventListener('click', function() {
  autoRefresh = !autoRefresh;
  this.classList.toggle('on', autoRefresh);
});
document.getElementById('search').addEventListener('input', render);

function lc(ms) { return ms <= 1200 ? 'fast' : ms < 2000 ? 'med' : 'slow'; }
function lcColor(ms) { return ms <= 1200 ? 'var(--green)' : ms < 2000 ? 'var(--yellow)' : 'var(--red)'; }
function esc(s) { return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

function toggle(id) {
  if (openEntries.has(id)) { openEntries.delete(id); } else { openEntries.add(id); }
  document.getElementById('e-'+id)?.classList.toggle('open');
}

// Pause auto-refresh while interacting with system prompt
let pauseUntil = 0;
document.addEventListener('scroll', (e) => { if (e.target.closest && e.target.closest('.sp-content')) pauseUntil = Date.now() + 10000; }, true);
document.addEventListener('wheel', (e) => { if (e.target.closest('.sp-content')) pauseUntil = Date.now() + 10000; }, {passive: true});

function render() {
  const q = document.getElementById('search').value.toLowerCase();
  const filtered = allData.filter(d => {
    if (!q) return true;
    return [d.user_message, d.tool_name, d.tool_args, d.tool_result, d.content].some(f => (f||'').toLowerCase().includes(q));
  });

  const feed = document.getElementById('feed');
  const empty = document.getElementById('empty');

  if (!filtered.length) { feed.innerHTML = ''; empty.style.display = 'block'; return; }
  empty.style.display = 'none';

  // Save open state of <details> elements before rebuilding DOM
  document.querySelectorAll('details[id^="sp-"]').forEach(el => {
    const id = parseInt(el.id.replace('sp-',''));
    if (el.open) openPrompts.add(id); else openPrompts.delete(id);
  });
  document.querySelectorAll('details[id^="hist-"]').forEach(el => {
    const id = parseInt(el.id.replace('hist-',''));
    if (el.open) openHistory.add(id); else openHistory.delete(id);
  });

  feed.innerHTML = filtered.map(d => {
    const hasTool = !!d.tool_name;
    const cls = hasTool ? 'has-tool' : d.content ? 'has-content' : '';

    let summary = '';
    if (d.user_message) summary += '<span class="user-msg">' + esc(d.user_message) + '</span>';
    if (hasTool) {
      summary += '<span class="arrow">→</span><span class="tool-badge">' + esc(d.tool_name) + '</span>';
    } else if (d.content) {
      summary += '<span class="arrow">→</span><span class="content-preview">' + esc(d.content).substring(0, 80) + '</span>';
    }

    let tags = '';
    if (d.prompt_tokens > 0 || d.cache_tokens > 0) tags += '<span class="tag tokens">' + (d.cache_tokens + d.prompt_tokens) + '→' + d.completion_tokens + ' tok</span>';
    if (d.cache_tokens > 0) tags += '<span class="tag cache">' + ((d.cache_tokens / (d.cache_tokens + d.prompt_tokens)) * 100).toFixed(0) + '% cached</span>';
    if (d.predicted_tps > 0) tags += '<span class="tag speed">' + d.predicted_tps.toFixed(1) + ' t/s</span>';
    if (d.draft_accept_rate > 0) tags += '<span class="tag draft">' + (d.draft_accept_rate*100).toFixed(0) + '% draft</span>';

    let detail = '<div class="detail-grid">';
    detail += di('User Message', d.user_message || '-');
    if (d.user_context) detail += di('Context', d.user_context);
    if (hasTool) {
      detail += di('Tool', d.tool_name);
      detail += di('Arguments', d.tool_args || '-');
    }
    if (d.tool_result) detail += di('Tool Result', d.tool_result);
    if (d.content) detail += di('Content', d.content);
    detail += di('Finish', d.finish_reason || '-');
    detail += di('Prompt Tokens', (d.cache_tokens + d.prompt_tokens) + ' total');
    if (d.cache_tokens > 0) {
      const total = d.cache_tokens + d.prompt_tokens;
      const pct = total > 0 ? ((d.cache_tokens/total)*100).toFixed(0) : 0;
      detail += di('Cached', d.cache_tokens + ' / ' + total + ' (' + pct + '% hit, ' + d.prompt_tokens + ' new)');
    }
    detail += di('Completion Tokens', d.completion_tokens || 0);
    if (d.prompt_tps > 0) detail += di('Prompt Speed', d.prompt_tps.toFixed(1) + ' tok/s');
    if (d.predicted_tps > 0) detail += di('Generate Speed', d.predicted_tps.toFixed(1) + ' tok/s');
    if (d.draft_accept_rate > 0) detail += di('Draft Accept', (d.draft_accept_rate*100).toFixed(1) + '%');
    detail += di('Model', d.model || '-');
    detail += di('Status', d.status_code);
    detail += '</div>';
    if (d.history && d.history.length > 0) {
      const hOpen = openHistory.has(d.id) ? ' open' : '';
      let hHtml = '<div style="margin-top:6px;display:flex;flex-direction:column;gap:4px">';
      d.history.forEach(t => {
        const isUser = t.role === 'user';
        const isAsst = t.role === 'assistant';
        const isTool = t.role === 'tool';
        const color = isUser ? 'var(--text)' : isAsst ? 'var(--green)' : isTool ? 'var(--blue)' : 'var(--dim)';
        const label = t.role.toUpperCase();
        hHtml += '<div style="padding:6px 10px;background:var(--bg);border:1px solid var(--border);border-radius:6px">'
          + '<span style="font-family:DM Mono,monospace;font-size:9px;color:' + color + ';text-transform:uppercase;letter-spacing:0.5px;margin-right:8px">' + label + '</span>'
          + '<span style="font-family:DM Mono,monospace;font-size:11px;color:var(--dim)">' + esc(t.content) + '</span>'
          + '</div>';
      });
      hHtml += '</div>';
      detail += '<details id="hist-' + d.id + '"' + hOpen + ' style="margin-top:10px"><summary style="font-family:DM Mono,monospace;font-size:10px;color:var(--muted);cursor:pointer;text-transform:uppercase;letter-spacing:0.5px">Conversation History (' + d.history.length + ' messages)</summary>' + hHtml + '</details>';
    }
    if (d.system_prompt) {
      const spOpen = openPrompts.has(d.id) ? ' open' : '';
      detail += '<details id="sp-' + d.id + '"' + spOpen + ' style="margin-top:10px"><summary style="font-family:DM Mono,monospace;font-size:10px;color:var(--muted);cursor:pointer;text-transform:uppercase;letter-spacing:0.5px">System Prompt</summary>'
        + '<pre class="sp-content" style="margin-top:6px;padding:10px;background:var(--bg);border:1px solid var(--border);border-radius:6px;font-family:DM Mono,monospace;font-size:11px;color:var(--dim);white-space:pre-wrap;word-break:break-word;max-height:60vh;overflow-y:auto">'
        + esc(d.system_prompt) + '</pre></details>';
    }

    const isOpen = openEntries.has(d.id) ? ' open' : '';

    return '<div class="entry ' + cls + isOpen + '" id="e-' + d.id + '">'
      + '<div class="entry-head" onclick="toggle(' + d.id + ')">'
      + '<div class="entry-time">' + (d.timestamp||'').split(' ')[1] + '</div>'
      + '<div class="entry-latency ' + lc(d.latency_ms) + '">' + d.latency_ms + 'ms</div>'
      + '<div class="entry-summary">' + summary + '</div>'
      + '<div class="entry-tags">' + tags + '</div>'
      + '</div>'
      + '<div class="entry-detail">' + detail + '</div>'
      + '</div>';
  }).join('');

  // Metrics
  const avg = Math.round(filtered.reduce((s,d) => s+d.latency_ms, 0) / filtered.length);
  const sorted = [...filtered].sort((a,b) => a.latency_ms - b.latency_ms);
  const p95 = sorted[Math.floor(sorted.length * 0.95)]?.latency_ms || 0;
  const tools = filtered.filter(d => d.tool_name).length;
  const drafts = filtered.filter(d => d.draft_accept_rate > 0);
  const avgDraft = drafts.length ? (drafts.reduce((s,d) => s+d.draft_accept_rate, 0) / drafts.length * 100).toFixed(0) + '%' : '-';

  document.getElementById('m-count').textContent = filtered.length;
  document.getElementById('m-avg').textContent = avg + 'ms';
  document.getElementById('m-p95').textContent = p95 + 'ms';
  document.getElementById('m-tools').textContent = tools;
  document.getElementById('m-draft').textContent = avgDraft;

  const cached = filtered.filter(d => d.cache_tokens > 0);
  const avgCache = cached.length ? (cached.reduce((s,d) => s + d.cache_tokens/(d.cache_tokens + d.prompt_tokens), 0) / cached.length * 100).toFixed(0) + '%' : '-';
  document.getElementById('m-cache').textContent = avgCache;

  // Sparkline
  const sparkData = allData.slice(0, 60).reverse();
  const maxMs = Math.max(...sparkData.map(d => d.latency_ms), 1);
  document.getElementById('sparkline').innerHTML = sparkData.map(d => {
    const h = Math.max(2, (d.latency_ms / maxMs) * 36);
    return '<div class="spark-bar" style="height:'+h+'px;background:'+lcColor(d.latency_ms)+'" title="'+d.latency_ms+'ms"></div>';
  }).join('');
}

function di(label, value) {
  const cls = (value === '-' || value === 0) ? ' dim' : '';
  return '<div class="detail-item"><div class="dl">' + label + '</div><div class="dv' + cls + '">' + esc(String(value)) + '</div></div>';
}

async function fetchData() {
  try {
    const r = await fetch('/api/logs');
    allData = await r.json();
    if (!allData) allData = [];
    render();
  } catch(e) { console.error(e); }
}

fetchData();
setInterval(() => { if (autoRefresh && Date.now() > pauseUntil) fetchData(); }, 2000);
</script>
</body>
</html>
`

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// ─── Main ───────────────────────────────────────────────────────────────────

func main() {
	log.Printf("llama-proxy starting")
	log.Printf("  proxy:     %s → %s", listenAddr, upstreamAddr)
	log.Printf("  dashboard: %s", dashAddr)
	log.Printf("  buffer:    last %d requests", maxEntries)

	// Dashboard server
	dashMux := http.NewServeMux()
	dashMux.HandleFunc("/api/logs", dashAPIHandler)
	dashMux.HandleFunc("/", dashHandler)
	go func() {
		log.Printf("Dashboard listening on %s", dashAddr)
		if err := http.ListenAndServe(dashAddr, dashMux); err != nil {
			log.Fatal(err)
		}
	}()

	// Proxy server
	proxyMux := http.NewServeMux()
	proxyMux.HandleFunc("/", proxyHandler)
	log.Printf("Proxy listening on %s", listenAddr)
	if err := http.ListenAndServe(listenAddr, proxyMux); err != nil {
		log.Fatal(err)
	}
}
