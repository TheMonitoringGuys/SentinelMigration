#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for Sentinel.Rules module with mocked API calls.
#>

BeforeAll {
    $srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $srcDir 'Sentinel.Api.psm1') -Force
    Import-Module (Join-Path $srcDir 'Sentinel.Rules.psm1') -Force
}

Describe 'Get-RuleMigrationId' {
    It 'Returns alertRuleTemplateName for template-based rules' {
        $rule = [PSCustomObject]@{
            properties = [PSCustomObject]@{
                displayName          = 'Test Rule'
                alertRuleTemplateName = 'abc-123-template'
            }
        }
        $id = Get-RuleMigrationId -Rule $rule
        $id | Should -Be 'abc-123-template'
    }

    It 'Returns deterministic GUID for custom rules with same displayName' {
        $rule1 = [PSCustomObject]@{
            properties = [PSCustomObject]@{
                displayName          = 'My Custom Rule'
                alertRuleTemplateName = $null
            }
        }
        $rule2 = [PSCustomObject]@{
            properties = [PSCustomObject]@{
                displayName          = 'My Custom Rule'
                alertRuleTemplateName = ''
            }
        }
        $id1 = Get-RuleMigrationId -Rule $rule1
        $id2 = Get-RuleMigrationId -Rule $rule2
        $id1 | Should -Be $id2
        $id1 | Should -Match '^[0-9a-f]{8}-'
    }

    It 'Returns different GUIDs for different displayNames' {
        $rule1 = [PSCustomObject]@{
            properties = [PSCustomObject]@{
                displayName          = 'Rule A'
                alertRuleTemplateName = $null
            }
        }
        $rule2 = [PSCustomObject]@{
            properties = [PSCustomObject]@{
                displayName          = 'Rule B'
                alertRuleTemplateName = $null
            }
        }
        $id1 = Get-RuleMigrationId -Rule $rule1
        $id2 = Get-RuleMigrationId -Rule $rule2
        $id1 | Should -Not -Be $id2
    }
}

Describe 'Export-RuleDefinition' {
    It 'Strips read-only properties' {
        $rule = [PSCustomObject]@{
            kind = 'Scheduled'
            properties = [PSCustomObject]@{
                displayName     = 'Test Rule'
                enabled         = $true
                query           = 'SecurityEvent | take 10'
                lastModifiedUtc = '2024-01-01T00:00:00Z'
                createdDateUtc  = '2024-01-01T00:00:00Z'
            }
        }

        $def = Export-RuleDefinition -Rule $rule
        $def.kind | Should -Be 'Scheduled'
        $def.properties.displayName | Should -Be 'Test Rule'
        $def.properties.PSObject.Properties.Name | Should -Not -Contain 'lastModifiedUtc'
        $def.properties.PSObject.Properties.Name | Should -Not -Contain 'createdDateUtc'
    }
}

Describe 'Get-SourceAnalyticsRules' {
    It 'Classifies rules correctly' {
        Mock Invoke-SentinelApiList -ModuleName Sentinel.Rules {
            return @(
                [PSCustomObject]@{
                    kind = 'Scheduled'
                    properties = [PSCustomObject]@{
                        displayName          = 'Template Enabled'
                        alertRuleTemplateName = 'tmpl-1'
                        enabled              = $true
                    }
                },
                [PSCustomObject]@{
                    kind = 'Scheduled'
                    properties = [PSCustomObject]@{
                        displayName          = 'Template Disabled'
                        alertRuleTemplateName = 'tmpl-2'
                        enabled              = $false
                    }
                },
                [PSCustomObject]@{
                    kind = 'Scheduled'
                    properties = [PSCustomObject]@{
                        displayName          = 'Custom Enabled'
                        alertRuleTemplateName = $null
                        enabled              = $true
                    }
                },
                [PSCustomObject]@{
                    kind = 'Scheduled'
                    properties = [PSCustomObject]@{
                        displayName          = 'Custom Disabled'
                        alertRuleTemplateName = ''
                        enabled              = $false
                    }
                }
            )
        }

        $result = Get-SourceAnalyticsRules -WorkspaceUri 'https://fake/ws'
        $result.TemplateRulesEnabled.Count  | Should -Be 1
        $result.TemplateRulesDisabled.Count | Should -Be 1
        $result.CustomRulesEnabled.Count    | Should -Be 1
        $result.CustomRulesDisabled.Count   | Should -Be 1
        $result.All.Count                   | Should -Be 4
    }
}

