package bridge

import (
	"context"
	"fmt"
	"log/slog"
	"runtime"
	"sync"
	"time"
)

// TabExecutor provides safe parallel execution across tabs.
//
// Each tab executes tasks sequentially (one at a time), but multiple tabs
// can execute concurrently up to a configurable limit. This prevents
// resource exhaustion on constrained devices (Raspberry Pi, low-memory
// servers) while enabling parallelism where hardware allows.
//
// Architecture:
//
//	Tab1 ─── sequential actions ───►
//	Tab2 ─── sequential actions ───►  (concurrent across tabs)
//	Tab3 ─── sequential actions ───►
type TabExecutor struct {
	semaphore   chan struct{}    // limits concurrent tab executions
	tabLocks    map[string]*sync.Mutex // per-tab sequential execution
	mu          sync.Mutex      // protects tabLocks map
	maxParallel int
}

// NewTabExecutor creates a TabExecutor with the given concurrency limit.
// If maxParallel <= 0, DefaultMaxParallel() is used.
func NewTabExecutor(maxParallel int) *TabExecutor {
	if maxParallel <= 0 {
		maxParallel = DefaultMaxParallel()
	}
	return &TabExecutor{
		semaphore:   make(chan struct{}, maxParallel),
		tabLocks:    make(map[string]*sync.Mutex),
		maxParallel: maxParallel,
	}
}

// DefaultMaxParallel returns a safe default based on available CPUs.
// Capped at 8 to prevent resource exhaustion on large machines.
func DefaultMaxParallel() int {
	n := runtime.NumCPU() * 2
	if n > 8 {
		n = 8
	}
	if n < 1 {
		n = 1
	}
	return n
}

// MaxParallel returns the configured concurrency limit.
func (te *TabExecutor) MaxParallel() int {
	return te.maxParallel
}

// tabMutex returns the per-tab mutex, creating one if needed.
func (te *TabExecutor) tabMutex(tabID string) *sync.Mutex {
	te.mu.Lock()
	defer te.mu.Unlock()
	m, ok := te.tabLocks[tabID]
	if !ok {
		m = &sync.Mutex{}
		te.tabLocks[tabID] = m
	}
	return m
}

// Execute runs a task for the given tab, ensuring:
//   - Only one task runs per tab at a time (per-tab sequential execution)
//   - At most maxParallel tabs execute concurrently (global semaphore)
//   - Panics inside the task are recovered and returned as errors
//   - Context cancellation/timeout is respected
//
// The task function receives the same context passed to Execute. Callers
// should use context.WithTimeout to bound execution time.
func (te *TabExecutor) Execute(ctx context.Context, tabID string, task func(ctx context.Context) error) error {
	if tabID == "" {
		return fmt.Errorf("tabID must not be empty")
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}

	// Acquire global semaphore (respect context cancellation)
	select {
	case te.semaphore <- struct{}{}:
		defer func() { <-te.semaphore }()
	case <-ctx.Done():
		return fmt.Errorf("tab %s: waiting for execution slot: %w", tabID, ctx.Err())
	}

	// Acquire per-tab lock for sequential execution within a tab
	tabMu := te.tabMutex(tabID)
	locked := make(chan struct{})
	go func() {
		tabMu.Lock()
		close(locked)
	}()

	select {
	case <-locked:
		defer tabMu.Unlock()
	case <-ctx.Done():
		// If we timed out waiting for the per-tab lock, we need to clean up.
		// Launch a goroutine to wait for the lock and immediately release it.
		go func() {
			<-locked
			tabMu.Unlock()
		}()
		return fmt.Errorf("tab %s: waiting for tab lock: %w", tabID, ctx.Err())
	}

	// Execute the task with panic recovery
	return te.safeRun(ctx, tabID, task)
}

// safeRun executes the task with panic recovery.
func (te *TabExecutor) safeRun(ctx context.Context, tabID string, task func(ctx context.Context) error) (err error) {
	defer func() {
		if r := recover(); r != nil {
			slog.Error("panic recovered in tab execution",
				"tabId", tabID,
				"panic", fmt.Sprintf("%v", r),
			)
			err = fmt.Errorf("tab %s: panic: %v", tabID, r)
		}
	}()
	return task(ctx)
}

// RemoveTab cleans up the per-tab mutex when a tab is closed.
// It deletes the entry from the map first, then acquires the old mutex
// to wait for any in-flight task to complete before returning.
//
// Note: after deletion, a concurrent Execute call for the same tabID
// will create a fresh mutex via tabMutex(). This is intentional — the
// old tab is being removed and a new tab with the same ID should start
// with a clean slate. Callers (CloseTab, CleanStaleTabs) ensure the
// tab context is cancelled before calling RemoveTab, so in-flight tasks
// will exit promptly.
func (te *TabExecutor) RemoveTab(tabID string) {
	te.mu.Lock()
	m, ok := te.tabLocks[tabID]
	if !ok {
		te.mu.Unlock()
		return
	}
	delete(te.tabLocks, tabID)
	te.mu.Unlock()

	// Wait for any in-flight task to finish, then release.
	m.Lock()
	m.Unlock()
}

// ActiveTabs returns the number of tabs that have associated mutexes.
func (te *TabExecutor) ActiveTabs() int {
	te.mu.Lock()
	defer te.mu.Unlock()
	return len(te.tabLocks)
}

// Stats returns execution statistics.
type ExecutorStats struct {
	MaxParallel   int `json:"maxParallel"`
	ActiveTabs    int `json:"activeTabs"`
	SemaphoreUsed int `json:"semaphoreUsed"`
	SemaphoreFree int `json:"semaphoreFree"`
}

func (te *TabExecutor) Stats() ExecutorStats {
	used := len(te.semaphore)
	return ExecutorStats{
		MaxParallel:   te.maxParallel,
		ActiveTabs:    te.ActiveTabs(),
		SemaphoreUsed: used,
		SemaphoreFree: te.maxParallel - used,
	}
}

// ExecuteWithTimeout is a convenience wrapper that creates a timeout context.
func (te *TabExecutor) ExecuteWithTimeout(ctx context.Context, tabID string, timeout time.Duration, task func(ctx context.Context) error) error {
	tCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	return te.Execute(tCtx, tabID, task)
}
