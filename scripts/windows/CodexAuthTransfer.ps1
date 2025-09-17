[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('export', 'import')]
    [string]$Command,

    [string]$Output,

    [string]$File,

    [switch]$Force,

    [switch]$NoMetadata
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProgramName = 'codex-auth-transfer'
$DefaultBundle = 'codex-auth-bundle.tar.gz'

function Write-Log {
    param([string]$Message)
    Write-Host "[$ProgramName] $Message"
}

function New-TemporaryDirectory {
    $path = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
    return (New-Item -ItemType Directory -Path $path -Force).FullName
}

function Get-PathHash {
    param([string]$Path)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path)
        $hashBytes = $sha1.ComputeHash($bytes)
        ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha1.Dispose()
    }
}

function Get-CodexCandidatePaths {
    $paths = @()
    $home = $env:USERPROFILE
    if ($env:APPDATA) { $paths += (Join-Path $env:APPDATA 'codex') }
    if ($env:LOCALAPPDATA) { $paths += (Join-Path $env:LOCALAPPDATA 'codex') }
    if ($home) {
        $paths += (Join-Path $home '.codex')
        $paths += (Join-Path $home 'AppData\Roaming\codex')
        $paths += (Join-Path $home 'AppData\Local\codex')
    }

    try {
        $codexPath = (& codex config path 2>$null)
        if ($codexPath -and (Test-Path -LiteralPath $codexPath)) {
            $paths = ,$codexPath + $paths
        }
    } catch {
        # codex CLI may not be available
    }

    $result = @()
    foreach ($p in $paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (-not (Test-Path -LiteralPath $p)) { continue }
        if ($result -contains $p) { continue }
        $result += $p
    }
    return $result
}

function Resolve-BundlePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = $DefaultBundle
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        try {
            return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        } catch {
            return $Path
        }
    }
    return (Join-Path -Path (Get-Location) -ChildPath $Path)
}

function Require-Tar {
    $tar = Get-Command tar -ErrorAction SilentlyContinue
    if (-not $tar) {
        throw "tar.exe was not found. Install the Windows tar utility (available in Windows 10 build 17063+) or add it to PATH."
    }
    return $tar.Source
}