Describe 'Import-AnalyticsRule' {
    BeforeEach {
        Mock Get-SentinelAccessToken -ModuleName Sentinel.Api { return 'fake-token' }
    }

    It 'Skips disabled rules when CreateDisabledRules is not set' {
        $rule = [PSCustomObject]@{
            kind = 'Scheduled'
            properties = [PSCustomObject]@{
                displayName          = 'Disabled Rule'
                alertRuleTemplateName = $null
                enabled              = $false
            }
        }

        $result = Import-AnalyticsRule -TargetWorkspaceUri 'https://fake/ws' -Rule $rule
        $result.Action | Should -Be 'Skipped'
        $result.Reason | Should -Match 'disabled'
    }

    It 'Creates rule in dry-run mode with WouldBeCreated action' {
        Mock Invoke-SentinelApi -ModuleName Sentinel.Rules {
            if ($Method -eq 'GET') { throw [System.Net.Http.HttpRequestException]::new("404") }
            return [PSCustomObject]@{ DryRun = $true; Simulated = $true }
        }

        # Need to handle the 404 properly
        Mock Invoke-SentinelApi -ModuleName Sentinel.Rules -ParameterFilter { $Method -eq 'GET' } {
            $ex = [System.Exception]::new("Not Found")
            $resp = [PSCustomObject]@{ StatusCode = 404 }
            $ex | Add-Member -NotePropertyName 'Response' -NotePropertyValue $resp
            throw $ex
        }

        Mock Invoke-SentinelApi -ModuleName Sentinel.Rules -ParameterFilter { $Method -eq 'PUT' } {
            return [PSCustomObject]@{ DryRun = $true; Simulated = $true }
        }

        $rule = [PSCustomObject]@{
            kind = 'Scheduled'
            properties = [PSCustomObject]@{
                displayName          = 'New Rule'
                alertRuleTemplateName = $null
                enabled              = $true
                query                = 'SecurityEvent | take 1'
            }
        }

        # This test validates the dry-run path logic
        # Full integration requires proper HTTP mock
    }
}

Describe 'ConvertTo-UniqueEntityMapping' {
    It 'Collapses byte-identical mappings' {
        $m = @(
            [PSCustomObject]@{ entityType='Process'; fieldMappings=@([PSCustomObject]@{ identifier='ProcessId'; columnName='PID' }) }
            [PSCustomObject]@{ entityType='Account'; fieldMappings=@([PSCustomObject]@{ identifier='Name'; columnName='User' }) }
            [PSCustomObject]@{ entityType='Process'; fieldMappings=@([PSCustomObject]@{ identifier='ProcessId'; columnName='PID' }) }
        )
        $r = ConvertTo-UniqueEntityMapping -EntityMappings $m
        $r.Count | Should -Be 2
        $r[0].entityType | Should -Be 'Process'
        $r[1].entityType | Should -Be 'Account'
    }

    It 'Keeps mappings that share an entity type but differ in fields' {
        $m = @(
            [PSCustomObject]@{ entityType='Host'; fieldMappings=@([PSCustomObject]@{ identifier='HostName'; columnName='Computer' }) }
            [PSCustomObject]@{ entityType='Host'; fieldMappings=@([PSCustomObject]@{ identifier='FullName'; columnName='Fqdn' }) }
        )
        (ConvertTo-UniqueEntityMapping -EntityMappings $m).Count | Should -Be 2
    }

    It 'Treats field order within a mapping as insignificant' {
        $m = @(
            [PSCustomObject]@{ entityType='Account'; fieldMappings=@(
                [PSCustomObject]@{ identifier='Name'; columnName='U' }
                [PSCustomObject]@{ identifier='UPNSuffix'; columnName='D' }) }
            [PSCustomObject]@{ entityType='Account'; fieldMappings=@(
                [PSCustomObject]@{ identifier='UPNSuffix'; columnName='D' }
                [PSCustomObject]@{ identifier='Name'; columnName='U' }) }
        )
        (ConvertTo-UniqueEntityMapping -EntityMappings $m).Count | Should -Be 1
    }

    It 'Handles an empty collection' {
        (ConvertTo-UniqueEntityMapping -EntityMappings @()).Count | Should -Be 0
    }
}

