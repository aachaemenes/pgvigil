package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Release is what the update check reads from the feed (the GitHub release JSON, or a mirror's file
// of the same shape): the tag and the page to open.
type Release struct {
	Tag string `json:"tag_name"`
	URL string `json:"html_url"`
}

// UpdateInterval is how often the check runs at most.
const UpdateInterval = 24 * time.Hour

// CheckUpdate reads the feed and says whether its release is newer than current. Only an https feed is
// read, or http to loopback (a local mirror, a test). Nothing is downloaded or installed: the result
// is a notice with the release page.
func CheckUpdate(ctx context.Context, client *http.Client, feed, current string) (Release, bool, error) {
	u, err := url.Parse(feed)
	if err != nil {
		return Release{}, false, fmt.Errorf("update feed: %w", err)
	}
	if err := feedAllowed(u); err != nil {
		return Release{}, false, err
	}
	// a redirect is held to the same rule as the feed itself (the client would follow it anywhere)
	c := *client
	c.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("update feed: too many redirects")
		}
		return feedAllowed(req.URL)
	}
	client = &c
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, feed, nil)
	if err != nil {
		return Release{}, false, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "pgvigil-app/"+version) // the version alone: no machine, user or install id
	resp, err := client.Do(req)
	if err != nil {
		return Release{}, false, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return Release{}, false, fmt.Errorf("update feed: status %d", resp.StatusCode)
	}
	var r Release
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&r); err != nil {
		return Release{}, false, fmt.Errorf("update feed: %w", err)
	}
	if _, ok := parseVersion(r.Tag); !ok {
		return r, false, fmt.Errorf("update feed: tag %q is not vX.Y.Z", r.Tag)
	}
	if p, err := url.Parse(r.URL); err != nil || p.Scheme != "https" {
		r.URL = "" // a page the window will not open
	}
	return r, Newer(r.Tag, current), nil
}

// feedAllowed is the feed's rule: https, or http to loopback (a local mirror, a test).
func feedAllowed(u *url.URL) error {
	if u.Scheme == "https" || (u.Scheme == "http" && loopbackHost(u.Hostname())) {
		return nil
	}
	return fmt.Errorf("update feed: %s is not https (http only to loopback, for a local mirror)", u.Redacted())
}

// Newer says whether tag is a later release than current; a dev or unparsable current never asks.
func Newer(tag, current string) bool {
	a, ok1 := parseVersion(tag)
	b, ok2 := parseVersion(current)
	if !ok1 || !ok2 {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return a[i] > b[i]
		}
	}
	return false
}

// parseVersion reads vX.Y.Z (a -suffix, a pre-release, is not offered: it parses as not ok).
func parseVersion(v string) ([3]int, bool) {
	var out [3]int
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	parts := strings.Split(v, ".")
	if len(parts) != 3 {
		return out, false
	}
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return out, false
		}
		out[i] = n
	}
	return out, true
}

// DueForCheck says whether the last check (unix seconds; 0 = never) is older than the interval.
func DueForCheck(last int64, now time.Time) bool {
	return last <= 0 || now.Sub(time.Unix(last, 0)) >= UpdateInterval || time.Unix(last, 0).After(now.Add(time.Hour))
}
