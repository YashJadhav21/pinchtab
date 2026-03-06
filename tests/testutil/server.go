// Package testutil provides shared helpers for integration tests.
package testutil

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Timeout constants for integration test operations.
const (
	HealthTimeout   = 30 * time.Second
	HealthTimeoutCI = 60 * time.Second
	ShutdownTimeout = 10 * time.Second
	InstanceTimeout = 30 * time.Second
)

// ServerConfig holds configuration for a test server instance.
type ServerConfig struct {
	Port    string // Server port (default: "19867")
	Headless bool   // Run Chrome headless (default: true)
	Stealth  string // Stealth level (default: "light")
}

// DefaultConfig returns a ServerConfig with sensible test defaults.
func DefaultConfig() ServerConfig {
	port := os.Getenv("PINCHTAB_TEST_PORT")
	if port == "" {
		port = "19867"
	}
	return ServerConfig{
		Port:     port,
		Headless: true,
		Stealth:  "light",
	}
}

// Server represents a running pinchtab test server with managed temp dirs.
type Server struct {
	URL        string
	Dir        string // Root temp dir containing binary, state, profiles
	BinaryPath string
	StateDir   string
	ProfileDir string
	cmd        *exec.Cmd
}

// StartServer builds, launches, and waits for a pinchtab server.
// The caller must call server.Stop() to shut down and clean up.
func StartServer(cfg ServerConfig) (*Server, error) {
	testDir, err := os.MkdirTemp("", "pinchtab-test-*")
	if err != nil {
		return nil, fmt.Errorf("create test dir: %w", err)
	}
	fmt.Fprintf(os.Stderr, "testutil: test dir: %s\n", testDir)

	s := &Server{
		URL:        fmt.Sprintf("http://localhost:%s", cfg.Port),
		Dir:        testDir,
		BinaryPath: filepath.Join(testDir, "pinchtab"),
		StateDir:   filepath.Join(testDir, "state"),
		ProfileDir: filepath.Join(testDir, "profiles"),
	}

	for _, d := range []string{s.StateDir, s.ProfileDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			s.Cleanup()
			return nil, fmt.Errorf("create %s: %w", d, err)
		}
	}

	// Build binary
	build := exec.Command("go", "build", "-o", s.BinaryPath, "./cmd/pinchtab/")
	build.Dir = FindRepoRoot()
	build.Stdout = os.Stdout
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		s.Cleanup()
		return nil, fmt.Errorf("build pinchtab: %w", err)
	}

	// Prepare environment — strip existing BRIDGE_*/PINCHTAB_* to avoid conflicts
	env := filterEnv(os.Environ(), "BRIDGE_", "PINCHTAB_")
	env = append(env,
		"PINCHTAB_PORT="+cfg.Port,
		"PINCHTAB_HEADLESS="+boolStr(cfg.Headless),
		"PINCHTAB_NO_RESTORE=true",
		"PINCHTAB_STEALTH="+cfg.Stealth,
		"PINCHTAB_STATE_DIR="+s.StateDir,
		"PINCHTAB_PROFILE_DIR="+s.ProfileDir,
	)
	if bin := os.Getenv("CHROME_BINARY"); bin != "" {
		env = append(env, "CHROME_BINARY="+bin)
	}

	// Start in its own process group for clean shutdown
	s.cmd = exec.Command(s.BinaryPath)
	s.cmd.Env = env
	s.cmd.Stdout = os.Stdout
	s.cmd.Stderr = os.Stderr
	s.cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	if err := s.cmd.Start(); err != nil {
		s.Cleanup()
		return nil, fmt.Errorf("start pinchtab: %w", err)
	}

	// Wait for health
	timeout := HealthTimeout
	if os.Getenv("CI") == "true" {
		timeout = HealthTimeoutCI
	}
	if !WaitForHealth(s.URL, timeout) {
		s.Stop()
		return nil, fmt.Errorf("pinchtab did not become healthy within %v", timeout)
	}

	return s, nil
}

// Stop gracefully shuts down the server and cleans up all temp files.
func (s *Server) Stop() {
	if s.cmd != nil && s.cmd.Process != nil {
		TerminateProcessGroup(s.cmd, ShutdownTimeout)
	}
	s.Cleanup()
}

// Cleanup removes the test directory. Respects PINCHTAB_TEST_KEEP_DIR.
func (s *Server) Cleanup() {
	if os.Getenv("PINCHTAB_TEST_KEEP_DIR") != "" {
		fmt.Fprintf(os.Stderr, "testutil: keeping test dir (PINCHTAB_TEST_KEEP_DIR set): %s\n", s.Dir)
		return
	}
	os.RemoveAll(s.Dir)
}

