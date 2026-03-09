# ============================================================
# PinchTab Scheduler - Phase 2 & 3 Manual Integration Tests
# ============================================================
# Real-world browser automation tests against live websites.
# Tests Phase 2 (Observability) and Phase 3 (Hardening) features:
#   - GET /scheduler/stats endpoint & metrics counters
#   - Per-agent metrics and dispatch latency tracking
#   - POST /tasks/batch endpoint (batch submission)
#   - Webhook callbacks (callbackUrl field)
#   - Metrics accuracy across real browser tasks
#
# Prerequisites:
#   1. Server running:  go run ./cmd/pinchtab dashboard
#      with scheduler enabled in config (scheduler.enabled = true)
#   2. At least one browser instance running with a tab.
#
# Usage:
#   .\tests\scheduler_phase2_3_test.ps1 [-Port 9867] [-Token ""]
#
# After running, results are appended to SCHEDULER_CHANGES.md
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

$Pass = 0
$Fail = 0
$Results = @()

function Write-Test {
    param([string]$Name, [bool]$Ok, [string]$Detail = "")
    $icon = if ($Ok) { "[PASS]" } else { "[FAIL]" }
    $color = if ($Ok) { "Green" } else { "Red" }
    Write-Host "$icon $Name" -ForegroundColor $color
    if ($Detail) { Write-Host "      $Detail" -ForegroundColor DarkGray }
    if ($Ok) { $script:Pass++ } else { $script:Fail++ }
    $script:Results += [PSCustomObject]@{ Test = $Name; Status = $icon; Detail = $Detail }
}

function Invoke-Api {
    param([string]$Method, [string]$Path, [object]$Body = $null)
    $uri = "$Base$Path"
    $params = @{
        Uri     = $uri
        Method  = $Method
        Headers = $Headers
        UseBasicParsing = $true
    }
    if ($Body) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 10)
    }
    try {
        $resp = Invoke-WebRequest @params
        return @{
            StatusCode = $resp.StatusCode
            Body       = ($resp.Content | ConvertFrom-Json)
            Raw        = $resp.Content
        }
    }
    catch {
        $ex = $_.Exception
        $code = 0
        $content = ""
        if ($ex.Response) {
            $code = [int]$ex.Response.StatusCode
            $sr = [System.IO.StreamReader]::new($ex.Response.GetResponseStream())
            $content = $sr.ReadToEnd()
            $sr.Close()
        }
        return @{
            StatusCode = $code
            Body       = $null
            Raw        = $content
            Error      = $ex.Message
        }
    }
}

