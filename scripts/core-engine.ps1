$ErrorActionPreference = "Stop"

# Shared launcher engine helpers. Keep GUI construction and event handlers in launch-llama-server.ps1.

function Get-ScriptDir {
	if ($PSScriptRoot -and (Test-Path -LiteralPath $PSScriptRoot)) {
		return [string]$PSScriptRoot
	}

	if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
		return [string](Split-Path -Parent $MyInvocation.MyCommand.Path)
	}

	return [string][System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\\')
}


function New-DefaultEnvMap {
	return [ordered]@{
		LLAMA_CPP_EXE_CPU = ""
		LLAMA_CPP_EXE_GPU = ""
		LLAMA_MODEL_PATH = ""
		LLAMA_PORT       = "8080"
		LLAMA_HOST       = "127.0.0.1"
		LLAMA_NGL        = "99"
		LLAMA_CTX        = "8192"
		LLAMA_EXTRA_ARGS = ""
	}
}


function Get-EnvMap {
	param([string]$EnvFile)

	$defaults = New-DefaultEnvMap

	if (-not (Test-Path -LiteralPath $EnvFile)) {
		return $defaults
	}

	foreach ($line in Get-Content -LiteralPath $EnvFile -Encoding UTF8) {
		if ($line -match '^set "([^=]+)=(.*)"$') {
			$defaults[$Matches[1]] = $Matches[2]
		}
	}

	return $defaults
}


function Save-EnvMap {
	param(
		[string]$EnvFile,
		[hashtable]$EnvMap
	)

	if ([string]::IsNullOrWhiteSpace([string]$EnvMap.LLAMA_CPP_EXE_CPU)) {
		$EnvMap.LLAMA_CPP_EXE_CPU = Resolve-BundledLlamaExePath -PreferGpu:$false
	}
	if ([string]::IsNullOrWhiteSpace([string]$EnvMap.LLAMA_CPP_EXE_GPU)) {
		$EnvMap.LLAMA_CPP_EXE_GPU = Resolve-BundledLlamaExePath -PreferGpu:$true
	}

	$lines = @(
		'@echo off',
		('set "LLAMA_CPP_EXE_CPU={0}"' -f $EnvMap.LLAMA_CPP_EXE_CPU),
		('set "LLAMA_CPP_EXE_GPU={0}"' -f $EnvMap.LLAMA_CPP_EXE_GPU),
		('set "LLAMA_MODEL_PATH={0}"' -f $EnvMap.LLAMA_MODEL_PATH),
		('set "LLAMA_PORT={0}"' -f $EnvMap.LLAMA_PORT),
		('set "LLAMA_HOST={0}"' -f $EnvMap.LLAMA_HOST),
		('set "LLAMA_NGL={0}"' -f $EnvMap.LLAMA_NGL),
		('set "LLAMA_CTX={0}"' -f $EnvMap.LLAMA_CTX),
		('set "LLAMA_EXTRA_ARGS={0}"' -f $EnvMap.LLAMA_EXTRA_ARGS),
		'',
		'REM Examples:',
		'REM set "LLAMA_CPP_EXE_CPU=C:\tools\llama.cpp\cpu\llama-server.exe"',
		'REM set "LLAMA_CPP_EXE_GPU=C:\tools\llama.cpp\gpu\llama-server.exe"',
		'REM set "LLAMA_MODEL_PATH=C:\path\to\model.gguf"'
	)

	# Use UTF-8 (no BOM) so Japanese paths are persisted without mojibake.
	[System.IO.File]::WriteAllText($EnvFile, ($lines -join "`r`n") + "`r`n", [System.Text.UTF8Encoding]::new($false))
}


function Get-UiSettings {
	param([string]$Path)

	$settings = [ordered]@{ language = "ja" }
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		return $settings
	}

	try {
		$raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
		if ($raw -and ($raw.language -in @("ja", "en"))) {
			$settings.language = [string]$raw.language
		}
	} catch {}

	return $settings
}


function Save-UiSettings {
	param(
		[string]$Path,
		[string]$Language
	)

	Write-JsonFile -Path $Path -Data ([ordered]@{
		generatedAt = (Get-Date).ToString("o")
		language    = if ($Language -in @("ja", "en")) { $Language } else { "ja" }
	})
}


function Get-RootDirSafe {
	if (-not [string]::IsNullOrWhiteSpace([string]$script:rootDir)) {
		return [string]$script:rootDir
	}

	$baseScriptDir = if (-not [string]::IsNullOrWhiteSpace([string]$script:scriptDir)) {
		[string]$script:scriptDir
	} else {
		Get-ScriptDir
	}

	if (-not [string]::IsNullOrWhiteSpace($baseScriptDir)) {
		try {
			return [string](Resolve-Path (Join-Path $baseScriptDir ".."))
		} catch {}
	}

	try {
		return [string](Resolve-Path ".")
	} catch {
		return ""
	}
}


function Backup-ConfigSnapshot {
	param([string]$Reason = "manual")

	$resolvedRootDir = Get-RootDirSafe
	if ([string]::IsNullOrWhiteSpace($resolvedRootDir)) {
		throw "Project root directory could not be resolved."
	}

	$backupDir = Join-Path $resolvedRootDir "config\backups"
	if (-not (Test-Path -LiteralPath $backupDir -PathType Container)) {
		New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
	}

	$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
	$backupPath = Join-Path $backupDir ("settings_{0}_{1}.json" -f $Reason, $stamp)
	$data = [ordered]@{
		generatedAt = (Get-Date).ToString("o")
		reason      = $Reason
		envMap      = $script:envMap
		agents      = $script:agents
		runtime     = Read-JsonFile -Path $runtimeProfileFile
		uiSettings  = [ordered]@{ language = $script:currentLanguage }
	}
	Write-JsonFile -Path $backupPath -Data $data
	return $backupPath
}


function Export-SettingsToFile {
	param([string]$Path)

	$data = [ordered]@{
		generatedAt = (Get-Date).ToString("o")
		envMap      = $script:envMap
		agents      = $script:agents
		runtime     = Read-JsonFile -Path $runtimeProfileFile
		uiSettings  = [ordered]@{ language = $script:currentLanguage }
	}
	Write-JsonFile -Path $Path -Data $data
}


