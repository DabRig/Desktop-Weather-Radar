<#
.SYNOPSIS
  End-to-end behaviour tests for DesktopRadar inside the real Rainmeter, against a local
  mock of NOAA (tests\mock-noaa.js, needs Node.js; dev-only).

.DESCRIPTION
  Creates a temporary skin copy <SkinPath>\DesktopRadarTest that points at
  http://127.0.0.1:<Port> with short timers, runs scenarios, and removes the copy at the end.
  Your real DesktopRadar skin is not touched. Rainmeter keeps an inactive [DesktopRadarTest]
  section in Rainmeter.ini afterwards (it does that for every skin ever loaded).

  Checks, per scenario: number of requests the skin made, what Radar.lua decided (debug log),
  State.inc, and the colour actually drawn on screen (single pixels inside the test skin only).

.PARAMETER SkipSuspend
  Skip the sleep/resume simulation (it freezes Rainmeter, all skins, for 10 seconds).
#>
[CmdletBinding()]
param([int]$Port = 8765, [switch]$SkipSuspend)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src = Join-Path $root 'skin\DesktopRadar'
$ini = Join-Path $env:APPDATA 'Rainmeter\Rainmeter.ini'
$skinPath = (Get-Content $ini | Where-Object { $_ -match '^SkinPath=' } | Select-Object -First 1) -replace '^SkinPath=', ''
$test = Join-Path $skinPath 'DesktopRadarTest'
$rm = Get-Process Rainmeter -ErrorAction Stop | Select-Object -First 1
$exe = $rm.Path
if (Test-Path $test) { throw "$test already exists. Remove it first (it is only ever created by this script)." }
foreach ($f in '@Resources\Location.inc', '@Resources\Images\blank.png', 'DownloadFile\layer_land.png') {
  if (-not (Test-Path (Join-Path $src $f))) { throw "Run tools\Update-Location.ps1 first (missing $f)." }
}

