$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\scripts\OpenCodePluginAutoUpdate.psm1'
Import-Module $modulePath -Force

Describe 'Split-PluginSpec' {
    It 'parses unscoped package with explicit version' {
        $result = Split-PluginSpec -Spec 'oh-my-openagent@latest'
        $result.PackageName | Should -Be 'oh-my-openagent'
        $result.VersionSpec | Should -Be 'latest'
    }

    It 'parses scoped package with implicit latest' {
        $result = Split-PluginSpec -Spec '@scope/plugin'
        $result.PackageName | Should -Be '@scope/plugin'
        $result.VersionSpec | Should -Be 'latest'
        $result.VersionWasImplicit | Should -Be $true
    }

    It 'parses scoped package with explicit version' {
        $result = Split-PluginSpec -Spec '@scope/plugin@1.2.3'
        $result.PackageName | Should -Be '@scope/plugin'
        $result.VersionSpec | Should -Be '1.2.3'
    }
}

Describe 'Find-DeprecatedRenameTarget' {
    It 'extracts rename target from deprecated message' {
        $target = Find-DeprecatedRenameTarget -DeprecatedMessage 'Package moved to oh-my-openagent. Please use it instead.'
        $target | Should -Be 'oh-my-openagent'
    }
}

Describe 'Compare-SemVer' {
    It 'detects newer remote version' {
        (Compare-SemVer -Left '3.12.3' -Right '3.14.0') | Should -BeLessThan 0
    }

    It 'detects equal version' {
        (Compare-SemVer -Left '3.14.0' -Right '3.14.0') | Should -Be 0
    }
}

Describe 'Test-ShouldRunDailyCheck' {
    It 'skips when same day and same hash' {
        $tempRoot = Join-Path $env:TEMP ('opencode-plugin-auto-update-tests-' + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $paths = [pscustomobject]@{
            ToolStateRoot = $tempRoot
            DailyStatePath = Join-Path $tempRoot 'daily-state.json'
        }

        $state = [pscustomobject]@{
            lastRunDate = (Get-Date).ToString('yyyy-MM-dd')
            pluginHash = 'abc123'
            updatedAt = (Get-Date).ToString('o')
            summary = [pscustomobject]@{ changed = $false }
        }

        Write-JsonFile -Path $paths.DailyStatePath -Value $state
        (Test-ShouldRunDailyCheck -Paths $paths -PluginHash 'abc123') | Should -Be $false
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Describe 'Get-RenameDecision' {
    It 'uses known rename rules for oh-my-opencode' {
        $tempRoot = Join-Path $env:TEMP ('opencode-plugin-auto-update-tests-' + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $rulePath = Join-Path $tempRoot 'known-plugin-renames.json'
        Set-Content -LiteralPath $rulePath -Encoding UTF8 -Value @'
[
  {
    "from": "oh-my-opencode",
    "to": "oh-my-openagent",
    "reason": "rename",
    "source": "test",
    "preserveVersionSpec": true
  }
]
'@
        $paths = [pscustomobject]@{ KnownRenameRulesPath = $rulePath }
        $plugin = [pscustomobject]@{ PackageName = 'oh-my-opencode'; VersionSpec = 'latest'; Spec = 'oh-my-opencode@latest' }
        $remote = [pscustomobject]@{ DeprecatedMessage = $null }
        $decision = Get-RenameDecision -Paths $paths -Plugin $plugin -RemoteState $remote
        $decision.HasRename | Should -Be $true
        $decision.TargetPackage | Should -Be 'oh-my-openagent'
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
