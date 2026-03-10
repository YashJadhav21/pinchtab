# Lightpanda Engine Integration

## Overview

PinchTab now supports **Lightpanda** as a third engine option alongside Chrome and
the Lite (Gost-DOM) engine. Lightpanda is a standalone Zig-based browser binary that
exposes the Chrome DevTools Protocol (CDP) over WebSocket, enabling lightweight
headless browsing with full JavaScript support.

### Engine Comparison

| Feature          | Chrome          | Lite (Gost-DOM)        | Lightpanda           |
|------------------|-----------------|------------------------|----------------------|
| **Runtime**      | Full browser    | Go HTTP + DOM parsing  | Zig binary + CDP     |
| **JavaScript**   | Full V8         | None                   | Yes                  |
| **Protocol**     | CDP             | None (in-process)      | CDP over WebSocket   |
| **Subprocess**   | Yes             | No                     | Yes (managed)        |
| **Memory**       | High            | Low                    | Low–Medium           |
| **Capabilities** | All             | Navigate/Snapshot/Text/Click/Type | Navigate/Snapshot/Text/Click/Type |
| **Screenshot/PDF** | Yes           | No (501)               | No (501)             |

## Architecture

```
┌─────────────────────────┐
│      HTTP Handlers      │
│  (navigation, snapshot, │
│   text, actions)        │
└────────┬────────────────┘
         │ altEngine()
         ▼
┌─────────────────────────┐
│        Router           │
│  ┌───────────────────┐  │
│  │   RouteRules[]    │  │
│  │ CapabilityRule    │  │
│  │ DefaultLP/Lite/   │  │
│  │ ChromeRule        │  │
│  └───────────────────┘  │
│                         │
│  lite Engine ──► LiteEngine (Gost-DOM)
│  lightpanda Engine ──► LightpandaEngine (CDP)
│  nil ──► Chrome (Bridge)│
└─────────────────────────┘
```

### LightpandaEngine

The engine manages a Lightpanda subprocess and communicates via CDP:

1. **Startup**: Finds a free port, launches `lightpanda --cd-port <port>`
2. **Connection**: Uses `chromedp.NewRemoteAllocator` to connect to `ws://127.0.0.1:<port>`
3. **Operations**: All Engine interface methods (Navigate, Snapshot, Text, Click, Type)
   use CDP commands through chromedp
4. **Shutdown**: Sends SIGINT to subprocess, cleans up allocator contexts

## Configuration

### Environment Variable

```bash
# Use Lightpanda engine
PINCHTAB_ENGINE=lightpanda

# Specify custom binary path (optional)
LIGHTPANDA_BIN=/path/to/lightpanda
```

### Config File

```json
{
  "server": {
    "engine": "lightpanda"
  }
}
```

### Valid Engine Modes

| Mode          | Behavior                                       |
|---------------|------------------------------------------------|
| `chrome`      | Default — always uses Chrome via CDP           |
| `lite`        | Always uses Gost-DOM (no browser needed)       |
| `lightpanda`  | Always uses Lightpanda via CDP                 |
| `auto`        | Per-request routing via rule chain             |

## Binary Discovery

The engine looks for the Lightpanda binary in this order:

1. `LIGHTPANDA_BIN` environment variable
2. `lightpanda` in system PATH
3. Common installation paths:
   - Linux: `/usr/local/bin/lightpanda`, `/usr/bin/lightpanda`, `$HOME/.local/bin/lightpanda`
   - Windows: `C:\lightpanda\lightpanda.exe`, `C:\Program Files\lightpanda\lightpanda.exe`

If the binary is not found, the engine returns a clear error with download instructions.

## Installation

### Download Lightpanda

```bash
# Linux (x86_64)
curl -LO https://github.com/nicholasgasior/gsfn/releases/download/v0.2.0/gsfn-linux-amd64
chmod +x gsfn-linux-amd64
./gsfn-linux-amd64 lightpanda-io/browser

# Or build from source
git clone https://github.com/lightpanda-io/browser.git
cd browser
# Follow build instructions at https://github.com/lightpanda-io/browser
```

### Quick Start

```powershell
# Set engine mode
$env:PINCHTAB_ENGINE = "lightpanda"

# Optional: specify binary path
$env:LIGHTPANDA_BIN = "C:\path\to\lightpanda.exe"

# Start PinchTab
go run ./cmd/pinchtab bridge
```

## Files Changed

