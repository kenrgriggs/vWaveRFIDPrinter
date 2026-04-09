# vWaveRFIDPrinter

A virtual ZPL printer that runs in Docker. Any app that sends ZPL over a raw TCP connection can target it — jobs are captured, parsed, and displayed in a browser UI with a rendered label preview.

## What it does

- Listens on **TCP :9100** for raw ZPL print jobs
- Parses each job for label dimensions, RFID write data, field text, and quantity
- Renders the label to a PNG using the [Labelary API](http://labelary.com) (requires internet)
- Streams job arrivals and log entries to the browser in real time over WebSocket
- Falls back to showing raw ZPL text if Labelary is unreachable

## Prerequisites

- Docker Desktop (or Docker Engine + Compose)
- Internet access for label rendering (Labelary)

## Quick start

```bash
cd vWaveRFIDPrinter
docker compose up -d
```

Open **http://localhost:8080** — the UI will be waiting for jobs.

## Pointing WaveRFIDPrintAgent at it

Change the printer address in `%APPDATA%\WaveRFIDPrintAgent\config.json`:

```json
{
  "printers": [
    { "name": "virtual", "address": "127.0.0.1:9100" }
  ],
  "defaultPrinter": "virtual"
}
```

Send a job from WaveRFIDPrintAgent and it will appear in the UI within a second or two.

## UI layout

```
+---------------------+-------------------------+
|   Label Preview     |   Print Queue           |
|                     |   (clickable job list)  |
|  [rendered image]   +-------------------------|
|                     |   System Log            |
|  job metadata       |   (live, auto-scroll)   |
|  RFID data          |                         |
|  ▶ Raw ZPL          |                         |
+---------------------+-------------------------+
```

- Click any job in the queue to preview it on the left
- **▶ Raw ZPL** expands the full ZPL source for that job
- **Clear All** button resets jobs and logs
- Log auto-scroll can be toggled

## ZPL commands recognized

| Command | Parsed field |
|---------|-------------|
| `^PW`   | Label width (dots → inches) |
| `^LL`   | Label length (dots → inches) |
| `^RFW,H` / `^RFW,A` | RFID write data (Hex or ASCII) |
| `^FD`   | Human-readable field text |
| `^PQ`   | Print quantity |

96-bit hex EPC values are identified as SGTIN-96, SSCC-96, or SGLN-96 based on the header byte.

## Configuration

All settings are environment variables in `docker-compose.yml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `TCP_PORT` | `9100` | Port that accepts ZPL print jobs |
| `HTTP_PORT` | `8080` | Port for the web UI |
| `DPMM` | `8` | Printer resolution (8 = 203 DPI, 12 = 300 DPI) |
| `LABELARY_URL` | `http://api.labelary.com` | ZPL rendering service |
| `MAX_JOBS` | `200` | How many jobs to keep in memory |

## Useful commands

```bash
# Start
docker compose up -d

# Stop
docker compose down

# Tail logs
docker compose logs -f

# Rebuild after code changes
docker compose build && docker compose up -d

# Send a test ZPL job manually (requires Node.js)
node -e "
const net = require('net');
const zpl = '^XA^PW799^LL203^RFW,H^FD3000E200001234567890ABCD^FS^FO50,50^ADN,18,10^FDTEST LABEL^FS^XZ';
const c = net.createConnection(9100, '127.0.0.1', () => { c.write(zpl); c.end(); });
"
```

## How jobs are processed

1. TCP client connects and sends raw bytes
2. Server buffers data and extracts complete `^XA...^XZ` blocks (handles chunked TCP delivery and multiple jobs per connection)
3. Job is stored in memory and broadcast to all connected browsers via WebSocket
4. ZPL is POSTed to Labelary asynchronously; the rendered PNG is broadcast when it arrives
5. Browser updates the job status and swaps in the image without a page reload

The TCP connection requires no handshake or acknowledgment — the client can connect, send, and disconnect immediately, matching how raw TCP print ports work.
