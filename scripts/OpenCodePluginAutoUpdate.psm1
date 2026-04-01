$ErrorActionPreference = 'Stop'

function Get-UpdaterPaths {
    [CmdletBinding()]
    param()

    $userProfile = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($userProfile)) {
        throw 'USERPROFILE is not set.'
    }

    $configRoot = Join-Path $userProfile '.config\opencode'
    $cacheRoot = Join-Path $userProfile '.cache\opencode'
    $toolRoot = Join-Path $userProfile '.config\opencode-plugin-auto-update'
    $toolLogRoot = Join-Path $toolRoot 'logs'
    $toolStateRoot = Join-Path $toolRoot 'state'
    $toolBackupRoot = Join-Path $toolRoot 'backups'
    $toolJournalRoot = Join-Path $toolRoot 'journal'

    [pscustomobject]@{
        UserProfile = $userProfile
        OpenCodeConfigRoot = $configRoot
        OpenCodeConfigPath = Join-Path $configRoot 'opencode.json'
        OpenCodeCacheRoot = $cacheRoot
        OpenCodeCachePackageJson = Join-Path $cacheRoot 'package.json'
        OpenCodeCacheNodeModules = Join-Path $cacheRoot 'node_modules'
        OpenCodeCacheLockFile = Join-Path $cacheRoot 'bun.lock'
        ToolRoot = $toolRoot
        ToolLogRoot = $toolLogRoot
        ToolStateRoot = $toolStateRoot
        ToolBackupRoot = $toolBackupRoot
        ToolJournalRoot = $toolJournalRoot
        DailyStatePath = Join-Path $toolStateRoot 'daily-state.json'
        LockPath = Join-Path $toolStateRoot 'run.lock'
        TranscriptPath = Join-Path $toolLogRoot ('transcript-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        JsonLogPath = Join-Path $toolLogRoot 'events.jsonl'
        KnownRenameRulesPath = Join-Path $PSScriptRoot '..\config\known-plugin-renames.json'
    }
}

function Ensure-Directory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Initialize-UpdaterEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Paths)

    @(
        $Paths.ToolRoot,
        $Paths.ToolLogRoot,
        $Paths.ToolStateRoot,
        $Paths.ToolBackupRoot,
        $Paths.ToolJournalRoot
    ) | ForEach-Object { Ensure-Directory -Path $_ }
}

function Read-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Optional
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($Optional) {
            return $null
        }

        throw "JSON file not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        if ($Optional) {
            return $null
        }

        throw "JSON file is empty: $Path"
    }

    return $raw | ConvertFrom-Json -Depth 100
}

function Write-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        Ensure-Directory -Path $parent
    }

    $json = $Value | ConvertTo-Json -Depth 100
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Write-JsonLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Event,
        [Parameter(Mandatory = $true)]$Data
    )

    Ensure-Directory -Path $Paths.ToolLogRoot
    $line = [pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        level = $Level
        event = $Event
        data = $Data
    } | ConvertTo-Json -Depth 20 -Compress

    Add-Content -LiteralPath $Paths.JsonLogPath -Value $line -Encoding UTF8
}

function Get-FileHashString {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InputText)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputText)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Split-PluginSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Spec)

    $trimmed = $Spec.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw 'Plugin spec cannot be empty.'
    }

    $lastAt = $trimmed.LastIndexOf('@')
    if ($trimmed.StartsWith('@')) {
        $lastAt = $trimmed.LastIndexOf('@')
        if ($lastAt -le 0) {
            return [pscustomobject]@{
                Spec = $trimmed
                PackageName = $trimmed
                VersionSpec = 'latest'
                VersionWasImplicit = $true
            }
        }

        $slashIndex = $trimmed.IndexOf('/')
        if ($lastAt -lt $slashIndex) {
            return [pscustomobject]@{
                Spec = $trimmed
                PackageName = $trimmed
                VersionSpec = 'latest'
                VersionWasImplicit = $true
            }
        }
    }
    elseif ($lastAt -lt 1) {
        return [pscustomobject]@{
            Spec = $trimmed
            PackageName = $trimmed
            VersionSpec = 'latest'
            VersionWasImplicit = $true
        }
    }

    $packageName = $trimmed.Substring(0, $lastAt)
    $versionSpec = $trimmed.Substring($lastAt + 1)
    if ([string]::IsNullOrWhiteSpace($versionSpec)) {
        $versionSpec = 'latest'
    }

    [pscustomobject]@{
        Spec = $trimmed
        PackageName = $packageName
        VersionSpec = $versionSpec
        VersionWasImplicit = $false
    }
}

