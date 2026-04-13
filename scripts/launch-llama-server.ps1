$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

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
	if ($gpuRadio.Checked -and -not (Test-NvidiaGpuDetected)) {
		$cpuRadio.Checked = $true
		$gpuRadio.Checked = $false
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

function Refresh-UpdateStatus {
	param([bool]$FetchRemote = $true)

	if (-not $updateStatusTextBox) {
		return
	}

	$status = Get-RepositoryUpdateStatus -FetchRemote:$FetchRemote
	$updateStatusTextBox.Text = Format-RepositoryUpdateStatus -Status $status
	$updateApplyButton.Enabled = (-not $script:isUpdateRunning) -and $status.Available -and $status.FetchOk -and (-not $status.Dirty) -and (-not [string]::IsNullOrWhiteSpace([string]$status.Upstream)) -and ($status.Ahead -eq 0) -and ($status.Behind -gt 0)
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

function Get-ExePathForCurrentMode {
	param([hashtable]$EnvMap)

	if ($cpuRadio -and $cpuRadio.Checked) {
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
		[System.Windows.Forms.Application]::DoEvents()
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

function Get-BootConfigState {
	return [ordered]@{
		modelFolder      = [string]$modelFolderBox.Text.Trim()
		cpuExePath       = [string]$exeCpuPathBox.Text.Trim()
		gpuExePath       = [string]$exeGpuPathBox.Text.Trim()
		selectedMode     = if ($cpuRadio.Checked) { "cpu" } else { "gpu" }
		defaultHost      = [string]$script:envMap.LLAMA_HOST
		defaultPort      = [string]$script:envMap.LLAMA_PORT
		defaultNgl       = [string]$script:envMap.LLAMA_NGL
		defaultCtx       = [string]$script:envMap.LLAMA_CTX
		defaultExtraArgs = [string]$script:envMap.LLAMA_EXTRA_ARGS
	}
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
		if (-not $cpuRadio.Checked) {
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
		[string]$StateFile
	)

	$port = 4173
	$healthUrl = "http://127.0.0.1:$port/__health"
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
		'-Port', $port
	)

	$stdoutLog = Join-Path $launcherLogDir "local-server.stdout.log"
	$stderrLog = Join-Path $launcherLogDir "local-server.stderr.log"
	Remove-Item -LiteralPath $stdoutLog,$stderrLog -ErrorAction SilentlyContinue

	$proc = Start-Process -FilePath "powershell.exe" -ArgumentList $psArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
	$stateObj = [ordered]@{
		pid       = $proc.Id
		startedAt = (Get-Date).ToString("o")
		url       = "http://127.0.0.1:$port/index.html"
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

function Show-LauncherError {
	param(
		[string]$Title,
		[string]$Details
	)

	$reportPath = Write-LauncherErrorReport -Title $Title -Details $Details
	$msg = $Title + "`r`n`r`n" + $Details + "`r`n`r`nTXT: " + $reportPath
	[System.Windows.Forms.MessageBox]::Show($msg, "LLM Game Base", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
	Start-Process notepad.exe -ArgumentList $reportPath | Out-Null
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
		modelPath       = [string]$EnvMap.LLAMA_MODEL_PATH
		modelName       = [System.IO.Path]::GetFileName([string]$EnvMap.LLAMA_MODEL_PATH)
		mode            = if ($EnvMap.LLAMA_NGL -eq "0") { "cpu" } else { "gpu" }
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

$script:scriptDir = Get-ScriptDir
$script:rootDir = [string](Resolve-Path (Join-Path $script:scriptDir ".."))
$scriptDir = $script:scriptDir
$rootDir = $script:rootDir
$modelsDir = Join-Path $rootDir "llama-runtime\models"
if (-not (Test-Path -LiteralPath $modelsDir -PathType Container)) {
	$modelsDir = Join-Path $rootDir "models"
}
$bundledRuntimeDir = Join-Path $rootDir "llama-runtime"
$bundledCpuDir = Join-Path $bundledRuntimeDir "cpu"
$bundledGpuDir = Join-Path $bundledRuntimeDir "gpu"
$bundledBinDir = Join-Path $rootDir "llama-runtime\bin"
$envFile = Join-Path $scriptDir "llama-server.env.bat"
$bootConfigFile = Join-Path $rootDir "config\\bootSettings.json"
$runtimeProfileFile = Join-Path $rootDir "config\\runtimeProfile.json"
$agentProfileFile = Join-Path $rootDir "config\\agentsProfile.json"
$uiSettingsFile = Join-Path $rootDir "config\\uiSettings.json"
$launchProfilesFile = Join-Path $rootDir "config\\launchProfiles.json"
$llamaStateFile = Join-Path $scriptDir "llama-server.state.json"
$gameStateFile = Join-Path $scriptDir "game-server.state.json"
$launcherLogDir = Join-Path $rootDir "logs"
if (-not (Test-Path -LiteralPath $launcherLogDir)) {
	New-Item -ItemType Directory -Path $launcherLogDir -Force | Out-Null
}
$startupTraceFile = Join-Path $launcherLogDir "launcher-startup.log"
try {
	[System.IO.File]::WriteAllText($startupTraceFile, "", [System.Text.UTF8Encoding]::new($false))
} catch {}

function Write-StartupTrace {
	param([string]$Message)

	try {
		Add-Content -LiteralPath $startupTraceFile -Encoding UTF8 -Value ((Get-Date).ToString("HH:mm:ss.fff") + " " + $Message)
	} catch {}
}

Write-StartupTrace "begin"

$script:envMap = Get-EnvMap -EnvFile $envFile
Ensure-ModeExePaths -EnvMap $script:envMap
$script:envMap.LLAMA_NGL = if (-not (Test-NvidiaGpuDetected)) { "0" } elseif ([string]::IsNullOrWhiteSpace([string]$script:envMap.LLAMA_NGL)) { "99" } else { [string]$script:envMap.LLAMA_NGL }
if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
	Save-EnvMap -EnvFile $envFile -EnvMap $script:envMap
}
$script:savedBootConfig = $null
$script:savedBootConfig = Get-SavedBootConfigState -Path $bootConfigFile
$script:launchProfiles = @(Get-LaunchProfiles -Path $launchProfilesFile)
$models = Get-Models -ModelsDir $modelsDir
$script:agents = @(Load-Agents -Path $agentProfileFile -Models $models -EnvMap $envMap)
$script:savedAgentsFingerprint = Get-AgentsFingerprint -AgentItems $script:agents
$script:IsLoadingAgentDetail = $false
$script:isUpdateRunning = $false
$uiSettings = Get-UiSettings -Path $uiSettingsFile
$script:currentLanguage = [string]$uiSettings.language
Write-StartupTrace "data loaded"
$script:i18n = @{
	ja = @{
		tabPlay = "プレイ"; tabBoot = "起動構成"; tabAgent = "AIモデル"; tabSettings = "設定"; tabHealth = "ヘルス"; tabLogs = "ログ"
		mode = "実行モード"; estimate = "想定: -"; useAi = "並列起動で使うAI"; ready = "Ready."
		openGame = "ゲームを開く"; start = "llama-server 起動"; close = "閉じる"
		exePathCpu = "CPU 実行パス (LLAMA_CPP_EXE_CPU)"; exePathGpu = "GPU 実行パス (LLAMA_CPP_EXE_GPU)"; browse = "参照"; localCpu = "同梱CPU"; localGpu = "同梱GPU"
		modelFolder = "AIモデルフォルダ (.gguf を走査)"; scan = ".gguf をスキャン"; modelList = "AIモデルのパス一覧"; saveBoot = "起動構成を保存"
		aiList = "AI一覧"; detail = "詳細設定"; name = "名前"; modelName = "モデル名 (起動構成一覧から選択)"
		updateDetail = "詳細を反映"; addAi = "AIを追加"; removeAi = "AIを削除"; saveAi = "AIモデルを保存"
		settingsTitle = "設定"; language = "言語"; applyLanguage = "適用"; resetInit = "初期化設定"
		exportSettings = "エクスポート"; importSettings = "インポート"; resetBoot = "起動構成のみ初期化"; resetAi = "AI設定のみ初期化"; resetAll = "すべて初期化"
		settingsHint = "初期化設定は、起動構成とAIモデル設定を初期値に戻します。"
		gpuDetected = "GPU: NVIDIA を検出しました"; gpuMissing = "GPU: NVIDIA は検出されませんでした"
		cudaOk = "CUDA: 利用可能"; cudaMissing = "CUDA: 利用不可 (cublas64_13.dll が見つかりません)"
		confirmReset = "起動構成とAIモデル設定を初期値に戻します。続行しますか？"
		resetDone = "初期化設定を適用しました。"; langSaved = "言語設定を保存しました。"
		confirmResetBoot = "起動構成のみ初期化します。続行しますか？"; confirmResetAi = "AI設定のみ初期化します。続行しますか？"; confirmResetAll = "すべての設定を初期化します。続行しますか？"
		resetBootDone = "起動構成を初期化しました。"; resetAiDone = "AI設定を初期化しました。"
		exportDone = "設定をエクスポートしました: {0}"; importDone = "設定をインポートしました。"
		backupDone = "バックアップを保存しました: {0}"; backupFailed = "バックアップ保存に失敗しました。"
		pickExport = "エクスポート先を選択"; pickImport = "インポートする設定ファイルを選択"
		importInvalid = "設定ファイルの読み込みに失敗しました。"
		missingBundled = "同梱 llama-server.exe が見つかりません。"; invalidFolder = "有効なフォルダを指定してください。"; noGguf = "指定フォルダに .gguf がありません。"
		atLeastOneAi = "AIは最低1つ必要です。"; savedBoot = "起動構成を保存しました。"
		estimateNone = "想定: AI未選択"; estimateCpu = "想定(CPU): モデル合計 {0} GiB / 必要RAM目安 {1} GiB / 実RAM {2} GiB"; estimateGpu = "想定(GPU): モデル合計 {0} GiB / 必要VRAM目安 {1} GiB"
		statusAiDetailUpdated = "AI詳細を反映しました。"; statusAiDetailAuto = "AI詳細反映 + 自動補正: {0}件"; statusAiAdded = "AIを追加しました。"; statusAiAddedAuto = "AI追加 + Port自動採番"
		statusAiSaved = "AIモデル設定を保存しました。"; statusAiSavedAuto = "AIモデル保存 + Port重複を自動補正"; statusScanning = ".gguf scan: {0}件"
		statusStarting = "llama-server 起動中... ({0} instance(s))"; statusReadyInstances = "Ready: {0} instance(s)"
		statusStartingAnim = "llama-server 起動中{0}"; llamaTimeoutHeader = "llama-server の起動がタイムアウトしました。"
		statusStartingElapsed = "{0}秒経過"
		llamaStateIdle = "llama-server: 待機"; llamaStateStarting = "llama-server: 起動中"; llamaStateReady = "llama-server: 稼働中"; llamaStateFailed = "llama-server: 起動失敗"
		localStateIdle = "local-server: 待機"; localStateStarting = "local-server: 起動中"; localStateReady = "local-server: 稼働中"; localStateFailed = "local-server: 起動失敗"; localStatePending = "local-server: 起動待ち"
		autoFixNotice = "AI設定を自動補正しました（重複Portや空欄）。"; noAiChecked = "並列起動に使うAIを1つ以上チェックしてください。"
		noModelPath = "選択されたAIにモデルパスがありません。AIモデルタブで .gguf を選ぶか、scripts/llama-server.env.bat の LLAMA_MODEL_PATH を設定してください。"; modelNotFound = "モデルファイルが存在しません: {0}"
		nvidiaOnly = "GPUモードはNVIDIA GPU専用です。NVIDIA GPUが検出されなかったため起動を中止しました。CPUモードを選んでください。"
		cudaMissingRun = "CUDA runtime が見つかりません。cublas64_13.dll が無いため GPU モードを起動できません。CUDA を導入するか、CPU モードを選んでください。"
		cudaAutoFallback = "CUDA runtime が見つからないため、CPU モードに切り替えて起動します。"
		exeNotFound = "llama-server.exe が見つかりません: {0}"; llamaNotReady = "llama-server did not become ready within 30 seconds."
		sectionLanguage = "1. 言語"; sectionConfigFiles = "2. 設定ファイル"; sectionReset = "3. 初期化"
		sectionProfile = "4. プロファイル"; profileName = "プロファイル名"; profileSave = "保存"; profileLoad = "読込"; profileSaved = "プロファイル保存: {0}"; profileLoaded = "プロファイル読込: {0}"
		sectionUpdate = "5. アップデート"; updateCheck = "更新確認"; updateApply = "更新実行"; updateRebuild = "更新後にEXE再生成"
		updateStateNoGit = "Git が見つかりません。アップデート機能は Git 管理された開発環境でのみ使えます。"; updateStateNoRepo = "この配置は Git ワークツリーではありません。"
		updateStateNoUpstream = "上流ブランチが設定されていません。"; updateStateFetchFailed = "origin からの更新確認に失敗しました。"
		updateStateDirty = "未コミット変更があります。commit または stash 後に更新してください。"; updateStateAhead = "ローカルコミットが origin より先行しているため、自動更新を止めています。"
		updateStateCurrent = "最新です。"; updateStateAvailable = "更新があります。"
		updateBranchLabel = "branch"; updateRemoteLabel = "origin"; updateUpstreamLabel = "upstream"; updateAheadLabel = "ahead"; updateBehindLabel = "behind"; updateDirtyLabel = "dirty"
		confirmUpdate = "origin から fast-forward 更新します。続行しますか？"; updateRunning = "アップデート中..."; updateDone = "アップデートが完了しました。"; updateFailed = "アップデートに失敗しました。"
		updateBuildDone = "EXE 再生成が完了しました。"; updateBuildFailed = "EXE 再生成に失敗しました。"; updateRestartNotice = "更新後の内容を反映するにはランチャーを再起動してください。"
		healthRefresh = "更新"; logsRefresh = "即時更新"; logsOpen = "開く"; logsAutoUpdate = "自動更新"; logsManualHint = "ログは[即時更新]または[自動更新]ON時のみ更新されます。"; preflightFailed = "起動前チェックでエラーが見つかりました。"; preflightWarnTitle = "起動前チェック"
		bootNotSaved = "起動構成が保存されていません"
		aiNotSaved = "AIモデル設定が保存されていません"; aiDetailNotApplied = "詳細が未反映です"
		cudaMissingBinary = "同梱の llama-server.exe は cublas64_13.dll が必要です。CUDA runtime を入れるか、Browse で CPU対応版の llama-server.exe を選択してください。"
	}
	en = @{
		tabPlay = "Play"; tabBoot = "Boot"; tabAgent = "AI Models"; tabSettings = "Settings"; tabHealth = "Health"; tabLogs = "Logs"
		mode = "Run Mode"; estimate = "Estimate: -"; useAi = "AI to launch in parallel"; ready = "Ready."
		openGame = "Open Game"; start = "Start llama-server"; close = "Close"
		exePathCpu = "CPU executable path (LLAMA_CPP_EXE_CPU)"; exePathGpu = "GPU executable path (LLAMA_CPP_EXE_GPU)"; browse = "Browse"; localCpu = "Bundled CPU"; localGpu = "Bundled GPU"
		modelFolder = "AI model folder (scan .gguf)"; scan = "Scan .gguf"; modelList = "Model path list"; saveBoot = "Save Boot Config"
		aiList = "AI List"; detail = "Details"; name = "Name"; modelName = "Model name (select from boot list)"
		updateDetail = "Apply Details"; addAi = "Add AI"; removeAi = "Remove AI"; saveAi = "Save AI Models"
		settingsTitle = "Settings"; language = "Language"; applyLanguage = "Apply"; resetInit = "Reset to Defaults"
		exportSettings = "Export"; importSettings = "Import"; resetBoot = "Reset Boot Only"; resetAi = "Reset AI Only"; resetAll = "Reset All"
		settingsHint = "Reset to defaults restores boot config and AI model settings."
		gpuDetected = "GPU: NVIDIA detected"; gpuMissing = "GPU: NVIDIA not detected"
		cudaOk = "CUDA: Available"; cudaMissing = "CUDA: Unavailable (cublas64_13.dll not found)"
		confirmReset = "This resets boot and AI model settings to defaults. Continue?"
		resetDone = "Default settings have been applied."; langSaved = "Language setting saved."
		confirmResetBoot = "Reset only boot settings. Continue?"; confirmResetAi = "Reset only AI settings. Continue?"; confirmResetAll = "Reset all settings. Continue?"
		resetBootDone = "Boot settings have been reset."; resetAiDone = "AI settings have been reset."
		exportDone = "Settings exported: {0}"; importDone = "Settings imported."
		backupDone = "Backup saved: {0}"; backupFailed = "Failed to save backup."
		pickExport = "Choose export destination"; pickImport = "Choose settings file to import"
		importInvalid = "Failed to load settings file."
		missingBundled = "Bundled llama-server.exe was not found."; invalidFolder = "Please select a valid folder."; noGguf = "No .gguf files found in the selected folder."
		atLeastOneAi = "At least one AI is required."; savedBoot = "Boot settings saved."
		estimateNone = "Estimate: no AI selected"; estimateCpu = "Estimate (CPU): models {0} GiB / RAM required {1} GiB / RAM {2} GiB"; estimateGpu = "Estimate (GPU): models {0} GiB / VRAM required {1} GiB"
		statusAiDetailUpdated = "AI details updated."; statusAiDetailAuto = "AI details updated + auto-fix: {0}"; statusAiAdded = "AI added."; statusAiAddedAuto = "AI added + port auto-assigned"
		statusAiSaved = "AI model settings saved."; statusAiSavedAuto = "AI models saved + port conflicts fixed"; statusScanning = ".gguf scan: {0}"
		statusStarting = "Starting llama-server... ({0} instance(s))"; statusReadyInstances = "Ready: {0} instance(s)"
		statusStartingAnim = "Starting llama-server{0}"; llamaTimeoutHeader = "llama-server startup timed out."
		statusStartingElapsed = "{0}s elapsed"
		llamaStateIdle = "llama-server: idle"; llamaStateStarting = "llama-server: starting"; llamaStateReady = "llama-server: running"; llamaStateFailed = "llama-server: failed"
		localStateIdle = "local-server: idle"; localStateStarting = "local-server: starting"; localStateReady = "local-server: running"; localStateFailed = "local-server: failed"; localStatePending = "local-server: pending"
		autoFixNotice = "AI settings were auto-fixed."; noAiChecked = "Select at least one AI for parallel launch."
		noModelPath = "The selected AI has no model path. Pick a .gguf in the AI Models tab or set LLAMA_MODEL_PATH in scripts/llama-server.env.bat."; modelNotFound = "Model file not found: {0}"
		nvidiaOnly = "GPU mode requires NVIDIA GPU. No NVIDIA GPU detected; switch to CPU mode."
		cudaMissingRun = "CUDA runtime not found. cublas64_13.dll is missing, so GPU mode cannot start. Install CUDA runtime or choose CPU mode."
		cudaAutoFallback = "CUDA runtime was not found, so launch will switch to CPU mode."
		exeNotFound = "llama-server.exe not found: {0}"; llamaNotReady = "llama-server did not become ready within 30 seconds."
		sectionLanguage = "1. Language"; sectionConfigFiles = "2. Config Files"; sectionReset = "3. Reset"
		sectionProfile = "4. Profiles"; profileName = "Profile name"; profileSave = "Save"; profileLoad = "Load"; profileSaved = "Profile saved: {0}"; profileLoaded = "Profile loaded: {0}"
		sectionUpdate = "5. Update"; updateCheck = "Check"; updateApply = "Update"; updateRebuild = "Rebuild EXEs after update"
		updateStateNoGit = "Git was not found. Update is available only in a git-based development checkout."; updateStateNoRepo = "This copy is not a git working tree."
		updateStateNoUpstream = "No upstream branch is configured."; updateStateFetchFailed = "Failed to fetch updates from origin."
		updateStateDirty = "Uncommitted changes were detected. Commit or stash them before updating."; updateStateAhead = "Local commits are ahead of origin, so automatic update is blocked."
		updateStateCurrent = "Already up to date."; updateStateAvailable = "Updates are available."
		updateBranchLabel = "branch"; updateRemoteLabel = "origin"; updateUpstreamLabel = "upstream"; updateAheadLabel = "ahead"; updateBehindLabel = "behind"; updateDirtyLabel = "dirty"
		confirmUpdate = "Apply a fast-forward update from origin now?"; updateRunning = "Updating..."; updateDone = "Update completed."; updateFailed = "Update failed."
		updateBuildDone = "EXE rebuild completed."; updateBuildFailed = "EXE rebuild failed."; updateRestartNotice = "Restart the launcher to load the updated scripts."
		healthRefresh = "Refresh"; logsRefresh = "Refresh Now"; logsOpen = "Open"; logsAutoUpdate = "Auto refresh"; logsManualHint = "Logs update only when [Refresh Now] is clicked or [Auto refresh] is enabled."; preflightFailed = "Preflight check found errors."; preflightWarnTitle = "Preflight"
		bootNotSaved = "Boot settings are not saved"
		aiNotSaved = "AI model settings are not saved"; aiDetailNotApplied = "Detail changes are not applied"
		cudaMissingBinary = "The bundled llama-server.exe requires cublas64_13.dll. Install CUDA runtime or choose a CPU-compatible llama-server.exe via Browse."
	}
}
$systemInfo = Get-SystemInfoText
$script:IsRefreshingAgentChecks = $false
$script:LastAddAiClickAt = [datetime]::MinValue
$script:IsClosingHandled = $false
$script:lastStartupErrorDetails = ""
$script:lastGameStartupErrorDetails = ""
$script:isStartupAnimating = $false
$script:isRefreshingLogsTab = $false
$script:isLogsAutoUpdateEnabled = $false
$script:startupDotIndex = 0
$script:startupDots = @('.', '..', '....')
$script:startupStartedAt = $null
$script:isModePathSyncing = $false

$form = New-Object System.Windows.Forms.Form
$form.Text = "LLM Game Base Launcher"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(980, 640)
$form.MinimumSize = New-Object System.Drawing.Size(980, 640)
$form.BackColor = [System.Drawing.Color]::FromArgb(6, 6, 6)
$form.ForeColor = [System.Drawing.Color]::Gainsboro
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

$title = New-Object System.Windows.Forms.Label
$title.Text = "LLM Game Base Launcher"
$title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16)
$title.Location = New-Object System.Drawing.Point(18, 12)
$title.Size = New-Object System.Drawing.Size(420, 30)
$form.Controls.Add($title)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(18, 52)
$tabs.Size = New-Object System.Drawing.Size(928, 542)
$form.Controls.Add($tabs)

$tabPlay = New-Object System.Windows.Forms.TabPage
$tabPlay.Text = "プレイ"
$tabPlay.BackColor = [System.Drawing.Color]::FromArgb(10, 10, 10)
$tabPlay.ForeColor = [System.Drawing.Color]::Gainsboro
$tabs.Controls.Add($tabPlay)

$tabBoot = New-Object System.Windows.Forms.TabPage
$tabBoot.Text = "起動構成"
$tabBoot.BackColor = [System.Drawing.Color]::FromArgb(10, 10, 10)
$tabBoot.ForeColor = [System.Drawing.Color]::Gainsboro
$tabs.Controls.Add($tabBoot)

$tabAgent = New-Object System.Windows.Forms.TabPage
$tabAgent.Text = "AIモデル"
$tabAgent.BackColor = [System.Drawing.Color]::FromArgb(10, 10, 10)
$tabAgent.ForeColor = [System.Drawing.Color]::Gainsboro
$tabs.Controls.Add($tabAgent)

$tabSettings = New-Object System.Windows.Forms.TabPage
$tabSettings.Text = "設定"
$tabSettings.BackColor = [System.Drawing.Color]::FromArgb(10, 10, 10)
$tabSettings.ForeColor = [System.Drawing.Color]::Gainsboro
$tabs.Controls.Add($tabSettings)

$tabHealth = New-Object System.Windows.Forms.TabPage
$tabHealth.Text = "ヘルス"
$tabHealth.BackColor = [System.Drawing.Color]::FromArgb(10, 10, 10)
$tabHealth.ForeColor = [System.Drawing.Color]::Gainsboro
$tabs.Controls.Add($tabHealth)

$tabLogs = New-Object System.Windows.Forms.TabPage
$tabLogs.Text = "ログ"
$tabLogs.BackColor = [System.Drawing.Color]::FromArgb(10, 10, 10)
$tabLogs.ForeColor = [System.Drawing.Color]::Gainsboro
$tabs.Controls.Add($tabLogs)
Write-StartupTrace "controls created"

$modeLabel = New-Object System.Windows.Forms.Label
$modeLabel.Text = "実行モード"
$modeLabel.Location = New-Object System.Drawing.Point(18, 16)
$modeLabel.Size = New-Object System.Drawing.Size(120, 24)
$tabPlay.Controls.Add($modeLabel)

$gpuRadio = New-Object System.Windows.Forms.RadioButton
$gpuRadio.Text = "GPU"
$gpuRadio.Location = New-Object System.Drawing.Point(18, 44)
$gpuRadio.Size = New-Object System.Drawing.Size(90, 24)
$gpuRadio.Checked = (Test-NvidiaGpuDetected) -and ($envMap.LLAMA_NGL -ne "0")
$tabPlay.Controls.Add($gpuRadio)

$cpuRadio = New-Object System.Windows.Forms.RadioButton
$cpuRadio.Text = "CPU"
$cpuRadio.Location = New-Object System.Drawing.Point(110, 44)
$cpuRadio.Size = New-Object System.Drawing.Size(90, 24)
$cpuRadio.Checked = (-not (Test-NvidiaGpuDetected)) -or ($envMap.LLAMA_NGL -eq "0")
$tabPlay.Controls.Add($cpuRadio)

$llamaRuntimeStatusLabel = New-Object System.Windows.Forms.Label
$llamaRuntimeStatusLabel.Location = New-Object System.Drawing.Point(220, 46)
$llamaRuntimeStatusLabel.Size = New-Object System.Drawing.Size(320, 22)
$llamaRuntimeStatusLabel.ForeColor = [System.Drawing.Color]::Silver
$llamaRuntimeStatusLabel.Text = "llama-server: idle"
$tabPlay.Controls.Add($llamaRuntimeStatusLabel)

$localRuntimeStatusLabel = New-Object System.Windows.Forms.Label
$localRuntimeStatusLabel.Location = New-Object System.Drawing.Point(548, 46)
$localRuntimeStatusLabel.Size = New-Object System.Drawing.Size(330, 22)
$localRuntimeStatusLabel.ForeColor = [System.Drawing.Color]::Silver
$localRuntimeStatusLabel.Text = "local-server: idle"
$tabPlay.Controls.Add($localRuntimeStatusLabel)

$sysInfoLabel = New-Object System.Windows.Forms.Label
$sysInfoLabel.Text = $systemInfo.Text
$sysInfoLabel.Location = New-Object System.Drawing.Point(18, 78)
$sysInfoLabel.Size = New-Object System.Drawing.Size(860, 24)
$sysInfoLabel.ForeColor = [System.Drawing.Color]::Silver
$tabPlay.Controls.Add($sysInfoLabel)

$gpuStatusLabel = New-Object System.Windows.Forms.Label
$gpuStatusLabel.Location = New-Object System.Drawing.Point(18, 104)
$gpuStatusLabel.Size = New-Object System.Drawing.Size(860, 22)
$gpuStatusLabel.ForeColor = [System.Drawing.Color]::Silver
$tabPlay.Controls.Add($gpuStatusLabel)

$cudaStatusLabel = New-Object System.Windows.Forms.Label
$cudaStatusLabel.Location = New-Object System.Drawing.Point(18, 128)
$cudaStatusLabel.Size = New-Object System.Drawing.Size(860, 22)
$cudaStatusLabel.ForeColor = [System.Drawing.Color]::Silver
$tabPlay.Controls.Add($cudaStatusLabel)

$estimateLabel = New-Object System.Windows.Forms.Label
$estimateLabel.Text = "想定: -"
$estimateLabel.Location = New-Object System.Drawing.Point(18, 152)
$estimateLabel.Size = New-Object System.Drawing.Size(860, 24)
$estimateLabel.ForeColor = [System.Drawing.Color]::Khaki
$tabPlay.Controls.Add($estimateLabel)

$agentCheckLabel = New-Object System.Windows.Forms.Label
$agentCheckLabel.Text = "並列起動で使うAI"
$agentCheckLabel.Location = New-Object System.Drawing.Point(18, 186)
$agentCheckLabel.Size = New-Object System.Drawing.Size(200, 22)
$tabPlay.Controls.Add($agentCheckLabel)

$agentCheckList = New-Object System.Windows.Forms.CheckedListBox
$agentCheckList.Location = New-Object System.Drawing.Point(18, 212)
$agentCheckList.Size = New-Object System.Drawing.Size(860, 176)
$agentCheckList.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
$agentCheckList.ForeColor = [System.Drawing.Color]::Gainsboro
$tabPlay.Controls.Add($agentCheckList)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(18, 396)
$statusLabel.Size = New-Object System.Drawing.Size(860, 24)
$statusLabel.ForeColor = [System.Drawing.Color]::Silver
$statusLabel.Text = "Ready."
$tabPlay.Controls.Add($statusLabel)

$openGameButton = New-Object System.Windows.Forms.Button
$openGameButton.Text = "Open Game"
$openGameButton.Location = New-Object System.Drawing.Point(598, 422)
$openGameButton.Size = New-Object System.Drawing.Size(110, 34)
$tabPlay.Controls.Add($openGameButton)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = "Start llama-server"
$startButton.Location = New-Object System.Drawing.Point(718, 422)
$startButton.Size = New-Object System.Drawing.Size(160, 34)
$startButton.BackColor = [System.Drawing.Color]::FromArgb(40, 96, 200)
$startButton.ForeColor = [System.Drawing.Color]::White
$startButton.FlatStyle = "Flat"
$tabPlay.Controls.Add($startButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "Close"
$closeButton.Location = New-Object System.Drawing.Point(502, 422)
$closeButton.Size = New-Object System.Drawing.Size(86, 34)
$tabPlay.Controls.Add($closeButton)

$exeCpuLabel = New-Object System.Windows.Forms.Label
$exeCpuLabel.Text = "CPU 実行パス (LLAMA_CPP_EXE_CPU)"
$exeCpuLabel.Location = New-Object System.Drawing.Point(18, 18)
$exeCpuLabel.Size = New-Object System.Drawing.Size(320, 22)
$tabBoot.Controls.Add($exeCpuLabel)

$exeCpuPathBox = New-Object System.Windows.Forms.TextBox
$exeCpuPathBox.Location = New-Object System.Drawing.Point(18, 42)
$exeCpuPathBox.Size = New-Object System.Drawing.Size(560, 27)
$exeCpuPathBox.Text = [string]$envMap.LLAMA_CPP_EXE_CPU
$tabBoot.Controls.Add($exeCpuPathBox)

$browseExeCpuButton = New-Object System.Windows.Forms.Button
$browseExeCpuButton.Text = "Browse"
$browseExeCpuButton.Location = New-Object System.Drawing.Point(588, 40)
$browseExeCpuButton.Size = New-Object System.Drawing.Size(120, 30)
$tabBoot.Controls.Add($browseExeCpuButton)

$localCpuButton = New-Object System.Windows.Forms.Button
$localCpuButton.Text = "Local CPU"
$localCpuButton.Location = New-Object System.Drawing.Point(718, 40)
$localCpuButton.Size = New-Object System.Drawing.Size(160, 30)
$tabBoot.Controls.Add($localCpuButton)

$exeGpuLabel = New-Object System.Windows.Forms.Label
$exeGpuLabel.Text = "GPU 実行パス (LLAMA_CPP_EXE_GPU)"
$exeGpuLabel.Location = New-Object System.Drawing.Point(18, 74)
$exeGpuLabel.Size = New-Object System.Drawing.Size(320, 22)
$tabBoot.Controls.Add($exeGpuLabel)

$exeGpuPathBox = New-Object System.Windows.Forms.TextBox
$exeGpuPathBox.Location = New-Object System.Drawing.Point(18, 98)
$exeGpuPathBox.Size = New-Object System.Drawing.Size(560, 27)
$exeGpuPathBox.Text = [string]$envMap.LLAMA_CPP_EXE_GPU
$tabBoot.Controls.Add($exeGpuPathBox)

$browseExeGpuButton = New-Object System.Windows.Forms.Button
$browseExeGpuButton.Text = "Browse"
$browseExeGpuButton.Location = New-Object System.Drawing.Point(588, 96)
$browseExeGpuButton.Size = New-Object System.Drawing.Size(120, 30)
$tabBoot.Controls.Add($browseExeGpuButton)

$localGpuButton = New-Object System.Windows.Forms.Button
$localGpuButton.Text = "Local GPU"
$localGpuButton.Location = New-Object System.Drawing.Point(718, 96)
$localGpuButton.Size = New-Object System.Drawing.Size(160, 30)
$tabBoot.Controls.Add($localGpuButton)

$modelFolderLabel = New-Object System.Windows.Forms.Label
$modelFolderLabel.Text = "AIモデルフォルダ (.gguf を走査)"
$modelFolderLabel.Location = New-Object System.Drawing.Point(18, 132)
$modelFolderLabel.Size = New-Object System.Drawing.Size(300, 22)
$tabBoot.Controls.Add($modelFolderLabel)

$modelFolderBox = New-Object System.Windows.Forms.TextBox
$modelFolderBox.Location = New-Object System.Drawing.Point(18, 156)
$modelFolderBox.Size = New-Object System.Drawing.Size(560, 27)
$modelFolderBox.Text = $modelsDir
$tabBoot.Controls.Add($modelFolderBox)

$browseModelFolderButton = New-Object System.Windows.Forms.Button
$browseModelFolderButton.Text = "Browse"
$browseModelFolderButton.Location = New-Object System.Drawing.Point(588, 154)
$browseModelFolderButton.Size = New-Object System.Drawing.Size(120, 30)
$tabBoot.Controls.Add($browseModelFolderButton)

$scanModelFolderButton = New-Object System.Windows.Forms.Button
$scanModelFolderButton.Text = "Scan .gguf"
$scanModelFolderButton.Location = New-Object System.Drawing.Point(718, 154)
$scanModelFolderButton.Size = New-Object System.Drawing.Size(160, 30)
$tabBoot.Controls.Add($scanModelFolderButton)

$modelListLabel = New-Object System.Windows.Forms.Label
$modelListLabel.Text = "AIモデルのパス一覧"
$modelListLabel.Location = New-Object System.Drawing.Point(18, 194)
$modelListLabel.Size = New-Object System.Drawing.Size(220, 24)
$tabBoot.Controls.Add($modelListLabel)

$modelPathGrid = New-Object System.Windows.Forms.DataGridView
$modelPathGrid.Location = New-Object System.Drawing.Point(18, 222)
$modelPathGrid.Size = New-Object System.Drawing.Size(860, 220)
$modelPathGrid.AllowUserToAddRows = $false
$modelPathGrid.AllowUserToResizeRows = $false
$modelPathGrid.RowHeadersVisible = $false
$modelPathGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$modelPathGrid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$modelPathGrid.BackgroundColor = [System.Drawing.Color]::FromArgb(18, 18, 18)
$modelPathGrid.ForeColor = [System.Drawing.Color]::Gainsboro
$modelPathGrid.GridColor = [System.Drawing.Color]::FromArgb(48, 48, 48)
$modelPathGrid.EnableHeadersVisualStyles = $false
$modelPathGrid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$modelPathGrid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::Gainsboro
$modelPathGrid.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(16, 16, 16)
$modelPathGrid.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gainsboro
$modelPathGrid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(55, 55, 55)
$modelPathGrid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
$modelPathGrid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(22, 22, 22)
$modelPathGrid.RowTemplate.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(16, 16, 16)
$modelPathGrid.RowTemplate.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gainsboro
$tabBoot.Controls.Add($modelPathGrid)

[void]$modelPathGrid.Columns.Add("model", "モデル")
[void]$modelPathGrid.Columns.Add("path", "パス")

$saveBootButton = New-Object System.Windows.Forms.Button
$saveBootButton.Text = "Save 起動構成"
$saveBootButton.Location = New-Object System.Drawing.Point(738, 454)
$saveBootButton.Size = New-Object System.Drawing.Size(140, 34)
$tabBoot.Controls.Add($saveBootButton)

$bootUnsavedLabel = New-Object System.Windows.Forms.Label
$bootUnsavedLabel.Text = "起動構成が保存されていません"
$bootUnsavedLabel.Location = New-Object System.Drawing.Point(18, 462)
$bootUnsavedLabel.Size = New-Object System.Drawing.Size(360, 24)
$bootUnsavedLabel.ForeColor = [System.Drawing.Color]::Tomato
$bootUnsavedLabel.Visible = $false
$tabBoot.Controls.Add($bootUnsavedLabel)

$aiListLabel = New-Object System.Windows.Forms.Label
$aiListLabel.Text = "AI一覧"
$aiListLabel.Location = New-Object System.Drawing.Point(18, 18)
$aiListLabel.Size = New-Object System.Drawing.Size(120, 24)
$tabAgent.Controls.Add($aiListLabel)

$agentList = New-Object System.Windows.Forms.ListBox
$agentList.Location = New-Object System.Drawing.Point(18, 46)
$agentList.Size = New-Object System.Drawing.Size(280, 396)
$agentList.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
$agentList.ForeColor = [System.Drawing.Color]::Gainsboro
$tabAgent.Controls.Add($agentList)

$detailLabel = New-Object System.Windows.Forms.Label
$detailLabel.Text = "詳細設定"
$detailLabel.Location = New-Object System.Drawing.Point(320, 18)
$detailLabel.Size = New-Object System.Drawing.Size(120, 24)
$tabAgent.Controls.Add($detailLabel)

$idLabel = New-Object System.Windows.Forms.Label
$idLabel.Text = "ID"
$idLabel.Location = New-Object System.Drawing.Point(320, 50)
$idLabel.Size = New-Object System.Drawing.Size(120, 20)
$tabAgent.Controls.Add($idLabel)

$idBox = New-Object System.Windows.Forms.TextBox
$idBox.Location = New-Object System.Drawing.Point(320, 72)
$idBox.Size = New-Object System.Drawing.Size(240, 27)
$tabAgent.Controls.Add($idBox)

$nameLabel = New-Object System.Windows.Forms.Label
$nameLabel.Text = "名前"
$nameLabel.Location = New-Object System.Drawing.Point(578, 50)
$nameLabel.Size = New-Object System.Drawing.Size(120, 20)
$tabAgent.Controls.Add($nameLabel)

$nameBox = New-Object System.Windows.Forms.TextBox
$nameBox.Location = New-Object System.Drawing.Point(578, 72)
$nameBox.Size = New-Object System.Drawing.Size(300, 27)
$tabAgent.Controls.Add($nameBox)

$modelPathLabel = New-Object System.Windows.Forms.Label
$modelPathLabel.Text = "モデル名 (起動構成一覧から選択)"
$modelPathLabel.Location = New-Object System.Drawing.Point(320, 110)
$modelPathLabel.Size = New-Object System.Drawing.Size(280, 20)
$tabAgent.Controls.Add($modelPathLabel)

$modelNameCombo = New-Object System.Windows.Forms.ComboBox
$modelNameCombo.Location = New-Object System.Drawing.Point(320, 132)
$modelNameCombo.Size = New-Object System.Drawing.Size(558, 27)
$modelNameCombo.DropDownStyle = "DropDownList"
$tabAgent.Controls.Add($modelNameCombo)

$portLabel = New-Object System.Windows.Forms.Label
$portLabel.Text = "LLAMA Port"
$portLabel.Location = New-Object System.Drawing.Point(320, 172)
$portLabel.Size = New-Object System.Drawing.Size(120, 20)
$tabAgent.Controls.Add($portLabel)

$portBox = New-Object System.Windows.Forms.TextBox
$portBox.Location = New-Object System.Drawing.Point(320, 194)
$portBox.Size = New-Object System.Drawing.Size(120, 27)
$tabAgent.Controls.Add($portBox)

$nglLabel = New-Object System.Windows.Forms.Label
$nglLabel.Text = "LLAMA NGL"
$nglLabel.Location = New-Object System.Drawing.Point(458, 172)
$nglLabel.Size = New-Object System.Drawing.Size(120, 20)
$tabAgent.Controls.Add($nglLabel)

$nglBox = New-Object System.Windows.Forms.TextBox
$nglBox.Location = New-Object System.Drawing.Point(458, 194)
$nglBox.Size = New-Object System.Drawing.Size(120, 27)
$tabAgent.Controls.Add($nglBox)

$ctxLabel = New-Object System.Windows.Forms.Label
$ctxLabel.Text = "LLAMA CTX"
$ctxLabel.Location = New-Object System.Drawing.Point(596, 172)
$ctxLabel.Size = New-Object System.Drawing.Size(120, 20)
$tabAgent.Controls.Add($ctxLabel)

$ctxBox = New-Object System.Windows.Forms.TextBox
$ctxBox.Location = New-Object System.Drawing.Point(596, 194)
$ctxBox.Size = New-Object System.Drawing.Size(120, 27)
$tabAgent.Controls.Add($ctxBox)

$updateAgentButton = New-Object System.Windows.Forms.Button
$updateAgentButton.Text = "詳細を反映"
$updateAgentButton.Location = New-Object System.Drawing.Point(738, 190)
$updateAgentButton.Size = New-Object System.Drawing.Size(140, 34)
$tabAgent.Controls.Add($updateAgentButton)

$aiDetailUnsavedLabel = New-Object System.Windows.Forms.Label
$aiDetailUnsavedLabel.Text = "詳細が未反映です"
$aiDetailUnsavedLabel.Location = New-Object System.Drawing.Point(320, 232)
$aiDetailUnsavedLabel.Size = New-Object System.Drawing.Size(240, 22)
$aiDetailUnsavedLabel.ForeColor = [System.Drawing.Color]::Tomato
$aiDetailUnsavedLabel.Visible = $false
$tabAgent.Controls.Add($aiDetailUnsavedLabel)

$addAgentButton = New-Object System.Windows.Forms.Button
$addAgentButton.Text = "Add AI"
$addAgentButton.Location = New-Object System.Drawing.Point(320, 454)
$addAgentButton.Size = New-Object System.Drawing.Size(120, 34)
$tabAgent.Controls.Add($addAgentButton)

$removeAgentButton = New-Object System.Windows.Forms.Button
$removeAgentButton.Text = "Remove AI"
$removeAgentButton.Location = New-Object System.Drawing.Point(450, 454)
$removeAgentButton.Size = New-Object System.Drawing.Size(120, 34)
$tabAgent.Controls.Add($removeAgentButton)

$saveAgentsButton = New-Object System.Windows.Forms.Button
$saveAgentsButton.Text = "Save AIモデル"
$saveAgentsButton.Location = New-Object System.Drawing.Point(738, 454)
$saveAgentsButton.Size = New-Object System.Drawing.Size(140, 34)
$tabAgent.Controls.Add($saveAgentsButton)

$aiUnsavedLabel = New-Object System.Windows.Forms.Label
$aiUnsavedLabel.Text = "AIモデル設定が保存されていません"
$aiUnsavedLabel.Location = New-Object System.Drawing.Point(18, 462)
$aiUnsavedLabel.Size = New-Object System.Drawing.Size(320, 24)
$aiUnsavedLabel.ForeColor = [System.Drawing.Color]::Tomato
$aiUnsavedLabel.Visible = $false
$tabAgent.Controls.Add($aiUnsavedLabel)

$settingsTitleLabel = New-Object System.Windows.Forms.Label
$settingsTitleLabel.Text = "設定"
$settingsTitleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 14)
$settingsTitleLabel.Location = New-Object System.Drawing.Point(18, 18)
$settingsTitleLabel.Size = New-Object System.Drawing.Size(220, 28)
$tabSettings.Controls.Add($settingsTitleLabel)

$settingsLangSectionLabel = New-Object System.Windows.Forms.Label
$settingsLangSectionLabel.Text = "1. 言語"
$settingsLangSectionLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$settingsLangSectionLabel.Location = New-Object System.Drawing.Point(18, 48)
$settingsLangSectionLabel.Size = New-Object System.Drawing.Size(220, 20)
$tabSettings.Controls.Add($settingsLangSectionLabel)

$languageLabel = New-Object System.Windows.Forms.Label
$languageLabel.Text = "Language"
$languageLabel.Location = New-Object System.Drawing.Point(18, 64)
$languageLabel.Size = New-Object System.Drawing.Size(160, 24)
$tabSettings.Controls.Add($languageLabel)

$languageCombo = New-Object System.Windows.Forms.ComboBox
$languageCombo.Location = New-Object System.Drawing.Point(18, 90)
$languageCombo.Size = New-Object System.Drawing.Size(240, 27)
$languageCombo.DropDownStyle = "DropDownList"
[void]$languageCombo.Items.Add("日本語 (ja)")
[void]$languageCombo.Items.Add("English (en)")
$tabSettings.Controls.Add($languageCombo)

$applyLanguageButton = New-Object System.Windows.Forms.Button
$applyLanguageButton.Text = "Apply"
$applyLanguageButton.Location = New-Object System.Drawing.Point(268, 88)
$applyLanguageButton.Size = New-Object System.Drawing.Size(110, 30)
$tabSettings.Controls.Add($applyLanguageButton)

$exportSettingsButton = New-Object System.Windows.Forms.Button
$exportSettingsButton.Text = "Export"
$exportSettingsButton.Location = New-Object System.Drawing.Point(18, 136)
$exportSettingsButton.Size = New-Object System.Drawing.Size(110, 30)
$tabSettings.Controls.Add($exportSettingsButton)

$settingsFileSectionLabel = New-Object System.Windows.Forms.Label
$settingsFileSectionLabel.Text = "2. 設定ファイル"
$settingsFileSectionLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$settingsFileSectionLabel.Location = New-Object System.Drawing.Point(18, 118)
$settingsFileSectionLabel.Size = New-Object System.Drawing.Size(260, 20)
$tabSettings.Controls.Add($settingsFileSectionLabel)

$importSettingsButton = New-Object System.Windows.Forms.Button
$importSettingsButton.Text = "Import"
$importSettingsButton.Location = New-Object System.Drawing.Point(138, 136)
$importSettingsButton.Size = New-Object System.Drawing.Size(110, 30)
$tabSettings.Controls.Add($importSettingsButton)

$resetBootButton = New-Object System.Windows.Forms.Button
$resetBootButton.Text = "起動構成のみ初期化"
$resetBootButton.Location = New-Object System.Drawing.Point(18, 184)
$resetBootButton.Size = New-Object System.Drawing.Size(200, 34)
$tabSettings.Controls.Add($resetBootButton)

$settingsResetSectionLabel = New-Object System.Windows.Forms.Label
$settingsResetSectionLabel.Text = "3. 初期化"
$settingsResetSectionLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$settingsResetSectionLabel.Location = New-Object System.Drawing.Point(18, 166)
$settingsResetSectionLabel.Size = New-Object System.Drawing.Size(220, 20)
$tabSettings.Controls.Add($settingsResetSectionLabel)

$resetAiButton = New-Object System.Windows.Forms.Button
$resetAiButton.Text = "AI設定のみ初期化"
$resetAiButton.Location = New-Object System.Drawing.Point(228, 184)
$resetAiButton.Size = New-Object System.Drawing.Size(200, 34)
$tabSettings.Controls.Add($resetAiButton)

$resetAllButton = New-Object System.Windows.Forms.Button
$resetAllButton.Text = "すべて初期化"
$resetAllButton.Location = New-Object System.Drawing.Point(438, 184)
$resetAllButton.Size = New-Object System.Drawing.Size(180, 34)
$tabSettings.Controls.Add($resetAllButton)

$settingsHintLabel = New-Object System.Windows.Forms.Label
$settingsHintLabel.Text = "初期化設定は、起動構成とAIモデル設定を初期値に戻します。"
$settingsHintLabel.Location = New-Object System.Drawing.Point(18, 230)
$settingsHintLabel.Size = New-Object System.Drawing.Size(840, 24)
$settingsHintLabel.ForeColor = [System.Drawing.Color]::Silver
$tabSettings.Controls.Add($settingsHintLabel)

$settingsProfileSectionLabel = New-Object System.Windows.Forms.Label
$settingsProfileSectionLabel.Text = "4. プロファイル"
$settingsProfileSectionLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$settingsProfileSectionLabel.Location = New-Object System.Drawing.Point(18, 264)
$settingsProfileSectionLabel.Size = New-Object System.Drawing.Size(220, 20)
$tabSettings.Controls.Add($settingsProfileSectionLabel)

$profileNameLabel = New-Object System.Windows.Forms.Label
$profileNameLabel.Text = "プロファイル名"
$profileNameLabel.Location = New-Object System.Drawing.Point(18, 286)
$profileNameLabel.Size = New-Object System.Drawing.Size(120, 24)
$tabSettings.Controls.Add($profileNameLabel)

$profileNameBox = New-Object System.Windows.Forms.TextBox
$profileNameBox.Location = New-Object System.Drawing.Point(18, 312)
$profileNameBox.Size = New-Object System.Drawing.Size(220, 27)
$tabSettings.Controls.Add($profileNameBox)

$profileSaveButton = New-Object System.Windows.Forms.Button
$profileSaveButton.Text = "保存"
$profileSaveButton.Location = New-Object System.Drawing.Point(248, 310)
$profileSaveButton.Size = New-Object System.Drawing.Size(100, 30)
$tabSettings.Controls.Add($profileSaveButton)

$profileListCombo = New-Object System.Windows.Forms.ComboBox
$profileListCombo.Location = New-Object System.Drawing.Point(360, 312)
$profileListCombo.Size = New-Object System.Drawing.Size(240, 27)
$profileListCombo.DropDownStyle = "DropDownList"
$tabSettings.Controls.Add($profileListCombo)

$profileLoadButton = New-Object System.Windows.Forms.Button
$profileLoadButton.Text = "読込"
$profileLoadButton.Location = New-Object System.Drawing.Point(610, 310)
$profileLoadButton.Size = New-Object System.Drawing.Size(100, 30)
$tabSettings.Controls.Add($profileLoadButton)

$settingsUpdateSectionLabel = New-Object System.Windows.Forms.Label
$settingsUpdateSectionLabel.Text = "5. アップデート"
$settingsUpdateSectionLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$settingsUpdateSectionLabel.Location = New-Object System.Drawing.Point(18, 352)
$settingsUpdateSectionLabel.Size = New-Object System.Drawing.Size(220, 20)
$tabSettings.Controls.Add($settingsUpdateSectionLabel)

$updateCheckButton = New-Object System.Windows.Forms.Button
$updateCheckButton.Text = "更新確認"
$updateCheckButton.Location = New-Object System.Drawing.Point(18, 378)
$updateCheckButton.Size = New-Object System.Drawing.Size(110, 30)
$tabSettings.Controls.Add($updateCheckButton)

$updateApplyButton = New-Object System.Windows.Forms.Button
$updateApplyButton.Text = "更新実行"
$updateApplyButton.Location = New-Object System.Drawing.Point(138, 378)
$updateApplyButton.Size = New-Object System.Drawing.Size(110, 30)
$updateApplyButton.Enabled = $false
$tabSettings.Controls.Add($updateApplyButton)

$updateRebuildCheck = New-Object System.Windows.Forms.CheckBox
$updateRebuildCheck.Text = "更新後にEXE再生成"
$updateRebuildCheck.Location = New-Object System.Drawing.Point(268, 382)
$updateRebuildCheck.Size = New-Object System.Drawing.Size(260, 24)
$updateRebuildCheck.ForeColor = [System.Drawing.Color]::Gainsboro
$tabSettings.Controls.Add($updateRebuildCheck)

$updateStatusTextBox = New-Object System.Windows.Forms.TextBox
$updateStatusTextBox.Location = New-Object System.Drawing.Point(18, 414)
$updateStatusTextBox.Size = New-Object System.Drawing.Size(860, 72)
$updateStatusTextBox.Multiline = $true
$updateStatusTextBox.ScrollBars = "Vertical"
$updateStatusTextBox.ReadOnly = $true
$updateStatusTextBox.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
$updateStatusTextBox.ForeColor = [System.Drawing.Color]::Gainsboro
$updateStatusTextBox.Text = ""
$tabSettings.Controls.Add($updateStatusTextBox)

$healthRefreshButton = New-Object System.Windows.Forms.Button
$healthRefreshButton.Text = "更新"
$healthRefreshButton.Location = New-Object System.Drawing.Point(18, 16)
$healthRefreshButton.Size = New-Object System.Drawing.Size(100, 30)
$tabHealth.Controls.Add($healthRefreshButton)

$healthTextBox = New-Object System.Windows.Forms.TextBox
$healthTextBox.Location = New-Object System.Drawing.Point(18, 56)
$healthTextBox.Size = New-Object System.Drawing.Size(860, 430)
$healthTextBox.Multiline = $true
$healthTextBox.ScrollBars = "Vertical"
$healthTextBox.ReadOnly = $true
$healthTextBox.BackColor = [System.Drawing.Color]::FromArgb(16, 16, 16)
$healthTextBox.ForeColor = [System.Drawing.Color]::Gainsboro
$tabHealth.Controls.Add($healthTextBox)

$logsRefreshButton = New-Object System.Windows.Forms.Button
$logsRefreshButton.Text = "更新"
$logsRefreshButton.Location = New-Object System.Drawing.Point(18, 16)
$logsRefreshButton.Size = New-Object System.Drawing.Size(100, 30)
$tabLogs.Controls.Add($logsRefreshButton)

$logFileCombo = New-Object System.Windows.Forms.ComboBox
$logFileCombo.Location = New-Object System.Drawing.Point(130, 18)
$logFileCombo.Size = New-Object System.Drawing.Size(490, 27)
$logFileCombo.DropDownStyle = "DropDownList"
$tabLogs.Controls.Add($logFileCombo)

$logsOpenButton = New-Object System.Windows.Forms.Button
$logsOpenButton.Text = "開く"
$logsOpenButton.Location = New-Object System.Drawing.Point(630, 16)
$logsOpenButton.Size = New-Object System.Drawing.Size(100, 30)
$tabLogs.Controls.Add($logsOpenButton)

$logsAutoUpdateCheck = New-Object System.Windows.Forms.CheckBox
$logsAutoUpdateCheck.Text = "自動更新"
$logsAutoUpdateCheck.Location = New-Object System.Drawing.Point(740, 20)
$logsAutoUpdateCheck.Size = New-Object System.Drawing.Size(140, 24)
$logsAutoUpdateCheck.Checked = $false
$tabLogs.Controls.Add($logsAutoUpdateCheck)

$logsTextBox = New-Object System.Windows.Forms.TextBox
$logsTextBox.Location = New-Object System.Drawing.Point(18, 56)
$logsTextBox.Size = New-Object System.Drawing.Size(860, 430)
$logsTextBox.Multiline = $true
$logsTextBox.ScrollBars = "Vertical"
$logsTextBox.ReadOnly = $true
$logsTextBox.BackColor = [System.Drawing.Color]::FromArgb(16, 16, 16)
$logsTextBox.ForeColor = [System.Drawing.Color]::Gainsboro
$tabLogs.Controls.Add($logsTextBox)

function Refresh-AgentListView {
	$agentList.Items.Clear()
	for ($i = 0; $i -lt $agents.Count; $i++) {
		$a = $agents[$i]
		$displayName = if ([string]::IsNullOrWhiteSpace([string]$a.name)) { "AI {0}" -f ($i + 1) } else { [string]$a.name }
		$displayId = if ([string]::IsNullOrWhiteSpace([string]$a.id)) { "agent-{0}" -f ($i + 1) } else { [string]$a.id }
		[void]$agentList.Items.Add(("{0}. {1} ({2})" -f ($i + 1), $displayName, $displayId))
	}
}

function Refresh-AgentCheckList {
	$script:IsRefreshingAgentChecks = $true
	try {
		$agentCheckList.Items.Clear()
		for ($i = 0; $i -lt $agents.Count; $i++) {
			$a = $agents[$i]
			$displayName = if ([string]::IsNullOrWhiteSpace([string]$a.name)) { "AI {0}" -f ($i + 1) } else { [string]$a.name }
			$displayId = if ([string]::IsNullOrWhiteSpace([string]$a.id)) { "agent-{0}" -f ($i + 1) } else { [string]$a.id }
			$label = "{0}. {1} [{2}] - {3}" -f ($i + 1), $displayName, $displayId, [System.IO.Path]::GetFileName([string]$a.modelPath)
			[void]$agentCheckList.Items.Add($label, [bool]$a.enabled)
		}
	} finally {
		$script:IsRefreshingAgentChecks = $false
	}
}

function Refresh-ModelPathGrid {
	$modelPathGrid.Rows.Clear()

	foreach ($m in $models) {
		$idx = $modelPathGrid.Rows.Add()
		$modelPathGrid.Rows[$idx].Cells[0].Value = $m.Name
		$modelPathGrid.Rows[$idx].Cells[1].Value = $m.FullName
	}

	foreach ($a in $agents) {
		if (-not [string]::IsNullOrWhiteSpace([string]$a.modelPath) -and -not ($models | Where-Object { $_.FullName -eq $a.modelPath })) {
			$idx = $modelPathGrid.Rows.Add()
			$modelPathGrid.Rows[$idx].Cells[0].Value = ("(AI) " + [System.IO.Path]::GetFileName([string]$a.modelPath))
			$modelPathGrid.Rows[$idx].Cells[1].Value = [string]$a.modelPath
		}
	}

	$modelNameCombo.Items.Clear()
	foreach ($m in $models) {
		[void]$modelNameCombo.Items.Add($m.Name)
	}
	foreach ($a in $agents) {
		if ($a.modelPath) {
			$fileName = [System.IO.Path]::GetFileName([string]$a.modelPath)
			if (-not [string]::IsNullOrWhiteSpace($fileName) -and -not $modelNameCombo.Items.Contains($fileName)) {
				[void]$modelNameCombo.Items.Add($fileName)
			}
		}
	}
}

function Update-EstimateLabel {
	$selected = @()
	for ($i = 0; $i -lt $agents.Count; $i++) {
		if ($i -lt $agentCheckList.Items.Count -and $agentCheckList.GetItemChecked($i)) {
			$selected += $agents[$i]
		}
	}

	$estimateLabel.Text = Get-EstimateText -SelectedAgents $selected -CpuMode $cpuRadio.Checked -RamGiB $systemInfo.RamGiB
}

function Get-UiText {
	param([string]$Key)

	$lang = if ($script:i18n.ContainsKey($script:currentLanguage)) { $script:currentLanguage } else { "ja" }
	if ($script:i18n[$lang].ContainsKey($Key)) {
		return [string]$script:i18n[$lang][$Key]
	}

	return $Key
}

function Get-SelectedLanguageCode {
	if ($languageCombo.SelectedIndex -eq 1) {
		return "en"
	}
	return "ja"
}

function Set-LanguageCombo {
	param([string]$LanguageCode)

	$languageCombo.SelectedIndex = if ($LanguageCode -eq "en") { 1 } else { 0 }
}

function Update-BootUnsavedWarning {
	if (-not $script:savedBootConfig) {
		$script:savedBootConfig = Get-SavedBootConfigState -Path $bootConfigFile
	}

	$current = Get-BootConfigState
	$saved = $script:savedBootConfig
	$bootUnsavedLabel.Visible =
		([string]$current.modelFolder -ne [string]$saved.modelFolder) -or
		([string]$current.cpuExePath -ne [string]$saved.cpuExePath) -or
		([string]$current.gpuExePath -ne [string]$saved.gpuExePath) -or
		([string]$current.selectedMode -ne [string]$saved.selectedMode) -or
		([string]$current.defaultHost -ne [string]$saved.defaultHost) -or
		([string]$current.defaultPort -ne [string]$saved.defaultPort) -or
		([string]$current.defaultNgl -ne [string]$saved.defaultNgl) -or
		([string]$current.defaultCtx -ne [string]$saved.defaultCtx) -or
		([string]$current.defaultExtraArgs -ne [string]$saved.defaultExtraArgs)
}

function Update-AiUnsavedWarning {
	$current = Get-AgentsFingerprint -AgentItems $script:agents
	$aiUnsavedLabel.Visible = ($current -ne $script:savedAgentsFingerprint)
}

function Update-AiDetailUnsavedWarning {
	if ($script:IsLoadingAgentDetail) {
		return
	}

	if ($agentList.SelectedIndex -lt 0 -or $agentList.SelectedIndex -ge $script:agents.Count) {
		$aiDetailUnsavedLabel.Visible = $false
		return
	}

	$a = $script:agents[$agentList.SelectedIndex]
	$modelName = [System.IO.Path]::GetFileName([string]$a.modelPath)
	$expectedId = [string]$a.id
	$expectedName = [string]$a.name
	$expectedPort = [string]$a.llamaPort
	$expectedNgl = [string]$a.llamaNgl
	$expectedCtx = [string]$a.llamaCtx
	$currentModel = [string]$modelNameCombo.Text

	$isDirty = ($idBox.Text.Trim() -ne $expectedId) -or
		($nameBox.Text.Trim() -ne $expectedName) -or
		($portBox.Text.Trim() -ne $expectedPort) -or
		($nglBox.Text.Trim() -ne $expectedNgl) -or
		($ctxBox.Text.Trim() -ne $expectedCtx) -or
		($currentModel -ne $modelName)

	$aiDetailUnsavedLabel.Visible = $isDirty
}

function Apply-UiLanguage {
	$tabPlay.Text = Get-UiText "tabPlay"
	$tabBoot.Text = Get-UiText "tabBoot"
	$tabAgent.Text = Get-UiText "tabAgent"
	$tabSettings.Text = Get-UiText "tabSettings"
	$tabHealth.Text = Get-UiText "tabHealth"
	$tabLogs.Text = Get-UiText "tabLogs"
	$modeLabel.Text = Get-UiText "mode"
	$agentCheckLabel.Text = Get-UiText "useAi"
	$openGameButton.Text = Get-UiText "openGame"
	$startButton.Text = Get-UiText "start"
	$closeButton.Text = Get-UiText "close"
	$exeCpuLabel.Text = Get-UiText "exePathCpu"
	$exeGpuLabel.Text = Get-UiText "exePathGpu"
	$browseExeCpuButton.Text = Get-UiText "browse"
	$browseExeGpuButton.Text = Get-UiText "browse"
	$localCpuButton.Text = Get-UiText "localCpu"
	$localGpuButton.Text = Get-UiText "localGpu"
	$modelFolderLabel.Text = Get-UiText "modelFolder"
	$browseModelFolderButton.Text = Get-UiText "browse"
	$scanModelFolderButton.Text = Get-UiText "scan"
	$modelListLabel.Text = Get-UiText "modelList"
	$saveBootButton.Text = Get-UiText "saveBoot"
	$aiListLabel.Text = Get-UiText "aiList"
	$detailLabel.Text = Get-UiText "detail"
	$nameLabel.Text = Get-UiText "name"
	$modelPathLabel.Text = Get-UiText "modelName"
	$updateAgentButton.Text = Get-UiText "updateDetail"
	$addAgentButton.Text = Get-UiText "addAi"
	$removeAgentButton.Text = Get-UiText "removeAi"
	$saveAgentsButton.Text = Get-UiText "saveAi"
	$settingsTitleLabel.Text = Get-UiText "settingsTitle"
	$settingsLangSectionLabel.Text = Get-UiText "sectionLanguage"
	$settingsFileSectionLabel.Text = Get-UiText "sectionConfigFiles"
	$settingsResetSectionLabel.Text = Get-UiText "sectionReset"
	$languageLabel.Text = Get-UiText "language"
	$applyLanguageButton.Text = Get-UiText "applyLanguage"
	$exportSettingsButton.Text = Get-UiText "exportSettings"
	$importSettingsButton.Text = Get-UiText "importSettings"
	$resetBootButton.Text = Get-UiText "resetBoot"
	$resetAiButton.Text = Get-UiText "resetAi"
	$resetAllButton.Text = Get-UiText "resetAll"
	$settingsHintLabel.Text = Get-UiText "settingsHint"
	$settingsProfileSectionLabel.Text = Get-UiText "sectionProfile"
	$profileNameLabel.Text = Get-UiText "profileName"
	$profileSaveButton.Text = Get-UiText "profileSave"
	$profileLoadButton.Text = Get-UiText "profileLoad"
	$settingsUpdateSectionLabel.Text = Get-UiText "sectionUpdate"
	$updateCheckButton.Text = Get-UiText "updateCheck"
	$updateApplyButton.Text = Get-UiText "updateApply"
	$updateRebuildCheck.Text = Get-UiText "updateRebuild"
	$healthRefreshButton.Text = Get-UiText "healthRefresh"
	$logsRefreshButton.Text = Get-UiText "logsRefresh"
	$logsOpenButton.Text = Get-UiText "logsOpen"
	$logsAutoUpdateCheck.Text = Get-UiText "logsAutoUpdate"
	$bootUnsavedLabel.Text = Get-UiText "bootNotSaved"
	$aiUnsavedLabel.Text = Get-UiText "aiNotSaved"
	$aiDetailUnsavedLabel.Text = Get-UiText "aiDetailNotApplied"
	if ($llamaRuntimeStatusLabel.ForeColor -eq [System.Drawing.Color]::LimeGreen) {
		$llamaRuntimeStatusLabel.Text = Get-UiText "llamaStateReady"
	} elseif ($llamaRuntimeStatusLabel.ForeColor -eq [System.Drawing.Color]::Tomato) {
		$llamaRuntimeStatusLabel.Text = Get-UiText "llamaStateFailed"
	} else {
		$llamaRuntimeStatusLabel.Text = Get-UiText "llamaStateIdle"
	}
	if ($localRuntimeStatusLabel.ForeColor -eq [System.Drawing.Color]::LimeGreen) {
		$localRuntimeStatusLabel.Text = Get-UiText "localStateReady"
	} elseif ($localRuntimeStatusLabel.ForeColor -eq [System.Drawing.Color]::Tomato) {
		$localRuntimeStatusLabel.Text = Get-UiText "localStateFailed"
	} else {
		$localRuntimeStatusLabel.Text = Get-UiText "localStateIdle"
	}

	if ($statusLabel.Text -eq "Ready." -or $statusLabel.Text -eq (Get-UiText "ready")) {
		$statusLabel.Text = Get-UiText "ready"
	}
	Update-EstimateLabel
	Update-BootUnsavedWarning
	Update-AiUnsavedWarning
	Update-AiDetailUnsavedWarning
}

function Refresh-ProfileList {
	$current = [string]$profileListCombo.Text
	$profileListCombo.Items.Clear()
	foreach ($p in @($script:launchProfiles)) {
		if ($p -and $p.name) {
			[void]$profileListCombo.Items.Add([string]$p.name)
		}
	}

	if (-not [string]::IsNullOrWhiteSpace($current) -and $profileListCombo.Items.Contains($current)) {
		$profileListCombo.SelectedItem = $current
	} elseif ($profileListCombo.Items.Count -gt 0) {
		$profileListCombo.SelectedIndex = 0
	}
}

function Refresh-HealthTab {
	$healthTextBox.Text = Get-HealthOverviewText
}

function Refresh-LogsTab {
	if ($script:isRefreshingLogsTab) {
		return
	}

	$script:isRefreshingLogsTab = $true
	try {
		$files = @(Get-AvailableLogFiles)
		$currentPath = [string]$logFileCombo.SelectedItem
		$logFileCombo.Items.Clear()
		foreach ($f in $files) {
			[void]$logFileCombo.Items.Add($f)
		}

		$target = $currentPath
		if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path -LiteralPath $target -PathType Leaf)) {
			$target = if ($files.Count -gt 0) { [string]$files[0] } else { "" }
		}

		if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path -LiteralPath $target -PathType Leaf)) {
			$logsTextBox.Text = ""
			return
		}

		$logsTextBox.Text = Get-LogPreviewText -Path $target -TailLines 300
	} finally {
		$script:isRefreshingLogsTab = $false
	}
}

function Set-ServerRuntimeState {
	param(
		[string]$LlamaText,
		[System.Drawing.Color]$LlamaColor,
		[string]$LocalText,
		[System.Drawing.Color]$LocalColor
	)

	$llamaRuntimeStatusLabel.Text = $LlamaText
	$llamaRuntimeStatusLabel.ForeColor = $LlamaColor
	$localRuntimeStatusLabel.Text = $LocalText
	$localRuntimeStatusLabel.ForeColor = $LocalColor
}

function Set-ModeSelectionByHardware {
	param([string]$Ngl)

	if (-not (Test-NvidiaGpuDetected)) {
		$cpuRadio.Checked = $true
		$gpuRadio.Checked = $false
		$script:envMap.LLAMA_NGL = "0"
		return
	}

	$cpuRadio.Checked = ([string]$Ngl -eq "0")
	$gpuRadio.Checked = ([string]$Ngl -ne "0")
}

function Get-StartupStatusText {
	param([string]$BaseText)

	$elapsedSeconds = 0
	if ($script:startupStartedAt) {
		$elapsedSeconds = [Math]::Max(0, [int]([DateTime]::Now - $script:startupStartedAt).TotalSeconds)
	}

	$elapsedText = [string]::Format((Get-UiText "statusStartingElapsed"), $elapsedSeconds)
	return [string]::Format("{0} {1} ({2})", $BaseText, $script:startupDots[$script:startupDotIndex], $elapsedText)
}

function Start-StartupAnimation {
	param([string]$BaseText)

	$script:startupBaseText = $BaseText
	$script:startupDotIndex = 0
	$script:startupStartedAt = Get-Date
	$script:isStartupAnimating = $true
	$statusLabel.Text = Get-StartupStatusText -BaseText $script:startupBaseText
	if ($startupTimer -and -not $startupTimer.Enabled) {
		$startupTimer.Start()
	}
}

function Stop-StartupAnimation {
	if ($startupTimer -and $startupTimer.Enabled) {
		$startupTimer.Stop()
	}
	$script:isStartupAnimating = $false
	$script:startupStartedAt = $null
}

function Sync-ExePathByMode {
	if ($script:isModePathSyncing) {
		return
	}

	$script:isModePathSyncing = $true
	try {
		if ([string]::IsNullOrWhiteSpace([string]$exeCpuPathBox.Text.Trim())) {
			$cpuExe = if ([string]::IsNullOrWhiteSpace([string]$script:envMap.LLAMA_CPP_EXE_CPU)) { Resolve-BundledLlamaExePath -PreferGpu:$false } else { [string]$script:envMap.LLAMA_CPP_EXE_CPU }
			if (Test-Path -LiteralPath $cpuExe -PathType Leaf) {
				$exeCpuPathBox.Text = $cpuExe
			}
		}

		if ([string]::IsNullOrWhiteSpace([string]$exeGpuPathBox.Text.Trim())) {
			$gpuExe = if ([string]::IsNullOrWhiteSpace([string]$script:envMap.LLAMA_CPP_EXE_GPU)) { Resolve-BundledLlamaExePath -PreferGpu:$true } else { [string]$script:envMap.LLAMA_CPP_EXE_GPU }
			if (Test-Path -LiteralPath $gpuExe -PathType Leaf) {
				$exeGpuPathBox.Text = $gpuExe
			}
		}
	} finally {
		$script:isModePathSyncing = $false
	}
}

function Refresh-HardwareStatusLabels {
	$gpuStatusLabel.Text = if (Test-NvidiaGpuDetected) {
		Get-UiText "gpuDetected"
	} else {
		Get-UiText "gpuMissing"
	}

	$gpuExePath = [string]$exeGpuPathBox.Text.Trim()
	$cudaStatusLabel.Text = if (Test-BundledCudaRuntimeAvailable -LlamaCppExePath $gpuExePath) {
		Get-UiText "cudaOk"
	} else {
		Get-UiText "cudaMissing"
	}
}

function Save-CurrentAgentDetail {
	if ($agentList.SelectedIndex -lt 0 -or $agentList.SelectedIndex -ge $agents.Count) {
		return
	}

	$idx = $agentList.SelectedIndex
	$currentModelPath = [string]$agents[$idx].modelPath
	$agents[$idx].id = if ([string]::IsNullOrWhiteSpace($idBox.Text)) { "agent-{0}" -f ($idx + 1) } else { $idBox.Text.Trim() }
	$agents[$idx].name = if ([string]::IsNullOrWhiteSpace($nameBox.Text)) { "AI {0}" -f ($idx + 1) } else { $nameBox.Text.Trim() }
	$selectedModelName = [string]$modelNameCombo.Text
	if ([string]::IsNullOrWhiteSpace($selectedModelName)) {
		if (-not [string]::IsNullOrWhiteSpace($currentModelPath)) {
			$agents[$idx].modelPath = $currentModelPath
		} elseif ($models.Count -gt 0) {
			$agents[$idx].modelPath = [string]$models[0].FullName
		} elseif (-not [string]::IsNullOrWhiteSpace([string]$envMap.LLAMA_MODEL_PATH)) {
			$agents[$idx].modelPath = [string]$envMap.LLAMA_MODEL_PATH
		} else {
			$agents[$idx].modelPath = ""
		}
	} else {
		$matched = $models | Where-Object { $_.Name -eq $selectedModelName } | Select-Object -First 1
		if ($matched) {
			$agents[$idx].modelPath = $matched.FullName
		} else {
			$agents[$idx].modelPath = Join-Path $modelFolderBox.Text $selectedModelName
		}
	}
	$agents[$idx].llamaPort = if ([string]::IsNullOrWhiteSpace($portBox.Text)) { [string]$envMap.LLAMA_PORT } else { $portBox.Text.Trim() }
	$agents[$idx].llamaNgl = if ([string]::IsNullOrWhiteSpace($nglBox.Text)) { [string]$envMap.LLAMA_NGL } else { $nglBox.Text.Trim() }
	$agents[$idx].llamaCtx = if ([string]::IsNullOrWhiteSpace($ctxBox.Text)) { [string]$envMap.LLAMA_CTX } else { $ctxBox.Text.Trim() }
}

function Load-AgentDetail {
	if ($agentList.SelectedIndex -lt 0 -or $agentList.SelectedIndex -ge $agents.Count) {
		$aiDetailUnsavedLabel.Visible = $false
		return
	}

	$script:IsLoadingAgentDetail = $true
	$a = $agents[$agentList.SelectedIndex]
	$idBox.Text = [string]$a.id
	$nameBox.Text = [string]$a.name
	$modelName = [System.IO.Path]::GetFileName([string]$a.modelPath)
	if ([string]::IsNullOrWhiteSpace($modelName) -and $models.Count -gt 0) {
		$modelName = [string]$models[0].Name
	}
	if (-not [string]::IsNullOrWhiteSpace($modelName) -and $modelNameCombo.Items.Contains($modelName)) {
		$modelNameCombo.SelectedItem = $modelName
	} elseif (-not [string]::IsNullOrWhiteSpace($modelName)) {
		if (-not $modelNameCombo.Items.Contains($modelName)) {
			[void]$modelNameCombo.Items.Add($modelName)
		}
		$modelNameCombo.SelectedItem = $modelName
	} else {
		$modelNameCombo.SelectedIndex = -1
	}
	$portBox.Text = [string]$a.llamaPort
	$nglBox.Text = [string]$a.llamaNgl
	$ctxBox.Text = [string]$a.llamaCtx
	$script:IsLoadingAgentDetail = $false
	Update-AiDetailUnsavedWarning
}

function Save-PlaySelectionsToAgents {
	for ($i = 0; $i -lt $agents.Count; $i++) {
		$agents[$i].enabled = ($i -lt $agentCheckList.Items.Count) -and $agentCheckList.GetItemChecked($i)
	}
}

function Start-GameFromLauncher {
	try {
		Set-ServerRuntimeState -LlamaText (Get-UiText "llamaStateReady") -LlamaColor ([System.Drawing.Color]::LimeGreen) -LocalText (Get-UiText "localStateStarting") -LocalColor ([System.Drawing.Color]::LimeGreen)
		if (-not (Ensure-GameServer -RootDir $rootDir -StateFile $gameStateFile)) {
			$details = "Game server did not become ready."
			if (-not [string]::IsNullOrWhiteSpace($script:lastGameStartupErrorDetails)) {
				$details += "`r`n`r`n" + $script:lastGameStartupErrorDetails
			}
			Set-ServerRuntimeState -LlamaText (Get-UiText "llamaStateReady") -LlamaColor ([System.Drawing.Color]::LimeGreen) -LocalText (Get-UiText "localStateFailed") -LocalColor ([System.Drawing.Color]::Tomato)
			throw $details
		}
		Set-ServerRuntimeState -LlamaText (Get-UiText "llamaStateReady") -LlamaColor ([System.Drawing.Color]::LimeGreen) -LocalText (Get-UiText "localStateReady") -LocalColor ([System.Drawing.Color]::LimeGreen)
		Start-Process "http://127.0.0.1:4173/index.html"
		return $true
	} catch {
		Show-LauncherError -Title "Open game failed" -Details (($_ | Out-String).TrimEnd())
		return $false
	}
}

 $browseExeCpuButton.Add_Click({
	$dialog = New-Object System.Windows.Forms.OpenFileDialog
	$dialog.Title = "CPU 用 llama.cpp 実行ファイルを選択"
	$dialog.Filter = "Executable (*.exe)|*.exe|All files (*.*)|*.*"
	$dialog.CheckFileExists = $true
	$dialog.CheckPathExists = $true
	$dialog.Multiselect = $false
	$initialDir = Split-Path -Parent $exeCpuPathBox.Text
	if ([string]::IsNullOrWhiteSpace($initialDir) -or -not (Test-Path -LiteralPath $initialDir -PathType Container)) {
		$initialDir = $bundledCpuDir
	}
	if (Test-Path -LiteralPath $initialDir -PathType Container) {
		$dialog.InitialDirectory = $initialDir
	}
	if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
		$exeCpuPathBox.Text = $dialog.FileName
		$script:envMap.LLAMA_CPP_EXE_CPU = $dialog.FileName
	}
})