function Import-SettingsFromFile {
	param([string]$Path)

	$imported = Read-JsonFile -Path $Path
	if (-not $imported) {
		throw (Get-UiText "importInvalid")
	}

	if ($imported.envMap) {
		$script:envMap = New-DefaultEnvMap
		foreach ($k in $script:envMap.Keys) {
			if ($imported.envMap.PSObject.Properties.Name -contains $k) {
				$script:envMap[$k] = [string]$imported.envMap.$k
			}
		}
		Save-EnvMap -EnvFile $envFile -EnvMap $script:envMap
	}

	if ($imported.agents) {
		$script:agents = @(Get-ValidAgents -AgentItems @($imported.agents))
		if ($script:agents.Count -eq 0) {
			$script:agents = @(New-DefaultAgents -Models $models -EnvMap $script:envMap)
		}
		[void](Repair-AgentEntries -AgentItems $script:agents -KnownModels $models -EnvMap $script:envMap)
		Save-Agents -Path $agentProfileFile -Agents $script:agents
	}

	if ($imported.uiSettings -and $imported.uiSettings.language) {
		$script:currentLanguage = if ([string]$imported.uiSettings.language -in @("ja", "en")) { [string]$imported.uiSettings.language } else { "ja" }
		Save-UiSettings -Path $uiSettingsFile -Language $script:currentLanguage
	}

	$activeIds = @($script:agents | Where-Object { $_.enabled } | ForEach-Object { [string]$_.id })
	if ($activeIds.Count -eq 0 -and $script:agents.Count -gt 0) {
		$activeIds = @([string]$script:agents[0].id)
	}
	Write-RuntimeProfile -ProfilePath $runtimeProfileFile -EnvMap $script:envMap -Agents $script:agents -ActiveAgentIds $activeIds
}


function Read-JsonFile {
	param([string]$Path)

	if (-not (Test-Path -LiteralPath $Path)) {
		return $null
	}

	try {
		return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
	} catch {
		return $null
	}
}


function Write-JsonFile {
	param(
		[string]$Path,
		$Data
	)

	$parent = Split-Path -Parent $Path
	if (-not (Test-Path -LiteralPath $parent)) {
		New-Item -ItemType Directory -Path $parent -Force | Out-Null
	}

	$json = $Data | ConvertTo-Json -Depth 8
	[System.IO.File]::WriteAllText($Path, $json + "`r`n", [System.Text.UTF8Encoding]::new($false))
}

if (-not $script:substAliasCache) {
	$script:substAliasCache = @{}
}


function Convert-ToShortPathIfAvailable {
	param([string]$Path)

	if ([string]::IsNullOrWhiteSpace($Path)) {
		return $Path
	}

	if (-not (Test-Path -LiteralPath $Path)) {
		return $Path
	}

	try {
		if (-not ('Win32ShortPath' -as [type])) {
			Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class Win32ShortPath {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern uint GetShortPathName(string longPath, StringBuilder shortPath, uint bufferSize);
}
'@
		}

		$buffer = New-Object System.Text.StringBuilder 1024
		$written = [Win32ShortPath]::GetShortPathName($Path, $buffer, $buffer.Capacity)
		if ($written -gt 0) {
			$shortPath = $buffer.ToString()
			if (-not [string]::IsNullOrWhiteSpace($shortPath)) {
				return $shortPath
			}
		}
	} catch {}

	return $Path
}


function Get-SubstMappings {
	$mapping = @{}
	foreach ($line in @(& subst 2>$null)) {
		if ($line -match '^(?<drive>[A-Z]:)\:\s*=>\s*(?<root>.+)$') {
			$mapping[$matches.drive] = $matches.root.Trim()
		}
	}

	return $mapping
}


