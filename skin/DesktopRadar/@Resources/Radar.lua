-- DesktopRadar controller. Runs inside Rainmeter's own process (no extra program).
-- Called by WebParser actions, by ActionTimer during replay, and once per skin tick.
--
-- Modules: radar (always), surface wind (ShowWind), alerts (ShowAlerts),
-- replay (AnimationEnabled). The optional ones never affect the radar.

local PNG_SIG  = '\137PNG\r\n\26\n'
local PNG_TAIL = 'IEND\174\66\96\130'   -- every complete PNG ends with this IEND chunk
local PENDING_TIMEOUT = 120             -- seconds before a silent download is given up
local RESUME_DELAY = 30                 -- after sleep/resume, check again after the network settles
local st = {}
local wind = {}
local alerts = {}
local anim = { state = 'idle', frames = {} }

local function num(name, default)
  return tonumber(SKIN:GetVariable(name, tostring(default))) or default
end
local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

-- Opt-in troubleshooting log (Settings.inc: DebugLog=1). Off by default: no file writes.
local function log(msg)
  if not st.debug then return end
  local f = io.open(st.dir .. 'debug.log', 'a')
  if f then f:write(os.date('%Y-%m-%d %H:%M:%S  ') .. msg .. '\n'); f:close() end
end

local function slotPath(slot)
  return st.dir .. 'radar_' .. slot .. '.png'
end

-- True only for a complete PNG. ArcGIS returns errors as JSON with HTTP 200, and a
-- dropped connection can leave half a file, so check both the header and the IEND tail.
local function isPng(path)
  local f = io.open(path, 'rb')
  if not f then return false end
  local head = f:read(8)
  local size = f:seek('end')
  local tail
  if size and size >= 20 then f:seek('set', size - 8); tail = f:read(8) end
  f:close()
  return head == PNG_SIG and tail == PNG_TAIL
end

local function endsWith(s, suffix)
  s = tostring(s or ''):lower()
  return s:sub(-#suffix) == suffix:lower()
end

local function fmtTime(t)
  local s = (os.date('%I:%M %p', t):gsub('^0', ''))
  if os.date('%Y%m%d', t) ~= os.date('%Y%m%d') then
    s = os.date('%b %d ', t) .. s
  end
  return s
end

-- ISO 8601 with offset ("2026-11-18T20:55:00+00:00") to Unix seconds.
local function isoToEpoch(s)
  if not s then return nil end
  local y, mo, d, h, mi, se, rest = s:match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)[%.%d]*(.*)$')
  if not y then return nil end
  local fields = { year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(se), isdst = false }
  local now = os.time()
  local stdOffset = now - os.time(os.date('!*t', now))   -- cancels mktime's local-time reading
  local t = os.time(fields) + stdOffset
  local sign, oh, om = rest:match('^([%+%-])(%d%d):?(%d%d)')
  if sign then
    local off = tonumber(oh) * 3600 + tonumber(om) * 60
    if sign == '+' then t = t - off else t = t + off end
  end
  return t
end

local function saveState()
  local inc = SKIN:GetVariable('@') .. 'State.inc'
  SKIN:Bang('!WriteKeyValue', 'Variables', 'Slot', st.slot, inc)
  SKIN:Bang('!WriteKeyValue', 'Variables', 'ObsEpochMs', string.format('%.0f', st.obsMs), inc)
  SKIN:Bang('!WriteKeyValue', 'Variables', 'LastSuccess', string.format('%d', st.lastOk), inc)
end

-- Sets a meter option only when its value changed.
local shown = {}
local function set(meter, option, value)
  local k = meter .. '.' .. option
  if shown[k] == value then return false end
  shown[k] = value
  SKIN:Bang('!SetOption', meter, option, value)
  return true
end

local function redraw(meters)
  for _, m in ipairs(meters) do SKIN:Bang('!UpdateMeter', m) end
  SKIN:Bang('!Redraw')
end

-- Ask a WebParser to fetch now. "Update" alone only arms the fetch for the measure's next
-- update, which is the next skin tick (up to 60 s); updating the measure right away sends it.
local function fetchNow(measure)
  SKIN:Bang('!CommandMeasure', measure, 'Update')
  SKIN:Bang('!UpdateMeasure', measure)
end

-- ===================================================================== radar

local function renderButtons()
  if not anim.enabled then
    set('MeterPlay', 'Hidden', '1'); set('MeterPause', 'Hidden', '1')
  elseif anim.state == 'playing' or anim.state == 'loading' then
    set('MeterPlay', 'Hidden', '1'); set('MeterPause', 'Hidden', '0')
  else
    set('MeterPlay', 'Hidden', '0'); set('MeterPause', 'Hidden', '1')
  end
end