$localCpuButton.Add_Click({
	$localExe = Resolve-BundledLlamaExePath -PreferGpu:$false
	if (-not (Test-Path -LiteralPath $localExe -PathType Leaf)) {
		[System.Windows.Forms.MessageBox]::Show((Get-UiText "missingBundled"), "Launcher", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
		return
	}
	$exeCpuPathBox.Text = $localExe
	$script:envMap.LLAMA_CPP_EXE_CPU = $localExe
})

$browseExeGpuButton.Add_Click({
	$dialog = New-Object System.Windows.Forms.OpenFileDialog
	$dialog.Title = "GPU 用 llama.cpp 実行ファイルを選択"
	$dialog.Filter = "Executable (*.exe)|*.exe|All files (*.*)|*.*"
	$dialog.CheckFileExists = $true
	$dialog.CheckPathExists = $true
	$dialog.Multiselect = $false
	$initialDir = Split-Path -Parent $exeGpuPathBox.Text
	if ([string]::IsNullOrWhiteSpace($initialDir) -or -not (Test-Path -LiteralPath $initialDir -PathType Container)) {
		$initialDir = $bundledGpuDir
	}
	if (Test-Path -LiteralPath $initialDir -PathType Container) {
		$dialog.InitialDirectory = $initialDir
	}
	if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
		$exeGpuPathBox.Text = $dialog.FileName
		$script:envMap.LLAMA_CPP_EXE_GPU = $dialog.FileName
	}
})

