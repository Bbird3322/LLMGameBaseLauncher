param(
  [string]$Root = "",
  [int]$Port = 4173,
  [switch]$NoStaticServer
)

$ErrorActionPreference = "Stop"

if (-not $Root) {
  $Root = [string](Resolve-Path (Join-Path $PSScriptRoot ".."))
}

$rootFullPath = [System.IO.Path]::GetFullPath($Root)
$runtimeProfilePath = Join-Path $rootFullPath "config\runtimeProfile.json"
$envFilePath = Join-Path $rootFullPath "scripts\llama-server.env.bat"
$llamaStatePath = Join-Path $rootFullPath "scripts\llama-server.state.json"
$logDir = Join-Path $rootFullPath "logs"
$defaultLlamaUrl = "http://127.0.0.1:8080"

if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Get-ContentType([string]$Path) {
  switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    ".html" { return "text/html; charset=utf-8" }
    ".js"   { return "text/javascript; charset=utf-8" }
    ".json" { return "application/json; charset=utf-8" }
    ".css"  { return "text/css; charset=utf-8" }
    ".svg"  { return "image/svg+xml" }
    ".png"  { return "image/png" }
    ".jpg"  { return "image/jpeg" }
    ".jpeg" { return "image/jpeg" }
    ".gif"  { return "image/gif" }
    ".ico"  { return "image/x-icon" }
    default  { return "application/octet-stream" }
  }
}

function Write-StringResponse {
  param(
    [System.Net.HttpListenerResponse]$Response,
    [int]$StatusCode,
    [string]$Body,
    [string]$ContentType = "text/plain; charset=utf-8"
  )

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
  $Response.StatusCode = $StatusCode
  $Response.ContentType = $ContentType
  $Response.ContentLength64 = $bytes.Length
  $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function ConvertTo-JsonResponse {
  param($Data)

  return ($Data | ConvertTo-Json -Depth 8 -Compress)
}

function Write-JsonResponse {
  param(
    [System.Net.HttpListenerResponse]$Response,
    [int]$StatusCode,
    $Data
  )

  Write-StringResponse -Response $Response -StatusCode $StatusCode -Body (ConvertTo-JsonResponse -Data $Data) -ContentType "application/json; charset=utf-8"
}

function Read-JsonFile {
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

function Read-EnvMapFromBat {
  param([string]$Path)

  $map = @{}
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $map
  }

  foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue) {
    if ($line -match '^set "([^=]+)=(.*)"$') {
      $map[$Matches[1]] = $Matches[2]
    }
  }

  return $map
}

function Get-RuntimeEnvValue {
  param(
    $RuntimeConfig,
    [hashtable]$EnvMap,
    [string]$Key,
    [string]$Fallback = ""
  )

  if ($RuntimeConfig -and $RuntimeConfig.envMap -and ($RuntimeConfig.envMap.PSObject.Properties.Name -contains $Key)) {
    $value = [string]$RuntimeConfig.envMap.$Key
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value
    }
  }

  if ($EnvMap.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace([string]$EnvMap[$Key])) {
    return [string]$EnvMap[$Key]
  }

  return $Fallback
}

function Get-LlamaBaseUrl {
  if (Test-Path -LiteralPath $runtimeProfilePath -PathType Leaf) {
    try {
      $runtimeCfg = Get-Content -LiteralPath $runtimeProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($runtimeCfg.llamaCppUrl) {
        return [string]$runtimeCfg.llamaCppUrl
      }
    } catch {}
  }

  return $defaultLlamaUrl
}

