$ErrorActionPreference = "Stop"
$ConfirmPreference = 'None'

function Get-RootDir {
  if ($PSScriptRoot -and (Test-Path -LiteralPath $PSScriptRoot)) {
    return [string](Resolve-Path (Join-Path $PSScriptRoot ".."))
  }
  return [string](Resolve-Path ".")
}

function Ensure-Ps2Exe {
  $env:PSExecutionPolicyPreference = 'Bypass'

  $cmd = Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue
  if ($cmd) {
    return
  }

  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  } catch {
    Write-Verbose "Failed to set TLS12 explicitly: $($_.Exception.Message)"
  }

  $nugetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
  if (-not $nugetProvider) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ForceBootstrap -Confirm:$false | Out-Null
  }

  try {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
  } catch {
    Write-Verbose "Failed to set PSGallery trust policy: $($_.Exception.Message)"
  }

  $module = Get-Module -ListAvailable ps2exe | Select-Object -First 1
  if (-not $module) {
    Install-Module ps2exe -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -AcceptLicense -Confirm:$false
  }

  Import-Module ps2exe -Force

  $cmd = Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue
  if (-not $cmd) {
    throw "Invoke-ps2exe was not found. Check PowerShell Gallery connectivity."
  }
}

$rootDir = Get-RootDir
$startPs1 = Join-Path $rootDir "release\LauncherEntry.ps1"
$startExe = Join-Path $rootDir "LLMGameBaseLauncher.exe"
$launcherPs1 = Join-Path $rootDir "scripts\launch-llama-server.ps1"

if (-not (Test-Path -LiteralPath $startPs1 -PathType Leaf)) {
  throw "release\\LauncherEntry.ps1 not found: $startPs1"
}
if (-not (Test-Path -LiteralPath $launcherPs1 -PathType Leaf)) {
  throw "launch-llama-server.ps1 not found: $launcherPs1"
}

Ensure-Ps2Exe

Invoke-ps2exe -inputFile $startPs1 -outputFile $startExe -x64 -STA -noConsole -title "LLM Game Base Launcher"

Write-Output "Built:"
Write-Output "  $startExe"
