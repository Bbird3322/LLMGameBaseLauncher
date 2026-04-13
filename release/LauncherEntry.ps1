param(
  [string]$RootDir = ""
)

$ErrorActionPreference = "Stop"

function Get-LauncherRoot {
  if (-not [string]::IsNullOrWhiteSpace($RootDir) -and (Test-Path -LiteralPath (Join-Path $RootDir "scripts\launch-llama-server.ps1"))) {
    return [string](Resolve-Path $RootDir)
  }

  if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot "..\scripts\launch-llama-server.ps1"))) {
    return [string](Resolve-Path (Join-Path $PSScriptRoot ".."))
  }

  if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot "scripts\launch-llama-server.ps1"))) {
    return [string](Resolve-Path $PSScriptRoot)
  }

  if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
    $baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if (Test-Path -LiteralPath (Join-Path $baseDir "..\scripts\launch-llama-server.ps1")) {
      return [string](Resolve-Path (Join-Path $baseDir ".."))
    }
    if (Test-Path -LiteralPath (Join-Path $baseDir "scripts\launch-llama-server.ps1")) {
      return [string](Resolve-Path $baseDir)
    }
  }

  return [string][System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\')
}

function ConvertTo-PowerShellLiteral {
  param([object]$Value)

  if ($null -eq $Value) {
    return '$null'
  }

  if ($Value -is [bool]) {
    return $(if ($Value) { '$true' } else { '$false' })
  }

  if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
    return [string]$Value
  }

  return "'" + ([string]$Value -replace "'", "''") + "'"
}

function Get-EncodedScriptInvocation {
  param(
    [string]$ScriptPath,
    [hashtable]$Parameters
  )

  $resolvedPath = [string](Resolve-Path $ScriptPath)
  $paramParts = @()
  foreach ($key in @($Parameters.Keys)) {
    $paramParts += ('-{0} {1}' -f $key, (ConvertTo-PowerShellLiteral -Value $Parameters[$key]))
  }

  $invokeTail = if ($paramParts.Count -gt 0) { ' ' + ($paramParts -join ' ') } else { '' }
  $command = @"
`$ErrorActionPreference = 'Stop'
`$scriptText = [System.IO.File]::ReadAllText($(ConvertTo-PowerShellLiteral -Value $resolvedPath), [System.Text.UTF8Encoding]::new(`$false))
& ([scriptblock]::Create(`$scriptText))$invokeTail
"@

  return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
}

function Write-StartupErrorReport {
  param(
    [string]$RootDir,
    [string]$Details
  )

  $logDir = Join-Path $RootDir "logs"
  $errorDir = Join-Path $logDir "error"
  if (-not (Test-Path -LiteralPath $errorDir)) {
    New-Item -ItemType Directory -Path $errorDir -Force | Out-Null
  }

  $reportPath = Join-Path $errorDir "startup-error.txt"
  $content = @(
    "Launcher failed.",
    ('=' * 48),
    $Details
  ) -join "`r`n"

  [System.IO.File]::WriteAllText($reportPath, $content + "`r`n", [System.Text.UTF8Encoding]::new($false))
  return $reportPath
}

function Start-StartupPopupProcess {
  param([string]$RootDir)

  $signalPath = Join-Path $RootDir "logs\startup-popup.signal"
  Remove-Item -LiteralPath $signalPath -Force -ErrorAction SilentlyContinue

  $popupScript = Join-Path $RootDir "scripts\startup-popup.ps1"
  if (-not (Test-Path -LiteralPath $popupScript -PathType Leaf)) {
    return $null
  }

  $popupProc = Start-Process -FilePath "powershell.exe" -ArgumentList @(
    "-NoProfile",
    "-STA",
    "-ExecutionPolicy", "Bypass",
    "-WindowStyle", "Hidden",
    "-File", $popupScript,
    "-SignalPath", $signalPath,
    "-Message", "Launcher starting"
  ) -WorkingDirectory $RootDir -PassThru

  return [pscustomobject]@{
    Process    = $popupProc
    SignalPath = $signalPath
  }
}

