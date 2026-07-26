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

    [Parameter(Mandatory = $true)]
    [string] $EvidencePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$engineRelativePath = "es/assets/engines/atg-video-2/02_subaru_ej25_uh.mr"
$pattern = '(?m)^([ \t]*)(simulation_frequency:[ \t]*20000[ \t]*)(\r?)$'

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

function Add-ExplicitConvolution {
    param(
        [Parameter(Mandatory = $true)]
        [string] $HostRoot
    )

    $enginePath = Join-Path $HostRoot $engineRelativePath
    if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
        throw "Parity engine script does not exist: $enginePath"
    }

    $text = [System.IO.File]::ReadAllText($enginePath)
    $expression = New-Object System.Text.RegularExpressions.Regex($pattern)
    $matches = $expression.Matches($text)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one EJ25 simulation-frequency insertion point, observed $($matches.Count)."
    }

    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $replacement = '${1}convolution: 1.0,' + $newline + '${1}${2}${3}'
    $updated = $expression.Replace($text, $replacement, 1)

    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($enginePath, $updated, $utf8WithoutBom)

    $verification = [System.IO.File]::ReadAllText($enginePath)
    $convolutionCount = [regex]::Matches(
        $verification,
        '(?m)^[ \t]*convolution:[ \t]*1\.0,[ \t]*\r?$').Count
    if ($convolutionCount -ne 1) {
        throw "Prepared parity script does not contain exactly one explicit convolution input."
    }

    return (Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash
}

$evidenceDirectory = Split-Path -Parent $EvidencePath
if (-not [string]::IsNullOrWhiteSpace($evidenceDirectory)) {
    New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
}

try {
    Copy-HostTree -Source $ReferenceSource -Destination $ReferenceDestination
    Copy-HostTree -Source $SourceBuiltSource -Destination $SourceBuiltDestination

    $referenceHash = Add-ExplicitConvolution -HostRoot $ReferenceDestination
    $sourceBuiltHash = Add-ExplicitConvolution -HostRoot $SourceBuiltDestination
    if ($referenceHash -ne $sourceBuiltHash) {
        throw "Reference and source-built parity scripts are not byte-identical."
    }

    @(
        "engine_relative_path=$engineRelativePath",
        "sha256=$referenceHash",
        "reference_host=$ReferenceDestination",
        "source_built_host=$SourceBuiltDestination"
    ) | Set-Content -LiteralPath $EvidencePath -Encoding ascii

    Write-Host "Prepared byte-identical explicit-convolution parity hosts."
    Write-Host "Parity engine SHA-256: $referenceHash"
}
catch {
    $errorPath = $EvidencePath + ".error.txt"
    $_ | Format-List * -Force | Out-File -LiteralPath $errorPath -Encoding utf8
    Write-Host "Parity preparation failed; error snapshot: $errorPath"
    Get-Content -LiteralPath $errorPath
    throw
}