function Resolve-AsciiDirectoryAlias {
	param([string]$DirectoryPath)

	if ([string]::IsNullOrWhiteSpace($DirectoryPath)) {
		return $DirectoryPath
	}

	$normalized = [System.IO.Path]::GetFullPath($DirectoryPath).TrimEnd('\')
	if ($normalized -notmatch '[^\u0000-\u007F]') {
		return $normalized
	}

	if ($script:substAliasCache.ContainsKey($normalized)) {
		return $script:substAliasCache[$normalized]
	}

	$existingMappings = Get-SubstMappings
	foreach ($entry in $existingMappings.GetEnumerator()) {
		if ([System.IO.Path]::GetFullPath($entry.Value).TrimEnd('\') -ieq $normalized) {
			$alias = ($entry.Key + '\')
			$script:substAliasCache[$normalized] = $alias
			return $alias
		}
	}

	foreach ($letter in @('X','Y','Z','W','V','U','T','S','R','Q','P','O','N','M')) {
		$drive = "$letter`:"
		if ($existingMappings.ContainsKey($drive)) {
			continue
		}

		try {
			& subst $drive $normalized | Out-Null
			if ($LASTEXITCODE -eq 0) {
				$alias = ($drive + '\')
				$script:substAliasCache[$normalized] = $alias
				return $alias
			}
		} catch {}
	}

	return $normalized
}


function Resolve-LaunchPath {
	param([string]$Path)

	if ([string]::IsNullOrWhiteSpace($Path)) {
		return $Path
	}

	$fullPath = [System.IO.Path]::GetFullPath($Path)
	if ($fullPath -notmatch '[^\u0000-\u007F]') {
		return $fullPath
	}

	$parentPath = Split-Path -Parent $fullPath
	if ([string]::IsNullOrWhiteSpace($parentPath)) {
		return Convert-ToShortPathIfAvailable -Path $fullPath
	}

	$aliasParent = Resolve-AsciiDirectoryAlias -DirectoryPath $parentPath
	$rebuiltPath = Join-Path $aliasParent (Split-Path -Leaf $fullPath)
	$shortPath = Convert-ToShortPathIfAvailable -Path $rebuiltPath
	if ($shortPath -match '[^\u0000-\u007F]') {
		return $rebuiltPath
	}

	return $shortPath
}


function Resolve-ModelLaunchPath {
	param([string]$ModelPath)

	if ([string]::IsNullOrWhiteSpace($ModelPath)) {
		return $ModelPath
	}

	$fullPath = [System.IO.Path]::GetFullPath($ModelPath)
	$launchPath = Resolve-LaunchPath -Path $fullPath
	if ((Test-Path -LiteralPath $launchPath -PathType Leaf) -and $launchPath -notmatch '[^\u0000-\u007F]') {
		return $launchPath
	}

	if ($fullPath -notmatch '[^\u0000-\u007F]') {
		return $launchPath
	}

	$aliasRoot = Join-Path $env:LOCALAPPDATA "LLMGameBase\model-alias"
	if (-not (Test-Path -LiteralPath $aliasRoot -PathType Container)) {
		New-Item -ItemType Directory -Path $aliasRoot -Force | Out-Null
	}

	$leaf = Split-Path -Leaf $fullPath
	$aliasPath = Join-Path $aliasRoot $leaf

	if (Test-Path -LiteralPath $aliasPath -PathType Leaf) {
		return $aliasPath
	}

	try {
		New-Item -ItemType HardLink -Path $aliasPath -Target $fullPath -ErrorAction Stop | Out-Null
		if (Test-Path -LiteralPath $aliasPath -PathType Leaf) {
			return $aliasPath
		}
	} catch {}

	return $launchPath
}


function Get-Models {
	param([string]$ModelsDir)

	if (-not (Test-Path -LiteralPath $ModelsDir)) {
		return @()
	}

	return @(Get-ChildItem -LiteralPath $ModelsDir -Filter *.gguf -File | Sort-Object Length)
}


function Resolve-BundledLlamaExePath {
	param([bool]$PreferGpu = $false)

	$cpuExe = Join-Path $bundledCpuDir "llama-server.exe"
	$gpuExe = Join-Path $bundledGpuDir "llama-server.exe"
	$legacyExe = Join-Path $bundledBinDir "llama-server.exe"

	if ($PreferGpu) {
		if (Test-Path -LiteralPath $gpuExe -PathType Leaf) { return $gpuExe }
		if (Test-Path -LiteralPath $cpuExe -PathType Leaf) { return $cpuExe }
	} else {
		if (Test-Path -LiteralPath $cpuExe -PathType Leaf) { return $cpuExe }
		if (Test-Path -LiteralPath $gpuExe -PathType Leaf) { return $gpuExe }
	}

	if (Test-Path -LiteralPath $legacyExe -PathType Leaf) { return $legacyExe }
	return $cpuExe
}


function Ensure-ModeExePaths {
	param([hashtable]$EnvMap)

	$legacyExePath = [string]$EnvMap.LLAMA_CPP_EXE
	if ([string]::IsNullOrWhiteSpace([string]$EnvMap.LLAMA_CPP_EXE_CPU)) {
		if ([string]$EnvMap.LLAMA_NGL -eq "0" -and -not [string]::IsNullOrWhiteSpace($legacyExePath)) {
			$EnvMap.LLAMA_CPP_EXE_CPU = $legacyExePath
		} else {
			$EnvMap.LLAMA_CPP_EXE_CPU = Resolve-BundledLlamaExePath -PreferGpu:$false
		}
	}
	if ([string]::IsNullOrWhiteSpace([string]$EnvMap.LLAMA_CPP_EXE_GPU)) {
		if ([string]$EnvMap.LLAMA_NGL -ne "0" -and -not [string]::IsNullOrWhiteSpace($legacyExePath)) {
			$EnvMap.LLAMA_CPP_EXE_GPU = $legacyExePath
		} else {
			$EnvMap.LLAMA_CPP_EXE_GPU = Resolve-BundledLlamaExePath -PreferGpu:$true
		}
	}
}


function Get-GitCommandPath {
	$cmd = Get-Command git.exe -ErrorAction SilentlyContinue
	if (-not $cmd) {
		$cmd = Get-Command git -ErrorAction SilentlyContinue
	}

	if ($cmd) {
		return [string]$cmd.Source
	}

	return $null
}


function Invoke-ExternalCommand {
	param(
		[string]$FilePath,
		[string[]]$Arguments,
		[string]$WorkingDirectory = ""
	)

	$resolvedWorkingDirectory = if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { Get-RootDirSafe } else { $WorkingDirectory }
	if ([string]::IsNullOrWhiteSpace($resolvedWorkingDirectory)) {
		return [pscustomobject]@{
			Success  = $false
			ExitCode = -1
			Output   = "Working directory could not be resolved."
		}
	}

	$pushedLocation = $false
	try {
		Push-Location -LiteralPath $resolvedWorkingDirectory
		$pushedLocation = $true
		$output = & $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ }
		$exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
		return [pscustomobject]@{
			Success  = ($exitCode -eq 0)
			ExitCode = $exitCode
			Output   = (($output | Where-Object { $_ -ne $null }) -join "`r`n").Trim()
		}
	} catch {
		return [pscustomobject]@{
			Success  = $false
			ExitCode = -1
			Output   = (($_ | Out-String).Trim())
		}
	} finally {
		if ($pushedLocation) {
			Pop-Location
		}
	}
}


function Get-RepositoryUpdateStatus {
	param([bool]$FetchRemote = $true)

	$gitPath = Get-GitCommandPath
	$status = [ordered]@{
		Available   = $false
		GitPath     = $gitPath
		RepoExists  = $false
		FetchOk     = $true
		Dirty       = $false
		Branch      = ""
		RemoteUrl   = ""
		Upstream    = ""
		Ahead       = 0
		Behind      = 0
		FetchOutput = ""
	}

	if (-not $gitPath) {
		return [pscustomobject]$status
	}

	$resolvedRootDir = Get-RootDirSafe
	if ([string]::IsNullOrWhiteSpace($resolvedRootDir)) {
		return [pscustomobject]$status
	}

	$repoMarker = Join-Path $resolvedRootDir ".git"
	if (-not (Test-Path -LiteralPath $repoMarker)) {
		return [pscustomobject]$status
	}

	$status.RepoExists = $true
	$status.Available = $true

	if ($FetchRemote) {
		$fetchResult = Invoke-ExternalCommand -FilePath $gitPath -Arguments @("fetch", "origin", "--prune")
		$status.FetchOk = [bool]$fetchResult.Success
		$status.FetchOutput = [string]$fetchResult.Output
	}

	$branchResult = Invoke-ExternalCommand -FilePath $gitPath -Arguments @("branch", "--show-current")
	if ($branchResult.Success) {
		$status.Branch = [string]$branchResult.Output.Trim()
	}

	$remoteResult = Invoke-ExternalCommand -FilePath $gitPath -Arguments @("remote", "get-url", "origin")
	if ($remoteResult.Success) {
		$status.RemoteUrl = [string]$remoteResult.Output.Trim()
	}

	$dirtyResult = Invoke-ExternalCommand -FilePath $gitPath -Arguments @("status", "--porcelain")
	if ($dirtyResult.Success) {
		$status.Dirty = -not [string]::IsNullOrWhiteSpace([string]$dirtyResult.Output)
	}

	$upstreamResult = Invoke-ExternalCommand -FilePath $gitPath -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
	if ($upstreamResult.Success) {
		$status.Upstream = [string]$upstreamResult.Output.Trim()

		$countResult = Invoke-ExternalCommand -FilePath $gitPath -Arguments @("rev-list", "--left-right", "--count", "HEAD...@{u}")
		if ($countResult.Success) {
			$parts = @([regex]::Split(([string]$countResult.Output).Trim(), '\s+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
			if ($parts.Count -ge 2) {
				$status.Ahead = [int]$parts[0]
				$status.Behind = [int]$parts[1]
			}
		}
	}

	return [pscustomobject]$status
}


function Format-RepositoryUpdateStatus {
	param($Status)

	$lines = @()
	$lines += ("updated: " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))

	if (-not $Status.GitPath) {
		$lines += (Get-UiText "updateStateNoGit")
		return ($lines -join "`r`n")
	}

	if (-not $Status.RepoExists) {
		$lines += (Get-UiText "updateStateNoRepo")
		return ($lines -join "`r`n")
	}

	$lines += ((Get-UiText "updateBranchLabel") + ": " + [string]$Status.Branch)
	$lines += ((Get-UiText "updateRemoteLabel") + ": " + [string]$Status.RemoteUrl)
	$lines += ((Get-UiText "updateUpstreamLabel") + ": " + $(if ([string]::IsNullOrWhiteSpace([string]$Status.Upstream)) { "-" } else { [string]$Status.Upstream }))
	$lines += ((Get-UiText "updateAheadLabel") + ": " + [string]$Status.Ahead)
	$lines += ((Get-UiText "updateBehindLabel") + ": " + [string]$Status.Behind)
	$lines += ((Get-UiText "updateDirtyLabel") + ": " + $(if ($Status.Dirty) { "yes" } else { "no" }))
	$lines += ""

	if (-not $Status.FetchOk) {
		$lines += (Get-UiText "updateStateFetchFailed")
		if (-not [string]::IsNullOrWhiteSpace([string]$Status.FetchOutput)) {
			$lines += ""
			$lines += [string]$Status.FetchOutput
		}
		return ($lines -join "`r`n")
	}

	if ([string]::IsNullOrWhiteSpace([string]$Status.Upstream)) {
		$lines += (Get-UiText "updateStateNoUpstream")
	} elseif ($Status.Dirty) {
		$lines += (Get-UiText "updateStateDirty")
	} elseif ($Status.Ahead -gt 0) {
		$lines += (Get-UiText "updateStateAhead")
	} elseif ($Status.Behind -gt 0) {
		$lines += (Get-UiText "updateStateAvailable")
	} else {
		$lines += (Get-UiText "updateStateCurrent")
	}

	return ($lines -join "`r`n")
}


function Invoke-RepositoryUpdate {
	param([bool]$RebuildExe = $false)

	$status = Get-RepositoryUpdateStatus -FetchRemote:$true
	if (-not $status.Available -or -not $status.FetchOk -or [string]::IsNullOrWhiteSpace([string]$status.Upstream) -or $status.Dirty -or ($status.Ahead -gt 0) -or ($status.Behind -le 0)) {
		return [pscustomobject]@{
			Success = $false
			Details = (Format-RepositoryUpdateStatus -Status $status)
		}
	}

	$details = @()
	$backupPath = Backup-ConfigSnapshot -Reason "before-update"
	$details += ([string]::Format((Get-UiText "backupDone"), $backupPath))

	$pullResult = Invoke-ExternalCommand -FilePath $status.GitPath -Arguments @("pull", "--ff-only")
	$details += ""
	$details += (Get-UiText "updateDone")
	if (-not [string]::IsNullOrWhiteSpace([string]$pullResult.Output)) {
		$details += ""
		$details += [string]$pullResult.Output
	}

	if (-not $pullResult.Success) {
		return [pscustomobject]@{
			Success = $false
			Details = (($details + "" + (Get-UiText "updateFailed")) -join "`r`n")
		}
	}

	$buildSuccess = $true
	if ($RebuildExe) {
		$buildScript = Join-Path (Get-RootDirSafe) "scripts\build-exe.ps1"
		if (Test-Path -LiteralPath $buildScript -PathType Leaf) {
			$buildResult = Invoke-ExternalCommand -FilePath "powershell.exe" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $buildScript)
			$details += ""
			if ($buildResult.Success) {
				$details += (Get-UiText "updateBuildDone")
			} else {
				$details += (Get-UiText "updateBuildFailed")
				$buildSuccess = $false
			}

			if (-not [string]::IsNullOrWhiteSpace([string]$buildResult.Output)) {
				$details += ""
				$details += [string]$buildResult.Output
			}
		}
	}

	$details += ""
	$details += (Get-UiText "updateRestartNotice")

	return [pscustomobject]@{
		Success = ($pullResult.Success -and $buildSuccess)
		Details = ($details -join "`r`n")
	}
}


function Get-ExePathForNgl {
	param(
		[hashtable]$EnvMap,
		[string]$Ngl
	)

	if ([string]$Ngl -eq "0") {
		return [string]$EnvMap.LLAMA_CPP_EXE_CPU
	}

	return [string]$EnvMap.LLAMA_CPP_EXE_GPU
}


function Test-IsBundledGpuExePath {
	param([string]$LlamaCppExePath)

	if ([string]::IsNullOrWhiteSpace($LlamaCppExePath)) {
		return $false
	}

	$target = [System.IO.Path]::GetFullPath($LlamaCppExePath).TrimEnd('\\')
	$gpuExe = [System.IO.Path]::GetFullPath((Join-Path $bundledGpuDir "llama-server.exe")).TrimEnd('\\')
	$legacyExe = [System.IO.Path]::GetFullPath((Join-Path $bundledBinDir "llama-server.exe")).TrimEnd('\\')

	return ($target -eq $gpuExe) -or ($target -eq $legacyExe)
}


function Test-BundledCudaRuntimeAvailable {
	param([string]$LlamaCppExePath)

	if (-not (Test-IsBundledGpuExePath -LlamaCppExePath $LlamaCppExePath)) {
		return $true
	}

	$exeDir = Split-Path -Parent $LlamaCppExePath
	$cudaRuntimeDirs = Get-CudaRuntimeDirectories
	if ($cudaRuntimeDirs.Count -gt 0) {
		foreach ($dir in @($cudaRuntimeDirs)) {
			if (Test-Path -LiteralPath (Join-Path $dir "cublas64_13.dll") -PathType Leaf) {
				return $true
			}
		}
	}

	if (-not $exeDir) {
		return $false
	}

	return (Test-Path -LiteralPath (Join-Path $exeDir "cublas64_13.dll") -PathType Leaf)
}


function Get-CudaRuntimeDirectories {
	$dirs = New-Object System.Collections.Generic.List[string]
	$envCudaPaths = @(
		$env:CUDA_PATH,
		$env:CUDA_PATH_V13_2,
		$env:CUDA_PATH_V13_1,
		$env:CUDA_PATH_V13_0
	)

	foreach ($base in @($envCudaPaths)) {
		if ([string]::IsNullOrWhiteSpace([string]$base)) {
			continue
		}

		$basePath = [string]$base
		foreach ($candidate in @(
			(Join-Path $basePath "bin\\x64"),
			(Join-Path $basePath "bin"),
			$basePath
		)) {
			if ((Test-Path -LiteralPath $candidate -PathType Container) -and -not $dirs.Contains($candidate)) {
				$dirs.Add($candidate)
			}
		}
	}

	$searchRoots = @(
		"C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA",
		"C:\Program Files (x86)\NVIDIA GPU Computing Toolkit\CUDA"
	)

	foreach ($root in @($searchRoots)) {
		if (-not (Test-Path -LiteralPath $root -PathType Container)) {
			continue
		}

		Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
			foreach ($candidate in @(
				(Join-Path $_.FullName "bin\\x64"),
				(Join-Path $_.FullName "bin")
			)) {
				if ((Test-Path -LiteralPath $candidate -PathType Container) -and -not $dirs.Contains($candidate)) {
					$dirs.Add($candidate)
				}
			}
		}
	}

	return @($dirs)
}


function Add-CudaRuntimeToPath {
	$dirs = @(Get-CudaRuntimeDirectories)
	if ($dirs.Count -eq 0) {
		return $null
	}

	$originalPath = [string]$env:PATH
	$extra = ($dirs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) -join ';'
	if ([string]::IsNullOrWhiteSpace($extra)) {
		return $null
	}

	if ($originalPath -like ($extra + '*')) {
		return $null
	}

	$env:PATH = $extra + ';' + $originalPath
	return $originalPath
}


function Test-LlamaServerHealth {
	param([hashtable]$EnvMap)

	$url = "http://{0}:{1}/health" -f $EnvMap.LLAMA_HOST, $EnvMap.LLAMA_PORT
	try {
		$response = Invoke-WebRequest -UseBasicParsing $url -TimeoutSec 3
		return $response.StatusCode -ge 200 -and $response.StatusCode -lt 500
	} catch {
		return $false
	}
}


function Wait-HttpReady {
	param(
		[string]$Url,
		[int]$Attempts = 30,
		[int]$DelayMs = 1000
	)

	for ($i = 0; $i -lt $Attempts; $i++) {
		try {
			$formsAppType = [System.Type]::GetType("System.Windows.Forms.Application, System.Windows.Forms", $false)
			if ($formsAppType) {
				$formsAppType.GetMethod("DoEvents", [System.Type[]]@()).Invoke($null, @()) | Out-Null
			}
		} catch {}

		try {
			$response = Invoke-WebRequest -UseBasicParsing $Url -TimeoutSec 2
			if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
				return $true
			}
		} catch {}
		Start-Sleep -Milliseconds $DelayMs
	}

	return $false
}


function Get-FileTailText {
	param(
		[string]$Path,
		[int]$Lines = 12
	)

	if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		return ""
	}

	try {
		return ((Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop) -join "`r`n")
	} catch {
		return ""
	}
}


