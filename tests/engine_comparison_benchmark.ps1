# ============================================================
# PinchTab 3-Engine Comparison Benchmark
# ============================================================
# Runs Navigate, Snapshot (all + interactive), and Text
# operations against real-world websites. Auto-detects the
# active engine from the X-Engine header and saves results.
# When result files for multiple engines exist, generates a
# side-by-side comparison table.
#
# Edge Cases Tested:
#   - Empty / minimal pages (example.com)
#   - JavaScript-heavy SPA-like pages (GitHub)
#   - Large content pages (Wikipedia)
#   - Pages with many interactive elements (DuckDuckGo, HN)
#   - Pages that may redirect (httpbin)
#   - Timeout-prone pages (Stack Overflow)
#   - Pages with complex DOM structure (Reddit)
#   - Error recovery: server 4xx/5xx responses
#   - Snapshot consistency: all vs interactive count check
#   - Text extraction: non-empty validation
#
# Usage (run once per engine mode):
#
#   # Chrome (default)
#   $env:PINCHTAB_ENGINE="chrome"; go run ./cmd/pinchtab bridge
#   .\tests\engine_comparison_benchmark.ps1
#
#   # Lite
#   $env:PINCHTAB_ENGINE="lite"; go run ./cmd/pinchtab bridge
#   .\tests\engine_comparison_benchmark.ps1
#
#   # Lightpanda (Docker)
#   $env:PINCHTAB_ENGINE="lightpanda"; go run ./cmd/pinchtab bridge
#   .\tests\engine_comparison_benchmark.ps1
#
#   The third run (or any run with 2+ result files) prints
#   a full cross-engine comparison.
#
# Parameters:
#   -Port     Server port (default 9867)
#   -Token    Bearer token for auth (default "")
#   -Clean    Remove old result files before running
# ============================================================

param(
    [string]$Port  = "9867",
    [string]$Token = "",
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
$Base = "http://localhost:$Port"
$Headers = @{ "Content-Type" = "application/json" }
if ($Token -ne "") {
    $Headers["Authorization"] = "Bearer $Token"
}

$ScriptDir = $PSScriptRoot
$ChromeResultsFile = Join-Path $ScriptDir "chrome_benchmark_results.json"
$LiteResultsFile   = Join-Path $ScriptDir "lite_benchmark_results.json"
$LpResultsFile     = Join-Path $ScriptDir "lightpanda_benchmark_results.json"

if ($Clean) {
    foreach ($f in @($ChromeResultsFile, $LiteResultsFile, $LpResultsFile)) {
        if (Test-Path $f) { Remove-Item $f -Force; Write-Host "Removed $f" -ForegroundColor DarkGray }
    }
}

# ============================================================
# Helper functions
# ============================================================

function Invoke-Api {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body = $null,
        [switch]$RawText
    )
    $uri = "$Base$Path"
    $params = @{
        Uri                = $uri
        Method             = $Method
        Headers            = $Headers
        UseBasicParsing    = $true
        ErrorAction        = "Stop"
        MaximumRedirection = 0
    }
    if ($Body) {
        $json = $Body | ConvertTo-Json -Depth 10
        $params["Body"] = $json
        $params["ContentType"] = "application/json"
    }
    try {
        $resp = Invoke-WebRequest @params
        $result = @{
            StatusCode = $resp.StatusCode
            Raw        = $resp.Content
            Headers    = $resp.Headers
        }
        if ($RawText) {
            $result["Body"] = $resp.Content
        } else {
            try { $result["Body"] = $resp.Content | ConvertFrom-Json } catch { $result["Body"] = $resp.Content }
        }
        return $result
    } catch {
        $status = 0
        $raw = $_.Exception.Message
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            try {
                $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                $raw = $reader.ReadToEnd()
                $reader.Close()
            } catch {}
        }
        return @{ StatusCode = $status; Raw = $raw; Body = $null; Headers = @{} }
    }
}

function Measure-ApiCall {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body = $null,
        [switch]$RawText
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($RawText) {
        $resp = Invoke-Api -Method $Method -Path $Path -Body $Body -RawText
    } else {
        $resp = Invoke-Api -Method $Method -Path $Path -Body $Body
    }
    $sw.Stop()
    $resp["ElapsedMs"] = $sw.ElapsedMilliseconds
    return $resp
}

