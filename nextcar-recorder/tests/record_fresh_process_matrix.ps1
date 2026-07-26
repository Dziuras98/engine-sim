[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $HostRoot,

    [Parameter(Mandatory = $true)]
    [string] $OutputRoot,

    [Parameter(Mandatory = $true)]
    [string] $LogRoot,

    [Parameter(Mandatory = $true)]
    [string] $NamePrefix
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$rpms = @(2000, 4000, 6000)
$throttles = @(25, 50, 100)
$frequency = 10000
$length = 1
$warmup = 60

$resolvedHost = (Resolve-Path -LiteralPath $HostRoot).Path
$absoluteLogRoot = [System.IO.Path]::GetFullPath($LogRoot)
New-Item -ItemType Directory -Path $absoluteLogRoot -Force | Out-Null

$absoluteOutputRoot = Join-Path $resolvedHost $OutputRoot
if (Test-Path -LiteralPath $absoluteOutputRoot) {
    Remove-Item -LiteralPath $absoluteOutputRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $absoluteOutputRoot -Force | Out-Null

$results = @()
Push-Location $resolvedHost
try {
    foreach ($rpm in $rpms) {
        foreach ($throttle in $throttles) {
            $point = "$rpm-$throttle"
            $relativeOutput = $OutputRoot.TrimEnd('/', '\\') + "/" + $point
            $logPath = Join-Path $absoluteLogRoot ($NamePrefix + "-" + $point + ".log")
            $arguments = @(
                "record",
                "--engine-script", "es/assets/main.mr",
                "--output", $relativeOutput,
                "--name", ($NamePrefix + "-" + $point),
                "--rpm", ("$rpm`:$frequency"),
                "--throttle", "$throttle",
                "--length", "$length",
                "--warmup", "$warmup",
                "--instances", "1"
            )

            & ".\ESRecorder.Cli.exe" @arguments *> $logPath
            $exitCode = $LASTEXITCODE
            $results += [pscustomobject]@{
                rpm = $rpm
                throttle = $throttle
                frequency = $frequency
                length = $length
                warmup = $warmup
                exitCode = $exitCode
                output = $relativeOutput
                log = [System.IO.Path]::GetFileName($logPath)
            }

            Write-Host "===== fresh process $rpm RPM / $throttle% (exit $exitCode) ====="
            Get-Content -LiteralPath $logPath
            if ($exitCode -ne 0) {
                throw "Fresh-process recording failed at $rpm RPM / $throttle%."
            }
        }
    }
}
finally {
    Pop-Location
    $results |
        ConvertTo-Json -Depth 3 |
        Set-Content (Join-Path $absoluteLogRoot ($NamePrefix + "-matrix.json")) `
            -Encoding utf8
}

if ($results.Count -ne 9) {
    throw "Expected nine fresh-process recordings, observed $($results.Count)."
}
