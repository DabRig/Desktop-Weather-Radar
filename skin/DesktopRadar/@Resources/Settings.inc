; DesktopRadar settings.
;
; After changing Latitude, Longitude, RadiusKm or Size, run:
;   powershell -ExecutionPolicy Bypass -File tools\Update-Location.ps1
; That recomputes the map area and redraws the basemap once (it is not
; downloaded again on startup). Other values apply after a skin refresh.

[Variables]
; Name shown in the title bar.
LocationName=Miami, FL

; Center point in decimal degrees (WGS84). West longitudes are negative.
Latitude=25.7617
Longitude=-80.1918

; Distance from the center to the edge of the map, in km (25 to 500).
RadiusKm=100

; Widget width and height in pixels (250 to 400).
Size=300

; Minutes between radar checks (5 to 60). NOAA publishes a new frame every
; 4 to 10 minutes. A check downloads an image only when a new frame exists.
RefreshMinutes=15

; The radar is marked STALE when the newest frame shown is older than this.
StaleMinutes=35

; Radar layer opacity, 0 (invisible) to 255 (solid).
RadarAlpha=215

; ---- Optional extras. Each one can be switched off without affecting the radar.

; Surface wind from the nearest NWS observation station (1 = show, 0 = off).
; This is wind at ground level, NOT the direction storms are moving.
ShowWind=1
; Wind speed units: mph, kmh or kt.
WindUnits=mph

; Active NWS alerts (watches, warnings, advisories) for this point (1 = show, 0 = off).
ShowAlerts=1

; Replay of recent observed radar (1 = show a play button, 0 = off). Playback starts
; only when you click play, stops by itself after AnimLoops loops, and never downloads
; during playback. It shows the past hour, not a forecast.
AnimationEnabled=0
; Minutes of history (30 to 60), maximum frames (4 to 10), milliseconds per frame, loops.
AnimMinutes=60
AnimFrames=8
AnimFrameMs=500
AnimLoops=4

; Troubleshooting only: 1 writes DownloadFile\debug.log. Leave at 0.
DebugLog=0