function Get-LlamaTimeoutDetails {
	param(
		[array]$ProcessStates,
		[array]$Agents,
		[hashtable]$EnvMap
	)

	$lines = @()
	$lines += "[llama-server]"
	foreach ($agent in @($Agents)) {
		$state = @($ProcessStates | Where-Object { [string]$_.id -eq [string]$agent.id } | Select-Object -First 1)
		$procId = if ($state) { [int]$state.pid } else { 0 }
		$running = $false
		if ($procId -gt 0) {
			$running = [bool](Get-Process -Id $procId -ErrorAction SilentlyContinue)
		}

		$healthUrl = "http://{0}:{1}/health" -f $EnvMap.LLAMA_HOST, [string]$agent.llamaPort
		$health = Wait-HttpReady -Url $healthUrl -Attempts 1 -DelayMs 10
		$lines += ("- {0} / pid={1} / running={2} / health={3}" -f [string]$agent.name, $procId, $running, $health)

		if ($state -and $state.stderrLog) {
			$tail = Get-FileTailText -Path ([string]$state.stderrLog) -Lines 10
			if (-not [string]::IsNullOrWhiteSpace($tail)) {
				$lines += "  stderr tail:"
				$lines += $tail
			}
		}
	}

	return ($lines -join "`r`n")
}


