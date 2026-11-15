package collect

import (
	"context"
	"errors"
	"net"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// The reachability probe (B24h-1b; dbachecks Instance#3, Server#4 / #5; the B24h fold's #1, #6, #9): a measure of
// whether, and how fast, a host answers - on its own goroutine and ticker, never inside a collection's run or the
// heartbeat's minute. B24h-1 measures the TCP handshake (connect() until it returns) to the address and port the
// instance's last opened connection used - no TLS, no login; a refusal (RST) is an answer. B24h-2 adds ICMP on Linux.
// By default an address is probed only after a collection of an instance on it failed (its answer goes into 'server
// unreachable' and the parent's 'server not answering'); probe_every_minute probes every known address each minute.

const (
	probeRoundMax   = 40 * time.Second // a round's hard deadline: an address not done by then is 'not probed'
	probeConnectMax = time.Second      // one connect's wait (Instance#3: an answer within 1000 ms)
	probeInFlight   = 32               // probes at once at least (probeInFlightFor sizes each round: Q3's 20 s)
	probeNeverEvery = 15 * time.Minute // an address that never answered is probed this often at most
)

// beatProbe: one address's probe in a round, on the beat (pgvigil.collector_probe, 0254). Answered nil: not probed in
// its round (the round's deadline), never 'not answered'.
type beatProbe struct {
	Host     string    `json:"host"`
	Address  string    `json:"address"`
	Method   string    `json:"method"`
	At       time.Time `json:"at"`
	Sent     int       `json:"sent"`
	Answered *int      `json:"answered"`
	MsSum    int64     `json:"ms_sum"`
	MsMax    int       `json:"ms_max"`
	// a round of probe_every_minute (the review of B24h-1 part b #7, the lead's 12:4x (a)): ping slow and not answering
	// judge such rows only - the default mode's probes after a failure feed the parent's words
	Scheduled bool `json:"scheduled"`
}

// beatOpened: an address a connection of an instance opened to since the last beat - a TCP answer (the review of
// B24h-1 part a #1): the repository sets the host's last answer from it (import_collector_probe)
type beatOpened struct {
	Host    string    `json:"host"`
	Address string    `json:"address"`
	At      time.Time `json:"at"`
}

// probeInFlightFor: the probes at once for a round of n addresses, so the round ends within 20 s at one connect's wait
// (the design fold's Q3: 2,124 hosts in about 20 s; the review of B24h-1 part a #5 - 32 fixed took 66 s), 32 at least,
// 512 at most
func probeInFlightFor(n int, connectMax time.Duration) int {
	ms := int(connectMax / time.Millisecond)
	return min(max(32, (n*ms+19999)/20000), 512)
}

type prober struct {
	method     string // 'tcp' (B24h-1: 'icmp' reads as tcp until B24h-2)
	every      bool   // probe_every_minute
	connectMax time.Duration
	roundMax   time.Duration
	dial       func(ctx context.Context, addr string) error

	mu       sync.Mutex
	addrOf   map[string]string    // instance: the address (ip:port) its last opened connection used
	hostOf   map[string]string    // address: the dial host it was reached by
	due      map[string]bool      // address: a collection of an instance on it failed since the last round
	answered map[string]bool      // address: answered at least once since the collector started
	tried    map[string]time.Time // address: when it was last probed
	out      []beatProbe
	opened   map[string]beatOpened // address: its newest opened connection since the last beat
}

func newProber(method string, every bool) *prober {
	return &prober{method: method, every: every, connectMax: probeConnectMax, roundMax: probeRoundMax, dial: dialTCP,
		addrOf: map[string]string{}, hostOf: map[string]string{}, due: map[string]bool{}, answered: map[string]bool{}, tried: map[string]time.Time{},
		opened: map[string]beatOpened{}}
}

func dialTCP(ctx context.Context, addr string) error {
	c, err := (&net.Dialer{}).DialContext(ctx, "tcp", addr)
	if err == nil {
		_ = c.Close()
	}
	return err
}

// noteRemote: the instance's connection opened to addr (its RemoteAddr), reached by the dial host. An opened
// connection is a TCP answer (the review of B24h-1 part a #1): the address is answered from now on (so a host that goes
// down is probed every minute after a failure, never throttled as one that never answered), and the beat carries it
func (p *prober) noteRemote(instance, host, addr string) {
	if addr == "" {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.addrOf[instance], p.hostOf[addr] = addr, host
	if p.method == "tcp" {
		p.answered[addr] = true
	}
	p.opened[addr] = beatOpened{Host: host, Address: addr, At: time.Now().UTC()}
}

// takeOpened hands the opened addresses since the last beat to the beat, sorted by address
func (p *prober) takeOpened() []beatOpened {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]beatOpened, 0, len(p.opened))
	for _, o := range p.opened {
		out = append(out, o)
	}
	p.opened = map[string]beatOpened{}
	sort.Slice(out, func(i, j int) bool { return out[i].Address < out[j].Address })
	return out
}

