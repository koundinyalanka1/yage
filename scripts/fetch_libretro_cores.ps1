# Fetch LibRetro cores for Android (NES, SNES, mGBA)
# Downloads from: https://buildbot.libretro.com/nightly/android/latest/
#
# Run from project root: .\scripts\fetch_libretro_cores.ps1

$baseUrl = "https://buildbot.libretro.com/nightly/android/latest"
$abis = @("armeabi-v7a", "arm64-v8a", "x86_64")
$cores = @(
    @{ name = "fceumm"; file = "fceumm_libretro_android.so" },
    @{ name = "snes9x2010"; file = "snes9x2010_libretro_android.so" },
    @{ name = "mgba"; file = "mgba_libretro_android.so" }
)

$jniLibs = "android\app\src\main\jniLibs"
if (-not (Test-Path $jniLibs)) {
    New-Item -ItemType Directory -Path $jniLibs -Force
}

foreach ($abi in $abis) {
    $abiDir = Join-Path $jniLibs $abi
    if (-not (Test-Path $abiDir)) {
        New-Item -ItemType Directory -Path $abiDir -Force
    }

    foreach ($core in $cores) {
        $zipUrl = "$baseUrl/$abi/$($core.file).zip"
        $zipPath = Join-Path $abiDir "$($core.file).zip"
        $soPath = Join-Path $abiDir $core.file

        Write-Host "Downloading $($core.name) for $abi..."
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
            Expand-Archive -Path $zipPath -DestinationPath $abiDir -Force
            Remove-Item $zipPath
            Write-Host "  OK: $soPath"
        } catch {
            Write-Host "  FAILED: $_"
        }
    }
}

Write-Host "`nDone. Cores placed in $jniLibs"
Write-Host "Rebuild the app: flutter clean && flutter build apk"