function Join-PluginSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$VersionSpec,
        [bool]$VersionWasImplicit = $false
    )

    if ($VersionWasImplicit -or $VersionSpec -eq 'latest') {
        return "$PackageName@latest"
    }

    return "$PackageName@$VersionSpec"
}

function Get-ConfiguredPlugins {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Paths)

    $config = Read-JsonFile -Path $Paths.OpenCodeConfigPath
    $plugins = @()

    if ($null -ne $config.plugin) {
        $plugins = @($config.plugin)
    }

    $parsed = @()
    foreach ($spec in $plugins) {
        $entry = Split-PluginSpec -Spec ([string]$spec)
        $parsed += [pscustomobject]@{
            Spec = $entry.Spec
            PackageName = $entry.PackageName
            VersionSpec = $entry.VersionSpec
            VersionWasImplicit = $entry.VersionWasImplicit
        }
    }

    [pscustomobject]@{
        Config = $config
        Plugins = $parsed
        PluginHash = (Get-FileHashString -InputText (($plugins | ConvertTo-Json -Compress)))
    }
}

function Get-LocalPluginState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    $cachePackage = Read-JsonFile -Path $Paths.OpenCodeCachePackageJson -Optional
    $resolvedVersion = $null
    if ($cachePackage -and $cachePackage.dependencies) {
        $property = $cachePackage.dependencies.PSObject.Properties | Where-Object { $_.Name -eq $PackageName } | Select-Object -First 1
        if ($property) {
            $resolvedVersion = $property.Value
        }
    }

    $installedPackageJson = Join-Path $Paths.OpenCodeCacheNodeModules ($PackageName + '\package.json')
    $installedPackage = Read-JsonFile -Path $installedPackageJson -Optional

    [pscustomobject]@{
        PackageName = $PackageName
        CacheDependencyVersion = $resolvedVersion
        InstalledVersion = if ($installedPackage) { $installedPackage.version } else { $null }
        InstalledPackageJsonPath = $installedPackageJson
        InstalledPackage = $installedPackage
    }
}

function Get-NpmDistTagsUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PackageName)

    $encodedName = [System.Uri]::EscapeDataString($PackageName)
    return "https://registry.npmjs.org/-/package/$encodedName/dist-tags"
}

function Get-NpmVersionMetadataUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $encodedName = [System.Uri]::EscapeDataString($PackageName)
    $encodedVersion = [System.Uri]::EscapeDataString($Version)
    return "https://registry.npmjs.org/$encodedName/$encodedVersion"
}

function Get-CommandSourcePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CommandName)

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if (-not $command) {
        return $null
    }

    return $command.Source
}

function Get-OpenCodeRuntimeProbe {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Paths)

    [pscustomobject]@{
        OpenCodeConfigPath = $Paths.OpenCodeConfigPath
        OpenCodeCacheRoot = $Paths.OpenCodeCacheRoot
        OpenCodeCommandPath = Get-CommandSourcePath -CommandName 'opencode'
        BunCommandPath = Get-CommandSourcePath -CommandName 'bun'
    }
}

function Invoke-RegistryRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$MaxAttempts = 3
    )

    $lastError = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod -Method Get -Uri $url -TimeoutSec 30
        }
        catch {
            $lastError = $_
            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Milliseconds (250 * $attempt)
            }
        }
    }

    throw "Failed to fetch npm registry URL '$url': $lastError"
}

