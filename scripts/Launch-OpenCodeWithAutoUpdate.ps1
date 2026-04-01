param(
    [switch]$ForceCheck,
    [switch]$DryRun,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$OpenCodeArgs
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'OpenCodePluginAutoUpdate.psm1'
Import-Module $modulePath -Force

$result = Invoke-DailyLaunchWorkflow -OpenCodeArguments $OpenCodeArgs -ForceCheck:$ForceCheck -DryRun:$DryRun
$summary = [pscustomobject]@{
    restarted = $result.Restarted
    startedProcessId = $result.StartedProcessId
    changed = $result.UpdateResult.Changed
    migrated = $result.UpdateResult.Migrated
    updated = $result.UpdateResult.Updated
    skipped = $result.UpdateResult.Skipped
    dryRun = [bool]$DryRun
    actions = @($result.UpdateResult.Plans | ForEach-Object {
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
