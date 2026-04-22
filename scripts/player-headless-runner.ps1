param(
  [string]$Root = "",
  [int]$Port = 4173,
  [switch]$NoOpenGame,
  [switch]$Wait,
  [switch]$AllEnabledAgents
)

$ErrorActionPreference = "Stop"

function Get-RunnerScriptDir {
  if ($PSScriptRoot -and (Test-Path -LiteralPath $PSScriptRoot -PathType Container)) {
    return [string]$PSScriptRoot
  }

  if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
    return [string](Split-Path -Parent $MyInvocation.MyCommand.Path)
  }

  return [string](Get-Location)
}

function Get-RunnerRootDir {
  param([string]$RequestedRoot)

  if (-not [string]::IsNullOrWhiteSpace($RequestedRoot) -and (Test-Path -LiteralPath $RequestedRoot -PathType Container)) {
    return [string](Resolve-Path $RequestedRoot)
  }

  return [string](Resolve-Path (Join-Path (Get-RunnerScriptDir) ".."))
}

function Write-RunnerLog {
  param([string]$Message)

  try {
    $line = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + $Message
    Add-Content -LiteralPath $script:runnerLogFile -Encoding UTF8 -Value $line
  } catch {}
}

function Get-ActiveRunnerAgents {
  param(
    [array]$Agents,
    $RuntimeProfile,
    [switch]$AllEnabled
  )

  $validAgents = @(Get-ValidAgents -AgentItems $Agents)
  if ($validAgents.Count -eq 0) {
    return @()
  }

  if ($AllEnabled) {
    return @($validAgents | Where-Object { $_.enabled })
  }

  $activeIds = @()
  if ($RuntimeProfile -and $RuntimeProfile.activeAgentIds) {
    $activeIds = @($RuntimeProfile.activeAgentIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }

  if ($activeIds.Count -gt 0) {
    $selected = @($validAgents | Where-Object { $activeIds -contains [string]$_.id })
    if ($selected.Count -gt 0) {
      return @($selected)
    }
  }

  $enabled = @($validAgents | Where-Object { $_.enabled })
  if ($enabled.Count -gt 0) {
    return @($enabled)
  }

  return @($validAgents | Select-Object -First 1)
}

function Get-RunnerFallbackModelPath {
  param(
    [hashtable]$EnvMap,
    [array]$KnownModels,
    $RuntimeProfile,
    [string[]]$SearchDirs
  )

  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace([string]$EnvMap.LLAMA_MODEL_PATH)) {
    $candidates += [string]$EnvMap.LLAMA_MODEL_PATH
  }
  if ($RuntimeProfile -and -not [string]::IsNullOrWhiteSpace([string]$RuntimeProfile.modelPath)) {
    $candidates += [string]$RuntimeProfile.modelPath
  }
  foreach ($model in @($KnownModels)) {
    if ($model -and -not [string]::IsNullOrWhiteSpace([string]$model.FullName)) {
      $candidates += [string]$model.FullName
    }
  }

  foreach ($candidate in @($candidates)) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return [string](Resolve-Path $candidate)
    }
  }

  foreach ($dir in @($SearchDirs)) {
    if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) {
      continue
    }

    $found = Get-ChildItem -LiteralPath $dir -Filter *.gguf -File -Recurse -ErrorAction SilentlyContinue |
      Sort-Object Length |
      Select-Object -First 1
    if ($found) {
      return [string]$found.FullName
    }
  }

  return ""
}

function Repair-RunnerMissingModelPaths {
  param(
    [array]$Agents,
    [string]$FallbackModelPath
  )

  if ([string]::IsNullOrWhiteSpace($FallbackModelPath)) {
    return
  }

  foreach ($agent in @($Agents)) {
    if ($agent -and [string]::IsNullOrWhiteSpace([string]$agent.modelPath)) {
      $agent.modelPath = $FallbackModelPath
    }
  }
}

function Test-RunnerAgentInputs {
  param(
    [hashtable]$EnvMap,
    [array]$Agents
  )

  if ($Agents.Count -eq 0) {
    throw "No AI agent configuration is available. Save AI settings in the launcher first."
  }

  $missingModelAgents = @()
  foreach ($agent in @($Agents)) {
    $modelPath = [string]$agent.modelPath
    if ([string]::IsNullOrWhiteSpace($modelPath)) {
      $missingModelAgents += [string]$agent.name
      continue
    }
    if (-not (Test-Path -LiteralPath $modelPath -PathType Leaf)) {
      throw ("Model file not found for agent '{0}': {1}" -f [string]$agent.name, $modelPath)
    }

    $exePath = Get-ExePathForNgl -EnvMap $EnvMap -Ngl ([string]$agent.llamaNgl)
    if ([string]::IsNullOrWhiteSpace($exePath) -or -not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
      throw ("llama-server.exe not found for agent '{0}': {1}" -f [string]$agent.name, $exePath)
    }
  }

  if ($missingModelAgents.Count -gt 0) {
    throw ("No .gguf model is configured for: {0}. Put a .gguf file under llama-runtime\models or save AI settings in the launcher first." -f ($missingModelAgents -join ", "))
  }
}