$localGpuButton.Add_Click({
	$localExe = Resolve-BundledLlamaExePath -PreferGpu:$true
	if (-not (Test-Path -LiteralPath $localExe -PathType Leaf)) {
		[System.Windows.Forms.MessageBox]::Show((Get-UiText "missingBundled"), "Launcher", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
		return
	}
	$exeGpuPathBox.Text = $localExe
	$script:envMap.LLAMA_CPP_EXE_GPU = $localExe
})

$browseModelFolderButton.Add_Click({
	$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
	$dialog.Description = "AIモデルフォルダを選択"
	$dialog.ShowNewFolderButton = $true
	$target = $modelFolderBox.Text.Trim()
	if ([string]::IsNullOrWhiteSpace($target)) {
		$target = $modelsDir
	}
	if (Test-Path -LiteralPath $target -PathType Container) {
		$dialog.SelectedPath = $target
	}
	if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
		$modelFolderBox.Text = $dialog.SelectedPath
	}
})

$applyLanguageButton.Add_Click({
	$script:currentLanguage = Get-SelectedLanguageCode
	Save-UiSettings -Path $uiSettingsFile -Language $script:currentLanguage
	Apply-UiLanguage
	Refresh-HardwareStatusLabels
	$statusLabel.Text = Get-UiText "langSaved"
})

