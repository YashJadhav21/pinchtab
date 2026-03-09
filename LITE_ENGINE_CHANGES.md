# Lite Engine: Chrome-Free DOM Capture using Gost-DOM

**Branch:** `feat/lite-engine-gostdom`  
**Issue:** [#201](https://github.com/pinchtab/pinchtab/issues/201)  
**Related Draft PR:** [#200](https://github.com/pinchtab/pinchtab/pull/200)  
**Dependency:** [gost-dom/browser v0.11.0](https://github.com/gost-dom/browser) (MIT, ~255 stars, Go 78.4%)

---

## Overview

This implementation adds a **Lite Engine** that can perform DOM capture (navigate, snapshot, text extraction, click, type) without requiring Chrome/Chromium. It uses [Gost-DOM](https://github.com/gost-dom/browser), a headless browser written in pure Go, to parse and traverse HTML documents.

The architecture follows the maintainer's guidance for **"clever routing that is expandable without touching the rest of the code"** — implemented via a strategy-pattern Router with pluggable rules.

## Architecture

### Engine Interface (`internal/engine/engine.go`)

```go
type Engine interface {
    Name() string
    Navigate(ctx context.Context, url string) (*NavigateResult, error)
    Snapshot(ctx context.Context, filter string) ([]SnapshotNode, error)
    Text(ctx context.Context) (string, error)
    Click(ctx context.Context, ref string) error
    Type(ctx context.Context, ref, text string) error
    Capabilities() []Capability
    Close() error
}
```

### Router (`internal/engine/router.go`)

The Router evaluates an ordered chain of `RouteRule` implementations. The first rule to return a non-`Undecided` verdict wins.

```
Request → Router → [Rule 1] → [Rule 2] → ... → [Fallback Rule] → Engine
```

Rules are hot-swappable at runtime via `AddRule()` / `RemoveRule()` — no handler code changes needed.

### Three Modes

| Mode | Behavior | Default Rules |
|------|----------|---------------|
| `chrome` | All requests → Chrome (default, backward compatible) | DefaultChromeRule |
| `lite` | DOM ops → Gost-DOM, screenshots/PDF/evaluate → Chrome | CapabilityRule → DefaultLiteRule |
| `auto` | Per-request routing based on URL patterns | CapabilityRule → ContentHintRule → DefaultChromeRule |

### Built-in Rules (`internal/engine/rules.go`)

| Rule | Purpose |
|------|---------|
| `CapabilityRule` | Routes screenshot/pdf/evaluate/cookies → Chrome (lite can't do these) |
| `ContentHintRule` | Routes `.html/.htm/.xml/.txt/.md` URLs → Lite (for navigate/snapshot/text) |
| `DefaultLiteRule` | Catch-all: routes all DOM ops → Lite |
| `DefaultChromeRule` | Final fallback: routes everything → Chrome |

### Expandability

Adding new routing logic requires only:
1. Implement `RouteRule` interface (2 methods: `Name()`, `Decide()`)
2. Call `router.AddRule(myRule)` — inserted before the fallback rule

No handler, config, or CMD changes needed.

## Files Changed

### New Files (8)
| File | Purpose | Lines |
|------|---------|-------|
| `internal/engine/engine.go` | Engine interface, types, capabilities | ~70 |
| `internal/engine/lite.go` | LiteEngine implementation using Gost-DOM | ~430 |
| `internal/engine/router.go` | Router with AddRule/RemoveRule | ~120 |
| `internal/engine/rules.go` | 4 built-in RouteRule implementations | ~95 |
| `internal/engine/lite_test.go` | LiteEngine unit tests | ~280 |
| `internal/engine/router_test.go` | Router unit tests | ~130 |
| `internal/engine/rules_test.go` | Rule unit tests | ~115 |
| `internal/engine/realworld_test.go` | Real-world website comparison tests | ~570 |

### Modified Files (8)
| File | Change |
|------|--------|
| `internal/config/config.go` | Added `Engine` field to RuntimeConfig + ServerConfig, `PINCHTAB_ENGINE` env var |
| `internal/handlers/handlers.go` | Added `Router *engine.Router` field, `useLite()` helper |
| `internal/handlers/navigation.go` | Lite fast path before ensureChrome |
| `internal/handlers/snapshot.go` | Lite fast path with SnapshotNode → A11yNode conversion |
| `internal/handlers/text.go` | Lite fast path returning plain text |
| `cmd/pinchtab/cmd_bridge.go` | Engine router wiring based on config mode |
| `go.mod` | Added gost-dom/browser v0.11.0, gost-dom/css v0.1.0 |
| `go.sum` | Updated checksums |

## Improvements Over PR #200 Draft

| Area | PR #200 | This Implementation |
|------|---------|-------------------|
| Tab management | Single window | Multi-tab with sequential IDs |
| HTML parsing | `browser.Open()` double-fetches | HTTP fetch → strip scripts → `html.NewWindowReader` |
| Script handling | Panics on `<script>` tags | Pre-parse stripping via `x/net/html` tokenizer |
| Click safety | No panic protection | `defer recover()` in Click method |
| Text output | Raw DOM text | `normalizeWhitespace()` — collapses runs of whitespace |
| Role mapping | Basic (a, button, input, etc.) | Extended: section→region, details→group, summary→button, dialog, article |
| Interactive detection | Basic tags | Adds summary, ARIA roles (tab, menuitem, switch) |
| Routing | None (always lite) | Strategy-pattern Router with pluggable rules |
| Configuration | None | `PINCHTAB_ENGINE` env var, config file support |

## Test Results

### Engine Package Tests (40+ tests, all passing)

```
=== Unit Tests ===
TestLiteEngine_Navigate          PASS
TestLiteEngine_Snapshot_All      PASS
TestLiteEngine_Snapshot_Interactive  PASS
TestLiteEngine_Text              PASS
TestLiteEngine_Click             PASS
TestLiteEngine_Type              PASS
TestLiteEngine_RefNotFound       PASS
TestLiteEngine_ScriptStyleSkipped  PASS
TestLiteEngine_AriaAttributes    PASS
TestLiteEngine_MultiTab          PASS
TestLiteEngine_Close             PASS
TestLiteEngine_Capabilities      PASS
TestLiteEngine_Name              PASS
TestNormalizeWhitespace          PASS

=== Router Tests ===
TestRouterChromeMode             PASS
TestRouterLiteMode               PASS
TestRouterAutoModeStaticContent  PASS
TestRouterAutoModeLiteNil        PASS
TestRouterAddRemoveRule          PASS
TestRouterRulesSnapshot          PASS

=== Rule Tests ===
TestCapabilityRule (9 cases)     PASS
TestContentHintRule (9 cases)    PASS
TestDefaultLiteRule (7 cases)    PASS
TestDefaultChromeRule (4 cases)  PASS
```

### Real-World Website Comparison Tests (16 suites, 63+ subtests)

| Suite | Simulates | Subtests | Result |
|-------|-----------|----------|--------|
| WikipediaStyle | Wikipedia article page | 9 | PASS |
| HackerNewsStyle | HN front page | 4 | PASS |
| EcommerceStyle | Product page with forms | 9 | PASS |
| FormHeavy | Registration form | 7 | PASS |
| AriaHeavy | Dashboard with ARIA roles | 11 | PASS |
| DeeplyNested | 5+ levels of div nesting | 4 | PASS |
| SpecialCharacters | Unicode, HTML entities, CJK | 3 | PASS |
| EmptyPage | Empty HTML body | 1 | PASS |
| NonHTMLContentType | JSON response | 1 | PASS |
| HTTP404 | 404 error page | 1 | PASS |
| LargePagePerformance | 200 sections, 800+ nodes | 1 | PASS |
| MultipleScriptTags | 5 script tags in head+body | 1 | PASS |
| InlineStyles | Style tags in head+body | 1 | PASS |
| ClickWorkflow | Button clicks | 1 | PASS |
| ClickLinkRecovery | Anchor click panic recovery | 1 | PASS |
| TypeWorkflow | Type into all textboxes | 1 | PASS |

### Full Project Test Suite

```
ok   cmd/pinchtab           2.8s
ok   internal/allocation    2.0s
ok   internal/config        1.6s
ok   internal/dashboard     3.1s
ok   internal/engine        1.4s   ← new package
ok   internal/handlers      6.8s
ok   internal/human         10.7s
ok   internal/idpi          2.0s
ok   internal/idutil        1.8s
ok   internal/instance      2.6s
ok   internal/orchestrator  3.2s
ok   internal/profiles      2.8s
ok   internal/proxy         2.8s
ok   internal/scheduler     4.0s
ok   internal/semantic      1.6s
ok   internal/strategy      1.7s
ok   internal/uameta        1.1s
ok   internal/web           1.5s
```

## Known Edge Cases & Limitations

| Edge Case | Behavior | Mitigation |
|-----------|----------|------------|
| `<script>` tags in HTML | Gost-DOM panics (nil ScriptHost) | Pre-parse stripping via x/net/html tokenizer |
| Click on `<a href>` | Gost-DOM navigates, may encounter scripts | `defer recover()` in Click, returns error |
| CSS `display:none` | Elements still appear in snapshot | Lite engine has no CSS engine |
| JavaScript-rendered content | Not captured (SPA, dynamic DOM) | Falls back to Chrome in auto mode |
| Screenshots / PDF | Not supported in lite | CapabilityRule routes to Chrome |
| Cookies / Evaluate | Not supported in lite | CapabilityRule routes to Chrome |
| `<noscript>` content | Stripped from snapshot | Consistent with script-disabled behavior |

## Configuration

### Environment Variable
```bash
PINCHTAB_ENGINE=lite    # or "chrome" (default) or "auto"
```

### Config File
```json
{
  "server": {
    "engine": "lite"
  }
}
```

### Response Headers
Lite-served responses include `X-Engine: lite` header for observability.

## Dependency Analysis

| Package | Size | License | Purpose |
|---------|------|---------|---------|
| gost-dom/browser v0.11.0 | ~2.5MB source | MIT | Headless browser (HTML parsing, DOM traversal) |
| gost-dom/css v0.1.0 | ~200KB | MIT | CSS selector support |
| golang.org/x/net (existing) | already in go.mod | BSD-3 | HTML tokenizer for script stripping |
