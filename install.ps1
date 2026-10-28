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
Write-Host ' EK INSTRUMENTATION / LAPTOP SERVER REV13' -ForegroundColor White
Write-Host '========================================' -ForegroundColor Magenta
Write-Host ('Repository: ' + $Repository)

# Jalankan executable eksternal via .NET agar stderr dari Python yang rusak
# tidak mengakhiri installer saat $ErrorActionPreference = 'Stop'.
# Berlaku untuk Windows PowerShell 5.1 dan PowerShell 7.
function Invoke-SafeProcess {
    param(
        [Parameter(Mandatory=$true)][string]$Executable,
        [Parameter(Mandatory=$true)][string]$Arguments
    )
    $process = $null
    try {
        if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { return $null }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Executable
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($psi)
        if (-not $process.WaitForExit(8000)) {
            try { $process.Kill() } catch {}
            return $null
        }
        if ($process.ExitCode -ne 0) { return $null }
        return $process.StandardOutput.ReadToEnd().Trim()
    } catch {
        return $null
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Find-Python {
    $candidates = New-Object 'System.Collections.Generic.List[string]'

    # `py -3` biasanya mengarah ke instalasi Python resmi, bukan alias Microsoft Store.
    foreach ($py in @(Get-Command py.exe -All -ErrorAction SilentlyContinue)) {
        if (-not $py -or -not $py.Source) { continue }
        $resolved = Invoke-SafeProcess -Executable $py.Source -Arguments '-3 -c "import sys;print(sys.executable)"'
        if ($resolved -and (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            $candidates.Add($resolved)
        }
    }

    # Cek semua entri PATH, bukan hanya entri pertama yang mungkin rusak.
    foreach ($cmd in @(Get-Command python.exe -All -ErrorAction SilentlyContinue)) {
        if ($cmd -and $cmd.Source) { $candidates.Add([string]$cmd.Source) }
    }

    # Pencarian tambahan jika PATH Windows belum diperbarui setelah instalasi.
    $locations = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python'),
        (Join-Path $env:ProgramFiles 'Python')
    )
    if (${env:ProgramFiles(x86)}) { $locations += (Join-Path ${env:ProgramFiles(x86)} 'Python') }
    foreach ($base in $locations) {
        if (Test-Path -LiteralPath $base) {
            Get-ChildItem -LiteralPath $base -Filter python.exe -File -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object { $candidates.Add($_.FullName) }
        }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        # Python >=3.9, instalasi normal (bukan virtual environment sementara).
        # Interpreter yang gagal, termasuk error 'No pyvenv.cfg file', dilewati.
        $check = Invoke-SafeProcess -Executable $candidate -Arguments '-c "import sys;print(int(sys.version_info >= (3,9) and sys.prefix == sys.base_prefix))"'
        if ($check -eq '1') { return $candidate }
        Write-Host ('  Melewati Python tidak valid / tidak sesuai: ' + $candidate) -ForegroundColor DarkYellow
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
    # REV13: fail explicitly if GitHub still contains the old index.html.
    # Prevents a misleading successful reinstall that leaves old themes/sidebar.
    $UIFile = Join-Path $Source.FullName 'index.html'
    $UIContent = [System.IO.File]::ReadAllText($UIFile)
    foreach ($required in @('EK_UI_REV13', 'id="sidebarToggle"', 'id="chartModal"', 'data-theme-choice="modern-dark"')) {
        if (-not $UIContent.Contains($required)) {
            throw 'index.html di GitHub masih versi lama! Push index.html REV13 bersama install.ps1 dan launch.ps1 ke branch main, lalu jalankan irm ulang.'
        }
    }
    Write-Host '  Dashboard EK UI REV13 terverifikasi (sidebar / tema / grafik popup).' -ForegroundColor Green
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
    # Verify bytes were copied to the installed application (not just downloaded).
    $LocalUI = Join-Path $Install 'index.html'
    if (-not (Test-Path -LiteralPath $LocalUI) -or -not ([System.IO.File]::ReadAllText($LocalUI)).Contains('EK_UI_REV13')) {
        throw 'Gagal memasang index.html REV13 ke folder aplikasi. Tutup server dan ulangi instalasi.'
    }
    Write-Host ('  Tampilan baru terpasang: ' + $LocalUI) -ForegroundColor Green
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
        $Shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Install 'launch.ps1') + '"'
        $Shortcut.WindowStyle = 1  # Normal visible PowerShell terminal; closing it stops server.py.
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
    Write-Host 'Klik shortcut: terminal server akan muncul dan dashboard otomatis terbuka.'
    Write-Host 'Tampilan REV13: buka PENGATURAN untuk tema, ☰ untuk sidebar, ⛶ untuk grafik.' -ForegroundColor Magenta -ForegroundColor White
    Write-Host 'Untuk STOP SERVER: tekan Ctrl+C atau tutup terminal yang muncul.' -ForegroundColor Yellow
} finally {
    if (Test-Path $Temp) { Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue }
}
