<#
.SYNOPSIS
    Sends RAW ZPL to a Windows print queue — the same way the agent does.

.DESCRIPTION
    Use this to smoke-test the USB-capture queue WITHOUT the agent. It writes raw
    bytes to the named queue via the Windows spooler RAW datatype (winspool), so
    it exercises the exact path the agent's usb-printer.js uses.

    Do NOT use Out-Printer to test — that renders through the driver's GDI path,
    not RAW, so Generic/Text-Only chokes ("Settings...not valid") and the bytes
    never arrive as clean ZPL. This script bypasses all of that.

.PARAMETER PrinterName
    The Windows queue to print to. Default: "vWaveRFID USB".

.PARAMETER Zpl
    The ZPL to send. Defaults to a small test label.

.EXAMPLE
    .\test-usb-raw.ps1
    # Sends a default "USB RAW TEST" label to the vWaveRFID USB queue.

.NOTES
    Does NOT require elevation. Requires the queue to exist (run
    setup-usb-capture-queue.ps1 first) and the Docker container to be up.
#>

param(
    [string]$PrinterName = "vWaveRFID USB",
    [string]$Zpl = "^XA^PW400^LL300^FO40,40^A0N,40,40^FDUSB RAW TEST^FS^FO40,110^A0N,28,28^FD$(Get-Date -Format HH:mm:ss)^FS^XZ"
)

$ErrorActionPreference = 'Stop'

# Inline C# that calls the Windows print spooler directly with the RAW datatype.
$code = @'
using System;
using System.Runtime.InteropServices;

public class RawPrinterHelper {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct DOCINFOA {
        [MarshalAs(UnmanagedType.LPWStr)] public string pDocName;
        [MarshalAs(UnmanagedType.LPWStr)] public string pOutputFile;
        [MarshalAs(UnmanagedType.LPWStr)] public string pDataType;
    }
    [DllImport("winspool.Drv", EntryPoint="OpenPrinterW", SetLastError=true, CharSet=CharSet.Unicode, ExactSpelling=true, CallingConvention=CallingConvention.StdCall)]
    public static extern bool OpenPrinter(string src, out IntPtr hPrinter, IntPtr pd);
    [DllImport("winspool.Drv", EntryPoint="ClosePrinter", SetLastError=true, ExactSpelling=true, CallingConvention=CallingConvention.StdCall)]
    public static extern bool ClosePrinter(IntPtr hPrinter);
    [DllImport("winspool.Drv", EntryPoint="StartDocPrinterW", SetLastError=true, CharSet=CharSet.Unicode, ExactSpelling=true, CallingConvention=CallingConvention.StdCall)]
    public static extern bool StartDocPrinter(IntPtr hPrinter, Int32 level, ref DOCINFOA di);
    [DllImport("winspool.Drv", EntryPoint="EndDocPrinter", SetLastError=true, ExactSpelling=true, CallingConvention=CallingConvention.StdCall)]
    public static extern bool EndDocPrinter(IntPtr hPrinter);
    [DllImport("winspool.Drv", EntryPoint="StartPagePrinter", SetLastError=true, ExactSpelling=true, CallingConvention=CallingConvention.StdCall)]
    public static extern bool StartPagePrinter(IntPtr hPrinter);
    [DllImport("winspool.Drv", EntryPoint="EndPagePrinter", SetLastError=true, ExactSpelling=true, CallingConvention=CallingConvention.StdCall)]
    public static extern bool EndPagePrinter(IntPtr hPrinter);
    [DllImport("winspool.Drv", EntryPoint="WritePrinter", SetLastError=true, ExactSpelling=true, CallingConvention=CallingConvention.StdCall)]
    public static extern bool WritePrinter(IntPtr hPrinter, IntPtr pBytes, Int32 dwCount, out Int32 dwWritten);

    public static void SendBytesToPrinter(string printerName, byte[] bytes) {
        IntPtr hPrinter;
        DOCINFOA di = new DOCINFOA();
        di.pDocName  = "WaveRFID RAW Test";
        di.pDataType = "RAW";
        if (!OpenPrinter(printerName, out hPrinter, IntPtr.Zero))
            throw new Exception("OpenPrinter failed (" + Marshal.GetLastWin32Error() + "). Is the queue name correct?");
        try {
            if (!StartDocPrinter(hPrinter, 1, ref di)) throw new Exception("StartDocPrinter failed: " + Marshal.GetLastWin32Error());
            try {
                if (!StartPagePrinter(hPrinter)) throw new Exception("StartPagePrinter failed: " + Marshal.GetLastWin32Error());
                IntPtr p = Marshal.AllocCoTaskMem(bytes.Length);
                try {
                    Marshal.Copy(bytes, 0, p, bytes.Length);
                    int written;
                    if (!WritePrinter(hPrinter, p, bytes.Length, out written)) throw new Exception("WritePrinter failed: " + Marshal.GetLastWin32Error());
                } finally { Marshal.FreeCoTaskMem(p); }
                EndPagePrinter(hPrinter);
            } finally { EndDocPrinter(hPrinter); }
        } finally { ClosePrinter(hPrinter); }
    }
}
'@

Add-Type -TypeDefinition $code -Language CSharp

Write-Host "Sending RAW ZPL to '$PrinterName' ..." -ForegroundColor Cyan
$bytes = [System.Text.Encoding]::ASCII.GetBytes($Zpl)
[RawPrinterHelper]::SendBytesToPrinter($PrinterName, $bytes)
Write-Host "Sent $($bytes.Length) bytes. Check the Docker UI at http://localhost:8080 — it should appear badged USB." -ForegroundColor Green
