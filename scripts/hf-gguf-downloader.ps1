$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {
  $securityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
  if ([enum]::GetNames([System.Net.SecurityProtocolType]) -contains "Tls13") {
    $securityProtocol = $securityProtocol -bor [System.Net.SecurityProtocolType]::Tls13
  }
  [System.Net.ServicePointManager]::SecurityProtocol = $securityProtocol
} catch {}

[System.Windows.Forms.Application]::EnableVisualStyles()

function Show-ErrorDialog {
  param([string]$Message)

  [System.Windows.Forms.MessageBox]::Show(
    $Message,
    "HF GGUF Downloader",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
  ) | Out-Null
}

function Invoke-Ui {
  param([scriptblock]$Action)

  try {
    & $Action
  } catch {
    Show-ErrorDialog -Message (($_ | Out-String).Trim())
  }
}

function Get-HfHeaders {
  param([string]$Token)

  $headers = @{ "User-Agent" = "HF-GGUF-Downloader/0.2" }
  if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $headers["Authorization"] = "Bearer $Token"
  }
  return $headers
}

function Invoke-HfHttpRequest {
  param(
    [string]$Uri,
    [string]$Token = "",
    [string]$Method = "GET"
  )

  if ([string]::IsNullOrWhiteSpace($Uri)) {
    throw "Uri is required."
  }

  $request = [System.Net.HttpWebRequest]::Create($Uri)
  $request.Method = $Method
  $request.AllowAutoRedirect = $true
  $request.UserAgent = "HF-GGUF-Downloader/0.3"
  $request.Accept = "application/json, text/plain, */*"
  $request.Timeout = 30000
  $request.ReadWriteTimeout = 30000
  if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $request.Headers["Authorization"] = "Bearer $Token"
  }

  $response = $null
  $stream = $null
  $reader = $null
  try {
    $response = [System.Net.HttpWebResponse]$request.GetResponse()
    $stream = $response.GetResponseStream()

    $encoding = [System.Text.Encoding]::UTF8
    if (-not [string]::IsNullOrWhiteSpace([string]$response.CharacterSet)) {
      try {
        $encoding = [System.Text.Encoding]::GetEncoding([string]$response.CharacterSet)
      } catch {}
    }

    $reader = New-Object System.IO.StreamReader($stream, $encoding)
    return [pscustomobject]@{
      Content    = $reader.ReadToEnd()
      Headers    = $response.Headers
      StatusCode = [int]$response.StatusCode
    }
  } finally {
    if ($reader) { $reader.Dispose() }
    elseif ($stream) { $stream.Dispose() }
    if ($response) { $response.Dispose() }
  }
}

function Invoke-HfJsonRequest {
  param(
    [string]$Uri,
    [string]$Token = ""
  )

  $response = Invoke-HfHttpRequest -Uri $Uri -Token $Token -Method "GET"
  if ([string]::IsNullOrWhiteSpace([string]$response.Content)) {
    return $null
  }

  return ([string]$response.Content | ConvertFrom-Json)
}

function ConvertFrom-HfApiJson {
  param([string]$Content)

  if ([string]::IsNullOrWhiteSpace($Content)) {
    return @()
  }

  $parsed = $Content | ConvertFrom-Json
  if ($parsed -is [System.Array]) {
    return @($parsed)
  }
  if ($parsed.PSObject.Properties.Name -contains "models") {
    return @($parsed.models)
  }
  return @($parsed)
}

function Get-HfNextLink {
  param([string]$LinkHeader)

  if ([string]::IsNullOrWhiteSpace($LinkHeader)) {
    return $null
  }

  $linkMatches = [regex]::Matches($LinkHeader, '<([^>]+)>;\s*rel="([^"]+)"')
  foreach ($match in $linkMatches) {
    if ([string]$match.Groups[2].Value -eq "next") {
      return [string]$match.Groups[1].Value
    }
  }

  return $null
}

function Read-JsonFileSafe {
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

function Get-ProjectRootDir {
  if (-not [string]::IsNullOrWhiteSpace([string]$PSScriptRoot)) {
    $scriptDir = [string]$PSScriptRoot
    return [string](Split-Path -Parent $scriptDir)
  }

  return [string](Get-Location)
}

function Get-ConfiguredModelDir {
  $rootDir = Get-ProjectRootDir
  $bootSettingsPath = Join-Path $rootDir "config\bootSettings.json"
  $bootSettings = Read-JsonFileSafe -Path $bootSettingsPath

  if ($bootSettings -and $bootSettings.boot -and -not [string]::IsNullOrWhiteSpace([string]$bootSettings.boot.modelFolder)) {
    return [string]$bootSettings.boot.modelFolder
  }

  return (Join-Path $rootDir "llama-runtime\models")
}

function Get-HfCatalogCachePath {
  $rootDir = Get-ProjectRootDir
  $configDir = Join-Path $rootDir "config"
  if (-not (Test-Path -LiteralPath $configDir -PathType Container)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
  }

  return (Join-Path $configDir "hf-gguf-model-catalog.json")
}

function Get-HfTextResourcesPath {
  $rootDir = Get-ProjectRootDir
  $scriptsDir = Join-Path $rootDir "scripts"
  return (Join-Path $scriptsDir "hf-gguf-text-resources.json")
}

function Get-HfTextResources {
  if ($script:hfTextResources) {
    return $script:hfTextResources
  }

  $resourcePath = Get-HfTextResourcesPath
  $script:hfTextResources = Read-JsonFileSafe -Path $resourcePath
  return $script:hfTextResources
}

function Get-HfLlamaCppModels {
  param([int]$MaxCount = 0)

  $pageSize = 100
  $collected = @()
  $nextUri = "https://huggingface.co/api/models?filter=llama.cpp&sort=downloads&direction=-1&limit=$pageSize"

  while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
    $response = Invoke-HfHttpRequest -Uri $nextUri
    $items = @(ConvertFrom-HfApiJson -Content $response.Content)
    if ($items.Count -eq 0) {
      break
    }

    if ($MaxCount -gt 0) {
      $remaining = $MaxCount - $collected.Count
      if ($remaining -le 0) {
        break
      }
      if ($items.Count -gt $remaining) {
        $collected += @($items | Select-Object -First $remaining)
        break
      }
    }

    $collected += $items
    $nextUri = Get-HfNextLink -LinkHeader ([string]$response.Headers["Link"])
    if ($items.Count -lt $pageSize) {
      break
    }
  }

  $seen = @{}
  $result = @()
  foreach ($item in $collected) {
    $repoId = [string]$item.id
    if ([string]::IsNullOrWhiteSpace($repoId) -or $seen.ContainsKey($repoId)) {
      continue
    }
    $seen[$repoId] = $true

    $downloads = 0L
    if ($null -ne $item.downloads) {
      $parsedDownloads = 0L
      if ([int64]::TryParse([string]$item.downloads, [ref]$parsedDownloads)) {
        $downloads = $parsedDownloads
      }
    }

    $result += [pscustomobject]@{
      RepoId      = $repoId
      Author      = [string]$item.author
      PublishedAt = [string]$item.createdAt
      Downloads   = $downloads
      LastChanged = [string]$item.lastModified
    }
  }

  return $result
}

function ConvertTo-CachedModelEntry {
  param([object]$Model)

  $downloads = 0L
  $parsedDownloads = 0L
  if ([int64]::TryParse([string]$Model.Downloads, [ref]$parsedDownloads)) {
    $downloads = $parsedDownloads
  }

  return [pscustomobject]@{
    RepoId      = [string]$Model.RepoId
    Author      = [string]$Model.Author
    PublishedAt = [string]$Model.PublishedAt
    Downloads   = $downloads
    LastChanged = [string]$Model.LastChanged
  }
}

function Test-HfModelCatalogCacheCompatible {
  param([object[]]$Models)

  if (-not $Models -or @($Models).Count -eq 0) {
    return $false
  }

  foreach ($model in @($Models)) {
    if ([string]::IsNullOrWhiteSpace([string]$model.RepoId)) {
      return $false
    }
    if (-not ($model.PSObject.Properties.Name -contains "PublishedAt")) {
      return $false
    }
  }

  return $true
}

function Save-HfModelCatalogCache {
  param([object[]]$Models)

  $cachePath = Get-HfCatalogCachePath
  $payload = [pscustomobject]@{
    UpdatedAt = [datetime]::UtcNow.ToString("o")
    Models    = @($Models | ForEach-Object { ConvertTo-CachedModelEntry -Model $_ })
  }

  $payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cachePath -Encoding UTF8
}

function Get-HfModelCatalogCache {
  $cachePath = Get-HfCatalogCachePath
  $cache = Read-JsonFileSafe -Path $cachePath
  if (-not $cache) {
    return $null
  }

  if (-not ($cache.PSObject.Properties.Name -contains "Models")) {
    return $null
  }

  $models = @()
  foreach ($model in @($cache.Models)) {
    if ([string]::IsNullOrWhiteSpace([string]$model.RepoId)) {
      continue
    }

    $models += ConvertTo-CachedModelEntry -Model $model
  }

  return [pscustomobject]@{
    UpdatedAt = [string]$cache.UpdatedAt
    Models    = $models
  }
}

function Get-SafeDateTime {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return [datetime]::MinValue
  }

  $parsed = [datetime]::MinValue
  if ([datetime]::TryParse($Value, [ref]$parsed)) {
    return $parsed.ToUniversalTime()
  }

  return [datetime]::MinValue
}

function Get-DisplayDate {
  param([string]$Value)

  $parsed = Get-SafeDateTime -Value $Value
  if ($parsed -eq [datetime]::MinValue) {
    return ""
  }

  return $parsed.ToString("yyyy-MM-dd")
}

function Get-ModelNameFromRepoId {
  param([string]$RepoId)

  $repoIdText = [string]$RepoId
  if ([string]::IsNullOrWhiteSpace($repoIdText)) {
    return ""
  }

  $segments = @($repoIdText -split '/')
  if ($segments.Count -ge 2) {
    return [string]$segments[$segments.Count - 1]
  }

  return $repoIdText
}

function Get-ModelAuthorName {
  param([object]$Model)

  $author = [string]$Model.Author
  if (-not [string]::IsNullOrWhiteSpace($author)) {
    return $author
  }

  $repoIdText = [string]$Model.RepoId
  $segments = @($repoIdText -split '/')
  if ($segments.Count -ge 2) {
    return [string]$segments[0]
  }

  return ""
}

function Get-ModelTrendScore {
  param([object]$Model)

  $lastChangedUtc = Get-SafeDateTime -Value ([string]$Model.LastChanged)
  $ageDays = [Math]::Max(1.0, ([datetime]::UtcNow - $lastChangedUtc).TotalDays)
  $downloads = [double]([int64]$Model.Downloads)
  return [Math]::Round($downloads / [Math]::Pow($ageDays + 2.0, 0.6), 2)
}

