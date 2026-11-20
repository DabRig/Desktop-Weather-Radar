# Shared helpers for DesktopRadar scripts (dot-source this file). PowerShell 5.1 compatible.

$RadarUserAgent = 'DesktopRadar/0.1 (personal Rainmeter widget)'
$RadarImageServer = 'https://mapservices.weather.noaa.gov/eventdriven/rest/services/radar/radar_base_reflectivity_time/ImageServer'
$Inv = [Globalization.CultureInfo]::InvariantCulture

function Read-IncVariables([string]$Path) {
  $h = @{}
  foreach ($l in Get-Content -LiteralPath $Path) {
    if ($l -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$') { $h[$Matches[1]] = $Matches[2] }
  }
  $h
}

function Read-RadarSettings([string]$Path) {
  $v = Read-IncVariables $Path
  $errs = @()
  $num = {
    param($name, $min, $max)
    $x = 0.0
    if (-not $v.ContainsKey($name) -or -not [double]::TryParse($v[$name], [Globalization.NumberStyles]::Float, $Inv, [ref]$x)) { $script:errs += "$name is missing or not a number"; return $null }
    if ($x -lt $min -or $x -gt $max) { $script:errs += "$name=$x is outside $min..$max" }
    $x
  }
  $script:errs = @()
  $o = [pscustomobject]@{
    LocationName = $v['LocationName']
    Latitude = $v['Latitude']; Longitude = $v['Longitude']; RadiusKm = $v['RadiusKm']; SizeText = $v['Size']
    Lat = (& $num 'Latitude' -85 85); Lon = (& $num 'Longitude' -180 180)
    Radius = (& $num 'RadiusKm' 25 500); Size = [int](& $num 'Size' 250 400)
    RefreshMinutes = (& $num 'RefreshMinutes' 5 60); StaleMinutes = (& $num 'StaleMinutes' 10 240)
    RadarAlpha = (& $num 'RadarAlpha' 0 255)
  }
  if ($script:errs.Count) { throw ("Settings.inc problems:`n  " + ($script:errs -join "`n  ")) }
  $o
}

# Square box in Web Mercator metres. Mercator stretches distances by 1/cos(lat),
# so the half-width in map units is radius / cos(lat) to cover RadiusKm on the ground.
function Get-MercatorBBox([double]$Latitude, [double]$Longitude, [double]$RadiusKm) {
  $R = 6378137.0
  $x = $R * $Longitude * [math]::PI / 180
  $y = $R * [math]::Log([math]::Tan([math]::PI / 4 + $Latitude * [math]::PI / 360))
  $h = $RadiusKm * 1000 / [math]::Cos($Latitude * [math]::PI / 180)
  , @(($x - $h), ($y - $h), ($x + $h), ($y + $h))
}

function ConvertFrom-Mercator([double]$X, [double]$Y) {
  $R = 6378137.0
  [pscustomobject]@{ Lon = $X / $R * 180 / [math]::PI; Lat = (2 * [math]::Atan([math]::Exp($Y / $R)) - [math]::PI / 2) * 180 / [math]::PI }
}

function Get-RadarRegion([double]$Latitude, [double]$Longitude) {
  $q = @{
    geometry = ('{0},{1}' -f $Longitude.ToString($Inv), $Latitude.ToString($Inv)); geometryType = 'esriGeometryPoint'; inSR = '4326'
    spatialRel = 'esriSpatialRelIntersects'; where = '1=1'; outFields = 'name,idp_validtime'
    orderByFields = 'idp_validtime DESC'; resultRecordCount = '1'; returnGeometry = 'false'; f = 'json'
  }
  $r = Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 -UserAgent $RadarUserAgent -Uri "$RadarImageServer/query" -Body $q
  if ($r.error) { throw "NOAA query error: $($r.error.message)" }
  if (-not $r.features -or -not $r.features.Count) { throw 'No NOAA radar mosaic covers this location (the service covers the US, Alaska, Hawaii, the Caribbean and Guam).' }
  ($r.features[0].attributes.name -split '_')[0]
}

# Downloads an ArcGIS export image. ArcGIS reports errors as JSON with HTTP 200,
# so the PNG signature is checked before the file is accepted.
function Save-ArcGisImage([string]$Url, [hashtable]$Query, [string]$OutFile) {
  try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -UserAgent $RadarUserAgent -Uri $Url -Body $Query -OutFile $OutFile } catch { return $false }
  Test-PngFile $OutFile
}

function Test-PngFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $fs = [IO.File]::OpenRead($Path)
  try { $b = New-Object byte[] 8; $n = $fs.Read($b, 0, 8) } finally { $fs.Dispose() }
  ($n -eq 8) -and ((($b | ForEach-Object { $_.ToString('X2') }) -join '') -eq '89504E470D0A1A0A')
}

# Paints every non-transparent pixel of a layer with one colour, keeping its alpha.
function Add-TintedLayer($Graphics, [string]$Path, [int[]]$Rgb, [double]$Alpha, [int]$Size) {
  $im = [Drawing.Image]::FromFile($Path)
  try {
    $cm = New-Object Drawing.Imaging.ColorMatrix
    $cm.Matrix00 = 0; $cm.Matrix11 = 0; $cm.Matrix22 = 0
    $cm.Matrix40 = $Rgb[0] / 255; $cm.Matrix41 = $Rgb[1] / 255; $cm.Matrix42 = $Rgb[2] / 255
    $cm.Matrix33 = $Alpha
    $ia = New-Object Drawing.Imaging.ImageAttributes
    $ia.SetColorMatrix($cm)
    $Graphics.DrawImage($im, (New-Object Drawing.Rectangle 0, 0, $Size, $Size), 0, 0, $im.Width, $im.Height, [Drawing.GraphicsUnit]::Pixel, $ia)
    $ia.Dispose()
  } finally { $im.Dispose() }
}

function Write-AsciiFile([string]$Path, [string[]]$Lines) {
  [IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
}
