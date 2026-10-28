# EK Instrumentation Laptop Server - GitHub one-line installer for Windows
# Repository: https://github.com/efendiyhy/pmgas-merge
# Install from trusted public repository:
# irm https://raw.githubusercontent.com/efendiyhy/pmgas-merge/main/install.ps1 | iex
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Official repository for this installer.
$Repository = 'efendiyhy/pmgas-merge'
if ($env:EK_LAPTOP_REPO) { $Repository = $env:EK_LAPTOP_REPO.Trim() }
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw 'Repository GitHub tidak valid. Gunakan format USERNAME/REPOSITORY.'
}

$Install = Join-Path $env:LOCALAPPDATA 'EKInstrumentation\LaptopServer'
$Data = Join-Path $Install 'data'
$Temp = Join-Path $env:TEMP ('EKLaptopServerInstall_' + [guid]::NewGuid().ToString('N'))
Write-Host ''
Write-Host '========================================' -ForegroundColor Magenta
Write-Host ' EK INSTRUMENTATION / LAPTOP SERVER' -ForegroundColor White
Write-Host '========================================' -ForegroundColor Magenta
Write-Host ('Repository: ' + $Repository)

function Find-Python {
    $candidates = New-Object System.Collections.Generic.List[string]
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) {
        $resolved = (& $py.Source -3 -c 'import sys;print(sys.executable)' 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and $resolved) { $candidates.Add([string]$resolved) }
    }
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($python) { $candidates.Add($python.Source) }
    foreach ($base in @((Join-Path $env:LOCALAPPDATA 'Programs\Python'), (Join-Path $env:ProgramFiles 'Python'))) {
        if (Test-Path $base) {
            Get-ChildItem $base -Filter python.exe -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $candidates.Add($_.FullName) }
        }
    }
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path $candidate)) { continue }
        $check = (& $candidate -c 'import sys;print(int(sys.version_info >= (3, 9)))' 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and $check -eq '1') { return $candidate }
    }
    return $null
}

try {
    New-Item -ItemType Directory -Force -Path $Temp, $Install, $Data | Out-Null
    $Zip = Join-Path $Temp 'repository.zip'
    $Url = 'https://codeload.github.com/' + $Repository + '/zip/refs/heads/main'
    Write-Host '[1/4] Mengambil paket terbaru dari GitHub...' -ForegroundColor Cyan
    Invoke-WebRequest -Uri $Url -OutFile $Zip -UseBasicParsing
    $Extract = Join-Path $Temp 'extract'
    Expand-Archive -Path $Zip -DestinationPath $Extract -Force
    $Source = Get-ChildItem -Path $Extract -Directory | Select-Object -First 1
    if (-not $Source -or -not (Test-Path (Join-Path $Source.FullName 'server.py')) -or -not (Test-Path (Join-Path $Source.FullName 'index.html'))) {
        throw 'Isi repo tidak sesuai: server.py dan index.html harus berada di folder root repo.'
    }
    Write-Host '[2/4] Memasang aplikasi (folder data lama dipertahankan)...' -ForegroundColor Cyan
    # Stop ONLY this app's existing Python process, so an update is activated on next launch.
    $appScriptPath = Join-Path $Install 'server.py'
    if (Test-Path $appScriptPath) {
        try {
            Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction Stop |
                Where-Object { $_.CommandLine -and $_.CommandLine.Contains($appScriptPath) } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop }
        } catch { Write-Host 'Peringatan: gagal menghentikan server lama. Tutup proses Python aplikasi secara manual bila diperlukan.' -ForegroundColor Yellow }
    }
    foreach ($name in @('server.py','index.html','launch.ps1','start_windows.bat','uninstall.ps1','README.md')) {
        $file = Join-Path $Source.FullName $name
        if (Test-Path $file) { Copy-Item -LiteralPath $file -Destination (Join-Path $Install $name) -Force }
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $Install 'assets') | Out-Null
    Copy-Item (Join-Path $Source.FullName 'assets\ek.ico') (Join-Path $Install 'assets\ek.ico') -Force
    $PythonPath = Find-Python
    if (-not $PythonPath) {
        Write-Host '[3/4] Python belum ada, mencoba instal otomatis dengan winget...' -ForegroundColor Yellow
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $winget) { throw 'Python 3.9+ tidak ditemukan dan winget tidak tersedia. Instal Python dari python.org, lalu jalankan perintah irm lagi.' }
        & $winget.Source install --id Python.Python.3.13 --exact --source winget --scope user --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { throw 'Instalasi Python gagal. Instal Python 3.9+ secara manual lalu jalankan perintah irm lagi.' }
        $PythonPath = Find-Python
        if (-not $PythonPath) { throw 'Python terpasang tetapi belum ditemukan. Tutup dan buka PowerShell lalu jalankan perintah irm lagi.' }
    }
    Write-Host ('[3/4] Python terdeteksi: ' + $PythonPath) -ForegroundColor Green
    Set-Content -LiteralPath (Join-Path $Install '.python_path') -Value $PythonPath -Encoding UTF8

    Write-Host '[4/4] Membuat shortcut Desktop dan Start Menu...' -ForegroundColor Cyan
    $Shell = New-Object -ComObject WScript.Shell
    $Desktop = [Environment]::GetFolderPath('DesktopDirectory')
    $StartMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    foreach ($destination in @($Desktop, $StartMenu)) {
        if (-not (Test-Path $destination)) { New-Item -ItemType Directory -Force $destination | Out-Null }
        $Shortcut = $Shell.CreateShortcut((Join-Path $destination 'EK Air Quality Hub.lnk'))
        $Shortcut.TargetPath = (Join-Path $PSHOME 'powershell.exe')
        $Shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Install 'launch.ps1') + '"'
        $Shortcut.WorkingDirectory = $Install
        $Shortcut.Description = 'EK Instrumentation - PM & Gas Laptop Server'
        $Shortcut.IconLocation = (Join-Path $Install 'assets\ek.ico') + ',0'
        $Shortcut.Save()
    }
    Write-Host ''
    Write-Host 'BERHASIL: Shortcut EK Air Quality Hub tersedia di Desktop dan Start Menu.' -ForegroundColor Green
    Write-Host ('Aplikasi: ' + $Install)
    Write-Host ('Database dan CSV: ' + $Data)
    Write-Host 'Port: 8787 | ESP endpoint: http://IP-LAPTOP:8787/api/ingest'
    Write-Host 'Klik shortcut untuk membuka dashboard.' -ForegroundColor White
} finally {
    if (Test-Path $Temp) { Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue }
}
