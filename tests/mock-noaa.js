// Local stand-in for NOAA's ImageServer and api.weather.gov, used only by
// tests\Test-SkinBehavior.ps1. Listens on 127.0.0.1 only. Node standard library only.
//
//   GET /ImageServer/query        newest frame, or the newest N with resultRecordCount=N
//   GET /ImageServer/exportImage  solid-colour PNG; colour = the requested frame's index % 4
//   GET /nws/stations/<id>/observations/latest   real NWS reply (fixtures/), fresh timestamp
//   GET /nws/alerts/active        real NWS reply with 3 alerts, or none (alerts=none)
//   GET /control?mode=..&advance=1&ageMin=N&seed=N&alerts=fixture|none&obsNull=KMIA,..&clear=1
//   GET /log                      every request received (excluding /log and /control)
//
// Modes: normal | queryerror | export500 | exportjson | exporttruncated | exportslow | down
'use strict';
const http = require('http');
const zlib = require('zlib');
const fs = require('fs');
const path = require('path');

const port = Number(process.argv[2] || 8765);
const fx = (f) => fs.readFileSync(path.join(__dirname, 'fixtures', f), 'utf8');
const OBS_VALID = fx('obs-KOPF-valid.json');
const OBS_NULL = fx('obs-KMIA-nullwind.json');
const ALERTS = fx('alerts-miami-2026-11-18.json');
const REGION = fx('region-miami-2026-11-19.json');
const COLORS = [[230, 40, 40], [40, 90, 230], [40, 200, 70], [240, 220, 30]];

const state = { mode: 'normal', frames: [{ ms: Date.now() - 2 * 60000, idx: 0 }], alerts: 'fixture', obsNull: new Set(['KMIA']), coverage: true };
const latest = () => state.frames[state.frames.length - 1];
const log = [];

const crcTable = new Int32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c;
});
function crc32(buf) {
  let c = -1;
  for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function solidPng(w, h, [r, g, b], alpha = 255) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6;
  const row = Buffer.alloc(1 + w * 4);
  for (let x = 0; x < w; x++) { row[1 + x * 4] = r; row[2 + x * 4] = g; row[3 + x * 4] = b; row[4 + x * 4] = alpha; }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(Buffer.concat(Array(h).fill(row)))), chunk('IEND', Buffer.alloc(0)),
  ]);
}
// Observation fixture with this station's id and a timestamp 10 minutes ago.
function obsFor(id) {
  const ts = new Date(Date.now() - 10 * 60000).toISOString().replace(/\.\d+Z$/, '+00:00');
  return (state.obsNull.has(id) ? OBS_NULL : OBS_VALID)
    .replace(/"timestamp":\s*"[^"]+"/, `"timestamp": "${ts}"`)
    .replace(/"stationId":\s*"[^"]+"/, `"stationId": "${id}"`);
}

http.createServer((req, res) => {
  const u = new URL(req.url, 'http://127.0.0.1');
  const q = u.searchParams;
  if (u.pathname !== '/log' && u.pathname !== '/control') {
    log.push({ at: new Date().toISOString(), path: u.pathname, time: q.get('time'), count: q.get('resultRecordCount'), mode: state.mode, ua: req.headers['user-agent'] || '' });
  }
  const json = (code, body) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(typeof body === 'string' ? body : JSON.stringify(body)); };

  if (u.pathname === '/log') return json(200, log);
  if (u.pathname === '/control') {
    if (q.get('mode')) state.mode = q.get('mode');
    if (q.get('alerts')) state.alerts = q.get('alerts');
    if (q.has('obsNull')) state.obsNull = new Set(q.get('obsNull').split(',').filter(Boolean));
    if (q.get('seed')) {
      const n = Number(q.get('seed')), end = Date.now() - 2 * 60000;
      state.frames = Array.from({ length: n }, (_, k) => ({ ms: end - (n - 1 - k) * 5 * 60000, idx: k }));
    }
    if (q.get('advance')) state.frames.push({ ms: Date.now() - Number(q.get('ageMin') || 2) * 60000, idx: latest().idx + 1 });
    if (q.get('clear')) log.length = 0;
    if (q.has('coverage')) state.coverage = q.get('coverage') !== '0';
    return json(200, { mode: state.mode, frames: state.frames.length, latest: latest(), color: COLORS[latest().idx % 4] });
  }
  if (state.mode === 'down') return req.socket.destroy();

  if (u.pathname.endsWith('/query') && q.get('geometry')) {
    // Setup's "which mosaic covers this point" query.
    // Real NOAA reply (fields list first, then features), so parsing is tested on the real shape.
    if (!state.coverage) return json(200, { ...JSON.parse(REGION), features: [] });
    return json(200, REGION);
  }
  if (u.pathname.endsWith('/query')) {
    if (state.mode === 'queryerror') return json(200, { error: { code: 400, message: 'Failed to execute query.', details: [] } });
    const n = Math.max(1, Number(q.get('resultRecordCount') || 1));
    const feats = state.frames.slice().reverse().slice(0, n).map((f) => ({ attributes: { idp_validtime: f.ms } }));
    return json(200, { objectIdFieldName: 'objectid', features: feats });
  }
  if (u.pathname.endsWith('/exportImage')) {
    const [w, h] = (q.get('size') || '300,300').split(',').map(Number);
    if (state.mode === 'export500') { res.writeHead(500); return res.end('server error'); }
    if (state.mode === 'exportjson') return json(200, { error: { code: 500, message: 'Error exporting image', details: [] } });
    const fr = state.frames.find((f) => String(f.ms) === q.get('time')) || latest();
    const png = solidPng(w, h, COLORS[fr.idx % 4]);
    if (state.mode === 'exporttruncated') { res.writeHead(200, { 'Content-Type': 'image/png' }); return res.end(png.subarray(0, Math.floor(png.length / 2))); }
    const send = () => { res.writeHead(200, { 'Content-Type': 'image/png' }); res.end(png); };
    return state.mode === 'exportslow' ? setTimeout(send, 8000) : send();
  }
  if (/^\/nws\/points\/[-\d.]+,[-\d.]+$/.test(u.pathname)) {
    return json(200, { properties: { gridId: 'MFL', radarStation: 'KAMX', observationStations: `http://127.0.0.1:${port}/nws/gridpoints/MFL/110,50/stations` } });
  }
  if (/^\/nws\/gridpoints\/[A-Z]+\/\d+,\d+\/stations$/.test(u.pathname)) {
    const ids = ['KMIA', 'KOPF', 'KHWO', 'KFLL'];   // 4, so the skin's own limit of 3 is tested
    return json(200, { features: ids.map((id) => ({ properties: { stationIdentifier: id } })) });
  }
  if (/^\/tiger\/.+\/MapServer\/export$/.test(u.pathname)) {
    const [w, h] = (q.get('size') || '300,300').split(',').map(Number);
    // Land is solid; the other layers are empty, like open ocean.
    const png = u.pathname.includes('USLandmass') ? solidPng(w, h, [240, 240, 235]) : solidPng(w, h, [0, 0, 0], 0);
    res.writeHead(200, { 'Content-Type': 'image/png' }); return res.end(png);
  }
  const m = u.pathname.match(/^\/nws\/stations\/([A-Z0-9]+)\/observations\/latest$/);
  if (m) return json(200, obsFor(m[1]));
  if (u.pathname === '/nws/alerts/active') {
    return json(200, state.alerts === 'none' ? '{"type":"FeatureCollection","features":[]}' : ALERTS);
  }
  res.writeHead(404); res.end();
}).listen(port, '127.0.0.1', () => console.log(`mock NOAA on http://127.0.0.1:${port}`));
