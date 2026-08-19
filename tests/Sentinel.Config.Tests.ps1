#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for Sentinel.Config module.
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'Sentinel.Config.psm1'
    Import-Module $modulePath -Force

    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "smt-cfg-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null

    function New-ConfigFile {
        param([string]$Name, [string]$Content)
        $p = Join-Path $script:TestRoot $Name
        Set-Content -Path $p -Value $Content -Encoding UTF8
        return $p
    }

    $script:ValidJson = @'
{
  "source": {
    "subscriptionId": "11111111-1111-1111-1111-111111111111",
    "resourceGroupName": "rg-source",
    "workspaceName": "ws-source"
  },
  "target": {
    "subscriptionId": "22222222-2222-2222-2222-222222222222",
    "resourceGroupName": "rg-target",
    "workspaceName": "ws-target"
  },
  "options": {
    "dryRun": false,
    "cloud": "Gov",
    "retryCount": 5,
    "throttleMs": 250
  }
}
'@
}

AfterAll {
    if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
        Remove-Item $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Test-ConfigIsJson' {
    It 'Detects JSON by extension' {
        Test-ConfigIsJson -Path 'c:\tmp\config.json' | Should -BeTrue
    }

    It 'Detects JSON by content when the extension is misleading' {
        Test-ConfigIsJson -Path 'c:\tmp\config.yaml' -Content '  { "source": {} }' | Should -BeTrue
    }

    It 'Treats YAML content as YAML' {
        Test-ConfigIsJson -Path 'c:\tmp\config.yaml' -Content "source:`n  workspaceName: ws" | Should -BeFalse
    }

    It 'Treats an extensionless file with YAML content as YAML' {
        Test-ConfigIsJson -Path 'c:\tmp\config' -Content "source:`n  workspaceName: ws" | Should -BeFalse
    }
}

Describe 'Read-MigrationConfig' {
    It 'Parses a JSON config without requiring powershell-yaml' {
        $p = New-ConfigFile -Name 'good.json' -Content $script:ValidJson
        $cfg = Read-MigrationConfig -Path $p

        $cfg.Source.SubscriptionId | Should -Be '11111111-1111-1111-1111-111111111111'
        $cfg.Source.ResourceGroupName | Should -Be 'rg-source'
        $cfg.Source.WorkspaceName | Should -Be 'ws-source'
        $cfg.Target.WorkspaceName | Should -Be 'ws-target'
        $cfg.Options.DryRun | Should -BeFalse
        $cfg.Options.Cloud | Should -Be 'Gov'
        $cfg.Options.RetryCount | Should -Be 5
        $cfg.Options.ThrottleMs | Should -Be 250
    }

    It 'Parses JSON content saved with a .yaml extension' {
        $p = New-ConfigFile -Name 'sneaky.yaml' -Content $script:ValidJson
        $cfg = Read-MigrationConfig -Path $p
        $cfg.Target.ResourceGroupName | Should -Be 'rg-target'
    }

    It 'Throws a clear error for a missing file' {
        { Read-MigrationConfig -Path (Join-Path $script:TestRoot 'nope.json') } |
            Should -Throw '*not found*'
    }

    It 'Throws a clear error for an empty file' {
        $p = New-ConfigFile -Name 'empty.json' -Content '   '
        { Read-MigrationConfig -Path $p } | Should -Throw '*empty*'
    }

    It 'Throws a clear error for malformed JSON' {
        $p = New-ConfigFile -Name 'bad.json' -Content '{ "source": '
        { Read-MigrationConfig -Path $p } | Should -Throw '*Failed to parse JSON*'
    }
}

