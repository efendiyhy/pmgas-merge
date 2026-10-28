# EK Air Quality Hub - visible terminal / foreground server (REV13)
# Close THIS terminal window (or press Ctrl+C) to stop its server process.
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Data = Join-Path $Root 'data'
$Logs = Join-Path $Data 'logs'
New-Item -ItemType Directory -Force -Path $Data, $Logs | Out-Null
$Port = if ($env:ESP_LAN_PORT) { [int]$env:ESP_LAN_PORT } else { 8787 }
$BaseUrl = "http://127.0.0.1:$Port"
$Child = $null

function Test-HubRunning {
    try {
        $status = Invoke-RestMethod -Uri ($BaseUrl + '/api/status') -TimeoutSec 1 -ErrorAction Stop
        return ($status.app_id -eq 'ek-laptop-server')
    } catch { return $false }
}

# Unlike calling python.exe directly, .NET ProcessStartInfo safely ignores broken
# Python installations (including the Windows 'No pyvenv.cfg file' error).
function Invoke-PythonProbe {
    param([string]$Executable, [string]$Arguments)
    if (-not $Executable -or -not (Test-Path -LiteralPath $Executable -PathType Leaf)) { return $null }
    $Process = $null
    try {
        $Psi = New-Object System.Diagnostics.ProcessStartInfo
        $Psi.FileName = $Executable
        $Psi.Arguments = $Arguments
        $Psi.UseShellExecute = $false
        $Psi.CreateNoWindow = $true
        $Psi.RedirectStandardOutput = $true
        $Psi.RedirectStandardError = $true
        $Process = [System.Diagnostics.Process]::Start($Psi)
        if (-not $Process.WaitForExit(6000)) {
            try { $Process.Kill() } catch {}
            return $null
        }
        if ($Process.ExitCode -ne 0) { return $null }
        return $Process.StandardOutput.ReadToEnd().Trim()
    } catch { return $null }
    finally { if ($null -ne $Process) { $Process.Dispose() } }
}

function Test-Python {
    param([string]$Candidate)
    $check = Invoke-PythonProbe -Executable $Candidate -Arguments '-c "import sys;print(int(sys.version_info >= (3,9) and sys.prefix == sys.base_prefix))"'
    return ($check -eq '1')
}

function Find-Python {
    $PathFile = Join-Path $Root '.python_path'
    if (Test-Path -LiteralPath $PathFile) {
        $saved = (Get-Content -LiteralPath $PathFile -Raw).Trim().Trim([char]0xFEFF)
        if (Test-Python $saved) { return $saved }
        Write-Host 'Python yang tersimpan sudah tidak valid. Mencari Python lainnya...' -ForegroundColor Yellow
    }
    foreach ($cmd in @(Get-Command py.exe -All -ErrorAction SilentlyContinue)) {
        if (-not $cmd -or -not $cmd.Source) { continue }
        $candidate = Invoke-PythonProbe -Executable $cmd.Source -Arguments '-3 -c "import sys;print(sys.executable)"'
        if (Test-Python $candidate) { return $candidate }
    }
    foreach ($cmd in @(Get-Command python.exe -All -ErrorAction SilentlyContinue)) {
        if ($cmd -and (Test-Python $cmd.Source)) { return $cmd.Source }
    }
    return $null
}

try {
    $Host.UI.RawUI.WindowTitle = 'EK Air Quality Hub - SERVER AKTIF (tutup terminal untuk stop)'
    Write-Host ''
    Write-Host '========================================================' -ForegroundColor Magenta
    Write-Host ' EK INSTRUMENTATION  |  PM + GAS LAPTOP SERVER' -ForegroundColor White
    Write-Host '========================================================' -ForegroundColor Magenta
    Write-Host 'Terminal ini mengontrol server yang berjalan.' -ForegroundColor Green
    Write-Host 'Untuk menghentikan server: Ctrl+C atau tutup terminal ini.' -ForegroundColor Yellow
    Write-Host 'Jangan tutup terminal bila ingin ESP32 terus mengirim data.' -ForegroundColor Yellow
    Write-Host ''

    # A second shortcut must not start a duplicate process or kill another server.
    if (Test-HubRunning) {
        Write-Host "Server sudah berjalan di $BaseUrl." -ForegroundColor Yellow
        Write-Host 'Tidak membuka proses server kedua. Gunakan terminal server pertama untuk menghentikannya.' -ForegroundColor Yellow
        Start-Process ($BaseUrl + '/?ui=REV13')
        exit 0
    }

    $Python = Find-Python
    if (-not $Python) { throw 'Python 3.9+ tidak ditemukan. Jalankan ulang install.ps1 agar Python dapat diperiksa.' }
    $Server = Join-Path $Root 'server.py'
    if (-not (Test-Path -LiteralPath $Server -PathType Leaf)) { throw 'server.py tidak ditemukan di folder instalasi.' }

    # CRITICAL: -NoNewWindow keeps the Python server attached to THIS console.
    # Do NOT use pythonw.exe, -WindowStyle Hidden, or a detached background process.
    Write-Host ('Python : ' + $Python)
    Write-Host ('Server : ' + $BaseUrl)
    Write-Host 'Memulai server di terminal ini...' -ForegroundColor Cyan
    $Child = Start-Process -FilePath $Python -ArgumentList ('-u "' + $Server + '"') -WorkingDirectory $Root -NoNewWindow -PassThru

    $Ready = $false
    for ($i = 0; $i -lt 40; $i++) {
        if ($Child.HasExited) { break }
        if (Test-HubRunning) { $Ready = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $Ready) { throw "Server gagal aktif pada port $Port. Periksa pesan Python di atas; mungkin port dipakai aplikasi lain." }

    Write-Host ''
    Write-Host 'SERVER RUNNING - Dashboard akan dibuka di browser.' -ForegroundColor Green
    Write-Host 'Tekan Ctrl+C / tutup TERMINAL INI untuk menghentikan server.' -ForegroundColor Yellow
    Start-Process ($BaseUrl + '/?ui=REV13')

    # Foreground console remains open for the full life of server.py.
    # If Ctrl+C interrupts Wait-Process, finally cleans up the child.
    Wait-Process -Id $Child.Id
    Write-Host 'Server berhenti.' -ForegroundColor Yellow
} catch {
    $Message = $_.Exception.Message
    Write-Host ('GAGAL: ' + $Message) -ForegroundColor Red
    Add-Content -LiteralPath (Join-Path $Logs 'launcher-error.log') -Value ((Get-Date).ToString('s') + ' | ' + $Message)
    Read-Host 'Tekan Enter untuk menutup terminal' | Out-Null
} finally {
    if ($null -ne $Child) {
        try {
            $Child.Refresh()
            if (-not $Child.HasExited) {
                Stop-Process -Id $Child.Id -Force -ErrorAction SilentlyContinue
            }
        } catch {}
        $Child.Dispose()
    }
}
