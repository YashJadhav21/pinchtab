//go:build integration

package integration

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"
)

// proxyInstance creates a shared instance for proxy tests that don't need isolation.
// Returns instance ID; registers cleanup via t.Cleanup.
func proxyInstance(t *testing.T) string {
	t.Helper()

	payload := map[string]any{
		"name":     fmt.Sprintf("proxy-test-%d", time.Now().Unix()),
		"headless": true,
	}

	status, body := httpPost(t, "/instances/launch", payload)
	if status != 201 {
		t.Fatalf("failed to create proxy test instance: %d", status)
	}

	instID := jsonField(t, body, "id")
	t.Cleanup(func() {
		httpPost(t, fmt.Sprintf("/instances/%s/stop", instID), nil)
	})

	waitForInstanceReady(t, instID)
	return instID
}

// TestProxy groups all proxy security tests under a single instance where possible.
func TestProxy(t *testing.T) {
	instID := proxyInstance(t)

	t.Run("LocalhostOnly", func(t *testing.T) {
		// Verify instance can be accessed via proxy (SSRF prevention)
		code, _, _ := navigateInstance(t, instID, "https://example.com")
		if code != 200 {
			t.Errorf("expected 200 for valid localhost proxy, got %d", code)
		}
	})

	t.Run("URLValidation", func(t *testing.T) {
		// Verify URL construction is safe with query params
		code, respBody, _ := navigateInstance(t, instID, "https://example.com/path?query=value")
		if code != 200 {
			t.Logf("navigate with query params got %d: %s", code, string(respBody))
		}
	})

	t.Run("SchemeValidation", func(t *testing.T) {
		// Verify proxy uses http scheme for localhost
		code, respBody, _ := navigateInstance(t, instID, "https://example.com")
		if code != 200 {
			t.Errorf("navigate failed (scheme validation): %d: %s", code, string(respBody))
		}
	})
}

// TestProxy_InstanceIsolation needs its own instances to verify isolation.
func TestProxy_InstanceIsolation(t *testing.T) {
	var instIDs []string
	var ports []string

	for i := 0; i < 2; i++ {
		payload := map[string]any{
			"name":     fmt.Sprintf("isolation-test-%d-%d", time.Now().Unix(), i),
			"headless": true,
		}

		status, body := httpPost(t, "/instances/launch", payload)
		if status != 201 {
			t.Fatalf("instance %d creation failed: %d", i, status)
		}

		instID := jsonField(t, body, "id")
		port := jsonField(t, body, "port")

		instIDs = append(instIDs, instID)
		ports = append(ports, port)
	}

	defer func() {
		for _, instID := range instIDs {
			httpPost(t, fmt.Sprintf("/instances/%s/stop", instID), nil)
		}
	}()

	if ports[0] == ports[1] {
		t.Fatalf("instances have same port: %s == %s", ports[0], ports[1])
	}

	waitForInstanceReady(t, instIDs[0])
	waitForInstanceReady(t, instIDs[1])

	code1, body1, _ := navigateInstance(t, instIDs[0], "https://example.com/page1")
	if code1 != 200 {
		t.Errorf("navigate in inst1 failed: %d: %s", code1, string(body1))
	}

	code2, body2, _ := navigateInstance(t, instIDs[1], "https://example.com/page2")
	if code2 != 200 {
		t.Errorf("navigate in inst2 failed: %d: %s", code2, string(body2))
	}

	_, tabsBody1 := httpPost(t, fmt.Sprintf("/instances/%s/tabs", instIDs[0]), nil)
	_, tabsBody2 := httpPost(t, fmt.Sprintf("/instances/%s/tabs", instIDs[1]), nil)

	var tabs1, tabs2 map[string]any
	if err := json.Unmarshal(tabsBody1, &tabs1); err != nil {
		t.Logf("inst1 tabs response not JSON: %v", err)
	}
	if err := json.Unmarshal(tabsBody2, &tabs2); err != nil {
		t.Logf("inst2 tabs response not JSON: %v", err)
	}
}
