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

function Get-EnvMap {
	param([string]$EnvFile)

	$defaults = [ordered]@{
		LLAMA_CPP_EXE    = ""
		LLAMA_MODEL_PATH = ""
		LLAMA_PORT       = "8080"
		LLAMA_HOST       = "127.0.0.1"
		LLAMA_NGL        = "99"
		LLAMA_CTX        = "8192"
		LLAMA_EXTRA_ARGS = ""
	}

	if (-not (Test-Path -LiteralPath $EnvFile)) {
		return $defaults
	}

	foreach ($line in Get-Content -LiteralPath $EnvFile) {
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

	$lines = @(
		'@echo off',
		('set "LLAMA_CPP_EXE={0}"' -f $EnvMap.LLAMA_CPP_EXE),
		('set "LLAMA_MODEL_PATH={0}"' -f $EnvMap.LLAMA_MODEL_PATH),
		('set "LLAMA_PORT={0}"' -f $EnvMap.LLAMA_PORT),
		('set "LLAMA_HOST={0}"' -f $EnvMap.LLAMA_HOST),
		('set "LLAMA_NGL={0}"' -f $EnvMap.LLAMA_NGL),
		('set "LLAMA_CTX={0}"' -f $EnvMap.LLAMA_CTX),
		('set "LLAMA_EXTRA_ARGS={0}"' -f $EnvMap.LLAMA_EXTRA_ARGS),
		'',
		'REM Examples:',
		'REM set "LLAMA_CPP_EXE=C:\tools\llama.cpp\bin\llama-server.exe"',
		'REM set "LLAMA_MODEL_PATH=C:\path\to\model.gguf"'
	)

	[System.IO.File]::WriteAllText($EnvFile, ($lines -join "`r`n") + "`r`n", [System.Text.ASCIIEncoding]::new())
}

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

function Get-Models {
	param([string]$ModelsDir)

	if (-not (Test-Path -LiteralPath $ModelsDir)) {
		return @()
	}

	return @(Get-ChildItem -LiteralPath $ModelsDir -Filter *.gguf -File | Sort-Object Length)
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
			$response = Invoke-WebRequest -UseBasicParsing $Url -TimeoutSec 2
			if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
				return $true
			}
		} catch {}
		Start-Sleep -Milliseconds $DelayMs
	}

	return $false
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
	foreach ($agent in @($Agents)) {
		$agentEnv = @{}
		foreach ($key in $EnvMap.Keys) {
			$agentEnv[$key] = $EnvMap[$key]
		}

		$agentEnv.LLAMA_MODEL_PATH = [string]$agent.modelPath
		$agentEnv.LLAMA_PORT = [string]$agent.llamaPort
		$agentEnv.LLAMA_CTX = [string]$agent.llamaCtx
		$agentEnv.LLAMA_NGL = [string]$agent.llamaNgl

		$serverUrl = "http://{0}:{1}" -f $agentEnv.LLAMA_HOST, $agentEnv.LLAMA_PORT
		$healthUrl = "$serverUrl/health"

		$args = @(
			'-m', $agentEnv.LLAMA_MODEL_PATH,
			'--host', $agentEnv.LLAMA_HOST,
			'--port', $agentEnv.LLAMA_PORT,
			'-c', $agentEnv.LLAMA_CTX,
			'-ngl', $agentEnv.LLAMA_NGL
		)

		if ($agentEnv.LLAMA_EXTRA_ARGS) {
			$args += ($agentEnv.LLAMA_EXTRA_ARGS -split '\\s+' | Where-Object { $_ })
		}

		$proc = Start-Process -FilePath $agentEnv.LLAMA_CPP_EXE -ArgumentList $args -WindowStyle Hidden -PassThru
		$processStates += [ordered]@{
			id        = [string]$agent.id
			name      = [string]$agent.name
			pid       = $proc.Id
			startedAt = (Get-Date).ToString("o")
			modelPath = $agentEnv.LLAMA_MODEL_PATH
			ngl       = $agentEnv.LLAMA_NGL
			url       = $serverUrl
		}

		if (-not (Wait-HttpReady -Url $healthUrl -Attempts 30 -DelayMs 1000)) {
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

	$proc = Start-Process -FilePath "powershell.exe" -ArgumentList $psArgs -WindowStyle Hidden -PassThru
	$stateObj = [ordered]@{
		pid       = $proc.Id
		startedAt = (Get-Date).ToString("o")
		url       = "http://127.0.0.1:$port/index.html"
	}
	Write-JsonFile -Path $StateFile -Data $stateObj
	return Wait-HttpReady -Url $healthUrl -Attempts 20 -DelayMs 500
}

function Write-LauncherErrorReport {
	param(
		[string]$Title,
		[string]$Details
	)

	$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
	$reportPath = Join-Path $launcherLogDir ("error_{0}.txt" -f $stamp)
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

function Get-EstimateText {
	param(
		[array]$SelectedAgents,
		[bool]$CpuMode,
		[double]$RamGiB
	)

	if ($SelectedAgents.Count -eq 0) {
		return "想定: AI未選択"
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
		return "想定(CPU): モデル合計 {0} GiB / 必要RAM目安 {1} GiB / 実RAM {2} GiB" -f $totalSize, $need, $RamGiB
	}

	$needGpu = [math]::Round(($totalSize * 1.15) + 1.0, 2)
	return "想定(GPU): モデル合計 {0} GiB / 必要VRAM目安 {1} GiB" -f $totalSize, $needGpu
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
			return $normalized
		}
	}

	$defaultModel = if ($Models.Count -gt 0) { $Models[0].FullName } else { [string]$EnvMap.LLAMA_MODEL_PATH }
	return @(
		[ordered]@{ no = 1; id = "agent-1"; name = "AI 1"; enabled = $true;  modelPath = $defaultModel; llamaPort = [string]$EnvMap.LLAMA_PORT; llamaNgl = [string]$EnvMap.LLAMA_NGL; llamaCtx = [string]$EnvMap.LLAMA_CTX },
		[ordered]@{ no = 2; id = "agent-2"; name = "AI 2"; enabled = $false; modelPath = $defaultModel; llamaPort = [string]$EnvMap.LLAMA_PORT; llamaNgl = [string]$EnvMap.LLAMA_NGL; llamaCtx = [string]$EnvMap.LLAMA_CTX },
		[ordered]@{ no = 3; id = "agent-3"; name = "AI 3"; enabled = $false; modelPath = $defaultModel; llamaPort = [string]$EnvMap.LLAMA_PORT; llamaNgl = [string]$EnvMap.LLAMA_NGL; llamaCtx = [string]$EnvMap.LLAMA_CTX }
	)
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

	return $result
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
	$defaultModelPath = if ($KnownModels.Count -gt 0) { $KnownModels[0].FullName } else { [string]$EnvMap.LLAMA_MODEL_PATH }

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

$scriptDir = Get-ScriptDir
$rootDir = [string](Resolve-Path (Join-Path $scriptDir ".."))
$modelsDir = Join-Path $rootDir "llama-runtime\\models"
$bundledBinDir = Join-Path $rootDir "llama-runtime\\bin"
$envFile = Join-Path $scriptDir "llama-server.env.bat"
$runtimeProfileFile = Join-Path $rootDir "config\\runtimeProfile.json"
$agentProfileFile = Join-Path $rootDir "config\\agentsProfile.json"
$llamaStateFile = Join-Path $scriptDir "llama-server.state.json"
$gameStateFile = Join-Path $scriptDir "game-server.state.json"
$launcherLogDir = Join-Path $rootDir "logs"
if (-not (Test-Path -LiteralPath $launcherLogDir)) {
	New-Item -ItemType Directory -Path $launcherLogDir -Force | Out-Null
}

$envMap = Get-EnvMap -EnvFile $envFile
$models = Get-Models -ModelsDir $modelsDir
$agents = Load-Agents -Path $agentProfileFile -Models $models -EnvMap $envMap
$systemInfo = Get-SystemInfoText
$script:IsRefreshingAgentChecks = $false
$script:LastAddAiClickAt = [datetime]::MinValue
$script:IsClosingHandled = $false

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

$modeLabel = New-Object System.Windows.Forms.Label
$modeLabel.Text = "実行モード"
$modeLabel.Location = New-Object System.Drawing.Point(18, 16)
$modeLabel.Size = New-Object System.Drawing.Size(120, 24)
$tabPlay.Controls.Add($modeLabel)

$gpuRadio = New-Object System.Windows.Forms.RadioButton
$gpuRadio.Text = "GPU"
$gpuRadio.Location = New-Object System.Drawing.Point(18, 44)
$gpuRadio.Size = New-Object System.Drawing.Size(90, 24)
$gpuRadio.Checked = ($envMap.LLAMA_NGL -ne "0")
$tabPlay.Controls.Add($gpuRadio)

$cpuRadio = New-Object System.Windows.Forms.RadioButton
$cpuRadio.Text = "CPU"
$cpuRadio.Location = New-Object System.Drawing.Point(110, 44)
$cpuRadio.Size = New-Object System.Drawing.Size(90, 24)
$cpuRadio.Checked = ($envMap.LLAMA_NGL -eq "0")
$tabPlay.Controls.Add($cpuRadio)

$sysInfoLabel = New-Object System.Windows.Forms.Label
$sysInfoLabel.Text = $systemInfo.Text
$sysInfoLabel.Location = New-Object System.Drawing.Point(18, 78)
$sysInfoLabel.Size = New-Object System.Drawing.Size(860, 24)
$sysInfoLabel.ForeColor = [System.Drawing.Color]::Silver
$tabPlay.Controls.Add($sysInfoLabel)

$estimateLabel = New-Object System.Windows.Forms.Label
$estimateLabel.Text = "想定: -"
$estimateLabel.Location = New-Object System.Drawing.Point(18, 108)
$estimateLabel.Size = New-Object System.Drawing.Size(860, 24)
$estimateLabel.ForeColor = [System.Drawing.Color]::Khaki
$tabPlay.Controls.Add($estimateLabel)

$agentCheckLabel = New-Object System.Windows.Forms.Label
$agentCheckLabel.Text = "並列起動で使うAI"
$agentCheckLabel.Location = New-Object System.Drawing.Point(18, 142)
$agentCheckLabel.Size = New-Object System.Drawing.Size(200, 22)
$tabPlay.Controls.Add($agentCheckLabel)

$agentCheckList = New-Object System.Windows.Forms.CheckedListBox
$agentCheckList.Location = New-Object System.Drawing.Point(18, 168)
$agentCheckList.Size = New-Object System.Drawing.Size(860, 220)
$agentCheckList.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
$agentCheckList.ForeColor = [System.Drawing.Color]::Gainsboro
$tabPlay.Controls.Add($agentCheckList)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(18, 428)
$statusLabel.Size = New-Object System.Drawing.Size(860, 24)
$statusLabel.ForeColor = [System.Drawing.Color]::Silver
$statusLabel.Text = "Ready."
$tabPlay.Controls.Add($statusLabel)

$openGameButton = New-Object System.Windows.Forms.Button
$openGameButton.Text = "Open Game"
$openGameButton.Location = New-Object System.Drawing.Point(598, 454)
$openGameButton.Size = New-Object System.Drawing.Size(110, 34)
$tabPlay.Controls.Add($openGameButton)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = "Start llama-server"
$startButton.Location = New-Object System.Drawing.Point(718, 454)
$startButton.Size = New-Object System.Drawing.Size(160, 34)
$startButton.BackColor = [System.Drawing.Color]::FromArgb(40, 96, 200)
$startButton.ForeColor = [System.Drawing.Color]::White
$startButton.FlatStyle = "Flat"
$tabPlay.Controls.Add($startButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "Close"
$closeButton.Location = New-Object System.Drawing.Point(502, 454)
$closeButton.Size = New-Object System.Drawing.Size(86, 34)
$tabPlay.Controls.Add($closeButton)

$exeLabel = New-Object System.Windows.Forms.Label
$exeLabel.Text = "llama 実行パス (LLAMA_CPP_EXE)"
$exeLabel.Location = New-Object System.Drawing.Point(18, 18)
$exeLabel.Size = New-Object System.Drawing.Size(280, 22)
$tabBoot.Controls.Add($exeLabel)

$exePathBox = New-Object System.Windows.Forms.TextBox
$exePathBox.Location = New-Object System.Drawing.Point(18, 44)
$exePathBox.Size = New-Object System.Drawing.Size(710, 27)
$exePathBox.Text = [string]$envMap.LLAMA_CPP_EXE
$tabBoot.Controls.Add($exePathBox)

$openBinButton = New-Object System.Windows.Forms.Button
$openBinButton.Text = "Open Bin"
$openBinButton.Location = New-Object System.Drawing.Point(738, 42)
$openBinButton.Size = New-Object System.Drawing.Size(140, 30)
$tabBoot.Controls.Add($openBinButton)

$modelFolderLabel = New-Object System.Windows.Forms.Label
$modelFolderLabel.Text = "AIモデルフォルダ (.gguf を走査)"
$modelFolderLabel.Location = New-Object System.Drawing.Point(18, 82)
$modelFolderLabel.Size = New-Object System.Drawing.Size(300, 22)
$tabBoot.Controls.Add($modelFolderLabel)

$modelFolderBox = New-Object System.Windows.Forms.TextBox
$modelFolderBox.Location = New-Object System.Drawing.Point(18, 106)
$modelFolderBox.Size = New-Object System.Drawing.Size(560, 27)
$modelFolderBox.Text = $modelsDir
$tabBoot.Controls.Add($modelFolderBox)

$browseModelFolderButton = New-Object System.Windows.Forms.Button
$browseModelFolderButton.Text = "Browse"
$browseModelFolderButton.Location = New-Object System.Drawing.Point(588, 104)
$browseModelFolderButton.Size = New-Object System.Drawing.Size(120, 30)
$tabBoot.Controls.Add($browseModelFolderButton)

$scanModelFolderButton = New-Object System.Windows.Forms.Button
$scanModelFolderButton.Text = "Scan .gguf"
$scanModelFolderButton.Location = New-Object System.Drawing.Point(718, 104)
$scanModelFolderButton.Size = New-Object System.Drawing.Size(160, 30)
$tabBoot.Controls.Add($scanModelFolderButton)

$modelListLabel = New-Object System.Windows.Forms.Label
$modelListLabel.Text = "AIモデルのパス一覧"
$modelListLabel.Location = New-Object System.Drawing.Point(18, 144)
$modelListLabel.Size = New-Object System.Drawing.Size(220, 24)
$tabBoot.Controls.Add($modelListLabel)

$modelPathGrid = New-Object System.Windows.Forms.DataGridView
$modelPathGrid.Location = New-Object System.Drawing.Point(18, 172)
$modelPathGrid.Size = New-Object System.Drawing.Size(860, 270)
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

function Save-CurrentAgentDetail {
	if ($agentList.SelectedIndex -lt 0 -or $agentList.SelectedIndex -ge $agents.Count) {
		return
	}

	$idx = $agentList.SelectedIndex
	$agents[$idx].id = if ([string]::IsNullOrWhiteSpace($idBox.Text)) { "agent-{0}" -f ($idx + 1) } else { $idBox.Text.Trim() }
	$agents[$idx].name = if ([string]::IsNullOrWhiteSpace($nameBox.Text)) { "AI {0}" -f ($idx + 1) } else { $nameBox.Text.Trim() }
	$selectedModelName = [string]$modelNameCombo.Text
	if ([string]::IsNullOrWhiteSpace($selectedModelName)) {
		$agents[$idx].modelPath = ""
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
		return
	}

	$a = $agents[$agentList.SelectedIndex]
	$idBox.Text = [string]$a.id
	$nameBox.Text = [string]$a.name
	$modelName = [System.IO.Path]::GetFileName([string]$a.modelPath)
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
}

function Save-PlaySelectionsToAgents {
	for ($i = 0; $i -lt $agents.Count; $i++) {
		$agents[$i].enabled = ($i -lt $agentCheckList.Items.Count) -and $agentCheckList.GetItemChecked($i)
	}
}

function Start-GameFromLauncher {
	try {
		if (-not (Ensure-GameServer -RootDir $rootDir -StateFile $gameStateFile)) {
			throw "Game server did not become ready."
		}
		Start-Process "http://127.0.0.1:4173/index.html"
		return $true
	} catch {
		Show-LauncherError -Title "Open game failed" -Details (($_ | Out-String).TrimEnd())
		return $false
	}
}

$openBinButton.Add_Click({
	if (-not (Test-Path -LiteralPath $bundledBinDir)) {
		New-Item -ItemType Directory -Path $bundledBinDir -Force | Out-Null
	}
	Start-Process explorer.exe $bundledBinDir
})

$browseModelFolderButton.Add_Click({
	$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
	$dialog.Description = "AIモデルフォルダを選択"
	$dialog.SelectedPath = $modelFolderBox.Text
	if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
		$modelFolderBox.Text = $dialog.SelectedPath
	}
})

$scanModelFolderButton.Add_Click({
	$target = $modelFolderBox.Text.Trim()
	if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path -LiteralPath $target -PathType Container)) {
		[System.Windows.Forms.MessageBox]::Show("有効なフォルダを指定してください。", "Launcher", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
		return
	}

	$models = Get-Models -ModelsDir $target
	$modelFolderBox.Text = $target
	if ($models.Count -eq 0) {
		[System.Windows.Forms.MessageBox]::Show("指定フォルダに .gguf がありません。", "Launcher", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
	}

	[void](Repair-AgentEntries -AgentItems $agents -KnownModels $models -EnvMap $envMap)
	Refresh-AgentListView
	Refresh-AgentCheckList
	Refresh-ModelPathGrid
	Update-EstimateLabel
	$statusLabel.Text = (".gguf scan: {0}件" -f $models.Count)
})

$agentCheckList.Add_ItemCheck({
	param($sender, $e)
	if ($script:IsRefreshingAgentChecks) {
		return
	}

	$updateInvoker = [System.Windows.Forms.MethodInvoker]{ Update-EstimateLabel }
	if ($sender.IsHandleCreated) {
		$sender.BeginInvoke($updateInvoker) | Out-Null
	} else {
		Update-EstimateLabel
	}
})

$cpuRadio.Add_CheckedChanged({ Update-EstimateLabel })
$gpuRadio.Add_CheckedChanged({ Update-EstimateLabel })

$agentList.Add_SelectedIndexChanged({ Load-AgentDetail })

$updateAgentButton.Add_Click({
	Save-CurrentAgentDetail
	$changed = Repair-AgentEntries -AgentItems $agents -KnownModels $models -EnvMap $envMap
	Refresh-AgentListView
	Refresh-AgentCheckList
	Refresh-ModelPathGrid
	Update-EstimateLabel
	$statusLabel.Text = if ($changed -gt 0) { "AI詳細反映 + 自動補正: $changed件" } else { "AI詳細を反映しました。" }
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
	$agents = Get-ValidAgents -AgentItems $agents
	$beforeCount = $agents.Count
	$defaultPath = if ($models.Count -gt 0) { $models[0].FullName } else { "" }
	$agents += [ordered]@{
		no = ($agents.Count + 1)
		id = "agent-{0}" -f ($agents.Count + 1)
		name = "AI {0}" -f ($agents.Count + 1)
		enabled = $false
		modelPath = $defaultPath
		llamaPort = ""
		llamaNgl = [string]$envMap.LLAMA_NGL
		llamaCtx = [string]$envMap.LLAMA_CTX
	}
	if ($agents.Count -gt ($beforeCount + 1)) {
		$agents = @($agents | Select-Object -First ($beforeCount + 1))
	}
	$changed = Repair-AgentEntries -AgentItems $agents -KnownModels $models -EnvMap $envMap
	Refresh-AgentListView
	Refresh-AgentCheckList
	Refresh-ModelPathGrid
	$agentList.SelectedIndex = $agents.Count - 1
	Update-EstimateLabel
	$statusLabel.Text = if ($changed -gt 0) { "AI追加 + Port自動採番" } else { "AIを追加しました。" }
	} finally {
		$addAgentButton.Tag = $null
	}
})