// TerminateProcessGroup sends SIGTERM to the process group, then SIGKILL on timeout.
func TerminateProcessGroup(cmd *exec.Cmd, timeout time.Duration) {
	if cmd.Process == nil {
		return
	}

	// Try graceful group shutdown
	if pgid, err := syscall.Getpgid(cmd.Process.Pid); err == nil {
		_ = syscall.Kill(-pgid, syscall.SIGTERM)
	} else {
		_ = cmd.Process.Signal(os.Interrupt)
	}

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()

	select {
	case <-done:
		return
	case <-time.After(timeout):
		// Force kill the entire process group
		if pgid, err := syscall.Getpgid(cmd.Process.Pid); err == nil {
			_ = syscall.Kill(-pgid, syscall.SIGKILL)
		}
		_ = cmd.Process.Kill()
		<-done
	}
}

// WaitForHealth polls the /health endpoint until it returns 200 or the timeout expires.
func WaitForHealth(base string, timeout time.Duration) bool {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	for {
		select {
		case <-ctx.Done():
			return false
		default:
		}

		req, err := http.NewRequestWithContext(ctx, "GET", base+"/health", nil)
		if err != nil {
			continue
		}
		resp, err := http.DefaultClient.Do(req)
		if err == nil {
			healthy := resp.StatusCode == 200
			_ = resp.Body.Close()
			if healthy {
				return true
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// FindRepoRoot walks up from the current directory to find go.mod.
func FindRepoRoot() string {
	dir, _ := os.Getwd()
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return filepath.Join("..", "..")
}

// LaunchInstance creates and waits for a test instance to be ready.
func LaunchInstance(base string) (string, error) {
	resp, err := http.Post(
		base+"/instances/launch",
		"application/json",
		strings.NewReader(`{"mode":"headless"}`),
	)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close() //nolint:errcheck

	if resp.StatusCode != 201 && resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("launch failed with status %d: %s", resp.StatusCode, string(body))
	}

	var result map[string]any
	body, _ := io.ReadAll(resp.Body)
	if err := json.Unmarshal(body, &result); err != nil {
		return "", fmt.Errorf("parse launch response: %w", err)
	}

	id, ok := result["id"].(string)
	if !ok {
		return "", fmt.Errorf("no instance id in launch response: %v", result)
	}

	fmt.Fprintf(os.Stderr, "testutil: launched instance %s\n", id)

	// Wait for instance readiness
	ctx, cancel := context.WithTimeout(context.Background(), InstanceTimeout)
	defer cancel()

	for {
		select {
		case <-ctx.Done():
			return "", fmt.Errorf("instance %s did not become ready within %v", id, InstanceTimeout)
		default:
		}

		openResp, err := http.Post(
			base+"/instances/"+id+"/tabs/open",
			"application/json",
			strings.NewReader(`{"url":"about:blank"}`),
		)
		if err != nil {
			time.Sleep(500 * time.Millisecond)
			continue
		}

		var tabID string
		if openResp.StatusCode == 200 {
			openBody, _ := io.ReadAll(openResp.Body)
			var open map[string]any
			if err := json.Unmarshal(openBody, &open); err == nil {
				if v, ok := open["tabId"].(string); ok {
					tabID = v
				}
			}
		}
		_ = openResp.Body.Close()

		if tabID == "" {
			time.Sleep(500 * time.Millisecond)
			continue
		}

		navResp, err := http.Post(
			base+"/tabs/"+tabID+"/navigate",
			"application/json",
			strings.NewReader(`{"url":"about:blank"}`),
		)
		if err != nil {
			time.Sleep(500 * time.Millisecond)
			continue
		}
		status := navResp.StatusCode
		_ = navResp.Body.Close()

		if status == 200 {
			fmt.Fprintf(os.Stderr, "testutil: instance %s is ready\n", id)
			return id, nil
		}
		time.Sleep(500 * time.Millisecond)
	}
}

func filterEnv(env []string, prefixes ...string) []string {
	out := make([]string, 0, len(env))
	for _, e := range env {
		skip := false
		for _, p := range prefixes {
			if strings.HasPrefix(e, p) {
				skip = true
				break
			}
		}
		if !skip {
			out = append(out, e)
		}
	}
	return out
}

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}