function Get-RemotePluginState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PackageName)

    $distTags = Invoke-RegistryRequest -Url (Get-NpmDistTagsUrl -PackageName $PackageName)
    $latestVersion = $distTags.latest
    if ([string]::IsNullOrWhiteSpace($latestVersion)) {
        throw "No latest dist-tag found for package '$PackageName'."
    }

    $latestMeta = Invoke-RegistryRequest -Url (Get-NpmVersionMetadataUrl -PackageName $PackageName -Version $latestVersion)

    [pscustomobject]@{
        PackageName = $PackageName
        LatestVersion = $latestVersion
        DeprecatedMessage = $latestMeta.deprecated
        RepositoryUrl = if ($latestMeta.repository) { $latestMeta.repository.url } else { $null }
        Homepage = $latestMeta.homepage
        PublishTime = if ($latestMeta.time) { $latestMeta.time.$latestVersion } else { $null }
        Metadata = $latestMeta
        DistTags = $distTags
    }
}

function Get-KnownRenameRules {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Paths)

    $rules = Read-JsonFile -Path $Paths.KnownRenameRulesPath -Optional
    if ($null -eq $rules) {
        return @()
    }

    return @($rules)
}

function Find-DeprecatedRenameTarget {
    [CmdletBinding()]
    param([string]$DeprecatedMessage)

    if ([string]::IsNullOrWhiteSpace($DeprecatedMessage)) {
        return $null
    }

    $patterns = @(
        '(?i)(?:renamed|moved)\s+(?:to\s+)?(?<pkg>@?[a-z0-9][a-z0-9._\-/]+)',
        '(?i)use\s+(?<pkg>@?[a-z0-9][a-z0-9._\-/]+)\s+instead',
        '(?i)install\s+(?<pkg>@?[a-z0-9][a-z0-9._\-/]+)'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($DeprecatedMessage, $pattern)
        if ($match.Success) {
            return $match.Groups['pkg'].Value.TrimEnd('.', ',', ';')
        }
    }

    return $null
}

function Get-RenameDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)]$Plugin,
        [Parameter(Mandatory = $true)]$RemoteState
    )

    $knownRules = Get-KnownRenameRules -Paths $Paths
    $rule = $knownRules | Where-Object { $_.from -eq $Plugin.PackageName } | Select-Object -First 1
    if ($rule) {
        return [pscustomobject]@{
            HasRename = $true
            TargetPackage = $rule.to
            Reason = $rule.reason
            Source = $rule.source
            Signal = 'known-rule'
            PreserveVersionSpec = [bool]$rule.preserveVersionSpec
        }
    }

    $deprecatedTarget = Find-DeprecatedRenameTarget -DeprecatedMessage $RemoteState.DeprecatedMessage
    if ($deprecatedTarget) {
        return [pscustomobject]@{
            HasRename = $true
            TargetPackage = $deprecatedTarget
            Reason = $RemoteState.DeprecatedMessage
            Source = 'npm deprecated metadata'
            Signal = 'deprecated-message'
            PreserveVersionSpec = $true
        }
    }

    return [pscustomobject]@{
        HasRename = $false
        TargetPackage = $null
        Reason = $null
        Source = $null
        Signal = $null
        PreserveVersionSpec = $true
    }
}

function ConvertTo-Version {
    [CmdletBinding()]
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $core = $Value.Split('-')[0]
    try {
        return [System.Version]$core
    }
    catch {
        return $null
    }
}

function Compare-SemVer {
    [CmdletBinding()]
    param(
        [string]$Left,
        [string]$Right
    )

    $leftVersion = ConvertTo-Version -Value $Left
    $rightVersion = ConvertTo-Version -Value $Right
    if ($leftVersion -and $rightVersion) {
        return $leftVersion.CompareTo($rightVersion)
    }

    return [string]::Compare($Left, $Right, $true)
}

