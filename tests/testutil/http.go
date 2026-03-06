package testutil

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// Client wraps an HTTP client bound to a server URL for integration tests.
type Client struct {
	BaseURL   string
	AuthToken string
	Timeout   time.Duration
}

// NewClient creates a test HTTP client for the given base URL.
func NewClient(baseURL string) *Client {
	return &Client{
		BaseURL:   baseURL,
		AuthToken: "test-token",
		Timeout:   45 * time.Second,
	}
}

// Get performs a GET request and returns status + body.
func (c *Client) Get(t *testing.T, path string) (int, []byte) {
	t.Helper()
	resp, err := http.Get(c.BaseURL + path)
	if err != nil {
		t.Fatalf("GET %s failed: %v", path, err)
	}
	defer resp.Body.Close() //nolint:errcheck
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, body
}

// Post performs a POST request with JSON body.
func (c *Client) Post(t *testing.T, path string, payload any) (int, []byte) {
	t.Helper()
	var reader io.Reader
	if payload != nil {
		data, err := json.Marshal(payload)
		if err != nil {
			t.Fatalf("marshal failed: %v", err)
		}
		reader = strings.NewReader(string(data))
	}
	resp, err := http.Post(c.BaseURL+path, "application/json", reader)
	if err != nil {
		t.Fatalf("POST %s failed: %v", path, err)
	}
	defer resp.Body.Close() //nolint:errcheck
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, body
}

// PostRaw performs a POST request with a raw string body.
func (c *Client) PostRaw(t *testing.T, path string, body string) (int, []byte) {
	t.Helper()
	resp, err := http.Post(c.BaseURL+path, "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatalf("POST %s failed: %v", path, err)
	}
	defer resp.Body.Close() //nolint:errcheck
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, data
}

// Patch performs a PATCH request with JSON body.
func (c *Client) Patch(t *testing.T, path string, payload any) (int, []byte) {
	t.Helper()
	var reader io.Reader
	if payload != nil {
		data, err := json.Marshal(payload)
		if err != nil {
			t.Fatalf("marshal failed: %v", err)
		}
		reader = strings.NewReader(string(data))
	}
	req, err := http.NewRequest("PATCH", c.BaseURL+path, reader)
	if err != nil {
		t.Fatalf("PATCH %s request creation failed: %v", path, err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("PATCH %s failed: %v", path, err)
	}
	defer resp.Body.Close() //nolint:errcheck
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, body
}

// Delete performs a DELETE request.
func (c *Client) Delete(t *testing.T, path string) (int, []byte) {
	t.Helper()
	req, err := http.NewRequest("DELETE", c.BaseURL+path, nil)
	if err != nil {
		t.Fatalf("DELETE %s request creation failed: %v", path, err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("DELETE %s failed: %v", path, err)
	}
	defer resp.Body.Close() //nolint:errcheck
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, body
}

// PostWithRetry attempts a POST request with retries for flaky tests.
func (c *Client) PostWithRetry(t *testing.T, path string, body any, maxRetries int) (int, []byte) {
	t.Helper()

	var lastCode int
	var lastBody []byte
	var lastErr error

	client := &http.Client{Timeout: c.Timeout}

	for i := 0; i <= maxRetries; i++ {
		if i > 0 {
			t.Logf("Retry %d/%d for %s", i, maxRetries, path)
			time.Sleep(2 * time.Second)
		}

		var reader io.Reader
		if body != nil {
			data, _ := json.Marshal(body)
			reader = strings.NewReader(string(data))
		}

		req, err := http.NewRequest("POST", c.BaseURL+path, reader)
		if err != nil {
			lastErr = err
			continue
		}
		req.Header.Set("Content-Type", "application/json")
		if c.AuthToken != "" {
			req.Header.Set("Authorization", "Bearer "+c.AuthToken)
		}

		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			t.Logf("Request failed with error: %v", err)
			continue
		}

		respBody, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		lastCode = resp.StatusCode
		lastBody = respBody
		lastErr = nil

		if resp.StatusCode == 200 {
			return resp.StatusCode, respBody
		}
		t.Logf("Request failed with status %d: %s", resp.StatusCode, string(respBody))
	}

	if lastErr != nil {
		t.Fatalf("http post %s: %v", path, lastErr)
	}
	return lastCode, lastBody
}

// JSONField extracts a string field from JSON response body.
func JSONField(t *testing.T, data []byte, key string) string {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("json parse failed: %v (body: %s)", err, string(data))
	}
	v, ok := m[key]
	if !ok {
		return ""
	}
	switch val := v.(type) {
	case string:
		return val
	default:
		b, _ := json.Marshal(val)
		return string(b)
	}
}