$removeAgentButton.Add_Click({
	if ($agentList.SelectedIndex -lt 0) {
		return
	}
	$idx = $agentList.SelectedIndex
	$next = [Math]::Max(0, $idx - 1)
	$agents = @($agents | Where-Object { $_ -ne $agents[$idx] })
	[void](Repair-AgentEntries -AgentItems $agents -KnownModels $models -EnvMap $envMap)
	Refresh-AgentListView
	Refresh-AgentCheckList
	Refresh-ModelPathGrid
	if ($agents.Count -gt 0) {
		$agentList.SelectedIndex = [Math]::Min($next, $agents.Count - 1)
	}
	Update-EstimateLabel
})

$saveAgentsButton.Add_Click({
	Save-CurrentAgentDetail
	Save-PlaySelectionsToAgents
	$changed = Repair-AgentEntries -AgentItems $agents -KnownModels $models -EnvMap $envMap
	Save-Agents -Path $agentProfileFile -Agents $agents
	Refresh-AgentListView
	Refresh-AgentCheckList
	Refresh-ModelPathGrid
	Update-EstimateLabel
	$statusLabel.Text = if ($changed -gt 0) { "AIモデル保存 + Port重複を自動補正" } else { "AIモデル設定を保存しました。" }
})

$saveBootButton.Add_Click({
	$envMap.LLAMA_CPP_EXE = $exePathBox.Text.Trim()
	Save-EnvMap -EnvFile $envFile -EnvMap $envMap
	$statusLabel.Text = "起動構成を保存しました。"
})

