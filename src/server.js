'use strict';

const net     = require('net');
const http    = require('http');
const express = require('express');
const WebSocket = require('ws');
const path    = require('path');

// ─── Config ───────────────────────────────────────────────────────────────────

const TCP_PORT    = parseInt(process.env.TCP_PORT    || '9100');
const HTTP_PORT   = parseInt(process.env.HTTP_PORT   || '8080');
const DPMM        = parseInt(process.env.DPMM        || '8');    // 8dpmm = 203dpi
const LABELARY    = process.env.LABELARY_URL || 'http://api.labelary.com';
const MAX_JOBS    = parseInt(process.env.MAX_JOBS    || '200');
const MAX_LOGS    = 1000;

// ─── State ────────────────────────────────────────────────────────────────────

const jobs = [];   // newest first
const logs = [];
let jobCounter = 0;

// ─── Broadcast ────────────────────────────────────────────────────────────────

const app        = express();
const httpServer = http.createServer(app);
const wss        = new WebSocket.Server({ server: httpServer });

function broadcast(type, payload) {
  const msg = JSON.stringify({ type, payload });
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN) client.send(msg);
  }
}

// ─── Logging ──────────────────────────────────────────────────────────────────

function log(level, message) {
  const entry = { ts: new Date().toISOString(), level, message };
  logs.push(entry);
  if (logs.length > MAX_LOGS) logs.shift();
  broadcast('log', entry);
  const prefix = level === 'error' ? '\x1b[31m' : level === 'warn' ? '\x1b[33m' : level === 'debug' ? '\x1b[90m' : '\x1b[36m';
  console.log(`${prefix}[${entry.ts}] [${level.toUpperCase()}]\x1b[0m ${message}`);
}

// ─── ZPL Parsing ──────────────────────────────────────────────────────────────

function parseZPL(zpl) {
  const DPI = DPMM * 25.4; // dots per inch

  // Dimensions from ZPL commands
  const pwMatch = zpl.match(/\^PW(\d+)/i);
  const llMatch = zpl.match(/\^LL(\d+)/i);
  const printWidthDots  = pwMatch ? parseInt(pwMatch[1]) : null;
  const labelLengthDots = llMatch ? parseInt(llMatch[1]) : null;

  let widthInches  = printWidthDots  ? parseFloat((printWidthDots  / DPI).toFixed(3)) : 4;
  let heightInches = labelLengthDots ? parseFloat((labelLengthDots / DPI).toFixed(3)) : 6;

  // Clamp to sane values for Labelary
  widthInches  = Math.min(Math.max(widthInches,  0.5), 15);
  heightInches = Math.min(Math.max(heightInches, 0.5), 15);

  // RFID write: ^RFW,{H|A}[,bytes,blocks,mem]^FD{data}^FS
  const rfidMatch = zpl.match(/\^RFW,([HA])(?:[^,\^]*(?:,[^,\^]*){0,3})?\^FD([^\^]+)/i);
  const rfidFormat = rfidMatch ? (rfidMatch[1].toUpperCase() === 'H' ? 'Hex' : 'ASCII') : null;
  const rfidData   = rfidMatch ? rfidMatch[2].trim() : null;

  // EPC header byte guess (for Hex EPC Gen2)
  let epcClass = null;
  if (rfidData && rfidFormat === 'Hex' && rfidData.length === 24) {
    const header = parseInt(rfidData.substring(0, 2), 16);
    if ((header & 0xE0) === 0x30) epcClass = 'SGTIN-96';
    else if ((header & 0xE0) === 0x35) epcClass = 'SSCC-96';
    else if ((header & 0xE0) === 0x38) epcClass = 'SGLN-96';
  }

  // Memory bank target: ^RFW mem param
  const rfidMem = rfidMatch
    ? (() => { const m = rfidMatch[0].match(/\^RFW,[HA],\d+,\d+,(\d)/i); return m ? ['Reserved','EPC','TID','User'][parseInt(m[1])] : 'EPC'; })()
    : null;

  // Quantity ^PQ
  const pqMatch = zpl.match(/\^PQ(\d+)/i);
  const quantity = pqMatch ? parseInt(pqMatch[1]) : 1;

  // Collect all ^FD field values
  const fieldData = [];
  const fdRe = /\^FD([^\^]+)/gi;
  let fdMatch;
  while ((fdMatch = fdRe.exec(zpl)) !== null) {
    const v = fdMatch[1].trim();
    if (v && !fieldData.includes(v)) fieldData.push(v);
  }

  return {
    printWidthDots, labelLengthDots,
    widthInches, heightInches,
    rfidData, rfidFormat, rfidMem, epcClass,
    fieldData, quantity
  };
}

// ─── Labelary Rendering ───────────────────────────────────────────────────────

