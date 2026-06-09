<#
.SYNOPSIS
    Creates a Windows print queue that captures RAW ZPL and forwards it to the
    vWaveRFIDPrinter Docker container's USB-capture port (9101).

.DESCRIPTION
    This is the interim "virtual USB printer" target. It lets you prototype the
    agent's USB print path (winspool RAW writes to a named printer) WITHOUT a
    physical printer or label stock — the bytes the agent "prints over USB" get
    captured and rendered as a label preview in the Docker UI, tagged USB.

    How it works:
      1. A Standard TCP/IP printer PORT is created pointing at 127.0.0.1:9101
         using the RAW protocol (the same protocol real network label printers
         use on port 9100). Anything spooled to it is streamed, bytes-as-is,
         to that socket.
      2. A printer QUEUE is created on that port using the built-in
         "Generic / Text Only" driver. When the agent prints with the RAW
         datatype, the spooler bypasses driver rendering and passes the ZPL
         through untouched — exactly what a ZPL printer expects.

    The agent simply prints to this queue BY NAME (e.g. "vWaveRFID USB") instead
    of opening a TCP socket. When your real Printronix + labels arrive, point the
    agent at the real USB printer's queue name instead — zero code changes.

.PARAMETER PrinterName
    Display name of the capture queue. Default: "vWaveRFID USB".

.PARAMETER PortHost
    Host the spooler streams captured bytes to. Default: 127.0.0.1
    (use the Docker host IP if the container runs on another machine).

.PARAMETER PortNumber
    TCP port the container's USB-capture listener is bound to. Default: 9101.

.PARAMETER Remove
    Tear down the queue and port instead of creating them.

.EXAMPLE
    # Create the capture queue (run from an elevated PowerShell):
    .\setup-usb-capture-queue.ps1

.EXAMPLE
    # Remove it later:
    .\setup-usb-capture-queue.ps1 -Remove

.NOTES
    Requires an elevated (Administrator) PowerShell session — adding printer
    ports and queues is a privileged operation.
#>

# ──────────────────────────────────────────────────────────────────────────────
#  Parameters
# ──────────────────────────────────────────────────────────────────────────────
param(
    [string]$PrinterName = "vWaveRFID USB",        # queue name the agent prints to
    [string]$PortHost    = "127.0.0.1",            # where captured bytes are streamed
    [int]   $PortNumber  = 9103,                   # container's USB-capture port (NOT 9101 — the agent owns 9101)
    [switch]$Remove                                # tear-down mode
)

# Stop on the first unhandled error so we never half-configure the queue.
$ErrorActionPreference = "Stop"

# Derive a port object name from the host:port so repeated runs are idempotent.
$PortName  = "vWaveUSB_${PortHost}_${PortNumber}"
$DriverName = "Generic / Text Only"               # built into every Windows install

# ──────────────────────────────────────────────────────────────────────────────
#  Admin check — adding ports/queues needs elevation
# ──────────────────────────────────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent() `
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run from an elevated (Administrator) PowerShell." -ForegroundColor Red
    exit 1
}

# ──────────────────────────────────────────────────────────────────────────────
#  Tear-down mode
# ──────────────────────────────────────────────────────────────────────────────
if ($Remove) {
    Write-Host "`nRemoving capture queue '$PrinterName'..." -ForegroundColor Yellow

    # Remove the printer first (a port can't be deleted while a queue uses it).
    if (Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue) {
        Remove-Printer -Name $PrinterName
        Write-Host "  Removed printer:  $PrinterName" -ForegroundColor Green
    } else {
        Write-Host "  Printer not found (already gone): $PrinterName" -ForegroundColor DarkGray
    }

    # Then remove the TCP/IP port.
    if (Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue) {
        Remove-PrinterPort -Name $PortName
        Write-Host "  Removed port:     $PortName" -ForegroundColor Green
    } else {
        Write-Host "  Port not found (already gone):   $PortName" -ForegroundColor DarkGray
    }

    Write-Host "`nDone.`n" -ForegroundColor Green
    exit 0
}

