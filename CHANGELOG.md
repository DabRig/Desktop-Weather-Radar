# Changelog

## 1.0.0 (2026-11-19)
First public release.

- Recent NOAA/NWS MRMS radar around any covered location, on a US Census map, refreshed every 15 minutes.
- The skin sets itself up on first load and after location changes: no scripts to run.
- Separate observation and download times. STALE and OFFLINE marking, keeping the last good image.
- Downloads only when a new frame exists. Every image is checked before use. One retry, no loops.
- Detects sleep/resume and checks once after waking.
- Optional surface wind (with nearest-station fallback), NWS alert chip, and past-hour replay.
- Sizes 250–400 px.