$script:fails = 0; $script:passes = 0
function Pass($m) { $script:passes++; Write-Host "  PASS  $m" -ForegroundColor Green }
function Fail($m) { $script:fails++; Write-Host "  FAIL  $m" -ForegroundColor Red }
function Expect($cond, $m) { if ($cond) { Pass $m } else { Fail $m } }
function Bang { & $exe @args; Start-Sleep -Milliseconds 300 }
function Mock([string]$q) { Invoke-RestMethod -UseBasicParsing -TimeoutSec 5 -Uri "http://127.0.0.1:$Port/control?$q" }
function Requests {
  # PowerShell 5.1 returns a JSON array as one object; unroll it.
  $r = Invoke-RestMethod -UseBasicParsing -TimeoutSec 5 -Uri "http://127.0.0.1:$Port/log"
  @($r | ForEach-Object { $_ })
}
$dbg = Join-Path $test 'DownloadFile\debug.log'
function DebugLines { if (Test-Path $dbg) { @(Get-Content $dbg) } else { @() } }
function Wait-Log([int]$from, [string]$pattern, [int]$timeout = 30) {
  $t = [Diagnostics.Stopwatch]::StartNew()
  while ($t.Elapsed.TotalSeconds -lt $timeout) {
    $l = DebugLines; if ($l.Count -gt $from) { $hit = $l[$from..($l.Count - 1)] | Where-Object { $_ -match $pattern } | Select-Object -First 1; if ($hit) { return $hit } }
    Start-Sleep -Milliseconds 400
  }
  $null
}
function Read-IncVariablesLocal([string]$p) { $h = @{}; foreach ($l in Get-Content $p) { if ($l -match '^(\w+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }; $h }
function State { $h = @{}; foreach ($l in Get-Content (Join-Path $test '@Resources\State.inc')) { if ($l -match '^(\w+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }; $h }

# Expected on-screen colour at a sample point = radar colour blended over the basemap pixel.
# The basemap is the ocean colour plus four layers, each painted one colour (Radar.ini ColorMatrix).
$SX = 60; $SY = 150
function Basemap-Pixel([string]$skinDir) {
  $c = @(13.0, 19.0, 29.0)
  foreach ($L in @(@('land', 37, 44, 58, 1.0), @('water', 13, 19, 29, 1.0), @('counties', 70, 88, 115, 0.55), @('roads', 84, 104, 136, 0.45))) {
    $f = Join-Path $skinDir "DownloadFile\layer_$($L[0]).png"
    if (-not (Test-Path $f)) { continue }
    $b = [Drawing.Bitmap]::FromFile($f); $a = $b.GetPixel($SX, $SY).A / 255 * $L[4]; $b.Dispose()
    for ($i = 0; $i -lt 3; $i++) { $c[$i] = $c[$i] * (1 - $a) + $L[$i + 1] * $a }
  }
  [pscustomobject]@{ R = $c[0]; G = $c[1]; B = $c[2] }
}
$bg = Basemap-Pixel $src
$COLORS = @(@(230, 40, 40), @(40, 90, 230), @(40, 200, 70), @(240, 220, 30))
function Screen-Pixel {
  $b = New-Object Drawing.Bitmap 1, 1; $g = [Drawing.Graphics]::FromImage($b)
  $g.CopyFromScreen($script:wx + $SX, $script:wy + $SY, 0, 0, (New-Object Drawing.Size 1, 1)); $g.Dispose()
  $p = $b.GetPixel(0, 0); $b.Dispose(); $p
}
function Expect-Color([int]$frame, [int]$alpha, [string]$what) {
  Start-Sleep -Milliseconds 800
  $c = $COLORS[$frame % 4]; $a = $alpha / 255
  $want = @(($bg.R * (1 - $a) + $c[0] * $a), ($bg.G * (1 - $a) + $c[1] * $a), ($bg.B * (1 - $a) + $c[2] * $a))
  $p = Screen-Pixel
  $d = [math]::Sqrt([math]::Pow($p.R - $want[0], 2) + [math]::Pow($p.G - $want[1], 2) + [math]::Pow($p.B - $want[2], 2))
  Expect ($d -lt 30) ("{0}: screen {1},{2},{3} vs expected {4:N0},{5:N0},{6:N0} (distance {7:N0})" -f $what, $p.R, $p.G, $p.B, $want[0], $want[1], $want[2], $d)
}
function Exports($since) { @(Requests | Where-Object { $_.path -like '*exportImage' -and [DateTimeOffset]::Parse($_.at) -gt $since }) }
function Queries($since) { @(Requests | Where-Object { $_.path -like '*query' -and [DateTimeOffset]::Parse($_.at) -gt $since }) }
function Trigger { Bang '!CommandMeasure' 'MeasureFrame' 'Update' 'DesktopRadarTest' }
function UtcNow { [DateTimeOffset]::UtcNow.AddMilliseconds(-200) }

$node = $null
try {
  Write-Host "Starting mock NOAA on 127.0.0.1:$Port"
  $node = Start-Process node -ArgumentList "`"$PSScriptRoot\mock-noaa.js`"", $Port -PassThru -WindowStyle Hidden
  Start-Sleep -Seconds 1; Mock 'mode=normal' | Out-Null

  # ---- temporary test copy ----
  Copy-Item $src $test -Recurse
  # Fresh runtime cache, but keep the map layers (setup itself is tested in [20]).
  Get-ChildItem (Join-Path $test 'DownloadFile') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'layer_*' } | Remove-Item -Force
  $r0 = Get-Content (Join-Path $test 'Radar.ini')
  Set-Content (Join-Path $test 'Radar.ini') ($r0 -replace '^TigerBase=.*$', "TigerBase=http://127.0.0.1:$Port/tiger") -Encoding ASCII
  Set-Content (Join-Path $test '@Resources\State.inc') "[Variables]`r`nSlot=a`r`nObsEpochMs=0`r`nLastSuccess=0" -Encoding ASCII
  $r = Get-Content (Join-Path $test 'Radar.ini')
  $r = $r -replace '^ImageServer=.*$', "ImageServer=http://127.0.0.1:$Port/ImageServer" -replace '^TickMs=.*$', 'TickMs=2000' -replace '^RetrySeconds=.*$', 'RetrySeconds=6'
  $r = $r -replace '^NWSApi=.*$', "NWSApi=http://127.0.0.1:$Port/nws"
  Set-Content (Join-Path $test 'Radar.ini') $r -Encoding ASCII
  $s = Get-Content (Join-Path $test '@Resources\Settings.inc')
  $s = $s -replace '^RefreshMinutes=.*$', 'RefreshMinutes=30' -replace '^DebugLog=.*$', 'DebugLog=1'
  $s = $s -replace '^ShowWind=.*$', 'ShowWind=1' -replace '^ShowAlerts=.*$', 'ShowAlerts=1' -replace '^AnimationEnabled=.*$', 'AnimationEnabled=1' -replace '^WindUnits=.*$', 'WindUnits=mph' -replace '^AnimLoops=.*$', 'AnimLoops=10'
  $loc = Get-Content (Join-Path $test '@Resources\Location.inc')
  if (-not ($loc | Where-Object { $_ -match '^ObsStations=\w' })) { throw 'Location.inc has no ObsStations; run tools\Update-Location.ps1 first.' }
  Set-Content (Join-Path $test '@Resources\Settings.inc') $s -Encoding ASCII
  $alpha = [int](($s | Where-Object { $_ -match '^RadarAlpha=' }) -replace '^RadarAlpha=', '')

  Write-Host "`n[1] First load: one query, one export, nothing downloaded at load"
  $t0 = UtcNow
  Bang '!RefreshApp'; Start-Sleep -Seconds 3
  Bang '!ActivateConfig' 'DesktopRadarTest' 'Radar.ini'
  Bang '!ZPos' '2' 'DesktopRadarTest'
  Start-Sleep -Seconds 1
  $sec = ''; $script:wx = 0; $script:wy = 0
  foreach ($l in Get-Content $ini) { if ($l -match '^\[(.+)\]') { $sec = $Matches[1] } elseif ($sec -eq 'DesktopRadarTest' -and $l -match '^WindowX=(-?\d+)') { $script:wx = [int]$Matches[1] } elseif ($sec -eq 'DesktopRadarTest' -and $l -match '^WindowY=(-?\d+)') { $script:wy = [int]$Matches[1] } }
  Expect ($null -ne (Wait-Log 0 'OnRadar ok slot=b')) 'first frame downloaded into slot b'
  Expect ($null -eq ((DebugLines) | Where-Object { $_ -match 'OnError' } | Select-Object -First 1)) 'no error during first load'
  Start-Sleep -Seconds 3
  Expect (@(Exports $t0).Count -eq 1) "exactly one export request (got $(@(Exports $t0).Count))"
  Expect (@(Queries $t0).Count -eq 1) "exactly one query request (got $(@(Queries $t0).Count))"
  $ua = (Requests | Select-Object -First 1).ua
  Expect ($ua -like 'DesktopRadar/*') "User-Agent is '$ua'"
  Expect ((State).Slot -eq 'b') 'State.inc Slot=b'
  Expect-Color 0 $alpha 'frame 0 (red) on screen'

  Write-Host "`n[2] Same frame again: query only, no download"
  $n = (DebugLines).Count; $t = UtcNow; Trigger
  Expect ($null -ne (Wait-Log $n 'frame unchanged')) 'skin noticed the frame is unchanged'
  Start-Sleep -Seconds 4
  Expect (@(Exports $t).Count -eq 0) "no export request (got $(@(Exports $t).Count))"

  Write-Host "`n[3] New frame: one download into the other slot"
  Mock 'advance=1&ageMin=2' | Out-Null
  $n = (DebugLines).Count; $t = UtcNow; Trigger
  Expect ($null -ne (Wait-Log $n 'OnRadar ok slot=a')) 'downloaded into slot a'
  Start-Sleep -Seconds 4
  Expect (@(Exports $t).Count -eq 1) "exactly one export request (got $(@(Exports $t).Count))"
  Expect-Color 1 $alpha 'frame 1 (blue) on screen'

  Write-Host "`n[4] Next frame reuses slot b: screen must show the NEW file, not a cached old one"
  Mock 'advance=1&ageMin=2' | Out-Null
  $n = (DebugLines).Count; $t = UtcNow; Trigger
  Expect ($null -ne (Wait-Log $n 'OnRadar ok slot=b')) 'downloaded into slot b again'
  Expect-Color 2 $alpha 'frame 2 (green) on screen'

  Write-Host "`n[5] NOAA returns HTTP 500: keep last image, one retry, no loop"
  Mock 'advance=1&ageMin=2&mode=export500' | Out-Null
  $n = (DebugLines).Count; $t = UtcNow; Trigger
  Expect ($null -ne (Wait-Log $n 'OnError')) 'error reported to the script'
  Expect ($null -ne (Wait-Log $n 'retry scheduled')) 'one retry scheduled'
  Start-Sleep -Seconds 16
  $e = @(Exports $t).Count
  Expect ($e -ge 1 -and $e -le 2) "export attempts in 16 s: $e (original + at most one retry)"
  Expect ((State).Slot -eq 'b') 'State.inc still points at the last good slot'
  Expect-Color 2 $alpha 'still frame 2 (green) on screen'

  Write-Host "`n[6] NOAA returns a JSON error with HTTP 200: rejected"
  Mock 'mode=exportjson' | Out-Null
  $n = (DebugLines).Count; Trigger
  Expect ($null -ne (Wait-Log $n 'bad image from NOAA')) 'JSON body rejected as not a PNG'
  Expect-Color 2 $alpha 'still frame 2 (green) on screen'

  Write-Host "`n[7] Truncated PNG: rejected"
  Mock 'mode=exporttruncated' | Out-Null
  $n = (DebugLines).Count; Trigger
  Expect ($null -ne (Wait-Log $n 'bad image from NOAA')) 'half a PNG rejected'
  Expect-Color 2 $alpha 'still frame 2 (green) on screen'

  Write-Host "`n[8] Query returns an error: no download attempted"
  Mock 'mode=queryerror' | Out-Null
  $n = (DebugLines).Count; $t = UtcNow; Trigger
  Expect ($null -ne (Wait-Log $n 'OnError no radar frame')) 'parse error reported'
  Start-Sleep -Seconds 3
  Expect (@(Exports $t).Count -eq 0) 'no export request'

  Write-Host "`n[9] Old frame (40 min): shown dimmed with STALE badge"
  Mock 'mode=normal&advance=1&ageMin=40' | Out-Null
  $n = (DebugLines).Count; Trigger
  Expect ($null -ne (Wait-Log $n 'OnRadar ok')) 'old frame downloaded'
  Expect ($null -ne (Wait-Log $n 'badge=STALE')) 'STALE badge shown'
  Expect-Color 4 ([math]::Floor($alpha * 0.5)) 'frame 4 (red) dimmed on screen'

  Write-Host "`n[10] Offline (connection refused): OFFLINE badge, image kept"
  Stop-Process -Id $node.Id -Force; $node = $null; Start-Sleep -Milliseconds 500
  $n = (DebugLines).Count; Trigger
  Expect ($null -ne (Wait-Log $n 'OnError offline' 40)) 'offline reported'
  Expect ($null -ne (Wait-Log $n 'badge=OFFLINE' 10)) 'OFFLINE badge shown'
  Expect-Color 4 ([math]::Floor($alpha * 0.5)) 'still frame 4 (red, dimmed) on screen'

  Write-Host "`n[11] Back online with a fresh frame: recovers, badge cleared"
  $node = Start-Process node -ArgumentList "`"$PSScriptRoot\mock-noaa.js`"", $Port -PassThru -WindowStyle Hidden
  Start-Sleep -Seconds 1
  Mock 'advance=1&ageMin=2' | Out-Null; Mock 'advance=1&ageMin=2' | Out-Null   # frame 2 -> green
  $n = (DebugLines).Count; Trigger
  Expect ($null -ne (Wait-Log $n 'OnRadar ok' 40)) 'downloaded after reconnect'
  Expect ($null -ne (Wait-Log $n 'badge= ' 10)) 'badge cleared'
  Expect-Color 2 $alpha 'frame 2 (green) on screen'

  Write-Host "`n[12] Skin restart: cached image shown at once, no re-download"
  Mock 'clear=1' | Out-Null
  $n = (DebugLines).Count; $t = UtcNow
  Bang '!Refresh' 'DesktopRadarTest'
  Expect ($null -ne (Wait-Log $n 'init .*cached=true')) 'cache found at load'
  Expect-Color 2 $alpha 'frame 2 (green) on screen right after restart'
  Start-Sleep -Seconds 5
  Expect (@(Exports $t).Count -eq 0) "no export after restart (got $(@(Exports $t).Count))"
  Expect (@(Queries $t).Count -eq 1) "one query after restart (got $(@(Queries $t).Count))"

  Write-Host "`n[14] Surface wind: nearest station has no wind, falls back to the next"
  $firstStation = (($loc | Where-Object { $_ -match '^ObsStations=' }) -replace '^ObsStations=', '').Split(',')[0]
  $w = Wait-Log 0 'wind "Wind ' 10
  Expect ($w -match 'wind "Wind ESE 14 mph"') "wind text from the fixture (120 deg, 22.2 km/h): $w"
  $obsReq = @(Requests | Where-Object { $_.path -like '*/observations/latest' } | ForEach-Object { ($_.path -split '/')[3] })
  Expect ($obsReq.Count -ge 2 -and $obsReq[0] -eq $firstStation) ("stations tried in order: " + ($obsReq -join ', '))
  $n = (DebugLines).Count
  Mock 'obsNull=KMIA,KOPF,KHWO,KTMB,KHST,KFLL' | Out-Null
  Bang '!CommandMeasure' 'MeasureWind' 'Update' 'DesktopRadarTest'
  Expect ($null -ne (Wait-Log $n 'wind "Wind --"' 20)) 'no station has wind: shows "Wind --", invents nothing'
  Mock 'obsNull=KMIA' | Out-Null

  Write-Host "`n[15] Alerts: real NWS reply with 3 alerts, then none"
  Expect ($null -ne (Wait-Log 0 'alert chip "FLOOD WATCH  \+2"' 10)) 'chip shows the most severe alert (Flood Watch, Severe) +2'
  $n = (DebugLines).Count
  Mock 'alerts=none' | Out-Null
  Bang '!CommandMeasure' 'MeasureAlerts' 'Update' 'DesktopRadarTest'
  Expect ($null -ne (Wait-Log $n 'OnAlerts count=0' 15)) 'no alerts: chip hidden'

  Write-Host "`n[16] Replay: 10 frames in the last ~47 min; downloads only what it needs"
  Mock 'seed=10&clear=1' | Out-Null
  $n = (DebugLines).Count; Trigger
  Expect ($null -ne (Wait-Log $n 'OnRadar ok')) 'live view moved to the newest seeded frame'
  $rmp = Get-Process -Id $rm.Id
  $c0 = $rmp.TotalProcessorTime.TotalMilliseconds; Start-Sleep -Seconds 10; $rmp.Refresh(); $idleMs = $rmp.TotalProcessorTime.TotalMilliseconds - $c0
  $n = (DebugLines).Count; $t = UtcNow
  Bang '!CommandMeasure' 'MeasureScript' 'AnimToggle()' 'DesktopRadarTest'
  $sel = Wait-Log $n 'anim list .* selected (\d+), cached (\d+)' 20
  Expect ($null -ne $sel) "frame list: $sel"
  Expect ($null -ne (Wait-Log $n 'anim play' 30)) 'playback started'
  $selN = [int]([regex]::Match($sel, 'selected (\d+)').Groups[1].Value); $cachedN = [int]([regex]::Match($sel, 'cached (\d+)').Groups[1].Value)
  Expect ($selN -ge 4 -and $selN -le 8) "selected $selN frames, evenly spaced (5-min source frames)"
  Expect (@(Exports $t).Count -eq ($selN - $cachedN)) "downloaded only missing frames: $(@(Exports $t).Count) = $selN selected - $cachedN cached"
  Expect (@(Queries $t).Count -eq 1 -and @(Queries $t)[0].count -eq '16') 'one frame-list query'
  Start-Sleep -Milliseconds 500
  $tp = [DateTimeOffset]::UtcNow
  $rmp.Refresh(); $c1 = $rmp.TotalProcessorTime.TotalMilliseconds
  $changes = 0; $prev = $null
  for ($i = 0; $i -lt 20; $i++) { $p = Screen-Pixel; $k = "$([math]::Round($p.R/40)),$([math]::Round($p.G/40)),$([math]::Round($p.B/40))"; if ($prev -and $k -ne $prev) { $changes++ }; $prev = $k; Start-Sleep -Milliseconds 500 }
  $rmp.Refresh(); $playMs = $rmp.TotalProcessorTime.TotalMilliseconds - $c1
  Expect ($changes -ge 4) "frame on screen changed $changes times in 10 s of sampling"
  Expect (@(Exports $t | Where-Object { [DateTimeOffset]::Parse($_.at) -gt $tp }).Count -eq 0) 'no downloads during playback'
  Write-Host ("        Rainmeter CPU: idle {0:N0} ms per 10 s, replay {1:N0} ms per 10 s (whole process, all skins)" -f $idleMs, $playMs) -ForegroundColor Cyan

  Write-Host "`n[17] Pause freezes the frame; play resumes; replay ends by itself"
  $n = (DebugLines).Count
  Bang '!CommandMeasure' 'MeasureScript' 'AnimToggle()' 'DesktopRadarTest'
  Expect ($null -ne (Wait-Log $n 'anim pause' 5)) 'paused'
  $p1 = Screen-Pixel; Start-Sleep -Seconds 2; $p2 = Screen-Pixel
  Expect ($p1.ToArgb() -eq $p2.ToArgb()) 'frame frozen while paused'
  Bang '!CommandMeasure' 'MeasureScript' 'AnimToggle()' 'DesktopRadarTest'
  Expect ($null -ne (Wait-Log $n 'anim resume' 5)) 'resumed'
  Expect ($null -ne (Wait-Log $n 'anim stop \(done\)' 60)) 'stopped by itself after AnimLoops'
  Expect-Color 9 $alpha 'back to the live (newest) frame'

  Write-Host "`n[18] Second replay within 3 minutes reuses cached frames: no requests"
  $n = (DebugLines).Count; $t = UtcNow
  Bang '!CommandMeasure' 'MeasureScript' 'AnimToggle()' 'DesktopRadarTest'
  Expect ($null -ne (Wait-Log $n 'anim reuse cached frames' 5)) 'cached frames reused'
  Start-Sleep -Seconds 2
  Expect ((@(Exports $t).Count + @(Queries $t).Count) -eq 0) 'no network requests'
  Bang '!CommandMeasure' 'MeasureScript' "AnimStop('stopped')" 'DesktopRadarTest'
  $animFiles = @(Get-ChildItem (Join-Path $test 'DownloadFile') -Filter 'anim_*.png')
  Expect ($animFiles.Count -le 8) "replay cache on disk: $($animFiles.Count) files, $([math]::Round((($animFiles | Measure-Object Length -Sum).Sum)/1KB)) KB"

  Write-Host "`n[19] Extras switched off: no wind/alert requests, no play button"
  $s2 = Get-Content (Join-Path $test '@Resources\Settings.inc')
  $s2 = $s2 -replace '^ShowWind=.*$', 'ShowWind=0' -replace '^ShowAlerts=.*$', 'ShowAlerts=0' -replace '^AnimationEnabled=.*$', 'AnimationEnabled=0'
  Set-Content (Join-Path $test '@Resources\Settings.inc') $s2 -Encoding ASCII
  Mock 'clear=1&alerts=fixture' | Out-Null
  $n = (DebugLines).Count
  Bang '!Refresh' 'DesktopRadarTest'
  Expect ($null -ne (Wait-Log $n 'init .*wind=false alerts=false anim=false' 10)) 'modules report off'
  Start-Sleep -Seconds 6
  $nws = @(Requests | Where-Object { $_.path -like '/nws/*' })
  Expect ($nws.Count -eq 0) "no api.weather.gov requests (got $($nws.Count))"
  Expect-Color 9 $alpha 'radar unaffected'

  Write-Host "`n[20] First-time setup inside the skin (no PowerShell): region, stations, map layers"
  $s3 = $s2 -replace '^ShowWind=.*$', 'ShowWind=1' -replace '^ShowAlerts=.*$', 'ShowAlerts=1'
  Set-Content (Join-Path $test '@Resources\Settings.inc') $s3 -Encoding ASCII
  Set-Content (Join-Path $test '@Resources\Location.inc') "[Variables]`r`nGeneratedFor=" -Encoding ASCII
  Get-ChildItem (Join-Path $test 'DownloadFile') -Filter 'layer_*' | Remove-Item -Force
  Mock 'clear=1' | Out-Null
  $n = (DebugLines).Count
  Bang '!Refresh' 'DesktopRadarTest'
  Expect ($null -ne (Wait-Log $n 'setup: Location ready' 40)) 'setup finished'
  Expect ($null -ne (Wait-Log $n 'init .*mismatch=false' 15)) 'skin refreshed itself with the new location'
  $L2 = Read-IncVariablesLocal (Join-Path $test '@Resources\Location.inc')
  $Lps = @{}; foreach ($l in $loc) { if ($l -match '^(\w+)=(.*)$') { $Lps[$Matches[1]] = $Matches[2] } }
  $b1 = $L2.BBox -split ',' | ForEach-Object { [double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) }
  $b2 = $Lps.BBox -split ',' | ForEach-Object { [double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) }
  $dmax = (0..3 | ForEach-Object { [math]::Abs($b1[$_] - $b2[$_]) } | Measure-Object -Maximum).Maximum
  Expect ($dmax -lt 0.2) "Lua map box matches the PowerShell one within $([math]::Round($dmax, 2)) m"
  Expect ($L2.Region -eq 'CONUS') "radar region: $($L2.Region)"
  Expect ($L2.RadarStation -eq 'KAMX' -and $L2.NWSRadarURL -like '*station/KAMX/standard') "radar station: $($L2.RadarStation)"
  Expect ($L2.ObsStations -eq 'KMIA,KOPF,KHWO' -and $L2.WindStation -eq 'KMIA') "wind stations: $($L2.ObsStations) (first 3 of 4)"
  Expect ($L2.AlertPoint -eq '25.7617,-80.1918') "alert point: $($L2.AlertPoint)"
  $req = Requests
  Expect (@($req | Where-Object { $_.path -like '/tiger/*/export' }).Count -eq 4) 'four map layers downloaded'
  Expect (@(Get-ChildItem (Join-Path $test 'DownloadFile') -Filter 'layer_*.png').Count -eq 4) 'four layer files on disk'
  Expect ($null -ne (Wait-Log $n 'OnRadar ok' 20)) 'radar downloaded for the new location'
  $bg = Basemap-Pixel $test
  Expect-Color 9 $alpha 'radar drawn over the freshly downloaded map'

  Write-Host "`n[21] Location outside NOAA coverage: clear message, no radar requests"
  Mock 'coverage=0&clear=1' | Out-Null
  Set-Content (Join-Path $test '@Resources\Settings.inc') ($s3 -replace '^Latitude=.*$', 'Latitude=51.5074' -replace '^Longitude=.*$', 'Longitude=-0.1278') -Encoding ASCII
  $n = (DebugLines).Count
  Bang '!Refresh' 'DesktopRadarTest'
  Expect ($null -ne (Wait-Log $n 'setup: No NOAA radar covers this location' 20)) 'says no NOAA radar covers it'
  Start-Sleep -Seconds 4
  Expect (@(Requests | Where-Object { $_.path -like '*exportImage' -or $_.path -like '/tiger/*' -or $_.path -like '/nws/*' }).Count -eq 0) 'no image, map or NWS requests'
  Mock 'coverage=1' | Out-Null
  Set-Content (Join-Path $test '@Resources\Settings.inc') $s3 -Encoding ASCII

  if (-not $SkipSuspend) {
    Write-Host "`n[13] Sleep/resume simulation: Rainmeter frozen 10 s, then resumed"
    Add-Type -Namespace Win -Name Proc -MemberDefinition '[DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h); [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);'
    $n = (DebugLines).Count
    $h = (Get-Process -Id $rm.Id).Handle
    [void][Win.Proc]::NtSuspendProcess($h)
    try { Start-Sleep -Seconds 10 } finally { [void][Win.Proc]::NtResumeProcess($h) }
    Expect ($null -ne (Wait-Log $n 'resume detected' 10)) 'long tick gap detected as resume'
    Expect ($null -ne (Wait-Log $n 'retry scheduled in 30s \(resume\)' 5)) 'one check scheduled 30 s after resume'
  }
}
finally {
  Write-Host "`nCleaning up"
  # Keep the evidence: the skin's debug log and the mock's request log.
  $keep = Join-Path ([IO.Path]::GetTempPath()) 'DesktopRadarTest-logs'
  New-Item -ItemType Directory -Force $keep | Out-Null
  if (Test-Path $dbg) { Copy-Item $dbg (Join-Path $keep 'debug.log') -Force }
  try { Requests | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $keep 'requests.json') -Encoding UTF8 } catch {}
  Write-Host "Logs kept in $keep"
  try { & $exe '!DeactivateConfig' 'DesktopRadarTest'; Start-Sleep -Seconds 2 } catch {}
  if (Test-Path $test) { Remove-Item $test -Recurse -Force }
  try { & $exe '!RefreshApp' } catch {}
  if ($node) { Stop-Process -Id $node.Id -Force -ErrorAction SilentlyContinue }
}
Write-Host ("`n{0} passed, {1} failed" -f $script:passes, $script:fails) -ForegroundColor $(if ($script:fails) { 'Red' } else { 'Green' })
if ($script:fails) { exit 1 }
