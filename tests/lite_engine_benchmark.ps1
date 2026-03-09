# ============================================================
# PinchTab Lite Engine vs Chrome — Performance Benchmark
# ============================================================
# Compares response times for Navigate, Snapshot, and Text
# operations across real-world websites using both engines.
#
# How to use:
#   1. Start server with Lite engine:
#        $env:PINCHTAB_ENGINE="lite"; go run ./cmd/pinchtab dashboard
#      Run the script:
#        .\tests\lite_engine_benchmark.ps1
#
#   2. Restart server with Chrome engine (default):
#        $env:PINCHTAB_ENGINE="chrome"; go run ./cmd/pinchtab dashboard
#      Run the script again:
#        .\tests\lite_engine_benchmark.ps1
#
#   The script auto-detects the active engine from X-Engine header.
#   Results are saved to JSON files. When both exist, comparison
#   is printed and appended to LITE_ENGINE_CHANGES.md.
#
# Usage:
#   .\tests\lite_engine_benchmark.ps1 [-Port 9867] [-Token ""]
# ============================================================

param(
    [string]$Port  = "9867",
    [string]$Token = ""
)

$ErrorActionPreference = "Stop"
$Base = "http://localhost:$Port"
$Headers = @{ "Content-Type" = "application/json" }
if ($Token -ne "") {
    $Headers["Authorization"] = "Bearer $Token"
}