# ──────────────────────────────────────────────────────────────────────────────
#  Create mode
# ──────────────────────────────────────────────────────────────────────────────
Write-Host "`nSetting up USB-capture print queue" -ForegroundColor Cyan
Write-Host "  Queue : $PrinterName"
Write-Host "  Target: ${PortHost}:${PortNumber} (RAW)`n"

# Step 1: the RAW TCP/IP port that streams spooled bytes to the container.
# Add-PrinterPort with -PrinterHostAddress + -PortNumber defaults to the RAW
# protocol — exactly how a network label printer's 9100 port behaves.
if (Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue) {
    Write-Host "Port '$PortName' already exists — reusing it." -ForegroundColor DarkGray
} else {
    Write-Host "Creating RAW port $PortName -> ${PortHost}:${PortNumber} ..." -ForegroundColor Yellow
    try {
        Add-PrinterPort -Name $PortName -PrinterHostAddress $PortHost -PortNumber $PortNumber -ErrorAction Stop
    } catch {
        throw "Add-PrinterPort failed: $($_.Exception.Message)"
    }

    # Add-PrinterPort can return BEFORE the spooler finishes registering the port,
    # which makes the Add-Printer below fail with "port does not exist". Poll until
    # the port actually shows up (this was the race you hit on the first run).
    $deadline = (Get-Date).AddSeconds(10)
    while (-not (Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue)) {
        if ((Get-Date) -gt $deadline) {
            throw "Port '$PortName' did not register within 10s. Re-run the script, or add it manually in Print Management."
        }
        Start-Sleep -Milliseconds 400
    }
    Write-Host "Created RAW port: $PortName -> ${PortHost}:${PortNumber}" -ForegroundColor Green
}

# Step 2: the queue itself, on the Generic / Text Only driver.
# RAW-datatype jobs pass through this driver untouched, so the ZPL arrives
# at the container byte-for-byte.
if (Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue) {
    # If a printer already exists, make sure it points at the RIGHT port — a
    # half-finished earlier run may have left it bound to a stale/missing port.
    $existing = Get-Printer -Name $PrinterName
    if ($existing.PortName -ne $PortName) {
        Write-Host "Printer '$PrinterName' exists but points at port '$($existing.PortName)' — repointing to '$PortName'." -ForegroundColor Yellow
        Set-Printer -Name $PrinterName -PortName $PortName
    } else {
        Write-Host "Printer '$PrinterName' already exists and points at the right port — reusing it." -ForegroundColor DarkGray
    }
} else {
    # Even after Get-PrinterPort confirms the port, the spooler can briefly still
    # reject it with "port does not exist". Retry a few times through that race
    # rather than bailing (this was the failure you hit).
    $created = $false
    for ($attempt = 1; $attempt -le 5 -and -not $created; $attempt++) {
        try {
            Add-Printer -Name $PrinterName -DriverName $DriverName -PortName $PortName -ErrorAction Stop
            $created = $true
        } catch {
            if ($attempt -eq 5) {
                throw "Add-Printer failed after $attempt attempts: $($_.Exception.Message)"
            }
            Write-Host "  Add-Printer attempt $attempt failed (port not ready yet) — retrying..." -ForegroundColor DarkYellow
            Start-Sleep -Milliseconds 800
        }
    }
    Write-Host "Created printer:  $PrinterName ($DriverName)" -ForegroundColor Green
}

# ──────────────────────────────────────────────────────────────────────────────
#  Summary
# ──────────────────────────────────────────────────────────────────────────────
Write-Host "`nReady." -ForegroundColor Green
Write-Host "Point the agent's USB printer at the queue name: " -NoNewline
Write-Host "$PrinterName" -ForegroundColor Cyan
Write-Host "Make sure the Docker container is up (docker compose up -d) so port $PortNumber is listening.`n"
