#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for Sentinel.Stats module with mocked Log Analytics calls.
#>

BeforeAll {
    $srcDir = Join-Path $PSScriptRoot '..' 'src'
    Import-Module (Join-Path $srcDir 'Sentinel.Stats.psm1') -Force

    function New-TestCoverageRule {
        param($Id, $Name, $Query)
        [PSCustomObject]@{
            name       = $Id
            properties = [PSCustomObject]@{
                displayName = $Name
                query       = $Query
            }
        }
    }
}

Describe 'Get-KqlReferencedTable' {
    It 'Returns the leading table from a simple query' {
        $tables = @(Get-KqlReferencedTable -Query 'SecurityEvent | where TimeGenerated > ago(1d) | count')
        $tables.Count | Should -Be 1
        $tables[0] | Should -Be 'SecurityEvent'
    }

    It 'Returns tables from union inputs' {
        $tables = @(Get-KqlReferencedTable -Query 'union withsource=X SecurityEvent, SigninLogs, AzureActivity | summarize count() by X')
        $tables.Count | Should -Be 3
        $tables | Should -Be @('SecurityEvent', 'SigninLogs', 'AzureActivity')
    }

    It 'Returns tables from isfuzzy union inputs' {
        $tables = @(Get-KqlReferencedTable -Query 'union isfuzzy=true SecurityEvent, CommonSecurityLog | take 5')
        $tables.Count | Should -Be 2
        $tables | Should -Be @('SecurityEvent', 'CommonSecurityLog')
    }

    It 'Returns tables inside a join clause' {
        $query = 'SecurityEvent | join kind=inner (SigninLogs | where ResultType == 0) on Account'
        $tables = @(Get-KqlReferencedTable -Query $query)
        $tables.Count | Should -Be 2
        $tables | Should -Be @('SecurityEvent', 'SigninLogs')
    }

    It 'Excludes let binding names but includes their source tables' {
        $query = 'let foo = SecurityEvent | where EventID == 4624; foo | summarize count()'
        $tables = @(Get-KqlReferencedTable -Query $query)
        $tables | Should -Be @('SecurityEvent')
    }

    It 'Strips line comments before parsing' {
        $query = "// AuditLogs | take 1`nSecurityEvent | where Account != 'x' // SigninLogs"
        $tables = @(Get-KqlReferencedTable -Query $query)
        $tables | Should -Be @('SecurityEvent')
    }

    It 'Returns an empty array for null and empty queries' {
        @(Get-KqlReferencedTable -Query $null).Count | Should -Be 0
        @(Get-KqlReferencedTable -Query '').Count | Should -Be 0
    }

    It 'Preserves single-item collection count' {
        $tables = @(Get-KqlReferencedTable -Query 'SecurityEvent | take 1')
        $tables.GetType().IsArray | Should -BeTrue
        $tables.Count | Should -Be 1
        $tables[0].GetType().IsArray | Should -BeFalse
        $tables[0] | Should -Be 'SecurityEvent'
    }
}

Describe 'Get-WorkspaceTableStat' {
    It 'Returns one stat object per requested table' {
        Mock Invoke-LogAnalyticsQuery -ModuleName Sentinel.Stats {
            [PSCustomObject]@{
                tables = @(
                    [PSCustomObject]@{
                        columns = @(
                            [PSCustomObject]@{ name = '_TableName_' },
                            [PSCustomObject]@{ name = 'Rows' }
                        )
                        rows = @(,(
                            @('SecurityEvent', 5)
                        ))
                    }
                )
            }
        }

        $stats = @(Get-WorkspaceTableStat -WorkspaceId '00000000-0000-0000-0000-000000000000' -TableName @('SecurityEvent', 'SigninLogs') -LookbackDays 3 -ThrottleDelayMs 0)

        $stats.Count | Should -Be 2
        ($stats | Where-Object TableName -eq 'SecurityEvent').RowCount | Should -Be 5
        ($stats | Where-Object TableName -eq 'SecurityEvent').HasData | Should -BeTrue
        ($stats | Where-Object TableName -eq 'SigninLogs').RowCount | Should -Be 0
        ($stats | Where-Object TableName -eq 'SigninLogs').HasData | Should -BeFalse
        $stats[0].LookbackDays | Should -Be 3
        Assert-MockCalled Invoke-LogAnalyticsQuery -ModuleName Sentinel.Stats -Times 1 -Exactly -ParameterFilter { $Query -match 'union withsource=_TableName_ isfuzzy=true SecurityEvent, SigninLogs' }
    }

    It 'Returns advisory failure rows without throwing' {
        Mock Invoke-LogAnalyticsQuery -ModuleName Sentinel.Stats { throw 'Forbidden' }

        { $script:stats = @(Get-WorkspaceTableStat -WorkspaceId '00000000-0000-0000-0000-000000000000' -TableName @('SecurityEvent') -ThrottleDelayMs 0) } | Should -Not -Throw
        $script:stats.Count | Should -Be 1
        $script:stats[0].RowCount | Should -Be -1
        $script:stats[0].HasData | Should -BeFalse
        $script:stats[0].Note | Should -Match 'Log Analytics query failed'
    }
}

Describe 'Get-RuleTableCoverage' {
    BeforeAll {
        $script:TableStats = @(
            [PSCustomObject]@{ TableName = 'SecurityEvent'; RowCount = 10; HasData = $true; LookbackDays = 7 },
            [PSCustomObject]@{ TableName = 'SigninLogs'; RowCount = 0; HasData = $false; LookbackDays = 7 },
            [PSCustomObject]@{ TableName = 'AzureActivity'; RowCount = 3; HasData = $true; LookbackDays = 7 }
        )
    }

    It 'Marks a rule ready when all tables have data' {
        $rule = New-TestCoverageRule -Id 'r1' -Name 'Ready rule' -Query 'SecurityEvent | join (AzureActivity | take 10) on CorrelationId'
        $row = @(Get-RuleTableCoverage -Rules @($rule) -TableStats $script:TableStats)
        $row.Status | Should -Be 'Ready'
        $row.TablesWithData | Should -Be 2
        $row.TablesEmpty | Should -Be 0
    }

    It 'Marks a rule partial when some tables are empty' {
        $rule = New-TestCoverageRule -Id 'r2' -Name 'Partial rule' -Query 'SecurityEvent | join (SigninLogs | take 10) on Account'
        $row = @(Get-RuleTableCoverage -Rules @($rule) -TableStats $script:TableStats)
        $row.Status | Should -Be 'PartialData'
        $row.TablesWithData | Should -Be 1
        $row.TablesEmpty | Should -Be 1
        $row.EmptyTableNames | Should -Be 'SigninLogs'
    }

    It 'Marks a rule no-data when all tables are empty' {
        $rule = New-TestCoverageRule -Id 'r3' -Name 'Empty rule' -Query 'SigninLogs | take 10'
        $row = @(Get-RuleTableCoverage -Rules @($rule) -TableStats $script:TableStats)
        $row.Status | Should -Be 'NoData'
        $row.TablesWithData | Should -Be 0
        $row.TablesEmpty | Should -Be 1
    }

    It 'Marks a rule with no query as NoQuery' {
        $rule = New-TestCoverageRule -Id 'r4' -Name 'Fusion rule' -Query $null
        $row = @(Get-RuleTableCoverage -Rules @($rule) -TableStats $script:TableStats)
        $row.Status | Should -Be 'NoQuery'
        $row.Tables | Should -Be ''
    }
}
