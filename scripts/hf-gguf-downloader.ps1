$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

function Get-ConfiguredModelDir {
  $rootDir = [string](Get-Location)
  $bootSettingsPath = Join-Path $rootDir "config\bootSettings.json"
  $bootSettings = Read-JsonFileSafe -Path $bootSettingsPath

  if ($bootSettings -and $bootSettings.boot -and -not [string]::IsNullOrWhiteSpace([string]$bootSettings.boot.modelFolder)) {
    return [string]$bootSettings.boot.modelFolder
  }

  return (Join-Path $rootDir "llama-runtime\models")
}

function Get-HfLlamaCppModels {
  param([int]$MaxCount = 500)

  $pageSize = 100
  $offset = 0
  $collected = @()

  while ($collected.Count -lt $MaxCount) {
    $remaining = $MaxCount - $collected.Count
    $limit = [Math]::Min($pageSize, $remaining)
    $uri = "https://huggingface.co/api/models?filter=llama.cpp&sort=downloads&direction=-1&limit=$limit&offset=$offset"
    $response = @(Invoke-RestMethod -Uri $uri -Headers (Get-HfHeaders -Token "") -Method Get)
    if ($response.Count -eq 0) {
      break
    }

    $collected += $response
    if ($response.Count -lt $limit) {
      break
    }

    $offset += $response.Count
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
      Downloads   = $downloads
      LastChanged = [string]$item.lastModified
    }
  }

  return $result
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

function Get-HfModelFiles {
  param(
    [string]$RepoId,
    [string]$Token
  )

  if ([string]::IsNullOrWhiteSpace($RepoId)) {
    throw "repo_id is required."
  }

  $repoId = $RepoId.Trim()
  $repoIdEscaped = [uri]::EscapeDataString($repoId)
  $uri = "https://huggingface.co/api/models/$repoIdEscaped"
  $response = Invoke-RestMethod -Uri $uri -Headers (Get-HfHeaders -Token $Token) -Method Get

  if (-not $response -or -not $response.siblings) {
    return @()
  }

  $revision = if (-not [string]::IsNullOrWhiteSpace([string]$response.sha)) {
    [string]$response.sha
  } else {
    "main"
  }

  return @(
    $response.siblings |
      Where-Object { $_.rfilename -like "*.gguf" } |
      Sort-Object rfilename |
      ForEach-Object {
        $relativePath = [string]$_.rfilename
        [pscustomobject]@{
          FileName    = $relativePath
          DownloadUrl = "https://huggingface.co/$repoId/resolve/$revision/$(ConvertTo-HfRelativePathUrl -Path $relativePath)"
        }
      }
  )
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
    $fileStream = [System.IO.File]::Open($destinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

    $buffer = New-Object byte[] (1024 * 1024)
    $totalRead = 0L
    $contentLength = [int64]$response.ContentLength
    $ProgressBar.Style = if ($contentLength -gt 0) { [System.Windows.Forms.ProgressBarStyle]::Continuous } else { [System.Windows.Forms.ProgressBarStyle]::Marquee }
    $ProgressBar.Value = 0

    while (($read = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
      $fileStream.Write($buffer, 0, $read)
      $totalRead += $read

      if ($contentLength -gt 0) {
        $percent = [Math]::Min(100, [int](($totalRead * 100L) / $contentLength))
        $ProgressBar.Value = $percent
        $StatusLabel.Text = ("Downloading... {0}% ({1:N2} / {2:N2} MB)" -f $percent, ($totalRead / 1MB), ($contentLength / 1MB))
      } else {
        $StatusLabel.Text = ("Downloading... {0:N2} MB" -f ($totalRead / 1MB))
      }

      [System.Windows.Forms.Application]::DoEvents()
    }
  } catch {
    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
      Remove-Item -LiteralPath $destinationPath -Force -ErrorAction SilentlyContinue
    }
    throw
  } finally {
    if ($fileStream) { $fileStream.Dispose() }
    if ($responseStream) { $responseStream.Dispose() }
    if ($response) { $response.Dispose() }
  }

  $ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
  $ProgressBar.Value = 100
  $StatusLabel.Text = "Download complete"
}

