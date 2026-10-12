# Creates a shortcut in the Startup folder so burnrate starts at every login.
#   powershell -ExecutionPolicy Bypass -File windows\install-autostart.ps1
$widget = Join-Path $PSScriptRoot 'Burnrate.ps1'
$link = Join-Path ([Environment]::GetFolderPath('Startup')) 'burnrate.lnk'

$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
$shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shortcut.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$widget`""
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.WindowStyle = 7  # minimiert
$shortcut.Save()
Write-Host "Autostart installed: $link"

& (Join-Path (Split-Path -Parent $PSScriptRoot) 'start.ps1')
