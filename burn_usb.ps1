# burn_usb.ps1 - write disk.img to a USB stick as a bootable raw image.
# Self-contained: derives disk.img from $PSScriptRoot at runtime (NO Chinese
# path literal in the source, so PowerShell 5.1's ANSI parsing can't mangle it),
# copies it to an ASCII temp path, then cleans + raw-writes the target disk.
#
# SAFETY: refuses any disk that is not a small USB non-system disk. ALWAYS
# confirm the disk number with the user first. This ERASES the target disk.
#
# Usage (elevated):  powershell -ExecutionPolicy Bypass -File burn_usb.ps1 -DiskNumber <N>
# Non-admin caller:  Start-Process powershell -Verb RunAs -ArgumentList '-ExecutionPolicy','Bypass','-File',$thisScript,'-DiskNumber','<N>' -Wait
param(
    [Parameter(Mandatory = $true)][int]$DiskNumber
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP 'jev_burn_usb.log'
function L($m) { Add-Content -Path $log -Value $m -Encoding utf8 }
Set-Content -Path $log -Value "=== burn start $(Get-Date -Format o)  disk=$DiskNumber ===" -Encoding utf8

try {
    $d = Get-Disk -Number $DiskNumber
    L "disk$DiskNumber BusType=$($d.BusType) Size=$($d.Size) IsSystem=$($d.IsSystem) IsBoot=$($d.IsBoot)"

    # --- safety gates ---
    if ($d.BusType -ne 'USB')      { throw "ABORT: disk$DiskNumber BusType is $($d.BusType), not USB" }
    if ($d.IsSystem -or $d.IsBoot) { throw "ABORT: disk$DiskNumber is a system/boot disk" }
    if ($d.Size -gt 64GB)          { throw "ABORT: disk$DiskNumber is $([math]::Round($d.Size/1GB,1)) GB (>64), refusing" }

    # disk.img sits next to this script (path may contain CJK -> copy to ASCII temp)
    $img = Join-Path $PSScriptRoot 'disk.img'
    $tmp = Join-Path $env:TEMP 'jev_disk_burn.img'
    Copy-Item -LiteralPath $img -Destination $tmp -Force
    $bytes = [IO.File]::ReadAllBytes($tmp)
    L "img bytes=$($bytes.Length)"
    if ($bytes.Length % 512 -ne 0) { throw "ABORT: image not sector-aligned" }

    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    L "cleared partition table"
    Start-Sleep -Milliseconds 500      # removable media can't go offline; cleared = no volume lock

    $path = "\\.\PhysicalDrive$DiskNumber"
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $fs.Write($bytes, 0, $bytes.Length)
    $fs.Flush(); $fs.Close()
    L "wrote $($bytes.Length) bytes to $path"
    Start-Sleep -Milliseconds 300

    $fr = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $buf = New-Object byte[] 512
    [void]$fr.Read($buf, 0, 512); $fr.Close()
    L ("readback sig = 0x{0:X2}{1:X2} (want 0x55 0xAA)" -f $buf[510], $buf[511])
    if ($buf[510] -eq 0x55 -and $buf[511] -eq 0xAA) { L "VERIFY OK - boot signature present" }
    else { L "VERIFY FAIL - signature mismatch" }
    L "=== done ==="
}
catch {
    L ("ERROR: " + $_.Exception.Message)
}
