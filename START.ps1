$ErrorActionPreference = "Stop"

function Get-LauncherRoot {
  if ($PSScriptRoot -and (Test-Path -LiteralPath $PSScriptRoot)) {
    return [string]$PSScriptRoot
  }

  if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
    return [string](Split-Path -Parent $MyInvocation.MyCommand.Path)
  }

  return [string][System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\')
}

function Write-StartupErrorReport {
  param(
    [string]$RootDir,
    [string]$Details
  )

  $logDir = Join-Path $RootDir "logs"
  if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
  }

  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $reportPath = Join-Path $logDir ("error_{0}.txt" -f $stamp)
  $content = @(
    "Launcher failed.",
    ('=' * 48),
    $Details
  ) -join "`r`n"

  [System.IO.File]::WriteAllText($reportPath, $content + "`r`n", [System.Text.UTF8Encoding]::new($false))
  return $reportPath
}

function Invoke-Launcher {
  param(
    [string]$LauncherExePath,
    [string]$LauncherScriptPath
  )

  $psExe = "powershell.exe"
  $args = @(
    "-NoProfile",
    "-STA",
    "-ExecutionPolicy", "Bypass",
    "-File", $LauncherScriptPath
  )

  $proc = Start-Process -FilePath $psExe -ArgumentList $args -PassThru -Wait
  if ($proc.ExitCode -ne 0) {
    throw "Launcher script exited with code $($proc.ExitCode)."
  }
}

try {
  Add-Type -AssemblyName System.Windows.Forms
  $rootDir = Get-LauncherRoot
  $launcherScript = Join-Path $rootDir "scripts\launch-llama-server.ps1"
  $launcherExe = Join-Path $rootDir "scripts\launch-llama-server.exe"

  if (-not (Test-Path -LiteralPath $launcherScript -PathType Leaf)) {
    throw "Launcher script not found: $launcherScript"
  }

  Invoke-Launcher -LauncherExePath $launcherExe -LauncherScriptPath $launcherScript
} catch {
  $safeRoot = Get-LauncherRoot
  $details = (($_ | Out-String).TrimEnd())
  $reportPath = Write-StartupErrorReport -RootDir $safeRoot -Details $details
  $msg = "Launcher failed.`r`n`r`n" + $details + "`r`n`r`nTXT: " + $reportPath
  [System.Windows.Forms.MessageBox]::Show($msg, "LLM Game Base", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
  Start-Process notepad.exe -ArgumentList $reportPath | Out-Null
  exit 1
}