# ============================================================
# Test websites — diverse set covering edge cases
# ============================================================
$Websites = @(
    # Simple / minimal page (baseline)
    @{ Name = "Example.com";       URL = "https://example.com";       Category = "minimal" },
    # Large content / many DOM nodes
    @{ Name = "Wikipedia (Go)";    URL = "https://en.wikipedia.org/wiki/Go_(programming_language)"; Category = "content-heavy" },
    # Hacker News — many links, simple HTML
    @{ Name = "Hacker News";       URL = "https://news.ycombinator.com"; Category = "link-heavy" },
    # API / minimal page with redirect potential
    @{ Name = "httpbin.org";       URL = "https://httpbin.org";       Category = "api-page" },
    # JS-heavy page with complex DOM
    @{ Name = "GitHub Explore";    URL = "https://github.com/explore"; Category = "js-heavy" },
    # Search engine — form with interactive elements
    @{ Name = "DuckDuckGo";       URL = "https://duckduckgo.com";     Category = "interactive" },
    # Another large content page
    @{ Name = "Wikipedia (CS)";    URL = "https://en.wikipedia.org/wiki/Computer_science"; Category = "content-heavy" },
    # High-traffic, potentially slow page
    @{ Name = "Stack Overflow";    URL = "https://stackoverflow.com/questions"; Category = "complex" }
)

# ============================================================
# PREFLIGHT: Server health check
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " PinchTab 3-Engine Comparison Benchmark"                      -ForegroundColor Cyan
Write-Host " Server: $Base"                                               -ForegroundColor Cyan
Write-Host " Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"       -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "--- Preflight: checking server health ---" -ForegroundColor Yellow
$serverAlive = $false
try {
    $health = Invoke-Api -Method GET -Path "/health"
    if ($health.StatusCode -eq 200) {
        Write-Host "[OK] Server is alive (health 200)" -ForegroundColor Green
        $serverAlive = $true
    }
} catch {}

if (-not $serverAlive) {
    # Health may return 503 when Chrome is unavailable (e.g. Lightpanda-only mode).
    # Verify the server is reachable by hitting /metrics which does not require Chrome.
    try {
        $metrics = Invoke-Api -Method GET -Path "/metrics"
        if ($metrics.StatusCode -eq 200) {
            Write-Host "[OK] Server is alive (health skipped -- alt-engine mode)" -ForegroundColor Green
            $serverAlive = $true
        }
    } catch {}
}

if (-not $serverAlive) {
    Write-Host "[FAIL] Server not reachable at $Base" -ForegroundColor Red
    Write-Host "       Start the server first:" -ForegroundColor Red
    Write-Host '       $env:PINCHTAB_ENGINE="<engine>"; go run ./cmd/pinchtab bridge' -ForegroundColor DarkGray
    exit 1
}

# ============================================================
# Detect engine mode via a probe request
# ============================================================
Write-Host ""
Write-Host "--- Detecting engine mode ---" -ForegroundColor Yellow

$probe = Invoke-Api -Method POST -Path "/navigate" -Body @{ url = "https://example.com" }
if ($probe.StatusCode -ne 200) {
    Write-Host "[FAIL] Probe navigation failed (status=$($probe.StatusCode))" -ForegroundColor Red
    Write-Host "       Raw: $($probe.Raw)" -ForegroundColor DarkGray
    exit 1
}

$EngineMode = "chrome"
if ($probe.Headers -and $probe.Headers["X-Engine"]) {
    $detected = $probe.Headers["X-Engine"]
    if ($detected -is [array]) { $detected = $detected[0] }
    $EngineMode = $detected
}

Write-Host "[OK] Engine detected: $EngineMode" -ForegroundColor Green
Write-Host ""

# ============================================================
# Run benchmarks
# ============================================================
Write-Host "############################################################" -ForegroundColor Cyan
Write-Host " BENCHMARKING: $($EngineMode.ToUpper()) ENGINE"               -ForegroundColor Cyan
Write-Host " Testing $($Websites.Count) websites"                         -ForegroundColor Cyan
Write-Host "############################################################" -ForegroundColor Cyan
Write-Host ""

