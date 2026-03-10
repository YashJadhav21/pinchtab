# ============================================================
# PinchTab Lightpanda Engine — Manual Test & Benchmark
# ============================================================
# Tests that the Lightpanda engine mode works end-to-end by
# running Navigate, Snapshot, and Text operations against real
# websites. Compares results with Chrome and Lite engines when
# their result files are available.
#
# Prerequisites:
#   1. Install Lightpanda binary and ensure it's in PATH or set
#      $env:LIGHTPANDA_BIN to the binary path.
#
#   2. Start PinchTab with Lightpanda engine:
#        $env:PINCHTAB_ENGINE="lightpanda"; go run ./cmd/pinchtab bridge
#
#   3. Run this script:
#        .\tests\lightpanda_benchmark.ps1
#
#   The script auto-detects the active engine from X-Engine header.
#   Results are saved to lightpanda_benchmark_results.json.
#
# Usage:
#   .\tests\lightpanda_benchmark.ps1 [-Port 9867] [-Token ""]
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
$LpResultsFile     = Join-Path $ScriptDir "lightpanda_benchmark_results.json"
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
# Test websites
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
Write-Host " PinchTab Lightpanda Engine Benchmark"       -ForegroundColor Cyan
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
# Detect engine mode
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
    $EngineMode = $probe.Headers["X-Engine"]
}

Write-Host "[OK] Engine detected: $EngineMode" -ForegroundColor Green
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
        $siteResult["NavigateStatus"] = "PASS"
        $siteResult["TabId"]          = $navResp.Body.tabId
        $siteResult["Title"]          = $navResp.Body.title
        $siteResult["Engine"]         = if ($navResp.Headers["X-Engine"]) { $navResp.Headers["X-Engine"] } else { "chrome" }
        Write-Host " $($navResp.ElapsedMs)ms [PASS] title=$($navResp.Body.title)" -ForegroundColor Green
    } else {
        $siteResult["NavigateMs"]     = $navResp.ElapsedMs
        $siteResult["NavigateStatus"] = "FAIL"
        $siteResult["Engine"]         = $EngineMode
        Write-Host " $($navResp.ElapsedMs)ms [FAIL] status=$($navResp.StatusCode)" -ForegroundColor Red
        $Fail++
        $AllResults += $siteResult
        continue
    }

    # --- Snapshot (interactive) ---
    Write-Host "  Snapshot..." -NoNewline
    $snapResp = Measure-ApiCall -Method GET -Path "/snapshot?filter=interactive"

    if ($snapResp.StatusCode -eq 200) {
        $nodeCount = 0
        if ($snapResp.Body.nodes) { $nodeCount = $snapResp.Body.nodes.Count }
        $siteResult["SnapshotMs"]     = $snapResp.ElapsedMs
        $siteResult["SnapshotStatus"] = "PASS"
        $siteResult["SnapshotNodes"]  = $nodeCount
        Write-Host " $($snapResp.ElapsedMs)ms [PASS] nodes=$nodeCount" -ForegroundColor Green
    } else {
        $siteResult["SnapshotMs"]     = $snapResp.ElapsedMs
        $siteResult["SnapshotStatus"] = "FAIL"
        Write-Host " $($snapResp.ElapsedMs)ms [FAIL]" -ForegroundColor Red
    }

    # --- Text ---
    Write-Host "  Text..." -NoNewline
    $textResp = Measure-ApiCall -Method GET -Path "/text" -RawText

    if ($textResp.StatusCode -eq 200) {
        $textLen = 0
        if ($textResp.Body) { $textLen = $textResp.Body.Length }
        $siteResult["TextMs"]     = $textResp.ElapsedMs
        $siteResult["TextStatus"] = "PASS"
        $siteResult["TextLength"] = $textLen
        Write-Host " $($textResp.ElapsedMs)ms [PASS] chars=$textLen" -ForegroundColor Green
    } else {
        $siteResult["TextMs"]     = $textResp.ElapsedMs
        $siteResult["TextStatus"] = "FAIL"
        Write-Host " $($textResp.ElapsedMs)ms [FAIL]" -ForegroundColor Red
    }

    $allPass = ($siteResult["NavigateStatus"] -eq "PASS") -and
               ($siteResult["SnapshotStatus"] -eq "PASS") -and
               ($siteResult["TextStatus"] -eq "PASS")
    if ($allPass) { $Pass++ } else { $Fail++ }
    $AllResults += $siteResult
    Write-Host ""
}

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " SUMMARY: $EngineMode engine"            -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Sites tested: $($Websites.Count)" -ForegroundColor White
Write-Host "  Pass:         $Pass" -ForegroundColor Green
Write-Host "  Fail:         $Fail" -ForegroundColor $(if ($Fail -gt 0) { "Red" } else { "Green" })
Write-Host ""