function Test-HttpReady {
  param(
    [string]$Url,
    [int]$Attempts = 1,
    [int]$DelayMs = 200
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

function Stop-TrackedLlamaProcesses {
  $state = Read-JsonFile -Path $llamaStatePath
  if (-not $state) {
    return 0
  }

  $entries = @()
  if ($state.pid) {
    $entries = @($state)
  } elseif ($state.processes) {
    $entries = @($state.processes)
  }

  $stopped = 0
  foreach ($entry in @($entries)) {
    if (-not $entry.pid) { continue }
    try {
      $process = Get-Process -Id ([int]$entry.pid) -ErrorAction Stop
      Stop-Process -Id $process.Id -Force -ErrorAction Stop
      $stopped += 1
    } catch {}
  }

  try {
    if (Test-Path -LiteralPath $llamaStatePath -PathType Leaf) {
      Remove-Item -LiteralPath $llamaStatePath -Force -ErrorAction SilentlyContinue
    }
  } catch {}

  return $stopped
}

function Get-LlamaExePathForNgl {
  param(
    $RuntimeConfig,
    [hashtable]$EnvMap,
    [string]$Ngl
  )

  $cpuPath = Get-RuntimeEnvValue -RuntimeConfig $RuntimeConfig -EnvMap $EnvMap -Key "LLAMA_CPP_EXE_CPU" -Fallback (Join-Path $rootFullPath "llama-runtime\cpu\llama-server.exe")
  $gpuPath = Get-RuntimeEnvValue -RuntimeConfig $RuntimeConfig -EnvMap $EnvMap -Key "LLAMA_CPP_EXE_GPU" -Fallback (Join-Path $rootFullPath "llama-runtime\gpu\llama-server.exe")

  if ([string]$Ngl -eq "0") {
    return $cpuPath
  }

  return $gpuPath
}

function Add-CudaRuntimeToPath {
  $candidateDirs = @(
    (Join-Path $rootFullPath "llama-runtime\gpu"),
    (Join-Path $rootFullPath "llama-runtime\bin"),
    (Join-Path $rootFullPath "llama-runtime")
  )

  $existingParts = @([string]$env:PATH -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $prependDirs = @()
  foreach ($dir in $candidateDirs) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
      continue
    }
    if ($existingParts -contains $dir) {
      continue
    }
    $prependDirs += $dir
  }

  if ($prependDirs.Count -eq 0) {
    return $null
  }

  $originalPath = [string]$env:PATH
  $env:PATH = (($prependDirs + $existingParts) -join ';')
  return $originalPath
}

function Get-ActiveRuntimeAgents {
  param($RuntimeConfig)

  if (-not $RuntimeConfig -or -not $RuntimeConfig.agents) {
    return @()
  }

  $agents = @($RuntimeConfig.agents)
  $activeIds = @()
  if ($RuntimeConfig.activeAgentIds) {
    $activeIds = @($RuntimeConfig.activeAgentIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }

  if ($activeIds.Count -gt 0) {
    $selected = @($agents | Where-Object { $activeIds -contains [string]$_.id })
    if ($selected.Count -gt 0) {
      return @($selected)
    }
  }

  $enabled = @($agents | Where-Object { $_.enabled })
  if ($enabled.Count -gt 0) {
    return @($enabled)
  }

  return @($agents | Select-Object -First 1)
}

function Start-LlamaFromRuntimeProfile {
  $runtimeConfig = Read-JsonFile -Path $runtimeProfilePath
  $envMap = Read-EnvMapFromBat -Path $envFilePath
  if (-not $runtimeConfig) {
    return [pscustomobject]@{
      ok = $false
      error = "runtime_profile_missing"
      detail = "runtimeProfile.json was not found or could not be read."
      runtimeProfilePath = $runtimeProfilePath
    }
  }

  $agents = @(Get-ActiveRuntimeAgents -RuntimeConfig $runtimeConfig)
  if ($agents.Count -eq 0) {
    return [pscustomobject]@{
      ok = $false
      error = "no_active_agents"
      detail = "runtimeProfile.json does not contain active agents."
      runtimeProfilePath = $runtimeProfilePath
    }
  }

  $processStates = @()
  foreach ($agent in @($agents)) {
    $hostName = if ([string]::IsNullOrWhiteSpace([string]$runtimeConfig.llamaHost)) {
      Get-RuntimeEnvValue -RuntimeConfig $runtimeConfig -EnvMap $envMap -Key "LLAMA_HOST" -Fallback "127.0.0.1"
    } else {
      [string]$runtimeConfig.llamaHost
    }
    $portText = [string]$agent.llamaPort
    if ([string]::IsNullOrWhiteSpace($portText)) {
      $portText = if ([string]::IsNullOrWhiteSpace([string]$runtimeConfig.llamaPort)) {
        Get-RuntimeEnvValue -RuntimeConfig $runtimeConfig -EnvMap $envMap -Key "LLAMA_PORT" -Fallback "8080"
      } else {
        [string]$runtimeConfig.llamaPort
      }
    }

    $ngl = if ([string]::IsNullOrWhiteSpace([string]$agent.llamaNgl)) {
      if ([string]$runtimeConfig.mode -eq "cpu") { "0" } else { "99" }
    } else {
      [string]$agent.llamaNgl
    }
    $ctx = if ([string]::IsNullOrWhiteSpace([string]$agent.llamaCtx)) {
      Get-RuntimeEnvValue -RuntimeConfig $runtimeConfig -EnvMap $envMap -Key "LLAMA_CTX" -Fallback "8192"
    } else {
      [string]$agent.llamaCtx
    }
    $modelPath = [string]$agent.modelPath
    if ([string]::IsNullOrWhiteSpace($modelPath)) {
      $modelPath = [string]$runtimeConfig.modelPath
    }
    if ([string]::IsNullOrWhiteSpace($modelPath) -or -not (Test-Path -LiteralPath $modelPath -PathType Leaf)) {
      return [pscustomobject]@{
        ok = $false
        error = "model_not_found"
        detail = ("Model file not found for agent '{0}'." -f [string]$agent.name)
        modelPath = $modelPath
      }
    }

    $exePath = Get-LlamaExePathForNgl -RuntimeConfig $runtimeConfig -EnvMap $envMap -Ngl $ngl
    if ([string]::IsNullOrWhiteSpace($exePath) -or -not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
      return [pscustomobject]@{
        ok = $false
        error = "exe_not_found"
        detail = ("llama-server.exe not found for agent '{0}'." -f [string]$agent.name)
        exePath = $exePath
      }
    }

    $arguments = @(
      '-m', $modelPath,
      '--host', $hostName,
      '--port', $portText,
      '-c', $ctx,
      '-ngl', $ngl
    )
    $extraArgs = Get-RuntimeEnvValue -RuntimeConfig $runtimeConfig -EnvMap $envMap -Key "LLAMA_EXTRA_ARGS" -Fallback ""
    if (-not [string]::IsNullOrWhiteSpace($extraArgs)) {
      $arguments += ($extraArgs -split '\s+' | Where-Object { $_ })
    }

    $stdoutLog = Join-Path $logDir ("llama-{0}.stdout.log" -f [string]$agent.id)
    $stderrLog = Join-Path $logDir ("llama-{0}.stderr.log" -f [string]$agent.id)
    Remove-Item -LiteralPath $stdoutLog,$stderrLog -ErrorAction SilentlyContinue

    $originalPath = $null
    if ([string]$ngl -ne "0") {
      $originalPath = Add-CudaRuntimeToPath
    }

    try {
      $proc = Start-Process -FilePath $exePath -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
    } finally {
      if ($null -ne $originalPath) {
        $env:PATH = $originalPath
      }
    }
    $serverUrl = "http://{0}:{1}" -f $hostName, $portText
    $processStates += [ordered]@{
      id = [string]$agent.id
      name = [string]$agent.name
      pid = $proc.Id
      startedAt = (Get-Date).ToString("o")
      modelPath = $modelPath
      ngl = $ngl
      url = $serverUrl
      stdoutLog = $stdoutLog
      stderrLog = $stderrLog
    }

    if (-not (Test-HttpReady -Url "$serverUrl/health" -Attempts 30 -DelayMs 1000)) {
      $tail = ""
      try {
        if (Test-Path -LiteralPath $stderrLog -PathType Leaf) {
          $tail = (@(Get-Content -LiteralPath $stderrLog -Tail 30 -ErrorAction SilentlyContinue) -join "`n")
        }
      } catch {}

      Write-StringFile -Path $llamaStatePath -Content (ConvertTo-JsonResponse -Data ([ordered]@{ processes = $processStates }))
      return [pscustomobject]@{
        ok = $false
        error = "llama_not_ready"
        detail = ("llama-server did not become ready for agent '{0}'." -f [string]$agent.name)
        url = $serverUrl
        stderrTail = $tail
      }
    }
  }

  Write-StringFile -Path $llamaStatePath -Content (ConvertTo-JsonResponse -Data ([ordered]@{ processes = $processStates }))
  return [pscustomobject]@{
    ok = $true
    restartedAt = (Get-Date).ToString("o")
    processes = $processStates
  }
}

function Write-StringFile {
  param(
    [string]$Path,
    [string]$Content
  )

  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  [System.IO.File]::WriteAllText($Path, $Content + "`r`n", [System.Text.UTF8Encoding]::new($false))
}

function Restart-LlamaFromRuntimeProfile {
  $stopped = Stop-TrackedLlamaProcesses
  $result = Start-LlamaFromRuntimeProfile
  if ($result -and ($result.PSObject.Properties.Name -contains "ok") -and $result.ok) {
    $result | Add-Member -NotePropertyName stoppedProcesses -NotePropertyValue $stopped -Force
  }
  return $result
}

function Invoke-LlamaProxy {
  param([string]$JsonBody)

  $llamaBaseUrl = Get-LlamaBaseUrl
  $llamaChatUrl = "$llamaBaseUrl/v1/chat/completions"

  try {
    $res = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $llamaChatUrl -Body $JsonBody -ContentType "application/json; charset=utf-8" -TimeoutSec 90
    return @{ status = [int]$res.StatusCode; body = [string]$res.Content }
  } catch {
    $statusCode = 502
    $upstreamBody = ""
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      $statusCode = [int]$_.Exception.Response.StatusCode
      try {
        $stream = $_.Exception.Response.GetResponseStream()
        if ($null -ne $stream) {
          $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
          try {
            $upstreamBody = $reader.ReadToEnd()
          } finally {
            $reader.Dispose()
          }
        }
      } catch {}
    }

    $errorBody = (@{
      error = "llama_proxy_failed"
      detail = $_.Exception.Message
      llamaBaseUrl = $llamaBaseUrl
      upstreamBody = if ($upstreamBody.Length -gt 800) { $upstreamBody.Substring(0, 800) } else { $upstreamBody }
    } | ConvertTo-Json -Depth 4)

    return @{ status = $statusCode; body = $errorBody }
  }
}

function Invoke-DelayedStop([string]$StopArgs) {
  $stopScript = Join-Path $PSScriptRoot "stop-runtime.ps1"
  $command = "Start-Sleep -Milliseconds 500; & '$stopScript' $StopArgs"
  Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-Command", $command) -WindowStyle Hidden | Out-Null
}

function New-HttpResult {
  param(
    [int]$StatusCode,
    [string]$ContentType,
    [byte[]]$BodyBytes
  )

  return [pscustomobject]@{
    StatusCode  = $StatusCode
    ContentType = $ContentType
    BodyBytes   = $BodyBytes
  }
}

function New-TextResult {
  param(
    [int]$StatusCode,
    [string]$Body,
    [string]$ContentType = "text/plain; charset=utf-8"
  )

  return New-HttpResult -StatusCode $StatusCode -ContentType $ContentType -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes($Body))
}