$profileSaveButton.Add_Click({
	$name = $profileNameBox.Text.Trim()
	if ([string]::IsNullOrWhiteSpace($name)) {
		return
	}

	$payload = Capture-CurrentProfileData
	$existing = @($script:launchProfiles | Where-Object { [string]$_.name -eq $name } | Select-Object -First 1)
	if ($existing) {
		$existing.data = $payload
		$existing.updatedAt = (Get-Date).ToString("o")
	} else {
		$script:launchProfiles += [pscustomobject][ordered]@{
			name      = $name
			updatedAt = (Get-Date).ToString("o")
			data      = $payload
		}
	}

	Save-LaunchProfiles -Path $launchProfilesFile -Profiles $script:launchProfiles
	Refresh-ProfileList
	$statusLabel.Text = [string]::Format((Get-UiText "profileSaved"), $name)
})

$profileLoadButton.Add_Click({
	$name = [string]$profileListCombo.SelectedItem
	if ([string]::IsNullOrWhiteSpace($name)) {
		return
	}

	$target = @($script:launchProfiles | Where-Object { [string]$_.name -eq $name } | Select-Object -First 1)
	if (-not $target) {
		return
	}

	Apply-LaunchProfileData -ProfileData $target.data
	$exeCpuPathBox.Text = [string]$script:envMap.LLAMA_CPP_EXE_CPU
	$exeGpuPathBox.Text = [string]$script:envMap.LLAMA_CPP_EXE_GPU
	Set-ModeSelectionByHardware -Ngl ([string]$script:envMap.LLAMA_NGL)
	Refresh-AgentListView
	Refresh-AgentCheckList
	Refresh-ModelPathGrid
	if ($agentList.Items.Count -gt 0) { $agentList.SelectedIndex = 0 }
	Update-EstimateLabel
	Refresh-HardwareStatusLabels
	Update-BootUnsavedWarning
	Update-AiUnsavedWarning
	Update-AiDetailUnsavedWarning
	$statusLabel.Text = [string]::Format((Get-UiText "profileLoaded"), $name)
})

