# Launch from Desktop shortcut. Requires Python 3.9+ installed.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$data = Join-Path $root 'data'
$logs = Join-Path $data 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$port = if ($env:ESP_LAN_PORT) { [int]$env:ESP_LAN_PORT } else { 8787 }
$baseUrl = 'http://127.0.0.1:' + $port
function Is-HubRunning {
    try {
        $s = Invoke-RestMethod -Uri ($baseUrl + '/api/status') -TimeoutSec 1 -ErrorAction Stop
        return ($s.app_id -eq 'ek-laptop-server')
    } catch { return $false }
}
try {
    if (-not (Is-HubRunning)) {
        $pathfile = Join-Path $root '.python_path'
        if (Test-Path $pathfile) { $python = (Get-Content -LiteralPath $pathfile -Raw).Trim() }
        if (-not $python -or -not (Test-Path $python)) {
            $py = Get-Command py.exe -ErrorAction SilentlyContinue
            if ($py) { $python = (& $py.Source -3 -c 'import sys;print(sys.executable)' 2>$null | Select-Object -First 1) }
        }
        if (-not $python -or -not (Test-Path $python)) { throw 'Python tidak ditemukan. Jalankan install.ps1 lagi.' }
        $pythonw = Join-Path (Split-Path $python -Parent) 'pythonw.exe'
        if (Test-Path $pythonw) { $python = $pythonw }
        Start-Process -FilePath $python -ArgumentList ('"' + (Join-Path $root 'server.py') + '"') -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logs 'server.log') -RedirectStandardError (Join-Path $logs 'server-error.log') | Out-Null
        for ($i=0; $i -lt 32; $i++) {
            if (Is-HubRunning) { break }
            Start-Sleep -Milliseconds 250
        }
        if (-not (Is-HubRunning)) { throw 'Server belum aktif. Periksa data\logs\server-error.log. Mungkin port 8787 sudah digunakan.' }
    }
    Start-Process ($baseUrl + '/')
} catch {
    Add-Content -LiteralPath (Join-Path $logs 'launcher-error.log') -Value ((Get-Date).ToString('s') + ' | ' + $_.Exception.Message)
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show($_.Exception.Message, 'EK Air Quality Hub', 'OK', 'Error') | Out-Null
}