Describe 'ConvertTo-NormalizedConfig' {
    It 'Applies safe defaults when options are omitted' {
        $cfg = ConvertTo-NormalizedConfig -RawConfig ([PSCustomObject]@{
                source = [PSCustomObject]@{ workspaceName = 'ws-source' }
            })

        # Dry run must default on so an unconfigured run cannot write to production.
        $cfg.Options.DryRun | Should -BeTrue
        $cfg.Options.Cloud | Should -Be 'Commercial'
        $cfg.Options.OverwriteExisting | Should -BeFalse
        $cfg.Options.RetryCount | Should -Be 3
        $cfg.Options.ThrottleMs | Should -Be 100
    }

    It 'Warns and ignores the removed concurrency option' {
        $warnings = @()
        ConvertTo-NormalizedConfig -RawConfig ([PSCustomObject]@{
                options = [PSCustomObject]@{ concurrency = 8 }
            }) -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

        @($warnings).Count | Should -BeGreaterThan 0
        [string]$warnings[0] | Should -Match 'concurrency'
        [string]$warnings[0] | Should -Match 'throttleMs'
    }

    It 'Honours dryRun set to false' {
        $cfg = ConvertTo-NormalizedConfig -RawConfig ([PSCustomObject]@{
                options = [PSCustomObject]@{ dryRun = $false }
            })
        $cfg.Options.DryRun | Should -BeFalse
    }

    It 'Defaults migrateSolutions on' {
        # Solution migration is the point of phase 2. Defaulting it off would restore the
        # original defect — solutions silently not migrating — for anyone on an old config.
        $cfg = ConvertTo-NormalizedConfig -RawConfig ([PSCustomObject]@{
                source = [PSCustomObject]@{ workspaceName = 'ws-source' }
            })
        $cfg.Options.MigrateSolutions | Should -BeTrue
    }

    It 'Honours migrateSolutions set to false' {
        $cfg = ConvertTo-NormalizedConfig -RawConfig ([PSCustomObject]@{
                options = [PSCustomObject]@{ migrateSolutions = $false }
            })
        $cfg.Options.MigrateSolutions | Should -BeFalse
    }

    It 'Reads migrateSolutions from YAML as well as JSON' {
        $p = Join-Path $script:TestRoot 'solutions.yaml'
        @'
source:
  workspaceName: ws-source
options:
  migrateSolutions: false
'@ | Set-Content -Path $p -Encoding UTF8

        $raw = Read-MigrationConfig -Path $p
        $cfg = ConvertTo-NormalizedConfig -RawConfig $raw
        $cfg.Options.MigrateSolutions | Should -BeFalse
    }
}

Describe 'Merge-ParameterOverrides' {
    It 'Lets CLI parameters win over file values' {
        $cfg = ConvertTo-NormalizedConfig -RawConfig ([PSCustomObject]@{
                source  = [PSCustomObject]@{ workspaceName = 'from-file' }
                options = [PSCustomObject]@{ retryCount = 2 }
            })

        $merged = Merge-ParameterOverrides -Config $cfg -Overrides @{
            SourceWorkspace = 'from-cli'
            RetryCount      = 7
        }

        $merged.Source.WorkspaceName | Should -Be 'from-cli'
        $merged.Options.RetryCount | Should -Be 7
    }

    It 'Ignores null overrides so unspecified parameters do not erase file values' {
        $cfg = ConvertTo-NormalizedConfig -RawConfig ([PSCustomObject]@{
                source = [PSCustomObject]@{ workspaceName = 'from-file' }
            })

        $merged = Merge-ParameterOverrides -Config $cfg -Overrides @{ SourceWorkspace = $null }
        $merged.Source.WorkspaceName | Should -Be 'from-file'
    }

    It 'Lets -SkipSolutions turn solution migration off from the CLI' {
        $cfg = ConvertTo-NormalizedConfig -RawConfig ([PSCustomObject]@{
                options = [PSCustomObject]@{ migrateSolutions = $true }
            })

        $merged = Merge-ParameterOverrides -Config $cfg -Overrides @{ MigrateSolutions = $false }
        $merged.Options.MigrateSolutions | Should -BeFalse
    }

    It 'Leaves migrateSolutions alone when the CLI says nothing' {
        $cfg = ConvertTo-NormalizedConfig -RawConfig ([PSCustomObject]@{
                options = [PSCustomObject]@{ migrateSolutions = $false }
            })

        $merged = Merge-ParameterOverrides -Config $cfg -Overrides @{ MigrateSolutions = $null }
        $merged.Options.MigrateSolutions | Should -BeFalse
    }
}

