[CmdletBinding()]
param(
    [string]$Generator = "Visual Studio 17 2022",
    [ValidateSet("x64")]
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
$env:VCPKG_DISABLE_METRICS = "1"

$MinimumCMakeVersion = [Version]"3.21.0"

$WinFlexBisonVersion = "2.5.25"
$WinFlexBisonUrl = "https://github.com/lexxmark/winflexbison/releases/download/v2.5.25/win_flex_bison-2.5.25.zip"
$WinFlexBisonSha256 = "8d324b62be33604b2c45ad1dd34ab93d722534448f55a16ca7292de32b6ac135"

$VcpkgVersion = "2026.05.25"
$VcpkgRepository = "https://github.com/microsoft/vcpkg.git"
$VcpkgDynamicTriplet = "x64-windows"
$VcpkgStaticTriplet = "x64-windows-static-md"

function Resolve-RepositoryPath {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$RepositoryRoot
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $Path))
}

function Get-RequiredCommand {
    param([Parameter(Mandatory = $true)] [string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Required tool '$Name' was not found on PATH."
    }

    return $command.Source
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)] [string]$Executable,
        [Parameter(Mandatory = $true)] [string[]]$Arguments,
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
        [Parameter(Mandatory = $true)] [string]$Executable,
        [Parameter(Mandatory = $true)] [string[]]$Arguments,
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
    param([Parameter(Mandatory = $true)] [string]$RepositoryRoot)

    $toolRoot = Join-Path $RepositoryRoot ".tools/winflexbison/$WinFlexBisonVersion"
    $flexExecutable = Join-Path $toolRoot "win_flex.exe"
    $bisonExecutable = Join-Path $toolRoot "win_bison.exe"

    if ((Test-Path -LiteralPath $flexExecutable) -and (Test-Path -LiteralPath $bisonExecutable)) {
        return [pscustomobject]@{
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

    $flexCandidate = Get-ChildItem -LiteralPath $toolRoot -Filter "win_flex.exe" -File -Recurse | Select-Object -First 1
    $bisonCandidate = Get-ChildItem -LiteralPath $toolRoot -Filter "win_bison.exe" -File -Recurse | Select-Object -First 1
    if ($null -eq $flexCandidate) {
        throw "win_flex.exe was not found after extracting WinFlexBison."
    }
    if ($null -eq $bisonCandidate) {
        throw "win_bison.exe was not found after extracting WinFlexBison."
    }

    return [pscustomobject]@{
        Flex = $flexCandidate.FullName
        Bison = $bisonCandidate.FullName
    }
}

function Get-VcpkgDependencies {
    param(
        [Parameter(Mandatory = $true)] [string]$RepositoryRoot,
        [Parameter(Mandatory = $true)] [string]$GitExecutable
    )

    $vcpkgRoot = Join-Path $RepositoryRoot ".tools/vcpkg/$VcpkgVersion"
    $vcpkgGitDirectory = Join-Path $vcpkgRoot ".git"

    if (-not (Test-Path -LiteralPath $vcpkgGitDirectory)) {
        if (Test-Path -LiteralPath $vcpkgRoot) {
            Remove-Item -LiteralPath $vcpkgRoot -Recurse -Force
        }

        New-Item -ItemType Directory -Path (Split-Path -Parent $vcpkgRoot) -Force | Out-Null
        Invoke-NativeCommand -Executable $GitExecutable -Arguments @(
            "clone",
            "--branch", $VcpkgVersion,
            "--depth", "1",
            $VcpkgRepository,
            $vcpkgRoot
        ) -Description "vcpkg checkout"
    }

    $checkedOutTag = Get-NativeCommandOutput -Executable $GitExecutable -Arguments @(
        "-C", $vcpkgRoot,
        "describe", "--tags", "--exact-match"
    ) -Description "vcpkg version verification"
    if ($checkedOutTag -ne $VcpkgVersion) {
        throw "Unexpected vcpkg checkout '$checkedOutTag'; expected '$VcpkgVersion'. Delete $vcpkgRoot and retry."
    }

    $vcpkgCommit = Get-NativeCommandOutput -Executable $GitExecutable -Arguments @(
        "-C", $vcpkgRoot,
        "rev-parse", "HEAD"
    ) -Description "vcpkg revision check"

    $vcpkgExecutable = Join-Path $vcpkgRoot "vcpkg.exe"
    if (-not (Test-Path -LiteralPath $vcpkgExecutable)) {
        $bootstrapScript = Join-Path $vcpkgRoot "bootstrap-vcpkg.bat"
        if (-not (Test-Path -LiteralPath $bootstrapScript)) {
            throw "vcpkg bootstrap script is missing: $bootstrapScript"
        }

        Invoke-NativeCommand -Executable $bootstrapScript -Arguments @("-disableMetrics") -Description "vcpkg bootstrap"
    }

    Invoke-NativeCommand -Executable $vcpkgExecutable -Arguments @(
        "install",
        "sdl2:$VcpkgDynamicTriplet",
        "sdl2-image:$VcpkgDynamicTriplet",
        "boost-filesystem:$VcpkgStaticTriplet",
        "--disable-metrics",
        "--clean-after-build"
    ) -Description "vcpkg dependency installation"

    $sdlRoot = Join-Path $vcpkgRoot "installed/$VcpkgDynamicTriplet"
    $boostRoot = Join-Path $vcpkgRoot "installed/$VcpkgStaticTriplet"
    $sdlInclude = Join-Path $sdlRoot "include/SDL2"
    $sdlLibrary = Join-Path $sdlRoot "lib/SDL2.lib"
    $sdlImageLibrary = Join-Path $sdlRoot "lib/SDL2_image.lib"
    $dynamicBin = Join-Path $sdlRoot "bin"
    $boostInclude = Join-Path $boostRoot "include"
    $boostLibraryDirectory = Join-Path $boostRoot "lib"
    $boostDebugLibraryDirectory = Join-Path $boostRoot "debug/lib"

    foreach ($requiredPath in @(
        (Join-Path $sdlInclude "SDL.h"),
        (Join-Path $sdlInclude "SDL_image.h"),
        $sdlLibrary,
        $sdlImageLibrary,
        $dynamicBin,
        (Join-Path $boostInclude "boost/version.hpp"),
        $boostLibraryDirectory
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Required vcpkg output is missing: $requiredPath"
        }
    }

    $boostFilesystemLibrary = Get-ChildItem -LiteralPath $boostLibraryDirectory -Filter "*boost_filesystem*.lib" -File | Select-Object -First 1
    if ($null -eq $boostFilesystemLibrary) {
        throw "Boost.Filesystem static library was not found in $boostLibraryDirectory."
    }

    $packageList = Get-NativeCommandOutput -Executable $vcpkgExecutable -Arguments @("list", "--disable-metrics") -Description "vcpkg package inventory"

    return [pscustomobject]@{
        VcpkgRoot = $vcpkgRoot
        Version = $VcpkgVersion
        Commit = $vcpkgCommit
        DynamicTriplet = $VcpkgDynamicTriplet
        StaticTriplet = $VcpkgStaticTriplet
        SdlInclude = $sdlInclude
        SdlLibrary = $sdlLibrary
        SdlImageLibrary = $sdlImageLibrary
        DynamicBin = $dynamicBin
        BoostRoot = $boostRoot
        BoostInclude = $boostInclude
        BoostLibraryDirectory = $boostLibraryDirectory
        BoostDebugLibraryDirectory = $boostDebugLibraryDirectory
        PackageList = $packageList
    }
}

function Copy-Tree {
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Required directory is missing: $Source"
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

function Stage-ReleasePackage {
    param(
        [Parameter(Mandatory = $true)] [string]$RepositoryRoot,
        [Parameter(Mandatory = $true)] [string]$ArtifactRoot,
        [Parameter(Mandatory = $true)] [string]$DynamicBin
    )

    $binDestination = Join-Path $ArtifactRoot "bin"
    $engineResourcesDestination = Join-Path $ArtifactRoot "engine-resources"

    Copy-Tree -Source (Join-Path $RepositoryRoot "assets") -Destination (Join-Path $ArtifactRoot "assets")
    Copy-Tree -Source (Join-Path $RepositoryRoot "dependencies/submodules/delta-studio/engines/basic/fonts") -Destination (Join-Path $engineResourcesDestination "fonts")
    Copy-Tree -Source (Join-Path $RepositoryRoot "dependencies/submodules/delta-studio/engines/basic/shaders") -Destination (Join-Path $engineResourcesDestination "shaders")

    Set-Content -LiteralPath (Join-Path $binDestination "delta.conf") -Value @(
        "../engine-resources",
        "../assets"
    ) -Encoding Ascii

    $runtimeLibraries = @(Get-ChildItem -LiteralPath $DynamicBin -Filter "*.dll" -File)
    if ($runtimeLibraries.Count -eq 0) {
        throw "No runtime DLLs were found in $DynamicBin."
    }
    foreach ($library in $runtimeLibraries) {
        Copy-Item -LiteralPath $library.FullName -Destination (Join-Path $binDestination $library.Name) -Force
    }

    foreach ($requiredDll in @("SDL2.dll", "SDL2_image.dll")) {
        if (-not (Test-Path -LiteralPath (Join-Path $binDestination $requiredDll))) {
            throw "Required runtime library was not staged: $requiredDll"
        }
    }

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
    Write-Host "Pinned submodules:"
    Write-Host $submoduleStatus
    $invalidSubmodule = $submoduleStatus -split "`r?`n" | Where-Object { $_ -match "^[\-\+U]" } | Select-Object -First 1
    if ($null -ne $invalidSubmodule) {
        throw "Submodules are not at the commits pinned by the checkout: $invalidSubmodule"
    }

    $winFlexBison = Get-WinFlexBison -RepositoryRoot $repositoryRoot
    $flexVersion = Get-NativeCommandOutput -Executable $winFlexBison.Flex -Arguments @("--version") -Description "Flex version check"
    $bisonVersion = Get-NativeCommandOutput -Executable $winFlexBison.Bison -Arguments @("--version") -Description "Bison version check"
    $dependencies = Get-VcpkgDependencies -RepositoryRoot $repositoryRoot -GitExecutable $git

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
        "-DSDL2_INCLUDE_DIR=$($dependencies.SdlInclude)",
        "-DSDL2_LIBRARY_TEMP=$($dependencies.SdlLibrary)",
        "-DSDL2_IMAGE_INCLUDE_DIR=$($dependencies.SdlInclude)",
        "-DSDL2_IMAGE_LIBRARY=$($dependencies.SdlImageLibrary)",
        "-DBOOST_ROOT=$($dependencies.BoostRoot)",
        "-DBOOST_LIBRARYDIR=$($dependencies.BoostLibraryDirectory)",
        "-DBoost_INCLUDE_DIR=$($dependencies.BoostInclude)",
        "-DBoost_LIBRARY_DIR_RELEASE=$($dependencies.BoostLibraryDirectory)",
        "-DBoost_LIBRARY_DIR_DEBUG=$($dependencies.BoostDebugLibraryDirectory)",
        "-DBoost_NO_SYSTEM_PATHS=ON",
        "-DBoost_USE_STATIC_LIBS=ON",
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

    Stage-ReleasePackage -RepositoryRoot $repositoryRoot -ArtifactRoot $artifactRoot -DynamicBin $dependencies.DynamicBin

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
            vcpkgTag = $dependencies.Version
            vcpkgCommit = $dependencies.Commit
            vcpkgDynamicTriplet = $dependencies.DynamicTriplet
            vcpkgStaticTriplet = $dependencies.StaticTriplet
        }
        dependencies = ($dependencies.PackageList -split "`r?`n")
        submodules = ($submoduleStatus -split "`r?`n")
    }

    $buildInfoPath = Join-Path $artifactRoot "build-info.json"
    $buildInfo | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $buildInfoPath -Encoding UTF8

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
