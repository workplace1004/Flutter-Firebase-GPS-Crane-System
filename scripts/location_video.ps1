# Screen recording for Play's foreground-service (location) declaration.
#
# Runs apps/driver_app/integration_test/location_video_test.dart on the
# Pixel_7 emulator and records it: sign-in, online, the "compartiendo tu
# ubicación" notification, Home, the notification still there, back to the
# app. The walkthrough prints VIDEO:<step>; this script does the system-side
# step. Output: store/drakegruas/video-ubicacion-chofer.mp4.
#
#   pwsh scripts/location_video.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
$appDir = Join-Path $root 'apps\driver_app'
$package = 'com.gruasrd.driver_app'
$out = Join-Path $root 'store\drakegruas\video-ubicacion-chofer.mp4'

if (-not ((& $adb devices) -match 'emulator-\d+\s+device')) {
    Write-Host 'Starting the Pixel_7 emulator...'
    flutter emulators --launch Pixel_7 | Out-Null
    & $adb wait-for-device
    while ((& $adb shell getprop sys.boot_completed).Trim() -ne '1') { Start-Sleep 2 }
}

# A real status bar this time: the notification is the point of the video.
& $adb shell am broadcast -a com.android.systemui.demo -e command exit | Out-Null
& $adb shell wm size reset
& $adb emu geo fix -69.9312 18.4861 | Out-Null

$grant = Start-Job -ArgumentList $adb, $package -ScriptBlock {
    param($adb, $package)
    for ($i = 0; $i -lt 300; $i++) {
        & $adb shell pm grant $package android.permission.ACCESS_FINE_LOCATION 2>$null
        if ($LASTEXITCODE -eq 0) {
            & $adb shell pm grant $package android.permission.ACCESS_COARSE_LOCATION 2>$null
            & $adb shell pm grant $package android.permission.POST_NOTIFICATIONS 2>$null
            return
        }
        Start-Sleep -Milliseconds 500
    }
}

$mapsKey = (Get-Content (Join-Path $appDir 'android\local.properties') |
    Where-Object { $_ -match '^MAPS_API_KEY=' }) -replace '^MAPS_API_KEY=', ''
$recorder = $null

Push-Location $appDir
try {
    flutter drive --no-pub "--dart-define=GOOGLE_MAPS_API_KEY=$mapsKey" `
        --driver=test_driver/integration_test.dart `
        --target=integration_test/location_video_test.dart 2>&1 |
        Tee-Object -FilePath (Join-Path $env:TEMP 'location_video.log') |
        ForEach-Object {
            if ("$_" -match 'VIDEO:(\w+)') {
                switch ($Matches[1]) {
                    'start' {
                        $recorder = Start-Job -ArgumentList $adb -ScriptBlock {
                            param($adb)
                            & $adb shell screenrecord --bit-rate 8000000 --time-limit 120 /sdcard/fgs.mp4
                        }
                    }
                    'shade' { & $adb shell cmd statusbar expand-notifications }
                    'collapse' { & $adb shell cmd statusbar collapse }
                    'home' { & $adb shell input keyevent KEYCODE_HOME }
                    'back' { & $adb shell monkey -p $package -c android.intent.category.LAUNCHER 1 | Out-Null }
                    'stop' {
                        & $adb shell pkill -INT screenrecord
                        Start-Sleep 3
                        & $adb pull /sdcard/fgs.mp4 $out | Out-Null
                        & $adb shell rm /sdcard/fgs.mp4
                    }
                }
                Write-Host "step $($Matches[1])"
            }
            elseif ("$_" -match 'All tests passed|Some tests failed') { Write-Host "$_" }
        }
}
finally {
    Pop-Location
    foreach ($job in @($grant, $recorder)) {
        if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
    }
}

Get-Item $out | Select-Object Name, Length
