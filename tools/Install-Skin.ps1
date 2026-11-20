<#
.SYNOPSIS
  Copies the DesktopRadar skin into your Rainmeter skins folder and (optionally) loads it.

.DESCRIPTION
  Reads SkinPath from %APPDATA%\Rainmeter\Rainmeter.ini (read only), copies the skin to
  <SkinPath>\DesktopRadar, keeps an existing Settings.inc and runtime cache, runs
  Update-Location.ps1 on the installed copy, and with -Load asks Rainmeter to load it.
  No admin rights, registry changes, services or scheduled tasks.

.PARAMETER Load
  Ask Rainmeter to refresh its skin list and load DesktopRadar.
.PARAMETER ResetSettings
  Overwrite an existing installed Settings.inc with the project's copy.
#>
[CmdletBinding()]
param([switch]$Load, [switch]$ResetSettings, [string]$ConfigName = 'DesktopRadar')
$ErrorActionPreference = 'Stop'
if ($ConfigName -notmatch '^[A-Za-z0-9_-]+$') { throw "ConfigName must be letters, digits, - or _" }

$src = (Resolve-Path (Join-Path $PSScriptRoot '..\skin\DesktopRadar')).Path
$ini = Join-Path $env:APPDATA 'Rainmeter\Rainmeter.ini'
if (-not (Test-Path $ini)) { throw "Rainmeter settings not found at $ini. Is Rainmeter installed and has it run once?" }
$skinPath = (Get-Content $ini | Where-Object { $_ -match '^SkinPath=' } | Select-Object -First 1) -replace '^SkinPath=', ''
if (-not $skinPath) { $skinPath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Rainmeter\Skins\' }
$dst = Join-Path $skinPath $ConfigName
Write-Host "Installing to $dst"

New-Item -ItemType Directory -Force (Join-Path $dst '@Resources\Images') | Out-Null
Copy-Item (Join-Path $src 'Radar.ini') $dst -Force
Copy-Item (Join-Path $src '@Resources\Radar.lua') (Join-Path $dst '@Resources') -Force
Copy-Item (Join-Path $src '@Resources\Images\blank.png') (Join-Path $dst '@Resources\Images') -Force
$dstSettings = Join-Path $dst '@Resources\Settings.inc'
if ($ResetSettings -or -not (Test-Path $dstSettings)) { Copy-Item (Join-Path $src '@Resources\Settings.inc') $dstSettings -Force }
else { Write-Host 'Kept your existing Settings.inc (use -ResetSettings to replace it).' }
# Location.inc and State.inc are filled in by the skin itself; only create empty ones.
foreach ($f in 'Location.inc', 'State.inc') {
  $p = Join-Path $dst "@Resources\$f"
  if (-not (Test-Path $p)) { Copy-Item (Join-Path $src "..\..\release\defaults\$f") $p }
}

if ($Load) {
  $exe = Join-Path $env:ProgramFiles 'Rainmeter\Rainmeter.exe'
  $running = Get-Process Rainmeter -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($running -and $running.Path) { $exe = $running.Path }
  if (-not (Test-Path $exe)) { throw "Rainmeter.exe not found at $exe" }
  & $exe '!RefreshApp'
  Start-Sleep -Seconds 3
  & $exe '!ActivateConfig' $ConfigName 'Radar.ini'
  Write-Host "Asked Rainmeter to load $ConfigName."
}
