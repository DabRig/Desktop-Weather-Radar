<#
.SYNOPSIS
  Unloads DesktopRadar and removes its folder from your Rainmeter skins folder.
  Asks before deleting. Leaves Rainmeter and your other skins alone. Does not touch
  this project folder.

.PARAMETER ConfigName
  Skin folder name (default DesktopRadar). Only needed for test copies.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param([string]$ConfigName = 'DesktopRadar')
$ErrorActionPreference = 'Stop'
if ($ConfigName -notmatch '^[A-Za-z0-9_-]+$') { throw "ConfigName must be letters, digits, - or _" }
$ini = Join-Path $env:APPDATA 'Rainmeter\Rainmeter.ini'
$skinPath = (Get-Content $ini | Where-Object { $_ -match '^SkinPath=' } | Select-Object -First 1) -replace '^SkinPath=', ''
$dst = Join-Path $skinPath $ConfigName
if (-not (Test-Path (Join-Path $dst 'Radar.ini'))) { Write-Host "Nothing to remove: $dst has no Radar.ini."; return }
$exe = Join-Path $env:ProgramFiles 'Rainmeter\Rainmeter.exe'
$running = Get-Process Rainmeter -ErrorAction SilentlyContinue | Select-Object -First 1
if ($running -and $running.Path) { $exe = $running.Path }
if ($PSCmdlet.ShouldProcess($dst, "Unload $ConfigName and delete its skin folder")) {
  if ((Test-Path $exe) -and $running) { & $exe '!DeactivateConfig' $ConfigName; Start-Sleep -Seconds 2 }
  Remove-Item -LiteralPath $dst -Recurse -Force
  if ($running) { & $exe '!RefreshApp' }
  Write-Host "Removed $dst"
}