$AllResults   = @()
$TotalPass    = 0
$TotalFail    = 0
$SiteIndex    = 0
$EdgeWarnings = @()

foreach ($site in $Websites) {
    $SiteIndex++
    Write-Host "============================================================" -ForegroundColor Magenta
    Write-Host " [$SiteIndex/$($Websites.Count)] $($site.Name) ($($site.Category))" -ForegroundColor Magenta
    Write-Host " $($site.URL)" -ForegroundColor DarkGray
    Write-Host "============================================================" -ForegroundColor Magenta

    $siteResult = @{
        Name     = $site.Name
        URL      = $site.URL
        Category = $site.Category
        Engine   = $EngineMode
    }

    # ---- Navigate ----
    Write-Host "  Navigate..." -NoNewline
    $navResp = Measure-ApiCall -Method POST -Path "/navigate" -Body @{ url = $site.URL }

    if ($navResp.StatusCode -eq 200) {
        $actualEngine = $EngineMode
        if ($navResp.Headers -and $navResp.Headers["X-Engine"]) {
            $hdr = $navResp.Headers["X-Engine"]
            if ($hdr -is [array]) { $hdr = $hdr[0] }
            $actualEngine = $hdr
        }
        $siteResult["NavigateMs"]     = $navResp.ElapsedMs
        $siteResult["NavigateStatus"] = "PASS"
        $siteResult["TabId"]          = $navResp.Body.tabId
        $siteResult["Title"]          = $navResp.Body.title
        $siteResult["ActualEngine"]   = $actualEngine
        Write-Host " $($navResp.ElapsedMs)ms [PASS]" -ForegroundColor Green -NoNewline
        Write-Host " engine=$actualEngine title=$($navResp.Body.title)" -ForegroundColor DarkGray

        # Edge case: check if engine fell back
        if ($actualEngine -ne $EngineMode) {
            $EdgeWarnings += "[$($site.Name)] Navigate: expected $EngineMode, got $actualEngine (fallback triggered)"
        }
    } else {
        $siteResult["NavigateMs"]     = $navResp.ElapsedMs
        $siteResult["NavigateStatus"] = "FAIL"
        $siteResult["ActualEngine"]   = $EngineMode
        Write-Host " $($navResp.ElapsedMs)ms [FAIL] status=$($navResp.StatusCode)" -ForegroundColor Red
        $TotalFail++
        $AllResults += $siteResult
        continue
    }

    # ---- Snapshot (all) ----
    Write-Host "  Snapshot (all)..." -NoNewline
    $snapResp = Measure-ApiCall -Method GET -Path "/snapshot"

    if ($snapResp.StatusCode -eq 200) {
        $nodeCount = 0
        if ($snapResp.Body.nodes) { $nodeCount = $snapResp.Body.nodes.Count }
        $siteResult["SnapshotAllMs"]     = $snapResp.ElapsedMs
        $siteResult["SnapshotAllStatus"] = "PASS"
        $siteResult["SnapshotAllNodes"]  = $nodeCount
        Write-Host " $($snapResp.ElapsedMs)ms [PASS] nodes=$nodeCount" -ForegroundColor Green

        # Edge case: empty snapshot on a non-trivial page
        if ($nodeCount -eq 0 -and $site.Category -ne "minimal") {
            $EdgeWarnings += "[$($site.Name)] Snapshot (all): 0 nodes on $($site.Category) page -- possible rendering failure"
        }
    } else {
        $snapEngine = $EngineMode
        if ($snapResp.Headers -and $snapResp.Headers["X-Engine"]) {
            $hdr = $snapResp.Headers["X-Engine"]
            if ($hdr -is [array]) { $hdr = $hdr[0] }
            $snapEngine = $hdr
        }
        $siteResult["SnapshotAllMs"]     = $snapResp.ElapsedMs
        $siteResult["SnapshotAllStatus"] = "FAIL"
        $siteResult["SnapshotAllNodes"]  = 0
        Write-Host " $($snapResp.ElapsedMs)ms [FAIL] status=$($snapResp.StatusCode)" -ForegroundColor Red

        # Check if it fell back to chrome
        if ($snapEngine -ne $EngineMode) {
            $EdgeWarnings += "[$($site.Name)] Snapshot: fell back from $EngineMode to $snapEngine"
        }
    }

    # ---- Snapshot (interactive) ----
    Write-Host "  Snapshot (interactive)..." -NoNewline
    $snapIResp = Measure-ApiCall -Method GET -Path "/snapshot?filter=interactive"

    if ($snapIResp.StatusCode -eq 200) {
        $iNodeCount = 0
        if ($snapIResp.Body.nodes) { $iNodeCount = $snapIResp.Body.nodes.Count }
        $siteResult["SnapshotInteractiveMs"]     = $snapIResp.ElapsedMs
        $siteResult["SnapshotInteractiveStatus"] = "PASS"
        $siteResult["SnapshotInteractiveNodes"]  = $iNodeCount
        Write-Host " $($snapIResp.ElapsedMs)ms [PASS] interactive=$iNodeCount" -ForegroundColor Green

        # Edge case: interactive count > all count
        $allNodes = [int]$siteResult["SnapshotAllNodes"]
        if ($allNodes -gt 0 -and $iNodeCount -gt $allNodes) {
            $EdgeWarnings += "[$($site.Name)] Interactive nodes ($iNodeCount) > All nodes ($allNodes) -- snapshot inconsistency"
        }
        # Edge case: zero interactive on a page known to have forms/links
        if ($iNodeCount -eq 0 -and $site.Category -eq "interactive") {
            $EdgeWarnings += "[$($site.Name)] 0 interactive nodes on interactive page -- possible JS issue"
        }
    } else {
        $siteResult["SnapshotInteractiveMs"]     = $snapIResp.ElapsedMs
        $siteResult["SnapshotInteractiveStatus"] = "FAIL"
        $siteResult["SnapshotInteractiveNodes"]  = 0
        Write-Host " $($snapIResp.ElapsedMs)ms [FAIL] status=$($snapIResp.StatusCode)" -ForegroundColor Red
    }

    # ---- Text ----
    Write-Host "  Text..." -NoNewline
    $textResp = Measure-ApiCall -Method GET -Path "/text" -RawText

    if ($textResp.StatusCode -eq 200) {
        $textLen = 0
        $textContent = $textResp.Body
        if ($textContent) { $textLen = $textContent.Length }
        $siteResult["TextMs"]     = $textResp.ElapsedMs
        $siteResult["TextStatus"] = "PASS"
        $siteResult["TextLength"] = $textLen
        Write-Host " $($textResp.ElapsedMs)ms [PASS] chars=$textLen" -ForegroundColor Green

        # Edge case: empty text on content-heavy page
        if ($textLen -eq 0 -and $site.Category -eq "content-heavy") {
            $EdgeWarnings += "[$($site.Name)] Text: 0 chars on content-heavy page -- text extraction failure"
        }
        # Edge case: suspiciously short text
        if ($textLen -gt 0 -and $textLen -lt 50 -and $site.Category -ne "minimal" -and $site.Category -ne "api-page") {
            $EdgeWarnings += "[$($site.Name)] Text: only $textLen chars -- suspiciously short for $($site.Category) page"
        }
    } else {
        $textEngine = $EngineMode
        if ($textResp.Headers -and $textResp.Headers["X-Engine"]) {
            $hdr = $textResp.Headers["X-Engine"]
            if ($hdr -is [array]) { $hdr = $hdr[0] }
            $textEngine = $hdr
        }
        $siteResult["TextMs"]     = $textResp.ElapsedMs
        $siteResult["TextStatus"] = "FAIL"
        $siteResult["TextLength"] = 0
        Write-Host " $($textResp.ElapsedMs)ms [FAIL] status=$($textResp.StatusCode)" -ForegroundColor Red

        if ($textEngine -ne $EngineMode) {
            $EdgeWarnings += "[$($site.Name)] Text: fell back from $EngineMode to $textEngine"
        }
    }

    # Count pass/fail for this site
    $allOps = @($siteResult["NavigateStatus"], $siteResult["SnapshotAllStatus"], $siteResult["SnapshotInteractiveStatus"], $siteResult["TextStatus"])
    $sitePassed = ($allOps | Where-Object { $_ -eq "PASS" }).Count
    $siteFailed = ($allOps | Where-Object { $_ -eq "FAIL" }).Count
    $TotalPass += $sitePassed
    $TotalFail += $siteFailed

    $AllResults += $siteResult
    Write-Host ""
}