// noteFailed: a collection of the instance failed - its address is probed in the next round (the default mode)
func (p *prober) noteFailed(instance string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if a := p.addrOf[instance]; a != "" {
		p.due[a] = true
	}
}

// round probes the addresses due at now (every known one under probe_every_minute, else those whose instance failed),
// at most probeInFlight at once, within the round's deadline; an address that never answered waits 15 minutes
func (p *prober) round(ctx context.Context, now time.Time) {
	p.mu.Lock()
	var addrs []string
	seen := map[string]bool{}
	for _, a := range p.addrOf {
		if seen[a] || (!p.every && !p.due[a]) {
			continue
		}
		seen[a] = true
		if t, ok := p.tried[a]; ok && !p.answered[a] && now.Sub(t) < probeNeverEvery {
			continue
		}
		addrs = append(addrs, a)
	}
	p.due = map[string]bool{}
	p.mu.Unlock()
	sort.Strings(addrs)
	rctx, cancel := context.WithTimeout(ctx, p.roundMax)
	defer cancel()
	res := make([]beatProbe, len(addrs))
	sem := make(chan struct{}, probeInFlightFor(len(addrs), p.connectMax))
	var wg sync.WaitGroup
	for i, a := range addrs {
		res[i] = beatProbe{Address: a, Method: p.method, At: now, Scheduled: p.every}
		wg.Add(1)
		go func(i int, a string) {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
			case <-rctx.Done():
				return // not started before the round's deadline: not probed
			}
			defer func() { <-sem }()
			cctx, ccancel := context.WithTimeout(rctx, p.connectMax)
			t0 := time.Now()
			err := p.dial(cctx, a)
			took := time.Since(t0)
			ccancel()
			if rctx.Err() != nil && err != nil && !refused(err) {
				return // cut by the round's deadline, not by its own wait: not probed
			}
			ans := 0
			if err == nil || refused(err) {
				ans = 1
			}
			res[i].Sent, res[i].Answered = 1, &ans
			if ans == 1 {
				// a handshake under a millisecond is 1 ms, never 0 (the review of B24h-1 part a #9)
				ms := max(took.Milliseconds(), 1)
				res[i].MsSum, res[i].MsMax = ms, int(ms)
			}
		}(i, a)
	}
	wg.Wait()
	p.mu.Lock()
	defer p.mu.Unlock()
	for i := range res {
		res[i].Host = p.hostOf[res[i].Address]
		if res[i].Answered != nil {
			p.tried[res[i].Address] = now
			if *res[i].Answered > 0 {
				p.answered[res[i].Address] = true
			}
		}
	}
	p.out = append(p.out, res...)
}

// loop: one round a minute, 30 s into it (apart from the heartbeat's minute), until the collector stops
func (p *prober) loop(ctx context.Context) {
	for {
		next := time.Now().Truncate(time.Minute).Add(time.Minute + 30*time.Second)
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Until(next)):
		}
		p.round(ctx, next.Truncate(time.Minute))
	}
}

// NoteRemote: the address (ip:port) an instance's connection just opened to - the probe's target for it (the fold's
// #6b: the address the last opened connection used); a loopback or socket address is not probed ('local')
func NoteRemote(instance, addr string) {
	if h := current.Load(); h != nil {
		h.noteRemote(instance, addr)
	}
}

func (h *Heartbeat) noteRemote(instance, addr string) {
	if h.probe == nil || !probeable(addr) {
		return
	}
	h.mu.Lock()
	host := targetHost(h.targets[instance])
	h.mu.Unlock()
	h.probe.noteRemote(instance, host, addr)
}

// probeable: a TCP address that is not loopback (a socket path, a loopback connection: 'local: not probed')
func probeable(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && !ip.IsLoopback()
}

// targetHost: the first host of a dial target ('postgres:db1:5432,db2:5433' -> 'db1'), as 0254's collector_target_host
// cuts it: an IPv6 literal written bare by PgTarget ('postgres:2001:db8::1:5432', pgx strips its brackets) loses its
// trailing ':port' (the review of B24h-1 part a #4), and a SQL Server named instance its '\name' (part b #6: one box,
// one host)
func targetHost(t string) string {
	if i := strings.IndexByte(t, ':'); i >= 0 {
		t = t[i+1:]
	}
	if i := strings.IndexByte(t, ','); i >= 0 {
		t = t[:i]
	}
	if h, _, err := net.SplitHostPort(t); err == nil {
		t = h
	} else if i := strings.LastIndexByte(t, ':'); i > 0 && allDigits(t[i+1:]) {
		t = t[:i]
	}
	if i := strings.IndexByte(t, '\\'); i >= 0 {
		t = t[:i]
	}
	return t
}

func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// take hands the rounds' rows to the beat
func (p *prober) take() []beatProbe {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := p.out
	p.out = nil
	return out
}

// refused: the host answered with a reset - an answer. ECONNREFUSED; on Windows the socket's own WSAECONNREFUSED
// (10061: Go's syscall.ECONNREFUSED there is an invented value the dialer never returns)
func refused(err error) bool {
	return errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, syscall.Errno(10061))
}
