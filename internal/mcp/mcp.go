// Package mcp serves the Model Context Protocol over stdio: a fixed set of read-only tools over
// the pgvigil repository for an AI client on the same machine.
//
// Every tool is answered by the JSON API's own handler, called in process (no listener, no
// socket): the SQL, the parameter checks and the statement text are the API's, so what the
// repository holds under each instance's query_text policy is all a tool can return. The
// repository connection is the web package's read-only session (default_transaction_read_only,
// statement and lock timeouts); the login is checked to be a reader before the first message is
// read (CheckReader). Nothing is written, nothing leaves the machine beyond the repository
// connection itself, and every text sent to the client has the login's password scrubbed.
//
// The transport is newline-delimited JSON-RPC 2.0 on stdin and stdout; logs go to stderr.
package mcp

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
)

// ProtocolVersions are the MCP revisions this server speaks, newest first.
var ProtocolVersions = []string{"2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"}

// JSON-RPC error codes.
const (
	codeParse          = -32700
	codeInvalidRequest = -32600
	codeMethodNotFound = -32601
	codeInvalidParams  = -32602
	codeInternal       = -32603
)

// MaxLine is the longest request line accepted (a tools/call is a few hundred bytes).
const MaxLine = 1 << 20

// Server answers MCP requests from an API handler.
type Server struct {
	api     http.Handler
	version string
	secrets []string
	// MaxRows caps every table a tool returns; the cut is named in the result.
	MaxRows int
	// MaxText caps every string value (a plan's text, a statement); the cut is named in the value.
	MaxText int

	mu sync.Mutex // one write to out at a time
}

// New returns a server over api (the web package's Handler, run without the UI login: the
// process is the client's own child on its own machine). secrets are scrubbed from every reply.
func New(api http.Handler, version string, secrets ...string) *Server {
	var keep []string
	for _, s := range secrets {
		if len(s) >= 4 { // a shorter value would scrub ordinary words
			keep = append(keep, s)
		}
	}
	return &Server{api: api, version: version, secrets: keep, MaxRows: 200, MaxText: 20000}
}

type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

// Serve reads requests from in until it ends (the client closed the pipe) or ctx is done, and
// writes each reply to out as one line. Requests are answered in order, one at a time.
func (s *Server) Serve(ctx context.Context, in io.Reader, out io.Writer) error {
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 64*1024), MaxLine)
	lines := make(chan []byte)
	errc := make(chan error, 1)
	go func() {
		for sc.Scan() {
			b := append([]byte(nil), sc.Bytes()...)
			select {
			case lines <- b:
			case <-ctx.Done():
				return
			}
		}
		errc <- sc.Err()
		close(lines)
	}()
	for {
		select {
		case <-ctx.Done():
			return nil
		case line, ok := <-lines:
			if !ok {
				err := <-errc
				if errors.Is(err, bufio.ErrTooLong) {
					_ = s.write(out, response{JSONRPC: "2.0", ID: json.RawMessage("null"), Error: &rpcError{codeInvalidRequest, fmt.Sprintf("request line over %d bytes", MaxLine)}})
				}
				return err
			}
			if resp, ok := s.Handle(ctx, line); ok {
				if err := s.write(out, resp); err != nil {
					return err
				}
			}
		}
	}
}

func (s *Server) write(out io.Writer, resp response) error {
	b, err := json.Marshal(resp)
	if err != nil {
		b, _ = json.Marshal(response{JSONRPC: "2.0", ID: resp.ID, Error: &rpcError{codeInternal, "reply could not be encoded"}})
	}
	b = append([]byte(s.scrub(string(b))), '\n')
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err = out.Write(b)
	return err
}

// Handle answers one request line; ok is false for a notification (no reply is sent).
func (s *Server) Handle(ctx context.Context, line []byte) (resp response, ok bool) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return response{}, false
	}
	fail := func(id json.RawMessage, code int, msg string) (response, bool) {
		if id == nil {
			id = json.RawMessage("null")
		}
		return response{JSONRPC: "2.0", ID: id, Error: &rpcError{code, msg}}, true
	}
	if line[0] == '[' {
		return fail(nil, codeInvalidRequest, "batches are not supported")
	}
	var req request
	if err := json.Unmarshal(line, &req); err != nil {
		return fail(nil, codeParse, "parse error: "+err.Error())
	}
	if req.JSONRPC != "2.0" || req.Method == "" {
		return fail(req.ID, codeInvalidRequest, "not a JSON-RPC 2.0 request")
	}
	if req.ID == nil || string(req.ID) == "null" { // a notification: initialized, cancelled; nothing to say back
		return response{}, false
	}
	var result any
	var err *rpcError
	switch req.Method {
	case "initialize":
		result, err = s.initialize(req.Params)
	case "ping":
		result = struct{}{}
	case "tools/list":
		result = map[string]any{"tools": toolList()}
	case "tools/call":
		result, err = s.call(ctx, req.Params)
	case "resources/list":
		result = map[string]any{"resources": []any{}}
	case "resources/templates/list":
		result = map[string]any{"resourceTemplates": []any{}}
	case "prompts/list":
		result = map[string]any{"prompts": []any{}}
	default:
		err = &rpcError{codeMethodNotFound, fmt.Sprintf("method %q is not served: pgvigil mcp is read-only and serves initialize, ping, tools/list and tools/call", req.Method)}
	}
	if err != nil {
		return fail(req.ID, err.Code, err.Message)
	}
	return response{JSONRPC: "2.0", ID: req.ID, Result: result}, true
}