# ============================================================
# Summary table
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " RESULTS: $($EngineMode.ToUpper()) ENGINE"                    -ForegroundColor Cyan
Write-Host " $TotalPass passed, $TotalFail failed / $($TotalPass + $TotalFail) total ops" -ForegroundColor $(if ($TotalFail -gt 0) { "Red" } else { "Green" })
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$fmt = "{0,-22} {1,10} {2,12} {3,14} {4,10} {5,10}"
Write-Host ($fmt -f "Website", "Navigate", "Snap (all)", "Snap (inter)", "Text", "Engine") -ForegroundColor White
Write-Host ($fmt -f ("=" * 22), ("=" * 10), ("=" * 12), ("=" * 14), ("=" * 10), ("=" * 10)) -ForegroundColor DarkGray

foreach ($r in $AllResults) {
    $navStr   = if ($r["NavigateStatus"] -eq "PASS") { "$($r['NavigateMs'])ms" } else { "FAIL" }
    $snapStr  = if ($r["SnapshotAllStatus"] -eq "PASS") { "$($r['SnapshotAllMs'])ms / $($r['SnapshotAllNodes'])n" } else { "FAIL" }
    $snapIStr = if ($r["SnapshotInteractiveStatus"] -eq "PASS") { "$($r['SnapshotInteractiveMs'])ms / $($r['SnapshotInteractiveNodes'])n" } else { "FAIL" }
    $textStr  = if ($r["TextStatus"] -eq "PASS") { "$($r['TextMs'])ms / $($r['TextLength'])c" } else { "FAIL" }
    $engStr   = if ($r["ActualEngine"]) { $r["ActualEngine"] } else { $EngineMode }
    Write-Host ($fmt -f $r["Name"], $navStr, $snapStr, $snapIStr, $textStr, $engStr)
}

