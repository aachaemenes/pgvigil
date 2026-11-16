package alerts

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// Post is a short text a channel posts outside the alert cycle - no finding, no repeat, no recovery: the Daily checks
// mail's counts after its mail is sent (B20-4). Only a webhook channel posts one (Slack, Teams, Discord, Google Chat or
// json); the json format carries Fields beside the text, for a program that reads it.
type Post struct {
	Kind   string         // what it is: the json format's "kind" ("daily checks")
	Title  string         // the first line
	Lines  []string       // the lines after it
	Route  string         // the UI page it links to (#/checks?w=24h), after alerts_base_url; no base = no link
	Fields map[string]any // the json format's other keys (the numbers); never one of source, kind, summary, text, link
}

// Post sends p on the channel: refused in words on a channel that is not a webhook.
func (c *Channel) Post(ctx context.Context, p Post) error {
	if c.Kind != "webhook" {
		return fmt.Errorf("channel %s is a %s channel: a post goes to a webhook channel", c.Name, c.Kind)
	}
	w, ok := c.sender.(*webhookSender)
	if !ok || w == nil {
		return fmt.Errorf("channel %s is not built", c.Name)
	}
	link := ""
	if c.base != "" && p.Route != "" {
		link = strings.TrimRight(c.base, "/") + "/" + strings.TrimLeft(p.Route, "/")
	}
	body, err := w.postBody(p, link)
	if err != nil {
		return err
	}
	sctx, cancel := context.WithTimeout(ctx, sendTimeout)
	defer cancel()
	return w.do(sctx, body)
}

// postBody is a Post in the channel's format; the text is the title, the lines and the link, one a line
func (s *webhookSender) postBody(p Post, link string) ([]byte, error) {
	lines := append([]string{}, p.Lines...)
	if link != "" {
		lines = append(lines, link)
	}
	plain := strings.Join(append([]string{p.Title}, lines...), "\n")
	switch s.format {
	case "slack":
		return json.Marshal(map[string]any{"text": strings.Join(append([]string{"*" + p.Title + "*"}, lines...), "\n")})
	case "discord":
		t := strings.Join(append([]string{"**" + p.Title + "**"}, lines...), "\n")
		if len(t) > discordLimit {
			t = t[:discordLimit]
		}
		return json.Marshal(map[string]any{"content": t, "username": "pgvigil", "allowed_mentions": map[string]any{"parse": []string{}}})
	case "googlechat":
		t := strings.Join(append([]string{"*" + p.Title + "*"}, lines...), "\n")
		if len(t) > googleChatLimit {
			t = t[:googleChatLimit]
		}
		return json.Marshal(map[string]any{"text": strings.ReplaceAll(t, "<users/", "< users/")})
	case "teams":
		body := []map[string]any{{"type": "TextBlock", "text": p.Title, "weight": "Bolder", "size": "Medium", "wrap": true}}
		for _, l := range lines {
			body = append(body, map[string]any{"type": "TextBlock", "text": l, "wrap": true})
		}
		return json.Marshal(map[string]any{"type": "message", "attachments": []map[string]any{{
			"contentType": "application/vnd.microsoft.card.adaptive",
			"content": map[string]any{"type": "AdaptiveCard", "version": "1.4",
				"$schema": "http://adaptivecards.io/schemas/adaptive-card.json", "body": body},
		}}})
	}
	out := map[string]any{}
	for k, v := range p.Fields {
		out[k] = v
	}
	out["source"], out["kind"], out["summary"], out["text"], out["link"] = "pgvigil", p.Kind, p.Title, plain, link
	return json.Marshal(out)
}
