# Architecture

## Choices
| Need | Choice | Why |
|---|---|---|
| Desktop host | Rainmeter 4.5 skin | Already installed and already starting at sign-in. No browser engine. |
| Radar data | NOAA/NWS `radar/radar_base_reflectivity_time` ImageServer | Official, free, MRMS mosaic every ~4–8 min, exports any box as a transparent PNG, time-enabled. |
| Basemap | US Census TIGERweb (USLandmass, Hydro, counties, primary roads) | Public domain, one export request per layer, same EPSG:3857 box as the radar. Esri's dark canvas looked similar, but its terms for keyless personal use were unclear. |
| Fallback provider | None (RainViewer evaluated) | Since 2026-01-01 RainViewer is zoom ≤ 7, 100 req/min, no nowcast. Not needed while NOAA works. |
| Logic | WebParser + Lua (`Radar.lua`) | Both run inside Rainmeter's process. No PowerShell or Python at runtime. |

## Data flow
```
every RefreshMinutes (WebParser MeasureFrame)
  GET ImageServer/query?where=name LIKE '<Region>%'&orderBy idp_validtime DESC&count=1  (~0.3 KB)
    -> Radar.lua OnFrame(): frame time plausible?  same as shown?  -> stop (no download)
    -> else set MeasureRadar URL = exportImage?bbox=..&time=<frame ms>, DownloadFile = other slot
       (MeasureRadar)  GET exportImage ... png32, nearest-neighbour  (~55 KB at 300 px)
         -> Radar.lua OnRadar(): file starts with the PNG signature?
              yes -> show that slot, write Slot/ObsEpochMs/LastSuccess to State.inc
              no  -> keep the old slot, show the error, schedule one retry
once per location change (setup in Radar.lua; tools\Update-Location.ps1 does the same for tests)
  bbox math, mosaic lookup, NWS station lookup (api.weather.gov/points), 4 TIGER layers
    -> Location.inc and DownloadFile\layer_*.png, then one skin refresh
```

## Geometry
The box is a square in Web Mercator (EPSG:3857) centred on the location. Its half-width in map
metres is `RadiusKm / cos(latitude)`, so the ground distance from centre to edge equals `RadiusKm`.
The radar and basemap are requested with the identical box, size and SR, so they align pixel for
pixel. `tests\Verify-Radar.ps1` checks that both services echo the same extent.

## Things found while building
- The service's root `timeInfo.timeExtent` was about 20 hours out of date during testing. The catalog
  `query` is current, so the skin reads frame times from `query`.
- Exports send `Cache-Control: max-age=43200`. Pinning `time=` to the newest frame keeps a cache
  from serving an old image, and it supplies the observation time.
- ArcGIS returns errors as JSON with HTTP 200, so every image is checked for the PNG signature
  before use.
- Nearest-neighbour exports keep NOAA's own colour ramp (105 colours in testing). Bilinear blends
  them into 10,000+ colours and doubles the file size.
- A WebParser fetch requested with `!CommandMeasure ... "Update"` only goes out on the measure's
  next update, which is the next skin tick (up to 60 s). `fetchNow()` in Radar.lua follows it with
  `!UpdateMeasure`, so it goes out immediately. This was found and fixed in Phase E; see BENCHMARKS.md.
- Rainmeter's `(?U)` (ungreedy) regex flag made `(\d+)` capture one digit. The pattern is greedy
  and requires 13 digits.

## Failure handling (Phase C)
| Situation | What the skin does |
|---|---|
| No new frame since the last check | Query only (~0.3 KB). No download. |
| Download in progress when a new check fires | Doesn't start a second download. |
| HTTP error, JSON error body, truncated file | Image rejected: needs both the PNG signature and the IEND tail. The old slot stays on screen. |
| Download never reports back | Abandoned after 120 s and treated as an error. |
| Any error | One retry after `RetrySeconds` (180), at most once per refresh period. |
| Can't connect | Status "offline". If the image is also old, the badge shows OFFLINE. |
| Frame older than `StaleMinutes` | Radar drawn at half opacity, obs time in amber, STALE badge. |
| Implausible frame time (> 1 day old or > 1 h ahead) | Rejected as "bad frame time". |
| PC wakes from sleep | Tick gap > 3 ticks is detected, and one check runs 30 s later. |
| Rainmeter/PC restart | Last good slot and times come from State.inc, so the image shows at once. Only a query is sent. |
| Location changed | Runs setup again (about 7 small requests), then refreshes once. No radar is downloaded for the old map in between. |

`tests\Test-SkinBehavior.ps1` exercises each row inside the real Rainmeter against `tests\mock-noaa.js`.

## Optional modules (Phase D)
| Module | Source | Requests | Notes |
|---|---|---|---|
| Surface wind | `api.weather.gov/stations/<id>/observations/latest` (~5 KB) | 1 per period, plus up to 2 fallbacks | The 3 nearest stations come from `/points` → `observationStations`, found during setup. KMIA's wind was null (QC "Z") during testing, so fallback is needed. |
| Alerts | `api.weather.gov/alerts/active?point=lat,lon` (~16 KB with 3 alerts) | 1 per period | Event and severity are parsed in order; the chip shows the highest severity. |
| Replay | the same ImageServer: `query` with 16 frame times, then `exportImage` per frame | 1 query plus missing frames, only on Play | Frames are cached as `anim_<ms>.png` (max 8). Replay frames no longer selected are deleted. The live frame is reused. ActionTimer steps frames every `AnimFrameMs`. No downloads during playback. |

Each module checks its own setting in `Initialize()`. A disabled module's WebParser is disabled,
so it makes no requests, and its meters stay hidden. The radar code path never depends on them.

Parsing notes:
- NWS JSON is pretty-printed. Each `{"unitCode", "value"}` block is isolated with Lua `%b{}`
  before `value` is read, so a null direction can't borrow the speed's number.
- Observation timestamps are ISO 8601 with an offset and are converted to Unix time.
  Observations more than 2 hours old aren't shown.

## Resource notes
- One skin update per minute (text and stale check). No shell commands. No skin refresh on new images.
- Network: one ~0.3 KB query per period, plus ~55 KB only when a new frame exists. At a 15-minute
  period that is at most about 5.3 MB/day.
- Disk: two rotating cache files plus a small State.inc write per successful update.
- Benchmarks of Rainmeter CPU, memory and startup with and without the skin are measured in Phase E
  and recorded there. None are claimed here.
