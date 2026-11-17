package web

import (
	"encoding/json"
	"testing"
)

// review-26 go2 N2 (B20-4): a render's post of the wrong JSON type, or one its checks refuse, is dropped with its
// reason - the body still decodes, so the mail goes without its post.
func TestRenderPostDropped(t *testing.T) {
	for _, c := range []struct {
		post string
		kept bool
		why  string
	}{
		{`{"instances": 12, "critical": 3, "warnings": 4, "worst": [{"name": "sql01", "critical": 2, "warnings": 0}]}`, true, ""},
		{`null`, false, ""},
		{`"oops"`, false, "the post is not an object of counts"},
		{`[1, 2]`, false, "the post is not an object of counts"},
		{`{"instances": "many"}`, false, "the post is not an object of counts"},
		{`{"instances": -1}`, false, "the post's counts are not counts"},
	} {
		var in mailRequest
		if err := json.Unmarshal([]byte(`{"key": "k", "html": "<p>x</p>", "post": `+c.post+`}`), &in); err != nil {
			t.Errorf("post %s: the body did not decode (the mail would fail with its post): %v", c.post, err)
			continue
		}
		p, err := dailyPostOf(in.Post)
		why := ""
		if err != nil {
			why = err.Error()
		}
		if (p != nil) != c.kept || why != c.why {
			t.Errorf("post %s: kept %v, why %q; want kept %v, why %q", c.post, p != nil, why, c.kept, c.why)
		}
		if c.kept && (p.Instances != 12 || p.Critical != 3 || len(p.Worst) != 1) {
			t.Errorf("post %s: read as %+v", c.post, p)
		}
	}
	// no post field at all: none, and no reason
	var in mailRequest
	if err := json.Unmarshal([]byte(`{"key": "k", "html": "<p>x</p>"}`), &in); err != nil {
		t.Fatal(err)
	}
	if p, err := dailyPostOf(in.Post); p != nil || err != nil {
		t.Errorf("no post field: %v %v", p, err)
	}
}
