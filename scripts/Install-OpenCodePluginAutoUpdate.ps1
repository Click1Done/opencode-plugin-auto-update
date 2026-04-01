param(
    [switch]$DesktopShortcut,
    [switch]$StartMenuShortcut
)

$ErrorActionPreference = 'Stop'

function New-LauncherShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$ShortcutPath,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.IconLocation = "$TargetPath,0"
    $shortcut.Save()
}

$launcherPath = Join-Path $PSScriptRoot 'Launch-OpenCodeWithAutoUpdate.ps1'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$workingDirectory = Split-Path -Parent $PSScriptRoot
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$launcherPath`""

if (-not $DesktopShortcut -and -not $StartMenuShortcut) {
    $DesktopShortcut = $true
    $StartMenuShortcut = $true
}

if ($DesktopShortcut) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = Join-Path $desktop 'OpenCode Auto Update.lnk'
    New-LauncherShortcut -ShortcutPath $shortcutPath -TargetPath $pwsh -Arguments $arguments -WorkingDirectory $workingDirectory
    Write-Host "Created desktop shortcut: $shortcutPath"
}

if ($StartMenuShortcut) {
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $shortcutPath = Join-Path $startMenu 'OpenCode Auto Update.lnk'
    New-LauncherShortcut -ShortcutPath $shortcutPath -TargetPath $pwsh -Arguments $arguments -WorkingDirectory $workingDirectory
    Write-Host "Created Start Menu shortcut: $shortcutPath"
}