local function render()
  renderButtons()
  if anim.state == 'playing' or anim.state == 'paused' then
    redraw({ 'MeterPlay', 'MeterPause' })
    return
  end
  local now = os.time()
  local obsS = st.obsMs / 1000
  local stale = (not st.haveImage) or (now - obsS) > st.staleMin * 60
  local changed = false

  if st.haveImage then
    changed = set('MeterRadar', 'ImageName', slotPath(st.slot)) or changed
    changed = set('MeterRadar', 'ImageAlpha', tostring(stale and math.floor(st.alpha * 0.5) or st.alpha)) or changed
    changed = set('MeterRadar', 'Hidden', '0') or changed
    changed = set('MeterObs', 'Text', 'Radar ' .. fmtTime(obsS)) or changed
  else
    changed = set('MeterRadar', 'Hidden', '1') or changed
    changed = set('MeterObs', 'Text', 'Radar --') or changed
  end
  changed = set('MeterObs', 'FontColor', stale and SKIN:GetVariable('Warn') or SKIN:GetVariable('TextMain')) or changed

  local fetched
  if st.lastOk > 0 then fetched = 'Updated ' .. fmtTime(st.lastOk) else fetched = 'Not downloaded yet' end
  if st.status ~= '' then fetched = fetched .. '  (' .. st.status .. ')' end
  if anim.state == 'loading' then fetched = string.format('Loading replay %d/%d', anim.loaded or 0, #anim.frames) end
  if st.configMismatch then fetched = st.setupMessage or 'Setting up location...' end
  changed = set('MeterFetched', 'Text', fetched) or changed

  local badge = ''
  if stale then badge = (st.status == 'offline') and 'OFFLINE' or 'STALE' end
  changed = set('MeterBadge', 'Text', badge) or changed
  changed = set('MeterBadge', 'Hidden', badge == '' and '1' or '0') or changed

  if changed then
    log(string.format('render slot=%s obs=%.0f stale=%s badge=%s fetched="%s"', st.slot, st.obsMs, tostring(stale), badge, fetched))
  end
  redraw({ 'MeterRadar', 'MeterBadge', 'MeterObs', 'MeterFetched', 'MeterPlay', 'MeterPause' })
end

local function scheduleRetry(delay, why)
  -- At most one retry per refresh period, so failures never turn into a request loop.
  if st.retryAt then return end
  if (os.time() - st.lastRetry) <= st.period then return end
  st.retryAt = os.time() + delay
  log('retry scheduled in ' .. delay .. 's (' .. why .. ')')
end

-- ===================================================================== wind

local DIRS = { 'N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW' }

-- Value and unit of a {"unitCode":..,"value":..} block. Isolating the block first means a
-- null value can never pick up the number from the next field.
local function qvalue(body, key)
  local block = body:match('"' .. key .. '"%s*:%s*(%b{})')
  if not block then return nil, nil end
  return tonumber(block:match('"value"%s*:%s*(%-?[%d%.]+)')), block:match('"unitCode"%s*:%s*"([^"]+)"')
end

local function windShow(text, tooltip, deg)
  set('MeterWindText', 'Text', text)
  set('MeterWindText', 'ToolTipText', tooltip)
  set('MeterWindText', 'Hidden', '0')
  if deg then
    set('MeterWindArrow', 'Shape', string.format('Path WindPath | Fill Color %s,230 | StrokeWidth 0 | Rotate %d,7,7', SKIN:GetVariable('TextMain'), (deg + 180) % 360))
    set('MeterWindArrow', 'ToolTipText', tooltip)
    set('MeterWindArrow', 'Hidden', '0')
  else
    set('MeterWindArrow', 'Hidden', '1')
  end
  log('wind "' .. text .. '"')
  redraw({ 'MeterWindText', 'MeterWindArrow' })
end

local function windFetch(idx)
  wind.idx = idx
  SKIN:Bang('!SetOption', 'MeasureWind', 'URL', SKIN:ReplaceVariables('#NWSApi#') .. '/stations/' .. wind.stations[idx] .. '/observations/latest')
  SKIN:Bang('!UpdateMeasure', 'MeasureWind')
end

function OnWind()
  if not wind.enabled then return end
  local body = SKIN:GetMeasure('MeasureWind'):GetStringValue() or ''
  local station = wind.stations[wind.idx]
  local deg = qvalue(body, 'windDirection')
  local spd, unit = qvalue(body, 'windSpeed')
  local ts = isoToEpoch(body:match('"timestamp"%s*:%s*"([^"]+)"'))
  local fresh = ts and (os.time() - ts) < 2 * 3600
  log(string.format('OnWind %s deg=%s speed=%s unit=%s age=%s', station, tostring(deg), tostring(spd), tostring(unit), ts and tostring(os.time() - ts) or 'nil'))

  if not spd or not fresh then
    -- This station has no usable wind right now; try the next one, once per cycle.
    if wind.hops < #wind.stations - 1 then
      wind.hops = wind.hops + 1
      windFetch(wind.idx % #wind.stations + 1)
      fetchNow('MeasureWind')
      return
    end
    wind.hops = 0
    if wind.idx ~= 1 then windFetch(1) end
    return windShow('Wind --', 'No recent surface wind report from ' .. table.concat(wind.stations, ', '), nil)
  end

  wind.hops = 0
  local kmh = spd
  if unit and unit:find('m_s%-1') then kmh = spd * 3.6 end
  local value, label = kmh / 1.609344, 'mph'
  if wind.units == 'kmh' then value, label = kmh, 'km/h' elseif wind.units == 'kt' then value, label = kmh / 1.852, 'kt' end
  local when = fmtTime(ts)
  local text, tip
  if kmh < 1.6 then
    text = 'Wind calm'
    tip = 'Surface wind calm, observed at ' .. station .. ' ' .. when .. '.'
    deg = nil
  elseif not deg then
    text = string.format('Wind var %d %s', math.floor(value + 0.5), label)
    tip = string.format('Surface wind variable at %d %s, observed at %s %s.', math.floor(value + 0.5), label, station, when)
  else
    local name = DIRS[math.floor(deg / 22.5 + 0.5) % 16 + 1]
    text = string.format('Wind %s %d %s', name, math.floor(value + 0.5), label)
    tip = string.format('Surface wind from the %s (%d deg) at %d %s, observed at %s %s. The arrow points where the air is going.', name, deg, math.floor(value + 0.5), label, station, when)
  end
  tip = tip .. ' Ground-level wind, not storm movement.'
  if wind.idx ~= 1 then windFetch(1) end   -- prefer the nearest station next time
  windShow(text, tip, deg)
end

function OnWindError(msg)
  if not wind.enabled then return end
  log('OnWindError ' .. tostring(msg))
  wind.hops = 0
  if shown['MeterWindText.Text'] == nil then windShow('Wind --', 'Surface wind unavailable (' .. tostring(msg) .. ')', nil) end
end

-- ===================================================================== alerts

local SEVERITY = { Extreme = 4, Severe = 3, Moderate = 2, Minor = 1, Unknown = 0 }

function OnAlerts()
  if not alerts.enabled then return end
  local body = SKIN:GetMeasure('MeasureAlerts'):GetStringValue() or ''
  if not body:find('"features"') then return OnAlertsError('unexpected reply') end
  local events, sevs = {}, {}
  for e in body:gmatch('"event"%s*:%s*"([^"]*)"') do events[#events + 1] = e end
  for s in body:gmatch('"severity"%s*:%s*"(%a+)"') do sevs[#sevs + 1] = s end
  alerts.ok = os.time()
  log('OnAlerts count=' .. #events .. ' ' .. table.concat(events, ', '))
  if #events == 0 then
    set('MeterAlert', 'Hidden', '1')
    return redraw({ 'MeterAlert' })
  end
  local best, bestRank = 1, -1
  local lines = {}
  for i, e in ipairs(events) do
    local rank = SEVERITY[sevs[i] or 'Unknown'] or 0
    if rank > bestRank then best, bestRank = i, rank end
    lines[#lines + 1] = '- ' .. e .. ' (' .. (sevs[i] or 'Unknown') .. ')'
  end
  local name = events[best]:upper()
  if #name > 22 then name = name:sub(1, 21) .. '.' end
  if #events > 1 then name = name .. '  +' .. (#events - 1) end
  local fill = '60,110,180,220'
  if bestRank >= 3 then fill = '200,50,50,225' elseif bestRank == 2 then fill = '205,120,20,225' end
  set('MeterAlert', 'Text', name)
  set('MeterAlert', 'SolidColor', fill)
  set('MeterAlert', 'ToolTipText', 'Active NWS alerts:#CRLF#' .. table.concat(lines, '#CRLF#') .. '#CRLF#Click for details on weather.gov.')
  set('MeterAlert', 'Hidden', '0')
  log('alert chip "' .. name .. '"')
  redraw({ 'MeterAlert' })
end

function OnAlertsError(msg)
  if not alerts.enabled then return end
  log('OnAlertsError ' .. tostring(msg))
  -- Keep whatever was shown; a failed refresh is not evidence that alerts ended.
  if shown['MeterAlert.Hidden'] == '0' then
    set('MeterAlert', 'ToolTipText', (shown['MeterAlert.ToolTipText'] or '') .. '#CRLF#(Last refresh failed: ' .. tostring(msg) .. ')')
  end
end

-- ===================================================================== replay

local function animFile(ms) return st.dir .. 'anim_' .. string.format('%.0f', ms) .. '.png' end

local function showFrame(i)
  local fr = anim.frames[i]
  if not fr then return end
  set('MeterRadar', 'ImageName', fr.path)
  set('MeterRadar', 'ImageAlpha', tostring(st.alpha))
  set('MeterRadar', 'Hidden', '0')
  set('MeterObs', 'Text', 'Replay ' .. fmtTime(fr.ms / 1000))
  set('MeterObs', 'FontColor', SKIN:GetVariable('Accent'))
  local what = (anim.state == 'paused') and 'Paused' or 'Past radar'
  set('MeterFetched', 'Text', string.format('%s %d/%d - not a forecast', what, i, #anim.frames))
  set('MeterBadge', 'Hidden', '1')
  log(string.format('anim show %d/%d ms=%.0f', i, #anim.frames, fr.ms))
  redraw({ 'MeterRadar', 'MeterObs', 'MeterFetched', 'MeterBadge' })
end

local function animPlay()
  anim.state = 'playing'
  anim.step, anim.loops = 1, 0
  anim.playedAt = os.time()
  renderButtons()
  showFrame(1)
  SKIN:Bang('!CommandMeasure', 'MeasureAnimTimer', 'Execute 1')
  log('anim play ' .. #anim.frames .. ' frames')
end

function AnimStop(why)
  SKIN:Bang('!CommandMeasure', 'MeasureAnimTimer', 'Stop 1')
  local was = anim.state
  anim.state = 'idle'
  anim.pendingMs = nil
  if why and why ~= 'done' and why ~= 'stopped' then st.status = 'replay ' .. why end
  log('anim stop (' .. tostring(why) .. ') was ' .. was)
  render()
end

local function animNext()
  for i, fr in ipairs(anim.frames) do
    if not fr.ready then
      anim.pendingMs, anim.pendingIdx = fr.ms, i
      local url = SKIN:ReplaceVariables('#ExportBase#') .. '&time=' .. string.format('%.0f', fr.ms)
      SKIN:Bang('!SetOption', 'MeasureAnimFrame', 'URL', url)
      SKIN:Bang('!SetOption', 'MeasureAnimFrame', 'DownloadFile', 'anim_' .. string.format('%.0f', fr.ms) .. '.png')
      SKIN:Bang('!UpdateMeasure', 'MeasureAnimFrame')
      fetchNow('MeasureAnimFrame')
      log('anim download ' .. i .. '/' .. #anim.frames .. ' ms=' .. string.format('%.0f', fr.ms))
      render()
      return
    end
  end
  anim.pendingMs = nil
  -- Drop frames that failed; replay needs at least two.
  local ok = {}
  for _, fr in ipairs(anim.frames) do if fr.ready then ok[#ok + 1] = fr end end
  anim.frames = ok
  if #ok < 2 then return AnimStop('needs 2+ frames') end
  animPlay()
end

function AnimToggle()
  if not anim.enabled then return end
  if anim.state == 'playing' then
    anim.state = 'paused'; anim.pausedAt = os.time()
    SKIN:Bang('!CommandMeasure', 'MeasureAnimTimer', 'Stop 1')
    log('anim pause')
    renderButtons(); showFrame(math.min(anim.step, #anim.frames))
    return
  elseif anim.state == 'paused' then
    anim.state = 'playing'
    SKIN:Bang('!CommandMeasure', 'MeasureAnimTimer', 'Execute 1')
    log('anim resume')
    renderButtons(); showFrame(math.min(anim.step, #anim.frames))
    return
  elseif anim.state == 'loading' then
    return AnimStop('stopped')
  end
  -- idle: reuse a recent frame list if every frame is still on disk.
  local now = os.time()
  if anim.listAt and now - anim.listAt < 180 and #anim.frames >= 2 and anim.listObs == st.obsMs then
    local all = true
    for _, fr in ipairs(anim.frames) do if not isPng(fr.path) then all = false end end
    if all then log('anim reuse cached frames'); return animPlay() end
  end
  anim.state = 'loading'; anim.startedAt = now; anim.loaded = 0; anim.frames = {}
  anim.wantList = true
  SKIN:Bang('!SetOption', 'MeasureAnimList', 'URL', SKIN:ReplaceVariables('#FrameListQuery#'))
  SKIN:Bang('!UpdateMeasure', 'MeasureAnimList')
  fetchNow('MeasureAnimList')
  log('anim list requested')
  render()
end

function OnAnimList()
  if anim.state ~= 'loading' or not anim.wantList then return end
  anim.wantList = false
  local body = SKIN:GetMeasure('MeasureAnimList'):GetStringValue() or ''
  local times = {}
  for t in body:gmatch('"idp_validtime"%s*:%s*(%d+)') do times[#times + 1] = tonumber(t) end
  table.sort(times, function(a, b) return a > b end)
  if #times < 2 then return AnimStop('no frame list') end

  -- Newest frame plus older ones spaced evenly across AnimMinutes, up to AnimFrames.
  local span = anim.minutes * 60000
  local gap = span / (anim.maxFrames - 1) * 0.8
  local sel = {}
  for _, t in ipairs(times) do
    if #sel == 0 then sel[1] = t
    elseif times[1] - t <= span + 60000 and sel[#sel] - t >= gap then sel[#sel + 1] = t end
    if #sel >= anim.maxFrames then break end
  end
  local frames, keep = {}, {}
  for i = #sel, 1, -1 do
    local t = sel[i]
    local fr = { ms = t }
    if t == st.obsMs and st.haveImage then
      fr.path = slotPath(st.slot)               -- already on disk as the live frame
    else
      fr.path = animFile(t)
      keep[string.format('%.0f', t)] = true
    end
    fr.ready = isPng(fr.path)                   -- cached from an earlier replay?
    frames[#frames + 1] = fr
  end
  -- Delete replay frames that are no longer needed (only files this skin created).
  for ms in pairs(anim.files) do
    if not keep[ms] then os.remove(st.dir .. 'anim_' .. ms .. '.png') end
  end
  anim.files = keep
  local list = {}
  for ms in pairs(keep) do list[#list + 1] = ms end
  SKIN:Bang('!WriteKeyValue', 'Variables', 'AnimFiles', table.concat(list, ','), SKIN:GetVariable('@') .. 'State.inc')

  anim.frames = frames
  anim.listAt = os.time()
  anim.listObs = st.obsMs
  anim.loaded = 0
  for _, fr in ipairs(frames) do if fr.ready then anim.loaded = anim.loaded + 1 end end
  log(string.format('anim list %d times, selected %d, cached %d', #times, #frames, anim.loaded))
  animNext()
end

function OnAnimFrame()
  if anim.state ~= 'loading' or not anim.pendingMs then return end
  local got = SKIN:GetMeasure('MeasureAnimFrame'):GetStringValue()
  if not endsWith(got, 'anim_' .. string.format('%.0f', anim.pendingMs) .. '.png') then
    log('anim ignored finish for ' .. tostring(got))
    return
  end
  local fr = anim.frames[anim.pendingIdx]
  fr.ready = isPng(fr.path)
  if fr.ready then anim.loaded = anim.loaded + 1 else fr.failed = true; fr.ready = false; log('anim frame rejected ' .. anim.pendingIdx) end
  if fr.failed then table.remove(anim.frames, anim.pendingIdx) end
  anim.pendingMs = nil
  animNext()
end

function OnAnimError(msg)
  if anim.state ~= 'loading' then return end                       -- load-time local copies
  if not anim.wantList and not anim.pendingMs then return end
  AnimStop(msg)
end

function AnimStep()
  if anim.state ~= 'playing' then return end
  local n = #anim.frames
  anim.step = anim.step + 1
  if anim.step > n + 3 then                -- hold the newest frame for 3 extra steps
    anim.step = 1
    anim.loops = anim.loops + 1
    if anim.loops >= anim.maxLoops then return AnimStop('done') end
  end
  if anim.step <= n then showFrame(anim.step) end
end

-- ===================================================================== location setup
-- Runs once after install and whenever Latitude, Longitude, RadiusKm or Size change.
-- Everything it learns goes into Location.inc; the map layers go into DownloadFile\.

local setup = { active = false }
local LAYERS = {
  { name = 'land',     svc = 'USLandmass',       show = '0' },
  { name = 'water',    svc = 'Hydro',            show = '1' },
  { name = 'counties', svc = 'tigerWMS_Current', show = '82' },
  { name = 'roads',    svc = 'Transportation',   show = '0,1,2' },
}
local setupLayers, setupNextLayer

local function setupMsg(m)
  st.setupMessage = m
  log('setup: ' .. m)
  render()
end

-- Square box in Web Mercator metres; half-width is radius / cos(lat) so the ground
-- distance from the centre to each edge equals RadiusKm.
local function mercatorBBox(lat, lon, radiusKm)
  local R = 6378137
  local x = R * math.rad(lon)
  local y = R * math.log(math.tan(math.pi / 4 + math.rad(lat) / 2))
  local h = radiusKm * 1000 / math.cos(math.rad(lat))
  return string.format('%.1f,%.1f,%.1f,%.1f', x - h, y - h, x + h, y + h)
end

local function setupValidate()
  local function check(name, lo, hi)
    local v = tonumber(SKIN:GetVariable(name, ''))
    if not v or v < lo or v > hi then return string.format('%s must be a number from %s to %s', name, lo, hi) end
  end
  return check('Latitude', -85, 85) or check('Longitude', -180, 180) or check('RadiusKm', 25, 500) or check('Size', 250, 400)
end

local function setupJson(url)
  setup.wantJson = true
  SKIN:Bang('!SetOption', 'MeasureSetupJson', 'URL', url)
  SKIN:Bang('!UpdateMeasure', 'MeasureSetupJson')
  fetchNow('MeasureSetupJson')
end

local function setupFinish()
  if not setup.layerOk.land then
    setup.active = false
    setup.retryAt = os.time() + st.retryDelay
    return setupMsg('Map download failed; retrying in ' .. math.floor(st.retryDelay / 60) .. ' min')
  end
  local inc = SKIN:GetVariable('@') .. 'Location.inc'
  for _, k in ipairs({ 'BBox', 'Region', 'RadarStation', 'NWSRadarURL', 'ObsStations', 'WindStation', 'AlertPoint', 'ForecastURL' }) do
    SKIN:Bang('!WriteKeyValue', 'Variables', k, setup.vals[k], inc)
  end
  SKIN:Bang('!WriteKeyValue', 'Variables', 'GeneratedFor', st.want, inc)   -- written last
  -- Cached radar and replay frames belong to the old map box.
  local state = SKIN:GetVariable('@') .. 'State.inc'
  SKIN:Bang('!WriteKeyValue', 'Variables', 'ObsEpochMs', '0', state)
  for ms in pairs(anim.files) do os.remove(st.dir .. 'anim_' .. ms .. '.png') end
  SKIN:Bang('!WriteKeyValue', 'Variables', 'AnimFiles', '', state)
  setup.active = false
  setupMsg('Location ready')
  SKIN:Bang('!Refresh')
end

setupNextLayer = function()
  setup.layerIdx = setup.layerIdx + 1
  local L = LAYERS[setup.layerIdx]
  if not L then return setupFinish() end
  setupMsg(string.format('Downloading map %d/%d', setup.layerIdx, #LAYERS))
  local url = SKIN:ReplaceVariables('#TigerBase#') .. '/' .. L.svc .. '/MapServer/export?bbox=' .. setup.vals.BBox ..
    '&bboxSR=3857&imageSR=3857&size=' .. setup.size .. ',' .. setup.size ..
    '&format=png32&transparent=true&layers=show:' .. L.show .. '&f=image'
  setup.wantFile = 'layer_' .. L.name .. '.png'
  SKIN:Bang('!SetOption', 'MeasureSetupFile', 'URL', url)
  SKIN:Bang('!SetOption', 'MeasureSetupFile', 'DownloadFile', setup.wantFile)
  SKIN:Bang('!UpdateMeasure', 'MeasureSetupFile')
  fetchNow('MeasureSetupFile')
end

setupLayers = function()
  setup.step = 'layers'
  setup.layerIdx, setup.layerOk = 0, {}
  setupNextLayer()
end

function SetupStart()
  setup.pendingStart = false
  local err = setupValidate()
  if err then
    setup.active = false
    return setupMsg('Check Settings.inc: ' .. err)
  end
  local lat, lon = num('Latitude', 0), num('Longitude', 0)
  local point = string.format('%.4f,%.4f', lat, lon)
  setup.active, setup.retryAt = true, nil
  setup.size = math.floor(num('Size', 300))
  setup.vals = {
    BBox = mercatorBBox(lat, lon, num('RadiusKm', 100)),
    AlertPoint = point, Region = '', RadarStation = '', ObsStations = '', WindStation = '',
    NWSRadarURL = 'https://radar.weather.gov/',
    ForecastURL = string.format('https://forecast.weather.gov/MapClick.php?lat=%.4f&lon=%.4f', lat, lon),
  }
  setup.step = 'region'
  setupMsg('Setting up location 1/3')
  setupJson(SKIN:ReplaceVariables('#ImageServer#') .. '/query?geometry=' .. string.format('%.5f,%.5f', lon, lat) ..
    '&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects&where=1%3D1' ..
    '&outFields=name,idp_validtime&orderByFields=idp_validtime+DESC&resultRecordCount=1&returnGeometry=false&f=json')
end

function OnSetupJson()
  if setup.pendingStart then return SetupStart() end        -- load-time local copy finished
  if not setup.active or not setup.wantJson then return end
  setup.wantJson = false
  local body = SKIN:GetMeasure('MeasureSetupJson'):GetStringValue() or ''
  if setup.step == 'region' then
    -- Read "name" only from the feature's attributes: the reply also lists field
    -- definitions ({"name":"objectid",...}) before the features.
    local attrs = body:match('"attributes"%s*:%s*(%b{})')
    local name = attrs and attrs:match('"name"%s*:%s*"(%u+_[^"]*)"')
    if not name then
      if body:find('"features"%s*:%s*%[%s*%]') then
        setup.active = false
        return setupMsg('No NOAA radar covers this location')
      end
      return OnSetupError('unexpected NOAA reply')
    end
    setup.vals.Region = name:match('^([^_]+)')
    setup.step = 'points'
    setupMsg('Setting up location 2/3')
    return setupJson(SKIN:ReplaceVariables('#NWSApi#') .. '/points/' .. setup.vals.AlertPoint)
  elseif setup.step == 'points' then
    local rs = body:match('"radarStation"%s*:%s*"(%w+)"')
    local stationsUrl = body:match('"observationStations"%s*:%s*"([^"]+)"')
    if rs then
      setup.vals.RadarStation = rs
      setup.vals.NWSRadarURL = 'https://radar.weather.gov/station/' .. rs .. '/standard'
    end
    if not stationsUrl then return setupLayers() end
    setup.step = 'stations'
    setupMsg('Setting up location 3/3')
    return setupJson(stationsUrl .. '?limit=3')
  elseif setup.step == 'stations' then
    local ids = {}
    for id in body:gmatch('"stationIdentifier"%s*:%s*"(%w+)"') do
      if #ids < 3 then ids[#ids + 1] = id end
    end
    setup.vals.ObsStations = table.concat(ids, ',')
    setup.vals.WindStation = ids[1] or ''
    return setupLayers()
  end
end

function OnSetupFile()
  if not setup.active or not setup.wantFile then return end
  local got = SKIN:GetMeasure('MeasureSetupFile'):GetStringValue()
  if not endsWith(got, setup.wantFile) then
    log('setup ignored finish for ' .. tostring(got))
    return
  end
  local ok = isPng(st.dir .. setup.wantFile)
  setup.layerOk[LAYERS[setup.layerIdx].name] = ok
  log('setup layer ' .. setup.wantFile .. ' ok=' .. tostring(ok))
  setup.wantFile = nil
  setupNextLayer()
end

function OnSetupError(msg)
  if setup.pendingStart then return SetupStart() end        -- load-time local copy
  if not setup.active then return end
  log('setup error at ' .. tostring(setup.step) .. ': ' .. tostring(msg))
  if setup.step == 'points' or setup.step == 'stations' then
    if not setup.wantJson then return end
    setup.wantJson = false
    return setupLayers()          -- wind and alerts need NWS; the radar does not
  elseif setup.step == 'layers' then
    if not setup.wantFile then return end
    setup.layerOk[LAYERS[setup.layerIdx].name] = false
    setup.wantFile = nil
    return setupNextLayer()
  end
  setup.wantJson = false
  setup.active = false
  setup.retryAt = os.time() + st.retryDelay
  setupMsg('Setup ' .. tostring(msg) .. '; retrying in ' .. math.floor(st.retryDelay / 60) .. ' min')
end

-- ===================================================================== lifecycle

function Initialize()
  st.dir = SKIN:GetVariable('CURRENTPATH') .. 'DownloadFile\\'
  st.debug = (SKIN:GetVariable('DebugLog', '0') == '1')
  st.slot = SKIN:GetVariable('Slot', 'a')
  if st.slot ~= 'a' and st.slot ~= 'b' then st.slot = 'a' end
  st.obsMs = num('ObsEpochMs', 0)
  st.lastOk = num('LastSuccess', 0)
  st.staleMin = num('StaleMinutes', 35)
  st.alpha = num('RadarAlpha', 215)
  st.tick = num('TickMs', 60000) / 1000
  st.period = num('RefreshMinutes', 15) * st.tick
  st.retryDelay = num('RetrySeconds', 180)
  st.status = ''
  st.pendingMs, st.pendingSlot, st.pendingAt = nil, nil, 0
  st.retryAt, st.lastRetry = nil, 0
  st.lastTick = os.time()
  st.haveImage = st.obsMs > 0 and isPng(slotPath(st.slot))
  local want = table.concat({ SKIN:GetVariable('Latitude'), SKIN:GetVariable('Longitude'),
    SKIN:GetVariable('RadiusKm'), SKIN:GetVariable('Size') }, ',')
  st.want = want
  st.configMismatch = (SKIN:GetVariable('GeneratedFor', '') ~= want) or not isPng(st.dir .. 'layer_land.png')
  if st.configMismatch then
    -- Setup starts once MeasureSetupJson's load-time local copy finishes (or after 5 s).
    setup.pendingStart = true
    setup.initAt = os.time()
    st.setupMessage = 'Setting up location...'
  end

  -- wind
  wind.stations = {}
  for id in (SKIN:GetVariable('ObsStations', '') or ''):gmatch('[^,%s]+') do wind.stations[#wind.stations + 1] = id end
  wind.enabled = SKIN:GetVariable('ShowWind', '0') == '1' and #wind.stations > 0 and not st.configMismatch
  wind.units = (SKIN:GetVariable('WindUnits', 'mph') or 'mph'):lower()
  wind.idx, wind.hops = 1, 0
  if not wind.enabled then
    SKIN:Bang('!DisableMeasure', 'MeasureWind')
    set('MeterWindText', 'Hidden', '1'); set('MeterWindArrow', 'Hidden', '1')
  end

  -- alerts
  alerts.enabled = SKIN:GetVariable('ShowAlerts', '0') == '1' and (SKIN:GetVariable('AlertPoint', '') or '') ~= '' and not st.configMismatch
  if not alerts.enabled then
    SKIN:Bang('!DisableMeasure', 'MeasureAlerts')
    set('MeterAlert', 'Hidden', '1')
  end

  -- replay
  anim.enabled = SKIN:GetVariable('AnimationEnabled', '0') == '1'
  anim.minutes = clamp(num('AnimMinutes', 60), 30, 60)
  anim.maxFrames = clamp(math.floor(num('AnimFrames', 8)), 4, 10)
  anim.maxLoops = clamp(math.floor(num('AnimLoops', 4)), 1, 20)
  anim.files = {}
  for ms in (SKIN:GetVariable('AnimFiles', '') or ''):gmatch('%d+') do anim.files[ms] = true end

  log(string.format('init slot=%s obs=%.0f cached=%s mismatch=%s wind=%s alerts=%s anim=%s',
    st.slot, st.obsMs, tostring(st.haveImage), tostring(st.configMismatch), tostring(wind.enabled), tostring(alerts.enabled), tostring(anim.enabled)))
  render()
end

function Update()
  local now = os.time()
  -- A long gap between ticks means the PC slept (or Rainmeter was frozen). Check soon after.
  if now - st.lastTick > st.tick * 3 then
    log('resume detected, gap ' .. (now - st.lastTick) .. 's')
    st.lastRetry = 0
    st.retryAt = nil
    scheduleRetry(RESUME_DELAY, 'resume')
  end
  st.lastTick = now
  if st.pendingMs and now - st.pendingAt > PENDING_TIMEOUT then
    log('download timed out')
    OnError('download timed out', 'radar')
  end
  if st.retryAt and now >= st.retryAt then
    st.retryAt = nil
    st.lastRetry = now
    log('retrying now')
    fetchNow('MeasureFrame')
  end
  if setup.pendingStart and now - (setup.initAt or now) >= 5 then SetupStart() end
  if not setup.active and setup.retryAt and now >= setup.retryAt then setup.retryAt = nil; SetupStart() end
  if anim.state == 'loading' and now - (anim.startedAt or now) > 90 then AnimStop('timed out') end
  if anim.state == 'paused' and now - (anim.pausedAt or now) > 120 then AnimStop('stopped') end
  render()
  return st.status
end

-- Newest frame time has arrived from MeasureFrame.
function OnFrame()
  if st.configMismatch then render() return end
  local raw = SKIN:GetMeasure('MeasureFrame'):GetStringValue()
  log('OnFrame raw=' .. tostring(raw))
  local ms = tonumber(raw)
  -- Plausible frame times only: not older than a day, not more than an hour ahead.
  local nowMs = os.time() * 1000
  if not ms or ms < nowMs - 86400000 or ms > nowMs + 3600000 then
    return OnError('bad frame time', 'frame')
  end
  if ms == st.obsMs and st.haveImage then
    st.status = ''          -- already showing the newest frame; nothing to download
    log('frame unchanged, no download')
    render()
    return
  end
  if st.pendingMs then
    log('download already in progress, not starting another')
    return
  end
  st.pendingMs, st.pendingAt = ms, os.time()
  st.pendingSlot = (st.slot == 'a') and 'b' or 'a'
  local url = SKIN:ReplaceVariables('#ExportBase#') .. '&time=' .. string.format('%.0f', ms)
  SKIN:Bang('!SetOption', 'MeasureRadar', 'URL', url)
  SKIN:Bang('!SetOption', 'MeasureRadar', 'DownloadFile', 'radar_' .. st.pendingSlot .. '.png')
  log('download -> slot ' .. st.pendingSlot .. ' time=' .. string.format('%.0f', ms))
  SKIN:Bang('!UpdateMeasure', 'MeasureRadar')        -- applies the new options
  fetchNow('MeasureRadar')
end

-- MeasureRadar finished a download.
function OnRadar()
  if not st.pendingMs then return end      -- the load-time local copy; ignore
  -- The load-time local copy can finish after a real download was requested. Accept only
  -- the file we asked for (WebParser's value is the path it just wrote).
  local got = SKIN:GetMeasure('MeasureRadar'):GetStringValue()
  if not endsWith(got, 'radar_' .. st.pendingSlot .. '.png') then
    log('OnRadar ignored finish for ' .. tostring(got))
    return
  end
  local slot, ms = st.pendingSlot, st.pendingMs
  st.pendingMs, st.pendingSlot = nil, nil
  if not isPng(slotPath(slot)) then return OnError('bad image from NOAA', 'check') end
  st.slot, st.obsMs, st.lastOk = slot, ms, os.time()
  st.haveImage = true
  st.status = ''
  st.retryAt = nil
  log('OnRadar ok slot=' .. slot)
  saveState()
  render()
end

function OnError(msg, source)
  log('OnError ' .. tostring(msg) .. ' from ' .. tostring(source) .. ' pending=' .. tostring(st.pendingMs))
  -- WebParser errors for the load-time local copy are not real failures.
  if source == 'radar' and not st.pendingMs then return end
  st.pendingMs, st.pendingSlot = nil, nil
  st.status = msg or 'error'
  scheduleRetry(st.retryDelay, msg or 'error')
  render()
end
