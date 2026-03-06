//go:build integration

package integration

import (
	"testing"
)

// Backward-compatible wrappers for tests using httpPatch/httpDelete.
// New tests should use client.Patch() / client.Delete() directly.

func httpPatch(t *testing.T, path string, payload any) (int, []byte) {
	return client.Patch(t, path, payload)
}

func httpDelete(t *testing.T, path string) (int, []byte) {
	return client.Delete(t, path)
}
