param(
  [string]$SignalPath,
  [string]$Message = "Launcher starting",
  [string]$RootDir = ""
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if ([string]::IsNullOrWhiteSpace($SignalPath)) {
  throw "SignalPath is required."
}

function Get-StartupRootDir {
  if (-not [string]::IsNullOrWhiteSpace($RootDir) -and (Test-Path -LiteralPath $RootDir -PathType Container)) {
    return [string](Resolve-Path $RootDir)
  }

  if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot "..\scripts\startup-popup.ps1"))) {
    return [string](Resolve-Path (Join-Path $PSScriptRoot ".."))
  }

  return [string](Get-Location)
}

function Write-StartupJsonFile {
  param(
    [string]$Path,
    $Data
  )

  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  $json = $Data | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText($Path, $json + "`r`n", [System.Text.UTF8Encoding]::new($false))
}

function Read-StartupJsonFile {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  try {
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Test-HasGgufModel {
  param([string]$ModelsDir)

  if (-not (Test-Path -LiteralPath $ModelsDir -PathType Container)) {
    return $false
  }

  return [bool](Get-ChildItem -LiteralPath $ModelsDir -Filter *.gguf -File -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Start-ModelDownloaderIfAvailable {
  param(
    [string]$ProjectRoot,
    [string]$SetupStatePath
  )

  $downloaderExe = Join-Path $ProjectRoot "HF-GGUF-Downloader.exe"
  $downloaderScript = Join-Path $ProjectRoot "scripts\hf-gguf-downloader.ps1"

  if (Test-Path -LiteralPath $downloaderExe -PathType Leaf) {
    Start-Process -FilePath $downloaderExe -WorkingDirectory $ProjectRoot | Out-Null
    return "exe"
  }

  if (Test-Path -LiteralPath $downloaderScript -PathType Leaf) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
      "-NoProfile",
      "-STA",
      "-ExecutionPolicy", "Bypass",
      "-File", $downloaderScript
    ) -WorkingDirectory $ProjectRoot | Out-Null
    return "script"
  }

  return "missing"
}

function Invoke-InitialSetup {
  param([string]$ProjectRoot)

  $configDir = Join-Path $ProjectRoot "config"
  $modelsDir = Join-Path $ProjectRoot "llama-runtime\models"
  $scriptsDir = Join-Path $ProjectRoot "scripts"
  $envFile = Join-Path $scriptsDir "llama-server.env.bat"
  $bootSettingsPath = Join-Path $configDir "bootSettings.json"
  $uiSettingsPath = Join-Path $configDir "uiSettings.json"
  $setupStatePath = Join-Path $configDir "startupSetup.json"

  foreach ($dir in @($configDir, $modelsDir)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
  }

  $now = (Get-Date).ToString("o")

  if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
    $cpuExe = Join-Path $ProjectRoot "llama-runtime\cpu\llama-server.exe"
    $gpuExe = Join-Path $ProjectRoot "llama-runtime\gpu\llama-server.exe"
    $envLines = @(
      '@echo off',
      ('set "LLAMA_CPP_EXE_CPU={0}"' -f $cpuExe),
      ('set "LLAMA_CPP_EXE_GPU={0}"' -f $gpuExe),
      'set "LLAMA_MODEL_PATH="',
      'set "LLAMA_PORT=8080"',
      'set "LLAMA_HOST=127.0.0.1"',
      'set "LLAMA_NGL=99"',
      'set "LLAMA_CTX=8192"',
      'set "LLAMA_EXTRA_ARGS="'
    )
    [System.IO.File]::WriteAllText($envFile, ($envLines -join "`r`n") + "`r`n", [System.Text.UTF8Encoding]::new($false))
  }

  if (-not (Test-Path -LiteralPath $bootSettingsPath -PathType Leaf)) {
    Write-StartupJsonFile -Path $bootSettingsPath -Data ([ordered]@{
      generatedAt = $now
      boot = [ordered]@{
        modelFolder      = $modelsDir
        cpuExePath       = Join-Path $ProjectRoot "llama-runtime\cpu\llama-server.exe"
        gpuExePath       = Join-Path $ProjectRoot "llama-runtime\gpu\llama-server.exe"
        selectedMode     = "gpu"
        defaultHost      = "127.0.0.1"
        defaultPort      = "8080"
        defaultNgl       = "99"
        defaultCtx       = "8192"
        defaultExtraArgs = ""
      }
    })
  }

  if (-not (Test-Path -LiteralPath $uiSettingsPath -PathType Leaf)) {
    Write-StartupJsonFile -Path $uiSettingsPath -Data ([ordered]@{
      generatedAt = $now
      language    = "ja"
    })
  }

  $previousSetup = Read-StartupJsonFile -Path $setupStatePath
  $hasModel = Test-HasGgufModel -ModelsDir $modelsDir
  $alreadyPromptedForModel = [bool](
    $previousSetup -and
    $previousSetup.completed -and
    ($previousSetup.downloaderLaunch -in @("exe", "script", "missing"))
  )
  $downloaderLaunch = "skipped"
  if (-not $hasModel -and -not $alreadyPromptedForModel) {
    $downloaderLaunch = Start-ModelDownloaderIfAvailable -ProjectRoot $ProjectRoot -SetupStatePath $setupStatePath
  } elseif (-not $hasModel -and $alreadyPromptedForModel) {
    $downloaderLaunch = "already-prompted"
  }

  Write-StartupJsonFile -Path $setupStatePath -Data ([ordered]@{
    generatedAt        = $now
    completed          = $true
    modelsDir          = $modelsDir
    modelPresent       = $hasModel
    downloaderLaunch   = $downloaderLaunch
    envFile            = $envFile
    bootSettingsPath   = $bootSettingsPath
    uiSettingsPath     = $uiSettingsPath
  })

  return [pscustomobject]@{
    ModelPresent     = $hasModel
    DownloaderLaunch = $downloaderLaunch
  }
}

$signalDir = Split-Path -Parent $SignalPath
if (-not (Test-Path -LiteralPath $signalDir -PathType Container)) {
  New-Item -ItemType Directory -Path $signalDir -Force | Out-Null
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "LLM Game Base"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.ControlBox = $false
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.Width = 360
$form.Height = 140
$form.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 24)
$form.ForeColor = [System.Drawing.Color]::Gainsboro

$label = New-Object System.Windows.Forms.Label
$label.Left = 18
$label.Top = 18
$label.Width = 310
$label.Height = 30
$label.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Regular)
$label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$form.Controls.Add($label)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Left = 18
$bar.Top = 58
$bar.Width = 310
$bar.Height = 18
$bar.Minimum = 0
$bar.Maximum = 100
$bar.Value = 0
$bar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
$form.Controls.Add($bar)