$updateCheckButton.Add_Click({
	if ($script:isUpdateRunning) {
		return
	}

	$updateCheckButton.Enabled = $false
	$updateApplyButton.Enabled = $false
	try {
		$updateStatusTextBox.Text = Get-UiText "updateRunning"
		$form.Refresh()
		Refresh-UpdateStatus -FetchRemote:$true
		$statusLabel.Text = Get-UiText "ready"
	} finally {
		$updateCheckButton.Enabled = $true
	}
})

$updateApplyButton.Add_Click({
	if ($script:isUpdateRunning) {
		return
	}

	$confirm = [System.Windows.Forms.MessageBox]::Show($form, (Get-UiText "confirmUpdate"), "Launcher", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
	if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
		return
	}

	$script:isUpdateRunning = $true
	$updateCheckButton.Enabled = $false
	$updateApplyButton.Enabled = $false
	try {
		$updateStatusTextBox.Text = Get-UiText "updateRunning"
		$form.Refresh()
		$result = Invoke-RepositoryUpdate -RebuildExe:([bool]$updateRebuildCheck.Checked)
		$updateStatusTextBox.Text = [string]$result.Details
		$statusLabel.Text = if ($result.Success) { Get-UiText "updateDone" } else { Get-UiText "updateFailed" }
	} finally {
		$script:isUpdateRunning = $false
		$updateCheckButton.Enabled = $true
		$status = Get-RepositoryUpdateStatus -FetchRemote:$false
		$updateApplyButton.Enabled = $status.Available -and $status.FetchOk -and (-not $status.Dirty) -and (-not [string]::IsNullOrWhiteSpace([string]$status.Upstream)) -and ($status.Ahead -eq 0) -and ($status.Behind -gt 0)
	}
})