function Get-LocalServerStatusDetails {
	param([string]$StateFile)

	$healthUrl = "http://127.0.0.1:4173/__health"
	$health = Wait-HttpReady -Url $healthUrl -Attempts 1 -DelayMs 10
	$state = Read-JsonFile -Path $StateFile
	$procId = 0
	if ($state -and $state.pid) {
		$procId = [int]$state.pid
	}
	$running = $false
	if ($procId -gt 0) {
		$running = [bool](Get-Process -Id $procId -ErrorAction SilentlyContinue)
	}

	return "[local-server] pid={0} / running={1} / health={2}" -f $procId, $running, $health
}


function Get-HealthOverviewText {
	$lines = @()
	$lines += ("updated: " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))

	$llamaState = Read-JsonFile -Path $llamaStateFile
	$processes = @()
	if ($llamaState -and $llamaState.processes) {
		$processes = @($llamaState.processes)
	}

	$lines += "[llama-server]"
	if ($processes.Count -eq 0) {
		$lines += "- no tracked process"
	} else {
		foreach ($p in $processes) {
			$procId = [int]$p.pid
			$running = [bool](Get-Process -Id $procId -ErrorAction SilentlyContinue)
			$url = [string]$p.url
			$health = Wait-HttpReady -Url ($url.TrimEnd('/') + '/health') -Attempts 1 -DelayMs 10
			$lines += ("- {0} pid={1} running={2} health={3} url={4}" -f [string]$p.name, $procId, $running, $health, $url)
		}
	}

	$lines += ""
	$lines += "[local-server]"
	$lines += (Get-LocalServerStatusDetails -StateFile $gameStateFile)

	return ($lines -join "`r`n")
}


function Get-AvailableLogFiles {
	if (-not (Test-Path -LiteralPath $launcherLogDir -PathType Container)) {
		return @()
	}

	$files = @(
		Get-ChildItem -LiteralPath $launcherLogDir -File | Where-Object {
			$ext = [string]$_.Extension
			$name = [string]$_.Name
			($ext -in @('.log', '.txt')) -and ($name -notin @('LOG', 'startup-popup.signal'))
		} | Sort-Object LastWriteTime -Descending
	)
	return @($files | Select-Object -ExpandProperty FullName)
}


function Get-LogPreviewText {
	param(
		[string]$Path,
		[int]$TailLines = 300
	)

	if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		return ""
	}

	try {
		$file = Get-Item -LiteralPath $Path -ErrorAction Stop
		$tail = @(Get-Content -LiteralPath $Path -Tail $TailLines -Encoding UTF8 -ErrorAction Stop)
		$prefix = @(
			("file: {0}" -f $file.FullName),
			("size: {0:N1} MiB" -f ($file.Length / 1MB)),
			("updated: {0}" -f $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")),
			("preview: last {0} line(s)" -f $tail.Count),
			""
		)
		return (($prefix + $tail) -join "`r`n")
	} catch {
		return ("Failed to read log preview: {0}" -f (($_ | Out-String).TrimEnd()))
	}
}


function Invoke-LaunchPreflight {
	param(
		[hashtable]$EnvMap,
		[array]$ActiveAgents,
		[bool]$CpuMode
	)

	$issues = @()
	$warnings = @()

	$exeToUse = if ($CpuMode) { [string]$EnvMap.LLAMA_CPP_EXE_CPU } else { [string]$EnvMap.LLAMA_CPP_EXE_GPU }
	if ([string]::IsNullOrWhiteSpace($exeToUse) -or -not (Test-Path -LiteralPath $exeToUse -PathType Leaf)) {
		$issues += ("exe not found: " + $exeToUse)
	}

	foreach ($a in @($ActiveAgents)) {
		$modelPath = [string]$a.modelPath
		if ([string]::IsNullOrWhiteSpace($modelPath) -or -not (Test-Path -LiteralPath $modelPath -PathType Leaf)) {
			$issues += ("model not found: " + $modelPath)
		}

		$portNumber = 0
		if ([int]::TryParse([string]$a.llamaPort, [ref]$portNumber)) {
			try {
				$listener = Get-NetTCPConnection -LocalAddress 127.0.0.1 -State Listen -LocalPort $portNumber -ErrorAction SilentlyContinue | Select-Object -First 1
				if ($listener) {
					$warnings += ("port already listening: " + $portNumber)
				}
			} catch {}
		} else {
			$issues += ("invalid port: " + [string]$a.llamaPort)
		}
	}

	if (-not $CpuMode) {
		if (-not (Test-NvidiaGpuDetected)) {
			$issues += "GPU mode selected but NVIDIA GPU not detected"
		}
	}

	$lines = @("[preflight]")
	if ($issues.Count -eq 0 -and $warnings.Count -eq 0) {
		$lines += "OK"
	}
	foreach ($i in $issues) { $lines += ("ERROR: " + $i) }
	foreach ($w in $warnings) { $lines += ("WARN: " + $w) }

	return [pscustomobject]@{
		Ok      = ($issues.Count -eq 0)
		Details = ($lines -join "`r`n")
	}
}


