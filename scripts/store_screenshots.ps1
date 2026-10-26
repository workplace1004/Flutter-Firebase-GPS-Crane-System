# Play Store screenshots of the chofer or customer app, from the demo backend.
#
# Runs apps/<app>/integration_test/store_screenshots_test.dart on the
# Pixel_7 emulator with the screen set to 1080x1920 (the 9:16 Play asks for)
# and a clean status bar, and saves a PNG each time the walkthrough prints
# STORE_SHOT:<name>. Output: store/drakegruas/screenshots-<chofer|cliente>/.
#
#   pwsh scripts/store_screenshots.ps1               # chofer
#   pwsh scripts/store_screenshots.ps1 -App client   # cliente

param([ValidateSet('driver', 'client')] [string] $App = 'driver')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
$appDir = Join-Path $root "apps\$($App)_app"
$out = Join-Path $root ('store\drakegruas\screenshots-' + @{ driver = 'chofer'; client = 'cliente' }[$App])
$package = "com.gruasrd.$($App)_app"
New-Item -ItemType Directory -Force $out | Out-Null

if (-not ((& $adb devices) -match 'emulator-\d+\s+device')) {
    Write-Host 'Starting the Pixel_7 emulator...'
    flutter emulators --launch Pixel_7 | Out-Null
    & $adb wait-for-device
    while ((& $adb shell getprop sys.boot_completed).Trim() -ne '1') { Start-Sleep 2 }
}

# 9:16 at phone density, Santo Domingo, and a status bar with nothing in it.
& $adb shell wm size 1080x1920
& $adb emu geo fix -69.9312 18.4861 | Out-Null
& $adb shell settings put global sysui_demo_allowed 1
foreach ($cmd in @(
        'enter',
        'clock -e hhmm 0930',
        'battery -e level 100 -e plugged false',
        'network -e wifi show -e level 4',
        'network -e mobile show -e datatype none -e level 4',
        'notifications -e visible false')) {
    $parts = $cmd -split ' ', 2
    & $adb shell am broadcast -a com.android.systemui.demo -e command $parts[0] $(if ($parts.Count -gt 1) { $parts[1] -split ' ' }) | Out-Null
}

# flutter drive installs and starts at once, so grant from the side while it
# does: the walkthrough spends its first seconds signing in.
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

# The same key the build puts in the manifest; the Dart side needs it too, or
# it draws the schematic map.
$mapsKey = (Get-Content (Join-Path $appDir 'android\local.properties') |
    Where-Object { $_ -match '^MAPS_API_KEY=' }) -replace '^MAPS_API_KEY=', ''

Push-Location $appDir
try {
    flutter drive --no-pub "--dart-define=GOOGLE_MAPS_API_KEY=$mapsKey" `
        --driver=test_driver/integration_test.dart `
        --target=integration_test/store_screenshots_test.dart 2>&1 |
        Tee-Object -FilePath (Join-Path $env:TEMP "store_screenshots_$App.log") |
        ForEach-Object {
            $line = "$_"
            if ($line -match 'STORE_SHOT:(\w+)') {
                $name = $Matches[1]
                if ($name -ne 'done') {
                    & $adb shell screencap -p "/sdcard/$name.png"
                    & $adb pull "/sdcard/$name.png" (Join-Path $out "$name.png") | Out-Null
                    & $adb shell rm "/sdcard/$name.png"
                    Write-Host "captured $name"
                }
            }
            elseif ($line -match 'All tests passed|Some tests failed|EXCEPTION|Error') {
                Write-Host $line
            }
        }
}
finally {
    Pop-Location
    Stop-Job $grant -ErrorAction SilentlyContinue; Remove-Job $grant -Force -ErrorAction SilentlyContinue
    & $adb shell am broadcast -a com.android.systemui.demo -e command exit | Out-Null
    & $adb shell wm size reset
}

Get-ChildItem $out -Filter *.png | Select-Object Name, Length
