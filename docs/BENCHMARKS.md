# Phase E results (2026-11-18)

Everything on this page was measured on the author's PC: Windows 11 Home 10.0.26300, Rainmeter
4.5.28 64-bit, with 3 other skins (illustro Clock, Disk, System) active. Nothing is estimated
unless it says so. Raw outputs: `benchmark-run1-console.txt`, `benchmark-results-run2.json`.
Script: `tests\Measure-Overhead.ps1`.

CPU and memory numbers are for the **whole Rainmeter process** (all skins), read from Windows
process counters. Each "with/without" pair is the same process with DesktopRadar loaded or unloaded.

## Steady state
| Run | Window | CPU without | CPU with | Private MB without → with | Working set MB without → with |
|---|---|---|---|---|---|
| 1 (without first) | 10 min each | 4.0 s (0.67% of one core) | 3.4 s (0.57%) | 24.4 → 28.3 (+3.9) | 65.4 → 69.3 (+3.9) |
| 2 (with first) | 5 min each | 1.4 s (0.47%) | 2.1 s (0.71%) | 17.8 → 20.4 (+2.6) | 57.8 → 60.4 (+2.6) |

- **CPU:** the difference changed sign between runs. The radar's steady CPU cost is smaller than
  the run-to-run noise of Rainmeter itself, which is about ±0.25% of one core.
  The "with" windows include a forced refresh: query, image download, wind and alerts.
- **Memory:** consistently +2.6 to +3.9 MB private.
- **Handles:** +13 (run 1) and +24 (run 2).

## Rainmeter startup (process start → all skin windows visible)
| | Run 1 | Run 2 #1 | #2 | #3 | Mean |
|---|---|---|---|---|---|
| Without (3 skins) | 419 ms, 300 ms | 359 ms | 298 ms | 294 ms | 334 ms |
| With (4 skins) | 389 ms | 363 ms | 344 ms | 361 ms | 364 ms |

- **Time to visible:** about +30 ms on average.
- **CPU in the first ~10 s:** without 359–422 ms (mean 381), with 375–719 ms (mean 586). That's
  about +205 ms of CPU spread over 10 s, while the skin makes its startup requests.
- **Private memory 10 s after start:** about 11.9 MB without, 19.7–21.1 MB with. It settles to
  the steady-state +3 MB.
- **Windows startup itself:** the skin adds no process, service, scheduled task, Run key or
  Startup entry (checked by `tests\Test-SizesAndRemoval.ps1`). Rainmeter was already in the
  Startup folder. A full Windows boot was not measured, because that would mean rebooting the
  author's PC.

## Replay (live widget, real NOAA)
| Run | Rainmeter CPU idle per 10 s | Rainmeter CPU while playing per 10 s |
|---|---|---|
| 1 | 16 ms | 219 ms |
| 2 | 16 ms | 188 ms |
| 3 | 31 ms | 141 ms |

- **CPU:** about +1.2–2.0% of one core while playing, and nothing otherwise.
- **Duration:** a default replay plays for about 16 s (5 frames + 3 hold steps, 0.5 s each, 4 loops).
- **Start time:** pressing play to playing took 0.8 s, including the frame list and 4 downloads (201 KB on disk).

## Network (measured payload sizes, live, 2026-11-18)
| Request | Bytes | When |
|---|---|---|
| Newest frame time (`query`, 1 record) | 333 | every 15 min |
| Radar image 300×300 (`exportImage`) | 53,336 | when a new frame exists (practically every 15 min) |
| Wind, KMIA latest observation | 5,060 | every 15 min |
| Wind, fallback station (KOPF) | 4,689 | only when KMIA has no wind |
| Alerts for the point (3 active) | 16,169 | every 15 min (size varies with alerts) |
| Replay frame list (`query`, 16 records) | 1,353 | only when Play is pressed |
| Replay frames | ~53 KB each, at most 7 | only when Play is pressed, only frames not cached |

Payload per 15-minute cycle is about 54 KB for the radar alone and 75–80 KB with wind and alerts.
Over a day (96 cycles), the arithmetic from these sizes is **about 5.2 MB radar-only, or
7.2–7.7 MB with extras**. This is computed, not metered: HTTP headers and TLS add some overhead
that wasn't counted.

## Fetch latency (after the Phase E fix)
Phase E found that WebParser fetches requested from Lua only went out on the next skin tick, up
to 60 s later. The fix updates the measure straight after the request. Measured at the real 60 s
tick against the local mock:

| | Before | After |
|---|---|---|
| First radar after load | up to 60 s | 0.2 s |
| Wind with one station fallback | up to 60 s | 0.2 s |
| Replay, play → playing (4 downloads) | about 4 min | 0.2 s (0.8 s live with real NOAA) |

Each fetch still happens exactly once: at load, 1 query, 1 export, 2 observation requests and 1 alerts request.

## Disk
- Two rotating radar files, about 55 KB each.
- Replay cache of at most 8 files. Stale replay frames are deleted when a new replay is built.
- `State.inc` is written once per successful radar update (3 keys).
- Nothing is written outside the skin folder.

## Functional validation
| Check | Result | How |
|---|---|---|
| Behavior suite (errors, offline, stale, restart, cache slots, sleep/resume, wind, alerts, replay, modules off) | 64/64 pass | `tests\Test-SkinBehavior.ps1` (inside Rainmeter, local mock) |
| Live data, geometry, alignment, link | 12/12 pass | `tests\Verify-Radar.ps1` |
| Sizes 250, 300, 400 px | All draw complete. Text doesn't scale with size. | `tests\Test-SizesAndRemoval.ps1`, plus window captures |
| Clean removal | Folder removed, not active, Run keys, Startup folder, tasks and services unchanged | `tests\Test-SizesAndRemoval.ps1` |
| Alignment | Radar and basemap services echo the same extent within 1 m | `tests\Verify-Radar.ps1` |
| Accuracy vs NWS | Our MRMS frame for 22:01:53 UTC matches the broad pattern of the NWS KAMX page captured at 22:02 UTC: main rain over and east of Miami, heaviest cells toward the Keys, scattered cells near West Palm Beach. NWS shows somewhat more light rain inland, which fits its composite reflectivity (max at any height) versus MRMS base reflectivity. | Owner's screenshot vs a wider render of the same frame |

## Known limits
- **Screen capture scaling:** one capture session saw the display as 2048×1152 (125% scaling)
  with a second monitor attached. In that session, captures needed ×1.25 coordinates. This
  affects screenshots taken by the test scripts, not the widget.
- **Rainmeter.ini leftovers:** inactive sections for test configs (DesktopRadarTest,
  DesktopRadarSize250/400, DesktopRadarProbe*, DesktopRadarLatency) remain in Rainmeter.ini.
  Rainmeter keeps one for every config it has loaded. They are harmless.