function Get-DesiredVersionSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plugin,
        [Parameter(Mandatory = $true)]$RenameDecision
    )

    if ($RenameDecision.HasRename -and $RenameDecision.PreserveVersionSpec) {
        return $Plugin.VersionSpec
    }

    return $Plugin.VersionSpec
}

function Get-PluginActionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)]$Plugin
    )

    $localState = Get-LocalPluginState -Paths $Paths -PackageName $Plugin.PackageName
    $remoteState = Get-RemotePluginState -PackageName $Plugin.PackageName
    $renameDecision = Get-RenameDecision -Paths $Paths -Plugin $Plugin -RemoteState $remoteState
    $effectivePackage = if ($renameDecision.HasRename) { $renameDecision.TargetPackage } else { $Plugin.PackageName }
    $effectiveVersionSpec = Get-DesiredVersionSpec -Plugin $Plugin -RenameDecision $renameDecision
    $effectiveRemoteState = if ($effectivePackage -eq $Plugin.PackageName) { $remoteState } else { Get-RemotePluginState -PackageName $effectivePackage }
    $effectiveLocalState = if ($effectivePackage -eq $Plugin.PackageName) { $localState } else { Get-LocalPluginState -Paths $Paths -PackageName $effectivePackage }

    $migrationNeeded = $effectivePackage -ne $Plugin.PackageName
    $updateNeeded = $false
    $expectedVersion = $null

    if ($effectiveVersionSpec -eq 'latest') {
        $expectedVersion = $effectiveRemoteState.LatestVersion
        if ([string]::IsNullOrWhiteSpace($effectiveLocalState.InstalledVersion)) {
            $updateNeeded = $true
        }
        elseif ((Compare-SemVer -Left $effectiveLocalState.InstalledVersion -Right $expectedVersion) -lt 0) {
            $updateNeeded = $true
        }
    }
    else {
        $expectedVersion = $effectiveVersionSpec
        if ($effectiveLocalState.InstalledVersion -ne $expectedVersion) {
            $updateNeeded = $true
        }
    }

    [pscustomobject]@{
        Plugin = $Plugin
        LocalState = $localState
        RemoteState = $remoteState
        RenameDecision = $renameDecision
        EffectivePackage = $effectivePackage
        EffectiveVersionSpec = $effectiveVersionSpec
        EffectiveRemoteState = $effectiveRemoteState
        EffectiveLocalState = $effectiveLocalState
        MigrationNeeded = $migrationNeeded
        UpdateNeeded = $updateNeeded
        ExpectedVersion = $expectedVersion
        DesiredSpec = Join-PluginSpec -PackageName $effectivePackage -VersionSpec $effectiveVersionSpec -VersionWasImplicit:$false
        Action = if ($migrationNeeded -and $updateNeeded) { 'migrate-and-update' } elseif ($migrationNeeded) { 'migrate' } elseif ($updateNeeded) { 'update' } else { 'noop' }
    }
}

function Get-DailyState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Paths)

    return Read-JsonFile -Path $Paths.DailyStatePath -Optional
}

function Test-ShouldRunDailyCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$PluginHash
    )

    $state = Get-DailyState -Paths $Paths
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if (-not $state) {
        return $true
    }

    if ($state.lastRunDate -ne $today) {
        return $true
    }

    return ($state.pluginHash -ne $PluginHash)
}

function Save-DailyState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$PluginHash,
        [Parameter(Mandatory = $true)]$Summary
    )

    $state = [pscustomobject]@{
        lastRunDate = (Get-Date).ToString('yyyy-MM-dd')
        pluginHash = $PluginHash
        updatedAt = (Get-Date).ToString('o')
        summary = $Summary
    }

    Write-JsonFile -Path $Paths.DailyStatePath -Value $state
}

function New-ConfigBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Paths)

    Ensure-Directory -Path $Paths.ToolBackupRoot
    $backupPath = Join-Path $Paths.ToolBackupRoot ('opencode.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    Copy-Item -LiteralPath $Paths.OpenCodeConfigPath -Destination $backupPath -Force
    return $backupPath
}

