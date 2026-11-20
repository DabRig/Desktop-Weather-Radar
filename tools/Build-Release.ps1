<#
.SYNOPSIS
  Builds release\DesktopRadar_<version>.rmskin, the double-click installer Rainmeter users expect.

.DESCRIPTION
  The package holds only source files plus empty Location.inc / State.inc, so each user's
  copy sets itself up on first load. Settings.inc is listed under VariableFiles, so
  upgrading keeps a user's own settings.

  .rmskin format: a zip containing RMSKIN.ini and Skins\<name>\..., followed by a 16-byte
  footer: the zip size (8 bytes, little-endian), a flags byte (0), and "RMSKIN" plus a NUL.
#>
[CmdletBinding()]
param([string]$Version, [string]$SkinName = 'DesktopRadar')   # SkinName: only for install tests
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$skin = Join-Path $root 'skin\DesktopRadar'
if (-not $Version) { $Version = ((Get-Content (Join-Path $skin 'Radar.ini')) -match '^Version=' | Select-Object -First 1) -replace '^Version=', '' }
$outDir = Join-Path $root 'release'
$out = Join-Path $outDir "$($SkinName)_$Version.rmskin"

# Published path inside the package -> source file
$files = [ordered]@{
  "Skins/$SkinName/Radar.ini" = Join-Path $skin 'Radar.ini'
  "Skins/$SkinName/@Resources/Radar.lua" = Join-Path $skin '@Resources\Radar.lua'
  "Skins/$SkinName/@Resources/Settings.inc" = Join-Path $skin '@Resources\Settings.inc'
  "Skins/$SkinName/@Resources/Location.inc" = Join-Path $root 'release\defaults\Location.inc'
  "Skins/$SkinName/@Resources/State.inc" = Join-Path $root 'release\defaults\State.inc'
  "Skins/$SkinName/@Resources/Images/blank.png" = Join-Path $skin '@Resources\Images\blank.png'
}
$rmskinIni = @"
[rmskin]
Name=$SkinName
Author=DabRig
Version=$Version
MinimumRainmeter=4.5.0
MinimumWindows=6.1
LoadType=Skin
Load=$SkinName\Radar.ini
VariableFiles=$SkinName\@Resources\Settings.inc
"@

# Guard: the shipped settings must be the public defaults.
$set = Get-Content $files["Skins/$SkinName/@Resources/Settings.inc"]
if (-not ($set -match '^DebugLog=0$')) { throw 'Settings.inc must ship with DebugLog=0' }
foreach ($f in $files.Values) { if (-not (Test-Path $f)) { throw "Missing $f" } }

New-Item -ItemType Directory -Force $outDir | Out-Null
$zipPath = "$out.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath }
$zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
  $e = $zip.CreateEntry('RMSKIN.ini')
  $w = New-Object IO.StreamWriter($e.Open(), (New-Object Text.UTF8Encoding($false)))
  $w.Write(($rmskinIni -replace "`r?`n", "`r`n")); $w.Dispose()
  foreach ($k in $files.Keys) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $files[$k], $k) }
} finally { $zip.Dispose() }

$bytes = [IO.File]::ReadAllBytes($zipPath)
$footer = New-Object byte[] 16
[BitConverter]::GetBytes([long]$bytes.Length).CopyTo($footer, 0)
$footer[8] = 0
[Text.Encoding]::ASCII.GetBytes('RMSKIN').CopyTo($footer, 9)   # byte 15 stays 0 (NUL)
$fs = [IO.File]::Create($out)
try { $fs.Write($bytes, 0, $bytes.Length); $fs.Write($footer, 0, 16) } finally { $fs.Dispose() }
Remove-Item $zipPath

$hash = (Get-FileHash $out -Algorithm SHA256).Hash
Write-Host "Built $out ($((Get-Item $out).Length) bytes)"
Write-Host "SHA256 $hash"
$zip = [IO.Compression.ZipFile]::OpenRead($out)
try { $zip.Entries | ForEach-Object { Write-Host ("  {0,-50} {1,7} B" -f $_.FullName, $_.Length) } } finally { $zip.Dispose() }