function Sort-Models {
  param([object[]]$Models)

  $sortBy = [string]$script:modelSortMode

  switch ($sortBy) {
    "LastChanged" {
      return @(
        $Models |
          Sort-Object -Property `
            @{ Expression = { Get-SafeDateTime -Value ([string]$_.LastChanged) }; Descending = $true }, `
            @{ Expression = { [int64]$_.Downloads }; Descending = $true }, `
            @{ Expression = { [string]$_.RepoId }; Descending = $false }
      )
    }
    "Trend" {
      return @(
        $Models |
          Sort-Object -Property `
            @{ Expression = { Get-ModelTrendScore -Model $_ }; Descending = $true }, `
            @{ Expression = { Get-SafeDateTime -Value ([string]$_.LastChanged) }; Descending = $true }, `
            @{ Expression = { [int64]$_.Downloads }; Descending = $true }, `
            @{ Expression = { [string]$_.RepoId }; Descending = $false }
      )
    }
    default {
      return @(
        $Models |
          Sort-Object -Property `
            @{ Expression = { [int64]$_.Downloads }; Descending = $true }, `
            @{ Expression = { Get-SafeDateTime -Value ([string]$_.LastChanged) }; Descending = $true }, `
            @{ Expression = { [string]$_.RepoId }; Descending = $false }
      )
    }
  }
}

function Get-CategoryNameFromRepoId {
  param([string]$RepoId)

  $name = [string]$RepoId
  if ($name -match '(?i)gemma') { return "Gemma" }
  if ($name -match '(?i)qwen') { return "Qwen" }
  if ($name -match '(?i)llama') { return "Llama" }
  if ($name -match '(?i)mistral|mixtral') { return "Mistral" }
  if ($name -match '(?i)phi') { return "Phi" }
  if ($name -match '(?i)deepseek') { return "DeepSeek" }
  if ($name -match '(?i)exaone') { return "EXAONE" }
  if ($name -match '(?i)command-r|cohere') { return "Command-R" }
  if ($name -match '(?i)solar') { return "Solar" }
  return "Other"
}

function Get-ModelCategories {
  param([object[]]$Models)

  $groups = @(
    $Models |
      Group-Object -Property { Get-CategoryNameFromRepoId -RepoId $_.RepoId } |
      Sort-Object -Property @{ Expression = "Count"; Descending = $true }, @{ Expression = "Name"; Descending = $false }
  )

  $categories = @()
  $categories += [pscustomobject]@{
    Name  = "All"
    Count = @($Models).Count
  }

  foreach ($group in $groups) {
    $authors = @(
      $group.Group |
        Group-Object -Property Author |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Name) } |
        Sort-Object -Property @{ Expression = "Count"; Descending = $true }, @{ Expression = "Name"; Descending = $false }
    )
    $primaryAuthor = if ($authors.Count -gt 0) { [string]$authors[0].Name } else { "" }

    $categories += [pscustomobject]@{
      Name          = [string]$group.Name
      Count         = @($group.Group).Count
      PrimaryAuthor = $primaryAuthor
    }
  }

  return $categories
}

function Get-AvatarUrlForAuthor {
  param([string]$Author)

  if ([string]::IsNullOrWhiteSpace($Author)) {
    return ""
  }

  return "https://huggingface.co/api/users/$([uri]::EscapeDataString($Author))/avatar"
}

function New-PlaceholderBitmap {
  param(
    [string]$Text,
    [int]$Width = 72,
    [int]$Height = 72
  )

  $bitmap = New-Object System.Drawing.Bitmap($Width, $Height)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.Clear([System.Drawing.Color]::FromArgb(236, 240, 245))
  $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(52, 73, 94))
  $font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
  $rect = New-Object System.Drawing.RectangleF(0, 0, $Width, $Height)
  $format = New-Object System.Drawing.StringFormat
  $format.Alignment = [System.Drawing.StringAlignment]::Center
  $format.LineAlignment = [System.Drawing.StringAlignment]::Center
  $graphics.DrawString($Text, $font, $brush, $rect, $format)
  $graphics.Dispose()
  $brush.Dispose()
  $font.Dispose()
  $format.Dispose()
  return $bitmap
}

function Get-AvatarImage {
  param(
    [string]$Author,
    [string]$FallbackText
  )

  $avatarUrl = Get-AvatarUrlForAuthor -Author $Author
  if (-not [string]::IsNullOrWhiteSpace($avatarUrl)) {
    try {
      $request = [System.Net.WebRequest]::Create($avatarUrl)
      $request.UserAgent = "HF-GGUF-Downloader/0.3"
      $response = $request.GetResponse()
      try {
        $stream = $response.GetResponseStream()
        try {
          return [System.Drawing.Image]::FromStream($stream)
        } finally {
          if ($stream) { $stream.Dispose() }
        }
      } finally {
        $response.Dispose()
      }
    } catch {}
  }

  return (New-PlaceholderBitmap -Text $FallbackText)
}

function Get-VisibleCategoryEntries {
  $namedCategories = @($script:categories | Where-Object { $_.Name -ne "All" })
  $explicitOther = @($namedCategories | Where-Object { $_.Name -eq "Other" } | Select-Object -First 1)
  $rankedCategories = @($namedCategories | Where-Object { $_.Name -ne "Other" })
  $topCategories = @($rankedCategories | Select-Object -First 5)
  $overflowCategories = @($rankedCategories | Select-Object -Skip 5)
  $otherCount = @($overflowCategories).Count
  if ($explicitOther) {
    $otherCount += [int]$explicitOther[0].Count
  }
  $entries = @()

  foreach ($category in $topCategories) {
    $entries += [pscustomobject]@{
      Key           = [string]$category.Name
      Name          = [string]$category.Name
      Count         = [int]$category.Count
      PrimaryAuthor = [string]$category.PrimaryAuthor
    }
  }

  $entries += [pscustomobject]@{
    Key           = "__OTHERS__"
    Name          = "Others"
    Count         = $otherCount
    PrimaryAuthor = ""
  }

  return $entries
}

function Get-ModelsForCurrentCategory {
  if ($script:selectedCategory -eq "__OTHERS__") {
    $topCategoryNames = @(
      Get-VisibleCategoryEntries |
        Where-Object { $_.Key -ne "__OTHERS__" } |
        ForEach-Object { [string]$_.Name }
    )

    return @(
      $script:models | Where-Object {
        $currentCategory = Get-CategoryNameFromRepoId -RepoId $_.RepoId
        $topCategoryNames -notcontains $currentCategory
      }
    )
  }

  if ($script:selectedCategory -eq "All") {
    return @($script:models)
  }

  return @(
    $script:models | Where-Object {
      (Get-CategoryNameFromRepoId -RepoId $_.RepoId) -eq $script:selectedCategory
    }
  )
}