$script:scriptDir = Get-RunnerScriptDir
$script:rootDir = Get-RunnerRootDir -RequestedRoot $Root
$scriptDir = $script:scriptDir
$rootDir = $script:rootDir

$coreEnginePath = Join-Path $scriptDir "core-engine.ps1"
if (-not (Test-Path -LiteralPath $coreEnginePath -PathType Leaf)) {
  throw "Missing core engine script: $coreEnginePath"
}
. $coreEnginePath

$modelsDir = Join-Path $rootDir "llama-runtime\models"
if (-not (Test-Path -LiteralPath $modelsDir -PathType Container)) {
  $modelsDir = Join-Path $rootDir "models"
}
$bundledRuntimeDir = Join-Path $rootDir "llama-runtime"
$bundledCpuDir = Join-Path $bundledRuntimeDir "cpu"
$bundledGpuDir = Join-Path $bundledRuntimeDir "gpu"
$bundledBinDir = Join-Path $rootDir "llama-runtime\bin"
$envFile = Join-Path $scriptDir "llama-server.env.bat"
$runtimeProfileFile = Join-Path $rootDir "config\runtimeProfile.json"
$agentProfileFile = Join-Path $rootDir "config\agentsProfile.json"
$llamaStateFile = Join-Path $scriptDir "llama-server.state.json"
$gameStateFile = Join-Path $scriptDir "game-server.state.json"
$launcherLogDir = Join-Path $rootDir "logs"
if (-not (Test-Path -LiteralPath $launcherLogDir -PathType Container)) {
  New-Item -ItemType Directory -Path $launcherLogDir -Force | Out-Null
}
$script:runnerLogFile = Join-Path $launcherLogDir "player-headless-runner.log"

Write-RunnerLog "begin"

$script:lastStartupErrorDetails = ""
$script:lastGameStartupErrorDetails = ""
$script:envMap = Get-EnvMap -EnvFile $envFile
Ensure-ModeExePaths -EnvMap $script:envMap

$models = Get-Models -ModelsDir $modelsDir
$script:agents = @(Load-Agents -Path $agentProfileFile -Models $models -EnvMap $script:envMap)
[void](Repair-AgentEntries -AgentItems $script:agents -KnownModels $models -EnvMap $script:envMap)

$runtimeProfile = Read-JsonFile -Path $runtimeProfileFile
$fallbackModelPath = Get-RunnerFallbackModelPath `
  -EnvMap $script:envMap `
  -KnownModels $models `
  -RuntimeProfile $runtimeProfile `
  -SearchDirs @($modelsDir, (Join-Path $rootDir "llama-runtime\models"), (Join-Path $rootDir "models"))
Repair-RunnerMissingModelPaths -Agents $script:agents -FallbackModelPath $fallbackModelPath

$activeAgents = @(Get-ActiveRunnerAgents -Agents $script:agents -RuntimeProfile $runtimeProfile -AllEnabled:$AllEnabledAgents)
Test-RunnerAgentInputs -EnvMap $script:envMap -Agents $activeAgents

$primary = $activeAgents[0]
$script:envMap.LLAMA_MODEL_PATH = [string]$primary.modelPath
$script:envMap.LLAMA_PORT = [string]$primary.llamaPort
$script:envMap.LLAMA_CTX = [string]$primary.llamaCtx
$script:envMap.LLAMA_NGL = [string]$primary.llamaNgl
if ([string]::IsNullOrWhiteSpace([string]$script:envMap.LLAMA_HOST)) {
  $script:envMap.LLAMA_HOST = "127.0.0.1"
}

$activeIds = @($activeAgents | ForEach-Object { [string]$_.id })
Write-RuntimeProfile -ProfilePath $runtimeProfileFile -EnvMap $script:envMap -Agents $script:agents -ActiveAgentIds $activeIds

Write-RunnerLog ("starting llama agents: " + ($activeIds -join ","))
$llamaReady = Start-LlamaServersHidden -EnvMap $script:envMap -Agents $activeAgents -StateFile $llamaStateFile
if (-not $llamaReady) {
  $details = if ([string]::IsNullOrWhiteSpace([string]$script:lastStartupErrorDetails)) { "llama-server did not become ready." } else { [string]$script:lastStartupErrorDetails }
  Write-RunnerLog $details
  throw $details
}

Write-RunnerLog "starting game server"
$gameReady = Ensure-GameServer -RootDir $rootDir -StateFile $gameStateFile -Port $Port
if (-not $gameReady) {
  $details = if ([string]::IsNullOrWhiteSpace([string]$script:lastGameStartupErrorDetails)) { "Game server did not become ready." } else { [string]$script:lastGameStartupErrorDetails }
  Write-RunnerLog $details
  throw $details
}

$gameUrl = "http://127.0.0.1:$Port/index.html"
Write-RunnerLog ("ready: " + $gameUrl)
Write-Output ("Ready: " + $gameUrl)

if (-not $NoOpenGame) {
  Start-Process $gameUrl | Out-Null
}

if ($Wait) {
  Write-RunnerLog "waiting"
  while ($true) {
    Start-Sleep -Seconds 2
  }
}
