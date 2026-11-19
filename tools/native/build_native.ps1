param(
    [Parameter(Mandatory = $true)][string]$SdkRoot,
    [Parameter(Mandatory = $true)][string]$BuildRoot,
    [ValidateSet('arm64-v8a', 'x86_64', 'both')][string]$Abi = 'both',
    [switch]$Runner
)
$ErrorActionPreference = 'Stop'
$nativeSdk = (Resolve-Path -LiteralPath $SdkRoot).Path
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\entry\src\main\cpp'))
$outputRoot = [IO.Path]::GetFullPath($BuildRoot)
$cmakePath = Join-Path $nativeSdk 'build-tools\cmake\bin\cmake.exe'
$ninjaPath = Join-Path $nativeSdk 'build-tools\cmake\bin\ninja.exe'
$toolchainPath = Join-Path $nativeSdk 'build\cmake\ohos.toolchain.cmake'
$architectures = if ($Abi -eq 'both') { @('arm64-v8a', 'x86_64') } else { @($Abi) }
$runnerValue = if ($Runner) { 'ON' } else { 'OFF' }
foreach ($architecture in $architectures) {
    $buildDirectory = Join-Path $outputRoot $architecture
    New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
    & $cmakePath -S $sourceRoot -B $buildDirectory -G Ninja `
        "-DCMAKE_TOOLCHAIN_FILE=$toolchainPath" "-DCMAKE_MAKE_PROGRAM=$ninjaPath" `
        "-DOHOS_ARCH=$architecture" '-DCMAKE_BUILD_TYPE=Release' "-DXDM_MEDIA_BUILD_RUNNER=$runnerValue"
    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed for $architecture, exit $LASTEXITCODE" }
    & $cmakePath --build $buildDirectory --parallel 1
    if ($LASTEXITCODE -ne 0) { throw "Native build failed for $architecture, exit $LASTEXITCODE" }
}
