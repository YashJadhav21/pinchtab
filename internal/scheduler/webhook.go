package scheduler

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"time"
)

// webhookClient is a dedicated HTTP client for webhook delivery with short timeouts.
var webhookClient = &http.Client{
	Timeout: 10 * time.Second,
}

// sendWebhook delivers a task snapshot to the configured callbackUrl.
// Delivery is best-effort: failures are logged but do not affect task state.
func sendWebhook(callbackURL string, t *Task) {
	if callbackURL == "" {
		return
	}

	// Only allow http/https schemes to prevent SSRF.
	parsed, err := url.Parse(callbackURL)
	if err != nil {
		slog.Warn("webhook: invalid callback URL", "task", t.ID, "url", callbackURL, "err", err)
		return
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		slog.Warn("webhook: unsupported scheme", "task", t.ID, "scheme", parsed.Scheme)
		return
	}

	snap := t.Snapshot()
	payload, err := json.Marshal(snap)
	if err != nil {
		slog.Warn("webhook: failed to marshal task", "task", t.ID, "err", err)
		return
	}

	req, err := http.NewRequest(http.MethodPost, callbackURL, bytes.NewReader(payload))
	if err != nil {
		slog.Warn("webhook: failed to create request", "task", t.ID, "err", err)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-PinchTab-Event", "task.completed")
	req.Header.Set("X-PinchTab-Task-ID", snap.ID)

	resp, err := webhookClient.Do(req)
	if err != nil {
		slog.Warn("webhook: delivery failed", "task", t.ID, "url", callbackURL, "err", err)
		return
	}
	// Drain body so the underlying connection can be reused.
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()

	if resp.StatusCode >= 400 {
		slog.Warn("webhook: non-success response", "task", t.ID, "url", callbackURL, "status", resp.StatusCode)
		return
	}

	slog.Info("webhook: delivered", "task", t.ID, "url", callbackURL, "status", resp.StatusCode)
}