function Get-LaunchProfiles {
	param([string]$Path)

	$data = Read-JsonFile -Path $Path
	if (-not $data -or -not $data.profiles) {
		return @()
	}

	return @($data.profiles)
}


function Save-LaunchProfiles {
	param(
		[string]$Path,
		[array]$Profiles
	)

	Write-JsonFile -Path $Path -Data ([ordered]@{
		generatedAt = (Get-Date).ToString("o")
		profiles    = @($Profiles)
	})
}


function Save-BootConfigState {
	param([string]$Path)

	Write-JsonFile -Path $Path -Data ([ordered]@{
		generatedAt = (Get-Date).ToString("o")
		boot        = Get-BootConfigState
	})
}


function Get-SavedBootConfigState {
	param([string]$Path)

	$defaults = [ordered]@{
		modelFolder      = [string]$modelsDir
		cpuExePath       = [string]$script:envMap.LLAMA_CPP_EXE_CPU
		gpuExePath       = [string]$script:envMap.LLAMA_CPP_EXE_GPU
		selectedMode     = if ([string]$script:envMap.LLAMA_NGL -eq "0") { "cpu" } else { "gpu" }
		defaultHost      = [string]$script:envMap.LLAMA_HOST
		defaultPort      = [string]$script:envMap.LLAMA_PORT
		defaultNgl       = [string]$script:envMap.LLAMA_NGL
		defaultCtx       = [string]$script:envMap.LLAMA_CTX
		defaultExtraArgs = [string]$script:envMap.LLAMA_EXTRA_ARGS
	}

	$data = Read-JsonFile -Path $Path
	if (-not $data -or -not $data.boot) {
		return [pscustomobject]$defaults
	}

	foreach ($k in @($defaults.Keys)) {
		if ($data.boot.PSObject.Properties.Name -contains $k) {
			$defaults[$k] = [string]$data.boot.$k
		}
	}

	return [pscustomobject]$defaults
}


function Capture-CurrentProfileData {
	return [ordered]@{
		envMap = [ordered]@{
			LLAMA_CPP_EXE_CPU = [string]$script:envMap.LLAMA_CPP_EXE_CPU
			LLAMA_CPP_EXE_GPU = [string]$script:envMap.LLAMA_CPP_EXE_GPU
			LLAMA_PORT        = [string]$script:envMap.LLAMA_PORT
			LLAMA_HOST        = [string]$script:envMap.LLAMA_HOST
			LLAMA_NGL         = [string]$script:envMap.LLAMA_NGL
			LLAMA_CTX         = [string]$script:envMap.LLAMA_CTX
			LLAMA_EXTRA_ARGS  = [string]$script:envMap.LLAMA_EXTRA_ARGS
		}
		agents = @($script:agents)
	}
}


function Apply-LaunchProfileData {
	param($ProfileData)

	if (-not $ProfileData) {
		return
	}

	if ($ProfileData.envMap) {
		foreach ($k in $ProfileData.envMap.PSObject.Properties.Name) {
			$script:envMap[$k] = [string]$ProfileData.envMap.$k
		}
	}

	Ensure-ModeExePaths -EnvMap $script:envMap

	if ($ProfileData.agents) {
		$script:agents = @($ProfileData.agents)
		[void](Repair-AgentEntries -AgentItems $script:agents -KnownModels $models -EnvMap $script:envMap)
	}
}


function Stop-TrackedProcess {
	param([string]$StateFile)

	$state = Read-JsonFile -Path $StateFile
	if (-not $state) {
		return
	}

	$entries = @()
	if ($state.pid) {
		$entries = @($state)
	} elseif ($state.processes) {
		$entries = @($state.processes)
	}

	foreach ($entry in $entries) {
		if (-not $entry.pid) { continue }
		try {
			$proc = Get-Process -Id ([int]$entry.pid) -ErrorAction Stop
			Stop-Process -Id $proc.Id -Force -ErrorAction Stop
			Start-Sleep -Milliseconds 400
		} catch {}
	}
}


function Start-LlamaServersHidden {
	param(
		[hashtable]$EnvMap,
		[array]$Agents,
		[string]$StateFile
	)

	Stop-TrackedProcess -StateFile $StateFile

	$processStates = @()
	$script:lastStartupErrorDetails = ""
	foreach ($agent in @($Agents)) {
		$agentEnv = @{}
		foreach ($key in $EnvMap.Keys) {
			$agentEnv[$key] = $EnvMap[$key]
		}

		$agentEnv.LLAMA_MODEL_PATH = [string]$agent.modelPath
		$agentEnv.LLAMA_PORT = [string]$agent.llamaPort
		$agentEnv.LLAMA_CTX = [string]$agent.llamaCtx
		$agentEnv.LLAMA_NGL = [string]$agent.llamaNgl

		$launchExe = Resolve-LaunchPath -Path (Get-ExePathForNgl -EnvMap $agentEnv -Ngl ([string]$agentEnv.LLAMA_NGL))
		$launchModel = Resolve-ModelLaunchPath -ModelPath $agentEnv.LLAMA_MODEL_PATH
		$serverUrl = "http://{0}:{1}" -f $agentEnv.LLAMA_HOST, $agentEnv.LLAMA_PORT
		$healthUrl = "$serverUrl/health"

		$launchArguments = @(
			'-m', $launchModel,
			'--host', $agentEnv.LLAMA_HOST,
			'--port', $agentEnv.LLAMA_PORT,
			'-c', $agentEnv.LLAMA_CTX,
			'-ngl', $agentEnv.LLAMA_NGL
		)

		if ($agentEnv.LLAMA_EXTRA_ARGS) {
			$launchArguments += ($agentEnv.LLAMA_EXTRA_ARGS -split '\\s+' | Where-Object { $_ })
		}

		$stdoutLog = Join-Path $launcherLogDir ("llama-{0}.stdout.log" -f [string]$agent.id)
		$stderrLog = Join-Path $launcherLogDir ("llama-{0}.stderr.log" -f [string]$agent.id)
		Remove-Item -LiteralPath $stdoutLog,$stderrLog -ErrorAction SilentlyContinue

		$originalPath = $null
		if ([string]$agentEnv.LLAMA_NGL -ne "0") {
			$originalPath = Add-CudaRuntimeToPath
		}

		try {
			$proc = Start-Process -FilePath $launchExe -ArgumentList $launchArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
		} finally {
			if ($null -ne $originalPath) {
				$env:PATH = $originalPath
			}
		}
		$processStates += [ordered]@{
			id        = [string]$agent.id
			name      = [string]$agent.name
			pid       = $proc.Id
			startedAt = (Get-Date).ToString("o")
			modelPath = $agentEnv.LLAMA_MODEL_PATH
			launchModelPath = $launchModel
			ngl       = $agentEnv.LLAMA_NGL
			url       = $serverUrl
			stdoutLog = $stdoutLog
			stderrLog = $stderrLog
		}

		if (-not (Wait-HttpReady -Url $healthUrl -Attempts 30 -DelayMs 1000)) {
			$script:lastStartupErrorDetails = Get-LlamaTimeoutDetails -ProcessStates $processStates -Agents $Agents -EnvMap $EnvMap
			Write-JsonFile -Path $StateFile -Data ([ordered]@{ processes = $processStates })
			return $false
		}
	}

	Write-JsonFile -Path $StateFile -Data ([ordered]@{ processes = $processStates })
	return $true
}


