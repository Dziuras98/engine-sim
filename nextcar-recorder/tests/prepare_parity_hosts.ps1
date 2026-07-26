[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ReferenceSource,

    [Parameter(Mandatory = $true)]
    [string] $SourceBuiltSource,

    [Parameter(Mandatory = $true)]
    [string] $ReferenceDestination,

    [Parameter(Mandatory = $true)]
    [string] $SourceBuiltDestination,

    [string] $SearchPathObjects = "es/objects/objects.mr",

    [Parameter(Mandatory = $true)]
    [string] $EvidencePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$engineRelativePath = "es/assets/engines/atg-video-2/02_subaru_ej25_uh.mr"

function Copy-HostTree {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Source,

        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Host source does not exist: $Source"
    }
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item (Join-Path $Source '*') $Destination -Recurse -Force
}

function Replace-ExactlyOnce {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text,

        [Parameter(Mandatory = $true)]
        [string] $Pattern,

        [Parameter(Mandatory = $true)]
        [string] $Replacement,

        [Parameter(Mandatory = $true)]
        [string] $Description
    )

    $expression = New-Object System.Text.RegularExpressions.Regex($Pattern)
    $matches = $expression.Matches($Text)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one $Description match, observed $($matches.Count)."
    }

    return $expression.Replace($Text, $Replacement, 1)
}

function Enable-SearchPathConvolution {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ObjectsPath
    )

    if (-not (Test-Path -LiteralPath $ObjectsPath -PathType Leaf)) {
        throw "Search-path objects library does not exist: $ObjectsPath"
    }

    $beforeHash = (Get-FileHash -LiteralPath $ObjectsPath -Algorithm SHA256).Hash
    $text = [System.IO.File]::ReadAllText($ObjectsPath)
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }

    $text = Replace-ExactlyOnce `
        -Text $text `
        -Pattern '(?m)^([ \t]*input noise \[float\];)\r?$' `
        -Replacement ('${1}' + $newline + '    input convolution [float];') `
        -Description 'private engine convolution input'

    $text = Replace-ExactlyOnce `
        -Text $text `
        -Pattern '(?m)^([ \t]*input noise: 1\.0;)\r?$' `
        -Replacement ('${1}' + $newline + '    input convolution: 1.0;') `
        -Description 'public engine convolution default'

    $text = Replace-ExactlyOnce `
        -Text $text `
        -Pattern '(?m)^([ \t]*)noise: noise\r?$' `
        -Replacement ('${1}noise: noise,' + $newline + '${1}convolution: convolution') `
        -Description 'engine convolution forwarding'

    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ObjectsPath, $text, $utf8WithoutBom)

    $verification = [System.IO.File]::ReadAllText($ObjectsPath)
    $expectedPatterns = @(
        '(?m)^[ \t]*input convolution \[float\];\r?$',
        '(?m)^[ \t]*input convolution: 1\.0;\r?$',
        '(?m)^[ \t]*convolution: convolution\r?$'
    )
    foreach ($expectedPattern in $expectedPatterns) {
        if ([regex]::Matches($verification, $expectedPattern).Count -ne 1) {
            throw "Patched search-path wrapper failed convolution verification."
        }
    }

    return [pscustomobject]@{
        Before = $beforeHash
        After = (Get-FileHash -LiteralPath $ObjectsPath -Algorithm SHA256).Hash
    }
}

$evidenceDirectory = Split-Path -Parent $EvidencePath
if (-not [string]::IsNullOrWhiteSpace($evidenceDirectory)) {
    New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
}

try {
    Copy-HostTree -Source $ReferenceSource -Destination $ReferenceDestination
    Copy-HostTree -Source $SourceBuiltSource -Destination $SourceBuiltDestination

    $referenceEngine = Join-Path $ReferenceDestination $engineRelativePath
    $sourceEngine = Join-Path $SourceBuiltDestination $engineRelativePath
    $referenceEngineHash = (Get-FileHash -LiteralPath $referenceEngine -Algorithm SHA256).Hash
    $sourceEngineHash = (Get-FileHash -LiteralPath $sourceEngine -Algorithm SHA256).Hash
    if ($referenceEngineHash -ne $sourceEngineHash) {
        throw "Reference and source-built engine scripts are not byte-identical."
    }

    $wrapperHashes = Enable-SearchPathConvolution -ObjectsPath $SearchPathObjects

    @(
        "engine_relative_path=$engineRelativePath",
        "engine_sha256=$referenceEngineHash",
        "engine_script_modified=false",
        "search_path_objects=$SearchPathObjects",
        "search_path_objects_before_sha256=$($wrapperHashes.Before)",
        "search_path_objects_after_sha256=$($wrapperHashes.After)",
        "reference_host=$ReferenceDestination",
        "source_built_host=$SourceBuiltDestination"
    ) | Set-Content -LiteralPath $EvidencePath -Encoding ascii

    Write-Host "Prepared byte-identical parity hosts."
    Write-Host "Engine script SHA-256: $referenceEngineHash"
    Write-Host "Patched actual ../../es search-path wrapper: $SearchPathObjects"
}
catch {
    $errorPath = $EvidencePath + ".error.txt"
    $_ | Format-List * -Force | Out-File -LiteralPath $errorPath -Encoding utf8
    Write-Host "Parity preparation failed; error snapshot: $errorPath"
    Get-Content -LiteralPath $errorPath
    throw
}
