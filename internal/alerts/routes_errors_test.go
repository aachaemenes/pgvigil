package alerts

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"strconv"
	"strings"
	"testing"
)

// A pass whose routes door failed is logged by Run as a warning, a quiet pass too (nothing sent, so the pass's own
// line is not written).
func TestLogPassWarnsRoutesErr(t *testing.T) {
	var b strings.Builder
	logPass(slog.New(slog.NewTextHandler(&b, nil)), Result{RoutesErr: errors.New("the door said no")}, nil)
	out := b.String()
	if !strings.Contains(out, "level=WARN") || !strings.Contains(out, "contact routes were not read") || !strings.Contains(out, "the door said no") {
		t.Fatalf("a quiet pass whose routes door failed logged %q, want a WARN naming the contact routes and the error", out)
	}
}

// A relay that refuses the recipient in its own words (a rewritten address, the local part alone) leaves nothing of
// the address in the route's error - its reply code stays; a refusal pgvigil makes itself (no STARTTLS) stays a
// refusal through the route.
func TestRouteSenderScrubsAndKeepsRefused(t *testing.T) {
	route := func(t *testing.T, sk *sink, mode string) *routeSender {
		t.Helper()
		host, port, _ := net.SplitHostPort(sk.ln.Addr().String())
		p, _ := strconv.Atoi(port)
		b, err := (&SMTP{Host: host, Port: p, TLS: mode, From: "pgvigil@example.org", To: []string{"Ann.Example@example.com"}}).build()
		if err != nil {
			t.Fatal(err)
		}
		return &routeSender{smtp: b.(*smtpSender), contact: 7, addr: "ann.example@example.com", raw: "Ann.Example@example.com", dest: "contact 7"}
	}
	sk := newSink(t, false)
	sk.rcptReply = "550 5.1.1 <ANN.EXAMPLE@relay.example.net> (ann.example) mailbox unknown"
	err := route(t, sk, "none").send(context.Background(), msg(crit))
	if err == nil || strings.Contains(strings.ToLower(err.Error()), "ann") || !strings.Contains(err.Error(), "contact 7") || !strings.Contains(err.Error(), "550") {
		t.Errorf("a relay's refusal in its own words: the route's error is %v, want 'contact 7' and the code 550 with nothing of the address", err)
	}
	if len(sk.msgs) != 0 {
		t.Error("a refused recipient was sent to")
	}
	err = route(t, newSink(t, false), "starttls").send(context.Background(), msg(crit))
	var re *refusedError
	if !errors.As(err, &re) || !strings.Contains(err.Error(), "STARTTLS") {
		t.Errorf("a relay without STARTTLS through a route: %v, want a refusal", err)
	}
}