$healthRefreshButton.Add_Click({ Refresh-HealthTab })
$logsRefreshButton.Add_Click({ Refresh-LogsTab })
$logsOpenButton.Add_Click({
	$target = [string]$logFileCombo.SelectedItem
	if (-not [string]::IsNullOrWhiteSpace($target) -and (Test-Path -LiteralPath $target -PathType Leaf)) {
		Start-Process notepad.exe -ArgumentList $target | Out-Null
	}
})

$logFileCombo.Add_SelectedIndexChanged({
	if ($logsAutoUpdateCheck.Checked) {
		Refresh-LogsTab
	}
})

$logsAutoUpdateCheck.Add_CheckedChanged({
	$script:isLogsAutoUpdateEnabled = [bool]$logsAutoUpdateCheck.Checked
	if ($script:isLogsAutoUpdateEnabled) {
		Refresh-LogsTab
		if ($logsAutoTimer -and -not $logsAutoTimer.Enabled) {
			$logsAutoTimer.Start()
		}
	} else {
		if ($logsAutoTimer -and $logsAutoTimer.Enabled) {
			$logsAutoTimer.Stop()
		}
	}
})

$tabs.Add_SelectedIndexChanged({
	if ($tabs.SelectedTab -eq $tabSettings -and [string]::IsNullOrWhiteSpace([string]$updateStatusTextBox.Text)) {
		Refresh-UpdateStatus -FetchRemote:$false
	} elseif ($tabs.SelectedTab -eq $tabHealth) {
		Refresh-HealthTab
	} elseif ($tabs.SelectedTab -eq $tabLogs -and $logsAutoUpdateCheck.Checked) {
		Refresh-LogsTab
	}
})