$script:models = @()
$script:categories = @()
$script:repoFiles = @()
$script:selectedCategory = "All"
$script:selectedRepoId = ""
$defaultModelDir = Get-ConfiguredModelDir

$form = New-Object System.Windows.Forms.Form
$form.Text = "HF GGUF Downloader"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(820, 620)
$form.MinimumSize = New-Object System.Drawing.Size(820, 620)
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Hugging Face GGUF Downloader"
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$titleLabel.Location = New-Object System.Drawing.Point(20, 16)
$titleLabel.Size = New-Object System.Drawing.Size(440, 34)
$form.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "Browse llama.cpp models, pick one, then install a .gguf file."
$subtitleLabel.Location = New-Object System.Drawing.Point(22, 50)
$subtitleLabel.Size = New-Object System.Drawing.Size(720, 20)
$form.Controls.Add($subtitleLabel)

$categoryPanel = New-Object System.Windows.Forms.Panel
$categoryPanel.Location = New-Object System.Drawing.Point(18, 84)
$categoryPanel.Size = New-Object System.Drawing.Size(770, 500)
$form.Controls.Add($categoryPanel)

$listPanel = New-Object System.Windows.Forms.Panel
$listPanel.Location = New-Object System.Drawing.Point(18, 84)
$listPanel.Size = New-Object System.Drawing.Size(770, 500)
$listPanel.Visible = $false
$form.Controls.Add($listPanel)

$installPanel = New-Object System.Windows.Forms.Panel
$installPanel.Location = New-Object System.Drawing.Point(18, 84)
$installPanel.Size = New-Object System.Drawing.Size(770, 500)
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

$refreshCategoriesButton = New-Object System.Windows.Forms.Button
$refreshCategoriesButton.Text = "Refresh catalog"
$refreshCategoriesButton.Location = New-Object System.Drawing.Point(610, 0)
$refreshCategoriesButton.Size = New-Object System.Drawing.Size(150, 30)
$categoryPanel.Controls.Add($refreshCategoriesButton)

$categoryCardsHost = New-Object System.Windows.Forms.Panel
$categoryCardsHost.Location = New-Object System.Drawing.Point(4, 64)
$categoryCardsHost.Size = New-Object System.Drawing.Size(756, 360)
$categoryPanel.Controls.Add($categoryCardsHost)

$categoryStatusLabel = New-Object System.Windows.Forms.Label
$categoryStatusLabel.Text = "Idle"
$categoryStatusLabel.Location = New-Object System.Drawing.Point(4, 436)
$categoryStatusLabel.Size = New-Object System.Drawing.Size(500, 20)
$categoryPanel.Controls.Add($categoryStatusLabel)

$openCategoryButton = New-Object System.Windows.Forms.Button
$openCategoryButton.Text = "Open model list"
$openCategoryButton.Location = New-Object System.Drawing.Point(610, 430)
$openCategoryButton.Size = New-Object System.Drawing.Size(150, 34)
$openCategoryButton.Visible = $false
$categoryPanel.Controls.Add($openCategoryButton)

$categoryLayoutMap = @(
  @{ X = 0;   Y = 0;   W = 360; H = 172 }
  @{ X = 0;   Y = 188; W = 360; H = 172 }
  @{ X = 384; Y = 0;   W = 372; H = 104 }
  @{ X = 384; Y = 116; W = 372; H = 104 }
  @{ X = 384; Y = 232; W = 372; H = 104 }
  @{ X = 384; Y = 348; W = 372; H = 0 }
)

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
$script:categoryCardButtons += New-CategoryCard -X 384 -Y 0   -Width 372 -Height 104
$script:categoryCardButtons += New-CategoryCard -X 384 -Y 116 -Width 372 -Height 104
$script:categoryCardButtons += New-CategoryCard -X 384 -Y 232 -Width 372 -Height 104