function Ensure-GameServer {
	param(
		[string]$RootDir,
		[string]$StateFile,
		[int]$Port = 4173
	)

	$healthUrl = "http://127.0.0.1:$Port/__health"
	$script:lastGameStartupErrorDetails = ""
	if (Wait-HttpReady -Url $healthUrl -Attempts 1 -DelayMs 10) {
		return $true
	}

	$serveScript = Join-Path $RootDir "scripts\\serve-game.ps1"
	$psArgs = @(
		'-NoProfile',
		'-WindowStyle', 'Hidden',
		'-ExecutionPolicy', 'Bypass',
		'-File', $serveScript,
		'-Root', $RootDir,
		'-Port', $Port
	)

	$stdoutLog = Join-Path $launcherLogDir "local-server.stdout.log"
	$stderrLog = Join-Path $launcherLogDir "local-server.stderr.log"
	Remove-Item -LiteralPath $stdoutLog,$stderrLog -ErrorAction SilentlyContinue

	$proc = Start-Process -FilePath "powershell.exe" -ArgumentList $psArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
	$stateObj = [ordered]@{
		pid       = $proc.Id
		startedAt = (Get-Date).ToString("o")
		url       = "http://127.0.0.1:$Port/index.html"
		stdoutLog = $stdoutLog
		stderrLog = $stderrLog
	}
	Write-JsonFile -Path $StateFile -Data $stateObj
	$ok = Wait-HttpReady -Url $healthUrl -Attempts 20 -DelayMs 500
	if (-not $ok) {
		$tail = Get-FileTailText -Path $stderrLog -Lines 20
		$script:lastGameStartupErrorDetails = (Get-LocalServerStatusDetails -StateFile $StateFile)
		if (-not [string]::IsNullOrWhiteSpace($tail)) {
			$script:lastGameStartupErrorDetails += "`r`nlocal stderr tail:`r`n" + $tail
		}
	}

	return $ok
}


function Write-LauncherErrorReport {
	param(
		[string]$Title,
		[string]$Details
	)

	$errorDir = Join-Path $launcherLogDir "error"
	if (-not (Test-Path -LiteralPath $errorDir -PathType Container)) {
		New-Item -ItemType Directory -Path $errorDir -Force | Out-Null
	}

	$reportPath = Join-Path $errorDir "launcher-error.txt"
	$content = @(
		$Title,
		('=' * 48),
		$Details
	) -join "`r`n"

	[System.IO.File]::WriteAllText($reportPath, $content + "`r`n", [System.Text.UTF8Encoding]::new($false))
	return $reportPath
}


function Stop-AllFromLauncher {
	try {
		$stopScript = Join-Path $scriptDir "stop-runtime.ps1"
		$proc = Start-Process -FilePath "powershell.exe" -ArgumentList @(
			"-NoProfile",
			"-ExecutionPolicy", "Bypass",
			"-File", $stopScript
		) -PassThru -Wait

		if ($proc.ExitCode -ne 0) {
			throw "stop-runtime.ps1 exited with code $($proc.ExitCode)."
		}

		return $true
	} catch {
		Show-LauncherError -Title "Stop all failed" -Details (($_ | Out-String).TrimEnd())
		return $false
	}
}