$ScriptDir = $PSScriptRoot
$LiteResultsFile   = Join-Path $ScriptDir "lite_benchmark_results.json"
$ChromeResultsFile = Join-Path $ScriptDir "chrome_benchmark_results.json"

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
        Uri                  = $uri
        Method               = $Method
        Headers              = $Headers
        UseBasicParsing      = $true
        ErrorAction          = "Stop"
        MaximumRedirection   = 0
    }
    if ($Body) {
        $json = $Body | ConvertTo-Json -Depth 10
        $params["Body"] = $json
        $params["ContentType"] = "application/json"
    }
    try {
        $resp = Invoke-WebRequest @params
        $result = @{
            StatusCode     = $resp.StatusCode
            Raw            = $resp.Content
            Headers        = $resp.Headers
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
# Real-world websites to benchmark
# ============================================================
$Websites = @(
    @{ Name = "Example.com";       URL = "https://example.com" },
    @{ Name = "Wikipedia (Go)";    URL = "https://en.wikipedia.org/wiki/Go_(programming_language)" },
    @{ Name = "Hacker News";       URL = "https://news.ycombinator.com" },
    @{ Name = "httpbin.org";       URL = "https://httpbin.org" },
    @{ Name = "GitHub Explore";    URL = "https://github.com/explore" },
    @{ Name = "DuckDuckGo";       URL = "https://duckduckgo.com" },
    @{ Name = "Wikipedia (CS)";    URL = "https://en.wikipedia.org/wiki/Computer_science" },
    @{ Name = "Stack Overflow";    URL = "https://stackoverflow.com/questions" }
)

# ============================================================
# PREFLIGHT: Server health
# ============================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " PinchTab Engine Benchmark"                  -ForegroundColor Cyan
Write-Host " Server: $Base"                              -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "--- Preflight: checking server ---" -ForegroundColor Yellow
$health = Invoke-Api -Method GET -Path "/health"
if ($health.StatusCode -ne 200) {
    Write-Host "Server not reachable at $Base - aborting." -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Server is alive" -ForegroundColor Green

# ============================================================
# Detect engine mode via a probe request
# ============================================================
Write-Host ""
Write-Host "--- Detecting engine mode ---" -ForegroundColor Yellow

$probe = Invoke-Api -Method POST -Path "/navigate" -Body @{ url = "https://example.com" }
if ($probe.StatusCode -ne 200) {
    Write-Host "[FAIL] Probe navigation failed (status=$($probe.StatusCode))" -ForegroundColor Red
    Write-Host "       Make sure the server is running with a browser instance." -ForegroundColor Red
    Write-Host "       Raw: $($probe.Raw)" -ForegroundColor DarkGray
    exit 1
}

$EngineMode = "chrome"
if ($probe.Headers -and $probe.Headers["X-Engine"] -eq "lite") {
    $EngineMode = "lite"
}
$ProbeTabId = $probe.Body.tabId

Write-Host "[OK] Engine detected: $EngineMode" -ForegroundColor Green
Write-Host "     Probe tabId: $ProbeTabId" -ForegroundColor DarkGray
Write-Host ""

# ============================================================
# Run benchmarks
# ============================================================
Write-Host "########################################" -ForegroundColor Cyan
Write-Host " BENCHMARKING: $($EngineMode.ToUpper()) ENGINE" -ForegroundColor Cyan
Write-Host " Testing $($Websites.Count) websites"    -ForegroundColor Cyan
Write-Host "########################################" -ForegroundColor Cyan
Write-Host ""

$AllResults = @()
$Pass = 0
$Fail = 0
$SiteIndex = 0

foreach ($site in $Websites) {
    $SiteIndex++
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host " [$SiteIndex/$($Websites.Count)] $($site.Name)" -ForegroundColor Magenta
    Write-Host " $($site.URL)" -ForegroundColor DarkGray
    Write-Host "========================================" -ForegroundColor Magenta

    $siteResult = @{
        Name = $site.Name
        URL  = $site.URL
    }

    # --- Navigate ---
    Write-Host "  Navigate..." -NoNewline
    $navResp = Measure-ApiCall -Method POST -Path "/navigate" -Body @{ url = $site.URL }

    if ($navResp.StatusCode -eq 200) {
        $siteResult["NavigateMs"]     = $navResp.ElapsedMs
        $siteResult["NavigateStatus"] = "OK"
        $siteResult["Title"]          = $navResp.Body.title
        $tabId = $navResp.Body.tabId
        Write-Host " $($navResp.ElapsedMs)ms" -ForegroundColor Green -NoNewline
        Write-Host " | title: $($navResp.Body.title)" -ForegroundColor DarkGray
        $Pass++
    } else {
        $siteResult["NavigateMs"]     = $navResp.ElapsedMs
        $siteResult["NavigateStatus"] = "FAIL ($($navResp.StatusCode))"
        $tabId = $null
        Write-Host " FAIL ($($navResp.StatusCode))" -ForegroundColor Red
        $Fail++
    }

    # Chrome may need a small wait for page to fully load
    if ($EngineMode -eq "chrome") {
        Start-Sleep -Seconds 2
    }

    # --- Snapshot (all) ---
    Write-Host "  Snapshot (all)..." -NoNewline
    $snapPath = "/snapshot"
    if ($tabId) { $snapPath = "/snapshot?tabId=$tabId" }
    $snapResp = Measure-ApiCall -Method GET -Path $snapPath

    if ($snapResp.StatusCode -eq 200) {
        $nodeCount = 0
        if ($snapResp.Body.nodes) { $nodeCount = $snapResp.Body.nodes.Count }
        $siteResult["SnapshotAllMs"]     = $snapResp.ElapsedMs
        $siteResult["SnapshotAllStatus"] = "OK"
        $siteResult["SnapshotAllNodes"]  = $nodeCount
        Write-Host " $($snapResp.ElapsedMs)ms" -ForegroundColor Green -NoNewline
        Write-Host " | $nodeCount nodes" -ForegroundColor DarkGray
        $Pass++
    } else {
        $siteResult["SnapshotAllMs"]     = $snapResp.ElapsedMs
        $siteResult["SnapshotAllStatus"] = "FAIL ($($snapResp.StatusCode))"
        $siteResult["SnapshotAllNodes"]  = 0
        Write-Host " FAIL ($($snapResp.StatusCode))" -ForegroundColor Red
        $Fail++
    }

    # --- Snapshot (interactive) ---
    Write-Host "  Snapshot (interactive)..." -NoNewline
    $snapIPath = "/snapshot?filter=interactive"
    if ($tabId) { $snapIPath = "/snapshot?tabId=$tabId&filter=interactive" }
    $snapIResp = Measure-ApiCall -Method GET -Path $snapIPath

    if ($snapIResp.StatusCode -eq 200) {
        $iNodeCount = 0
        if ($snapIResp.Body.nodes) { $iNodeCount = $snapIResp.Body.nodes.Count }
        $siteResult["SnapshotInteractiveMs"]     = $snapIResp.ElapsedMs
        $siteResult["SnapshotInteractiveStatus"] = "OK"
        $siteResult["SnapshotInteractiveNodes"]  = $iNodeCount
        Write-Host " $($snapIResp.ElapsedMs)ms" -ForegroundColor Green -NoNewline
        Write-Host " | $iNodeCount interactive nodes" -ForegroundColor DarkGray
        $Pass++
    } else {
        $siteResult["SnapshotInteractiveMs"]     = $snapIResp.ElapsedMs
        $siteResult["SnapshotInteractiveStatus"] = "FAIL ($($snapIResp.StatusCode))"
        $siteResult["SnapshotInteractiveNodes"]  = 0
        Write-Host " FAIL ($($snapIResp.StatusCode))" -ForegroundColor Red
        $Fail++
    }

    # --- Text extraction ---
    Write-Host "  Text..." -NoNewline
    $textPath = "/text"
    if ($tabId) { $textPath = "/text?tabId=$tabId" }
    # Lite returns plain text, Chrome returns JSON
    $textResp = Measure-ApiCall -Method GET -Path $textPath -RawText

    if ($textResp.StatusCode -eq 200) {
        $textLen = 0
        $textContent = $textResp.Body
        if ($textContent) { $textLen = $textContent.Length }
        $siteResult["TextMs"]       = $textResp.ElapsedMs
        $siteResult["TextStatus"]   = "OK"
        $siteResult["TextLength"]   = $textLen
        Write-Host " $($textResp.ElapsedMs)ms" -ForegroundColor Green -NoNewline
        Write-Host " | $textLen chars" -ForegroundColor DarkGray
        $Pass++
    } else {
        $siteResult["TextMs"]       = $textResp.ElapsedMs
        $siteResult["TextStatus"]   = "FAIL ($($textResp.StatusCode))"
        $siteResult["TextLength"]   = 0
        Write-Host " FAIL ($($textResp.StatusCode))" -ForegroundColor Red
        $Fail++
    }

    $AllResults += $siteResult
    Write-Host ""
}

# ============================================================
# Summary table
# ============================================================
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " BENCHMARK RESULTS: $($EngineMode.ToUpper()) ENGINE" -ForegroundColor Cyan
Write-Host " $Pass passed, $Fail failed / $($Pass + $Fail) total" -ForegroundColor $(if ($Fail -eq 0) { "Green" } else { "Red" })
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Print summary table
$fmt = "{0,-22} {1,12} {2,14} {3,14} {4,10}"
Write-Host ($fmt -f "Website", "Navigate", "Snap (all)", "Snap (inter)", "Text") -ForegroundColor White
Write-Host ($fmt -f "----------------------", "------------", "--------------", "--------------", "----------") -ForegroundColor DarkGray

foreach ($r in $AllResults) {
    $navStr   = if ($r.NavigateStatus -eq "OK") { "$($r.NavigateMs)ms" } else { $r.NavigateStatus }
    $snapStr  = if ($r.SnapshotAllStatus -eq "OK") { "$($r.SnapshotAllMs)ms ($($r.SnapshotAllNodes)n)" } else { $r.SnapshotAllStatus }
    $snapIStr = if ($r.SnapshotInteractiveStatus -eq "OK") { "$($r.SnapshotInteractiveMs)ms ($($r.SnapshotInteractiveNodes)n)" } else { $r.SnapshotInteractiveStatus }
    $textStr  = if ($r.TextStatus -eq "OK") { "$($r.TextMs)ms ($($r.TextLength)c)" } else { $r.TextStatus }
    Write-Host ($fmt -f $r.Name, $navStr, $snapStr, $snapIStr, $textStr)
}

# Total time (Measure-Object doesn't work on hashtables; sum manually)
$totalNav  = 0; $AllResults | Where-Object { $_.NavigateStatus -eq "OK" }    | ForEach-Object { $totalNav  += [int]$_.NavigateMs }
$totalSnap = 0; $AllResults | Where-Object { $_.SnapshotAllStatus -eq "OK" } | ForEach-Object { $totalSnap += [int]$_.SnapshotAllMs }
$totalText = 0; $AllResults | Where-Object { $_.TextStatus -eq "OK" }        | ForEach-Object { $totalText += [int]$_.TextMs }
Write-Host ""
Write-Host "  Total Navigate: ${totalNav}ms | Snapshot: ${totalSnap}ms | Text: ${totalText}ms" -ForegroundColor Cyan
Write-Host "  Grand Total: $($totalNav + $totalSnap + $totalText)ms" -ForegroundColor Cyan

# ============================================================
# Save results to JSON
# ============================================================
$outputData = @{
    Engine    = $EngineMode
    Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Server    = $Base
    Websites  = $AllResults
    Totals    = @{
        NavigateMs = $totalNav
        SnapshotMs = $totalSnap
        TextMs     = $totalText
        GrandTotal = $totalNav + $totalSnap + $totalText
    }
    Summary   = @{
        Pass = $Pass
        Fail = $Fail
    }
}

$outputFile = if ($EngineMode -eq "lite") { $LiteResultsFile } else { $ChromeResultsFile }
$outputData | ConvertTo-Json -Depth 10 | Set-Content -Path $outputFile -Encoding UTF8
Write-Host ""
Write-Host "Results saved to: $outputFile" -ForegroundColor Green

# ============================================================
# Comparison: if both result files exist, generate side-by-side
# ============================================================
$otherFile = if ($EngineMode -eq "lite") { $ChromeResultsFile } else { $LiteResultsFile }

if (Test-Path $otherFile) {
    Write-Host ""
    Write-Host "########################################" -ForegroundColor Cyan
    Write-Host " COMPARISON: LITE vs CHROME"              -ForegroundColor Cyan
    Write-Host "########################################" -ForegroundColor Cyan
    Write-Host ""

    $liteData   = Get-Content $LiteResultsFile -Raw | ConvertFrom-Json
    $chromeData = Get-Content $ChromeResultsFile -Raw | ConvertFrom-Json

    Write-Host "Lite run:   $($liteData.Timestamp)" -ForegroundColor DarkGray
    Write-Host "Chrome run: $($chromeData.Timestamp)" -ForegroundColor DarkGray
    Write-Host ""

    # Build comparison table
    $cmpFmt = "{0,-22} {1,10} {2,10} {3,10} | {4,10} {5,10} {6,10} | {7,10}"
    Write-Host ($cmpFmt -f "Website", "Lite Nav", "Lite Snap", "Lite Text", "Chr Nav", "Chr Snap", "Chr Text", "Winner") -ForegroundColor White
    Write-Host ($cmpFmt -f "----------------------", "----------", "----------", "----------", "----------", "----------", "----------", "----------") -ForegroundColor DarkGray

    $liteWins = 0
    $chromeWins = 0

    $comparisonRows = @()

    foreach ($liteSite in $liteData.Websites) {
        $chromeSite = $chromeData.Websites | Where-Object { $_.Name -eq $liteSite.Name }
        if (-not $chromeSite) { continue }

        $liteTotal  = [int]$liteSite.NavigateMs + [int]$liteSite.SnapshotAllMs + [int]$liteSite.TextMs
        $chromeTotal = [int]$chromeSite.NavigateMs + [int]$chromeSite.SnapshotAllMs + [int]$chromeSite.TextMs
        $winner = if ($liteTotal -lt $chromeTotal) { "LITE" } elseif ($chromeTotal -lt $liteTotal) { "CHROME" } else { "TIE" }
        if ($winner -eq "LITE") { $liteWins++ } elseif ($winner -eq "CHROME") { $chromeWins++ }

        $winColor = if ($winner -eq "LITE") { "Green" } elseif ($winner -eq "CHROME") { "Yellow" } else { "White" }

        Write-Host ($cmpFmt -f $liteSite.Name, "$($liteSite.NavigateMs)ms", "$($liteSite.SnapshotAllMs)ms", "$($liteSite.TextMs)ms", "$($chromeSite.NavigateMs)ms", "$($chromeSite.SnapshotAllMs)ms", "$($chromeSite.TextMs)ms", $winner) -ForegroundColor $winColor

        $comparisonRows += @{
            Name           = $liteSite.Name
            LiteNavigate   = [int]$liteSite.NavigateMs
            LiteSnapshot   = [int]$liteSite.SnapshotAllMs
            LiteSnapI      = [int]$liteSite.SnapshotInteractiveMs
            LiteText       = [int]$liteSite.TextMs
            LiteTotal      = $liteTotal
            LiteNodes      = [int]$liteSite.SnapshotAllNodes
            LiteINodes     = [int]$liteSite.SnapshotInteractiveNodes
            LiteTextLen    = [int]$liteSite.TextLength
            ChromeNavigate = [int]$chromeSite.NavigateMs
            ChromeSnapshot = [int]$chromeSite.SnapshotAllMs
            ChromeSnapI    = [int]$chromeSite.SnapshotInteractiveMs
            ChromeText     = [int]$chromeSite.TextMs
            ChromeTotal    = $chromeTotal
            ChromeNodes    = [int]$chromeSite.SnapshotAllNodes
            ChromeINodes   = [int]$chromeSite.SnapshotInteractiveNodes
            ChromeTextLen  = [int]$chromeSite.TextLength
            Winner         = $winner
        }
    }

    Write-Host ""
    Write-Host "  Lite wins: $liteWins | Chrome wins: $chromeWins" -ForegroundColor Cyan
    Write-Host "  Lite total: $($liteData.Totals.GrandTotal)ms | Chrome total: $($chromeData.Totals.GrandTotal)ms" -ForegroundColor Cyan

    $overallWinner = if ($liteData.Totals.GrandTotal -lt $chromeData.Totals.GrandTotal) { "LITE" } elseif ($chromeData.Totals.GrandTotal -lt $liteData.Totals.GrandTotal) { "CHROME" } else { "TIE" }
    $speedup = 0
    if ($overallWinner -eq "LITE" -and $chromeData.Totals.GrandTotal -gt 0) {
        $speedup = [math]::Round($chromeData.Totals.GrandTotal / $liteData.Totals.GrandTotal, 2)
        Write-Host "  Overall winner: LITE (${speedup}x faster)" -ForegroundColor Green
    } elseif ($overallWinner -eq "CHROME" -and $liteData.Totals.GrandTotal -gt 0) {
        $speedup = [math]::Round($liteData.Totals.GrandTotal / $chromeData.Totals.GrandTotal, 2)
        Write-Host "  Overall winner: CHROME (${speedup}x faster)" -ForegroundColor Yellow
    } else {
        Write-Host "  Overall: TIE" -ForegroundColor White
    }

    # ============================================================
    # Append comparison to LITE_ENGINE_CHANGES.md
    # ============================================================
    $mdPath = Join-Path $ScriptDir "..\LITE_ENGINE_CHANGES.md"
    if (Test-Path $mdPath) {
        Write-Host ""
        Write-Host "--- Updating LITE_ENGINE_CHANGES.md ---" -ForegroundColor Yellow

        $mdContent = Get-Content $mdPath -Raw

        # Build the comparison markdown section
        $section = @()
        $section += ""
        $section += "## Performance Benchmark: Lite vs Chrome"
        $section += ""
        $section += "**Lite run:** $($liteData.Timestamp) | **Chrome run:** $($chromeData.Timestamp)"
        $section += ""
        $section += "### Response Times (ms)"
        $section += ""
        $section += "| Website | Lite Navigate | Lite Snapshot | Lite Text | Chrome Navigate | Chrome Snapshot | Chrome Text | Winner |"
        $section += "|---------|--------------|--------------|-----------|----------------|----------------|-------------|--------|"

        foreach ($row in $comparisonRows) {
            $section += "| $($row.Name) | $($row.LiteNavigate)ms | $($row.LiteSnapshot)ms | $($row.LiteText)ms | $($row.ChromeNavigate)ms | $($row.ChromeSnapshot)ms | $($row.ChromeText)ms | **$($row.Winner)** |"
        }

        $section += ""
        $section += "### Totals"
        $section += ""
        $section += "| Metric | Lite | Chrome | Difference |"
        $section += "|--------|------|--------|------------|"

        $navDiff = [int]$chromeData.Totals.NavigateMs - [int]$liteData.Totals.NavigateMs
        $snapDiff = [int]$chromeData.Totals.SnapshotMs - [int]$liteData.Totals.SnapshotMs
        $textDiff = [int]$chromeData.Totals.TextMs - [int]$liteData.Totals.TextMs
        $grandDiff = [int]$chromeData.Totals.GrandTotal - [int]$liteData.Totals.GrandTotal

        $section += "| Navigate Total | $($liteData.Totals.NavigateMs)ms | $($chromeData.Totals.NavigateMs)ms | $($navDiff)ms |"
        $section += "| Snapshot Total | $($liteData.Totals.SnapshotMs)ms | $($chromeData.Totals.SnapshotMs)ms | $($snapDiff)ms |"
        $section += "| Text Total | $($liteData.Totals.TextMs)ms | $($chromeData.Totals.TextMs)ms | $($textDiff)ms |"
        $section += "| **Grand Total** | **$($liteData.Totals.GrandTotal)ms** | **$($chromeData.Totals.GrandTotal)ms** | **$($grandDiff)ms** |"

        $section += ""
        if ($overallWinner -eq "LITE") {
            $section += "> **Result:** Lite Engine is **${speedup}x faster** overall (wins $liteWins/$($comparisonRows.Count) sites)"
        } elseif ($overallWinner -eq "CHROME") {
            $section += "> **Result:** Chrome Engine is **${speedup}x faster** overall (wins $chromeWins/$($comparisonRows.Count) sites)"
        } else {
            $section += "> **Result:** Both engines performed equally"
        }

        $section += ""
        $section += "### Node & Text Comparison"
        $section += ""
        $section += "| Website | Lite Nodes | Chrome Nodes | Lite Interactive | Chrome Interactive | Lite Text (chars) | Chrome Text (chars) |"
        $section += "|---------|-----------|-------------|-----------------|-------------------|------------------|-------------------|"

        foreach ($row in $comparisonRows) {
            $section += "| $($row.Name) | $($row.LiteNodes) | $($row.ChromeNodes) | $($row.LiteINodes) | $($row.ChromeINodes) | $($row.LiteTextLen) | $($row.ChromeTextLen) |"
        }

        $section += ""
        $section += "*Benchmark run from ``tests/lite_engine_benchmark.ps1``*"
        $section += ""

        $sectionText = $section -join "`n"

        # Remove existing benchmark section if present (replace it)
        $marker = "## Performance Benchmark: Lite vs Chrome"
        if ($mdContent -match [regex]::Escape($marker)) {
            # Find and replace existing section (from marker to next ## or end)
            $pattern = "(?s)\r?\n?" + [regex]::Escape($marker) + ".*?(?=\r?\n## [^P]|\z)"
            $mdContent = [regex]::Replace($mdContent, $pattern, $sectionText)
        } else {
            # Append at end
            $mdContent = $mdContent.TrimEnd() + [Environment]::NewLine + $sectionText
        }

        Set-Content -Path $mdPath -Value $mdContent -Encoding UTF8 -NoNewline
        Write-Host "[OK] LITE_ENGINE_CHANGES.md updated with comparison table" -ForegroundColor Green
    } else {
        Write-Host "LITE_ENGINE_CHANGES.md not found at $mdPath - skipping update" -ForegroundColor Yellow
    }
} else {
    Write-Host ""
    $needed = if ($EngineMode -eq "lite") { "chrome" } else { "lite" }
    Write-Host "============================================" -ForegroundColor Yellow
    Write-Host " To generate comparison, restart the server" -ForegroundColor Yellow
    Write-Host " with PINCHTAB_ENGINE=$needed and run again." -ForegroundColor Yellow
    Write-Host "============================================" -ForegroundColor Yellow
}

Write-Host ""
if ($Fail -gt 0) { exit 1 } else { exit 0 }