$othersButton = New-Object System.Windows.Forms.Button
$othersButton.Location = New-Object System.Drawing.Point(384, 348)
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

$backToCategoryButton = New-Object System.Windows.Forms.Button
$backToCategoryButton.Text = "Back"
$backToCategoryButton.Location = New-Object System.Drawing.Point(454, 0)
$backToCategoryButton.Size = New-Object System.Drawing.Size(150, 30)
$listPanel.Controls.Add($backToCategoryButton)

$refreshModelsButton = New-Object System.Windows.Forms.Button
$refreshModelsButton.Text = "Refresh models"
$refreshModelsButton.Location = New-Object System.Drawing.Point(610, 0)
$refreshModelsButton.Size = New-Object System.Drawing.Size(150, 30)
$listPanel.Controls.Add($refreshModelsButton)

$modelsListView = New-Object System.Windows.Forms.ListView
$modelsListView.Location = New-Object System.Drawing.Point(4, 40)
$modelsListView.Size = New-Object System.Drawing.Size(756, 400)
$modelsListView.View = [System.Windows.Forms.View]::Details
$modelsListView.FullRowSelect = $true
$modelsListView.MultiSelect = $false
$modelsListView.GridLines = $true
$modelsListView.HideSelection = $false
[void]$modelsListView.Columns.Add("Repo", 430)
[void]$modelsListView.Columns.Add("Downloads", 110)
[void]$modelsListView.Columns.Add("Last Modified", 190)
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

$installTitleLabel = New-Object System.Windows.Forms.Label
$installTitleLabel.Text = "Install model"
$installTitleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$installTitleLabel.Location = New-Object System.Drawing.Point(4, 0)
$installTitleLabel.Size = New-Object System.Drawing.Size(200, 26)
$installPanel.Controls.Add($installTitleLabel)

$selectedRepoLabel = New-Object System.Windows.Forms.Label
$selectedRepoLabel.Text = "Repo:"
$selectedRepoLabel.Location = New-Object System.Drawing.Point(4, 34)
$selectedRepoLabel.Size = New-Object System.Drawing.Size(740, 20)
$installPanel.Controls.Add($selectedRepoLabel)

$backButton = New-Object System.Windows.Forms.Button
$backButton.Text = "Back"
$backButton.Location = New-Object System.Drawing.Point(610, 0)
$backButton.Size = New-Object System.Drawing.Size(150, 30)
$installPanel.Controls.Add($backButton)

$tokenLabel = New-Object System.Windows.Forms.Label
$tokenLabel.Text = "Access Token (optional)"
$tokenLabel.Location = New-Object System.Drawing.Point(4, 68)
$tokenLabel.Size = New-Object System.Drawing.Size(220, 20)
$installPanel.Controls.Add($tokenLabel)

$tokenTextBox = New-Object System.Windows.Forms.TextBox
$tokenTextBox.Location = New-Object System.Drawing.Point(4, 90)
$tokenTextBox.Size = New-Object System.Drawing.Size(756, 28)
$tokenTextBox.UseSystemPasswordChar = $true
$installPanel.Controls.Add($tokenTextBox)

$fetchFilesButton = New-Object System.Windows.Forms.Button
$fetchFilesButton.Text = "Fetch .gguf files"
$fetchFilesButton.Location = New-Object System.Drawing.Point(610, 126)
$fetchFilesButton.Size = New-Object System.Drawing.Size(150, 30)
$installPanel.Controls.Add($fetchFilesButton)

$filesLabel = New-Object System.Windows.Forms.Label
$filesLabel.Text = ".gguf files"
$filesLabel.Location = New-Object System.Drawing.Point(4, 132)
$filesLabel.Size = New-Object System.Drawing.Size(120, 20)
$installPanel.Controls.Add($filesLabel)