function New-JsonResult {
  param(
    [int]$StatusCode,
    $Data
  )

  return New-TextResult -StatusCode $StatusCode -Body (ConvertTo-JsonResponse -Data $Data) -ContentType "application/json; charset=utf-8"
}

function Invoke-ServeRoute {
  param(
    [string]$Method,
    [string]$Path,
    [string]$Body
  )

  if ($Path -eq "/__health") {
    return New-JsonResult -StatusCode 200 -Data ([ordered]@{
      ok = $true
      role = if ($NoStaticServer) { "api" } else { "static+api" }
      port = $Port
      llamaBaseUrl = Get-LlamaBaseUrl
    })
  }

  if ($Path -eq "/__control/stop-game") {
    Invoke-DelayedStop -StopArgs "-GameOnly"
    return New-JsonResult -StatusCode 200 -Data ([ordered]@{ ok = $true; scope = "game" })
  }

  if ($Path -eq "/__control/stop-all") {
    Invoke-DelayedStop -StopArgs ""
    return New-JsonResult -StatusCode 200 -Data ([ordered]@{ ok = $true; scope = "all" })
  }

  if ($Path -eq "/__control/llama/restart") {
    if ($Method -notin @("POST", "GET")) {
      return New-JsonResult -StatusCode 405 -Data ([ordered]@{ ok = $false; error = "method_not_allowed"; allowed = @("POST", "GET") })
    }

    $restartResult = Restart-LlamaFromRuntimeProfile
    $statusCode = if ($restartResult.ok) { 200 } else { 500 }
    return New-JsonResult -StatusCode $statusCode -Data $restartResult
  }

  if ($Path -eq "/api/chat") {
    if ($Method -ne "POST") {
      return New-JsonResult -StatusCode 405 -Data ([ordered]@{ ok = $false; error = "method_not_allowed"; allowed = @("POST") })
    }

    if ([string]::IsNullOrWhiteSpace($Body)) {
      return New-JsonResult -StatusCode 400 -Data ([ordered]@{ ok = $false; error = "empty_request_body" })
    }

    $proxyResult = Invoke-LlamaProxy -JsonBody $Body
    return New-TextResult -StatusCode $proxyResult.status -Body $proxyResult.body -ContentType "application/json; charset=utf-8"
  }

  if ($Method -ne "GET") {
    return New-JsonResult -StatusCode 405 -Data ([ordered]@{ ok = $false; error = "method_not_allowed"; allowed = @("GET") })
  }

  if ($NoStaticServer) {
    return New-JsonResult -StatusCode 404 -Data ([ordered]@{ ok = $false; error = "static_server_disabled"; path = $Path })
  }

  if ($Path -eq "/") {
    $Path = "/index.html"
  }

  $relativePath = $Path.TrimStart('/') -replace '/', '\\'
  $candidatePath = Join-Path $rootFullPath $relativePath
  $localPath = [System.IO.Path]::GetFullPath($candidatePath)

  if (-not $localPath.StartsWith($rootFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    return New-TextResult -StatusCode 403 -Body "Forbidden"
  }

  if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
    return New-TextResult -StatusCode 404 -Body "Not Found"
  }

  return New-HttpResult -StatusCode 200 -ContentType (Get-ContentType -Path $localPath) -BodyBytes ([System.IO.File]::ReadAllBytes($localPath))
}