$status = New-Object System.Windows.Forms.Label
$status.Left = 18
$status.Top = 84
$status.Width = 310
$status.Height = 20
$status.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$status.ForeColor = [System.Drawing.Color]::Silver
$status.Text = "Starting..."
$form.Controls.Add($status)

$dots = @(".", "..", "...", "....")
$script:index = 0
$script:barValue = 0
$script:barStep = 4
$script:isClosingPhase = $false
$script:shownAt = Get-Date
$script:setupDone = $false
$minimumVisibleMs = 1200
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 350
$timer.Add_Tick({
  $script:index = ($script:index + 1) % $dots.Count
  $label.Text = $Message + $dots[$script:index]

  $elapsedMs = ([datetime]::Now - $script:shownAt).TotalMilliseconds
  if (-not $script:isClosingPhase -and $elapsedMs -ge $minimumVisibleMs -and (Test-Path -LiteralPath $SignalPath -PathType Leaf)) {
    $script:isClosingPhase = $true
    $script:barStep = 20
    $status.Text = "Finalizing..."
  }

  $script:barValue += $script:barStep
  if ($script:isClosingPhase) {
    if ($script:barValue -ge 100) {
      $script:barValue = 100
      $bar.Value = $script:barValue
      $form.Close()
      return
    }
  } else {
    if ($script:barValue -ge 100) {
      $script:barValue = 100
      $script:barStep = -4
    } elseif ($script:barValue -le 0) {
      $script:barValue = 0
      $script:barStep = 4
    }
  }
  $bar.Value = $script:barValue
})

$form.Add_Shown({
  $timer.Start()
  if (-not $script:setupDone) {
    $script:setupDone = $true
    try {
      $status.Text = "Preparing first-run setup..."
      [System.Windows.Forms.Application]::DoEvents()
      $setup = Invoke-InitialSetup -ProjectRoot (Get-StartupRootDir)
      if (-not $setup.ModelPresent) {
        if ($setup.DownloaderLaunch -in @("exe", "script")) {
          $status.Text = "Model downloader opened..."
        } elseif ($setup.DownloaderLaunch -eq "already-prompted") {
          $status.Text = "Waiting for launcher..."
        } elseif ($setup.DownloaderLaunch -eq "missing") {
          $status.Text = "Model downloader not found..."
        } else {
          $status.Text = "Waiting for launcher..."
        }
      } else {
        $status.Text = "Initial setup ready..."
      }
    } catch {
      $status.Text = "Setup warning logged..."
      try {
        $root = Get-StartupRootDir
        $errorDir = Join-Path $root "logs\error"
        if (-not (Test-Path -LiteralPath $errorDir -PathType Container)) {
          New-Item -ItemType Directory -Path $errorDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText((Join-Path $errorDir "startup-setup-error.txt"), (($_ | Out-String).TrimEnd()) + "`r`n", [System.Text.UTF8Encoding]::new($false))
      } catch {}
    }
  }
})
$form.Add_FormClosed({
  try { $timer.Stop() } catch {}
  try { $timer.Dispose() } catch {}
})

$label.Text = $Message + $dots[0]
[System.Windows.Forms.Application]::Run($form)