function Restore-ConfigBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )

    Copy-Item -LiteralPath $BackupPath -Destination $Paths.OpenCodeConfigPath -Force
}

function Write-JournalEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)]$Entry
    )

    Ensure-Directory -Path $Paths.ToolJournalRoot
    $path = Join-Path $Paths.ToolJournalRoot ('journal-' + (Get-Date -Format 'yyyyMMdd') + '.jsonl')
    $line = $Entry | ConvertTo-Json -Depth 20 -Compress
    Add-Content -LiteralPath $path -Value $line -Encoding UTF8
}

function Set-ConfiguredPluginSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$FromSpec,
        [Parameter(Mandatory = $true)][string]$ToSpec
    )

    $config = Read-JsonFile -Path $Paths.OpenCodeConfigPath
    $plugins = @($config.plugin)
    $rewritten = @()
    foreach ($plugin in $plugins) {
        if ([string]$plugin -eq $FromSpec) {
            $rewritten += $ToSpec
        }
        else {
            $rewritten += [string]$plugin
        }
    }

    $config.plugin = $rewritten
    Write-JsonFile -Path $Paths.OpenCodeConfigPath -Value $config
}

function Get-BunExecutablePath {
    [CmdletBinding()]
    param()

    $path = Get-CommandSourcePath -CommandName 'bun'
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw 'bun command not found. Install Bun or ensure it is on PATH.'
    }

    return $path
}

function Invoke-BunProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $bunPath = Get-BunExecutablePath
    $result = & $bunPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "bun command failed with exit code ${exitCode}: $($result | Out-String)"
    }

    return $result
}

function Invoke-PluginCacheRefresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$VersionSpec
    )

    Ensure-Directory -Path $Paths.OpenCodeCacheRoot

    $arguments = @(
        'add',
        '--force',
        '--exact',
        '--cwd', $Paths.OpenCodeCacheRoot,
        "$PackageName@$VersionSpec"
    )

    try {
        return Invoke-BunProcess -Arguments $arguments -WorkingDirectory $Paths.OpenCodeCacheRoot
    }
    catch {
        $modulePath = Join-Path $Paths.OpenCodeCacheNodeModules $PackageName
        if (Test-Path -LiteralPath $modulePath) {
            Remove-Item -LiteralPath $modulePath -Recurse -Force
        }

        if (Test-Path -LiteralPath $Paths.OpenCodeCacheLockFile) {
            Remove-Item -LiteralPath $Paths.OpenCodeCacheLockFile -Force
        }

        return Invoke-BunProcess -Arguments $arguments -WorkingDirectory $Paths.OpenCodeCacheRoot
    }
}

function Test-PluginRefreshResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    $state = Get-LocalPluginState -Paths $Paths -PackageName $PackageName
    if (-not $state.InstalledVersion) {
        throw "Plugin package '$PackageName' is not installed after refresh."
    }

    if ($state.InstalledVersion -ne $ExpectedVersion) {
        throw "Plugin package '$PackageName' expected version '$ExpectedVersion' but found '$($state.InstalledVersion)'."
    }

    if ($state.CacheDependencyVersion -and $state.CacheDependencyVersion -ne $ExpectedVersion) {
        throw "Cache dependency for '$PackageName' expected '$ExpectedVersion' but found '$($state.CacheDependencyVersion)'."
    }

    return $true
}

function Get-OpenCodeProcesses {
    [CmdletBinding()]
    param()

    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and $_.CommandLine -match '(?i)\bopencode(\.cmd|\.ps1|\.exe)?\b'
        }

    return @($processes)
}

function Stop-OpenCodeProcesses {
    [CmdletBinding()]
    param()

    $processes = Get-OpenCodeProcesses
    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    }

    return $processes.Count
}

