$ErrorActionPreference = 'Stop'

$desktop = [Environment]::GetFolderPath('Desktop')
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$paths = @(
    (Join-Path $desktop 'OpenCode Auto Update.lnk'),
    (Join-Path $startMenu 'OpenCode Auto Update.lnk')
)

foreach ($path in $paths) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
        Write-Host "Removed shortcut: $path"
    }
}
