<#
.SYNOPSIS
  Checks DesktopRadar's data source, configuration and geometry. Makes a handful of
  small HTTP requests to NOAA and the Census. Changes nothing except a temp folder.

.PARAMETER SkinDir
  Skin folder to check (defaults to the project copy). Point it at the installed copy
  to also check the runtime cache.
#>
[CmdletBinding()]
param([string]$SkinDir)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\RadarCommon.ps1')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Drawing
if (-not $SkinDir) { $SkinDir = Join-Path $PSScriptRoot '..\skin\DesktopRadar' }
$SkinDir = (Resolve-Path $SkinDir).Path
$res = Join-Path $SkinDir '@Resources'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('DesktopRadarTest_' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $tmp | Out-Null

$script:fail = 0
function Check([string]$Name, [scriptblock]$Test) {
  try { $detail = & $Test; Write-Host ("PASS  {0}  {1}" -f $Name, $detail) -ForegroundColor Green }
  catch { $script:fail++; Write-Host ("FAIL  {0}  {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red }
}
function Assert($cond, [string]$msg) { if (-not $cond) { throw $msg } }

$s = $null; $loc = $null
Check 'config: Settings.inc parses and is in range' { $script:s = Read-RadarSettings (Join-Path $res 'Settings.inc'); "$($s.LocationName) r=$($s.RadiusKm)km size=$($s.Size)" }
Check 'config: Location.inc matches Settings.inc' {
  $script:loc = Read-IncVariables (Join-Path $res 'Location.inc')
  $want = '{0},{1},{2},{3}' -f $s.Latitude, $s.Longitude, $s.RadiusKm, $s.SizeText
  Assert ($loc.GeneratedFor -eq $want) "GeneratedFor=$($loc.GeneratedFor), settings=$want. Run tools\Update-Location.ps1"
  "region=$($loc.Region) station=$($loc.RadarStation)"
}
Check 'geometry: bbox is centred on the location' {
  $b = $loc.BBox -split ',' | ForEach-Object { [double]::Parse($_, $Inv) }
  $c = ConvertFrom-Mercator (($b[0] + $b[2]) / 2) (($b[1] + $b[3]) / 2)
  Assert ([math]::Abs($c.Lat - $s.Lat) -lt 1e-5 -and [math]::Abs($c.Lon - $s.Lon) -lt 1e-5) "centre is $($c.Lat),$($c.Lon)"
  Assert ([math]::Abs(($b[2] - $b[0]) - ($b[3] - $b[1])) -lt 1) 'bbox is not square'
  ('centre {0:N5},{1:N5}' -f $c.Lat, $c.Lon)
}
Check 'geometry: east-west ground width equals 2 x radius' {
  $b = $loc.BBox -split ',' | ForEach-Object { [double]::Parse($_, $Inv) }
  $w = ConvertFrom-Mercator $b[0] 0; $e = ConvertFrom-Mercator $b[2] 0
  # Haversine along the centre latitude
  $R = 6371.0088; $phi = $s.Lat * [math]::PI / 180; $dl = ($e.Lon - $w.Lon) * [math]::PI / 180
  $a = [math]::Cos($phi) * [math]::Cos($phi) * [math]::Pow([math]::Sin($dl / 2), 2)
  $km = 2 * $R * [math]::Asin([math]::Sqrt($a))
  Assert ([math]::Abs($km - 2 * $s.Radius) / (2 * $s.Radius) -lt 0.01) "width $km km"
  ('{0:N1} km' -f $km)
}

$frameJson = $null; $ms = $null
Check 'NOAA: newest frame time (same regex as the skin)' {
  $u = "$RadarImageServer/query?where=name+LIKE+%27$($loc.Region)%25%27&outFields=idp_validtime&orderByFields=idp_validtime+DESC&resultRecordCount=1&returnGeometry=false&f=json"
  $script:frameJson = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -UserAgent $RadarUserAgent -Uri $u).Content
  # Read the regex straight from the skin so the test checks what Rainmeter runs.
  $rx = (Get-Content (Join-Path $SkinDir 'Radar.ini') | Where-Object { $_ -match '^RegExp=' } | Select-Object -First 1) -replace '^RegExp=', ''
  $m = [regex]::Match($frameJson, $rx)
  Assert ($m.Groups[1].Value.Length -eq 13) "skin regex captured '$($m.Groups[1].Value)' (expected 13 digits)"
  Assert $m.Success "no idp_validtime in reply: $($frameJson.Substring(0, [math]::Min(200, $frameJson.Length)))"
  $script:ms = [double]$m.Groups[1].Value
  $t = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms)
  $age = ([DateTimeOffset]::UtcNow - $t).TotalMinutes
  Assert ($age -lt 30 -and $age -gt -5) ("frame is {0:N1} min old" -f $age)
  ('{0:u} UTC = {1:t} local, {2:N1} min old' -f $t.UtcDateTime, $t.LocalDateTime, $age)
}
Check 'timestamps: regex rejects an ArcGIS error reply' {
  $err = '{"error":{"code":400,"message":"Failed to execute query.","details":[]}}'
  $rx = (Get-Content (Join-Path $SkinDir 'Radar.ini') | Where-Object { $_ -match '^RegExp=' } | Select-Object -First 1) -replace '^RegExp=', ''
  Assert (-not [regex]::IsMatch($err, $rx)) 'error JSON matched'
  'ok'
}
$radarFile = Join-Path $tmp 'radar.png'
Check 'NOAA: export for that frame is a PNG of the right size' {
  $u = "$RadarImageServer/exportImage?bbox=$($loc.BBox)&bboxSR=3857&imageSR=3857&size=$($s.Size),$($s.Size)&format=png32&transparent=true&interpolation=RSP_NearestNeighbor&f=image&time=$('{0:0}' -f $ms)"
  $sw = [Diagnostics.Stopwatch]::StartNew()
  Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -UserAgent $RadarUserAgent -Uri $u -OutFile $radarFile
  $sw.Stop()
  Assert (Test-PngFile $radarFile) 'not a PNG'
  $im = [Drawing.Image]::FromFile($radarFile); try { $wh = "$($im.Width)x$($im.Height)"; $fmt = $im.PixelFormat } finally { $im.Dispose() }
  Assert ($wh -eq "$($s.Size)x$($s.Size)") "size $wh"
  ('{0} {1} {2:N0} bytes in {3} ms' -f $wh, $fmt, (Get-Item $radarFile).Length, $sw.ElapsedMilliseconds)
}
Check 'alignment: radar and basemap services return the identical extent' {
  $q = "bbox=$($loc.BBox)&bboxSR=3857&imageSR=3857&size=$($s.Size),$($s.Size)&f=json"
  $r = Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 -UserAgent $RadarUserAgent -Uri "$RadarImageServer/exportImage?$q&format=png32"
  $m = Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 -UserAgent $RadarUserAgent -Uri "https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/USLandmass/MapServer/export?$q&format=png32&layers=show:0"
  $b = $loc.BBox -split ',' | ForEach-Object { [double]::Parse($_, $Inv) }
  foreach ($e in @($r.extent, $m.extent)) {
    $d = @([math]::Abs($e.xmin - $b[0]), [math]::Abs($e.ymin - $b[1]), [math]::Abs($e.xmax - $b[2]), [math]::Abs($e.ymax - $b[3])) | Measure-Object -Maximum
    Assert ($d.Maximum -lt 1) "extent differs by $($d.Maximum) m"
    Assert ($e.spatialReference.latestWkid -eq 3857) "SR $($e.spatialReference.latestWkid)"
  }
  ('both {0}x{1}, EPSG:3857, within 1 m of requested box' -f $r.width, $r.height)
}
Check 'fallback: an ArcGIS error body is rejected as "not a PNG"' {
  $bad = Join-Path $tmp 'bad.png'; [IO.File]::WriteAllText($bad, '{"error":{"code":500}}')
  Assert (-not (Test-PngFile $bad)) 'error body accepted'
  'ok'
}
Check 'link: NWS radar page answers' {
  $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -UserAgent $RadarUserAgent -Uri $loc.NWSRadarURL -Method Head
  "HTTP $($r.StatusCode) $($loc.NWSRadarURL)"
}
Check 'assets: map layers and blank image present' {
  Assert (Test-PngFile (Join-Path $res 'Images\blank.png')) 'blank.png missing'
  $out = @()
  foreach ($n in 'land', 'water', 'counties', 'roads') {
    $f = Join-Path $SkinDir "DownloadFile\layer_$n.png"
    Assert (Test-PngFile $f) "layer_$n.png missing (the skin downloads it on first load)"
    $im = [Drawing.Image]::FromFile($f); try { $wh = "$($im.Width)x$($im.Height)" } finally { $im.Dispose() }
    Assert ($wh -eq "$($s.Size)x$($s.Size)") "layer_$n is $wh"
    $out += "$n $wh"
  }
  $out -join ', '
}
$cache = Join-Path $SkinDir 'DownloadFile'
if (Test-Path $cache) {
  Check 'runtime: cached slot in State.inc is a valid PNG' {
    $st = Read-IncVariables (Join-Path $res 'State.inc')
    $f = Join-Path $cache "radar_$($st.Slot).png"
    Assert (Test-PngFile $f) "$f invalid"
    $t = [DateTimeOffset]::FromUnixTimeMilliseconds([long][double]$st.ObsEpochMs)
    "slot $($st.Slot), observation $('{0:t}' -f $t.LocalDateTime)"
  }
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
if ($script:fail) { Write-Host "$script:fail check(s) failed." -ForegroundColor Red; exit 1 } else { Write-Host 'All checks passed.' -ForegroundColor Green }
