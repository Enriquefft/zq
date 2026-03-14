# zq installer for Windows — https://github.com/Enriquefft/zq
#
# Usage:
#   irm https://raw.githubusercontent.com/Enriquefft/zq/main/install.ps1 | iex
#
# Or with options:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Enriquefft/zq/main/install.ps1))) -Version 0.1.0

param(
    [string]$Version = $env:ZQ_VERSION,
    [string]$InstallDir = ""
)

$ErrorActionPreference = "Stop"
$Repo = "Enriquefft/zq"
$BaseUrl = "https://github.com/$Repo/releases"

# ── Checks ────────────────────────────────────────────────────────────────────

if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Error "zq requires a 64-bit operating system"
    exit 1
}

# ── Resolve version ──────────────────────────────────────────────────────────

if (-not $Version) {
    Write-Host "  > fetching latest version..." -ForegroundColor Blue
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest"
    $Version = $release.tag_name -replace '^v', ''
    if (-not $Version) {
        Write-Error "could not determine latest version — set ZQ_VERSION or use -Version"
        exit 1
    }
}

$Version = $Version -replace '^v', ''

# ── Set install directory ─────────────────────────────────────────────────────

if (-not $InstallDir) {
    $InstallDir = Join-Path $env:LOCALAPPDATA "zq"
}
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# ── Download & verify ─────────────────────────────────────────────────────────

$Archive = "zq-$Version-windows-amd64.zip"
$DownloadUrl = "$BaseUrl/download/v$Version/$Archive"
$ChecksumsUrl = "$BaseUrl/download/v$Version/checksums-sha256.txt"

$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "zq-install-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

try {
    $ArchivePath = Join-Path $TmpDir $Archive
    $ChecksumsPath = Join-Path $TmpDir "checksums-sha256.txt"

    Write-Host "  > downloading zq v$Version for windows/amd64..." -ForegroundColor Blue
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $ArchivePath -UseBasicParsing
    Invoke-WebRequest -Uri $ChecksumsUrl -OutFile $ChecksumsPath -UseBasicParsing

    Write-Host "  > verifying checksum..." -ForegroundColor Blue
    $checksumLine = Get-Content $ChecksumsPath | Where-Object { $_ -match $Archive }
    if (-not $checksumLine) {
        Write-Error "archive not found in checksums file"
        exit 1
    }
    $expected = ($checksumLine -split '\s+')[0]
    $actual = (Get-FileHash -Path $ArchivePath -Algorithm SHA256).Hash.ToLower()

    if ($expected -ne $actual) {
        Write-Error "checksum mismatch: expected $expected, got $actual"
        exit 1
    }

    # ── Install ───────────────────────────────────────────────────────────────

    Write-Host "  > extracting to $InstallDir..." -ForegroundColor Blue
    Expand-Archive -Path $ArchivePath -DestinationPath $TmpDir -Force
    Copy-Item (Join-Path $TmpDir "zq.exe") -Destination (Join-Path $InstallDir "zq.exe") -Force

    Write-Host "  > installed zq v$Version to $InstallDir\zq.exe" -ForegroundColor Blue

    # ── PATH ──────────────────────────────────────────────────────────────────

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*$InstallDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$InstallDir;$userPath", "User")
        Write-Host ""
        Write-Host "  > added $InstallDir to your user PATH" -ForegroundColor Green
        Write-Host "  > restart your shell for the change to take effect" -ForegroundColor Yellow
    }
}
finally {
    Remove-Item -Path $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
