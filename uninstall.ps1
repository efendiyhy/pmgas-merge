# Removes only shortcuts and executable files by default. Data stays safe.
$ErrorActionPreference = 'Stop'
$Root = Join-Path $env:LOCALAPPDATA 'EKInstrumentation\LaptopServer'
$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
foreach ($dir in @($desktop,$startMenu)) {
    $link = Join-Path $dir 'EK Air Quality Hub.lnk'
    if (Test-Path $link) { Remove-Item $link -Force }
}
foreach ($file in @('server.py','index.html','launch.ps1','start_windows.bat','uninstall.ps1','README.md','.python_path')) {
    $path = Join-Path $Root $file
    if (Test-Path $path) { Remove-Item $path -Force }
}
Write-Host 'Shortcut dan file aplikasi telah dihapus. Folder data/ TIDAK dihapus.' -ForegroundColor Green
Write-Host ('Data masih ada di: ' + (Join-Path $Root 'data'))
