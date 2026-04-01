param(
    [switch]$Force,
    [switch]$SkipDailyStateWrite,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'OpenCodePluginAutoUpdate.psm1'
Import-Module $modulePath -Force

$result = Invoke-PluginAutoUpdate -Force:$Force -SkipDailyStateWrite:$SkipDailyStateWrite -DryRun:$DryRun
$summary = [pscustomobject]@{
    changed = $result.Changed
    migrated = $result.Migrated
    updated = $result.Updated
    skipped = $result.Skipped
    dryRun = [bool]$DryRun
    pluginHash = $result.PluginHash
    actions = @($result.Plans | ForEach-Object {
        [pscustomobject]@{
            package = $_.Plugin.PackageName
            declaredSpec = $_.Plugin.Spec
            effectivePackage = $_.EffectivePackage
            action = $_.Action
            installedVersion = $_.EffectiveLocalState.InstalledVersion
            expectedVersion = $_.ExpectedVersion
        }
    })
}

$summary | ConvertTo-Json -Depth 20