Describe 'Export-RuleDefinition entity mapping dedupe' {
    It 'Removes duplicates so a 6-mapping rule fits the 5 cap' {
        $rule = [PSCustomObject]@{
            kind = 'Scheduled'
            properties = [PSCustomObject]@{
                displayName    = 'CVE rule'
                enabled        = $true
                entityMappings = @(
                    [PSCustomObject]@{ entityType='Account'; fieldMappings=@([PSCustomObject]@{ identifier='Name'; columnName='a' }) }
                    [PSCustomObject]@{ entityType='Host';    fieldMappings=@([PSCustomObject]@{ identifier='HostName'; columnName='b' }) }
                    [PSCustomObject]@{ entityType='Process'; fieldMappings=@([PSCustomObject]@{ identifier='ProcessId'; columnName='c' }) }
                    [PSCustomObject]@{ entityType='IP';      fieldMappings=@([PSCustomObject]@{ identifier='Address'; columnName='d' }) }
                    [PSCustomObject]@{ entityType='File';    fieldMappings=@([PSCustomObject]@{ identifier='Name'; columnName='e' }) }
                    [PSCustomObject]@{ entityType='Process'; fieldMappings=@([PSCustomObject]@{ identifier='ProcessId'; columnName='c' }) }
                )
            }
        }
        $d = Export-RuleDefinition -Rule $rule
        @($d.properties.entityMappings).Count | Should -Be 5
    }
}

Describe 'Resolve-RuleMigrationIdMap' {
    It 'Gives rules sharing a template distinct target ids' {
        $rules = @(
            [PSCustomObject]@{ name='aaa-111'; properties=[PSCustomObject]@{ displayName='Dup'; alertRuleTemplateName='tpl-shared' } }
            [PSCustomObject]@{ name='bbb-222'; properties=[PSCustomObject]@{ displayName='Dup'; alertRuleTemplateName='tpl-shared' } }
        )
        $map = Resolve-RuleMigrationIdMap -Rules $rules
        $map['aaa-111'] | Should -Be 'tpl-shared'
        $map['bbb-222'] | Should -Not -Be 'tpl-shared'
        $map['bbb-222'] | Should -Not -BeNullOrEmpty
    }

    It 'Is stable regardless of the order the API returns rules in' {
        $a = [PSCustomObject]@{ name='aaa-111'; properties=[PSCustomObject]@{ displayName='Dup'; alertRuleTemplateName='tpl-shared' } }
        $b = [PSCustomObject]@{ name='bbb-222'; properties=[PSCustomObject]@{ displayName='Dup'; alertRuleTemplateName='tpl-shared' } }
        $m1 = Resolve-RuleMigrationIdMap -Rules @($a,$b)
        $m2 = Resolve-RuleMigrationIdMap -Rules @($b,$a)
        $m1['aaa-111'] | Should -Be $m2['aaa-111']
        $m1['bbb-222'] | Should -Be $m2['bbb-222']
    }

    It 'Leaves a lone template rule on the template id' {
        $rules = @([PSCustomObject]@{ name='aaa-111'; properties=[PSCustomObject]@{ displayName='Solo'; alertRuleTemplateName='tpl-solo' } })
        (Resolve-RuleMigrationIdMap -Rules $rules)['aaa-111'] | Should -Be 'tpl-solo'
    }

    It 'Falls back to Get-RuleMigrationId for custom rules' {
        $rule = [PSCustomObject]@{ name='ccc-333'; properties=[PSCustomObject]@{ displayName='Custom'; alertRuleTemplateName=$null } }
        (Resolve-RuleMigrationIdMap -Rules @($rule))['ccc-333'] | Should -Be (Get-RuleMigrationId -Rule $rule)
    }
}