function ConvertTo-HfRelativePathUrl {
  param([string]$Path)

  $segments = @([string]$Path -split '/')
  return (($segments | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
}

function Format-FileSize {
  param([Nullable[int64]]$SizeBytes)

  if ($null -eq $SizeBytes -or $SizeBytes -lt 0) {
    return "Unknown"
  }

  $size = [double]$SizeBytes
  if ($size -ge 1TB) { return ("{0:N2} TB" -f ($size / 1TB)) }
  if ($size -ge 1GB) { return ("{0:N2} GB" -f ($size / 1GB)) }
  if ($size -ge 1MB) { return ("{0:N2} MB" -f ($size / 1MB)) }
  if ($size -ge 1KB) { return ("{0:N2} KB" -f ($size / 1KB)) }
  return ("{0} B" -f [int64]$size)
}

function ConvertTo-HtmlEncodedText {
  param([string]$Text)

  return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function Convert-MarkdownInlineToHtml {
  param([string]$Text)

  $html = ConvertTo-HtmlEncodedText -Text $Text
  $html = [regex]::Replace($html, '&amp;lt;(https?://[^&]+?)&amp;gt;', '<a href="$1">$1</a>')
  $html = [regex]::Replace($html, '(https?://[^\s<]+)', '<a href="$1">$1</a>')
  $html = [regex]::Replace($html, '\[([^\]]+)\]\((https?://[^)]+)\)', '<a href="$2">$1</a>')
  $html = [regex]::Replace($html, '`([^`]+)`', '<code>$1</code>')
  $html = [regex]::Replace($html, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
  $html = [regex]::Replace($html, '__([^_]+)__', '<strong>$1</strong>')
  $html = [regex]::Replace($html, '(?<!\*)\*([^*]+)\*(?!\*)', '<em>$1</em>')
  $html = [regex]::Replace($html, '(?<!_)_([^_]+)_(?!_)', '<em>$1</em>')
  return $html
}

function Convert-MarkdownToHtml {
  param([string]$Markdown)

  if ([string]::IsNullOrWhiteSpace($Markdown)) {
    return "<html><body><p>No description available.</p></body></html>"
  }

  $normalized = ([string]$Markdown) -replace "`r`n", "`n" -replace "`r", "`n"
  $lines = @($normalized -split "`n")
  $htmlLines = New-Object System.Collections.Generic.List[string]
  $inCodeBlock = $false
  $inList = $false

  foreach ($line in $lines) {
    $trimmed = $line.TrimEnd()

    if ($trimmed -match '^\s*```') {
      if ($inList) {
        [void]$htmlLines.Add("</ul>")
        $inList = $false
      }

      if ($inCodeBlock) {
        [void]$htmlLines.Add("</code></pre>")
        $inCodeBlock = $false
      } else {
        [void]$htmlLines.Add("<pre><code>")
        $inCodeBlock = $true
      }
      continue
    }

    if ($inCodeBlock) {
      [void]$htmlLines.Add((ConvertTo-HtmlEncodedText -Text $trimmed))
      continue
    }

    if ([string]::IsNullOrWhiteSpace($trimmed)) {
      if ($inList) {
        [void]$htmlLines.Add("</ul>")
        $inList = $false
      }
      continue
    }

    if ($trimmed -match '^(#{1,6})\s+(.+)$') {
      if ($inList) {
        [void]$htmlLines.Add("</ul>")
        $inList = $false
      }

      $level = $matches[1].Length
      $content = Convert-MarkdownInlineToHtml -Text $matches[2]
      [void]$htmlLines.Add("<h$level>$content</h$level>")
      continue
    }

    if ($trimmed -match '^[-*]\s+(.+)$') {
      if (-not $inList) {
        [void]$htmlLines.Add("<ul>")
        $inList = $true
      }

      $content = Convert-MarkdownInlineToHtml -Text $matches[1]
      [void]$htmlLines.Add("<li>$content</li>")
      continue
    }

    if ($trimmed -match '^\d+\.\s+(.+)$') {
      if (-not $inList) {
        [void]$htmlLines.Add("<ul>")
        $inList = $true
      }

      $content = Convert-MarkdownInlineToHtml -Text $matches[1]
      [void]$htmlLines.Add("<li>$content</li>")
      continue
    }

    if ($trimmed -match '^>\s?(.+)$') {
      if ($inList) {
        [void]$htmlLines.Add("</ul>")
        $inList = $false
      }

      $content = Convert-MarkdownInlineToHtml -Text $matches[1]
      [void]$htmlLines.Add("<blockquote>$content</blockquote>")
      continue
    }

    if ($inList) {
      [void]$htmlLines.Add("</ul>")
      $inList = $false
    }

    $paragraph = Convert-MarkdownInlineToHtml -Text $trimmed
    [void]$htmlLines.Add("<p>$paragraph</p>")
  }

  if ($inList) {
    [void]$htmlLines.Add("</ul>")
  }
  if ($inCodeBlock) {
    [void]$htmlLines.Add("</code></pre>")
  }

  $body = ($htmlLines -join "`n")
  return @"
<html>
<head>
  <meta http-equiv="X-UA-Compatible" content="IE=edge" />
  <style>
    body { font-family: "Segoe UI", sans-serif; font-size: 13px; line-height: 1.45; color: #243447; background: #ffffff; margin: 12px; }
    h1, h2, h3, h4, h5, h6 { color: #13293d; margin: 16px 0 8px; }
    p { margin: 0 0 10px; }
    ul { margin: 0 0 10px 20px; padding: 0; }
    li { margin: 0 0 4px; }
    code { font-family: Consolas, monospace; background: #f2f5f8; padding: 1px 4px; border-radius: 3px; }
    pre { background: #f6f8fa; padding: 10px; border-radius: 6px; overflow-x: auto; }
    blockquote { margin: 0 0 10px; padding: 8px 12px; border-left: 4px solid #d0d7de; background: #f6f8fa; }
    a { color: #0b6bcb; text-decoration: none; }
  </style>
</head>
<body>
$body
</body>
</html>
"@
}

function Convert-MarkdownToDisplayText {
  param([string]$Markdown)

  if ([string]::IsNullOrWhiteSpace($Markdown)) {
    return "No description available."
  }

  $text = ([string]$Markdown) -replace "`r`n", "`n" -replace "`r", "`n"
  $text = [regex]::Replace($text, '^\s*```.*$', '', [System.Text.RegularExpressions.RegexOptions]::Multiline)
  $text = [regex]::Replace($text, '^\s{0,3}#{1,6}\s*', '', [System.Text.RegularExpressions.RegexOptions]::Multiline)
  $text = [regex]::Replace($text, '^\s*[-*]\s+', '- ', [System.Text.RegularExpressions.RegexOptions]::Multiline)
  $text = [regex]::Replace($text, '\[([^\]]+)\]\((https?://[^)]+)\)', '$1 <$2>')
  $text = [regex]::Replace($text, '<(https?://[^>]+)>', '$1')
  $text = [regex]::Replace($text, '\*\*([^*]+)\*\*', '$1')
  $text = [regex]::Replace($text, '__([^_]+)__', '$1')
  $text = [regex]::Replace($text, '`([^`]+)`', '$1')
  $text = [regex]::Replace($text, '(?<!\*)\*([^*]+)\*(?!\*)', '$1')
  $text = [regex]::Replace($text, '(?<!_)_([^_]+)_(?!_)', '$1')
  $text = [regex]::Replace($text, "`n{3,}", "`n`n")
  return $text.Trim()
}

function Get-HfModelDescriptionText {
  param([object]$Response)

  if (-not $Response) {
    return "No description available."
  }

  $candidates = @(
    [string]$Response.description,
    [string]$Response.cardData.summary,
    [string]$Response.cardData.description,
    [string]$Response.cardData.model_description
  )

  foreach ($candidate in $candidates) {
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
      return $candidate.Trim()
    }
  }

  return "No description available."
}

function Get-HfModelMetadataValue {
  param(
    [object]$Response,
    [string[]]$PropertyNames
  )

  if (-not $Response -or -not $PropertyNames) {
    return ""
  }

  foreach ($propertyName in $PropertyNames) {
    $value = ""

    if ($Response.PSObject.Properties.Name -contains $propertyName) {
      $value = [string]$Response.$propertyName
    } elseif ($Response.cardData -and $Response.cardData.PSObject.Properties.Name -contains $propertyName) {
      $rawValue = $Response.cardData.$propertyName
      if ($rawValue -is [System.Array]) {
        $value = ((@($rawValue) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ", ")
      } else {
        $value = [string]$rawValue
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value.Trim()
    }
  }

  return ""
}

function Get-HfLanguageName {
  param([string]$LanguageCode)

  $code = ([string]$LanguageCode).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($code)) {
    return ""
  }

  $resources = Get-HfTextResources
  if ($resources -and $resources.languages) {
    $languageEntry = $resources.languages.PSObject.Properties[$code]
    if ($languageEntry -and $languageEntry.Value) {
      $localizedName = $languageEntry.Value.PSObject.Properties[$script:uiLanguage]
      if ($localizedName -and -not [string]::IsNullOrWhiteSpace([string]$localizedName.Value)) {
        return [string]$localizedName.Value
      }
    }

    foreach ($entry in $resources.languages.PSObject.Properties) {
      if (-not $entry.Value) {
        continue
      }

      $entryEnglish = [string]$entry.Value.en
      $entryJapanese = [string]$entry.Value.ja
      if (
        $code -eq $entryEnglish.Trim().ToLowerInvariant() -or
        $code -eq $entryJapanese.Trim().ToLowerInvariant()
      ) {
        $localizedName = $entry.Value.PSObject.Properties[$script:uiLanguage]
        if ($localizedName -and -not [string]::IsNullOrWhiteSpace([string]$localizedName.Value)) {
          return [string]$localizedName.Value
        }
      }
    }
  }

  try {
    $culture = [System.Globalization.CultureInfo]::GetCultures([System.Globalization.CultureTypes]::AllCultures) |
      Where-Object {
        $_.TwoLetterISOLanguageName -eq $code -or
        $_.ThreeLetterISOLanguageName -eq $code -or
        $_.ThreeLetterWindowsLanguageName.ToLowerInvariant() -eq $code
      } |
      Select-Object -First 1

    if ($culture) {
      if ($script:uiLanguage -eq "ja") {
        return [string]$culture.NativeName
      }
      return [string]$culture.EnglishName
    }
  } catch {}

  return [string]$LanguageCode
}

function Get-HfLanguageDisplayText {
  param([string]$LanguageValue)

  $rawValue = [string]$LanguageValue
  if ([string]::IsNullOrWhiteSpace($rawValue)) {
    return ""
  }

  $items = @($rawValue -split '\s*[,;/|]\s*' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($items.Count -eq 0) {
    return ""
  }

  $resolved = foreach ($item in $items) {
    $trimmed = ([string]$item).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
      continue
    }

    if ($trimmed -match '^[a-zA-Z]{2,3}$') {
      Get-HfLanguageName -LanguageCode $trimmed
      continue
    }

    if ($trimmed -match '^[a-zA-Z]{2,3}[-_][a-zA-Z]{2,4}$') {
      $primaryCode = ($trimmed -split '[-_]')[0]
      Get-HfLanguageName -LanguageCode $primaryCode
      continue
    }

    $trimmed
  }

  return ((@($resolved) | Select-Object -Unique) -join ", ")
}

function Remove-MarkdownFrontMatter {
  param([string]$Markdown)

  $text = [string]$Markdown
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $text
  }

  $normalized = $text -replace "`r`n", "`n" -replace "`r", "`n"
  if ($normalized -notmatch '^\s*---\n') {
    return $text
  }

  $withoutFrontMatter = [regex]::Replace($normalized, '^\s*---\n.*?\n---\n?', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
  return $withoutFrontMatter -replace "`n", "`r`n"
}

function Get-HfModelCardText {
  param(
    [string]$RepoId,
    [string]$Revision,
    [string]$Token,
    [object]$Response
  )

  if (-not [string]::IsNullOrWhiteSpace($RepoId) -and -not [string]::IsNullOrWhiteSpace($Revision)) {
    $readmeCandidates = @("README.md", "Readme.md", "readme.md")

    foreach ($readmePath in $readmeCandidates) {
      try {
        $readmeUrl = "https://huggingface.co/$RepoId/resolve/$Revision/$readmePath"
        $readmeResponse = Invoke-HfHttpRequest -Uri $readmeUrl -Token $Token
        $readmeText = [string]$readmeResponse.Content
        if (-not [string]::IsNullOrWhiteSpace($readmeText)) {
          return (Remove-MarkdownFrontMatter -Markdown $readmeText).Trim()
        }
      } catch {}
    }
  }

  return (Get-HfModelDescriptionText -Response $Response)
}

function Get-PipelineTagDescription {
  param([string]$PipelineTag)

  $value = ([string]$PipelineTag).Trim().ToLowerInvariant()
  $resources = Get-HfTextResources
  if ($resources -and $resources.pipelines) {
    $pipelineEntry = $resources.pipelines.PSObject.Properties[$value]
    if ($pipelineEntry -and $pipelineEntry.Value -and $pipelineEntry.Value.description) {
      $description = $pipelineEntry.Value.description.PSObject.Properties[$script:uiLanguage]
      if ($description -and -not [string]::IsNullOrWhiteSpace([string]$description.Value)) {
        return [string]$description.Value
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace($PipelineTag) -or $value -eq "unknown") {
    return $(if ($script:uiLanguage -eq "ja") { "パイプライン情報はモデルのメタデータに設定されていません。" } else { "Pipeline tag is not provided in the model metadata." })
  }

  return $(if ($script:uiLanguage -eq "ja") { "Pipeline tag '$PipelineTag': Hugging Face 上での主な用途カテゴリを示します。" } else { "Pipeline tag '$PipelineTag': this indicates the main task category the model is published for on Hugging Face." })
}

function Get-LicenseDescription {
  param(
    [string]$LicenseId,
    [string]$LicenseName
  )

  $id = ([string]$LicenseId).Trim().ToLowerInvariant()
  $name = if ([string]::IsNullOrWhiteSpace($LicenseName)) { [string]$LicenseId } else { [string]$LicenseName }
  $isJapanese = ($script:uiLanguage -eq "ja")
  $resources = Get-HfTextResources
  if ($resources -and $resources.licenses) {
    $licenseEntry = $resources.licenses.PSObject.Properties[$id]
    if ($licenseEntry -and $licenseEntry.Value -and $licenseEntry.Value.description) {
      $description = $licenseEntry.Value.description.PSObject.Properties[$script:uiLanguage]
      if ($description -and -not [string]::IsNullOrWhiteSpace([string]$description.Value)) {
        return [string]$description.Value
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace($id) -or $id -eq "unknown") {
    return $(if ($isJapanese) { "ライセンス情報がメタデータに設定されていません。" } else { "License information is not provided in the metadata." })
  }

  if ($id -eq "other") {
    return $(if ($isJapanese) { "その他のライセンスです。モデルページや LICENSE ファイルで個別条件を確認してください。" } else { "This repo uses another license. Review the model page or LICENSE file for the exact terms." })
  }

  return $(if ($isJapanese) { "正式名称: $name。詳細な利用条件、再配布条件、商用利用可否はモデルページのライセンス本文を確認してください。" } else { "Official name: $name. Review the full license text on the model page for exact usage, redistribution, and commercial-use terms." })
}

function Get-HfOfficialLicenseName {
  param([string]$LicenseId)

  $id = ([string]$LicenseId).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($id)) {
    return ""
  }

  $resources = Get-HfTextResources
  if ($resources -and $resources.licenses) {
    $licenseEntry = $resources.licenses.PSObject.Properties[$id]
    if ($licenseEntry -and $licenseEntry.Value) {
      $licenseName = $licenseEntry.Value.PSObject.Properties["name"]
      if ($licenseName -and -not [string]::IsNullOrWhiteSpace([string]$licenseName.Value)) {
        return [string]$licenseName.Value
      }
    }
  }

  return [string]$LicenseId
}

function Open-InstallRepo {
  param(
    [string]$RepoId,
    [bool]$PushCurrent = $false
  )

  if ([string]::IsNullOrWhiteSpace($RepoId)) {
    return
  }

  if ($PushCurrent -and -not [string]::IsNullOrWhiteSpace($script:selectedRepoId)) {
    $script:installRepoHistory += [string]$script:selectedRepoId
  }

  $script:selectedRepoId = [string]$RepoId
  $script:currentView = "install"
  $modelName = Get-ModelNameFromRepoId -RepoId $script:selectedRepoId
  $titleLabel.Text = $modelName
  $titleLabel.Size = New-Object System.Drawing.Size(740, 34)
  $titleMetaPanel.Visible = $true
  Set-TopContentOffset -ShowTitleMeta:$true
  $baseModelLinkLabel.Text = "Base: Unknown"
  $baseModelLinkLabel.Tag = ""
  $baseModelLinkLabel.Visible = $true
  $pipelineInfoLabel.Text = "Pipeline: Unknown"
  $pipelineInfoLabel.Visible = $true
  $languageInfoLabel.Text = "Language: Unknown"
  $languageInfoLabel.Visible = $true
  $licenseInfoLabel.Text = "License: Unknown"
  $licenseInfoLabel.Visible = $true
  $subtitleLabel.Visible = $false
  $globalBackButton.Visible = $true
  $globalActionButton.Visible = $true
  $globalActionButton.Text = Get-UiText "FetchFiles"
  $filesListView.Items.Clear()
  $descriptionBrowser.Text = (Convert-MarkdownToDisplayText -Markdown "")
  $script:repoFiles = @()
  $saveTextBox.Text = ""
  $progressBar.Value = 0
  $downloadButton.Enabled = $false
  $installStatusLabel.Text = Get-UiText "LoadingFiles"
  $listPanel.Visible = $false
  $installPanel.Visible = $true
  Apply-Language
  Load-RepoFiles
}

function Get-HfFileSizeBytes {
  param(
    [string]$DownloadUrl,
    [string]$Token
  )

  if ([string]::IsNullOrWhiteSpace($DownloadUrl)) {
    return $null
  }

  try {
    $request = [System.Net.HttpWebRequest]::Create($DownloadUrl)
    $request.Method = "HEAD"
    $request.AllowAutoRedirect = $true
    $request.UserAgent = "HF-GGUF-Downloader/0.3"
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
      $request.Headers["Authorization"] = "Bearer $Token"
    }

    $response = $null
    try {
      $response = [System.Net.HttpWebResponse]$request.GetResponse()
      if ($response.ContentLength -gt 0) {
        return [int64]$response.ContentLength
      }
    } finally {
      if ($response) { $response.Dispose() }
    }
  } catch {}

  return $null
}

function Get-HfModelFiles {
  param(
    [string]$RepoId,
    [string]$Token
  )

  if ([string]::IsNullOrWhiteSpace($RepoId)) {
    throw "repo_id is required."
  }

  $repoId = $RepoId.Trim()
  $uri = "https://huggingface.co/api/models/$repoId"
  $response = Invoke-HfJsonRequest -Uri $uri -Token $Token

  if (-not $response -or -not $response.siblings) {
    return [pscustomobject]@{
      Description = Get-HfModelCardText -RepoId $repoId -Revision "main" -Token $Token -Response $response
      License     = Get-HfModelMetadataValue -Response $response -PropertyNames @("license")
      BaseModel   = Get-HfModelMetadataValue -Response $response -PropertyNames @("base_model", "baseModel")
      PipelineTag = Get-HfModelMetadataValue -Response $response -PropertyNames @("pipeline_tag", "pipelineTag")
      Language    = Get-HfModelMetadataValue -Response $response -PropertyNames @("language", "languages")
      Files       = @()
    }
  }

  $revision = if (-not [string]::IsNullOrWhiteSpace([string]$response.sha)) {
    [string]$response.sha
  } else {
    "main"
  }

  $files = @(
    $response.siblings |
      Where-Object { $_.rfilename -like "*.gguf" } |
      Sort-Object rfilename |
      ForEach-Object {
        $relativePath = [string]$_.rfilename
        $downloadUrl = "https://huggingface.co/$repoId/resolve/$revision/$(ConvertTo-HfRelativePathUrl -Path $relativePath)"
        $sizeBytes = $null
        if ($null -ne $_.size) {
          $parsedSize = 0L
          if ([int64]::TryParse([string]$_.size, [ref]$parsedSize)) {
            $sizeBytes = $parsedSize
          }
        } elseif ($_.lfs -and $null -ne $_.lfs.size) {
          $parsedSize = 0L
          if ([int64]::TryParse([string]$_.lfs.size, [ref]$parsedSize)) {
            $sizeBytes = $parsedSize
          }
        }
        if ($null -eq $sizeBytes -or $sizeBytes -le 0) {
          $sizeBytes = Get-HfFileSizeBytes -DownloadUrl $downloadUrl -Token $Token
        }

        [pscustomobject]@{
          FileName    = $relativePath
          SizeBytes   = $sizeBytes
          SizeLabel   = Format-FileSize -SizeBytes $sizeBytes
          DownloadUrl = $downloadUrl
        }
      }
  )

  return [pscustomobject]@{
    Description = Get-HfModelCardText -RepoId $repoId -Revision $revision -Token $Token -Response $response
    License     = Get-HfModelMetadataValue -Response $response -PropertyNames @("license")
    BaseModel   = Get-HfModelMetadataValue -Response $response -PropertyNames @("base_model", "baseModel")
    PipelineTag = Get-HfModelMetadataValue -Response $response -PropertyNames @("pipeline_tag", "pipelineTag")
    Language    = Get-HfModelMetadataValue -Response $response -PropertyNames @("language", "languages")
    Files       = $files
  }
}

function Start-HfFileDownload {
  param(
    [string]$DownloadUrl,
    [string]$FileName,
    [string]$DestinationPath,
    [string]$Token,
    [System.Windows.Forms.ProgressBar]$ProgressBar,
    [System.Windows.Forms.Label]$StatusLabel
  )

  if ([string]::IsNullOrWhiteSpace($DownloadUrl)) {
    throw "Download URL is required."
  }
  if ([string]::IsNullOrWhiteSpace($FileName)) {
    throw "Select a .gguf file first."
  }
  if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
    throw "Select a destination path."
  }

  $downloadUrl = $DownloadUrl.Trim()
  $fileName = $FileName.Trim()
  $destinationPath = $DestinationPath.Trim()
  $temporaryPath = "$destinationPath.downloading"
  $parentDir = Split-Path -Parent $destinationPath

  if ([string]::IsNullOrWhiteSpace($parentDir)) {
    throw "Destination folder is invalid."
  }
  if (-not (Test-Path -LiteralPath $parentDir -PathType Container)) {
    New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
  }

  $request = [System.Net.HttpWebRequest]::Create($downloadUrl)
  $request.Method = "GET"
  $request.AllowAutoRedirect = $true
  $request.UserAgent = "HF-GGUF-Downloader/0.2"
  if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $request.Headers["Authorization"] = "Bearer $Token"
  }

  $response = $null
  $responseStream = $null
  $fileStream = $null

  try {
    $response = [System.Net.HttpWebResponse]$request.GetResponse()
    $responseStream = $response.GetResponseStream()
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
      Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
    $fileStream = [System.IO.File]::Open($temporaryPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

    $buffer = New-Object byte[] (1024 * 1024)
    $totalRead = 0L
    $contentLength = [int64]$response.ContentLength
    $ProgressBar.Style = if ($contentLength -gt 0) { [System.Windows.Forms.ProgressBarStyle]::Continuous } else { [System.Windows.Forms.ProgressBarStyle]::Marquee }
    $ProgressBar.Value = 0
    $StatusLabel.Text = ("Downloading to temp file...`r`n{0}" -f ([System.IO.Path]::GetFileName($temporaryPath)))

    while (($read = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
      $fileStream.Write($buffer, 0, $read)
      $totalRead += $read

      if ($contentLength -gt 0) {
        $percent = [Math]::Min(100, [int](($totalRead * 100L) / $contentLength))
        $ProgressBar.Value = $percent
        $StatusLabel.Text = ("Downloading {0}`r`n{1}% ({2:N2} / {3:N2} MB)" -f ([System.IO.Path]::GetFileName($temporaryPath)), $percent, ($totalRead / 1MB), ($contentLength / 1MB))
      } else {
        $StatusLabel.Text = ("Downloading {0}`r`n{1:N2} MB" -f ([System.IO.Path]::GetFileName($temporaryPath), ($totalRead / 1MB)))
      }

      [System.Windows.Forms.Application]::DoEvents()
    }

    $fileStream.Dispose()
    $fileStream = $null
    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
      Remove-Item -LiteralPath $destinationPath -Force -ErrorAction SilentlyContinue
    }
    Move-Item -LiteralPath $temporaryPath -Destination $destinationPath -Force
  } catch {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
      Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
    throw
  } finally {
    if ($fileStream) { $fileStream.Dispose() }
    if ($responseStream) { $responseStream.Dispose() }
    if ($response) { $response.Dispose() }
  }

  $ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
  $ProgressBar.Value = 100
  $StatusLabel.Text = ("Download complete`r`n{0}" -f ([System.IO.Path]::GetFileName($destinationPath)))
}

$script:models = @()
$script:categories = @()
$script:repoFiles = @()
$script:selectedCategory = "All"
$script:selectedRepoId = ""
$script:installRepoHistory = @()
$script:modelSortMode = "Trend"
$script:uiLanguage = "ja"
$script:currentView = "category"
$script:hfTextResources = $null
$defaultModelDir = Get-ConfiguredModelDir

function Get-UiText {
  param([string]$Key)

  $resources = Get-HfTextResources
  if ($resources -and $resources.ui) {
    $entry = $resources.ui.PSObject.Properties[$Key]
    if ($entry -and $entry.Value) {
      $localized = $entry.Value.PSObject.Properties[$script:uiLanguage]
      if ($localized -and -not [string]::IsNullOrWhiteSpace([string]$localized.Value)) {
        return [string]$localized.Value
      }
      $fallback = $entry.Value.PSObject.Properties["en"]
      if ($fallback -and -not [string]::IsNullOrWhiteSpace([string]$fallback.Value)) {
        return [string]$fallback.Value
      }
    }
  }
  return $Key
}

function Set-ListViewColumnText {
  param(
    [System.Windows.Forms.ListView]$ListView,
    [int]$Index,
    [string]$Text
  )

  if ($ListView -and $ListView.Columns.Count -gt $Index) {
    $ListView.Columns[$Index].Text = $Text
  }
}

function Set-TopContentOffset {
  param([bool]$ShowTitleMeta)

  $defaultTopY = 76
  $topY = if ($ShowTitleMeta) { 100 } else { $defaultTopY }
  $panelHeight = 584 - $topY

  $categoryPanel.Location = New-Object System.Drawing.Point(18, $topY)
  $categoryPanel.Size = New-Object System.Drawing.Size(770, $panelHeight)
  $listPanel.Location = New-Object System.Drawing.Point(18, $topY)
  $listPanel.Size = New-Object System.Drawing.Size(770, $panelHeight)
  $installPanel.Location = New-Object System.Drawing.Point(18, $topY)
  $installPanel.Size = New-Object System.Drawing.Size(770, $panelHeight)
}

function Update-TitleMetaLayout {
  $safeRight = $titleMetaPanel.Right
  if ($globalBackButton) {
    $safeRight = [Math]::Min($safeRight, ($globalBackButton.Left - 10))
  }

  $availableWidth = [Math]::Max(320, ($safeRight - $titleMetaPanel.Left))
  $script:titleMetaTextWidth = $availableWidth

  $baseModelLinkLabel.Location = New-Object System.Drawing.Point(0, 0)
  $baseModelLinkLabel.Size = New-Object System.Drawing.Size($availableWidth, 16)
  $pipelineInfoLabel.Location = New-Object System.Drawing.Point(0, 16)
  $pipelineInfoLabel.Size = New-Object System.Drawing.Size($availableWidth, 16)
  $languageInfoLabel.Location = New-Object System.Drawing.Point(0, 32)
  $languageInfoLabel.Size = New-Object System.Drawing.Size($availableWidth, 32)
  $languageInfoLabel.AutoEllipsis = $false
  $licenseInfoLabel.Location = New-Object System.Drawing.Point(0, 64)
  $licenseInfoLabel.Size = New-Object System.Drawing.Size($availableWidth, 16)

  $titleMetaPanel.Size = New-Object System.Drawing.Size($availableWidth, 80)
}

function Format-WrappedMetaListText {
  param(
    [string]$Prefix,
    [string]$Value,
    [int]$MaxWidth,
    [System.Drawing.Font]$Font
  )

  $prefixText = ("{0}: " -f [string]$Prefix)
  if ([string]::IsNullOrWhiteSpace([string]$Value)) {
    return $prefixText.TrimEnd()
  }

  $items = @([string]$Value -split '\s*,\s*' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($items.Count -le 1) {
    return ("{0}{1}" -f $prefixText, [string]$Value)
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $currentLine = $prefixText

  foreach ($item in $items) {
    $piece = [string]$item
    $candidate = if ($currentLine -eq $prefixText) {
      ("{0}{1}" -f $currentLine, $piece)
    } else {
      ("{0}, {1}" -f $currentLine, $piece)
    }

    $candidateWidth = [System.Windows.Forms.TextRenderer]::MeasureText($candidate, $Font).Width
    if ($candidateWidth -le $MaxWidth -or $currentLine -eq $prefixText) {
      $currentLine = $candidate
    } else {
      [void]$lines.Add($currentLine)
      $currentLine = $piece
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($currentLine)) {
    [void]$lines.Add($currentLine)
  }

  return ($lines -join "`r`n")
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "HF GGUF Downloader"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(820, 620)
$form.MinimumSize = New-Object System.Drawing.Size(820, 620)
$form.MaximumSize = New-Object System.Drawing.Size(820, 620)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = Get-UiText "AppTitle"
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$titleLabel.Location = New-Object System.Drawing.Point(20, 16)
$titleLabel.Size = New-Object System.Drawing.Size(400, 34)
$form.Controls.Add($titleLabel)

$languageLabel = New-Object System.Windows.Forms.Label
$languageLabel.Location = New-Object System.Drawing.Point(560, 20)
$languageLabel.Size = New-Object System.Drawing.Size(72, 20)
$form.Controls.Add($languageLabel)

$languageComboBox = New-Object System.Windows.Forms.ComboBox
$languageComboBox.Location = New-Object System.Drawing.Point(636, 16)
$languageComboBox.Size = New-Object System.Drawing.Size(124, 28)
$languageComboBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$languageComboBox.Items.Add("日本語")
[void]$languageComboBox.Items.Add("English")
$languageComboBox.SelectedIndex = 0
$form.Controls.Add($languageComboBox)

$globalBackButton = New-Object System.Windows.Forms.Button
$globalBackButton.Text = "Back"
$globalBackButton.Location = New-Object System.Drawing.Point(454, 84)
$globalBackButton.Size = New-Object System.Drawing.Size(150, 30)
$globalBackButton.Visible = $false
$form.Controls.Add($globalBackButton)

$globalActionButton = New-Object System.Windows.Forms.Button
$globalActionButton.Text = "Refresh"
$globalActionButton.Location = New-Object System.Drawing.Point(610, 84)
$globalActionButton.Size = New-Object System.Drawing.Size(150, 30)
$form.Controls.Add($globalActionButton)

$titleMetaPanel = New-Object System.Windows.Forms.Panel
$titleMetaPanel.Location = New-Object System.Drawing.Point(22, 50)
$titleMetaPanel.Size = New-Object System.Drawing.Size(520, 64)
$titleMetaPanel.Visible = $false
$form.Controls.Add($titleMetaPanel)

$titleMetaToolTip = New-Object System.Windows.Forms.ToolTip
$titleMetaToolTip.AutoPopDelay = 10000
$titleMetaToolTip.InitialDelay = 300
$titleMetaToolTip.ReshowDelay = 150

$baseModelLinkLabel = New-Object System.Windows.Forms.LinkLabel
$baseModelLinkLabel.Text = "Base: Unknown"
$baseModelLinkLabel.Location = New-Object System.Drawing.Point(0, 0)
$baseModelLinkLabel.Size = New-Object System.Drawing.Size(520, 16)
$baseModelLinkLabel.LinkBehavior = [System.Windows.Forms.LinkBehavior]::NeverUnderline
$baseModelLinkLabel.Visible = $false
$titleMetaPanel.Controls.Add($baseModelLinkLabel)

$pipelineInfoLabel = New-Object System.Windows.Forms.Label
$pipelineInfoLabel.Text = "Pipeline: Unknown"
$pipelineInfoLabel.Location = New-Object System.Drawing.Point(0, 16)
$pipelineInfoLabel.Size = New-Object System.Drawing.Size(520, 16)
$pipelineInfoLabel.Visible = $false
$titleMetaPanel.Controls.Add($pipelineInfoLabel)

$languageInfoLabel = New-Object System.Windows.Forms.Label
$languageInfoLabel.Text = "Language: Unknown"
$languageInfoLabel.Location = New-Object System.Drawing.Point(0, 32)
$languageInfoLabel.Size = New-Object System.Drawing.Size(520, 32)
$languageInfoLabel.Visible = $false
$titleMetaPanel.Controls.Add($languageInfoLabel)

$licenseInfoLabel = New-Object System.Windows.Forms.Label
$licenseInfoLabel.Text = "License: Unknown"
$licenseInfoLabel.Location = New-Object System.Drawing.Point(0, 64)
$licenseInfoLabel.Size = New-Object System.Drawing.Size(520, 16)
$licenseInfoLabel.Visible = $false
$titleMetaPanel.Controls.Add($licenseInfoLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "Browse llama.cpp models, pick one, then install a .gguf file."
$subtitleLabel.Location = New-Object System.Drawing.Point(22, 50)
$subtitleLabel.Size = New-Object System.Drawing.Size(720, 20)
$form.Controls.Add($subtitleLabel)

$categoryPanel = New-Object System.Windows.Forms.Panel
$categoryPanel.Location = New-Object System.Drawing.Point(18, 124)
$categoryPanel.Size = New-Object System.Drawing.Size(770, 460)
$form.Controls.Add($categoryPanel)

$listPanel = New-Object System.Windows.Forms.Panel
$listPanel.Location = New-Object System.Drawing.Point(18, 124)
$listPanel.Size = New-Object System.Drawing.Size(770, 460)
$listPanel.Visible = $false
$form.Controls.Add($listPanel)

$installPanel = New-Object System.Windows.Forms.Panel
$installPanel.Location = New-Object System.Drawing.Point(18, 124)
$installPanel.Size = New-Object System.Drawing.Size(770, 460)
$installPanel.Visible = $false
$form.Controls.Add($installPanel)

$categoryTitleLabel = New-Object System.Windows.Forms.Label
$categoryTitleLabel.Text = "Select category"
$categoryTitleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$categoryTitleLabel.Location = New-Object System.Drawing.Point(4, 0)
$categoryTitleLabel.Size = New-Object System.Drawing.Size(220, 26)
$categoryPanel.Controls.Add($categoryTitleLabel)

$categoryHintLabel = New-Object System.Windows.Forms.Label
$categoryHintLabel.Text = "Choose a family like Gemma or Qwen before opening the model list."
$categoryHintLabel.Location = New-Object System.Drawing.Point(4, 30)
$categoryHintLabel.Size = New-Object System.Drawing.Size(560, 20)
$categoryPanel.Controls.Add($categoryHintLabel)

$categoryCardsHost = New-Object System.Windows.Forms.Panel
$categoryCardsHost.Location = New-Object System.Drawing.Point(4, 64)
$categoryCardsHost.Size = New-Object System.Drawing.Size(756, 360)
$categoryPanel.Controls.Add($categoryCardsHost)

$categoryStatusLabel = New-Object System.Windows.Forms.Label
$categoryStatusLabel.Text = "Idle"
$categoryStatusLabel.Location = New-Object System.Drawing.Point(4, 436)
$categoryStatusLabel.Size = New-Object System.Drawing.Size(500, 20)
$categoryPanel.Controls.Add($categoryStatusLabel)

$script:categoryCardButtons = @()

function New-CategoryCard {
  param(
    [int]$X,
    [int]$Y,
    [int]$Width,
    [int]$Height
  )

  $panel = New-Object System.Windows.Forms.Panel
  $panel.Location = New-Object System.Drawing.Point($X, $Y)
  $panel.Size = New-Object System.Drawing.Size($Width, $Height)
  $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $panel.BackColor = [System.Drawing.Color]::White
  $categoryCardsHost.Controls.Add($panel)

  $button = New-Object System.Windows.Forms.Button
  $button.Location = New-Object System.Drawing.Point(0, 0)
  $button.Size = $panel.Size
  $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $button.FlatAppearance.BorderSize = 0
  $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(232, 238, 245)
  $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(240, 244, 248)
  $button.BackColor = [System.Drawing.Color]::White
  $button.UseVisualStyleBackColor = $false
  $button.Tag = $null
  $panel.Controls.Add($button)

  $picture = New-Object System.Windows.Forms.PictureBox
  $picture.Location = New-Object System.Drawing.Point(16, 16)
  $picture.Size = New-Object System.Drawing.Size(72, 72)
  $picture.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
  $picture.BackColor = [System.Drawing.Color]::Transparent
  $button.Controls.Add($picture)

  $nameLabel = New-Object System.Windows.Forms.Label
  $nameLabel.Location = New-Object System.Drawing.Point(104, 18)
  $nameLabel.Size = New-Object System.Drawing.Size(($Width - 120), 30)
  $nameLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
  $nameLabel.BackColor = [System.Drawing.Color]::Transparent
  $button.Controls.Add($nameLabel)

  $metaLabel = New-Object System.Windows.Forms.Label
  $metaLabel.Location = New-Object System.Drawing.Point(104, 54)
  $metaLabel.Size = New-Object System.Drawing.Size(($Width - 120), 36)
  $metaLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
  $metaLabel.BackColor = [System.Drawing.Color]::Transparent
  $button.Controls.Add($metaLabel)

  return [pscustomobject]@{
    Panel     = $panel
    Button    = $button
    Picture   = $picture
    NameLabel = $nameLabel
    MetaLabel = $metaLabel
  }
}

$script:categoryCardButtons += New-CategoryCard -X 0   -Y 0   -Width 360 -Height 172
$script:categoryCardButtons += New-CategoryCard -X 0   -Y 188 -Width 360 -Height 172
$script:categoryCardButtons += New-CategoryCard -X 384 -Y 0   -Width 372 -Height 96
$script:categoryCardButtons += New-CategoryCard -X 384 -Y 108 -Width 372 -Height 96
$script:categoryCardButtons += New-CategoryCard -X 384 -Y 216 -Width 372 -Height 96

$othersButton = New-Object System.Windows.Forms.Button
$othersButton.Location = New-Object System.Drawing.Point(384, 320)
$othersButton.Size = New-Object System.Drawing.Size(372, 36)
$othersButton.Text = "Others"
$othersButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$othersButton.FlatAppearance.BorderSize = 0
$othersButton.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(232, 238, 245)
$othersButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(240, 244, 248)
$othersButton.BackColor = [System.Drawing.Color]::White
$othersButton.UseVisualStyleBackColor = $false
$othersButton.Visible = $false
$categoryCardsHost.Controls.Add($othersButton)

$listInfoLabel = New-Object System.Windows.Forms.Label
$listInfoLabel.Text = "Model list"
$listInfoLabel.Location = New-Object System.Drawing.Point(4, 4)
$listInfoLabel.Size = New-Object System.Drawing.Size(360, 20)
$listPanel.Controls.Add($listInfoLabel)

$sortLabel = New-Object System.Windows.Forms.Label
$sortLabel.Text = "Sort by"
$sortLabel.Location = New-Object System.Drawing.Point(4, 36)
$sortLabel.Size = New-Object System.Drawing.Size(60, 20)
$listPanel.Controls.Add($sortLabel)

$sortComboBox = New-Object System.Windows.Forms.ComboBox
$sortComboBox.Location = New-Object System.Drawing.Point(68, 32)
$sortComboBox.Size = New-Object System.Drawing.Size(220, 28)
$sortComboBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$sortComboBox.Items.Add("Downloads")
[void]$sortComboBox.Items.Add("Last updated")
[void]$sortComboBox.Items.Add("Trend")
$sortComboBox.SelectedIndex = 2
$listPanel.Controls.Add($sortComboBox)

$modelsListView = New-Object System.Windows.Forms.ListView
$modelsListView.Location = New-Object System.Drawing.Point(4, 68)
$modelsListView.Size = New-Object System.Drawing.Size(756, 372)
$modelsListView.View = [System.Windows.Forms.View]::Details
$modelsListView.FullRowSelect = $true
$modelsListView.MultiSelect = $false
$modelsListView.GridLines = $true
$modelsListView.HideSelection = $false
[void]$modelsListView.Columns.Add("Model", 300)
[void]$modelsListView.Columns.Add("Author", 150)
[void]$modelsListView.Columns.Add("Published", 120)
[void]$modelsListView.Columns.Add("Downloads", 170)
$listPanel.Controls.Add($modelsListView)

$listStatusLabel = New-Object System.Windows.Forms.Label
$listStatusLabel.Text = "Idle"
$listStatusLabel.Location = New-Object System.Drawing.Point(4, 450)
$listStatusLabel.Size = New-Object System.Drawing.Size(500, 20)
$listPanel.Controls.Add($listStatusLabel)

$openInstallButton = New-Object System.Windows.Forms.Button
$openInstallButton.Text = "Open install"
$openInstallButton.Location = New-Object System.Drawing.Point(610, 444)
$openInstallButton.Size = New-Object System.Drawing.Size(150, 34)
$openInstallButton.Enabled = $false
$listPanel.Controls.Add($openInstallButton)

$filesLabel = New-Object System.Windows.Forms.Label
$filesLabel.Text = "Model card"
$filesLabel.Location = New-Object System.Drawing.Point(4, 44)
$filesLabel.Size = New-Object System.Drawing.Size(160, 20)
$installPanel.Controls.Add($filesLabel)

$descriptionBrowser = New-Object System.Windows.Forms.RichTextBox
$descriptionBrowser.Location = New-Object System.Drawing.Point(4, 68)
$descriptionBrowser.Size = New-Object System.Drawing.Size(448, 360)
$descriptionBrowser.ReadOnly = $true
$descriptionBrowser.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$descriptionBrowser.BackColor = [System.Drawing.Color]::White
$descriptionBrowser.ForeColor = [System.Drawing.Color]::FromArgb(36, 52, 71)
$descriptionBrowser.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$descriptionBrowser.DetectUrls = $true
$installPanel.Controls.Add($descriptionBrowser)

$downloadFilesLabel = New-Object System.Windows.Forms.Label
$downloadFilesLabel.Text = "Download .gguf"
$downloadFilesLabel.Location = New-Object System.Drawing.Point(470, 42)
$downloadFilesLabel.Size = New-Object System.Drawing.Size(160, 20)
$installPanel.Controls.Add($downloadFilesLabel)

$filesListView = New-Object System.Windows.Forms.ListView
$filesListView.Location = New-Object System.Drawing.Point(470, 66)
$filesListView.Size = New-Object System.Drawing.Size(290, 258)
$filesListView.View = [System.Windows.Forms.View]::Details
$filesListView.FullRowSelect = $true
$filesListView.MultiSelect = $false
$filesListView.GridLines = $true
$filesListView.HideSelection = $false
[void]$filesListView.Columns.Add("File", 192)
[void]$filesListView.Columns.Add("Size", 78)
$installPanel.Controls.Add($filesListView)

$saveLabel = New-Object System.Windows.Forms.Label
$saveLabel.Text = "Save path"
$saveLabel.Location = New-Object System.Drawing.Point(470, 338)
$saveLabel.Size = New-Object System.Drawing.Size(120, 20)
$installPanel.Controls.Add($saveLabel)

$saveTextBox = New-Object System.Windows.Forms.TextBox
$saveTextBox.Location = New-Object System.Drawing.Point(470, 360)
$saveTextBox.Size = New-Object System.Drawing.Size(290, 28)
$installPanel.Controls.Add($saveTextBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "Browse"
$browseButton.Location = New-Object System.Drawing.Point(610, 394)
$browseButton.Size = New-Object System.Drawing.Size(150, 30)
$installPanel.Controls.Add($browseButton)

$downloadButton = New-Object System.Windows.Forms.Button
$downloadButton.Text = "Install selected file"
$downloadButton.Location = New-Object System.Drawing.Point(470, 394)
$downloadButton.Size = New-Object System.Drawing.Size(130, 30)
$downloadButton.Enabled = $false
$installPanel.Controls.Add($downloadButton)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(470, 434)
$progressBar.Size = New-Object System.Drawing.Size(290, 22)
$progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
$installPanel.Controls.Add($progressBar)

$installStatusLabel = New-Object System.Windows.Forms.Label
$installStatusLabel.Text = "Idle"
$installStatusLabel.Location = New-Object System.Drawing.Point(4, 448)
$installStatusLabel.Size = New-Object System.Drawing.Size(756, 20)
$installPanel.Controls.Add($installStatusLabel)

$saveDialog = New-Object System.Windows.Forms.SaveFileDialog
$saveDialog.Filter = "GGUF files (*.gguf)|*.gguf|All files (*.*)|*.*"
$saveDialog.Title = "Choose save path"

$script:titleMetaTextWidth = 520

function Apply-Language {
  Update-TitleMetaLayout

  if ($installPanel.Visible -and -not [string]::IsNullOrWhiteSpace($script:selectedRepoId)) {
    $titleLabel.Text = Get-ModelNameFromRepoId -RepoId $script:selectedRepoId
  } elseif ($listPanel.Visible) {
    $titleLabel.Text = $script:selectedCategory
  } else {
    $titleLabel.Text = Get-UiText "AppTitle"
  }

  $languageLabel.Text = Get-UiText "Language"
  $languageLabel.Visible = $true
  $languageComboBox.Visible = $true
  $languageLabel.BringToFront()
  $languageComboBox.BringToFront()
  $subtitleLabel.Text = Get-UiText "Subtitle"
  $categoryTitleLabel.Text = Get-UiText "CategoryTitle"
  $categoryHintLabel.Text = Get-UiText "CategoryHint"
  $listInfoLabel.Text = if ($listPanel.Visible) { (Get-UiText "ModelListFor") -f $script:selectedCategory } else { Get-UiText "ModelList" }
  $sortLabel.Text = Get-UiText "SortBy"
  $openInstallButton.Text = Get-UiText "OpenInstall"
  $globalBackButton.Text = Get-UiText "Back"
  $filesLabel.Text = Get-UiText "ModelCard"
  $downloadFilesLabel.Text = Get-UiText "DownloadGguf"
  $saveLabel.Text = Get-UiText "SavePath"
  $browseButton.Text = Get-UiText "Browse"
  $downloadButton.Text = Get-UiText "InstallSelectedFile"
  $saveDialog.Title = Get-UiText "SaveDialogTitle"
  if ($installStatusLabel.Text -eq "Idle" -or $installStatusLabel.Text -eq "待機中") { $installStatusLabel.Text = Get-UiText "Idle" }
  if ($listStatusLabel.Text -eq "Idle" -or $listStatusLabel.Text -eq "待機中") { $listStatusLabel.Text = Get-UiText "Idle" }
  if ($categoryStatusLabel.Text -eq "Idle" -or $categoryStatusLabel.Text -eq "待機中") { $categoryStatusLabel.Text = Get-UiText "Idle" }

  $sortComboBox.Items.Clear()
  [void]$sortComboBox.Items.Add((Get-UiText "SortDownloads"))
  [void]$sortComboBox.Items.Add((Get-UiText "SortLastUpdated"))
  [void]$sortComboBox.Items.Add((Get-UiText "SortTrend"))
  switch ($script:modelSortMode) {
    "LastChanged" { $sortComboBox.SelectedIndex = 1 }
    "Trend" { $sortComboBox.SelectedIndex = 2 }
    default { $sortComboBox.SelectedIndex = 0 }
  }

  Set-ListViewColumnText -ListView $modelsListView -Index 0 -Text (Get-UiText "ColumnModel")
  Set-ListViewColumnText -ListView $modelsListView -Index 1 -Text (Get-UiText "ColumnAuthor")
  Set-ListViewColumnText -ListView $modelsListView -Index 2 -Text (Get-UiText "ColumnPublished")
  Set-ListViewColumnText -ListView $modelsListView -Index 3 -Text (Get-UiText "ColumnDownloads")
  Set-ListViewColumnText -ListView $filesListView -Index 0 -Text (Get-UiText "ColumnFile")
  Set-ListViewColumnText -ListView $filesListView -Index 1 -Text (Get-UiText "ColumnSize")

  $titleMetaToolTip.SetToolTip($pipelineInfoLabel, $(Get-UiText "PipelineTooltip"))
  $titleMetaToolTip.SetToolTip($licenseInfoLabel, $(Get-UiText "LicenseTooltip"))
  $othersButton.Text = Get-UiText "Others"

  switch ($script:currentView) {
    "install" { $globalActionButton.Text = Get-UiText "FetchFiles" }
    "list" { $globalActionButton.Text = Get-UiText "RefreshModels" }
    default { $globalActionButton.Text = Get-UiText "RefreshCatalog" }
  }
}

function Refresh-CategoryListView {
  $entries = @(Get-VisibleCategoryEntries)

  for ($i = 0; $i -lt $script:categoryCardButtons.Count; $i += 1) {
    $card = $script:categoryCardButtons[$i]
    if ($i -lt $entries.Count - 1) {
      $entry = $entries[$i]
      $card.Panel.Visible = $true
      $card.Button.Tag = $entry
      $card.NameLabel.Text = $entry.Name
      $card.MetaLabel.Text = ("{0} models`r`n{1}" -f $entry.Count, $(if ([string]::IsNullOrWhiteSpace($entry.PrimaryAuthor)) { "community" } else { $entry.PrimaryAuthor }))
      $card.Picture.Image = Get-AvatarImage -Author $entry.PrimaryAuthor -FallbackText ($entry.Name.Substring(0, [Math]::Min(2, $entry.Name.Length)).ToUpper())
    } else {
      $card.Panel.Visible = $false
      $card.Button.Tag = $null
    }
  }

  $othersEntry = $entries | Where-Object { $_.Key -eq "__OTHERS__" } | Select-Object -First 1
  if ($othersEntry -and $othersEntry.Count -gt 0) {
    $othersButton.Tag = $othersEntry
    $othersButton.Text = ("Others ({0})" -f $othersEntry.Count)
    $othersButton.Visible = $true
  } else {
    $othersButton.Tag = $null
    $othersButton.Visible = $false
  }
}

function Refresh-ModelListView {
  $modelsListView.Items.Clear()

  $filteredModels = @(Sort-Models -Models @(Get-ModelsForCurrentCategory))

  foreach ($model in $filteredModels) {
    $publishedAt = [string]$model.PublishedAt
    if ([string]::IsNullOrWhiteSpace($publishedAt)) {
      $publishedAt = [string]$model.LastChanged
    }

    $item = New-Object System.Windows.Forms.ListViewItem((Get-ModelNameFromRepoId -RepoId $model.RepoId))
    [void]$item.SubItems.Add((Get-ModelAuthorName -Model $model))
    [void]$item.SubItems.Add((Get-DisplayDate -Value $publishedAt))
    [void]$item.SubItems.Add(([string]$model.Downloads))
    $item.Tag = $model
    [void]$modelsListView.Items.Add($item)
  }

  $openInstallButton.Enabled = ($modelsListView.SelectedItems.Count -gt 0)
}

function Load-ModelCatalog {
  param(
    [switch]$ForceRefresh,
    [switch]$UseCacheOnly
  )

  $openInstallButton.Enabled = $false
  $categoryStatusLabel.Text = if ($ForceRefresh) { Get-UiText "RefreshingCatalog" } else { Get-UiText "LoadingCatalog" }
  $listStatusLabel.Text = if ($ForceRefresh) { Get-UiText "RefreshingCatalog" } else { Get-UiText "LoadingCatalog" }
  [System.Windows.Forms.Application]::DoEvents()

  $loadedFromCache = $false
  $cacheUpdatedAt = ""

  if (-not $ForceRefresh) {
    $cachedCatalog = Get-HfModelCatalogCache
    if (
      $cachedCatalog -and
      @($cachedCatalog.Models).Count -gt 0 -and
      (Test-HfModelCatalogCacheCompatible -Models @($cachedCatalog.Models))
    ) {
      $script:models = @($cachedCatalog.Models)
      $loadedFromCache = $true
      $cacheUpdatedAt = [string]$cachedCatalog.UpdatedAt
    }
  }

  if ($UseCacheOnly -and -not $loadedFromCache -and @($script:models).Count -gt 0) {
    $script:categories = @(Get-ModelCategories -Models $script:models)
    Refresh-CategoryListView
    Refresh-ModelListView
    $categoryStatusLabel.Text = ((Get-UiText "LoadedCategories") -f $script:models.Count, $script:categories.Count, "memory")
    $listStatusLabel.Text = ((Get-UiText "LoadedModelsCache") -f $script:models.Count)
    return
  }

  if (-not $loadedFromCache) {
    $script:models = @(Get-HfLlamaCppModels)
    Save-HfModelCatalogCache -Models $script:models
    $cacheUpdatedAt = [datetime]::UtcNow.ToString("o")
  }

  $script:categories = @(Get-ModelCategories -Models $script:models)
  Refresh-CategoryListView
  Refresh-ModelListView
  if ($loadedFromCache) {
    $loadedAtText = if ([string]::IsNullOrWhiteSpace($cacheUpdatedAt)) { "cache" } else { "cache: $cacheUpdatedAt" }
    $categoryStatusLabel.Text = ((Get-UiText "LoadedCategories") -f $script:models.Count, $script:categories.Count, $loadedAtText)
    $listStatusLabel.Text = ((Get-UiText "LoadedModelsCache") -f $script:models.Count)
  } else {
    $categoryStatusLabel.Text = ((Get-UiText "RefreshedCategories") -f $script:models.Count, $script:categories.Count)
    $listStatusLabel.Text = ((Get-UiText "RefreshedModels") -f $script:models.Count)
  }
}

function Open-CategoryView {
  $script:currentView = "category"
  $titleLabel.Text = Get-UiText "AppTitle"
  $titleLabel.Size = New-Object System.Drawing.Size(740, 34)
  $titleMetaPanel.Visible = $false
  $baseModelLinkLabel.Visible = $false
  $pipelineInfoLabel.Visible = $false
  $languageInfoLabel.Visible = $false
  $licenseInfoLabel.Visible = $false
  $subtitleLabel.Visible = $false
  $globalBackButton.Visible = $false
  $globalActionButton.Visible = $true
  $globalActionButton.Text = Get-UiText "RefreshCatalog"
  Set-TopContentOffset -ShowTitleMeta:$false
  $installPanel.Visible = $false
  $listPanel.Visible = $false
  $categoryPanel.Visible = $true
  Apply-Language
}

function Open-ModelListView {
  param([object]$SelectedEntry)

  if (-not $SelectedEntry) {
    throw "Select a category first."
  }

  $selected = $SelectedEntry
  $script:selectedCategory = [string]$selected.Name
  $script:currentView = "list"
  if ($selected.Key -eq "__OTHERS__") {
    $script:selectedCategory = "__OTHERS__"
  }
  $listInfoLabel.Text = ((Get-UiText "ModelListFor") -f $script:selectedCategory)
  $titleLabel.Text = $script:selectedCategory
  $titleLabel.Size = New-Object System.Drawing.Size(740, 34)
  $titleMetaPanel.Visible = $false
  $baseModelLinkLabel.Visible = $false
  $pipelineInfoLabel.Visible = $false
  $languageInfoLabel.Visible = $false
  $licenseInfoLabel.Visible = $false
  $subtitleLabel.Visible = $true
  $globalBackButton.Visible = $true
  $globalActionButton.Visible = $true
  $globalActionButton.Text = Get-UiText "RefreshModels"
  Set-TopContentOffset -ShowTitleMeta:$false
  $categoryPanel.Visible = $false
  $installPanel.Visible = $false
  $listPanel.Visible = $true
  Apply-Language
  Refresh-ModelListView
}

function Open-InstallView {
  if ($modelsListView.SelectedItems.Count -eq 0) {
    throw "Select a model first."
  }

  $selected = $modelsListView.SelectedItems[0].Tag
  $script:installRepoHistory = @()
  Open-InstallRepo -RepoId ([string]$selected.RepoId) -PushCurrent:$false
}

function Open-ListView {
  param([switch]$UseCacheOnly)

  $script:currentView = "list"
  $titleLabel.Text = $script:selectedCategory
  $titleLabel.Size = New-Object System.Drawing.Size(740, 34)
  $titleMetaPanel.Visible = $false
  $baseModelLinkLabel.Visible = $false
  $pipelineInfoLabel.Visible = $false
  $languageInfoLabel.Visible = $false
  $licenseInfoLabel.Visible = $false
  $subtitleLabel.Visible = $true
  $globalBackButton.Visible = $true
  $globalActionButton.Visible = $true
  $globalActionButton.Text = Get-UiText "RefreshModels"
  Set-TopContentOffset -ShowTitleMeta:$false
  $installPanel.Visible = $false
  $listPanel.Visible = $true
  Apply-Language
  if ($UseCacheOnly) {
    Load-ModelCatalog -UseCacheOnly
  } else {
    Refresh-ModelListView
  }
}

function Load-RepoFiles {
  if ([string]::IsNullOrWhiteSpace($script:selectedRepoId)) {
    throw "No repo selected."
  }

  $downloadButton.Enabled = $false
  $filesListView.Items.Clear()
  $descriptionBrowser.Text = (Convert-MarkdownToDisplayText -Markdown "")
  $script:repoFiles = @()
  $progressBar.Value = 0
  $installStatusLabel.Text = Get-UiText "LoadingFiles"
  [System.Windows.Forms.Application]::DoEvents()

  $repoInfo = Get-HfModelFiles -RepoId $script:selectedRepoId -Token ""
  $titleLabel.Text = Get-ModelNameFromRepoId -RepoId $script:selectedRepoId
  $unknownWord = if ($script:uiLanguage -eq "ja") { "不明" } else { "Unknown" }
  $baseModelText = if ([string]::IsNullOrWhiteSpace([string]$repoInfo.BaseModel)) { $unknownWord } else { [string]$repoInfo.BaseModel }
  $baseModelLinkLabel.Text = ("{0}: {1}" -f (Get-UiText "BasePrefix"), $baseModelText)
  $baseModelLinkLabel.Tag = if ($baseModelText -ne $unknownWord) { $baseModelText } else { "" }
  $basePrefixLength = ((Get-UiText "BasePrefix") + ": ").Length
  $baseModelLinkLabel.LinkArea = New-Object System.Windows.Forms.LinkArea($basePrefixLength, $baseModelText.Length)
  $baseModelLinkLabel.Visible = $true

  $pipelineText = if ([string]::IsNullOrWhiteSpace([string]$repoInfo.PipelineTag)) { $unknownWord } else { [string]$repoInfo.PipelineTag }
  $pipelineInfoLabel.Text = ("{0}: {1}" -f (Get-UiText "PipelinePrefix"), $pipelineText)
  $pipelineInfoLabel.Visible = $true
  $titleMetaToolTip.SetToolTip($pipelineInfoLabel, (Get-PipelineTagDescription -PipelineTag $pipelineText))

  $languageText = if ([string]::IsNullOrWhiteSpace([string]$repoInfo.Language)) { $unknownWord } else { (Get-HfLanguageDisplayText -LanguageValue ([string]$repoInfo.Language)) }
  $languageInfoLabel.Text = Format-WrappedMetaListText `
    -Prefix (Get-UiText "LanguagePrefix") `
    -Value $languageText `
    -MaxWidth $script:titleMetaTextWidth `
    -Font $languageInfoLabel.Font
  $languageInfoLabel.Visible = $true

  $licenseText = if ([string]::IsNullOrWhiteSpace([string]$repoInfo.License)) { $unknownWord } else { (Get-HfOfficialLicenseName -LicenseId ([string]$repoInfo.License)) }
  $licenseInfoLabel.Text = ("{0}: {1}" -f (Get-UiText "LicensePrefix"), $licenseText)
  $licenseInfoLabel.Visible = $true
  $titleMetaToolTip.SetToolTip($licenseInfoLabel, (Get-LicenseDescription -LicenseId ([string]$repoInfo.License) -LicenseName $licenseText))
  $descriptionBrowser.Text = (Convert-MarkdownToDisplayText -Markdown ([string]$repoInfo.Description))
  $script:repoFiles = @($repoInfo.Files)
  if ($script:repoFiles.Count -eq 0) {
    $saveTextBox.Text = ""
    $downloadButton.Enabled = $false
    $installStatusLabel.Text = Get-UiText "NoGguf"
    return
  }

  foreach ($file in $script:repoFiles) {
    $item = New-Object System.Windows.Forms.ListViewItem([string]$file.FileName)
    [void]$item.SubItems.Add([string]$file.SizeLabel)
    $item.Tag = $file
    [void]$filesListView.Items.Add($item)
  }

  if (-not (Test-Path -LiteralPath $defaultModelDir -PathType Container)) {
    New-Item -ItemType Directory -Path $defaultModelDir -Force | Out-Null
  }

  $saveTextBox.Text = Join-Path (Get-ConfiguredModelDir) $script:repoFiles[0].FileName
  if ($filesListView.Items.Count -gt 0) {
    $filesListView.Items[0].Selected = $true
  }
  $downloadButton.Enabled = $true
  $installStatusLabel.Text = ((Get-UiText "FetchedFiles") -f $script:repoFiles.Count)
}

foreach ($card in $script:categoryCardButtons) {
  $card.Button.Add_Click({
    $entry = $this.Tag
    if ($entry) {
      Invoke-Ui { Open-ModelListView -SelectedEntry $entry }
    }
  })
}

$othersButton.Add_Click({
  $entry = $this.Tag
  if ($entry) {
    Invoke-Ui { Open-ModelListView -SelectedEntry $entry }
  }
})

$sortComboBox.Add_SelectedIndexChanged({
  switch ($sortComboBox.SelectedIndex) {
    1 { $script:modelSortMode = "LastChanged" }
    2 { $script:modelSortMode = "Trend" }
    default { $script:modelSortMode = "Downloads" }
  }

  Refresh-ModelListView
})

$modelsListView.Add_SelectedIndexChanged({
  $openInstallButton.Enabled = ($modelsListView.SelectedItems.Count -gt 0)
})

$modelsListView.Add_DoubleClick({
  if ($modelsListView.SelectedItems.Count -gt 0) {
    Invoke-Ui { Open-InstallView }
  }
})

$openInstallButton.Add_Click({
  Invoke-Ui { Open-InstallView }
})

$globalBackButton.Add_Click({
  switch ($script:currentView) {
    "install" {
      if (@($script:installRepoHistory).Count -gt 0) {
        $previousRepoId = [string]$script:installRepoHistory[-1]
        if (@($script:installRepoHistory).Count -gt 1) {
          $script:installRepoHistory = @($script:installRepoHistory[0..(@($script:installRepoHistory).Count - 2)])
        } else {
          $script:installRepoHistory = @()
        }
        Invoke-Ui { Open-InstallRepo -RepoId $previousRepoId -PushCurrent:$false }
      } else {
        Invoke-Ui { Open-ListView -UseCacheOnly }
      }
    }
    "list" {
      Open-CategoryView
    }
    default {
      Open-CategoryView
    }
  }
})

$globalActionButton.Add_Click({
  Invoke-Ui {
    switch ($script:currentView) {
      "install" { Load-RepoFiles }
      default { Load-ModelCatalog -ForceRefresh }
    }
  }
})

$baseModelLinkLabel.Add_LinkClicked({
  $targetRepoId = [string]$baseModelLinkLabel.Tag
  if (-not [string]::IsNullOrWhiteSpace($targetRepoId)) {
    Invoke-Ui { Open-InstallRepo -RepoId $targetRepoId -PushCurrent:$true }
  }
})

$languageComboBox.Add_SelectedIndexChanged({
  $script:uiLanguage = if ($languageComboBox.SelectedIndex -eq 1) { "en" } else { "ja" }
  Apply-Language
})

$filesListView.Add_SelectedIndexChanged({
  if ($filesListView.SelectedItems.Count -eq 0) {
    return
  }

  $selectedFile = $filesListView.SelectedItems[0].Tag
  if (-not $selectedFile) {
    return
  }

  $selectedName = [string]$selectedFile.FileName
  $currentSavePath = [string]$saveTextBox.Text
  $targetDir = ""
  if (-not [string]::IsNullOrWhiteSpace($currentSavePath)) {
    $targetDir = Split-Path -Parent $currentSavePath
  }
  if ([string]::IsNullOrWhiteSpace($targetDir)) {
    $targetDir = $defaultModelDir
  }

  $saveTextBox.Text = Join-Path $targetDir $selectedName
})

$browseButton.Add_Click({
  Invoke-Ui {
    $selectedName = if ($filesListView.SelectedItems.Count -gt 0) { [string]$filesListView.SelectedItems[0].Text } else { "model.gguf" }
    $saveDialog.FileName = $selectedName
    if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
      $saveTextBox.Text = $saveDialog.FileName
    }
  }
})

$downloadButton.Add_Click({
  Invoke-Ui {
    $selectedRepoFile = if ($filesListView.SelectedItems.Count -gt 0) { $filesListView.SelectedItems[0].Tag } else { $null }
    if (-not $selectedRepoFile) {
      throw "Select a .gguf file first."
    }

    $downloadButton.Enabled = $false
    $globalActionButton.Enabled = $false
    $browseButton.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()

    Start-HfFileDownload `
      -DownloadUrl $selectedRepoFile.DownloadUrl `
      -FileName ([string]$selectedRepoFile.FileName) `
      -DestinationPath $saveTextBox.Text `
      -Token "" `
      -ProgressBar $progressBar `
      -StatusLabel $installStatusLabel

    [System.Windows.Forms.MessageBox]::Show(
      ("Saved:`r`n{0}" -f $saveTextBox.Text),
      "HF GGUF Downloader",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
  }

  $downloadButton.Enabled = $true
  $globalActionButton.Enabled = $true
  $browseButton.Enabled = $true
})

Set-TopContentOffset -ShowTitleMeta:$false
Apply-Language
$form.Add_Shown({
  [void]$form.BeginInvoke([System.Windows.Forms.MethodInvoker]{
    Invoke-Ui { Load-ModelCatalog }
  })
})
[void]$form.ShowDialog()