# Compute averages
$navTimes  = $AllResults | Where-Object { $_["NavigateStatus"] -eq "PASS" } | ForEach-Object { [int]$_["NavigateMs"] }
$snapTimes = $AllResults | Where-Object { $_["SnapshotAllStatus"] -eq "PASS" } | ForEach-Object { [int]$_["SnapshotAllMs"] }
$textTimes = $AllResults | Where-Object { $_["TextStatus"] -eq "PASS" } | ForEach-Object { [int]$_["TextMs"] }

$totalNav = 0; $navTimes  | ForEach-Object { $totalNav  += $_ }
$totalSnap = 0; $snapTimes | ForEach-Object { $totalSnap += $_ }
$totalText = 0; $textTimes | ForEach-Object { $totalText += $_ }

Write-Host ""
Write-Host "  Total Navigate: ${totalNav}ms | Snapshot: ${totalSnap}ms | Text: ${totalText}ms" -ForegroundColor Cyan
Write-Host "  Grand Total:    $($totalNav + $totalSnap + $totalText)ms" -ForegroundColor Cyan

# ============================================================
# Edge case warnings
# ============================================================
if ($EdgeWarnings.Count -gt 0) {
    Write-Host ""
    Write-Host "--- Edge Case Warnings ---" -ForegroundColor Yellow
    foreach ($w in $EdgeWarnings) {
        Write-Host "  [!] $w" -ForegroundColor Yellow
    }
}

# ============================================================
# Save results to engine-specific JSON file
# ============================================================
$outputData = @{
    Engine    = $EngineMode
    Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Server    = $Base
    Results   = $AllResults
    Totals    = @{
        NavigateMs = $totalNav
        SnapshotMs = $totalSnap
        TextMs     = $totalText
        GrandTotal = $totalNav + $totalSnap + $totalText
    }
    Summary   = @{
        Pass = $TotalPass
        Fail = $TotalFail
    }
    EdgeWarnings = $EdgeWarnings
}

$saveFile = switch ($EngineMode) {
    "lightpanda" { $LpResultsFile }
    "lite"       { $LiteResultsFile }
    default      { $ChromeResultsFile }
}

$outputData | ConvertTo-Json -Depth 10 | Set-Content -Path $saveFile -Encoding UTF8
Write-Host ""
Write-Host "Results saved to: $saveFile" -ForegroundColor Green

