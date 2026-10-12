# Removes the Startup shortcut and stops burnrate.
#   powershell -ExecutionPolicy Bypass -File windows\uninstall-autostart.ps1
$link = Join-Path ([Environment]::GetFolderPath('Startup')) 'burnrate.lnk'
Remove-Item -LiteralPath $link -ErrorAction SilentlyContinue

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*\windows\Burnrate.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Write-Host 'Autostart removed.'