Describe 'Assert-ConfigValid' {
    BeforeAll {
        function New-ValidConfig {
            ConvertTo-NormalizedConfig -RawConfig ([PSCustomObject]@{
                    source = [PSCustomObject]@{
                        subscriptionId    = 'sub-a'
                        resourceGroupName = 'rg-a'
                        workspaceName     = 'ws-a'
                    }
                    target = [PSCustomObject]@{
                        subscriptionId    = 'sub-b'
                        resourceGroupName = 'rg-b'
                        workspaceName     = 'ws-b'
                    }
                })
        }
    }

    It 'Accepts a fully populated config' {
        { Assert-ConfigValid -Config (New-ValidConfig) } | Should -Not -Throw
    }

    It 'Reports every missing required field at once' {
        $cfg = ConvertTo-NormalizedConfig -RawConfig ([PSCustomObject]@{})
        { Assert-ConfigValid -Config $cfg } | Should -Throw '*source.subscriptionId is required*'
    }

    It 'Rejects an unknown cloud' {
        $cfg = New-ValidConfig
        $cfg.Options.Cloud = 'Mars'
        { Assert-ConfigValid -Config $cfg } | Should -Throw "*must be 'Commercial' or 'Gov'*"
    }

    It 'Rejects a retryCount above the ceiling' {
        $cfg = New-ValidConfig
        $cfg.Options.RetryCount = 99
        { Assert-ConfigValid -Config $cfg } | Should -Throw '*retryCount must be between 0 and 10*'
    }

    It 'Rejects a negative retryCount' {
        $cfg = New-ValidConfig
        $cfg.Options.RetryCount = -1
        { Assert-ConfigValid -Config $cfg } | Should -Throw '*retryCount must be between 0 and 10*'
    }

    It 'Accepts retryCount at the boundaries' {
        $cfg = New-ValidConfig
        $cfg.Options.RetryCount = 0
        { Assert-ConfigValid -Config $cfg } | Should -Not -Throw
        $cfg.Options.RetryCount = 10
        { Assert-ConfigValid -Config $cfg } | Should -Not -Throw
    }

    It 'Rejects a throttleMs above the ceiling' {
        $cfg = New-ValidConfig
        $cfg.Options.ThrottleMs = 120000
        { Assert-ConfigValid -Config $cfg } | Should -Throw '*throttleMs must be between 0 and 60000*'
    }

    It 'Rejects migrating a workspace onto itself' {
        $cfg = New-ValidConfig
        $cfg.Target.SubscriptionId = $cfg.Source.SubscriptionId
        $cfg.Target.ResourceGroupName = $cfg.Source.ResourceGroupName
        $cfg.Target.WorkspaceName = $cfg.Source.WorkspaceName

        { Assert-ConfigValid -Config $cfg } | Should -Throw '*same workspace*'
    }

    It 'Allows the same workspace name in a different resource group' {
        $cfg = New-ValidConfig
        $cfg.Target.WorkspaceName = $cfg.Source.WorkspaceName
        { Assert-ConfigValid -Config $cfg } | Should -Not -Throw
    }
}

Describe 'Shipped sample config' {
    It 'samples/config.yaml parses and validates' {
        # The sample is the documented starting point and the reference for every
        # option, so a typo in it breaks the first thing a new user does.
        $sample = Join-Path $PSScriptRoot '..' 'samples' 'config.yaml'
        Test-Path $sample | Should -BeTrue

        $cfg = Read-MigrationConfig -Path $sample
        $cfg.Source.WorkspaceName | Should -Not -BeNullOrEmpty
        $cfg.Target.WorkspaceName | Should -Not -BeNullOrEmpty
        $cfg.Options.DryRun | Should -BeTrue   # sample must never default to writing
        { Assert-ConfigValid -Config $cfg } | Should -Not -Throw
    }

    It 'Is the only config sample, so there is no ambiguity about which to copy' {
        $samples = Get-ChildItem (Join-Path $PSScriptRoot '..' 'samples') -File |
            Where-Object { $_.Name -match '^config\.' }
        @($samples).Count | Should -Be 1
        $samples[0].Name | Should -Be 'config.yaml'
    }
}