function Stop-StartupPopupProcess {
  param($PopupState)

  if (-not $PopupState) {
    return
  }

  try {
    if ($PopupState.SignalPath -and (Test-Path -LiteralPath $PopupState.SignalPath)) {
      [System.IO.File]::WriteAllText([string]$PopupState.SignalPath, "close", [System.Text.UTF8Encoding]::new($false))
    }
  } catch {}

  try {
    if ($PopupState.Process -and -not $PopupState.Process.HasExited) {
      $PopupState.Process.WaitForExit(5000) | Out-Null
    }
  } catch {}

  try {
    if ($PopupState.Process -and -not $PopupState.Process.HasExited) {
      Stop-Process -Id $PopupState.Process.Id -Force -ErrorAction SilentlyContinue
    }
  } catch {}

  try {
    if ($PopupState.SignalPath -and (Test-Path -LiteralPath $PopupState.SignalPath)) {
      Remove-Item -LiteralPath $PopupState.SignalPath -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}

function Invoke-Launcher {
  param(
    [string]$RootDir,
    [string]$LauncherExePath,
    [string]$LauncherScriptPath
  )

  $psExe = "powershell.exe"
  $logDir = Join-Path $RootDir "logs"
  if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
  }

  $stdoutLog = Join-Path $logDir "launcher.stdout.log"
  $stderrLog = Join-Path $logDir "launcher.stderr.log"
  $startupTraceLog = Join-Path $logDir "launcher-startup.log"
  $startupSignalPath = Join-Path $logDir "startup-popup.signal"
  $guiReadyMarker = "before ShowDialog"
  $guiTimeoutSec = 60
  Remove-Item -LiteralPath $startupSignalPath -Force -ErrorAction SilentlyContinue
  try {
    $targetPath = $null
    $launchArguments = @()
    if (-not [string]::IsNullOrWhiteSpace($LauncherScriptPath) -and (Test-Path -LiteralPath $LauncherScriptPath -PathType Leaf)) {
      $targetPath = $psExe
      $launchArguments = @(
        "-NoProfile",
        "-STA",
        "-NoLogo",
        "-ExecutionPolicy", "Bypass",
        "-File", $LauncherScriptPath
      )
    } elseif (-not [string]::IsNullOrWhiteSpace($LauncherExePath) -and (Test-Path -LiteralPath $LauncherExePath -PathType Leaf)) {
      $targetPath = $LauncherExePath
      $launchArguments = @()
    } else {
      throw "Launcher entrypoint not found: $LauncherScriptPath / $LauncherExePath"
    }

    if ($launchArguments.Count -gt 0) {
      $proc = Start-Process -FilePath $targetPath -ArgumentList $launchArguments -WorkingDirectory $RootDir -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
    } else {
      $proc = Start-Process -FilePath $targetPath -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
    }

    $guiReady = $false
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.HasExited) {
      $hasMarker = $false
      try {
        if (Test-Path -LiteralPath $startupTraceLog -PathType Leaf) {
          $traceText = Get-Content -LiteralPath $startupTraceLog -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
          $hasMarker = (-not [string]::IsNullOrWhiteSpace($traceText)) -and ($traceText -match [regex]::Escape($guiReadyMarker))
        }
      } catch {}

      if ($hasMarker) {
        $guiReady = $true
        break
      }

      if ($timer.Elapsed.TotalSeconds -ge $guiTimeoutSec) {
        break
      }

      Start-Sleep -Milliseconds 300
    }

    if (-not $proc.HasExited -and -not $guiReady) {
      try {
        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
      } catch {}

      throw ("GUI startup timeout: marker '{0}' was not observed within {1} seconds. trace={2}" -f $guiReadyMarker, $guiTimeoutSec, $startupTraceLog)
    }

    if (-not $proc.HasExited) {
      $proc.WaitForExit()
    }

    try {
      $proc.Refresh()
    } catch {}

    $exitCodeRaw = $null
    try {
      $exitCodeRaw = $proc.ExitCode
    } catch {}

    $exitCode = 0
    if ($null -eq $exitCodeRaw -or [string]::IsNullOrWhiteSpace([string]$exitCodeRaw)) {
      $exitCode = if ($guiReady) { 0 } else { -1 }
    } else {
      $exitCode = [int]$exitCodeRaw
    }

    if (-not $guiReady) {
      throw ("Launcher exited before GUI became ready. exitCode={0} trace={1}" -f $exitCode, $startupTraceLog)
    }

    if ($exitCode -ne 0) {
      $detailLines = @(
        "Launcher script exited with code $exitCode.",
        "stdout: $stdoutLog",
        "stderr: $stderrLog",
        "trace: $startupTraceLog"
      )

      foreach ($path in @($stderrLog, $stdoutLog)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
          $tail = @(Get-Content -LiteralPath $path -Tail 50 -ErrorAction SilentlyContinue)
          if ($tail.Count -gt 0) {
            $detailLines += ""
            $detailLines += ("tail: {0}" -f $path)
            $detailLines += $tail
          }
        }
      }

      throw ($detailLines -join "`r`n")
    }
  } finally {
    try {
      if (Test-Path -LiteralPath $startupSignalPath) {
        Remove-Item -LiteralPath $startupSignalPath -Force -ErrorAction SilentlyContinue
      }
    } catch {}
  }
}

