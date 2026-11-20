package alerts

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// task B24k: the azuremonitor kind against loopback stubs of the token endpoint (Microsoft's client-credentials page:
// a form post, {token_type, expires_in, access_token}) and the Logs Ingestion upload (the tutorial: 204; 401, 400 with
// {"error":{"code","message"}}). The 204 and the error bodies of the upload are assumed beyond what the pages state.

const (
	azTestTenant = "72f988bf-86f1-41af-91ab-2d7cd011db47"
	azTestClient = "00001111-aaaa-2222-bbbb-3333cccc4444"
	azTestSecret = "qWgdYAmab0YSkuL1qKv5bPX"
	azTestDCR    = "dcr-0123456789abcdef0123456789abcdef"
)

type azStub struct {
	mu        sync.Mutex
	tokens    int
	tokenForm []string
	uploads   [][]map[string]any
	sizes     []int
	answer    int // the next upload's status (0 = 204)
	answerSet bool
	body      string
}

func (st *azStub) handler(t *testing.T) http.Handler {
	t.Helper()
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		st.mu.Lock()
		defer st.mu.Unlock()
		switch {
		case r.URL.Path == "/"+azTestTenant+"/oauth2/v2.0/token" && r.Method == http.MethodPost:
			_ = r.ParseForm()
			st.tokens++
			st.tokenForm = append(st.tokenForm, r.PostForm.Encode())
			if r.PostForm.Get("client_secret") != azTestSecret || r.PostForm.Get("grant_type") != "client_credentials" {
				w.WriteHeader(http.StatusBadRequest)
				_, _ = w.Write([]byte(`{"error":"invalid_client","error_description":"AADSTS7000215: Invalid client secret ` + r.PostForm.Get("client_secret") + `"}`))
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"token_type": "Bearer", "expires_in": 3599, "access_token": "tok" + string(rune('0'+st.tokens))})
		case r.URL.Path == "/dataCollectionRules/"+azTestDCR+"/streams/Custom-PgvigilAlerts" && r.URL.Query().Get("api-version") == "2023-01-01":
			if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer tok") || r.Header.Get("Content-Type") != "application/json" {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			raw, _ := io.ReadAll(r.Body)
			var rows []map[string]any
			_ = json.Unmarshal(raw, &rows)
			code := http.StatusNoContent
			if st.answerSet {
				code, st.answerSet = st.answer, false
			}
			if code == http.StatusUnauthorized && r.Header.Get("Authorization") != "Bearer tok1" {
				code = http.StatusNoContent // only the first token is refused
			}
			if code == http.StatusNoContent {
				st.uploads = append(st.uploads, rows)
				st.sizes = append(st.sizes, len(raw))
			}
			w.WriteHeader(code)
			_, _ = w.Write([]byte(st.body))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
}

func (st *azStub) next(code int, body string) {
	st.mu.Lock()
	st.answer, st.answerSet, st.body = code, true, body
	st.mu.Unlock()
}

func (st *azStub) seen() (tokens int, uploads [][]map[string]any, sizes []int) {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.tokens, append([][]map[string]any(nil), st.uploads...), append([]int(nil), st.sizes...)
}

func azureFor(t *testing.T, base string, secretEnv string) *azureSender {
	t.Helper()
	s, err := (&AzureMonitor{Endpoint: base, DCRID: azTestDCR, Stream: "Custom-PgvigilAlerts", Tenant: azTestTenant,
		ClientID: azTestClient, ClientSecret: secretEnv, LoginURL: base}).build()
	if err != nil {
		t.Fatal(err)
	}
	return s.(*azureSender)
}

func TestAzureMonitorRefuses(t *testing.T) {
	t.Setenv("PGV_TEST_AZ_SECRET", azTestSecret)
	good := AzureMonitor{Endpoint: "https://pgvigil-x1y2.eastus-1.ingest.monitor.azure.com", DCRID: azTestDCR, Stream: "Custom-PgvigilAlerts",
		Tenant: azTestTenant, ClientID: azTestClient, ClientSecret: "env:PGV_TEST_AZ_SECRET"}
	if _, err := good.build(); err != nil {
		t.Fatalf("a good block: %v", err)
	}
	for name, f := range map[string]func(*AzureMonitor){
		"inline secret":      func(a *AzureMonitor) { a.ClientSecret = azTestSecret },
		"a cloud":            func(a *AzureMonitor) { a.Cloud = "germany" },
		"tenant not a GUID":  func(a *AzureMonitor) { a.Tenant = "contoso.onmicrosoft.com" },
		"dcr id":             func(a *AzureMonitor) { a.DCRID = "my-dcr" },
		"stream":             func(a *AzureMonitor) { a.Stream = "PgvigilAlerts_CL" },
		"plain endpoint":     func(a *AzureMonitor) { a.Endpoint = "http://ingest.example.org" },
		"endpoint path":      func(a *AzureMonitor) { a.Endpoint = good.Endpoint + "/dataCollectionRules/x" },
		"a login off a test": func(a *AzureMonitor) { a.LoginURL = "https://login.example.org" },
	} {
		a := good
		f(&a)
		if _, err := a.build(); err == nil {
			t.Errorf("%s: built", name)
		}
	}
	for cloud, want := range map[string][2]string{
		"":      {"https://login.microsoftonline.com/", "https://monitor.azure.com//.default"},
		"usgov": {"https://login.microsoftonline.us/", "https://monitor.azure.us//.default"},
		"china": {"https://login.partner.microsoftonline.cn/", "https://monitor.azure.cn//.default"},
	} {
		a := good
		a.Cloud = cloud
		s, err := a.build()
		if err != nil {
			t.Fatalf("cloud %q: %v", cloud, err)
		}
		as := s.(*azureSender)
		if !strings.HasPrefix(as.token.String(), want[0]+azTestTenant+"/oauth2/v2.0/token") || as.scope != want[1] {
			t.Errorf("cloud %q: token %s scope %s, want %s / %s", cloud, as.token, as.scope, want[0], want[1])
		}
	}
}