# Averages
$navTimes  = $AllResults | Where-Object { $_.NavigateStatus -eq "PASS" } | ForEach-Object { $_.NavigateMs }
$snapTimes = $AllResults | Where-Object { $_.SnapshotStatus -eq "PASS" } | ForEach-Object { $_.SnapshotMs }
$textTimes = $AllResults | Where-Object { $_.TextStatus -eq "PASS" } | ForEach-Object { $_.TextMs }

if ($navTimes.Count -gt 0) {
    $avgNav  = [math]::Round(($navTimes  | Measure-Object -Average).Average, 0)
    $avgSnap = [math]::Round(($snapTimes | Measure-Object -Average).Average, 0)
    $avgText = [math]::Round(($textTimes | Measure-Object -Average).Average, 0)
    $avgTotal = $avgNav + $avgSnap + $avgText

    Write-Host "  Avg Navigate:  ${avgNav}ms" -ForegroundColor Yellow
    Write-Host "  Avg Snapshot:  ${avgSnap}ms" -ForegroundColor Yellow
    Write-Host "  Avg Text:      ${avgText}ms" -ForegroundColor Yellow
    Write-Host "  Avg Total:     ${avgTotal}ms" -ForegroundColor Yellow
}

Write-Host ""

# ============================================================
# Save results
# ============================================================
$output = @{
    Engine    = $EngineMode
    Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Results   = $AllResults
}

$saveFile = switch ($EngineMode) {
    "lightpanda" { $LpResultsFile }
    "lite"       { $LiteResultsFile }
    default      { $ChromeResultsFile }
}

$output | ConvertTo-Json -Depth 10 | Set-Content -Path $saveFile -Encoding UTF8
Write-Host "Results saved to: $saveFile" -ForegroundColor DarkGray
Write-Host ""

# ============================================================
# Cross-engine comparison (if multiple result files exist)
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
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " CROSS-ENGINE COMPARISON"                 -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $header = "{0,-20}" -f "Metric"
    foreach ($eng in $engines) {
        $header += " {0,15}" -f $eng.Name
    }
    Write-Host $header -ForegroundColor White

    Write-Host ("-" * ($header.Length + 5)) -ForegroundColor DarkGray

    foreach ($metric in @("NavigateMs", "SnapshotMs", "TextMs")) {
        $row = "{0,-20}" -f $metric.Replace("Ms", " (ms)")
        foreach ($eng in $engines) {
            $vals = $eng.Data.Results | Where-Object { $_.$metric -gt 0 } | ForEach-Object { $_.$metric }
            if ($vals.Count -gt 0) {
                $avg = [math]::Round(($vals | Measure-Object -Average).Average, 0)
                $row += " {0,15}" -f $avg
            } else {
                $row += " {0,15}" -f "N/A"
            }
        }
        Write-Host $row -ForegroundColor Yellow
    }

    # Total
    $row = "{0,-20}" -f "Total (ms)"
    foreach ($eng in $engines) {
        $total = 0
        foreach ($metric in @("NavigateMs", "SnapshotMs", "TextMs")) {
            $vals = $eng.Data.Results | Where-Object { $_.$metric -gt 0 } | ForEach-Object { $_.$metric }
            if ($vals.Count -gt 0) {
                $total += [math]::Round(($vals | Measure-Object -Average).Average, 0)
            }
        }
        $row += " {0,15}" -f $total
    }
    Write-Host $row -ForegroundColor Cyan

    Write-Host ""
}

Write-Host "Done." -ForegroundColor Green