$openGameButton.Add_Click({
	[void](Start-GameFromLauncher)
})

$closeButton.Add_Click({
	$form.Close()
})

$form.Add_FormClosing({
	param($sender, $e)

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
		Save-CurrentAgentDetail
		Save-PlaySelectionsToAgents
		$changed = Repair-AgentEntries -AgentItems $agents -KnownModels $models -EnvMap $envMap
		if ($changed -gt 0) {
			[System.Windows.Forms.MessageBox]::Show("AI設定を自動補正しました（重複Portや空欄）。", "Launcher", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
		}

		$active = @($agents | Where-Object { $_.enabled })
		if ($active.Count -eq 0) {
			throw "並列起動に使うAIを1つ以上チェックしてください。"
		}

		$primary = $active[0]
		foreach ($agent in @($active)) {
			if ([string]::IsNullOrWhiteSpace([string]$agent.modelPath)) {
				throw "選択されたAIにモデルパスがありません。"
			}
			if (-not (Test-Path -LiteralPath $agent.modelPath -PathType Leaf)) {
				throw "モデルファイルが存在しません: $($agent.modelPath)"
			}
		}

		$envMap.LLAMA_CPP_EXE = $exePathBox.Text.Trim()
		if ([string]::IsNullOrWhiteSpace($envMap.LLAMA_CPP_EXE)) {
			$envMap.LLAMA_CPP_EXE = Join-Path $bundledBinDir "llama-server.exe"
		}

		$envMap.LLAMA_MODEL_PATH = [string]$primary.modelPath
		$envMap.LLAMA_PORT = [string]$primary.llamaPort
		$envMap.LLAMA_CTX = [string]$primary.llamaCtx
		$envMap.LLAMA_NGL = if ($cpuRadio.Checked) { "0" } else { [string]$primary.llamaNgl }
		if ([string]::IsNullOrWhiteSpace($envMap.LLAMA_HOST)) {
			$envMap.LLAMA_HOST = "127.0.0.1"
		}

		if (-not (Test-Path -LiteralPath $envMap.LLAMA_CPP_EXE -PathType Leaf)) {
			throw "llama-server.exe が見つかりません: $($envMap.LLAMA_CPP_EXE)"
		}

		Save-EnvMap -EnvFile $envFile -EnvMap $envMap
		Save-Agents -Path $agentProfileFile -Agents $agents

		$activeIds = @($active | ForEach-Object { [string]$_.id })
		Write-RuntimeProfile -ProfilePath $runtimeProfileFile -EnvMap $envMap -Agents $agents -ActiveAgentIds $activeIds

		$statusLabel.Text = ("llama-server 起動中... ({0} instance(s))" -f $active.Count)
		$ok = Start-LlamaServersHidden -EnvMap $envMap -Agents $active -StateFile $llamaStateFile
		if (-not $ok) {
			throw "llama-server did not become ready within 30 seconds."
		}

		$statusLabel.Text = ("Ready: {0} instance(s)" -f $active.Count)

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
		$statusLabel.Text = "Ready."
	}
})

Refresh-AgentListView
Refresh-AgentCheckList
Refresh-ModelPathGrid
[void](Repair-AgentEntries -AgentItems $agents -KnownModels $models -EnvMap $envMap)
$closeButton.BringToFront()
$openGameButton.BringToFront()
$startButton.BringToFront()
if ($agentList.Items.Count -gt 0) {
	$agentList.SelectedIndex = 0
}
Update-EstimateLabel

Start-LauncherExitWatchdog -LauncherPid $PID -StopScriptPath (Join-Path $scriptDir "stop-runtime.ps1")
[void]$form.ShowDialog()
