#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for Sentinel.Api module with mocked REST calls.
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'Sentinel.Api.psm1'
    Import-Module $modulePath -Force
}

Describe 'Get-SentinelApiVersion' {
    It 'Returns known API version for alertRules' {
        $version = Get-SentinelApiVersion -Resource 'alertRules'
        $version | Should -Be '2024-09-01'
    }

    It 'Returns known API version for workbooks' {
        $version = Get-SentinelApiVersion -Resource 'workbooks'
        $version | Should -Be '2022-04-01'
    }

    It 'Returns known API version for watchlists' {
        $version = Get-SentinelApiVersion -Resource 'watchlists'
        $version | Should -Be '2024-09-01'
    }

    It 'Throws for unknown resource' {
        { Get-SentinelApiVersion -Resource 'nonExistent' } | Should -Throw
    }
}

Describe 'Get-SentinelWorkspaceUri' {
    It 'Builds correct workspace URI' {
        $uri = Get-SentinelWorkspaceUri `
            -ArmEndpoint 'https://management.azure.com' `
            -SubscriptionId 'sub-123' `
            -ResourceGroupName 'rg-test' `
            -WorkspaceName 'ws-test'

        $uri | Should -Be 'https://management.azure.com/subscriptions/sub-123/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/ws-test'
    }
}

Describe 'Get-AlertRulesUri' {
    It 'Builds correct alert rules list URI with api-version' {
        $wsUri = 'https://management.azure.com/subscriptions/sub-123/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/ws-test'
        $uri = Get-AlertRulesUri -WorkspaceUri $wsUri
        $uri | Should -Match 'Microsoft.SecurityInsights/alertRules\?api-version=2024-09-01'
    }
}

Describe 'Get-AlertRuleUri' {
    It 'Includes rule ID in URI' {
        $wsUri = 'https://management.azure.com/subscriptions/sub-123/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/ws-test'
        $uri = Get-AlertRuleUri -WorkspaceUri $wsUri -RuleId 'rule-abc'
        $uri | Should -Match 'alertRules/rule-abc\?api-version='
    }
}

Describe 'Get-WorkbooksUri' {
    It 'Includes category=sentinel in URI' {
        $uri = Get-WorkbooksUri `
            -ArmEndpoint 'https://management.azure.com' `
            -SubscriptionId 'sub-123' `
            -ResourceGroupName 'rg-test'
        $uri | Should -Match 'category=sentinel'
        $uri | Should -Match 'Microsoft.Insights/workbooks'
    }

    It 'Includes sourceId when provided' {
        $wsId = '/subscriptions/sub-123/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/ws-test'
        $uri = Get-WorkbooksUri `
            -ArmEndpoint 'https://management.azure.com' `
            -SubscriptionId 'sub-123' `
            -ResourceGroupName 'rg-test' `
            -SourceId $wsId
        $uri | Should -Match 'sourceId='
        $uri | Should -Match 'category=sentinel'
    }
}

Describe 'Get-WatchlistsUri' {
    It 'Builds workspace-scoped watchlists URI' {
        $wsUri = 'https://management.azure.com/subscriptions/sub-123/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/ws-test'
        $uri = Get-WatchlistsUri -WorkspaceUri $wsUri
        $uri | Should -Match 'Microsoft.SecurityInsights/watchlists'
        $uri | Should -Match 'api-version='
    }
}

Describe 'Get-WatchlistUri' {
    It 'Includes alias in URI' {
        $wsUri = 'https://management.azure.com/subscriptions/sub-123/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/ws-test'
        $uri = Get-WatchlistUri -WorkspaceUri $wsUri -WatchlistAlias 'myAlias'
        $uri | Should -Match 'watchlists/myAlias'
    }
}

Describe 'Get-WatchlistItemsUri' {
    It 'Includes alias and watchlistItems path' {
        $wsUri = 'https://management.azure.com/subscriptions/sub-123/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/ws-test'
        $uri = Get-WatchlistItemsUri -WorkspaceUri $wsUri -WatchlistAlias 'myAlias'
        $uri | Should -Match 'watchlists/myAlias/watchlistItems'
    }
}

Describe 'Get-ContentTemplateUri' {
    It 'Builds workspace-scoped contentTemplates URI' {
        $wsUri = 'https://management.azure.com/subscriptions/sub-123/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/ws-test'
        $uri = Get-ContentTemplateUri -WorkspaceUri $wsUri
        $uri | Should -Match 'Microsoft.SecurityInsights/contentTemplates\?api-version=2024-09-01'
    }

    It 'Filters server-side by content kind' {
        # Unfiltered, this returns every content kind in the workspace — workbooks,
        # playbooks, parsers — when all we consume is the analytics rules.
        $wsUri = 'https://management.azure.com/subscriptions/sub-123/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/ws-test'
        $uri = Get-ContentTemplateUri -WorkspaceUri $wsUri -ContentKind 'AnalyticsRule'
        $uri | Should -Match '\$filter='
        [uri]::UnescapeDataString($uri) | Should -Match "properties/contentKind eq 'AnalyticsRule'"
    }

    It 'Omits the filter when no kind is given' {
        $wsUri = 'https://management.azure.com/ws'
        (Get-ContentTemplateUri -WorkspaceUri $wsUri) | Should -Not -Match '\$filter'
        (Get-ContentTemplateUri -WorkspaceUri $wsUri -ContentKind '  ') | Should -Not -Match '\$filter'
    }
}

Describe 'Invoke-SentinelApi - DryRun' {
    It 'Skips PUT in dry-run mode and returns simulated result' {
        # Mock token acquisition
        Mock Get-SentinelAccessToken { return 'fake-token' } -ModuleName Sentinel.Api

        $result = Invoke-SentinelApi `
            -Uri 'https://management.azure.com/fake' `
            -Method PUT `
            -Body @{ test = 'data' } `
            -DryRun

        $result.DryRun | Should -Be $true
        $result.Simulated | Should -Be $true
        $result.Method | Should -Be 'PUT'
    }

    It 'Skips DELETE in dry-run mode' {
        Mock Get-SentinelAccessToken { return 'fake-token' } -ModuleName Sentinel.Api

        $result = Invoke-SentinelApi `
            -Uri 'https://management.azure.com/fake' `
            -Method DELETE `
            -DryRun

        $result.DryRun | Should -Be $true
        $result.Method | Should -Be 'DELETE'
    }
}