async function renderZPL(zpl, meta) {
  const url = `${LABELARY}/v1/printers/${DPMM}dpmm/labels/${meta.widthInches}x${meta.heightInches}/0/`;
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': 'image/png'
      },
      body: zpl,
      signal: AbortSignal.timeout(12000)
    });
    if (!res.ok) {
      log('warn', `Labelary HTTP ${res.status} for job render`);
      return null;
    }
    const buf = Buffer.from(await res.arrayBuffer());
    return buf.toString('base64');
  } catch (err) {
    log('warn', `Labelary unreachable: ${err.message} — label stored as ZPL only`);
    return null;
  }
}

// ─── Job Processing ───────────────────────────────────────────────────────────

async function processJob(zpl, clientAddr) {
  const id = ++jobCounter;
  const meta = parseZPL(zpl);

  const job = { id, ts: new Date().toISOString(), clientAddr, zpl, meta, status: 'rendering', image: null };

  jobs.unshift(job);
  if (jobs.length > MAX_JOBS) jobs.pop();

  const rfidNote = meta.rfidData
    ? ` | RFID(${meta.rfidFormat}): ${meta.rfidData}`
    : '';
  log('info', `Job #${id} from ${clientAddr} | ${zpl.length} bytes | ${meta.widthInches}"×${meta.heightInches}"${rfidNote}`);

  broadcast('job', jobView(job));

  job.image = await renderZPL(zpl, meta);
  job.status = job.image ? 'rendered' : 'render_failed';

  if (job.image) {
    log('info', `Job #${id} rendered OK`);
  } else {
    log('warn', `Job #${id} render failed — Labelary unreachable or invalid ZPL`);
  }

  broadcast('job_update', jobView(job));
}

// Strip raw ZPL from broadcast (client fetches on demand to keep WS messages small)
function jobView(job) {
  const { zpl, ...rest } = job;
  return { ...rest, zplLength: zpl.length };
}

// ─── TCP Server ───────────────────────────────────────────────────────────────

const tcpServer = net.createServer((socket) => {
  const client = `${socket.remoteAddress}:${socket.remotePort}`;
  log('info', `TCP connect: ${client}`);

  let buffer = '';

  socket.on('data', (chunk) => {
    buffer += chunk.toString('utf8');
    log('debug', `${chunk.length} bytes from ${client}`);

    // Extract complete ^XA...^XZ jobs — one connection may send multiple
    while (true) {
      const start = buffer.search(/\^XA/i);
      if (start === -1) { buffer = ''; break; }       // No job start — discard preamble

      const end = buffer.search(/\^XZ/i);
      if (end === -1) break;                           // Incomplete job — wait for more data

      const zpl = buffer.substring(start, end + 3);   // inclusive of ^XZ
      buffer = buffer.substring(end + 3);

      // Kick off async, don't block the TCP read loop
      processJob(zpl, client).catch(err => log('error', `processJob: ${err.message}`));
    }
  });

  socket.on('end',   () => log('info',  `TCP disconnect: ${client}`));
  socket.on('error', (err) => log('error', `Socket [${client}]: ${err.message}`));
});

// ─── HTTP / REST ──────────────────────────────────────────────────────────────

app.use(express.static(path.join(__dirname, 'public')));

// Initial page load state
app.get('/api/state', (req, res) => {
  res.json({
    jobs: jobs.map(jobView),
    logs: logs.slice(-300),
    stats: { totalJobs: jobCounter }
  });
});

// Raw ZPL for a specific job (fetched on-demand by the browser)
app.get('/api/jobs/:id/zpl', (req, res) => {
  const job = jobs.find(j => j.id === parseInt(req.params.id));
  if (!job) return res.status(404).json({ error: 'not found' });
  res.type('text/plain').send(job.zpl);
});

// Clear everything
app.delete('/api/jobs', (req, res) => {
  jobs.length = 0;
  logs.length = 0;
  broadcast('cleared', {});
  log('info', 'Jobs and logs cleared');
  res.json({ ok: true });
});

// ─── WebSocket ────────────────────────────────────────────────────────────────

wss.on('connection', (ws, req) => {
  const origin = req.socket.remoteAddress;
  log('debug', `Browser connected from ${origin}`);
  ws.on('close', () => log('debug', `Browser disconnected from ${origin}`));
});

// ─── Start ────────────────────────────────────────────────────────────────────

tcpServer.listen(TCP_PORT, '0.0.0.0', () =>
  log('info', `TCP print server ready on 0.0.0.0:${TCP_PORT}`)
);

httpServer.listen(HTTP_PORT, '0.0.0.0', () =>
  log('info', `Web UI ready at http://localhost:${HTTP_PORT}`)
);