$filesListBox = New-Object System.Windows.Forms.ListBox
$filesListBox.Location = New-Object System.Drawing.Point(4, 164)
$filesListBox.Size = New-Object System.Drawing.Size(756, 160)
$filesListBox.HorizontalScrollbar = $true
$installPanel.Controls.Add($filesListBox)

$saveLabel = New-Object System.Windows.Forms.Label
$saveLabel.Text = "Save path"
$saveLabel.Location = New-Object System.Drawing.Point(4, 338)
$saveLabel.Size = New-Object System.Drawing.Size(120, 20)
$installPanel.Controls.Add($saveLabel)

$saveTextBox = New-Object System.Windows.Forms.TextBox
$saveTextBox.Location = New-Object System.Drawing.Point(4, 360)
$saveTextBox.Size = New-Object System.Drawing.Size(596, 28)
$installPanel.Controls.Add($saveTextBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "Browse"
$browseButton.Location = New-Object System.Drawing.Point(610, 358)
$browseButton.Size = New-Object System.Drawing.Size(150, 30)
$installPanel.Controls.Add($browseButton)

$downloadButton = New-Object System.Windows.Forms.Button
$downloadButton.Text = "Install selected file"
$downloadButton.Location = New-Object System.Drawing.Point(4, 402)
$downloadButton.Size = New-Object System.Drawing.Size(220, 34)
$downloadButton.Enabled = $false
$installPanel.Controls.Add($downloadButton)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(236, 406)
$progressBar.Size = New-Object System.Drawing.Size(524, 26)
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

  $filteredModels = @(Get-ModelsForCurrentCategory)

  foreach ($model in $filteredModels) {
    $item = New-Object System.Windows.Forms.ListViewItem($model.RepoId)
    [void]$item.SubItems.Add(([string]$model.Downloads))
    [void]$item.SubItems.Add($model.LastChanged)
    $item.Tag = $model
    [void]$modelsListView.Items.Add($item)
  }

  $openInstallButton.Enabled = ($modelsListView.SelectedItems.Count -gt 0)
}

function Load-ModelCatalog {
  $refreshCategoriesButton.Enabled = $false
  $refreshModelsButton.Enabled = $false
  $openCategoryButton.Enabled = $false
  $openInstallButton.Enabled = $false
  $categoryStatusLabel.Text = "Loading llama.cpp models..."
  $listStatusLabel.Text = "Loading llama.cpp models..."
  [System.Windows.Forms.Application]::DoEvents()

  $script:models = @(Get-HfLlamaCppModels -MaxCount 500)
  $script:categories = @(Get-ModelCategories -Models $script:models)
  Refresh-CategoryListView
  Refresh-ModelListView
  $categoryStatusLabel.Text = ("Loaded {0} model(s) in {1} categories" -f $script:models.Count, $script:categories.Count)
  $listStatusLabel.Text = ("Loaded {0} model(s)" -f $script:models.Count)
  $refreshCategoriesButton.Enabled = $true
  $refreshModelsButton.Enabled = $true
}

function Open-CategoryView {
  $installPanel.Visible = $false
  $listPanel.Visible = $false
  $categoryPanel.Visible = $true
}

function Open-ModelListView {
  param([object]$SelectedEntry)

  if (-not $SelectedEntry) {
    throw "Select a category first."
  }

  $selected = $SelectedEntry
  $script:selectedCategory = [string]$selected.Name
  if ($selected.Key -eq "__OTHERS__") {
    $script:selectedCategory = "__OTHERS__"
  }
  $listInfoLabel.Text = "Model list: $($script:selectedCategory)"
  Refresh-ModelListView
  $categoryPanel.Visible = $false
  $installPanel.Visible = $false
  $listPanel.Visible = $true
}