# ============================================================
# Cross-engine comparison (if 2+ result files exist)
# ============================================================
$engines = @()
if (Test-Path $ChromeResultsFile) {
    $chromeData = Get-Content $ChromeResultsFile -Raw | ConvertFrom-Json
    $engines += @{ Name = "Chrome"; Data = $chromeData }
}
if (Test-Path $LiteResultsFile) {
    $liteData = Get-Content $LiteResultsFile -Raw | ConvertFrom-Json
    $engines += @{ Name = "Lite"; Data = $liteData }
}
if (Test-Path $LpResultsFile) {
    $lpData = Get-Content $LpResultsFile -Raw | ConvertFrom-Json
    $engines += @{ Name = "Lightpanda"; Data = $lpData }
}

if ($engines.Count -ge 2) {
    Write-Host ""
    Write-Host "############################################################" -ForegroundColor Cyan
    Write-Host " CROSS-ENGINE COMPARISON ($($engines.Count) engines)"        -ForegroundColor Cyan
    Write-Host "############################################################" -ForegroundColor Cyan
    Write-Host ""

    foreach ($eng in $engines) {
        Write-Host "  $($eng.Name) run: $($eng.Data.Timestamp)" -ForegroundColor DarkGray
    }
    Write-Host ""

    # ---- Averages table ----
    Write-Host "--- Average Response Times (ms) ---" -ForegroundColor Yellow
    Write-Host ""

    $hdrFmt = "{0,-20}"
    foreach ($eng in $engines) { $hdrFmt += " {0,14}" -f "" }
    $header = "{0,-20}" -f "Metric"
    foreach ($eng in $engines) { $header += (" {0,14}" -f $eng.Name) }
    Write-Host $header -ForegroundColor White
    Write-Host ("{0,-20}" -f ("-" * 20) + ((" " + ("-" * 14)) * $engines.Count)) -ForegroundColor DarkGray

    foreach ($metric in @("NavigateMs", "SnapshotAllMs", "SnapshotInteractiveMs", "TextMs")) {
        $label = $metric.Replace("Ms", "").Replace("All", " (all)").Replace("Interactive", " (inter)")
        $row = "{0,-20}" -f $label
        foreach ($eng in $engines) {
            $vals = @()
            foreach ($r in $eng.Data.Results) {
                $v = $r.$metric
                if ($null -ne $v -and [int]$v -gt 0) { $vals += [int]$v }
            }
            if ($vals.Count -gt 0) {
                $avg = [math]::Round(($vals | Measure-Object -Average).Average, 0)
                $row += " {0,14}" -f "${avg}ms"
            } else {
                $row += " {0,14}" -f "N/A"
            }
        }
        Write-Host $row -ForegroundColor Yellow
    }

    # Grand total row
    $row = "{0,-20}" -f "GRAND TOTAL"
    $grandTotals = @()
    foreach ($eng in $engines) {
        $gt = 0
        if ($eng.Data.Totals -and $eng.Data.Totals.GrandTotal) {
            $gt = [int]$eng.Data.Totals.GrandTotal
        }
        $grandTotals += $gt
        $row += " {0,14}" -f "${gt}ms"
    }
    Write-Host $row -ForegroundColor Cyan

    Write-Host ""

    # ---- Per-site comparison ----
    Write-Host "--- Per-Site Breakdown ---" -ForegroundColor Yellow
    Write-Host ""

    # Collect all unique site names
    $allSiteNames = @()
    foreach ($eng in $engines) {
        foreach ($r in $eng.Data.Results) {
            if ($allSiteNames -notcontains $r.Name) { $allSiteNames += $r.Name }
        }
    }

    $siteFmt = "{0,-22}"
    foreach ($eng in $engines) { $siteFmt += " {0,16}" -f "" }
    $siteHeader = "{0,-22}" -f "Website"
    foreach ($eng in $engines) { $siteHeader += (" {0,16}" -f "$($eng.Name) Total") }
    $siteHeader += " {0,10}" -f "Winner"
    Write-Host $siteHeader -ForegroundColor White
    Write-Host ("{0,-22}" -f ("-" * 22) + ((" " + ("-" * 16)) * $engines.Count) + " " + ("-" * 10)) -ForegroundColor DarkGray

    $engineWins = @{}
    foreach ($eng in $engines) { $engineWins[$eng.Name] = 0 }

    foreach ($siteName in $allSiteNames) {
        $row = "{0,-22}" -f $siteName
        $bestTotal = [int]::MaxValue
        $bestEngine = "N/A"
        $totals = @()

        foreach ($eng in $engines) {
            $siteData = $eng.Data.Results | Where-Object { $_.Name -eq $siteName }
            if ($siteData) {
                $nav  = if ($siteData.NavigateMs) { [int]$siteData.NavigateMs } else { 0 }
                $snap = if ($siteData.SnapshotAllMs) { [int]$siteData.SnapshotAllMs } else { 0 }
                $text = if ($siteData.TextMs) { [int]$siteData.TextMs } else { 0 }
                $total = $nav + $snap + $text
                $totals += $total
                $row += " {0,16}" -f "${total}ms"

                if ($total -gt 0 -and $total -lt $bestTotal) {
                    $bestTotal = $total
                    $bestEngine = $eng.Name
                }
            } else {
                $totals += 0
                $row += " {0,16}" -f "N/A"
            }
        }

        if ($bestEngine -ne "N/A") { $engineWins[$bestEngine]++ }
        $winColor = switch ($bestEngine) {
            "Chrome"     { "White" }
            "Lite"       { "Green" }
            "Lightpanda" { "Magenta" }
            default      { "DarkGray" }
        }
        $row += " {0,10}" -f $bestEngine
        Write-Host $row -ForegroundColor $winColor
    }

    # ---- Win summary ----
    Write-Host ""
    Write-Host "--- Win Count ---" -ForegroundColor Yellow
    foreach ($eng in $engines) {
        $wins = $engineWins[$eng.Name]
        $color = if ($wins -eq ($engineWins.Values | Measure-Object -Maximum).Maximum) { "Green" } else { "White" }
        Write-Host "  $($eng.Name): $wins wins" -ForegroundColor $color
    }

    # ---- Overall winner ----
    $minGrand = ($grandTotals | Where-Object { $_ -gt 0 } | Measure-Object -Minimum).Minimum
    $winnerIdx = [array]::IndexOf($grandTotals, $minGrand)
    if ($winnerIdx -ge 0 -and $minGrand -gt 0) {
        $overallWinner = $engines[$winnerIdx].Name
        Write-Host ""
        Write-Host "  OVERALL FASTEST: $overallWinner (${minGrand}ms total)" -ForegroundColor Green
    }

    # ---- Pass/Fail comparison ----
    Write-Host ""
    Write-Host "--- Reliability (Pass/Fail) ---" -ForegroundColor Yellow
    $relFmt = "{0,-15} {1,8} {2,8} {3,10}"
    Write-Host ($relFmt -f "Engine", "Pass", "Fail", "Rate") -ForegroundColor White
    Write-Host ($relFmt -f ("-" * 15), ("-" * 8), ("-" * 8), ("-" * 10)) -ForegroundColor DarkGray

    foreach ($eng in $engines) {
        $p = 0; $f = 0
        if ($eng.Data.Summary) {
            $p = [int]$eng.Data.Summary.Pass
            $f = [int]$eng.Data.Summary.Fail
        }
        $total = $p + $f
        $rate = if ($total -gt 0) { [math]::Round(($p / $total) * 100, 1) } else { 0 }
        $rateColor = if ($rate -ge 90) { "Green" } elseif ($rate -ge 70) { "Yellow" } else { "Red" }
        Write-Host ($relFmt -f $eng.Name, $p, $f, "${rate}%") -ForegroundColor $rateColor
    }

    Write-Host ""
} else {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host " Only $($engines.Count) engine result file(s) found."        -ForegroundColor Yellow
    Write-Host " Run this script with different engine modes to compare."     -ForegroundColor Yellow
    Write-Host ' Example: $env:PINCHTAB_ENGINE="lite"; go run ./cmd/pinchtab bridge' -ForegroundColor DarkGray
    Write-Host "============================================================" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
if ($TotalFail -gt 0) { exit 1 } else { exit 0 }