Describe 'Invoke-SentinelApiList' {
    It 'Handles paginated responses' {
        $callCount = 0
        Mock Invoke-SentinelApi -ModuleName Sentinel.Api {
            $script:callCount++
            if ($Uri -match 'page2') {
                return [PSCustomObject]@{
                    value    = @([PSCustomObject]@{ name = 'item3' })
                    nextLink = $null
                }
            }
            else {
                return [PSCustomObject]@{
                    value    = @(
                        [PSCustomObject]@{ name = 'item1' },
                        [PSCustomObject]@{ name = 'item2' }
                    )
                    nextLink = 'https://management.azure.com/fake?page2'
                }
            }
        }

        $items = Invoke-SentinelApiList -Uri 'https://management.azure.com/fake'
        $items.Count | Should -Be 3
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Pagination guards: a misbehaving collection must not hang the migration
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Invoke-SentinelApiList pagination' {
    It 'Follows nextLink across pages and returns every item' {
        Mock -ModuleName 'Sentinel.Api' Invoke-SentinelApi {
            if ($Uri -eq 'page1') { return [PSCustomObject]@{ value = @('a', 'b'); nextLink = 'page2' } }
            return [PSCustomObject]@{ value = @('c'); nextLink = $null }
        }
        $r = Invoke-SentinelApiList -Uri 'page1' -ThrottleDelayMs 0
        @($r).Count | Should -Be 3
    }

    It 'Stops when a nextLink points back at a page already fetched' {
        # Without the seen-link guard this loops until the process is killed.
        Mock -ModuleName 'Sentinel.Api' Invoke-SentinelApi {
            return [PSCustomObject]@{ value = @('x'); nextLink = 'loop' }
        }
        $r = Invoke-SentinelApiList -Uri 'loop' -ThrottleDelayMs 0 -WarningAction SilentlyContinue
        @($r).Count | Should -Be 1
    }

    It 'Stops at MaxPages' {
        $script:calls = 0
        Mock -ModuleName 'Sentinel.Api' Invoke-SentinelApi {
            $script:calls++
            return [PSCustomObject]@{ value = @('x'); nextLink = "page$script:calls" }
        }
        $r = Invoke-SentinelApiList -Uri 'start' -ThrottleDelayMs 0 -MaxPages 3 -WarningAction SilentlyContinue
        @($r).Count | Should -Be 3
    }

    It 'Truncates at MaxRecords' {
        $script:n = 0
        Mock -ModuleName 'Sentinel.Api' Invoke-SentinelApi {
            $script:n++
            return [PSCustomObject]@{ value = @(1, 2, 3, 4, 5); nextLink = "p$script:n" }
        }
        $r = Invoke-SentinelApiList -Uri 'start' -ThrottleDelayMs 0 -MaxRecords 7 -WarningAction SilentlyContinue
        @($r).Count | Should -Be 7
    }

    It 'Returns an empty array when the collection is empty' {
        Mock -ModuleName 'Sentinel.Api' Invoke-SentinelApi {
            return [PSCustomObject]@{ value = @(); nextLink = $null }
        }
        @(Invoke-SentinelApiList -Uri 'empty' -ThrottleDelayMs 0).Count | Should -Be 0
    }
}