$exportSettingsButton.Add_Click({
	$dialog = New-Object System.Windows.Forms.SaveFileDialog
	$dialog.Title = Get-UiText "pickExport"
	$dialog.Filter = "JSON (*.json)|*.json|All files (*.*)|*.*"
	$dialog.FileName = "launcher-settings.json"
	if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
	Export-SettingsToFile -Path $dialog.FileName
	$statusLabel.Text = ([string]::Format((Get-UiText "exportDone"), $dialog.FileName))
})

$importSettingsButton.Add_Click({
	$dialog = New-Object System.Windows.Forms.OpenFileDialog
	$dialog.Title = Get-UiText "pickImport"
	$dialog.Filter = "JSON (*.json)|*.json|All files (*.*)|*.*"
	$dialog.CheckFileExists = $true
	if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
	try {
		$backupPath = Backup-ConfigSnapshot -Reason "import"
		Import-SettingsFromFile -Path $dialog.FileName
		Ensure-ModeExePaths -EnvMap $script:envMap
		Set-LanguageCombo -LanguageCode $script:currentLanguage
		Apply-UiLanguage
		$exeCpuPathBox.Text = [string]$script:envMap.LLAMA_CPP_EXE_CPU
		$exeGpuPathBox.Text = [string]$script:envMap.LLAMA_CPP_EXE_GPU
		Refresh-AgentListView
		Refresh-AgentCheckList
		Refresh-ModelPathGrid
		if ($agentList.Items.Count -gt 0) { $agentList.SelectedIndex = 0 }
		Refresh-HardwareStatusLabels
		Update-BootUnsavedWarning
		$script:savedAgentsFingerprint = Get-AgentsFingerprint -AgentItems $script:agents
		Update-AiUnsavedWarning
		Update-AiDetailUnsavedWarning
		$statusLabel.Text = (Get-UiText "importDone") + " / " + ([string]::Format((Get-UiText "backupDone"), $backupPath))
	} catch {
		Show-LauncherError -Title "Import failed" -Details (($_ | Out-String).TrimEnd())
	}
})