func (s *Server) initialize(params json.RawMessage) (any, *rpcError) {
	var p struct {
		ProtocolVersion string `json:"protocolVersion"`
	}
	if len(params) > 0 {
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, &rpcError{codeInvalidParams, "initialize params: " + err.Error()}
		}
	}
	v := ProtocolVersions[0] // the client's when this server speaks it, else the newest (the client decides)
	for _, k := range ProtocolVersions {
		if k == p.ProtocolVersion {
			v = k
		}
	}
	return map[string]any{
		"protocolVersion": v,
		"capabilities":    map[string]any{"tools": map[string]any{"listChanged": false}},
		"serverInfo":      map[string]any{"name": "pgvigil", "title": "pgvigil repository (read only)", "version": s.version},
		"instructions": "Read-only tools over a pgvigil monitoring repository of PostgreSQL instances. " +
			"Start with fleet_summary to see the instances and their failing checks; an instance is named by its name or its instance_id. " +
			"Times are RFC 3339; a window defaults to the last hour (24 hours for plans). Statement text is what the instance's query_text policy let the repository keep.",
	}, nil
}

func (s *Server) call(ctx context.Context, params json.RawMessage) (any, *rpcError) {
	var p struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, &rpcError{codeInvalidParams, "tools/call params: " + err.Error()}
	}
	t, ok := toolByName(p.Name)
	if !ok {
		return nil, &rpcError{codeInvalidParams, fmt.Sprintf("unknown tool %q: pgvigil mcp is read-only; it serves only the tools tools/list names and has no tool that writes, cancels, terminates or runs SQL", p.Name)}
	}
	args := map[string]any{}
	if len(p.Arguments) > 0 && string(p.Arguments) != "null" {
		d := json.NewDecoder(bytes.NewReader(p.Arguments))
		d.UseNumber()
		if err := d.Decode(&args); err != nil {
			return toolError("arguments must be a JSON object: " + err.Error()), nil
		}
	}
	for k := range args {
		if !t.takes(k) {
			return toolError(fmt.Sprintf("%s takes no argument %q (it takes: %s)", t.Name, k, strings.Join(t.argNames(), ", "))), nil
		}
	}
	v, err := t.run(ctx, s, args)
	if err != nil {
		return toolError(err.Error()), nil
	}
	b, err := json.MarshalIndent(s.limit(v), "", " ")
	if err != nil {
		return toolError("the result could not be encoded: " + err.Error()), nil
	}
	return map[string]any{"content": []any{map[string]any{"type": "text", "text": string(b)}}, "isError": false}, nil
}

func toolError(msg string) map[string]any {
	return map[string]any{"content": []any{map[string]any{"type": "text", "text": msg}}, "isError": true}
}

// get runs one GET against the API handler in process and decodes its JSON (numbers kept exact).
func (s *Server) get(ctx context.Context, path string, q url.Values) (any, error) {
	u := "http://pgvigil-mcp" + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	r, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	r.RemoteAddr = "127.0.0.1:0"
	w := &recorder{h: http.Header{}}
	s.api.ServeHTTP(w, r)
	d := json.NewDecoder(&w.buf)
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		return nil, fmt.Errorf("%s: status %d, the reply is not JSON", path, w.status())
	}
	if w.status() != http.StatusOK {
		if m, ok := v.(map[string]any); ok {
			if e, ok := m["error"].(string); ok {
				return nil, errors.New(e)
			}
		}
		return nil, fmt.Errorf("%s: status %d", path, w.status())
	}
	return v, nil
}

// recorder is the in-process ResponseWriter.
type recorder struct {
	h    http.Header
	code int
	buf  bytes.Buffer
}

func (r *recorder) Header() http.Header { return r.h }
func (r *recorder) WriteHeader(c int) {
	if r.code == 0 {
		r.code = c
	}
}
func (r *recorder) Write(b []byte) (int, error) {
	if r.code == 0 {
		r.code = http.StatusOK
	}
	return r.buf.Write(b)
}
func (r *recorder) status() int {
	if r.code == 0 {
		return http.StatusOK
	}
	return r.code
}

var (
	pwKV  = regexp.MustCompile(`(?i)(password\s*=\s*)('(?:[^'\\]|\\.)*'|[^\s"]+)`)
	pwURL = regexp.MustCompile(`(postgres(?:ql)?://[^:/@\s"]+:)[^@\s"]+@`)
)

// scrub removes the login's password and any password-shaped value from a reply.
func (s *Server) scrub(text string) string {
	for _, sec := range s.secrets {
		text = strings.ReplaceAll(text, sec, "[redacted]")
		if j, err := json.Marshal(sec); err == nil { // the JSON-escaped form, as it sits in a reply line
			if e := string(j[1 : len(j)-1]); e != sec {
				text = strings.ReplaceAll(text, e, "[redacted]")
			}
		}
	}
	text = pwKV.ReplaceAllString(text, "${1}[redacted]")
	return pwURL.ReplaceAllString(text, "${1}[redacted]@")
}