function Open-InstallView {
  if ($modelsListView.SelectedItems.Count -eq 0) {
    throw "Select a model first."
  }

  $selected = $modelsListView.SelectedItems[0].Tag
  $script:selectedRepoId = [string]$selected.RepoId
  $selectedRepoLabel.Text = "Repo: $($script:selectedRepoId)"
  $filesListBox.Items.Clear()
  $script:repoFiles = @()
  $saveTextBox.Text = ""
  $progressBar.Value = 0
  $downloadButton.Enabled = $false
  $installStatusLabel.Text = "Fetching .gguf files..."
  $listPanel.Visible = $false
  $installPanel.Visible = $true
  Load-RepoFiles
}

function Open-ListView {
  $installPanel.Visible = $false
  $listPanel.Visible = $true
}

function Load-RepoFiles {
  if ([string]::IsNullOrWhiteSpace($script:selectedRepoId)) {
    throw "No repo selected."
  }

  $fetchFilesButton.Enabled = $false
  $downloadButton.Enabled = $false
  $filesListBox.Items.Clear()
  $script:repoFiles = @()
  $progressBar.Value = 0
  $installStatusLabel.Text = "Fetching .gguf files..."
  [System.Windows.Forms.Application]::DoEvents()

  $script:repoFiles = @(Get-HfModelFiles -RepoId $script:selectedRepoId -Token $tokenTextBox.Text)
  if ($script:repoFiles.Count -eq 0) {
    throw "No .gguf files found for this repo."
  }

  foreach ($file in $script:repoFiles) {
    [void]$filesListBox.Items.Add($file.FileName)
  }

  if (-not (Test-Path -LiteralPath $defaultModelDir -PathType Container)) {
    New-Item -ItemType Directory -Path $defaultModelDir -Force | Out-Null
  }

  $filesListBox.SelectedIndex = 0
  $saveTextBox.Text = Join-Path (Get-ConfiguredModelDir) $script:repoFiles[0].FileName
  $downloadButton.Enabled = $true
  $fetchFilesButton.Enabled = $true
  $installStatusLabel.Text = ("Fetched {0} file(s)" -f $script:repoFiles.Count)
}

$refreshCategoriesButton.Add_Click({
  Invoke-Ui { Load-ModelCatalog }
})

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

$refreshModelsButton.Add_Click({
  Invoke-Ui { Load-ModelCatalog }
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

$backToCategoryButton.Add_Click({
  Open-CategoryView
})

$backButton.Add_Click({
  Open-ListView
})

$fetchFilesButton.Add_Click({
  Invoke-Ui {
    Load-RepoFiles
  }
})

$filesListBox.Add_SelectedIndexChanged({
  if (-not $filesListBox.SelectedItem) {
    return
  }

  $selectedName = [string]$filesListBox.SelectedItem
  $targetDir = Split-Path -Parent $saveTextBox.Text
  if ([string]::IsNullOrWhiteSpace($targetDir)) {
    $targetDir = $defaultModelDir
  }

  $saveTextBox.Text = Join-Path $targetDir $selectedName
})

$browseButton.Add_Click({
  Invoke-Ui {
    $selectedName = if ($filesListBox.SelectedItem) { [string]$filesListBox.SelectedItem } else { "model.gguf" }
    $saveDialog.FileName = $selectedName
    if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
      $saveTextBox.Text = $saveDialog.FileName
    }
  }
})

$downloadButton.Add_Click({
  Invoke-Ui {
    $selectedRepoFile = $script:repoFiles | Where-Object { $_.FileName -eq [string]$filesListBox.SelectedItem } | Select-Object -First 1
    if (-not $selectedRepoFile) {
      throw "Select a .gguf file first."
    }

    $downloadButton.Enabled = $false
    $fetchFilesButton.Enabled = $false
    $browseButton.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()

    Start-HfFileDownload `
      -DownloadUrl $selectedRepoFile.DownloadUrl `
      -FileName ([string]$filesListBox.SelectedItem) `
      -DestinationPath $saveTextBox.Text `
      -Token $tokenTextBox.Text `
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
  $fetchFilesButton.Enabled = $true
  $browseButton.Enabled = $true
})

Invoke-Ui { Load-ModelCatalog }
[void]$form.ShowDialog()