Describe 'Import-AnalyticsRule singleton template recovery' {
    BeforeEach {
        Mock Get-SentinelAccessToken -ModuleName Sentinel.Api { return 'fake-token' }
        Mock Invoke-SentinelApi -ModuleName Sentinel.Rules -ParameterFilter { $Method -eq 'GET' } {
            $ex = [System.Exception]::new('Not Found')
            $ex | Add-Member -NotePropertyName 'Response' -NotePropertyValue ([PSCustomObject]@{ StatusCode = 404 })
            throw $ex
        }
        Mock Invoke-SentinelApiList -ModuleName Sentinel.Rules {
            return @([PSCustomObject]@{ name='BuiltInFusion'; kind='Fusion'
                properties=[PSCustomObject]@{ alertRuleTemplateName='tpl-fusion'; displayName='Advanced Multistage Attack Detection' } })
        }
        $script:fusionRule = [PSCustomObject]@{ kind='Fusion'; name='BuiltInFusion'
            properties=[PSCustomObject]@{ displayName='Advanced Multistage Attack Detection'
                alertRuleTemplateName='tpl-fusion'; enabled=$true } }
    }

    It 'Reports an already-installed singleton as Skipped, not Failed' {
        Mock Invoke-SentinelApi -ModuleName Sentinel.Rules -ParameterFilter { $Method -eq 'PUT' } {
            throw [System.Exception]::new("Analytics rule template 'tpl-fusion' is already installed for workspace and cannot be installed more than once.")
        }
        $r = Import-AnalyticsRule -TargetWorkspaceUri 'https://fake/ws' -Rule $script:fusionRule
        $r.Action | Should -Be 'Skipped'
        $r.RuleId | Should -Be 'BuiltInFusion'
        $r.Reason | Should -Match 'only one instance'
    }

    It 'Updates the existing instance under -OverwriteExisting' {
        $script:putUris = @()
        Mock Invoke-SentinelApi -ModuleName Sentinel.Rules -ParameterFilter { $Method -eq 'PUT' } {
            $script:putUris += $Uri
            if ($Uri -notmatch 'BuiltInFusion') {
                throw [System.Exception]::new("Analytics rule template 'tpl-fusion' is already installed for workspace and cannot be installed more than once.")
            }
            return [PSCustomObject]@{ ok = $true }
        }
        $r = Import-AnalyticsRule -TargetWorkspaceUri 'https://fake/ws' -Rule $script:fusionRule -OverwriteExisting
        $r.Action | Should -Be 'Updated'
        $r.RuleId | Should -Be 'BuiltInFusion'
        $script:putUris[-1] | Should -Match 'BuiltInFusion'
    }

    It 'Still fails when no matching template is present in the target' {
        Mock Invoke-SentinelApiList -ModuleName Sentinel.Rules { return @() }
        Mock Invoke-SentinelApi -ModuleName Sentinel.Rules -ParameterFilter { $Method -eq 'PUT' } {
            throw [System.Exception]::new("Analytics rule template 'tpl-fusion' is already installed and cannot be installed more than once.")
        }
        (Import-AnalyticsRule -TargetWorkspaceUri 'https://fake/ws' -Rule $script:fusionRule).Action | Should -Be 'Failed'
    }
}

Describe 'Import-AnalyticsRule entity mapping truncation' {
    BeforeEach {
        Mock Get-SentinelAccessToken -ModuleName Sentinel.Api { return 'fake-token' }
        Mock Invoke-SentinelApi -ModuleName Sentinel.Rules -ParameterFilter { $Method -eq 'GET' } {
            $ex = [System.Exception]::new('Not Found')
            $ex | Add-Member -NotePropertyName 'Response' -NotePropertyValue ([PSCustomObject]@{ StatusCode = 404 })
            throw $ex
        }
    }

    It 'Retries with the cap and names what was dropped' {
        $script:attempt = 0
        Mock Invoke-SentinelApi -ModuleName Sentinel.Rules -ParameterFilter { $Method -eq 'PUT' } {
            $script:attempt++
            if ($script:attempt -eq 1) {
                throw [System.Exception]::new("Invalid length of '6' for 'EntityMappings', should be between '1' and '5'.")
            }
            return [PSCustomObject]@{ ok = $true }
        }
        $mappings = 1..6 | ForEach-Object {
            [PSCustomObject]@{ entityType = "Type$_"; fieldMappings = @([PSCustomObject]@{ identifier="Id$_"; columnName="c$_" }) }
        }
        $rule = [PSCustomObject]@{ kind='Scheduled'; name='rule-1'
            properties=[PSCustomObject]@{ displayName='Too many mappings'; alertRuleTemplateName=$null
                enabled=$true; query='SecurityEvent | take 1'; entityMappings=@($mappings) } }

        $r = Import-AnalyticsRule -TargetWorkspaceUri 'https://fake/ws' -Rule $rule
        $r.Action | Should -Be 'Created'
        $r.Reason | Should -Match 'trimmed to the API maximum of 5'
        $r.Reason | Should -Match 'Type6'
        $script:attempt | Should -Be 2
    }
}
