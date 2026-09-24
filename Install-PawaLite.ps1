<#
.SYNOPSIS
  Installs everything Pawa-Lite(Beta)V2 needs: Python + pip deps,
  VC++ runtime, and Windows Defender exclusions (false-positive prone).

  Run normally (no admin shell needed) - it self-elevates via UAC:
    powershell -ExecutionPolicy Bypass -File Install-PawaLite.ps1
#>
param(
  [string]$RepoDir = $PSScriptRoot,
  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Pawa-Lite(Beta)V2')
)

$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  ([Security.Principal.WindowsPrincipal]$id).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
  Write-Host '[*] Requesting admin rights (needed for Defender exclusions)...'
  $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  Start-Process powershell.exe -ArgumentList $args -Verb RunAs -Wait
  exit $LASTEXITCODE
}

Write-Host '=== Pawa-Lite(Beta)V2 setup ===' -ForegroundColor Cyan

# 1. Python ---------------------------------------------------------------
$py = Get-Command py -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
if (-not $py) {
  Write-Host '[*] Installing Python via winget...'
  winget install --silent --accept-package-agreements --accept-source-agreements Python.Python.3.14
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
  $py = Get-Command py -ErrorAction SilentlyContinue
  if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
}
if (-not $py) { throw 'Python not found even after install. Install it manually: https://www.python.org/downloads/' }
Write-Host ("[+] Python: " + (& $py.Source --version 2>&1 | Select-Object -First 1))

# 2. pip deps -------------------------------------------------------------
$deps = @('pymem', 'pywin32', 'pydirectinput', 'requests', 'pyperclip',
          'psutil', 'zstandard', 'websocket-client')
Write-Host '[*] Installing pip deps (this takes a bit)...'
& $py.Source -m pip install --upgrade pip | Out-Null
& $py.Source -m pip install @deps
if ($LASTEXITCODE -ne 0) { throw 'pip install failed' }
Write-Host '[+] pip deps ok'

# 3. VC++ runtime (Tauri/WebView2 apps need it on bare systems) ------------
Write-Host '[*] Ensuring VC++ runtime...'
winget install --silent --accept-package-agreements --accept-source-agreements Microsoft.VCRedist.2015+.x64 2>$null
Write-Host '[+] VC++ runtime ok (or already present)'

# 4. Defender exclusions (false positives: injector-like behavior) ---------
$paths = @(
  $InstallDir,
  (Join-Path $env:APPDATA 'Pawa-Lite-BetaV2'),
  $RepoDir
) | Where-Object { $_ -and $_.Trim() -ne '' }

foreach ($p in $paths) {
  if (-not (Test-Path -LiteralPath $p)) {
    New-Item -ItemType Directory -Path $p -Force | Out-Null
  }
  try {
    Add-MpPreference -ExclusionPath $p -ErrorAction Stop
    Write-Host ("[+] Defender exclusion: " + $p) -ForegroundColor Green
  } catch {
    Write-Host ("[!] Exclusion failed for " + $p + ': ' + $_.Exception.Message) -ForegroundColor Yellow
  }
}

Write-Host ''
Write-Host '=== Done. Install the UI with the Setup exe, then Attach. ===' -ForegroundColor Cyan
Write-Host 'If Defender still quarantines, restore from Protection History'
Write-Host '(exclusions prevent future hits, not past ones).'
