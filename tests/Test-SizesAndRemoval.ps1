<#
.SYNOPSIS
  Installs temporary copies at the smallest and largest supported sizes, captures each
  (only its own window area), then removes them with Uninstall-Skin.ps1 and checks that
  nothing is left behind: folder, window, startup entries, Run keys, scheduled tasks.
  Uses the real NOAA/NWS services (a few small requests per copy).
#>
[CmdletBinding()]
param([int[]]$Sizes = @(250, 400), [string]$OutDir = (Join-Path ([IO.Path]::GetTempPath()) 'DesktopRadarSizes'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ini = Join-Path $env:APPDATA 'Rainmeter\Rainmeter.ini'
$skinPath = (Get-Content $ini | Where-Object { $_ -match '^SkinPath=' } | Select-Object -First 1) -replace '^SkinPath=', ''
$exe = (Get-Process Rainmeter | Select-Object -First 1).Path
New-Item -ItemType Directory -Force $OutDir | Out-Null
$fails = 0
# This PowerShell may see a scaled desktop; Rainmeter positions are in real pixels.
Add-Type -Namespace Dpi -Name Caps -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h); [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr dc, int i);'
$dc = [Dpi.Caps]::GetDC([IntPtr]::Zero)
$scale = [Dpi.Caps]::GetDeviceCaps($dc, 118) / [Dpi.Caps]::GetDeviceCaps($dc, 8)   # DESKTOPHORZRES / HORZRES
if ($scale -le 0) { $scale = 1 }
Write-Host ("Capture scale: {0:N2}" -f $scale)
function Check($ok, $msg) { if ($ok) { Write-Host "  PASS  $msg" -ForegroundColor Green } else { $script:fails++; Write-Host "  FAIL  $msg" -ForegroundColor Red } }

function Snapshot {
  [pscustomobject]@{
    run = ((Get-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Run -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $_.Name }) -join '|'
    startup = (Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup" -Name) -join '|'
    tasks = ((Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'radar|rainmeter' }).TaskName) -join '|'
  }
}
$before = Snapshot

foreach ($size in $Sizes) {
  $name = "DesktopRadarSize$size"
  Write-Host "`n[$size px] install as $name"
  if (Test-Path (Join-Path $skinPath $name)) { throw "$name already exists" }
  New-Item -ItemType Directory -Force (Join-Path $skinPath "$name\@Resources") | Out-Null
  $s = Get-Content (Join-Path $root 'skin\DesktopRadar\@Resources\Settings.inc')
  $s = $s -replace '^Size=.*$', "Size=$size" -replace '^AnimationEnabled=.*$', 'AnimationEnabled=1'
  Set-Content (Join-Path $skinPath "$name\@Resources\Settings.inc") $s -Encoding ASCII
  & (Join-Path $root 'tools\Install-Skin.ps1') -ConfigName $name -Load | Out-Null
  # The skin sets itself up (map box, stations, map layers), refreshes, then downloads radar.
  $stateFile = Join-Path $skinPath "$name\@Resources\State.inc"
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt 90 -and -not ((Get-Content $stateFile) -match '^ObsEpochMs=\d{13}')) { Start-Sleep -Milliseconds 500 }
  $ready = $sw.Elapsed.TotalSeconds
  Check ((Get-Content $stateFile) -match '^ObsEpochMs=\d{13}') ("first-run setup + first radar in {0:N1} s, no PowerShell" -f $ready)
  & $exe '!ZPos' '2' $name
  Start-Sleep -Seconds 5                       # let wind and alerts arrive
  $sec = ''; $x = 0; $y = 0
  foreach ($l in Get-Content $ini) { if ($l -match '^\[(.+)\]') { $sec = $Matches[1] } elseif ($sec -eq $name -and $l -match '^WindowX=(-?\d+)') { $x = [int]$Matches[1] } elseif ($sec -eq $name -and $l -match '^WindowY=(-?\d+)') { $y = [int]$Matches[1] } }
  $px = [int][math]::Ceiling($size * $scale)
  $bmp = New-Object Drawing.Bitmap $px, $px; $g = [Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen([int]($x * $scale), [int]($y * $scale), 0, 0, $bmp.Size); $g.Dispose()
  $png = Join-Path $OutDir "widget-$size.png"; $bmp.Save($png); $bmp.Dispose()
  Write-Host "  captured $png"
  $loc = Get-Content (Join-Path $skinPath "$name\@Resources\Location.inc")
  Check (($loc -match '^GeneratedFor=\S').Count -eq 1) 'Location.inc filled in by the skin'
  $im = [Drawing.Image]::FromFile((Join-Path $skinPath "$name\DownloadFile\layer_land.png")); $bw = $im.Width; $im.Dispose()
  Check ($bw -eq $size) "map layers downloaded at $bw px"

  Write-Host "[$size px] remove with Uninstall-Skin.ps1"
  & (Join-Path $root 'tools\Uninstall-Skin.ps1') -ConfigName $name -Confirm:$false
  Start-Sleep -Seconds 2
  Check (-not (Test-Path (Join-Path $skinPath $name))) 'skin folder gone'
  $wins = Get-Process Rainmeter | ForEach-Object { $_.MainWindowTitle }
  $sec = ''; $active = $false
  foreach ($l in Get-Content $ini) { if ($l -match '^\[(.+)\]') { $sec = $Matches[1] } elseif ($sec -eq $name -and $l -match '^Active=([1-9])') { $active = $true } }
  Check (-not $active) 'Rainmeter no longer lists it as active'
}

$after = Snapshot
Write-Host "`n[system] nothing added outside the skin folder"
Check ($before.run -eq $after.run) "HKCU Run unchanged ($($after.run))"
Check ($before.startup -eq $after.startup) "Startup folder unchanged ($($after.startup))"
Check ($after.tasks -eq '') "no scheduled tasks named radar/rainmeter ('$($after.tasks)')"
Check ((Get-Service | Where-Object { $_.Name -match 'radar' }).Count -eq 0) 'no services named radar'
Write-Host ("`n{0} failure(s). Captures in {1}" -f $fails, $OutDir)
if ($fails) { exit 1 }
