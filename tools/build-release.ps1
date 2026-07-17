[CmdletBinding()]
param(
    [string]$Generator = "Visual Studio 17 2022",
    [ValidateSet("x64", "Win32", "ARM64")]
    [string]$Architecture = "x64",
    [string]$BuildDirectory = "build/release",
    [string]$ArtifactDirectory = "artifacts/Release",
    [switch]$NoClean,
    [switch]$SkipSubmoduleUpdate,
    [int]$Parallel = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$WinFlexBisonVersion = "2.5.25"
$WinFlexBisonUrl = "https://github.com/lexxmark/winflexbison/releases/download/v2.5.25/win_flex_bison-2.5.25.zip"
$WinFlexBisonSha256 = "8d324b62be33604b2c45ad1dd34ab93d722534448f55a16ca7292de32b6ac135"
$MinimumCMakeVersion = [Version]"3.21.0"

function Resolve-RepositoryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $Path))
}

function Get-RequiredCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Required tool '$Name' was not found on PATH."
    }

    return $command.Source
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string]$Description = $Executable
    )

    Write-Host "> $Executable $($Arguments -join ' ')"
    & $Executable @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$Description failed with exit code $exitCode."
    }
}

function Get-NativeCommandOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string]$Description = $Executable
    )

    $output = & $Executable @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$Description failed with exit code $exitCode."
    }

    return ($output -join [Environment]::NewLine).Trim()
}

function Get-WinFlexBison {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $toolRoot = Join-Path $RepositoryRoot ".tools/winflexbison/$WinFlexBisonVersion"
    $flexExecutable = Join-Path $toolRoot "win_flex.exe"
    $bisonExecutable = Join-Path $toolRoot "win_bison.exe"

    if ((Test-Path -LiteralPath $flexExecutable) -and (Test-Path -LiteralPath $bisonExecutable)) {
        return @{
            Flex = $flexExecutable
            Bison = $bisonExecutable
        }
    }

    $downloadDirectory = Join-Path $RepositoryRoot ".tools/downloads"
    $archivePath = Join-Path $downloadDirectory "win_flex_bison-$WinFlexBisonVersion.zip"
    New-Item -ItemType Directory -Path $downloadDirectory -Force | Out-Null

    $downloadRequired = $true
    if (Test-Path -LiteralPath $archivePath) {
        $existingHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $downloadRequired = $existingHash -ne $WinFlexBisonSha256
        if ($downloadRequired) {
            Remove-Item -LiteralPath $archivePath -Force
        }
    }

    if ($downloadRequired) {
        Write-Host "Downloading WinFlexBison $WinFlexBisonVersion..."
        Invoke-WebRequest -Uri $WinFlexBisonUrl -OutFile $archivePath
    }

    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $WinFlexBisonSha256) {
        throw "WinFlexBison checksum mismatch. Expected $WinFlexBisonSha256, received $actualHash."
    }

    if (Test-Path -LiteralPath $toolRoot) {
        Remove-Item -LiteralPath $toolRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
    Expand-Archive -LiteralPath $archivePath -DestinationPath $toolRoot -Force

    if (-not (Test-Path -LiteralPath $flexExecutable)) {
        $flexExecutable = (Get-ChildItem -LiteralPath $toolRoot -Filter "win_flex.exe" -File -Recurse | Select-Object -First 1).FullName
    }
    if (-not (Test-Path -LiteralPath $bisonExecutable)) {
        $bisonExecutable = (Get-ChildItem -LiteralPath $toolRoot -Filter "win_bison.exe" -File -Recurse | Select-Object -First 1).FullName
    }

    if ([string]::IsNullOrWhiteSpace($flexExecutable) -or -not (Test-Path -LiteralPath $flexExecutable)) {
        throw "win_flex.exe was not found after extracting WinFlexBison."
    }
    if ([string]::IsNullOrWhiteSpace($bisonExecutable) -or -not (Test-Path -LiteralPath $bisonExecutable)) {
        throw "win_bison.exe was not found after extracting WinFlexBison."
    }

    return @{
        Flex = $flexExecutable
        Bison = $bisonExecutable
    }
}