func TestAzureMonitorSend(t *testing.T) {
	st := &azStub{}
	srv := httptest.NewServer(st.handler(t))
	defer srv.Close()
	t.Setenv("PGV_TEST_AZ_SECRET", azTestSecret)
	s := azureFor(t, srv.URL, "env:PGV_TEST_AZ_SECRET")
	if d := s.destination(); strings.Contains(d, azTestSecret) || !strings.HasSuffix(d, "(azure monitor logs)") {
		t.Errorf("destination %q", d)
	}
	ctx := context.Background()
	at := time.Date(2026, 11, 15, 8, 0, 0, 0, time.UTC)
	warn := crit
	warn.Severity = "warning"
	if err := s.send(ctx, Message{SentAt: at, Alerts: []Alert{crit, warn}}); err != nil {
		t.Fatalf("send: %v", err)
	}
	tokens, ups, _ := st.seen()
	if tokens != 1 || len(ups) != 1 || len(ups[0]) != 2 {
		t.Fatalf("tokens %d, uploads %v", tokens, ups)
	}
	r0 := ups[0][0]
	if r0["TimeGenerated"] != "2026-11-15T08:00:00Z" || r0["Severity"] != "critical" || r0["Instance"] != "erp01" || r0["Check"] != crit.Setting {
		t.Errorf("row 0 %v", r0)
	}
	st.mu.Lock()
	tf := st.tokenForm[0]
	st.mu.Unlock()
	if !strings.Contains(tf, "scope=http") || !strings.Contains(tf, "%2F%2F.default") {
		t.Errorf("token form %s: want the Monitor audience's //.default", tf)
	}
	// the token is kept: a second send fetches none
	if err := s.send(ctx, msg(crit)); err != nil {
		t.Fatal(err)
	}
	if tokens, _, _ = st.seen(); tokens != 1 {
		t.Errorf("%d token fetches for two sends, want 1", tokens)
	}
	// a 401 fetches the token again, once, and the upload goes
	s.mu.Lock()
	s.bearer = "tok1"
	s.mu.Unlock()
	st.next(http.StatusUnauthorized, "")
	if err := s.send(ctx, msg(crit)); err != nil {
		t.Errorf("after a 401: %v", err)
	}
	if tokens, _, _ = st.seen(); tokens != 2 {
		t.Errorf("%d token fetches after a 401, want 2", tokens)
	}
	// a 400 shows Azure's message
	st.next(http.StatusBadRequest, `{"error":{"code":"InvalidStream","message":"The stream Custom-PgvigilAlerts is not declared in the DCR"}}`)
	if err := s.send(ctx, msg(crit)); err == nil || !strings.Contains(err.Error(), "InvalidStream The stream") {
		t.Errorf("a 400: %v", err)
	}
	// a long detail is cut at 60,000 bytes on a character; 40 such rows go in several calls, each under the budget
	big := crit
	big.Detail = strings.Repeat("é", 40000) // 80,000 bytes
	many := make([]Alert, 40)
	for i := range many {
		many[i] = big
	}
	_, before, _ := st.seen()
	if err := s.send(ctx, Message{SentAt: at, Alerts: many}); err != nil {
		t.Fatal(err)
	}
	_, ups, sizes := st.seen()
	ups, sizes = ups[len(before):], sizes[len(before):]
	rows := 0
	for i, u := range ups {
		rows += len(u)
		if sizes[i] > azMaxCall {
			t.Errorf("call %d of %d bytes, over %d", i, sizes[i], azMaxCall)
		}
	}
	if rows != 40 || len(ups) < 3 {
		t.Errorf("%d rows in %d calls, want 40 in several", rows, len(ups))
	}
	if d := ups[0][0]["Detail"].(string); len(d) > azMaxDetail || !strings.HasPrefix(d, "éé") {
		t.Errorf("a detail of %d bytes", len(d))
	}
}

func TestAzureMonitorTokenError(t *testing.T) {
	st := &azStub{}
	srv := httptest.NewServer(st.handler(t))
	defer srv.Close()
	t.Setenv("PGV_TEST_AZ_WRONG", "wrong-secret-value")
	s := azureFor(t, srv.URL, "env:PGV_TEST_AZ_WRONG")
	err := s.send(context.Background(), msg(crit))
	if err == nil || !strings.Contains(err.Error(), "AADSTS7000215") || strings.Contains(err.Error(), "wrong-secret-value") {
		t.Errorf("a refused secret (Entra's words, the secret scrubbed): %v", err)
	}
	if _, ups, _ := st.seen(); len(ups) != 0 {
		t.Error("an upload without a token")
	}
}

// the secret is replaced before Azure's words are cut, so a cut through it leaves no part of it.
func TestAzureWordsHideBeforeCut(t *testing.T) {
	desc := strings.Repeat("a", maxLine-len(" ...")-len("invalid_client ")-8) + azTestSecret // the cut falls inside the secret
	raw := []byte(`{"error":"invalid_client","error_description":"` + desc + `"}`)
	if got := azWords(raw); !strings.Contains(got, azTestSecret[:8]) {
		t.Fatalf("the case does not cut through the secret: %q", got[len(got)-20:])
	}
	if got := azWords(raw, azTestSecret); strings.Contains(got, azTestSecret[:8]) {
		t.Errorf("a part of the secret survived the cut: %q", got[len(got)-20:])
	}
}