function Start-OpenCodeProcess {
    [CmdletBinding()]
    param([string[]]$Arguments = @())

    $command = Get-Command opencode -ErrorAction SilentlyContinue
    if (-not $command) {
        throw 'opencode command not found.'
    }

    $source = $command.Source
    if ($source -match '\.ps1$') {
        $pwsh = Get-CommandSourcePath -CommandName 'pwsh'
        if (-not $pwsh) {
            throw 'pwsh command not found.'
        }

        $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $source) + $Arguments
        return Start-Process -FilePath $pwsh -ArgumentList $argumentList -PassThru
    }

    return Start-Process -FilePath $source -ArgumentList $Arguments -PassThru
}

function Invoke-WithUpdaterLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    Ensure-Directory -Path $Paths.ToolStateRoot
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Paths.LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        return & $ScriptBlock
    }
    catch [System.IO.IOException] {
        throw 'Updater is already running.'
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
    }
}

function Invoke-PluginAutoUpdate {
    [CmdletBinding()]
    param(
        [switch]$Force,
        [switch]$SkipDailyStateWrite,
        [switch]$DryRun
    )

    $paths = Get-UpdaterPaths
    Initialize-UpdaterEnvironment -Paths $paths
    $configured = Get-ConfiguredPlugins -Paths $paths
    $probe = Get-OpenCodeRuntimeProbe -Paths $paths

    Write-JsonLog -Paths $paths -Level 'info' -Event 'probe.completed' -Data $probe

    if (-not $Force -and -not (Test-ShouldRunDailyCheck -Paths $paths -PluginHash $configured.PluginHash)) {
        return [pscustomobject]@{
            Changed = $false
            Skipped = $true
            Reason = 'already-checked-today'
            PluginHash = $configured.PluginHash
            Paths = $paths
            Plans = @()
        }
    }

    $plans = @()
    foreach ($plugin in $configured.Plugins) {
        $plans += Get-PluginActionPlan -Paths $paths -Plugin $plugin
    }

    Write-JournalEntry -Paths $paths -Entry ([pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        type = 'run.started'
        dryRun = [bool]$DryRun
        pluginCount = $configured.Plugins.Count
    })

    $backupPath = $null
    $changed = $false
    $migrated = $false
    $updated = $false

    try {
        foreach ($plan in $plans) {
            Write-JsonLog -Paths $paths -Level 'info' -Event 'plugin.plan' -Data ([pscustomobject]@{
                package = $plan.Plugin.PackageName
                declaredSpec = $plan.Plugin.Spec
                effectivePackage = $plan.EffectivePackage
                effectiveVersionSpec = $plan.EffectiveVersionSpec
                installedVersion = $plan.EffectiveLocalState.InstalledVersion
                remoteLatest = $plan.EffectiveRemoteState.LatestVersion
                action = $plan.Action
                renameSignal = $plan.RenameDecision.Signal
            })

            if ($DryRun) {
                continue
            }

            if ($plan.MigrationNeeded) {
                if (-not $backupPath) {
                    $backupPath = New-ConfigBackup -Paths $paths
                }

                Set-ConfiguredPluginSpec -Paths $paths -FromSpec $plan.Plugin.Spec -ToSpec $plan.DesiredSpec
                $migrated = $true
                $changed = $true

                Write-JournalEntry -Paths $paths -Entry ([pscustomobject]@{
                    timestamp = (Get-Date).ToString('o')
                    type = 'migration'
                    from = $plan.Plugin.Spec
                    to = $plan.DesiredSpec
                    source = $plan.RenameDecision.Source
                    reason = $plan.RenameDecision.Reason
                })
            }

            if ($plan.UpdateNeeded -or $plan.MigrationNeeded) {
                Invoke-PluginCacheRefresh -Paths $paths -PackageName $plan.EffectivePackage -VersionSpec $plan.EffectiveVersionSpec | Out-Null
                Test-PluginRefreshResult -Paths $paths -PackageName $plan.EffectivePackage -ExpectedVersion $plan.ExpectedVersion | Out-Null
                $updated = $true
                $changed = $true

                Write-JournalEntry -Paths $paths -Entry ([pscustomobject]@{
                    timestamp = (Get-Date).ToString('o')
                    type = 'refresh'
                    package = $plan.EffectivePackage
                    versionSpec = $plan.EffectiveVersionSpec
                    expectedVersion = $plan.ExpectedVersion
                    action = $plan.Action
                })
            }
        }
    }
    catch {
        if ($backupPath) {
            Restore-ConfigBackup -Paths $paths -BackupPath $backupPath
            Write-JournalEntry -Paths $paths -Entry ([pscustomobject]@{
                timestamp = (Get-Date).ToString('o')
                type = 'rollback'
                backupPath = $backupPath
                reason = $_.Exception.Message
            })
        }

        Write-JsonLog -Paths $paths -Level 'error' -Event 'plugin.update.failed' -Data ([pscustomobject]@{ message = $_.Exception.Message })
        throw
    }

    $summary = [pscustomobject]@{
        changed = $changed
        migrated = $migrated
        updated = $updated
        dryRun = [bool]$DryRun
        checkedAt = (Get-Date).ToString('o')
        pluginCount = $configured.Plugins.Count
    }

    if (-not $SkipDailyStateWrite -and -not $DryRun) {
        Save-DailyState -Paths $paths -PluginHash $configured.PluginHash -Summary $summary
    }

    Write-JournalEntry -Paths $paths -Entry ([pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        type = 'run.committed'
        dryRun = [bool]$DryRun
        changed = $changed
        migrated = $migrated
        updated = $updated
    })

    Write-JsonLog -Paths $paths -Level 'info' -Event 'plugin.update.completed' -Data $summary

    return [pscustomobject]@{
        Changed = $changed
        Migrated = $migrated
        Updated = $updated
        Skipped = $false
        PluginHash = $configured.PluginHash
        Paths = $paths
        Plans = $plans
        Summary = $summary
        BackupPath = $backupPath
    }
}