$resetBootButton.Add_Click({
	$confirm = [System.Windows.Forms.MessageBox]::Show($form, (Get-UiText "confirmResetBoot"), "Launcher", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
	if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
	$backupPath = Backup-ConfigSnapshot -Reason "reset-boot"
	$script:envMap = New-DefaultEnvMap
	$script:envMap.LLAMA_CPP_EXE_CPU = Resolve-BundledLlamaExePath -PreferGpu:$false
	$script:envMap.LLAMA_CPP_EXE_GPU = Resolve-BundledLlamaExePath -PreferGpu:$true
	if ($models.Count -gt 0) { $script:envMap.LLAMA_MODEL_PATH = [string]$models[0].FullName }
	$script:envMap.LLAMA_NGL = if (Test-NvidiaGpuDetected) { "99" } else { "0" }
	Save-EnvMap -EnvFile $envFile -EnvMap $script:envMap
	$exeCpuPathBox.Text = [string]$script:envMap.LLAMA_CPP_EXE_CPU
	$exeGpuPathBox.Text = [string]$script:envMap.LLAMA_CPP_EXE_GPU
	Refresh-HardwareStatusLabels
	Update-BootUnsavedWarning
	$statusLabel.Text = (Get-UiText "resetBootDone") + " / " + ([string]::Format((Get-UiText "backupDone"), $backupPath))
})

$resetAiButton.Add_Click({
	$confirm = [System.Windows.Forms.MessageBox]::Show($form, (Get-UiText "confirmResetAi"), "Launcher", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
	if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
	$backupPath = Backup-ConfigSnapshot -Reason "reset-ai"
	$script:agents = @(New-DefaultAgents -Models $models -EnvMap $script:envMap)
	Save-Agents -Path $agentProfileFile -Agents $script:agents
	Write-RuntimeProfile -ProfilePath $runtimeProfileFile -EnvMap $script:envMap -Agents $script:agents -ActiveAgentIds @("agent-1")
	$script:savedAgentsFingerprint = Get-AgentsFingerprint -AgentItems $script:agents
	Refresh-AgentListView
	Refresh-AgentCheckList
	Refresh-ModelPathGrid
	if ($agentList.Items.Count -gt 0) { $agentList.SelectedIndex = 0 }
	Update-EstimateLabel
	Update-AiUnsavedWarning
	Update-AiDetailUnsavedWarning
	$statusLabel.Text = (Get-UiText "resetAiDone") + " / " + ([string]::Format((Get-UiText "backupDone"), $backupPath))
})

$resetAllButton.Add_Click({
	$confirm = [System.Windows.Forms.MessageBox]::Show($form, (Get-UiText "confirmResetAll"), "Launcher", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
	if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
	$backupPath = Backup-ConfigSnapshot -Reason "reset-all"
	$script:envMap = New-DefaultEnvMap
	$script:envMap.LLAMA_CPP_EXE_CPU = Resolve-BundledLlamaExePath -PreferGpu:$false
	$script:envMap.LLAMA_CPP_EXE_GPU = Resolve-BundledLlamaExePath -PreferGpu:$true
	if ($models.Count -gt 0) { $script:envMap.LLAMA_MODEL_PATH = [string]$models[0].FullName }
	Save-EnvMap -EnvFile $envFile -EnvMap $script:envMap
	$script:agents = @(New-DefaultAgents -Models $models -EnvMap $script:envMap)
	Save-Agents -Path $agentProfileFile -Agents $script:agents
	$script:savedAgentsFingerprint = Get-AgentsFingerprint -AgentItems $script:agents
	Write-RuntimeProfile -ProfilePath $runtimeProfileFile -EnvMap $script:envMap -Agents $script:agents -ActiveAgentIds @("agent-1")
	$exeCpuPathBox.Text = [string]$script:envMap.LLAMA_CPP_EXE_CPU
	$exeGpuPathBox.Text = [string]$script:envMap.LLAMA_CPP_EXE_GPU
	Set-ModeSelectionByHardware -Ngl ([string]$script:envMap.LLAMA_NGL)
	Refresh-AgentListView
	Refresh-AgentCheckList
	Refresh-ModelPathGrid
	if ($agentList.Items.Count -gt 0) { $agentList.SelectedIndex = 0 }
	Update-EstimateLabel
	Refresh-HardwareStatusLabels
	Update-BootUnsavedWarning
	Update-AiUnsavedWarning
	Update-AiDetailUnsavedWarning
	$statusLabel.Text = (Get-UiText "resetDone") + " / " + ([string]::Format((Get-UiText "backupDone"), $backupPath))
})

$scanModelFolderButton.Add_Click({
	$target = $modelFolderBox.Text.Trim()
	if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path -LiteralPath $target -PathType Container)) {
		[System.Windows.Forms.MessageBox]::Show((Get-UiText "invalidFolder"), "Launcher", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
		return
	}

	$models = Get-Models -ModelsDir $target
	$modelFolderBox.Text = $target
	if ($models.Count -eq 0) {
		[System.Windows.Forms.MessageBox]::Show((Get-UiText "noGguf"), "Launcher", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
	}

	[void](Repair-AgentEntries -AgentItems $agents -KnownModels $models -EnvMap $envMap)
	Refresh-AgentListView
	Refresh-AgentCheckList
	Refresh-ModelPathGrid
	Update-EstimateLabel
	Update-AiUnsavedWarning
	Update-AiDetailUnsavedWarning
	$statusLabel.Text = ([string]::Format((Get-UiText "statusScanning"), $models.Count))
})

$agentCheckList.Add_ItemCheck({
	param($eventSource, $e)
	if ($script:IsRefreshingAgentChecks) {
		return
	}

	$updateInvoker = [System.Windows.Forms.MethodInvoker]{ Update-EstimateLabel }
	if ($eventSource.IsHandleCreated) {
		$eventSource.BeginInvoke($updateInvoker) | Out-Null
	} else {
		Update-EstimateLabel
	}
})

$cpuRadio.Add_CheckedChanged({
	Update-EstimateLabel
	if ($cpuRadio.Checked) {
		Sync-ExePathByMode
	}
	Update-BootUnsavedWarning
})
$gpuRadio.Add_CheckedChanged({
	Update-EstimateLabel
	if ($gpuRadio.Checked) {
		Sync-ExePathByMode
	}
	Update-BootUnsavedWarning
})
$exeCpuPathBox.Add_TextChanged({
	$script:envMap.LLAMA_CPP_EXE_CPU = $exeCpuPathBox.Text.Trim()
	Refresh-HardwareStatusLabels
	Update-BootUnsavedWarning
})

$exeGpuPathBox.Add_TextChanged({
	$script:envMap.LLAMA_CPP_EXE_GPU = $exeGpuPathBox.Text.Trim()
	Refresh-HardwareStatusLabels
	Update-BootUnsavedWarning
})

$modelFolderBox.Add_TextChanged({
	Update-BootUnsavedWarning
})

$startupTimer = New-Object System.Windows.Forms.Timer
$startupTimer.Interval = 420
$startupTimer.Add_Tick({
	if (-not $script:isStartupAnimating) {
		return
	}
	$script:startupDotIndex = ($script:startupDotIndex + 1) % $script:startupDots.Count
	$statusLabel.Text = Get-StartupStatusText -BaseText $script:startupBaseText
})

$logsAutoTimer = New-Object System.Windows.Forms.Timer
$logsAutoTimer.Interval = 3000
$logsAutoTimer.Add_Tick({
	if ($logsAutoUpdateCheck.Checked -and $tabs.SelectedTab -eq $tabLogs) {
		Refresh-LogsTab
	}
})

$idBox.Add_TextChanged({ Update-AiDetailUnsavedWarning })
$nameBox.Add_TextChanged({ Update-AiDetailUnsavedWarning })
$modelNameCombo.Add_SelectedIndexChanged({ Update-AiDetailUnsavedWarning })
$portBox.Add_TextChanged({ Update-AiDetailUnsavedWarning })
$nglBox.Add_TextChanged({ Update-AiDetailUnsavedWarning })
$ctxBox.Add_TextChanged({ Update-AiDetailUnsavedWarning })

$agentList.Add_SelectedIndexChanged({ Load-AgentDetail })

$updateAgentButton.Add_Click({
	Save-CurrentAgentDetail
	$changed = Repair-AgentEntries -AgentItems $script:agents -KnownModels $models -EnvMap $script:envMap
	Refresh-AgentListView
	Refresh-AgentCheckList
	Refresh-ModelPathGrid
	Update-EstimateLabel
	Update-AiUnsavedWarning
	Update-AiDetailUnsavedWarning
	$statusLabel.Text = if ($changed -gt 0) { [string]::Format((Get-UiText "statusAiDetailAuto"), $changed) } else { Get-UiText "statusAiDetailUpdated" }
})

$addAgentButton.Add_Click({
	$now = Get-Date
	if (($now - $script:LastAddAiClickAt).TotalMilliseconds -lt 500) {
		return
	}
	$script:LastAddAiClickAt = $now

	if ($addAgentButton.Tag -eq "busy") {
		return
	}
	$addAgentButton.Tag = "busy"
	try {
	$script:agents = @(Get-ValidAgents -AgentItems $script:agents)
	$defaultPath = if ($models.Count -gt 0) { $models[0].FullName } else { "" }
	$script:agents += [pscustomobject][ordered]@{
		no = ($script:agents.Count + 1)
		id = "agent-{0}" -f ($script:agents.Count + 1)
		name = "AI {0}" -f ($script:agents.Count + 1)
		enabled = $false
		modelPath = $defaultPath
		llamaPort = ""
		llamaNgl = [string]$script:envMap.LLAMA_NGL
		llamaCtx = [string]$script:envMap.LLAMA_CTX
	}
	$changed = Repair-AgentEntries -AgentItems $script:agents -KnownModels $models -EnvMap $script:envMap
	Refresh-AgentListView
	Refresh-AgentCheckList
	Refresh-ModelPathGrid
	$agentList.SelectedIndex = $script:agents.Count - 1
	Update-EstimateLabel
	Update-AiUnsavedWarning
	Update-AiDetailUnsavedWarning
	$statusLabel.Text = if ($changed -gt 0) { Get-UiText "statusAiAddedAuto" } else { Get-UiText "statusAiAdded" }
	} finally {
		$addAgentButton.Tag = $null
	}
})

$removeAgentButton.Add_Click({
	if ($agentList.SelectedIndex -lt 0) {
		return
	}
	if ($script:agents.Count -le 1) {
		[System.Windows.Forms.MessageBox]::Show((Get-UiText "atLeastOneAi"), "Launcher", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
		return
	}
	$idx = $agentList.SelectedIndex
	$next = [Math]::Max(0, $idx - 1)
	$script:agents = @($script:agents | Where-Object { $_ -ne $script:agents[$idx] })
	[void](Repair-AgentEntries -AgentItems $script:agents -KnownModels $models -EnvMap $script:envMap)
	Refresh-AgentListView
	Refresh-AgentCheckList
	Refresh-ModelPathGrid
	if ($script:agents.Count -gt 0) {
		$agentList.SelectedIndex = [Math]::Min($next, $script:agents.Count - 1)
	}
	Update-EstimateLabel
	Update-AiUnsavedWarning
	Update-AiDetailUnsavedWarning
})

$saveAgentsButton.Add_Click({
	Save-CurrentAgentDetail
	Save-PlaySelectionsToAgents
	$changed = Repair-AgentEntries -AgentItems $script:agents -KnownModels $models -EnvMap $script:envMap
	Save-Agents -Path $agentProfileFile -Agents $script:agents
	$script:savedAgentsFingerprint = Get-AgentsFingerprint -AgentItems $script:agents
	Refresh-AgentListView
	Refresh-AgentCheckList
	Refresh-ModelPathGrid
	Update-EstimateLabel
	Update-AiUnsavedWarning
	Update-AiDetailUnsavedWarning
	$statusLabel.Text = if ($changed -gt 0) { Get-UiText "statusAiSavedAuto" } else { Get-UiText "statusAiSaved" }
})

$saveBootButton.Add_Click({
	$script:envMap.LLAMA_CPP_EXE_CPU = $exeCpuPathBox.Text.Trim()
	$script:envMap.LLAMA_CPP_EXE_GPU = $exeGpuPathBox.Text.Trim()
	Save-EnvMap -EnvFile $envFile -EnvMap $script:envMap
	Save-BootConfigState -Path $bootConfigFile
	$script:savedBootConfig = Get-SavedBootConfigState -Path $bootConfigFile
	Update-BootUnsavedWarning
	$statusLabel.Text = Get-UiText "savedBoot"
})

$openGameButton.Add_Click({
	[void](Start-GameFromLauncher)
})

$closeButton.Add_Click({
	$form.Close()
})

$form.Add_FormClosing({
	param($eventSource, $e)
	[void]$eventSource

	if ($script:IsClosingHandled) {
		return
	}

	if (Stop-AllFromLauncher) {
		$script:IsClosingHandled = $true
		return
	}

	$e.Cancel = $true
})

$startButton.Add_Click({
	try {
		$startButton.Enabled = $false
		Save-CurrentAgentDetail
		Save-PlaySelectionsToAgents
		$changed = Repair-AgentEntries -AgentItems $script:agents -KnownModels $models -EnvMap $script:envMap
		if ($changed -gt 0) {
			[System.Windows.Forms.MessageBox]::Show((Get-UiText "autoFixNotice"), "Launcher", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
		}

		$active = @($script:agents | Where-Object { $_.enabled })
		if ($active.Count -eq 0) {
			throw (Get-UiText "noAiChecked")
		}

		$primary = $active[0]
		foreach ($agent in @($active)) {
			if ([string]::IsNullOrWhiteSpace([string]$agent.modelPath)) {
				throw (Get-UiText "noModelPath")
			}
			if (-not (Test-Path -LiteralPath $agent.modelPath -PathType Leaf)) {
				throw ([string]::Format((Get-UiText "modelNotFound"), $agent.modelPath))
			}
		}

		if ($cpuRadio.Checked) {
			$script:envMap.LLAMA_CPP_EXE_CPU = $exeCpuPathBox.Text.Trim()
			if ([string]::IsNullOrWhiteSpace($script:envMap.LLAMA_CPP_EXE_CPU)) {
				$script:envMap.LLAMA_CPP_EXE_CPU = Resolve-BundledLlamaExePath -PreferGpu:$false
			}
		} else {
			$script:envMap.LLAMA_CPP_EXE_GPU = $exeGpuPathBox.Text.Trim()
			if ([string]::IsNullOrWhiteSpace($script:envMap.LLAMA_CPP_EXE_GPU)) {
				$script:envMap.LLAMA_CPP_EXE_GPU = Resolve-BundledLlamaExePath -PreferGpu:$true
			}
		}

		$selectedExe = Get-ExePathForCurrentMode -EnvMap $script:envMap
		if ($cpuRadio.Checked) {
			$cpuExe = [string]$script:envMap.LLAMA_CPP_EXE_CPU
			if (Test-Path -LiteralPath $cpuExe -PathType Leaf) {
				$selectedExe = $cpuExe
			}
		} else {
			$gpuExe = [string]$script:envMap.LLAMA_CPP_EXE_GPU
			if (Test-Path -LiteralPath $gpuExe -PathType Leaf) {
				$selectedExe = $gpuExe
			}
		}

		if ($gpuRadio.Checked -and -not (Test-NvidiaGpuDetected)) {
			throw (Get-UiText "nvidiaOnly")
		}

		if ($gpuRadio.Checked -and (Test-IsBundledGpuExePath -LlamaCppExePath $selectedExe) -and -not (Test-BundledCudaRuntimeAvailable -LlamaCppExePath $selectedExe)) {
			if (Test-Path -LiteralPath $script:envMap.LLAMA_CPP_EXE_CPU -PathType Leaf) {
				$cpuRadio.Checked = $true
				$gpuRadio.Checked = $false
				$script:envMap.LLAMA_NGL = "0"
				$selectedExe = [string]$script:envMap.LLAMA_CPP_EXE_CPU
				[System.Windows.Forms.MessageBox]::Show((Get-UiText "cudaAutoFallback"), "Launcher", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
			} else {
				throw (Get-UiText "cudaMissingRun")
			}
		}

		$preflight = Invoke-LaunchPreflight -EnvMap $script:envMap -ActiveAgents $active -CpuMode:([bool]$cpuRadio.Checked)
		if (-not $preflight.Ok) {
			$healthTextBox.Text = $preflight.Details
			throw ((Get-UiText "preflightFailed") + "`r`n`r`n" + $preflight.Details)
		}

		$script:envMap.LLAMA_MODEL_PATH = [string]$primary.modelPath
		$script:envMap.LLAMA_PORT = [string]$primary.llamaPort
		$script:envMap.LLAMA_CTX = [string]$primary.llamaCtx
		$script:envMap.LLAMA_NGL = if ($cpuRadio.Checked) { "0" } else { [string]$primary.llamaNgl }
		if ([string]::IsNullOrWhiteSpace($script:envMap.LLAMA_HOST)) {
			$script:envMap.LLAMA_HOST = "127.0.0.1"
		}

		if (-not (Test-Path -LiteralPath $selectedExe -PathType Leaf)) {
			throw ([string]::Format((Get-UiText "exeNotFound"), $selectedExe))
		}

		Save-EnvMap -EnvFile $envFile -EnvMap $script:envMap
		Save-Agents -Path $agentProfileFile -Agents $script:agents

		$activeIds = @($active | ForEach-Object { [string]$_.id })
		Write-RuntimeProfile -ProfilePath $runtimeProfileFile -EnvMap $script:envMap -Agents $script:agents -ActiveAgentIds $activeIds

		Set-ServerRuntimeState -LlamaText (Get-UiText "llamaStateStarting") -LlamaColor ([System.Drawing.Color]::LimeGreen) -LocalText (Get-UiText "localStatePending") -LocalColor ([System.Drawing.Color]::LimeGreen)
		$statusLabel.Text = ([string]::Format((Get-UiText "statusStarting"), $active.Count))
		Start-StartupAnimation -BaseText ([string]::Format((Get-UiText "statusStarting"), $active.Count))
		$ok = Start-LlamaServersHidden -EnvMap $script:envMap -Agents $active -StateFile $llamaStateFile
		if (-not $ok) {
			Set-ServerRuntimeState -LlamaText (Get-UiText "llamaStateFailed") -LlamaColor ([System.Drawing.Color]::Tomato) -LocalText (Get-UiText "localStateIdle") -LocalColor ([System.Drawing.Color]::Silver)
			$details = (Get-UiText "llamaTimeoutHeader") + "`r`n`r`n" + (Get-UiText "llamaNotReady")
			if (-not [string]::IsNullOrWhiteSpace($script:lastStartupErrorDetails)) {
				$details += "`r`n`r`n" + $script:lastStartupErrorDetails
			}
			$details += "`r`n`r`n" + (Get-LocalServerStatusDetails -StateFile $gameStateFile)
			throw $details
		}
		Set-ServerRuntimeState -LlamaText (Get-UiText "llamaStateReady") -LlamaColor ([System.Drawing.Color]::LimeGreen) -LocalText (Get-UiText "localStatePending") -LocalColor ([System.Drawing.Color]::LimeGreen)

		$statusLabel.Text = ([string]::Format((Get-UiText "statusReadyInstances"), $active.Count))

		$go = [System.Windows.Forms.MessageBox]::Show(
			$form,
			"llama-server is ready. Open the game now?",
			"Launcher",
			[System.Windows.Forms.MessageBoxButtons]::YesNo,
			[System.Windows.Forms.MessageBoxIcon]::Question
		)
		if ($go -eq [System.Windows.Forms.DialogResult]::Yes) {
			[void](Start-GameFromLauncher)
		}
	} catch {
		Show-LauncherError -Title "LLM launcher failed" -Details (($_ | Out-String).TrimEnd())
		$statusLabel.Text = Get-UiText "ready"
	} finally {
		Stop-StartupAnimation
		$startButton.Enabled = $true
	}
})

Write-StartupTrace "before Refresh-AgentListView"
Refresh-AgentListView
Write-StartupTrace "before Refresh-AgentCheckList"
Refresh-AgentCheckList
Write-StartupTrace "before Refresh-ModelPathGrid"
Refresh-ModelPathGrid
Write-StartupTrace "before Repair-AgentEntries"
[void](Repair-AgentEntries -AgentItems $script:agents -KnownModels $models -EnvMap $script:envMap)
Write-StartupTrace "before Refresh-ProfileList"
Refresh-ProfileList
Write-StartupTrace "before Set-LanguageCombo"
Set-LanguageCombo -LanguageCode $script:currentLanguage
Write-StartupTrace "before Apply-UiLanguage"
Apply-UiLanguage
$gpuStatusLabel.Text = ""
$cudaStatusLabel.Text = ""
$null = Refresh-HardwareStatusLabels
$null = Update-BootUnsavedWarning
$null = Update-AiUnsavedWarning
$null = Update-AiDetailUnsavedWarning
Set-ServerRuntimeState -LlamaText (Get-UiText "llamaStateIdle") -LlamaColor ([System.Drawing.Color]::Silver) -LocalText (Get-UiText "localStateIdle") -LocalColor ([System.Drawing.Color]::Silver)
$closeButton.BringToFront()
$openGameButton.BringToFront()
$startButton.BringToFront()
if ($agentList.Items.Count -gt 0) {
	$agentList.SelectedIndex = 0
}
Update-EstimateLabel
Write-StartupTrace "before Refresh-HealthTab"
Refresh-HealthTab
Write-StartupTrace "skip Refresh-LogsTab (manual mode)"
$logsTextBox.Text = Get-UiText "logsManualHint"
Refresh-UpdateStatus -FetchRemote:$false
Write-StartupTrace "tabs refreshed"

Write-StartupTrace "before ShowDialog"
$startupSignalPath = Join-Path $launcherLogDir "startup-popup.signal"
try {
	[System.IO.File]::WriteAllText($startupSignalPath, "ready", [System.Text.UTF8Encoding]::new($false))
} catch {}
[void]$form.ShowDialog()
Write-StartupTrace "dialog closed"