function Start-LauncherExitWatchdog {
	param(
		[int]$LauncherPid,
		[string]$StopScriptPath
	)

	$command = @"
`$pidToWatch = $LauncherPid
`$stopScript = '$StopScriptPath'
while (`$true) {
	`$p = Get-Process -Id `$pidToWatch -ErrorAction SilentlyContinue
	if (`$null -eq `$p) { break }
	Start-Sleep -Milliseconds 500
}
try {
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$stopScript | Out-Null
} catch {}
"@

	Start-Process -FilePath "powershell.exe" -ArgumentList @(
		"-NoProfile",
		"-WindowStyle", "Hidden",
		"-ExecutionPolicy", "Bypass",
		"-Command", $command
	) -WindowStyle Hidden | Out-Null
}


function Get-SystemInfoText {
	$gpu = $null
	$ram = $null
	try {
		$gpu = Get-CimInstance Win32_VideoController |
			Where-Object { $_.AdapterRAM -gt 0 } |
			Sort-Object AdapterRAM -Descending |
			Select-Object -First 1
	} catch {}

	try {
		$ram = Get-CimInstance Win32_ComputerSystem
	} catch {}

	$ramGiB = if ($ram.TotalPhysicalMemory) { [math]::Round(([int64]$ram.TotalPhysicalMemory / 1GB), 2) } else { 0 }
	$gpuText = if ($gpu) {
		"GPU: {0} ({1} GiB VRAM)" -f $gpu.Name, [math]::Round(([int64]$gpu.AdapterRAM / 1GB), 2)
	} else {
		"GPU: not detected"
	}

	return [ordered]@{
		RamGiB = $ramGiB
		Text   = ("RAM: {0} GiB | {1}" -f $ramGiB, $gpuText)
	}
}


function Test-NvidiaGpuDetected {
	try {
		$gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.AdapterRAM -gt 0 })
		foreach ($gpu in $gpus) {
			$compatibility = [string]$gpu.AdapterCompatibility
			$name = [string]$gpu.Name
			if ($compatibility -match 'NVIDIA' -or $name -match 'NVIDIA') {
				return $true
			}
		}
	} catch {}

	return $false
}


function Get-EstimateText {
	param(
		[array]$SelectedAgents,
		[bool]$CpuMode,
		[double]$RamGiB
	)

	if ($SelectedAgents.Count -eq 0) {
		return (Get-UiText "estimateNone")
	}

	$totalSize = 0.0
	foreach ($agent in $SelectedAgents) {
		if ($agent.modelPath -and (Test-Path -LiteralPath $agent.modelPath -PathType Leaf)) {
			$totalSize += ([System.IO.FileInfo]$agent.modelPath).Length / 1GB
		}
	}

	$totalSize = [math]::Round($totalSize, 2)
	if ($CpuMode) {
		$need = [math]::Round(($totalSize * 1.35) + 2.0, 2)
		return ([string]::Format((Get-UiText "estimateCpu"), $totalSize, $need, $RamGiB))
	}

	$needGpu = [math]::Round(($totalSize * 1.15) + 1.0, 2)
	return ([string]::Format((Get-UiText "estimateGpu"), $totalSize, $needGpu))
}


function New-DefaultAgents {
	param(
		[array]$Models,
		[hashtable]$EnvMap
	)

	$defaultModel = if ($Models.Count -gt 0) { $Models[0].FullName } elseif (-not [string]::IsNullOrWhiteSpace([string]$EnvMap.LLAMA_MODEL_PATH)) { [string]$EnvMap.LLAMA_MODEL_PATH } else { "" }
	return @(
		[pscustomobject][ordered]@{ no = 1; id = "agent-1"; name = "AI 1"; enabled = $true; modelPath = $defaultModel; llamaPort = [string]$EnvMap.LLAMA_PORT; llamaNgl = [string]$EnvMap.LLAMA_NGL; llamaCtx = [string]$EnvMap.LLAMA_CTX }
	)
}


function Get-AgentsFingerprint {
	param([array]$AgentItems)
	return ((@($AgentItems) | ConvertTo-Json -Depth 8 -Compress))
}


function Load-Agents {
	param(
		[string]$Path,
		[array]$Models,
		[hashtable]$EnvMap
	)

	$raw = Read-JsonFile -Path $Path
	if ($raw -and $raw.agents) {
		$loaded = @()
		if ($raw.agents -is [System.Collections.IDictionary]) {
			$loaded = @([pscustomobject]$raw.agents)
		} else {
			$loaded = @($raw.agents)
		}

		$normalized = @()
		foreach ($item in $loaded) {
			if ($null -eq $item) { continue }
			if ($item -is [System.Collections.DictionaryEntry]) { continue }
			$props = $item.PSObject.Properties.Name
			if (-not ($props -contains 'id' -or $props -contains 'name' -or $props -contains 'modelPath')) {
				continue
			}
			$normalized += $item
		}

		if ($normalized.Count -gt 0) {
			return @($normalized)
		}
	}

	return @(New-DefaultAgents -Models $Models -EnvMap $EnvMap)
}


function Get-ValidAgents {
	param([array]$AgentItems)

	$result = @()
	foreach ($item in @($AgentItems)) {
		if ($null -eq $item) { continue }
		if ($item -is [System.Collections.DictionaryEntry]) { continue }
		$props = $item.PSObject.Properties.Name
		if (-not ($props -contains 'id' -or $props -contains 'name' -or $props -contains 'modelPath')) {
			continue
		}
		$result += $item
	}

	return @($result)
}


function Save-Agents {
	param(
		[string]$Path,
		[array]$Agents
	)

	for ($i = 0; $i -lt $Agents.Count; $i++) {
		$Agents[$i].no = $i + 1
	}

	$data = [ordered]@{
		generatedAt = (Get-Date).ToString("o")
		agents      = $Agents
	}
	Write-JsonFile -Path $Path -Data $data
}


function Write-RuntimeProfile {
	param(
		[string]$ProfilePath,
		[hashtable]$EnvMap,
		[array]$Agents,
		[array]$ActiveAgentIds
	)

	$runtimeData = [ordered]@{
		generatedAt     = (Get-Date).ToString("o")
		llamaCppUrl     = "http://{0}:{1}" -f $EnvMap.LLAMA_HOST, $EnvMap.LLAMA_PORT
		llamaHost       = [string]$EnvMap.LLAMA_HOST
		llamaPort       = [string]$EnvMap.LLAMA_PORT
		modelPath       = [string]$EnvMap.LLAMA_MODEL_PATH
		modelName       = [System.IO.Path]::GetFileName([string]$EnvMap.LLAMA_MODEL_PATH)
		mode            = if ($EnvMap.LLAMA_NGL -eq "0") { "cpu" } else { "gpu" }
		envMap          = [ordered]@{
			LLAMA_CPP_EXE_CPU = [string]$EnvMap.LLAMA_CPP_EXE_CPU
			LLAMA_CPP_EXE_GPU = [string]$EnvMap.LLAMA_CPP_EXE_GPU
			LLAMA_MODEL_PATH  = [string]$EnvMap.LLAMA_MODEL_PATH
			LLAMA_HOST        = [string]$EnvMap.LLAMA_HOST
			LLAMA_PORT        = [string]$EnvMap.LLAMA_PORT
			LLAMA_NGL         = [string]$EnvMap.LLAMA_NGL
			LLAMA_CTX         = [string]$EnvMap.LLAMA_CTX
			LLAMA_EXTRA_ARGS  = [string]$EnvMap.LLAMA_EXTRA_ARGS
		}
		activeAgentIds  = $ActiveAgentIds
		agents          = $Agents
	}

	Write-JsonFile -Path $ProfilePath -Data $runtimeData
}


function Get-PortSeedFromId {
	param(
		[string]$Id,
		[int]$FallbackIndex
	)

	if ($Id -match '(\d+)') {
		return (8080 + [int]$Matches[1])
	}

	return (8080 + $FallbackIndex)
}


function Repair-AgentEntries {
	param(
		[array]$AgentItems,
		[array]$KnownModels,
		[hashtable]$EnvMap
	)

	$usedPorts = @{}
	$changed = 0
	$defaultModelPath = if ($KnownModels.Count -gt 0) { $KnownModels[0].FullName } elseif (-not [string]::IsNullOrWhiteSpace([string]$EnvMap.LLAMA_MODEL_PATH)) { [string]$EnvMap.LLAMA_MODEL_PATH } else { "" }

	for ($i = 0; $i -lt $AgentItems.Count; $i++) {
		$a = $AgentItems[$i]

		$expectedId = "agent-{0}" -f ($i + 1)
		if ([string]::IsNullOrWhiteSpace([string]$a.id)) {
			$a.id = $expectedId
			$changed += 1
		}
		if ([string]::IsNullOrWhiteSpace([string]$a.name)) {
			$a.name = "AI {0}" -f ($i + 1)
			$changed += 1
		}
		if ([string]::IsNullOrWhiteSpace([string]$a.modelPath) -and -not [string]::IsNullOrWhiteSpace($defaultModelPath)) {
			$a.modelPath = $defaultModelPath
			$changed += 1
		}

		$seed = Get-PortSeedFromId -Id ([string]$a.id) -FallbackIndex ($i + 1)
		$portValue = 0
		if (-not [int]::TryParse([string]$a.llamaPort, [ref]$portValue) -or $portValue -lt 1 -or $portValue -gt 65535) {
			$portValue = $seed
			$changed += 1
		}

		while ($usedPorts.ContainsKey($portValue)) {
			$portValue += 1
			if ($portValue -gt 65535) {
				$portValue = 1024
			}
			$changed += 1
		}

		$usedPorts[$portValue] = $true
		$a.llamaPort = [string]$portValue

		if ([string]::IsNullOrWhiteSpace([string]$a.llamaNgl)) {
			$a.llamaNgl = [string]$EnvMap.LLAMA_NGL
			$changed += 1
		}
		if ([string]::IsNullOrWhiteSpace([string]$a.llamaCtx)) {
			$a.llamaCtx = [string]$EnvMap.LLAMA_CTX
			$changed += 1
		}

		$a.no = $i + 1
	}

	return $changed
}


