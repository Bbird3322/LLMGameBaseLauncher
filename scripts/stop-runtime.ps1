param(
  [switch]$LlamaOnly,
  [switch]$GameOnly
)

$ErrorActionPreference = "Stop"

function Read-JsonFile {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  try {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Remove-StateFile {
  param([string]$Path)

  if (Test-Path -LiteralPath $Path) {
    Remove-Item -LiteralPath $Path -Force
  }
}

function Stop-TrackedProcess {
  param(
    [string]$Name,
    [string]$StateFile
  )

  $state = Read-JsonFile -Path $StateFile
  if (-not $state) {
    Write-Output "[INFO] $Name was not tracked."
    return
  }

  $entries = @()
  if ($state.pid) {
    $entries = @($state)
  } elseif ($state.processes) {
    $entries = @($state.processes)
  }

  if ($entries.Count -eq 0) {
    Write-Output "[INFO] $Name was not tracked."
    return
  }

  foreach ($entry in $entries) {
    if (-not $entry.pid) { continue }
    try {
      $process = Get-Process -Id ([int]$entry.pid) -ErrorAction Stop
      Stop-Process -Id $process.Id -Force -ErrorAction Stop
      Write-Output "[OK] Stopped $Name (PID $($process.Id))."
    } catch {
      Write-Output "[INFO] $Name was already stopped."
    }
  }

  Remove-StateFile -Path $StateFile
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$llamaStateFile = Join-Path $scriptDir "llama-server.state.json"
$gameStateFile = Join-Path $scriptDir "game-server.state.json"

if (-not $GameOnly) {
  Stop-TrackedProcess -Name "llama-server" -StateFile $llamaStateFile
}

if (-not $LlamaOnly) {
  Stop-TrackedProcess -Name "game server" -StateFile $gameStateFile
}