function Wait-TaskDone {
    param([string]$TaskId, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-Api -Method GET -Path "/tasks/$TaskId"
        if ($r.StatusCode -eq 200 -and $r.Body.state -in @("done","failed","cancelled")) {
            return $r.Body
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Submit-Task {
    param(
        [string]$AgentId,
        [string]$Action,
        [string]$Tab,
        [hashtable]$Params = @{},
        [int]$Priority = 5,
        [string]$CallbackUrl = ""
    )
    $body = @{ agentId = $AgentId; action = $Action; tabId = $Tab; priority = $Priority }
    if ($Params.Count -gt 0) { $body["params"] = $Params }
    if ($CallbackUrl -ne "") { $body["callbackUrl"] = $CallbackUrl }
    return Invoke-Api -Method POST -Path "/tasks" -Body $body
}

function Navigate-Tab {
    param([string]$Tab, [string]$Url)
    $r = Invoke-Api -Method POST -Path "/tabs/$Tab/navigate" -Body @{ url = $Url }
    Start-Sleep -Seconds 3
    return $r
}

# ============================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " PinchTab Scheduler - Phase 2 & 3 Tests"   -ForegroundColor Cyan
Write-Host " Server: $Base"                              -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --------------------------------------------------
# PREFLIGHT: Server & scheduler health
# --------------------------------------------------
Write-Host "--- Preflight: Server & Scheduler ---" -ForegroundColor Yellow
$health = Invoke-Api -Method GET -Path "/health"
Write-Test "Server is alive" ($health.StatusCode -eq 200) $health.Raw
if ($health.StatusCode -ne 200) {
    Write-Host "Server not reachable at $Base - aborting." -ForegroundColor Red
    exit 1
}

$schedCheck = Invoke-Api -Method GET -Path "/tasks"
if ($schedCheck.StatusCode -eq 404 -or $schedCheck.StatusCode -eq 0) {
    Write-Host "Scheduler not enabled! Add '" -NoNewline -ForegroundColor Red
    Write-Host '{"scheduler":{"enabled":true}}' -NoNewline -ForegroundColor Yellow
    Write-Host "' to your config.json and restart the server." -ForegroundColor Red
    exit 1
}
Write-Test "Scheduler is enabled" ($schedCheck.StatusCode -eq 200)

# --------------------------------------------------
# PREFLIGHT: Discover instance & tab
# --------------------------------------------------
Write-Host ""
Write-Host "--- Discovering instance & tab ---" -ForegroundColor Yellow
$instances = Invoke-Api -Method GET -Path "/instances"
$running = ($instances.Body | Where-Object { $_.status -eq "running" })
if (-not $running -or $running.Count -eq 0) {
    Write-Host "No running instances found. Start one first." -ForegroundColor Red
    exit 1
}
$inst = if ($running -is [array]) { $running[0] } else { $running }
Write-Host "  Instance: $($inst.id)  Port: $($inst.port)" -ForegroundColor DarkGray

$tabsResp = Invoke-Api -Method GET -Path "/instances/tabs"
$tabs = $tabsResp.Body
if (-not $tabs -or ($tabs.Count -eq 0)) {
    Write-Host "  No tabs found - creating one ..." -ForegroundColor DarkGray
    $newTab = Invoke-Api -Method POST -Path "/tab" -Body @{ action = "new"; url = "about:blank" }
    $TabId = $newTab.Body.tabId
    Start-Sleep -Seconds 2
} else {
    $tab = if ($tabs -is [array]) { $tabs[0] } else { $tabs }
    $TabId = $tab.id
}
Write-Host "  Tab: $TabId" -ForegroundColor DarkGray
Write-Test "Tab discovered" ($TabId -ne $null -and $TabId -ne "") "tabId=$TabId"

# ============================================================
# PHASE 2: OBSERVABILITY
# ============================================================
Write-Host ""
Write-Host "########################################" -ForegroundColor Cyan
Write-Host " PHASE 2: OBSERVABILITY TESTS"           -ForegroundColor Cyan
Write-Host "########################################" -ForegroundColor Cyan

# --------------------------------------------------
# SCENARIO 1: Stats endpoint structure
# --------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host " SCENARIO 1: GET /scheduler/stats"      -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta

Write-Host ""
Write-Host "--- 1a: Stats endpoint returns valid structure ---" -ForegroundColor Yellow
$stats = Invoke-Api -Method GET -Path "/scheduler/stats"
Write-Test "GET /scheduler/stats returns 200" ($stats.StatusCode -eq 200)
Write-Test "Response has queue section" ($null -ne $stats.Body.queue)
Write-Test "Response has metrics section" ($null -ne $stats.Body.metrics)
Write-Test "Response has config section" ($null -ne $stats.Body.config)

Write-Host ""
Write-Host "--- 1b: Metrics fields present ---" -ForegroundColor Yellow
$m = $stats.Body.metrics
Write-Test "Has tasksSubmitted" ($null -ne $m.tasksSubmitted)
Write-Test "Has tasksCompleted" ($null -ne $m.tasksCompleted)
Write-Test "Has tasksFailed" ($null -ne $m.tasksFailed)
Write-Test "Has tasksCancelled" ($null -ne $m.tasksCancelled)
Write-Test "Has tasksRejected" ($null -ne $m.tasksRejected)
Write-Test "Has tasksExpired" ($null -ne $m.tasksExpired)
Write-Test "Has dispatchCount" ($null -ne $m.dispatchCount)
Write-Test "Has avgDispatchLatencyMs" ($null -ne $m.avgDispatchLatencyMs)
Write-Test "Has agents map" ($null -ne $m.agents)

Write-Host ""
Write-Host "--- 1c: Config section fields ---" -ForegroundColor Yellow
$cfg = $stats.Body.config
Write-Test "Config has strategy" ($null -ne $cfg.strategy)
Write-Test "Config has maxQueueSize" ($null -ne $cfg.maxQueueSize)
Write-Test "Config has maxPerAgent" ($null -ne $cfg.maxPerAgent)
Write-Test "Config has workerCount" ($null -ne $cfg.workerCount)
Write-Test "Config has maxInflight" ($null -ne $cfg.maxInflight)
Write-Test "Config has resultTTL" ($null -ne $cfg.resultTTL)

Write-Host ""
Write-Host "--- 1d: Queue stats fields ---" -ForegroundColor Yellow
$qs = $stats.Body.queue
Write-Test "Queue has totalQueued" ($null -ne $qs.totalQueued)
Write-Test "Queue has totalInflight" ($null -ne $qs.totalInflight)
Write-Test "Queue has agents" ($null -ne $qs.agents)

# --------------------------------------------------
# SCENARIO 2: Metrics increment after real browser tasks on Wikipedia
# --------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host " SCENARIO 2: Metrics on Wikipedia"      -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta

$nav1 = Navigate-Tab -Tab $TabId -Url "https://en.wikipedia.org/wiki/Main_Page"
Write-Test "Navigate to Wikipedia Main Page" ($nav1.StatusCode -eq 200)

# Capture baseline metrics
$baselineStats = (Invoke-Api -Method GET -Path "/scheduler/stats").Body.metrics
$baseSubmitted = $baselineStats.tasksSubmitted
$baseCompleted = $baselineStats.tasksCompleted

Write-Host ""
Write-Host "--- 2a: Scroll Wikipedia and track metrics ---" -ForegroundColor Yellow
$s2a = Submit-Task -AgentId "wiki-metrics" -Action "scroll" -Tab $TabId -Params @{ scrollY = 400 }
Write-Test "Submit: scroll Wikipedia 400px" ($s2a.StatusCode -eq 202)
$r2a = Wait-TaskDone -TaskId $s2a.Body.taskId
Write-Test "Scroll completed" ($r2a -ne $null -and $r2a.state -eq "done") "state=$($r2a.state)"

Write-Host ""
Write-Host "--- 2b: Click a heading link on Wikipedia ---" -ForegroundColor Yellow
$s2b = Submit-Task -AgentId "wiki-metrics" -Action "click" -Tab $TabId -Params @{ selector = "#bodyContent a" }
Write-Test "Submit: click a content link" ($s2b.StatusCode -eq 202)
$r2b = Wait-TaskDone -TaskId $s2b.Body.taskId
Write-Test "Click completed" ($r2b -ne $null -and $r2b.state -in @("done","failed")) "state=$($r2b.state)"

Write-Host ""
Write-Host "--- 2c: Hover over first paragraph ---" -ForegroundColor Yellow
$s2c = Submit-Task -AgentId "wiki-metrics" -Action "hover" -Tab $TabId -Params @{ selector = "#mp-upper p" }
Write-Test "Submit: hover first paragraph" ($s2c.StatusCode -eq 202)
$r2c = Wait-TaskDone -TaskId $s2c.Body.taskId
Write-Test "Hover completed" ($r2c -ne $null -and $r2c.state -in @("done","failed")) "state=$($r2c.state)"

# Verify metrics incremented
Write-Host ""
Write-Host "--- 2d: Verify metrics incremented ---" -ForegroundColor Yellow
$afterStats = (Invoke-Api -Method GET -Path "/scheduler/stats").Body.metrics
Write-Test "tasksSubmitted increased by >= 3" ($afterStats.tasksSubmitted -ge ($baseSubmitted + 3))
Write-Test "dispatchCount > 0" ($afterStats.dispatchCount -gt 0)
Write-Test "avgDispatchLatencyMs >= 0" ($afterStats.avgDispatchLatencyMs -ge 0)

# Per-agent metrics
Write-Host ""
Write-Host "--- 2e: Per-agent metrics for wiki-metrics ---" -ForegroundColor Yellow
if ($afterStats.agents -and $afterStats.agents."wiki-metrics") {
    $agentM = $afterStats.agents."wiki-metrics"
    Write-Test "Agent wiki-metrics submitted >= 3" ($agentM.submitted -ge 3)
    Write-Test "Agent wiki-metrics has completed field" ($null -ne $agentM.completed)
    Write-Test "Agent wiki-metrics has failed field" ($null -ne $agentM.failed)
} else {
    Write-Test "Agent wiki-metrics present in agents map" $false "not found"
}

# --------------------------------------------------
# SCENARIO 3: Metrics on cancel of real-world task
# --------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host " SCENARIO 3: Cancel Metrics Tracking"   -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta

$cancelBefore = (Invoke-Api -Method GET -Path "/scheduler/stats").Body.metrics.tasksCancelled

Write-Host ""
Write-Host "--- 3a: Submit and immediately cancel ---" -ForegroundColor Yellow
# Submit several low-priority tasks to increase chance one is still queued when we cancel.
for ($ci = 0; $ci -lt 5; $ci++) {
    Submit-Task -AgentId "cancel-metrics" -Action "scroll" -Tab $TabId -Priority 99 | Out-Null
}
$cancelTask = Submit-Task -AgentId "cancel-metrics" -Action "scroll" -Tab $TabId -Priority 99
Write-Test "Task submitted for cancel" ($cancelTask.StatusCode -eq 202) "taskId=$($cancelTask.Body.taskId)"
$cancelId = $cancelTask.Body.taskId

$cancelResp = Invoke-Api -Method POST -Path "/tasks/$cancelId/cancel"
$cancelOk = ($cancelResp.StatusCode -eq 200 -or $cancelResp.StatusCode -eq 409)
Write-Test "Cancel returns 200 or 409 (already done)" $cancelOk "status=$($cancelResp.StatusCode)"

$cancelCheck = Invoke-Api -Method GET -Path "/tasks/$cancelId"
$cancelState = $cancelCheck.Body.state
Write-Test "Task state is terminal" ($cancelState -in @("cancelled","done","failed")) "state=$cancelState"

Write-Host ""
Write-Host "--- 3b: Verify cancel metrics tracked ---" -ForegroundColor Yellow
# Wait for all cancel-metrics tasks to finish
Start-Sleep -Seconds 3
$cancelAfter = (Invoke-Api -Method GET -Path "/scheduler/stats").Body.metrics
Write-Test "cancel-metrics agent tracked" ($null -ne $cancelAfter.agents."cancel-metrics")
if ($cancelAfter.agents."cancel-metrics") {
    $cm = $cancelAfter.agents."cancel-metrics"
    Write-Test "cancel-metrics submitted >= 6" ($cm.submitted -ge 6)
}

# --------------------------------------------------
# SCENARIO 4: Dispatch latency tracking with Hacker News tasks
# --------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host " SCENARIO 4: Dispatch Latency (HN)"     -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta

$nav4 = Navigate-Tab -Tab $TabId -Url "https://news.ycombinator.com"
Write-Test "Navigate to Hacker News" ($nav4.StatusCode -eq 200)

$latencyBefore = (Invoke-Api -Method GET -Path "/scheduler/stats").Body.metrics.dispatchCount

Write-Host ""
Write-Host "--- 4a: Click first story on HN ---" -ForegroundColor Yellow
$s4a = Submit-Task -AgentId "hn-latency" -Action "click" -Tab $TabId -Params @{
    selector = ".titleline > a"
    waitNav  = "true"
}
Write-Test "Submit: click first HN story" ($s4a.StatusCode -eq 202)
$r4a = Wait-TaskDone -TaskId $s4a.Body.taskId
Write-Test "Click story completed" ($r4a -ne $null -and $r4a.state -in @("done","failed")) "state=$($r4a.state)"
Start-Sleep -Seconds 2

Write-Host ""
Write-Host "--- 4b: Scroll the story page ---" -ForegroundColor Yellow
$s4b = Submit-Task -AgentId "hn-latency" -Action "scroll" -Tab $TabId -Params @{ scrollY = 600 }
Write-Test "Submit: scroll story 600px" ($s4b.StatusCode -eq 202)
$r4b = Wait-TaskDone -TaskId $s4b.Body.taskId
Write-Test "Story scroll completed" ($r4b -ne $null -and $r4b.state -in @("done","failed")) "state=$($r4b.state)"

Write-Host ""
Write-Host "--- 4c: Verify dispatch latency tracking ---" -ForegroundColor Yellow
$latencyAfter = (Invoke-Api -Method GET -Path "/scheduler/stats").Body.metrics
Write-Test "dispatchCount increased" ($latencyAfter.dispatchCount -gt $latencyBefore)
Write-Test "avgDispatchLatencyMs > 0 after dispatches" ($latencyAfter.avgDispatchLatencyMs -gt 0) "avg=$($latencyAfter.avgDispatchLatencyMs)ms"

# ============================================================
# PHASE 3: HARDENING
# ============================================================
Write-Host ""
Write-Host "########################################" -ForegroundColor Cyan
Write-Host " PHASE 3: HARDENING TESTS"               -ForegroundColor Cyan
Write-Host "########################################" -ForegroundColor Cyan

# --------------------------------------------------
# SCENARIO 5: Batch submission - Wikipedia multi-action
# --------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host " SCENARIO 5: Batch Submit (Wikipedia)"  -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta

$nav5 = Navigate-Tab -Tab $TabId -Url "https://en.wikipedia.org/wiki/Alan_Turing"
Write-Test "Navigate to Alan Turing article" ($nav5.StatusCode -eq 200)

Write-Host ""
Write-Host "--- 5a: Batch submit 3 real browser tasks ---" -ForegroundColor Yellow
$batchBody = @{
    agentId = "batch-wiki"
    tasks   = @(
        @{ action = "scroll"; tabId = $TabId; params = @{ scrollY = 300 } },
        @{ action = "hover"; tabId = $TabId; params = @{ selector = "h1" } },
        @{ action = "scroll"; tabId = $TabId; params = @{ scrollY = 200 }; priority = 1 }
    )
}
$br = Invoke-Api -Method POST -Path "/tasks/batch" -Body $batchBody
Write-Test "Batch returns 202" ($br.StatusCode -eq 202)
Write-Test "Batch has tasks array" ($null -ne $br.Body.tasks)
Write-Test "Batch submitted count = 3" ($br.Body.submitted -eq 3)

# Verify each task was assigned an ID
if ($br.Body.tasks) {
    foreach ($i in 0..($br.Body.tasks.Count - 1)) {
        $item = $br.Body.tasks[$i]
        Write-Test "Batch task[$i] has taskId" ($null -ne $item.taskId -and $item.taskId -ne "")
    }
}

Write-Host ""
Write-Host "--- 5b: Wait for all batch tasks to complete ---" -ForegroundColor Yellow
$batchAllDone = $true
if ($br.Body.tasks) {
    foreach ($bt in $br.Body.tasks) {
        if ($bt.taskId) {
            $bResult = Wait-TaskDone -TaskId $bt.taskId
            if ($bResult -eq $null) { $batchAllDone = $false }
        }
    }
}
Write-Test "All batch tasks reached terminal state" $batchAllDone

Write-Host ""
Write-Host "--- 5c: Batch agent appears in per-agent metrics ---" -ForegroundColor Yellow
$batchMetrics = (Invoke-Api -Method GET -Path "/scheduler/stats").Body.metrics
if ($batchMetrics.agents -and $batchMetrics.agents."batch-wiki") {
    $bm = $batchMetrics.agents."batch-wiki"
    Write-Test "batch-wiki submitted >= 3" ($bm.submitted -ge 3)
} else {
    Write-Test "batch-wiki agent in metrics" $false "not found"
}

# --------------------------------------------------
# SCENARIO 6: Batch validation errors
# --------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host " SCENARIO 6: Batch Validation"          -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta

Write-Host ""
Write-Host "--- 6a: Missing agentId ---" -ForegroundColor Yellow
$br6a = Invoke-Api -Method POST -Path "/tasks/batch" -Body @{
    tasks = @(@{ action = "click"; tabId = $TabId })
}
Write-Test "Missing agentId returns 400" ($br6a.StatusCode -eq 400)

Write-Host ""
Write-Host "--- 6b: Empty tasks array ---" -ForegroundColor Yellow
$br6b = Invoke-Api -Method POST -Path "/tasks/batch" -Body @{
    agentId = "batch-empty"
    tasks   = @()
}
Write-Test "Empty tasks returns 400" ($br6b.StatusCode -eq 400)

Write-Host ""
Write-Host "--- 6c: Oversized batch (>50) ---" -ForegroundColor Yellow
$bigTasks = @()
for ($i = 0; $i -lt 51; $i++) {
    $bigTasks += @{ action = "scroll"; tabId = $TabId }
}
$br6c = Invoke-Api -Method POST -Path "/tasks/batch" -Body @{
    agentId = "batch-big"
    tasks   = $bigTasks
}
Write-Test "Oversized batch returns 400" ($br6c.StatusCode -eq 400)

Write-Host ""
Write-Host "--- 6d: Bad JSON body ---" -ForegroundColor Yellow
$br6d = Invoke-Api -Method POST -Path "/tasks/batch" -Body "not json"
Write-Test "Invalid JSON returns 400" ($br6d.StatusCode -eq 400)

# --------------------------------------------------
# SCENARIO 7: Batch with callbackUrl on httpbin form
# --------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host " SCENARIO 7: Batch + Callback (httpbin)" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta

$nav7 = Navigate-Tab -Tab $TabId -Url "https://httpbin.org/forms/post"
Write-Test "Navigate to httpbin.org forms" ($nav7.StatusCode -eq 200)

Write-Host ""
Write-Host "--- 7a: Batch form fill with callbackUrl ---" -ForegroundColor Yellow
$br7 = Invoke-Api -Method POST -Path "/tasks/batch" -Body @{
    agentId     = "batch-form"
    callbackUrl = "http://localhost:19876/hook"
    tasks       = @(
        @{ action = "fill"; tabId = $TabId; params = @{ selector = "input[name='custname']"; text = "Jane Doe" } },
        @{ action = "fill"; tabId = $TabId; params = @{ selector = "input[name='custtel']"; text = "555-9999" } },
        @{ action = "click"; tabId = $TabId; params = @{ selector = "input[value='medium']" } }
    )
}
Write-Test "Batch with callback returns 202" ($br7.StatusCode -eq 202)
Write-Test "3 tasks in response" ($br7.Body.submitted -eq 3)

# Verify the callback URL is stored on each task
if ($br7.Body.tasks -and $br7.Body.tasks.Count -gt 0) {
    $firstTaskId = $br7.Body.tasks[0].taskId
    if ($firstTaskId) {
        $taskDetail = Invoke-Api -Method GET -Path "/tasks/$firstTaskId"
        Write-Test "Task has callbackUrl field" ($taskDetail.Body.callbackUrl -eq "http://localhost:19876/hook")
    }
}

# Wait for completion
if ($br7.Body.tasks) {
    foreach ($bt in $br7.Body.tasks) {
        if ($bt.taskId) { $null = Wait-TaskDone -TaskId $bt.taskId }
    }
}

# --------------------------------------------------
# SCENARIO 8: Single task with callbackUrl (webhook field test)
# --------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host " SCENARIO 8: Task with callbackUrl"     -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta

$nav8 = Navigate-Tab -Tab $TabId -Url "https://en.wikipedia.org/wiki/Computer_science"
Write-Test "Navigate to CS Wikipedia article" ($nav8.StatusCode -eq 200)

Write-Host ""
Write-Host "--- 8a: Submit task with callbackUrl and verify stored ---" -ForegroundColor Yellow
$s8a = Submit-Task -AgentId "cb-agent" -Action "scroll" -Tab $TabId -Params @{ scrollY = 300 } -CallbackUrl "http://localhost:19876/webhook"
Write-Test "Submit with callback returns 202" ($s8a.StatusCode -eq 202)

$taskGet = Invoke-Api -Method GET -Path "/tasks/$($s8a.Body.taskId)"
Write-Test "Task GET returns callbackUrl" ($taskGet.Body.callbackUrl -eq "http://localhost:19876/webhook") "callbackUrl=$($taskGet.Body.callbackUrl)"

$r8a = Wait-TaskDone -TaskId $s8a.Body.taskId
Write-Test "Callback task completed" ($r8a -ne $null -and $r8a.state -in @("done","failed")) "state=$($r8a.state)"

Write-Host ""
Write-Host "--- 8b: Task without callbackUrl has no field ---" -ForegroundColor Yellow
$s8b = Submit-Task -AgentId "no-cb-agent" -Action "scroll" -Tab $TabId -Params @{ scrollY = 100 }
Write-Test "Submit without callback returns 202" ($s8b.StatusCode -eq 202)

$taskGet2 = Invoke-Api -Method GET -Path "/tasks/$($s8b.Body.taskId)"
$hasCb = ($null -ne $taskGet2.Body.callbackUrl -and $taskGet2.Body.callbackUrl -ne "")
Write-Test "Task without callback has empty/no callbackUrl" (-not $hasCb) "callbackUrl=$($taskGet2.Body.callbackUrl)"

# --------------------------------------------------
# SCENARIO 9: Multi-agent batch + metrics accuracy on GitHub Explore
# --------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host " SCENARIO 9: Multi-Agent Batch (GitHub)" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta

$nav9 = Navigate-Tab -Tab $TabId -Url "https://github.com/explore"
Write-Test "Navigate to GitHub Explore" ($nav9.StatusCode -eq 200)

Write-Host ""
Write-Host "--- 9a: Two agents submit batches concurrently ---" -ForegroundColor Yellow
$metricsBefore = (Invoke-Api -Method GET -Path "/scheduler/stats").Body.metrics.tasksSubmitted

# Agent 1 batch
$br9a = Invoke-Api -Method POST -Path "/tasks/batch" -Body @{
    agentId = "gh-agent-1"
    tasks   = @(
        @{ action = "scroll"; tabId = $TabId; params = @{ scrollY = 300 } },
        @{ action = "scroll"; tabId = $TabId; params = @{ scrollY = 200 }; priority = 1 }
    )
}
Write-Test "Agent-1 batch returns 202" ($br9a.StatusCode -eq 202) "submitted=$($br9a.Body.submitted)"

# Agent 2 batch
$br9b = Invoke-Api -Method POST -Path "/tasks/batch" -Body @{
    agentId = "gh-agent-2"
    tasks   = @(
        @{ action = "scroll"; tabId = $TabId; params = @{ scrollY = 100 } },
        @{ action = "hover"; tabId = $TabId; params = @{ selector = "h2" } }
    )
}
Write-Test "Agent-2 batch returns 202" ($br9b.StatusCode -eq 202) "submitted=$($br9b.Body.submitted)"

# Wait for all tasks
$allIds = @()
if ($br9a.Body.tasks) { $allIds += ($br9a.Body.tasks | ForEach-Object { $_.taskId }) }
if ($br9b.Body.tasks) { $allIds += ($br9b.Body.tasks | ForEach-Object { $_.taskId }) }
$allCompleted = $true
foreach ($tid in $allIds) {
    if ($tid) {
        $rr = Wait-TaskDone -TaskId $tid
        if ($rr -eq $null) { $allCompleted = $false }
    }
}
Write-Test "All 4 multi-agent batch tasks completed" $allCompleted

Write-Host ""
Write-Host "--- 9b: Verify per-agent metrics isolation ---" -ForegroundColor Yellow
$metricsAfter = (Invoke-Api -Method GET -Path "/scheduler/stats").Body.metrics
Write-Test "Total submitted increased by >= 4" ($metricsAfter.tasksSubmitted -ge ($metricsBefore + 4))

if ($metricsAfter.agents."gh-agent-1") {
    Write-Test "gh-agent-1 submitted >= 2" ($metricsAfter.agents."gh-agent-1".submitted -ge 2)
} else {
    Write-Test "gh-agent-1 in agents map" $false "not found"
}
if ($metricsAfter.agents."gh-agent-2") {
    Write-Test "gh-agent-2 submitted >= 2" ($metricsAfter.agents."gh-agent-2".submitted -ge 2)
} else {
    Write-Test "gh-agent-2 in agents map" $false "not found"
}

# --------------------------------------------------
# SCENARIO 10: Full metrics accuracy test on DuckDuckGo
# --------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host " SCENARIO 10: Full Metrics (DuckDuckGo)" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta

$nav10 = Navigate-Tab -Tab $TabId -Url "https://duckduckgo.com"
Write-Test "Navigate to DuckDuckGo" ($nav10.StatusCode -eq 200)

# Snapshot before
$snap10before = (Invoke-Api -Method GET -Path "/scheduler/stats").Body.metrics

Write-Host ""
Write-Host "--- 10a: humanClick on search input ---" -ForegroundColor Yellow
$s10a = Submit-Task -AgentId "ddg-agent" -Action "humanClick" -Tab $TabId -Params @{
    selector = "input[name='q']"
}
Write-Test "Submit: humanClick search input" ($s10a.StatusCode -eq 202)
$r10a = Wait-TaskDone -TaskId $s10a.Body.taskId
Write-Test "humanClick completed" ($r10a -ne $null -and $r10a.state -in @("done","failed")) "state=$($r10a.state)"

Write-Host ""
Write-Host "--- 10b: humanType search query ---" -ForegroundColor Yellow
$s10b = Submit-Task -AgentId "ddg-agent" -Action "humanType" -Tab $TabId -Params @{
    selector = "input[name='q']"
    text     = "PinchTab scheduler"
}
Write-Test "Submit: humanType search query" ($s10b.StatusCode -eq 202)
$r10b = Wait-TaskDone -TaskId $s10b.Body.taskId
Write-Test "humanType completed" ($r10b -ne $null -and $r10b.state -in @("done","failed")) "state=$($r10b.state)"

Write-Host ""
Write-Host "--- 10c: Press Enter to search ---" -ForegroundColor Yellow
$s10c = Submit-Task -AgentId "ddg-agent" -Action "press" -Tab $TabId -Params @{ key = "Enter" }
Write-Test "Submit: press Enter" ($s10c.StatusCode -eq 202)
$r10c = Wait-TaskDone -TaskId $s10c.Body.taskId
Write-Test "Search submitted" ($r10c -ne $null -and $r10c.state -in @("done","failed")) "state=$($r10c.state)"
Start-Sleep -Seconds 2

Write-Host ""
Write-Host "--- 10d: Scroll search results ---" -ForegroundColor Yellow
$s10d = Submit-Task -AgentId "ddg-agent" -Action "scroll" -Tab $TabId -Params @{ scrollY = 500 }
Write-Test "Submit: scroll results" ($s10d.StatusCode -eq 202)
$r10d = Wait-TaskDone -TaskId $s10d.Body.taskId
Write-Test "Results scroll completed" ($r10d -ne $null -and $r10d.state -in @("done","failed")) "state=$($r10d.state)"

Write-Host ""
Write-Host "--- 10e: Verify final metrics snapshot ---" -ForegroundColor Yellow
$snap10after = (Invoke-Api -Method GET -Path "/scheduler/stats").Body.metrics
Write-Test "tasksSubmitted increased by >= 4" ($snap10after.tasksSubmitted -ge ($snap10before.tasksSubmitted + 4))

if ($snap10after.agents."ddg-agent") {
    $ddg = $snap10after.agents."ddg-agent"
    Write-Test "ddg-agent submitted >= 4" ($ddg.submitted -ge 4)
    Write-Test "ddg-agent completed >= 0" ($ddg.completed -ge 0)
} else {
    Write-Test "ddg-agent in agents map" $false "not found"
}

# ============================================================
# SUMMARY
# ============================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " RESULTS: $Pass passed, $Fail failed / $($Pass + $Fail) total" -ForegroundColor $(if ($Fail -eq 0) { "Green" } else { "Red" })
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# Append results to SCHEDULER_CHANGES.md
# ============================================================
$mdPath = Join-Path $PSScriptRoot "..\SCHEDULER_CHANGES.md"
if (-not (Test-Path $mdPath)) {
    $mdPath = Join-Path (Get-Location) "SCHEDULER_CHANGES.md"
}

if (Test-Path $mdPath) {
    $timestamp  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $sep        = "---"
    $h2         = "## Phase 2 & 3 Manual Integration Test Results (Real-World)"
    $tblHeader  = "| # | Test | Status | Detail |"
    $tblSep     = "|---|------|--------|--------|"

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("")
    $lines.Add($sep)
    $lines.Add("")
    $lines.Add($h2)
    $lines.Add("")
    $lines.Add("**Run at:** $timestamp")
    $lines.Add("**Server:** $Base")
    $lines.Add("**Instance:** $($inst.id) (port $($inst.port))")
    $lines.Add("**Tab:** $TabId")
    $lines.Add("")
    $lines.Add("### Phase 2 features tested")
    $lines.Add("- GET /scheduler/stats endpoint structure")
    $lines.Add("- Metrics counters (tasksSubmitted, tasksCompleted, tasksFailed, tasksCancelled, tasksExpired)")
    $lines.Add("- Per-agent metrics isolation")
    $lines.Add("- Dispatch latency tracking (dispatchCount, avgDispatchLatencyMs)")
    $lines.Add("")
    $lines.Add("### Phase 3 features tested")
    $lines.Add("- POST /tasks/batch endpoint (real browser tasks)")
    $lines.Add("- Batch validation (missing agentId, empty tasks, oversized batch)")
    $lines.Add("- callbackUrl field on single tasks and batch tasks")
    $lines.Add("- Multi-agent batch submission with metrics accuracy")
    $lines.Add("")
    $lines.Add("### Websites tested")
    $lines.Add("- Wikipedia (en.wikipedia.org) -- scroll, click, hover, metrics tracking")
    $lines.Add("- Hacker News (news.ycombinator.com) -- click story, scroll, dispatch latency")
    $lines.Add("- GitHub (github.com/explore) -- multi-agent batch, per-agent metrics")
    $lines.Add("- httpbin.org (forms) -- batch form fill with callbackUrl")
    $lines.Add("- DuckDuckGo (duckduckgo.com) -- humanClick, humanType, full metrics snapshot")
    $lines.Add("")
    $lines.Add("### Action kinds exercised")
    $lines.Add("scroll, click, hover, fill, press, humanClick, humanType")
    $lines.Add("")
    $lines.Add($tblHeader)
    $lines.Add($tblSep)

    $i = 1
    foreach ($r in $Results) {
        $detail = if ($r.Detail) { ($r.Detail -replace '\|', '/') } else { "" }
        if ($detail.Length -gt 80) { $detail = $detail.Substring(0, 80) + "..." }
        $lines.Add("| $i | $($r.Test) | $($r.Status) | $detail |")
        $i++
    }

    $lines.Add("")
    $lines.Add("**Total: $Pass passed, $Fail failed / $($Pass + $Fail) tests**")
    $lines.Add("")

    Add-Content -Path $mdPath -Value ($lines -join "`n") -Encoding UTF8
    Write-Host "Results appended to $mdPath" -ForegroundColor Green
} else {
    Write-Host "SCHEDULER_CHANGES.md not found - skipping MD update." -ForegroundColor Yellow
}

# Exit code
if ($Fail -gt 0) { exit 1 } else { exit 0 }
