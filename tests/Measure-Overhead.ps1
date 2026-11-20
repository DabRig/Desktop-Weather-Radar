<#
.SYNOPSIS
  Measures what DesktopRadar adds to Rainmeter: steady-state CPU and memory, Rainmeter
  startup time, and CPU during a replay. Results go to the console and a JSON file.

.DESCRIPTION
  1. Steady state: Rainmeter with DesktopRadar unloaded for -Minutes, then loaded for
     -Minutes (one refresh cycle is forced at the start of the loaded window so the
     window includes real downloads). Samples every 15 s.
  2. Startup: restarts Rainmeter -Runs times without the skin and -Runs times with it,
     timing process start until every skin window is visible.
  3. Replay: CPU over 15 s of playback (if AnimationEnabled=1).
  Your other skins stay as they are. The skin is left loaded at the end, as it was.
  No admin rights, no system changes.
#>
[CmdletBinding()]
param([double]$Minutes = 10, [int]$Runs = 3, [string]$Out, [switch]$WithFirst)
$ErrorActionPreference = 'Stop'
if (-not $Out) { $Out = Join-Path $PSScriptRoot '..\docs\benchmark-results.json' }
$exe = (Get-Process Rainmeter | Select-Object -First 1).Path
$ini = Join-Path $env:APPDATA 'Rainmeter\Rainmeter.ini'

Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class RmWin {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  public static int Count(uint pid, string mustContain) {
    int n = 0;
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p);
      if (p == pid && IsWindowVisible(h)) { var c = new StringBuilder(64); GetClassName(h, c, 64);
        if (c.ToString() == "RainmeterMeterWindow") { var t = new StringBuilder(512); GetWindowText(h, t, 512);
          if (mustContain == null || t.ToString().Contains(mustContain)) n++; } } return true; }, IntPtr.Zero);
    return n;
  }
}
'@

function Activeconfigs {
  $sec = ''; $list = @()
  foreach ($l in Get-Content $ini) { if ($l -match '^\[(.+)\]') { $sec = $Matches[1] } elseif ($l -match '^Active=[1-9]' -and $sec -ne 'Rainmeter') { $list += $sec } }
  $list
}
function Sample-Window([string]$label, [double]$mins, [scriptblock]$atStart) {
  $p = Get-Process Rainmeter | Select-Object -First 1
  if ($atStart) { & $atStart }
  $p.Refresh(); $cpu0 = $p.TotalProcessorTime.TotalMilliseconds; $t0 = Get-Date
  $ws = @(); $pv = @(); $h = @()
  $end = (Get-Date).AddMinutes($mins)
  $step = [math]::Min(15, [math]::Max(1, $mins * 60 / 5))
  do {
    $p.Refresh(); $ws += $p.WorkingSet64 / 1MB; $pv += $p.PrivateMemorySize64 / 1MB; $h += $p.HandleCount
    Start-Sleep -Seconds $step
  } while ((Get-Date) -lt $end)
  $p.Refresh(); $cpu = $p.TotalProcessorTime.TotalMilliseconds - $cpu0; $secs = ((Get-Date) - $t0).TotalSeconds
  $r = [pscustomobject]@{
    label = $label; seconds = [math]::Round($secs); cpuMs = [math]::Round($cpu)
    cpuPercentOneCore = [math]::Round(100 * $cpu / ($secs * 1000), 3)
    workingSetMB = [math]::Round(($ws | Measure-Object -Average).Average, 1)
    privateMB = [math]::Round(($pv | Measure-Object -Average).Average, 1)
    privateMaxMB = [math]::Round(($pv | Measure-Object -Maximum).Maximum, 1)
    handles = [math]::Round(($h | Measure-Object -Average).Average)
  }
  Write-Host ("{0,-22} CPU {1,6} ms in {2} s ({3}% of one core)  WS {4} MB  private {5} MB (max {6})  handles {7}" -f $r.label, $r.cpuMs, $r.seconds, $r.cpuPercentOneCore, $r.workingSetMB, $r.privateMB, $r.privateMaxMB, $r.handles)
  $r
}
function Restart-Timed([string]$label) {
  $configs = Activeconfigs
  & $exe '!Quit'
  # Poll instead of Wait-Process: it throws if the process exits between lookup and wait.
  $q = [Diagnostics.Stopwatch]::StartNew()
  while ((Get-Process Rainmeter -ErrorAction SilentlyContinue) -and $q.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 200 }
  Start-Sleep -Seconds 3
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $proc = Start-Process $exe -PassThru
  $want = $configs.Count
  while ($sw.Elapsed.TotalSeconds -lt 30 -and [RmWin]::Count([uint32]$proc.Id, $null) -lt $want) { Start-Sleep -Milliseconds 25 }
  $allMs = $sw.ElapsedMilliseconds
  Start-Sleep -Seconds 10
  $proc.Refresh()
  $r = [pscustomobject]@{ label = $label; skins = $want; msToAllSkinsVisible = $allMs; cpuMsFirst10s = [math]::Round($proc.TotalProcessorTime.TotalMilliseconds); privateMBAfter10s = [math]::Round($proc.PrivateMemorySize64 / 1MB, 1) }
  Write-Host ("{0,-22} {1} skins visible after {2} ms; CPU in first ~10 s {3} ms; private {4} MB" -f $label, $want, $allMs, $r.cpuMsFirst10s, $r.privateMBAfter10s)
  $r
}