function Copy-RuntimeResources {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,
        [Parameter(Mandatory = $true)]
        [string]$ArtifactRoot
    )

    $assetsSource = Join-Path $RepositoryRoot "assets"
    $fontsSource = Join-Path $RepositoryRoot "dependencies/submodules/delta-studio/engines/basic/fonts"
    $shadersSource = Join-Path $RepositoryRoot "dependencies/submodules/delta-studio/engines/basic/shaders"

    foreach ($requiredPath in @($assetsSource, $fontsSource, $shadersSource)) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Required runtime resource is missing: $requiredPath"
        }
    }

    $assetsDestination = Join-Path $ArtifactRoot "assets"
    $engineResourcesDestination = Join-Path $ArtifactRoot "engine-resources"
    $binDestination = Join-Path $ArtifactRoot "bin"

    New-Item -ItemType Directory -Path $engineResourcesDestination -Force | Out-Null
    New-Item -ItemType Directory -Path $binDestination -Force | Out-Null

    Copy-Item -LiteralPath $assetsSource -Destination $assetsDestination -Recurse -Force
    Copy-Item -LiteralPath $fontsSource -Destination (Join-Path $engineResourcesDestination "fonts") -Recurse -Force
    Copy-Item -LiteralPath $shadersSource -Destination (Join-Path $engineResourcesDestination "shaders") -Recurse -Force

    Set-Content -LiteralPath (Join-Path $binDestination "delta.conf") -Value @(
        "../engine-resources",
        "../assets"
    ) -Encoding Ascii

    $launcher = @'
$ErrorActionPreference = "Stop"
Push-Location -LiteralPath (Join-Path $PSScriptRoot "bin")
try {
    & ".\engine-sim-app.exe"
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
'@
    Set-Content -LiteralPath (Join-Path $ArtifactRoot "run-engine-sim.ps1") -Value $launcher -Encoding Ascii
}

