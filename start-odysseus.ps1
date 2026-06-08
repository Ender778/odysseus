#Requires -Version 5.1
<#
  Odysseus - all-in-one native launcher (Windows).

  One double-click to bring up the whole stack:
    1. Make sure Docker is running (starts Docker Desktop if needed).
    2. Start the dependency containers defined in docker-compose.yml:
         - chromadb  (vector memory)   :8100
         - searxng   (web search)      :8080
         - ntfy      (notifications)   :8091
    3. Hand off to launch-windows.ps1, which creates/updates the venv,
       runs first-time setup, and starts the native Odysseus server.
    4. Open http://localhost:<port> in your browser once it's listening.

  The Odysseus app itself runs NATIVELY (Python venv) for best GPU/Cookbook
  support; only its dependencies run in Docker. Press Ctrl+C in this window
  to stop the app. The Docker dependency containers keep running with
  `restart: unless-stopped`; stop them with:  docker compose stop

  Usage:
    powershell -ExecutionPolicy Bypass -File .\start-odysseus.ps1
    powershell -ExecutionPolicy Bypass -File .\start-odysseus.ps1 -Port 7000 -BindHost 127.0.0.1
    powershell -ExecutionPolicy Bypass -File .\start-odysseus.ps1 -NoBrowser
#>
param(
    [int]$Port = 7000,
    [string]$BindHost = "127.0.0.1",
    [switch]$NoBrowser,
    # By default, stopping the app (in-app "Close" button or Ctrl+C) also stops
    # the dependency containers. Pass -KeepDocker to leave them running.
    [switch]$KeepDocker
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Write-Step($msg) { Write-Host ""; Write-Host ("==> " + $msg) -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host ("    " + $msg) -ForegroundColor Gray }
function Write-Warn($msg) { Write-Host ("[warn] " + $msg) -ForegroundColor Yellow }
function Fail($msg) {
    Write-Host ""
    Write-Host ("ERROR: " + $msg) -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

function Test-Docker {
    # Note: under $ErrorActionPreference='Stop', redirecting a native command's
    # stderr (e.g. `*> $null`) wraps its output in an ErrorRecord and throws in
    # Windows PowerShell 5.1 even on success. Suppress locally and check the
    # real exit code instead of relying on $?.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        docker info 2>$null 1>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Test-Port([int]$p) {
    return [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# 0. If Odysseus is already serving, just open the browser and exit.
# ---------------------------------------------------------------------------
if (Test-Port $Port) {
    Write-Step "Odysseus already running on port $Port"
    if (-not $NoBrowser) { Start-Process "http://localhost:$Port" }
    Write-Info "Nothing to do. Close this window."
    Read-Host "Press Enter to exit"
    exit 0
}

# ---------------------------------------------------------------------------
# 1. Ensure Docker is up (dependencies run as containers).
# ---------------------------------------------------------------------------
Write-Step "Checking Docker"
if (-not (Test-Docker)) {
    Write-Warn "Docker isn't responding. Attempting to start Docker Desktop..."
    $desktop = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $desktop) {
        Start-Process $desktop | Out-Null
        Write-Info "Waiting for the Docker engine (up to ~120s)..."
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 2
            if (Test-Docker) { break }
        }
    }
    if (-not (Test-Docker)) {
        Fail "Docker Desktop isn't running. Start it and re-run this launcher. (Dependencies like ChromaDB run in Docker.)"
    }
}
Write-Info "Docker is up."

# ---------------------------------------------------------------------------
# 2. Start dependency containers from docker-compose.yml (not the app).
# ---------------------------------------------------------------------------
Write-Step "Starting dependency services (ChromaDB, SearXNG, ntfy)"
docker compose up -d chromadb searxng ntfy
if ($LASTEXITCODE -ne 0) {
    Write-Warn "One or more dependency services failed to start."
    Write-Warn "Continuing anyway - memory, search, or notifications may be degraded."
}

Write-Info "Waiting for ChromaDB on :8100 ..."
# Use 127.0.0.1 (not localhost): Chroma is published on 127.0.0.1 (IPv4 only),
# but "localhost" resolves to ::1 first on Windows and the IPv6 attempt can hang
# until the timeout, producing a false "not ready" warning.
$chromaOk = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:8100/api/v2/heartbeat" -TimeoutSec 2 *> $null
        $chromaOk = $true; break
    } catch { Start-Sleep -Seconds 1 }
}
if ($chromaOk) { Write-Info "ChromaDB is ready." } else { Write-Warn "ChromaDB did not answer in time; vector memory may start DEGRADED." }

# ---------------------------------------------------------------------------
# 3. Open the browser once the app is listening (background watcher).
# ---------------------------------------------------------------------------
if (-not $NoBrowser) {
    Start-Job -Name "odysseus-open-browser" -ScriptBlock {
        param($p)
        for ($i = 0; $i -lt 180; $i++) {
            if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) {
                Start-Process "http://localhost:$p"
                break
            }
            Start-Sleep -Seconds 1
        }
    } -ArgumentList $Port | Out-Null
}

# ---------------------------------------------------------------------------
# 4. Launch the native Odysseus server (foreground; Ctrl+C to stop).
# ---------------------------------------------------------------------------
Write-Step "Launching Odysseus (this window stays open; Ctrl+C to stop)"
& "$PSScriptRoot\launch-windows.ps1" -Port $Port -BindHost $BindHost

# Cleanup the browser watcher if the server exited quickly.
Get-Job -Name "odysseus-open-browser" -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 5. The server has exited (in-app "Close", Ctrl+C, or crash). Tear down the
#    dependency containers we started, so closing the app closes the whole
#    stack. Pass -KeepDocker to skip this. Docker Desktop itself is left
#    running (stopping it is a heavier action; quit it from the tray if wanted).
# ---------------------------------------------------------------------------
if (-not $KeepDocker) {
    if (Test-Docker) {
        Write-Step "Stopping dependency services (ChromaDB, SearXNG, ntfy)"
        docker compose stop
        Write-Info "Dependency containers stopped. Run the launcher again to bring everything back."
    } else {
        Write-Info "Docker not reachable; skipping container shutdown."
    }
}