$results = [ordered]@{ measuredAt = (Get-Date).ToString('s'); machine = (Get-CimInstance Win32_OperatingSystem).Caption + ' ' + [Environment]::OSVersion.Version; rainmeter = (Get-Item $exe).VersionInfo.ProductVersion }
Write-Host "Rainmeter $($results.rainmeter); active skins: $((Activeconfigs) -join ', ')"

Write-Host "`n--- Steady state ($Minutes min each)"
$doWithout = { & $exe '!DeactivateConfig' 'DesktopRadar'; Start-Sleep -Seconds 30; $results.without = Sample-Window 'without DesktopRadar' $Minutes $null }
$doWith = { & $exe '!ActivateConfig' 'DesktopRadar' 'Radar.ini'; Start-Sleep -Seconds 30; $results.with = Sample-Window 'with DesktopRadar' $Minutes { & $exe '!CommandMeasure' 'MeasureFrame' 'Update' 'DesktopRadar' } }
if ($WithFirst) { & $doWith; & $doWithout; & $exe '!ActivateConfig' 'DesktopRadar' 'Radar.ini'; Start-Sleep -Seconds 30 } else { & $doWithout; & $doWith }

$anim = (Get-Content (Join-Path ((Get-Content $ini | Where-Object { $_ -match '^SkinPath=' }) -replace '^SkinPath=', '') 'DesktopRadar\@Resources\Settings.inc')) -match '^AnimationEnabled=1'
if ($anim) {
  Write-Host "`n--- Replay (15 s of playback; includes loading frames)"
  $results.replay = Sample-Window 'replay playing' 0.25 { & $exe '!CommandMeasure' 'MeasureScript' 'AnimToggle()' 'DesktopRadar' }
  & $exe '!CommandMeasure' 'MeasureScript' "AnimStop('stopped')" 'DesktopRadar'
}

Write-Host "`n--- Rainmeter startup ($Runs runs each)"
$results.startup = @()
for ($i = 1; $i -le $Runs; $i++) {
  & $exe '!DeactivateConfig' 'DesktopRadar'; Start-Sleep -Seconds 2
  $results.startup += Restart-Timed "start without #$i"
  & $exe '!ActivateConfig' 'DesktopRadar' 'Radar.ini'; Start-Sleep -Seconds 2
  $results.startup += Restart-Timed "start with #$i"
}
# Leave it as found: skin loaded.
if (-not ((Activeconfigs) -contains 'DesktopRadar')) { & $exe '!ActivateConfig' 'DesktopRadar' 'Radar.ini' }

$results | ConvertTo-Json -Depth 4 | Set-Content $Out -Encoding UTF8
Write-Host "`nSaved $Out"
