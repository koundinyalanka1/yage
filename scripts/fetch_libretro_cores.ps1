# Fetch LibRetro cores for Android (NES, SNES, mGBA, Genesis Plus GX)
# Downloads from: https://buildbot.libretro.com/nightly/android/latest/
#
# Run from project root: .\scripts\fetch_libretro_cores.ps1

$baseUrl = "https://buildbot.libretro.com/nightly/android/latest"
$abis = @("armeabi-v7a", "arm64-v8a", "x86_64")
$cores = @(
    @{ name = "fceumm"; file = "fceumm_libretro_android.so" },
    @{ name = "snes9x2010"; file = "snes9x2010_libretro_android.so" },
    @{ name = "mgba"; file = "mgba_libretro_android.so" },
    @{ name = "genesis_plus_gx"; file = "genesis_plus_gx_libretro_android.so" }
)

$jniLibs = "android\app\src\main\jniLibs"
if (-not (Test-Path $jniLibs)) {
    New-Item -ItemType Directory -Path $jniLibs -Force | Out-Null
}

foreach ($abi in $abis) {
    $abiDir = Join-Path $jniLibs $abi
    if (-not (Test-Path $abiDir)) {
        New-Item -ItemType Directory -Path $abiDir -Force | Out-Null
    }

    foreach ($core in $cores) {
        $zipUrl = "$baseUrl/$abi/$($core.file).zip"
        $zipPath = Join-Path $abiDir "$($core.file).zip"
        # Android requires the "lib" prefix for .so files bundled in the APK
        $finalName = "lib$($core.file)"
        $finalPath = Join-Path $abiDir $finalName

        Write-Host "Downloading $($core.name) for $abi..."
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
            Expand-Archive -Path $zipPath -DestinationPath $abiDir -Force
            Remove-Item $zipPath

            # Rename to add "lib" prefix (buildbot files don't have it)
            $extractedPath = Join-Path $abiDir $core.file
            if ((Test-Path $extractedPath) -and ($extractedPath -ne $finalPath)) {
                Move-Item -Path $extractedPath -Destination $finalPath -Force
            }
            Write-Host "  OK: $finalPath"
        } catch {
            Write-Host "  FAILED: $_" -ForegroundColor Red
        }
    }
}

Write-Host "`nDone. Cores placed in $jniLibs"
Write-Host "Rebuild the app: flutter clean && flutter build apk"