function Read-TcpHttpRequest {
  param([System.Net.Sockets.NetworkStream]$Stream)

  $headerBytes = New-Object System.Collections.Generic.List[byte]
  $buffer = New-Object byte[] 1
  while ($true) {
    $read = $Stream.Read($buffer, 0, 1)
    if ($read -le 0) {
      return $null
    }

    [void]$headerBytes.Add($buffer[0])
    $count = $headerBytes.Count
    if ($count -ge 4 -and $headerBytes[$count - 4] -eq 13 -and $headerBytes[$count - 3] -eq 10 -and $headerBytes[$count - 2] -eq 13 -and $headerBytes[$count - 1] -eq 10) {
      break
    }
  }

  $headerText = [System.Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
  $lines = @($headerText -split "`r`n")
  if ($lines.Count -eq 0 -or [string]::IsNullOrWhiteSpace($lines[0])) {
    return $null
  }

  $requestParts = @($lines[0] -split ' ')
  if ($requestParts.Count -lt 2) {
    return $null
  }

  $contentLength = 0
  foreach ($line in $lines) {
    if ($line -match '^Content-Length:\s*(\d+)\s*$') {
      $contentLength = [int]$Matches[1]
      break
    }
  }

  $bodyBytes = New-Object byte[] $contentLength
  $offset = 0
  while ($offset -lt $contentLength) {
    $read = $Stream.Read($bodyBytes, $offset, $contentLength - $offset)
    if ($read -le 0) {
      break
    }
    $offset += $read
  }

  $rawPath = [string]$requestParts[1]
  $pathOnly = ($rawPath -split '\?', 2)[0]
  return [pscustomobject]@{
    Method = [string]$requestParts[0]
    Path   = [System.Uri]::UnescapeDataString($pathOnly)
    Body   = [System.Text.Encoding]::UTF8.GetString($bodyBytes, 0, $offset)
  }
}

function Write-TcpHttpResponse {
  param(
    [System.Net.Sockets.NetworkStream]$Stream,
    $Result
  )

  $reason = switch ([int]$Result.StatusCode) {
    200 { "OK" }
    400 { "Bad Request" }
    403 { "Forbidden" }
    404 { "Not Found" }
    405 { "Method Not Allowed" }
    500 { "Internal Server Error" }
    502 { "Bad Gateway" }
    default { "OK" }
  }

  $bodyBytes = [byte[]]$Result.BodyBytes
  $header = "HTTP/1.1 {0} {1}`r`nContent-Type: {2}`r`nContent-Length: {3}`r`nConnection: close`r`n`r`n" -f [int]$Result.StatusCode, $reason, [string]$Result.ContentType, $bodyBytes.Length
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
  $Stream.Write($headerBytes, 0, $headerBytes.Length)
  if ($bodyBytes.Length -gt 0) {
    $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
  }
}

$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Parse("127.0.0.1")), $Port
$listener.Start()

try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $request = Read-TcpHttpRequest -Stream $stream
      if ($null -eq $request) {
        $result = New-JsonResult -StatusCode 400 -Data ([ordered]@{ ok = $false; error = "bad_request" })
      } else {
        try {
          $result = Invoke-ServeRoute -Method $request.Method -Path $request.Path -Body $request.Body
        } catch {
          $result = New-JsonResult -StatusCode 500 -Data ([ordered]@{
            ok = $false
            error = "internal_server_error"
            detail = $_.Exception.Message
          })
        }
      }

      Write-TcpHttpResponse -Stream $stream -Result $result
    } finally {
      try { $client.Close() } catch {}
    }
  }
} finally {
  $listener.Stop()
}