function Invoke-StartupCleanup {
  param([string]$RootDir)

  $stopScript = Join-Path $RootDir "scripts\stop-runtime.ps1"
  if (-not (Test-Path -LiteralPath $stopScript -PathType Leaf)) {
    return "startup cleanup skipped: stop-runtime.ps1 not found"
  }

  try {
    $cleanupProc = Start-Process -FilePath "powershell.exe" -ArgumentList @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", $stopScript
    ) -WorkingDirectory $RootDir -PassThru -Wait -WindowStyle Hidden

    return "startup cleanup exit code: $($cleanupProc.ExitCode)"
  } catch {
    return "startup cleanup failed: " + (($_ | Out-String).TrimEnd())
  }
}

function Invoke-StartupLogCleanup {
  param([string]$RootDir)

  $logDir = Join-Path $RootDir "logs"
  $errorDir = Join-Path $logDir "error"
  $keepNames = @("LOG", "ERROR")
  $deletedCount = 0

  try {
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
      New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $errorDir -PathType Container)) {
      New-Item -ItemType Directory -Path $errorDir -Force | Out-Null
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $logDir -Recurse -File -ErrorAction SilentlyContinue)) {
      if ($keepNames -contains [string]$file.Name) {
        continue
      }

      Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
      if (-not (Test-Path -LiteralPath $file.FullName -PathType Leaf)) {
        $deletedCount++
      }
    }

    return "startup log cleanup removed: $deletedCount file(s)"
  } catch {
    return "startup log cleanup failed: " + (($_ | Out-String).TrimEnd())
  }
}

function Invoke-EmergencyCleanup {
  param([string]$RootDir)

  $stopScript = Join-Path $RootDir "scripts\stop-runtime.ps1"
  if (-not (Test-Path -LiteralPath $stopScript -PathType Leaf)) {
    return "cleanup skipped: stop-runtime.ps1 not found"
  }

  try {
    $cleanupProc = Start-Process -FilePath "powershell.exe" -ArgumentList @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", $stopScript
    ) -WorkingDirectory $RootDir -PassThru -Wait -WindowStyle Hidden

    return "cleanup exit code: $($cleanupProc.ExitCode)"
  } catch {
    return "cleanup failed: " + (($_ | Out-String).TrimEnd())
  }
}

function Invoke-LauncherEntry {
  param([string]$RootDir)

  try {
    Add-Type -AssemblyName System.Windows.Forms
    $launcherScript = Join-Path $RootDir "scripts\launch-llama-server.ps1"

    if (-not (Test-Path -LiteralPath $launcherScript -PathType Leaf)) {
      throw "Launcher script not found: $launcherScript"
    }

    $startupPopup = Start-StartupPopupProcess -RootDir $RootDir
    $script:startupCleanupResult = Invoke-StartupCleanup -RootDir $RootDir
    $script:startupLogCleanupResult = Invoke-StartupLogCleanup -RootDir $RootDir
    Invoke-Launcher -RootDir $RootDir -LauncherExePath "" -LauncherScriptPath $launcherScript
  } catch {
    $safeRoot = $RootDir
    $details = (($_ | Out-String).TrimEnd())
    if ($script:startupCleanupResult) {
      $details = $details + "`r`n`r`n" + [string]$script:startupCleanupResult
    }
    if ($script:startupLogCleanupResult) {
      $details = $details + "`r`n`r`n" + [string]$script:startupLogCleanupResult
    }
    $cleanupResult = Invoke-EmergencyCleanup -RootDir $safeRoot
    $details = $details + "`r`n`r`n" + $cleanupResult
    $reportPath = Write-StartupErrorReport -RootDir $safeRoot -Details $details
    $msg = "Launcher failed.`r`n`r`n" + $details + "`r`n`r`nTXT: " + $reportPath
    [System.Windows.Forms.MessageBox]::Show($msg, "LLM Game Base", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    Start-Process notepad.exe -ArgumentList $reportPath | Out-Null
    exit 1
  } finally {
    try {
      Stop-StartupPopupProcess -PopupState $startupPopup
    } catch {}
  }
}

$rootDir = Get-LauncherRoot
Invoke-LauncherEntry -RootDir $rootDir