function Convert-ToRelativePath {
    param([string]$FullPath, [string]$Home)
    $normalizedHome = [System.IO.Path]::GetFullPath($Home)
    $normalizedFull = [System.IO.Path]::GetFullPath($FullPath)
    if ($normalizedFull.StartsWith($normalizedHome, [System.StringComparison]::OrdinalIgnoreCase)) {
        $suffix = $normalizedFull.Substring($normalizedHome.Length).TrimStart('\', '/')
        return '.{0}' -f ($suffix -replace '\\', '/')
    }
    $hash = Get-PathHash -Path $normalizedFull
    return ".codex-external/$hash"
}

function Convert-ToSystemPath {
    param([string]$Root, [string]$Relative)
    $winRel = $Relative -replace '/', '\\'
    return [System.IO.Path]::GetFullPath((Join-Path -Path $Root -ChildPath $winRel))
}

function Copy-CodexItem {
    param([string]$Source, [string]$Destination)
    if (Test-Path -LiteralPath $Source -PathType Container) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        $args = @($Source, $Destination, '/MIR', '/COPY:DAT', '/R:2', '/W:2', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
        & robocopy @args | Out-Null
        if ($LASTEXITCODE -gt 7) {
            throw "robocopy failed with exit code $LASTEXITCODE while copying $Source"
        }
    } else {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
}

function Protect-Path {
    param([string]$Path)
    try {
        & icacls "$Path" /inheritance:r /grant:r "$env:USERNAME:(OI)(CI)F" "SYSTEM:(OI)(CI)F" | Out-Null
    } catch {
        Write-Warning "Failed to tighten permissions on $Path: $_"
    }
}

function Stage-CodexData {
    param([string]$StageDir, [string]$ListFile)
    $paths = Get-CodexCandidatePaths
    if (-not $paths -or $paths.Count -eq 0) {
        throw 'No Codex credential directories were found.'
    }
    Write-Log 'Detected credential locations:'
    foreach ($p in $paths) { Write-Log "  - $p" }

    Set-Content -Path $ListFile -Value @() -Encoding UTF8

    foreach ($p in $paths) {
        $rel = Convert-ToRelativePath -FullPath $p -Home $env:USERPROFILE
        $dest = Convert-ToSystemPath -Root $StageDir -Relative $rel
        Copy-CodexItem -Source $p -Destination $dest
        Add-Content -Path $ListFile -Value $rel
    }
}

function Write-Manifest {
    param([string]$StageDir)
    $manifestPath = Join-Path $StageDir '.codex_auth_manifest'
    $lines = @()
    $lines += "created_at=$(Get-Date -Format o)"
    $lines += 'paths_file=.codex_auth_paths.txt'
    if (-not $NoMetadata.IsPresent) {
        $lines += "user=$env:USERNAME"
        $lines += "host=$env:COMPUTERNAME"
    }
    Set-Content -Path $manifestPath -Value $lines -Encoding UTF8
}

function Invoke-Export {
    $bundlePath = Resolve-BundlePath -Path $Output
    $tarPath = Require-Tar
    $tmpDir = New-TemporaryDirectory
    $stageDir = Join-Path $tmpDir 'stage'
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
    $listFile = Join-Path $stageDir '.codex_auth_paths.txt'
    try {
        Stage-CodexData -StageDir $stageDir -ListFile $listFile
        Write-Manifest -StageDir $stageDir
        Push-Location $stageDir
        try {
            & $tarPath -czf "$bundlePath" .
            if ($LASTEXITCODE -ne 0) {
                throw "tar exited with code $LASTEXITCODE"
            }
        } finally {
            Pop-Location
        }
        Protect-Path -Path $bundlePath
        Write-Log "Bundle created at $bundlePath"
        Write-Log 'Transfer it only over secure channels.'
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-ListFile {
    param([string]$TempDir)
    $listPath = Join-Path $TempDir '.codex_auth_paths.txt'
    if (-not (Test-Path -LiteralPath $listPath)) {
        Write-Log 'Path list missing; inferring from archive contents...'
        $candidates = @()
        $targets = @('.config/codex', '.local/share/codex', '.codex')
        foreach ($t in $targets) {
            $candidate = Convert-ToSystemPath -Root $TempDir -Relative $t
            if (Test-Path -LiteralPath $candidate) {
                $candidates += $t
            }
        }
        $externalRoot = Convert-ToSystemPath -Root $TempDir -Relative '.codex-external'
        if (Test-Path -LiteralPath $externalRoot) {
            $candidates += (Get-ChildItem -LiteralPath $externalRoot -Directory | ForEach-Object { ".codex-external/$($_.Name)" })
        }
        if ($candidates.Count -gt 0) {
            Set-Content -Path $listPath -Value ($candidates | Sort-Object -Unique) -Encoding UTF8
        }
    }
    if (-not (Test-Path -LiteralPath $listPath)) {
        throw 'No credential paths found in bundle.'
    }
    return $listPath
}

function Backup-IfExists {
    param([string]$Target)
    if (Test-Path -LiteralPath $Target) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$Target.bak-$timestamp"
        Write-Log "Backing up existing path: $Target -> $backup"
        Move-Item -LiteralPath $Target -Destination $backup -Force
    }
}

function Invoke-Import {
    $bundlePath = Resolve-BundlePath -Path $File
    if (-not (Test-Path -LiteralPath $bundlePath)) {
        throw "Bundle not found: $bundlePath"
    }
    $tarPath = Require-Tar
    $tmpDir = New-TemporaryDirectory
    try {
        Write-Log "Extracting bundle $bundlePath ..."
        & $tarPath -xzf "$bundlePath" -C "$tmpDir"
        if ($LASTEXITCODE -ne 0) {
            throw "tar exited with code $LASTEXITCODE"
        }
        $listFile = Get-ListFile -TempDir $tmpDir
        $paths = Get-Content -Path $listFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        if (-not $paths -or $paths.Count -eq 0) {
            throw 'No credential paths found in bundle.'
        }
        Write-Log 'Restoring credential directories:'
        foreach ($rel in $paths) {
            Write-Log "  - $rel"
            $src = Convert-ToSystemPath -Root $tmpDir -Relative $rel
            $dest = Convert-ToSystemPath -Root $env:USERPROFILE -Relative $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
            if (Test-Path -LiteralPath $dest) {
                if ($Force.IsPresent) {
                    Backup-IfExists -Target $dest
                } else {
                    throw "Destination already exists: $dest. Re-run with -Force to overwrite."
                }
            }
            Copy-CodexItem -Source $src -Destination $dest
            Protect-Path -Path $dest
        }
        Write-Log "Credentials restored under $env:USERPROFILE."
        Write-Log 'If Codex rejects the tokens, perform login using a secure tunnel or device code.'
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

switch ($Command) {
    'export' { Invoke-Export }
    'import' { Invoke-Import }
    default { throw "Unknown command: $Command" }
}
