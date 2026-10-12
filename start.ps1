# burnrate - Windows launcher. Double-click start.cmd, or run:
#   powershell -ExecutionPolicy Bypass -File start.ps1
# Stops a running instance and starts the widget without a console window.
$widget = Join-Path $PSScriptRoot 'windows\Burnrate.ps1'

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*\windows\Burnrate.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$widget`""
)
Write-Host 'burnrate is running (right-click the widget -> Quit).'
