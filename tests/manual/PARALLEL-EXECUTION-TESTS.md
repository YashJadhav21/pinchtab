# Parallel Tab Execution - Manual Test Suite

## Overview

This directory contains automated test scripts for validating PinchTab's parallel tab execution feature. The tests verify concurrent behavior, isolation, resource limits, and failure handling.

## Status of Tests in Documentation

The tests described in [`docs/parallel-tab-execution.md`](../../docs/parallel-tab-execution.md) are **aspirational scenarios** - they describe expected behavior but were not originally automated. This test suite (`test-parallel-execution.ps1`) implements automated versions of those scenarios.

## Test Suite

### `test-parallel-execution.ps1`

Automated PowerShell script that tests parallel execution by:
- Starting PinchTab with custom configuration
- Making concurrent HTTP requests to the API
- Verifying isolation, ordering, and failure handling
- Measuring performance

**Tests included:**
1. **Parallel Search Engines** - 3 tabs navigate concurrently to different search engines
2. **Resource Limit Enforcement** - 5 tabs with `maxParallel=2` (verifies semaphore queuing)
3. **Same Tab Sequential Ordering** - 3 concurrent actions on same tab execute sequentially
4. **Failure Isolation** - One tab's failure doesn't affect others

## Prerequisites

- **PinchTab must NOT be running** (the script starts it with custom config)
- **Chrome/Chromium** installed
- **Internet access** for live website tests
- **PowerShell 5.1+** (Windows) or PowerShell Core 7+ (cross-platform)

## Usage

### Run all tests:
```powershell
.\tests\manual\test-parallel-execution.ps1
```

### Run specific test:
```powershell
.\tests\manual\test-parallel-execution.ps1 -TestName "Test1-ParallelSearchEngines"
```

### Skip slow tests (faster, but less coverage):
```powershell
.\tests\manual\test-parallel-execution.ps1 -SkipSlow
```

### Stop on first failure:
```powershell
.\tests\manual\test-parallel-execution.ps1 -FailFast
```

### Verbose output (for debugging):
```powershell
.\tests\manual\test-parallel-execution.ps1 -Verbose
```

### Custom port:
```powershell
.\tests\manual\test-parallel-execution.ps1 -Port 9868
```

## Expected Output

```
╔════════════════════════════════════════════════════════════════╗
║  PinchTab Parallel Tab Execution - Manual Test Suite          ║
╚════════════════════════════════════════════════════════════════╝

  → Starting PinchTab server...
  ✓ PinchTab server started (PID: 12345)

============================================================
  Test 1 - Parallel Search Engines
============================================================
  → Creating 3 tabs...
  → Navigating to search engines concurrently...
  ✓ All 3 tabs navigated successfully in 4.2s
  ✓ All tabs have different URLs (isolated)

============================================================
  Test 2 - Resource Limit Enforcement
============================================================
  → Testing with maxParallel=2...
  → Creating 5 tabs...
  → Navigating 5 tabs concurrently (should queue 3 of them)...
  ✓ All 5 navigations completed in 8.5s (with maxParallel=2 limits)
  ✓ All 5 tabs successfully navigated despite limit

============================================================
  Test 3 - Same Tab Sequential Ordering
============================================================
  → Creating tab and navigating to test page...
  → Sending 3 concurrent actions to same tab...
  ✓ All 3 sequential actions on same tab succeeded
  ✓ Actions took 3.2s (sequential as expected)

============================================================
  Test 4 - Failure Isolation
============================================================
  → Creating 3 tabs...
  → Navigating: 2 valid URLs + 1 invalid URL...
  ✓ Tab1 and Tab3 succeeded despite Tab2 failure (isolation working)
  ✓ Tab2 correctly failed with invalid URL

╔════════════════════════════════════════════════════════════════╗
║  Test Summary                                                  ║
╚════════════════════════════════════════════════════════════════╝
  Passed:  10
  Failed:  0
  Skipped: 0

✅ All tests passed!
```

## Comparison with Documentation

### Documentation Tests vs. Automated Tests

| Documentation Test | Automated? | Notes |
|-------------------|------------|-------|
| Test 1 - Parallel Search Engines | ✅ Yes | Simplified version (navigate only, no find/action) |
| Test 2 - Ecommerce Scraping | ❌ No | Complex semantic find + action chains (future work) |
| Test 3 - Login Forms | ❌ No | Requires form interaction automation (future work) |
| Test 4 - Dynamic SPAs | ❌ No | Requires scroll + snapshot verification (future work) |
| Test 5 - Navigation Stress (10 tabs) | ✅ Partial | Automated as Test 2 with 5 tabs |
| Test 6 - Resource Limits | ✅ Yes | Automated as Test 2 |
| Test 7 - Same Tab Lock | ✅ Yes | Automated as Test 3 |
| Test 8 - Failure Isolation | ✅ Yes | Automated as Test 4 |

## Limitations

These automated tests verify:
- ✅ Concurrent navigation works
- ✅ Resource limits are enforced
- ✅ Same-tab actions are sequential
- ✅ Failures are isolated

These tests do **NOT** verify (requires more complex setup):
- ❌ Exact log timestamps (documentation shows millisecond-precise ordering)
- ❌ Search engine interactions (find input, type query, submit)
- ❌ E-commerce scraping (semantic find, product extraction)
- ❌ Form filling across tabs
- ❌ Dynamic content loading (scroll + snapshot verification)

## Future Work

To fully automate all documentation scenarios:

1. **Add semantic find/action chains** - implement Test 1 with actual search queries
2. **Add form interaction tests** - automate Test 3 (login forms)
3. **Add scroll + snapshot verification** - automate Test 4 (SPAs)
4. **Add stress tests** - scale up to 10+ tabs (Test 5)
5. **Add log analysis** - verify timestamp ordering and concurrency in logs

## Integration Tests

For more comprehensive integration tests (without manual execution), see:
- [`tests/integration/`](../integration/) - Go-based integration tests with testcontainers
- Run with: `go test ./tests/integration/...`

## Troubleshooting

### "PinchTab already running"
Stop any existing PinchTab instances:
```powershell
Get-Process pinchtab | Stop-Process
```

### "PinchTab executable not found"
Build PinchTab first:
```powershell
go build -o pinchtab.exe ./cmd/pinchtab
```

### "Navigation timeout"
Increase timeout or check internet connection:
```powershell
# Edit test-parallel-execution.ps1, increase TimeoutSec in Invoke-Api calls
```

### Tests fail intermittently
This is expected for live website tests. Retry or use `-SkipSlow` for more reliable tests.

## Contributing

To add more test scenarios:
1. Add a new function `TestN-YourTestName` to `test-parallel-execution.ps1`
2. Add it to the main execution block
3. Update this README with the new test description
4. Submit a PR!
