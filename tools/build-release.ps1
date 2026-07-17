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
$VcpkgCommit = "d015e31e90838a4c9dfa3eed45979bc70d9357fc"
$VcpkgRepository = "https://github.com/microsoft/vcpkg.git"
$VcpkgTriplet = "x64-windows"

$BoostVersion = "1.78.0"
$BoostArchiveName = "boost_1_78_0.zip"
$BoostArchiveUrl = "https://archives.boost.io/release/1.78.0/source/boost_1_78_0.zip"
$BoostArchiveSha256 = "f22143b5528e081123c3c5ed437e92f648fe69748e95fa6e2bd41484e2986cc3"

function Resolve-RepoPath {
    param([string]$Path, [string]$Root)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
}

function Require-Command {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Required tool '$Name' was not found on PATH."
    }
    return $command.Source
}

function Run-Native {
    param([string]$Executable, [string[]]$Arguments, [string]$Description)
    Write-Host "> $Executable $($Arguments -join ' ')"
    & $Executable @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

function Capture-Native {
    param([string]$Executable, [string[]]$Arguments, [string]$Description)
    $output = & $Executable @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
    return ($output -join [Environment]::NewLine).Trim()
}

function Get-VerifiedArchive {
    param(
        [string]$Url,
        [string]$Path,
        [string]$Sha256,
        [string]$Description
    )

    if (Test-Path -LiteralPath $Path) {
        $cachedHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($cachedHash -ne $Sha256) {
            Remove-Item -LiteralPath $Path -Force
        }
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "Downloading $Description..."
        $null = Invoke-WebRequest -Uri $Url -OutFile $Path
    }
    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $Sha256) {
        throw "$Description checksum mismatch. Expected $Sha256, received $actualHash."
    }
}

function Copy-Tree {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Required directory is missing: $Source"
    }
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

