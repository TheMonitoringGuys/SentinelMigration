#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for Sentinel.Workbooks module with mocked API calls.
#>

BeforeAll {
    $srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $srcDir 'Sentinel.Api.psm1') -Force
    Import-Module (Join-Path $srcDir 'Sentinel.Workbooks.psm1') -Force
}

Describe 'Get-WorkbookMigrationId' {
    It 'Returns deterministic GUID for same displayName' {
        $wb1 = [PSCustomObject]@{
            properties = [PSCustomObject]@{ displayName = 'My Workbook' }
        }
        $wb2 = [PSCustomObject]@{
            properties = [PSCustomObject]@{ displayName = 'My Workbook' }
        }

        $id1 = Get-WorkbookMigrationId -Workbook $wb1
        $id2 = Get-WorkbookMigrationId -Workbook $wb2

        $id1 | Should -Be $id2
        $id1 | Should -Match '^[0-9a-f]{8}-'
    }

    It 'Returns different GUIDs for different displayNames' {
        $wb1 = [PSCustomObject]@{
            properties = [PSCustomObject]@{ displayName = 'Workbook A' }
        }
        $wb2 = [PSCustomObject]@{
            properties = [PSCustomObject]@{ displayName = 'Workbook B' }
        }

        $id1 = Get-WorkbookMigrationId -Workbook $wb1
        $id2 = Get-WorkbookMigrationId -Workbook $wb2

        $id1 | Should -Not -Be $id2
    }
}

Describe 'Export-WorkbookDefinition' {
    It 'Strips read-only properties' {
        $wb = [PSCustomObject]@{
            location = 'eastus'
            tags     = @{ env = 'dev' }
            kind     = 'shared'
            properties = [PSCustomObject]@{
                displayName    = 'Test Workbook'
                serializedData = '{"version":"Notebook/1.0"}'
                timeModified   = '2024-01-01T00:00:00Z'
                userId         = 'user@example.com'
                sourceId       = '/subscriptions/old/...'
            }
        }

        $def = Export-WorkbookDefinition -Workbook $wb
        $def.properties.displayName | Should -Be 'Test Workbook'
        $def.properties.serializedData | Should -Not -BeNullOrEmpty
        $def.properties.PSObject.Properties.Name | Should -Not -Contain 'timeModified'
        $def.properties.PSObject.Properties.Name | Should -Not -Contain 'userId'
        $def.location | Should -Be 'eastus'
    }

    It 'Preserves tags' {
        $wb = [PSCustomObject]@{
            location = 'westus'
            tags     = @{ environment = 'staging'; team = 'secops' }
            kind     = 'shared'
            properties = [PSCustomObject]@{
                displayName    = 'Tagged Workbook'
                serializedData = '{}'
            }
        }

        $def = Export-WorkbookDefinition -Workbook $wb
        $def.tags.environment | Should -Be 'staging'
        $def.tags.team | Should -Be 'secops'
    }
}

Describe 'Get-SourceWorkbooks' {
    It 'Returns workbooks from mocked API' {
        Mock Invoke-SentinelApiList -ModuleName Sentinel.Workbooks {
            return @(
                [PSCustomObject]@{
                    name = 'wb-1'
                    properties = [PSCustomObject]@{ displayName = 'Workbook 1' }
                },
                [PSCustomObject]@{
                    name = 'wb-2'
                    properties = [PSCustomObject]@{ displayName = 'Workbook 2' }
                }
            )
        }

        $workbooks = Get-SourceWorkbooks `
            -ArmEndpoint 'https://management.azure.com' `
            -SubscriptionId 'sub-123' `
            -ResourceGroupName 'rg-test' `
            -WorkspaceResourceId '/subscriptions/sub-123/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/ws-test'

        $workbooks.Count | Should -Be 2
    }

    It 'Filters out previously migrated workbooks' {
        Mock Invoke-SentinelApiList -ModuleName Sentinel.Workbooks {
            return @(
                [PSCustomObject]@{
                    name = 'wb-original'
                    properties = [PSCustomObject]@{ displayName = 'Workbook A' }
                },
                [PSCustomObject]@{
                    name = 'wb-migrated'
                    properties = [PSCustomObject]@{ displayName = 'Workbook A' }
                    tags = @{ MigratedFromWorkbookId = 'wb-original' }
                }
            )
        }

        $workbooks = Get-SourceWorkbooks `
            -ArmEndpoint 'https://management.azure.com' `
            -SubscriptionId 'sub-123' `
            -ResourceGroupName 'rg-test' `
            -WorkspaceResourceId '/subscriptions/sub-123/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/ws-test'

        $workbooks.Count | Should -Be 1
        $workbooks[0].name | Should -Be 'wb-original'
    }
}