function Invoke-DailyLaunchWorkflow {
    [CmdletBinding()]
    param(
        [string[]]$OpenCodeArguments = @(),
        [switch]$ForceCheck,
        [switch]$DryRun
    )

    $paths = Get-UpdaterPaths
    Initialize-UpdaterEnvironment -Paths $paths

    Start-Transcript -Path $paths.TranscriptPath -Force | Out-Null
    try {
        return Invoke-WithUpdaterLock -Paths $paths -ScriptBlock {
            $result = Invoke-PluginAutoUpdate -Force:$ForceCheck -DryRun:$DryRun
            if ($DryRun) {
                return [pscustomobject]@{
                    Restarted = $false
                    StartedProcessId = $null
                    UpdateResult = $result
                }
            }
            if ($result.Changed) {
                $stopped = Stop-OpenCodeProcesses
                Start-Sleep -Milliseconds 500
                $started = Start-OpenCodeProcess -Arguments $OpenCodeArguments
                Write-JsonLog -Paths $paths -Level 'info' -Event 'opencode.restarted' -Data ([pscustomobject]@{
                    stoppedProcesses = $stopped
                    startedProcessId = $started.Id
                })
                return [pscustomobject]@{
                    Restarted = $true
                    StartedProcessId = $started.Id
                    UpdateResult = $result
                }
            }

            $started = Start-OpenCodeProcess -Arguments $OpenCodeArguments
            Write-JsonLog -Paths $paths -Level 'info' -Event 'opencode.started' -Data ([pscustomobject]@{ processId = $started.Id })
            return [pscustomobject]@{
                Restarted = $false
                StartedProcessId = $started.Id
                UpdateResult = $result
            }
        }
    }
    finally {
        Stop-Transcript | Out-Null
    }
}

Export-ModuleMember -Function @(
    'Invoke-PluginAutoUpdate',
    'Invoke-DailyLaunchWorkflow',
    'Split-PluginSpec',
    'Find-DeprecatedRenameTarget',
    'Compare-SemVer',
    'Test-ShouldRunDailyCheck',
    'Write-JsonFile',
    'Get-RenameDecision'
)