try {
    $totalTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $startedUtc = [DateTime]::UtcNow

    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw "engine-sim currently supports the Windows build only."
    }

    $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
    if (-not (Test-Path -LiteralPath (Join-Path $root "CMakeLists.txt"))) {
        throw "Repository root could not be determined from $PSScriptRoot."
    }

    $cmake = Require-Command "cmake"
    $git = Require-Command "git"
    $cmakeVersionText = Capture-Native $cmake @("--version") "CMake version check"
    $versionMatch = [Regex]::Match($cmakeVersionText, "cmake version ([0-9]+\.[0-9]+\.[0-9]+)")
    if (-not $versionMatch.Success) {
        throw "Unable to parse CMake version from: $cmakeVersionText"
    }
    $cmakeVersion = [Version]$versionMatch.Groups[1].Value
    if ($cmakeVersion -lt $MinimumCMakeVersion) {
        throw "CMake $MinimumCMakeVersion or newer is required; found $cmakeVersion."
    }
    $cmakeHelp = Capture-Native $cmake @("--help") "CMake generator check"
    if ($cmakeHelp -notmatch [Regex]::Escape($Generator)) {
        throw "CMake generator '$Generator' is unavailable. Install Visual Studio 2022 with Desktop development with C++."
    }
    $gitVersion = Capture-Native $git @("--version") "Git version check"

    $buildRoot = Resolve-RepoPath $BuildDirectory $root
    $artifactRoot = Resolve-RepoPath $ArtifactDirectory $root
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
        Run-Native $git @("-C", $root, "submodule", "sync", "--recursive") "Submodule synchronization"
        Run-Native $git @("-C", $root, "submodule", "update", "--init", "--recursive") "Submodule initialization"
    }
    $submoduleStatus = Capture-Native $git @("-C", $root, "submodule", "status", "--recursive") "Submodule status check"
    Write-Host "Pinned submodules:"
    Write-Host $submoduleStatus
    $invalidSubmodule = $submoduleStatus -split "`r?`n" | Where-Object { $_ -match "^[\-\+U]" } | Select-Object -First 1
    if ($null -ne $invalidSubmodule) {
        throw "Submodules are not at commits pinned by the checkout: $invalidSubmodule"
    }

    $dependencyTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $downloadRoot = Join-Path $root ".tools/downloads"
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null

    # Flex/Bison used by the pinned piranha submodule.
    $flexRoot = Join-Path $root ".tools/winflexbison/$WinFlexBisonVersion"
    $flexExe = Join-Path $flexRoot "win_flex.exe"
    $bisonExe = Join-Path $flexRoot "win_bison.exe"
    if (-not ((Test-Path -LiteralPath $flexExe) -and (Test-Path -LiteralPath $bisonExe))) {
        $flexArchive = Join-Path $downloadRoot "win_flex_bison-$WinFlexBisonVersion.zip"
        Get-VerifiedArchive $WinFlexBisonUrl $flexArchive $WinFlexBisonSha256 "WinFlexBison $WinFlexBisonVersion"
        if (Test-Path -LiteralPath $flexRoot) {
            Remove-Item -LiteralPath $flexRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Path $flexRoot -Force | Out-Null
        Expand-Archive -LiteralPath $flexArchive -DestinationPath $flexRoot -Force
        $flexCandidate = Get-ChildItem -LiteralPath $flexRoot -Filter "win_flex.exe" -File -Recurse | Select-Object -First 1
        $bisonCandidate = Get-ChildItem -LiteralPath $flexRoot -Filter "win_bison.exe" -File -Recurse | Select-Object -First 1
        if (($null -eq $flexCandidate) -or ($null -eq $bisonCandidate)) {
            throw "WinFlexBison executables were not found after extraction."
        }
        $flexExe = $flexCandidate.FullName
        $bisonExe = $bisonCandidate.FullName
    }
    $flexVersion = Capture-Native $flexExe @("--version") "Flex version check"
    $bisonVersion = Capture-Native $bisonExe @("--version") "Bison version check"

    # SDL2 and SDL2_image from a pinned, current vcpkg snapshot.
    $vcpkgRoot = Join-Path $root ".tools/vcpkg/$VcpkgVersion"
    if (-not (Test-Path -LiteralPath (Join-Path $vcpkgRoot ".git"))) {
        if (Test-Path -LiteralPath $vcpkgRoot) {
            Remove-Item -LiteralPath $vcpkgRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $vcpkgRoot) -Force | Out-Null
        Run-Native $git @("clone", "--branch", $VcpkgVersion, "--depth", "1", $VcpkgRepository, $vcpkgRoot) "vcpkg checkout"
    }
    $actualVcpkgCommit = Capture-Native $git @("-C", $vcpkgRoot, "rev-parse", "HEAD") "vcpkg revision check"
    if ($actualVcpkgCommit -ne $VcpkgCommit) {
        throw "Unexpected vcpkg commit '$actualVcpkgCommit'; expected '$VcpkgCommit'."
    }
    $vcpkgExe = Join-Path $vcpkgRoot "vcpkg.exe"
    if (-not (Test-Path -LiteralPath $vcpkgExe)) {
        Run-Native (Join-Path $vcpkgRoot "bootstrap-vcpkg.bat") @("-disableMetrics") "vcpkg bootstrap"
    }
    Run-Native $vcpkgExe @(
        "install",
        "sdl2:$VcpkgTriplet",
        "sdl2-image:$VcpkgTriplet",
        "--disable-metrics",
        "--clean-after-build"
    ) "vcpkg SDL dependency installation"

    $sdlRoot = Join-Path $vcpkgRoot "installed/$VcpkgTriplet"
    $sdlInclude = Join-Path $sdlRoot "include/SDL2"
    $sdlLibrary = Join-Path $sdlRoot "lib/SDL2.lib"
    $sdlImageLibrary = Join-Path $sdlRoot "lib/SDL2_image.lib"
    $runtimeBin = Join-Path $sdlRoot "bin"
    foreach ($path in @(
        (Join-Path $sdlInclude "SDL.h"),
        (Join-Path $sdlInclude "SDL_image.h"),
        $sdlLibrary,
        $sdlImageLibrary,
        $runtimeBin
    )) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Required vcpkg output is missing: $path"
        }
    }
    $vcpkgPackages = Capture-Native $vcpkgExe @("list", "--disable-metrics") "vcpkg package inventory"

    # Boost 1.78 preserves path::is_complete(), required by the pinned piranha source.
    $boostRoot = Join-Path $root ".tools/boost/$BoostVersion"
    $boostSource = Join-Path $boostRoot "source/boost_1_78_0"
    $boostStage = Join-Path $boostRoot "stage"
    $boostLib = Join-Path $boostStage "lib"
    $boostArchive = Join-Path $downloadRoot $BoostArchiveName
    $boostFilesystemLibrary = $null
    if (Test-Path -LiteralPath $boostLib) {
        $boostFilesystemLibrary = Get-ChildItem -LiteralPath $boostLib -Filter "*boost_filesystem*.lib" -File | Select-Object -First 1
    }
    if (($null -eq $boostFilesystemLibrary) -or -not (Test-Path -LiteralPath (Join-Path $boostSource "boost/version.hpp"))) {
        Get-VerifiedArchive $BoostArchiveUrl $boostArchive $BoostArchiveSha256 "Boost $BoostVersion"
        if (Test-Path -LiteralPath $boostRoot) {
            Remove-Item -LiteralPath $boostRoot -Recurse -Force
        }
        $boostExtractRoot = Join-Path $boostRoot "source"
        New-Item -ItemType Directory -Path $boostExtractRoot -Force | Out-Null
        Expand-Archive -LiteralPath $boostArchive -DestinationPath $boostExtractRoot -Force
        $boostBootstrap = Join-Path $boostSource "bootstrap.bat"
        if (-not (Test-Path -LiteralPath $boostBootstrap)) {
            throw "Boost bootstrap script was not found after extraction."
        }
        Run-Native $boostBootstrap @() "Boost bootstrap"
        $boostB2 = Join-Path $boostSource "b2.exe"
        if (-not (Test-Path -LiteralPath $boostB2)) {
            throw "Boost b2.exe was not produced by bootstrap."
        }
        $boostJobs = if ($Parallel -gt 0) { $Parallel } else { [Math]::Max(1, [Environment]::ProcessorCount) }
        Run-Native $boostB2 @(
            "--with-filesystem",
            "--with-system",
            "toolset=msvc-14.3",
            "address-model=64",
            "variant=release",
            "link=static",
            "runtime-link=shared",
            "threading=multi",
            "--layout=versioned",
            "--stagedir=$boostStage",
            "-j$boostJobs",
            "stage"
        ) "Boost.Filesystem build"
    }
    $boostFilesystemLibrary = Get-ChildItem -LiteralPath $boostLib -Filter "*boost_filesystem*.lib" -File | Select-Object -First 1
    if ($null -eq $boostFilesystemLibrary) {
        throw "Boost.Filesystem library was not produced in $boostLib."
    }
    $dependencyTimer.Stop()

    $configureArgs = @(
        "-S", $root,
        "-B", $buildRoot,
        "-G", $Generator,
        "-A", $Architecture,
        "-DDTV=OFF",
        "-DPIRANHA_ENABLED=ON",
        "-DDISCORD_ENABLED=ON",
        "-DFLEX_EXECUTABLE=$flexExe",
        "-DBISON_EXECUTABLE=$bisonExe",
        "-DSDL2_BUILDING_LIBRARY=ON",
        "-DSDL2_INCLUDE_DIR=$sdlInclude",
        "-DSDL2_LIBRARY_TEMP=$sdlLibrary",
        "-DSDL2_IMAGE_INCLUDE_DIR=$sdlInclude",
        "-DSDL2_IMAGE_LIBRARY=$sdlImageLibrary",
        "-DBOOST_ROOT=$boostSource",
        "-DBOOST_LIBRARYDIR=$boostLib",
        "-DBoost_INCLUDE_DIR=$boostSource",
        "-DBoost_LIBRARY_DIR_RELEASE=$boostLib",
        "-DBoost_NO_SYSTEM_PATHS=ON",
        "-DBoost_USE_STATIC_LIBS=ON",
        "-DBoost_USE_STATIC_RUNTIME=OFF",
        "-DBoost_USE_RELEASE_LIBS=ON",
        "-DBoost_USE_DEBUG_LIBS=OFF",
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
        "-DCMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE=$artifactBin",
        "-DCMAKE_ARCHIVE_OUTPUT_DIRECTORY_RELEASE=$artifactLib",
        "-DCMAKE_LIBRARY_OUTPUT_DIRECTORY_RELEASE=$artifactLib"
    )
    $configureTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Run-Native $cmake $configureArgs "Release configuration"
    $configureTimer.Stop()

    $buildArgs = @("--build", $buildRoot, "--config", "Release", "--target", "engine-sim-app", "--parallel")
    if ($Parallel -gt 0) {
        $buildArgs += $Parallel.ToString()
    }
    $compileTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Run-Native $cmake $buildArgs "Release compilation"
    $compileTimer.Stop()

    $executable = Join-Path $artifactBin "engine-sim-app.exe"
    if (-not (Test-Path -LiteralPath $executable)) {
        $candidate = Get-ChildItem -LiteralPath $buildRoot -Filter "engine-sim-app.exe" -File -Recurse | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($null -eq $candidate) {
            throw "Build completed but engine-sim-app.exe was not produced."
        }
        Copy-Item -LiteralPath $candidate.FullName -Destination $executable -Force
    }

    Copy-Tree (Join-Path $root "assets") (Join-Path $artifactRoot "assets")
    Copy-Tree (Join-Path $root "dependencies/submodules/delta-studio/engines/basic/fonts") (Join-Path $artifactRoot "engine-resources/fonts")
    Copy-Tree (Join-Path $root "dependencies/submodules/delta-studio/engines/basic/shaders") (Join-Path $artifactRoot "engine-resources/shaders")
    Set-Content -LiteralPath (Join-Path $artifactBin "delta.conf") -Value @("../engine-resources", "../assets") -Encoding Ascii

    $runtimeLibraries = @(Get-ChildItem -LiteralPath $runtimeBin -Filter "*.dll" -File)
    if ($runtimeLibraries.Count -eq 0) {
        throw "No runtime DLLs were found in $runtimeBin."
    }
    foreach ($dll in $runtimeLibraries) {
        Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $artifactBin $dll.Name) -Force
    }
    foreach ($requiredDll in @("SDL2.dll", "SDL2_image.dll")) {
        if (-not (Test-Path -LiteralPath (Join-Path $artifactBin $requiredDll))) {
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
    Set-Content -LiteralPath (Join-Path $artifactRoot "run-engine-sim.ps1") -Value $launcher -Encoding Ascii

    $sourceCommit = Capture-Native $git @("-C", $root, "rev-parse", "HEAD") "Source revision check"
    $visualStudioVersion = "Detected by CMake generator"
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio/Installer/vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) {
        $detectedVs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property catalog_productDisplayVersion
        if (($LASTEXITCODE -eq 0) -and -not [string]::IsNullOrWhiteSpace(($detectedVs -join ""))) {
            $visualStudioVersion = ($detectedVs -join "").Trim()
        }
    }
    $osDescription = [System.Environment]::OSVersion.VersionString
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        if ($null -ne $os) {
            $osDescription = "$($os.Caption) $($os.Version)"
        }
    }
    catch {
        Write-Verbose $_.Exception.Message
    }

    $totalTimer.Stop()
    $buildInfo = [ordered]@{
        task = "NC-001"
        configuration = "Release"
        sourceCommit = $sourceCommit
        startedUtc = $startedUtc.ToString("o")
        completedUtc = [DateTime]::UtcNow.ToString("o")
        dependencySeconds = [Math]::Round($dependencyTimer.Elapsed.TotalSeconds, 3)
        configureSeconds = [Math]::Round($configureTimer.Elapsed.TotalSeconds, 3)
        compileSeconds = [Math]::Round($compileTimer.Elapsed.TotalSeconds, 3)
        totalSeconds = [Math]::Round($totalTimer.Elapsed.TotalSeconds, 3)
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
            vcpkgTag = $VcpkgVersion
            vcpkgCommit = $actualVcpkgCommit
            vcpkgTriplet = $VcpkgTriplet
            boost = $BoostVersion
        }
        dependencies = @(
            "boost-filesystem:$BoostVersion (official source, static, MSVC runtime DLL)",
            ($vcpkgPackages -split "`r?`n")
        )
        submodules = ($submoduleStatus -split "`r?`n")
    }
    $buildInfoPath = Join-Path $artifactRoot "build-info.json"
    $buildInfo | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $buildInfoPath -Encoding UTF8

    Write-Host ""
    Write-Host "Release build completed successfully." -ForegroundColor Green
    Write-Host "Executable: $executable"
    Write-Host "Dependency setup: $([Math]::Round($dependencyTimer.Elapsed.TotalSeconds, 3)) s"
    Write-Host "Configure time: $([Math]::Round($configureTimer.Elapsed.TotalSeconds, 3)) s"
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