try {
    $overallTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $startedUtc = [DateTime]::UtcNow

    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw "engine-sim currently supports the Windows build only."
    }

    $repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot "CMakeLists.txt"))) {
        throw "Repository root could not be determined from $PSScriptRoot."
    }

    $cmake = Get-RequiredCommand -Name "cmake"
    $git = Get-RequiredCommand -Name "git"

    $cmakeVersionOutput = Get-NativeCommandOutput -Executable $cmake -Arguments @("--version") -Description "CMake version check"
    $cmakeVersionMatch = [Regex]::Match($cmakeVersionOutput, "cmake version ([0-9]+\.[0-9]+\.[0-9]+)")
    if (-not $cmakeVersionMatch.Success) {
        throw "Unable to parse CMake version from: $cmakeVersionOutput"
    }
    $cmakeVersion = [Version]$cmakeVersionMatch.Groups[1].Value
    if ($cmakeVersion -lt $MinimumCMakeVersion) {
        throw "CMake $MinimumCMakeVersion or newer is required; found $cmakeVersion."
    }

    $cmakeHelp = Get-NativeCommandOutput -Executable $cmake -Arguments @("--help") -Description "CMake generator check"
    if ($cmakeHelp -notmatch [Regex]::Escape($Generator)) {
        throw "CMake generator '$Generator' is not available. Install Visual Studio 2022 with the Desktop development with C++ workload."
    }

    $gitVersion = Get-NativeCommandOutput -Executable $git -Arguments @("--version") -Description "Git version check"
    $buildRoot = Resolve-RepositoryPath -Path $BuildDirectory -RepositoryRoot $repositoryRoot
    $artifactRoot = Resolve-RepositoryPath -Path $ArtifactDirectory -RepositoryRoot $repositoryRoot
    $artifactBin = Join-Path $artifactRoot "bin"
    $artifactLib = Join-Path $artifactRoot "lib"

    if (-not $NoClean) {
        foreach ($path in @($buildRoot, $artifactRoot)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Recurse -Force
            }
        }
    }

    New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $artifactBin -Force | Out-Null
    New-Item -ItemType Directory -Path $artifactLib -Force | Out-Null

    if (-not $SkipSubmoduleUpdate) {
        Invoke-NativeCommand -Executable $git -Arguments @("-C", $repositoryRoot, "submodule", "sync", "--recursive") -Description "Submodule synchronization"
        Invoke-NativeCommand -Executable $git -Arguments @("-C", $repositoryRoot, "submodule", "update", "--init", "--recursive") -Description "Submodule initialization"
    }

    $submoduleStatus = Get-NativeCommandOutput -Executable $git -Arguments @("-C", $repositoryRoot, "submodule", "status", "--recursive") -Description "Submodule status check"
    $invalidSubmodule = $submoduleStatus -split "`r?`n" | Where-Object { $_ -match "^[\-\+U]" } | Select-Object -First 1
    if ($null -ne $invalidSubmodule) {
        throw "Submodules are not at the commits pinned by the checkout: $invalidSubmodule"
    }

    $winFlexBison = Get-WinFlexBison -RepositoryRoot $repositoryRoot
    $flexVersion = Get-NativeCommandOutput -Executable $winFlexBison.Flex -Arguments @("--version") -Description "Flex version check"
    $bisonVersion = Get-NativeCommandOutput -Executable $winFlexBison.Bison -Arguments @("--version") -Description "Bison version check"

    $configureArguments = @(
        "-S", $repositoryRoot,
        "-B", $buildRoot,
        "-G", $Generator,
        "-A", $Architecture,
        "-DDTV=OFF",
        "-DPIRANHA_ENABLED=ON",
        "-DDISCORD_ENABLED=ON",
        "-DFLEX_EXECUTABLE=$($winFlexBison.Flex)",
        "-DBISON_EXECUTABLE=$($winFlexBison.Bison)",
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
        "-DCMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE=$artifactBin",
        "-DCMAKE_ARCHIVE_OUTPUT_DIRECTORY_RELEASE=$artifactLib",
        "-DCMAKE_LIBRARY_OUTPUT_DIRECTORY_RELEASE=$artifactLib"
    )

    $configureTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-NativeCommand -Executable $cmake -Arguments $configureArguments -Description "Release configuration"
    $configureTimer.Stop()

    $buildArguments = @(
        "--build", $buildRoot,
        "--config", "Release",
        "--target", "engine-sim-app",
        "--parallel"
    )
    if ($Parallel -gt 0) {
        $buildArguments += $Parallel.ToString()
    }

    $compileTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-NativeCommand -Executable $cmake -Arguments $buildArguments -Description "Release compilation"
    $compileTimer.Stop()

    $expectedExecutable = Join-Path $artifactBin "engine-sim-app.exe"
    if (-not (Test-Path -LiteralPath $expectedExecutable)) {
        $builtExecutable = Get-ChildItem -LiteralPath $buildRoot -Filter "engine-sim-app.exe" -File -Recurse |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
        if ($null -eq $builtExecutable) {
            throw "Build completed but engine-sim-app.exe was not produced."
        }

        Copy-Item -LiteralPath $builtExecutable.FullName -Destination $expectedExecutable -Force
    }

    Copy-RuntimeResources -RepositoryRoot $repositoryRoot -ArtifactRoot $artifactRoot

    $sourceCommit = Get-NativeCommandOutput -Executable $git -Arguments @("-C", $repositoryRoot, "rev-parse", "HEAD") -Description "Source revision check"
    $visualStudioVersion = "Detected by CMake generator"
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio/Installer/vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) {
        $detectedVersion = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property catalog_productDisplayVersion
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($detectedVersion -join ""))) {
            $visualStudioVersion = ($detectedVersion -join "").Trim()
        }
    }

    $osDescription = [System.Environment]::OSVersion.VersionString
    try {
        $operatingSystem = Get-CimInstance Win32_OperatingSystem
        if ($null -ne $operatingSystem) {
            $osDescription = "$($operatingSystem.Caption) $($operatingSystem.Version)"
        }
    }
    catch {
        Write-Verbose "Win32_OperatingSystem information unavailable: $($_.Exception.Message)"
    }

    $overallTimer.Stop()
    $completedUtc = [DateTime]::UtcNow
    $buildInfo = [ordered]@{
        task = "NC-001"
        configuration = "Release"
        sourceCommit = $sourceCommit
        startedUtc = $startedUtc.ToString("o")
        completedUtc = $completedUtc.ToString("o")
        configureSeconds = [Math]::Round($configureTimer.Elapsed.TotalSeconds, 3)
        compileSeconds = [Math]::Round($compileTimer.Elapsed.TotalSeconds, 3)
        totalSeconds = [Math]::Round($overallTimer.Elapsed.TotalSeconds, 3)
        executable = "bin/engine-sim-app.exe"
        environment = [ordered]@{
            operatingSystem = $osDescription
            processor = $env:PROCESSOR_IDENTIFIER
            powershell = $PSVersionTable.PSVersion.ToString()
            cmake = $cmakeVersion.ToString()
            git = $gitVersion
            generator = $Generator
            architecture = $Architecture
            visualStudio = $visualStudioVersion
            flex = ($flexVersion -split "`r?`n" | Select-Object -First 1)
            bison = ($bisonVersion -split "`r?`n" | Select-Object -First 1)
        }
        submodules = ($submoduleStatus -split "`r?`n")
    }

    $buildInfoPath = Join-Path $artifactRoot "build-info.json"
    $buildInfo | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $buildInfoPath -Encoding UTF8

    Write-Host ""
    Write-Host "Release build completed successfully." -ForegroundColor Green
    Write-Host "Executable: $expectedExecutable"
    Write-Host "Compile time: $([Math]::Round($compileTimer.Elapsed.TotalSeconds, 3)) s"
    Write-Host "Build metadata: $buildInfoPath"
    exit 0
}
catch {
    Write-Host ""
    Write-Host "NC-001 Release build failed: $($_.Exception.Message)" -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        Write-Host $_.ScriptStackTrace
    }
    exit 1
}