| File | Change |
|------|--------|
| `internal/engine/engine.go` | Added `ModeLightpanda`, `UseLightpanda` decision |
| `internal/engine/lightpanda.go` | **New** — LightpandaEngine implementation |
| `internal/engine/rules.go` | Added `DefaultLightpandaRule` |
| `internal/engine/router.go` | Extended Router with `lightpanda` field, `NewRouterWithEngines()`, `Lightpanda()` accessor |
| `internal/config/config.go` | Updated Engine comment to include "lightpanda" |
| `cmd/pinchtab/cmd_bridge.go` | Added `ModeLightpanda` wiring with fallback to chrome |
| `internal/handlers/handlers.go` | Added `altEngine()` method for generic engine dispatch |
| `internal/handlers/navigation.go` | Updated fast path to use `altEngine()` |
| `internal/handlers/snapshot.go` | Updated fast path to use `altEngine()` |
| `internal/handlers/text.go` | Updated fast path to use `altEngine()` |
| `internal/engine/lightpanda_test.go` | **New** — 16 unit tests |
| `tests/lightpanda_benchmark.ps1` | **New** — benchmark script with cross-engine comparison |

## Testing

### Unit Tests

```bash
# Run all engine tests (including Lightpanda)
go test ./internal/engine/... -v

# Run only Lightpanda tests
go test ./internal/engine/... -run "Lightpanda|DefaultLightpanda|RouterWithEngines"
```

### Test Results

```
=== RUN   TestLightpandaEngine_Name           --- PASS
=== RUN   TestLightpandaEngine_Capabilities   --- PASS
=== RUN   TestLightpandaEngine_SnapshotNoPage --- PASS
=== RUN   TestLightpandaEngine_TextNoPage     --- PASS
=== RUN   TestLightpandaEngine_ClickNoPage    --- PASS
=== RUN   TestLightpandaEngine_TypeNoPage     --- PASS
=== RUN   TestLightpandaEngine_CloseEmpty     --- PASS
=== RUN   TestFindLightpandaBinary_Empty      --- PASS
=== RUN   TestIsInteractiveRole               --- PASS
=== RUN   TestStripHTMLTags                   --- PASS
=== RUN   TestBuildSnapshotFromAXTree         --- PASS
=== RUN   TestBuildSnapshotFromAXTree_InteractiveFilter --- PASS
=== RUN   TestBuildSnapshotFromAXTree_SkipsNoneAndGeneric --- PASS
=== RUN   TestAxValueStr                      --- PASS
=== RUN   TestDefaultLightpandaRule           --- PASS
=== RUN   TestRouterLightpandaMode            --- PASS
=== RUN   TestRouterWithEngines_BackwardCompat --- PASS
=== RUN   TestWaitForCDP_Timeout              --- PASS
=== RUN   TestFindFreePortLP                  --- PASS
PASS — 0 regressions in existing 40+ tests
```

### Manual Benchmark

```powershell
# Start with lightpanda engine
$env:PINCHTAB_ENGINE = "lightpanda"
go run ./cmd/pinchtab bridge

# In another terminal
.\tests\lightpanda_benchmark.ps1
```

## Design Decisions

1. **Separate Engine, not Bridge modification**: Lightpanda implements the `Engine`
   interface (like Lite) rather than modifying the Bridge. This keeps the existing
   Chrome path untouched and follows the open-closed principle.

2. **Dynamic port allocation**: Uses `net.Listen("tcp", ":0")` to find a free port,
   avoiding conflicts with Chrome or other services.

3. **chromedp RemoteAllocator**: Connects to Lightpanda's CDP WebSocket using
   `chromedp.NewRemoteAllocator`, reusing the same CDP client library as Chrome.

4. **Generic handler dispatch**: Handlers now use `altEngine()` instead of
   `useLite()` for the fast path. This routes to whichever non-Chrome engine is
   active (lite or lightpanda) without duplicating handler code.

5. **Backward compatibility**: `NewRouter()` still works unchanged. The new
   `NewRouterWithEngines()` constructor is the extended version that accepts
   both lite and lightpanda engines.

6. **Graceful fallback**: If the Lightpanda binary isn't found at startup,
   `cmd_bridge.go` logs a warning and falls back to Chrome mode.

## Subprocess Lifecycle

```
Start:
  1. Find free TCP port
  2. Launch: lightpanda --cd-port <port>
  3. Set env: LIGHTPANDA_DISABLE_TELEMETRY=true
  4. Poll TCP until CDP endpoint accepts connections (10s timeout)
  5. Connect chromedp.NewRemoteAllocator(ws://127.0.0.1:<port>)

Close:
  1. Cancel all tab contexts
  2. Cancel allocator context
  3. Send os.Interrupt to subprocess
  4. Wait for process exit
```
