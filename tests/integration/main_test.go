//go:build integration

package integration

import (
	"fmt"
	"os"
	"testing"

	"github.com/pinchtab/pinchtab/tests/testutil"
)

var (
	server       *testutil.Server
	client       *testutil.Client
	currentTabID string
)

func TestMain(m *testing.M) {
	cfg := testutil.DefaultConfig()

	var err error
	server, err = testutil.StartServer(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to start server: %v\n", err)
		os.Exit(1)
	}

	client = testutil.NewClient(server.URL)

	// Launch a test instance for orchestrator-mode tests
	if _, err := testutil.LaunchInstance(server.URL); err != nil {
		fmt.Fprintf(os.Stderr, "failed to launch test instance: %v\n", err)
		server.Stop()
		os.Exit(1)
	}

	code := m.Run()
	server.Stop()
	os.Exit(code)
}

func navigate(t *testing.T, url string) {
	t.Helper()
	code, body := client.PostWithRetry(t, "/navigate", map[string]any{"url": url}, 2)
	if code != 200 {
		t.Fatalf("navigate to %s failed with %d: %s", url, code, string(body))
	}

	if id := testutil.JSONField(t, body, "tabId"); id != "" {
		currentTabID = id
		t.Logf("current tab: %s", currentTabID)
		t.Cleanup(func() { closeCurrentTab(t) })
	}
}

func closeCurrentTab(t *testing.T) {
	t.Helper()
	if currentTabID == "" {
		return
	}
	_, _ = client.Post(t, "/tab", map[string]any{
		"tabId":  currentTabID,
		"action": "close",
	})
	currentTabID = ""
}

func navigateInstance(t *testing.T, instID, url string) (int, []byte, string) {
	t.Helper()

	openCode, openBody := client.PostWithRetry(t, fmt.Sprintf("/instances/%s/tabs/open", instID), map[string]any{
		"url": "about:blank",
	}, 2)
	if openCode != 200 {
		return openCode, openBody, ""
	}

	tabID := testutil.JSONField(t, openBody, "tabId")
	if tabID == "" {
		return 500, []byte(`{"error":"missing tabId from open tab response"}`), ""
	}

	path := fmt.Sprintf("/tabs/%s/navigate", tabID)
	code, body := client.PostWithRetry(t, path, map[string]any{"url": url}, 2)
	return code, body, tabID
}

func waitForInstanceReady(t *testing.T, instID string) {
	t.Helper()
	if !testutil.WaitForHealth(server.URL+"/instances/"+instID, 15*1e9) {
		t.Logf("warning: instance %s did not become ready within 15 seconds", instID)
	}
}

// Backward-compatible wrappers — delegate to testutil.Client.
// Existing tests use these package-level functions; new tests should use client.* directly.

func httpGet(t *testing.T, path string) (int, []byte)     { return client.Get(t, path) }
func httpPost(t *testing.T, path string, p any) (int, []byte) { return client.Post(t, path, p) }
func httpPostRaw(t *testing.T, path string, b string) (int, []byte) { return client.PostRaw(t, path, b) }
func httpPostWithRetry(t *testing.T, path string, body any, retries int) (int, []byte) {
	return client.PostWithRetry(t, path, body, retries)
}
func jsonField(t *testing.T, data []byte, key string) string { return testutil.JSONField(t, data, key) }
func findRepoRoot() string                                     { return testutil.FindRepoRoot() }
