#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for Sentinel.Watchlists module.
#>

BeforeAll {
    $apiModule = Join-Path $PSScriptRoot '..' 'src' 'Sentinel.Api.psm1'
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'Sentinel.Watchlists.psm1'
    Import-Module $apiModule -Force
    Import-Module $modulePath -Force
}

Describe 'Get-SourceWatchlists' {
    It 'Returns watchlists from mocked API' {
        Mock Invoke-SentinelApiList -ModuleName Sentinel.Watchlists {
            return @(
                [PSCustomObject]@{
                    name = 'wl-alias-1'
                    properties = [PSCustomObject]@{
                        displayName    = 'Watchlist 1'
                        watchlistAlias = 'wl-alias-1'
                        itemsSearchKey = 'IP'
                    }
                },
                [PSCustomObject]@{
                    name = 'wl-alias-2'
                    properties = [PSCustomObject]@{
                        displayName    = 'Watchlist 2'
                        watchlistAlias = 'wl-alias-2'
                        itemsSearchKey = 'Domain'
                    }
                }
            )
        }

        $wsUri = 'https://management.azure.com/subscriptions/sub-123/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/ws-test'
        $watchlists = Get-SourceWatchlists -SourceWorkspaceUri $wsUri

        $watchlists.Count | Should -Be 2
        $watchlists[0].properties.watchlistAlias | Should -Be 'wl-alias-1'
    }
}

Describe 'Export-WatchlistDefinition' {
    It 'Strips read-only properties' {
        $watchlist = [PSCustomObject]@{
            name = 'test-alias'
            properties = [PSCustomObject]@{
                displayName       = 'Test Watchlist'
                watchlistAlias    = 'test-alias'
                itemsSearchKey    = 'IP'
                provider          = 'Microsoft'
                source            = 'test.csv'
                sourceType        = 'Local'
                description       = 'A test watchlist'
                watchlistId       = '00000000-0000-0000-0000-000000000001'
                tenantId          = '00000000-0000-0000-0000-000000000002'
                created           = '2026-01-01T00:00:00Z'
                updated           = '2026-01-02T00:00:00Z'
                uploadStatus      = 'Complete'
                provisioningState = 'Succeeded'
                isDeleted         = $false
            }
        }

        $exported = Export-WatchlistDefinition -Watchlist $watchlist

        $exported.displayName | Should -Be 'Test Watchlist'
        $exported.itemsSearchKey | Should -Be 'IP'
        $exported.PSObject.Properties['watchlistId'] | Should -BeNullOrEmpty
        $exported.PSObject.Properties['tenantId'] | Should -BeNullOrEmpty
        $exported.PSObject.Properties['created'] | Should -BeNullOrEmpty
        $exported.PSObject.Properties['updated'] | Should -BeNullOrEmpty
        $exported.PSObject.Properties['uploadStatus'] | Should -BeNullOrEmpty
        $exported.PSObject.Properties['provisioningState'] | Should -BeNullOrEmpty
        $exported.PSObject.Properties['isDeleted'] | Should -BeNullOrEmpty
    }

    It 'Preserves user-facing properties' {
        $watchlist = [PSCustomObject]@{
            name = 'test-alias'
            properties = [PSCustomObject]@{
                displayName    = 'My Watchlist'
                watchlistAlias = 'test-alias'
                itemsSearchKey = 'Domain'
                provider       = 'Custom'
                source         = 'domains.csv'
                sourceType     = 'Local'
                description    = 'Domains to watch'
                labels         = @('prod', 'security')
            }
        }

        $exported = Export-WatchlistDefinition -Watchlist $watchlist

        $exported.displayName | Should -Be 'My Watchlist'
        $exported.provider | Should -Be 'Custom'
        $exported.description | Should -Be 'Domains to watch'
        $exported.labels | Should -Contain 'prod'
    }
}

Describe 'ConvertTo-WatchlistCsv' {
    It 'Converts items to CSV with header row' {
        $items = @(
            [PSCustomObject]@{
                properties = [PSCustomObject]@{
                    itemsKeyValue = [PSCustomObject]@{ IP = '10.0.0.1'; Name = 'Server1' }
                }
            },
            [PSCustomObject]@{
                properties = [PSCustomObject]@{
                    itemsKeyValue = [PSCustomObject]@{ IP = '10.0.0.2'; Name = 'Server2' }
                }
            }
        )

        $csv = ConvertTo-WatchlistCsv -Items $items
        $lines = $csv -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -ne '' }

        $lines.Count | Should -Be 3
        $lines[0] | Should -Match 'IP'
        $lines[0] | Should -Match 'Name'
        $lines[1] | Should -Match '10\.0\.0\.1'
        $lines[2] | Should -Match '10\.0\.0\.2'
    }

    It 'Handles values containing commas by quoting' {
        $items = @(
            [PSCustomObject]@{
                properties = [PSCustomObject]@{
                    itemsKeyValue = [PSCustomObject]@{ Desc = 'hello, world'; ID = '1' }
                }
            }
        )

        $csv = ConvertTo-WatchlistCsv -Items $items
        $csv | Should -Match '"hello, world"'
    }

    It 'Returns empty string for empty items' {
        $csv = ConvertTo-WatchlistCsv -Items @()
        $csv | Should -Be ''
    }
}

Describe 'Import-Watchlist' {
    It 'Skips when watchlist exists and -OverwriteExisting not set' {
        Mock Invoke-SentinelApi -ModuleName Sentinel.Watchlists {
            return [PSCustomObject]@{ name = 'existing-wl'; properties = @{ displayName = 'Existing' } }
        }

        $wl = [PSCustomObject]@{
            name = 'my-wl'
            properties = [PSCustomObject]@{
                displayName    = 'My Watchlist'
                watchlistAlias = 'my-wl'
                itemsSearchKey = 'IP'
                provider       = 'Microsoft'
            }
        }

        $srcUri = 'https://management.azure.com/subscriptions/sub/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/src'
        $tgtUri = 'https://management.azure.com/subscriptions/sub/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/tgt'

        $result = Import-Watchlist -SourceWorkspaceUri $srcUri -TargetWorkspaceUri $tgtUri -Watchlist $wl
        $result.Action | Should -Be 'Skipped'
        $result.WatchlistAlias | Should -Be 'my-wl'
    }

    It 'Creates watchlist with items when target does not exist' {
        $getCalled = $false
        Mock Invoke-SentinelApi -ModuleName Sentinel.Watchlists {
            if ($Method -eq 'GET') {
                $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
                $ex = [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not Found', $resp)
                throw $ex
            }
            return [PSCustomObject]@{ name = 'new-wl'; properties = @{} }
        }

        Mock Invoke-SentinelApiList -ModuleName Sentinel.Watchlists {
            return @(
                [PSCustomObject]@{
                    properties = [PSCustomObject]@{
                        itemsKeyValue = [PSCustomObject]@{ IP = '10.0.0.1'; Host = 'srv1' }
                    }
                }
            )
        }

        $wl = [PSCustomObject]@{
            name = 'new-wl'
            properties = [PSCustomObject]@{
                displayName    = 'New Watchlist'
                watchlistAlias = 'new-wl'
                itemsSearchKey = 'IP'
                provider       = 'Microsoft'
                source         = 'data.csv'
            }
        }

        $srcUri = 'https://management.azure.com/subscriptions/sub/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/src'
        $tgtUri = 'https://management.azure.com/subscriptions/sub/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/tgt'

        $result = Import-Watchlist -SourceWorkspaceUri $srcUri -TargetWorkspaceUri $tgtUri -Watchlist $wl
        $result.Action | Should -Be 'Created'
        $result.ItemCount | Should -Be 1
    }
}

Describe 'Import-Watchlist with no source items' {
    It 'Omits sourceType and rawContent so the API accepts an empty watchlist' {
        $script:sentBody = $null
        Mock Invoke-SentinelApi -ModuleName Sentinel.Watchlists {
            if ($Method -eq 'GET') {
                $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not Found', $resp)
            }
            $script:sentBody = $Body
            return [PSCustomObject]@{ name = 'VIPUsers'; properties = @{} }
        }
        Mock Invoke-SentinelApiList -ModuleName Sentinel.Watchlists { return @() }

        $wl = [PSCustomObject]@{
            name = 'VIPUsers'
            properties = [PSCustomObject]@{
                displayName    = 'VIP Users'
                watchlistAlias = 'VIPUsers'
                itemsSearchKey = 'User Principal Name'
                provider       = 'Microsoft'
                source         = 'VIP Users (1).csv'
                sourceType     = 'Local'
            }
        }
        $base = 'https://management.azure.com/subscriptions/sub/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces'
        $result = Import-Watchlist -SourceWorkspaceUri "$base/src" -TargetWorkspaceUri "$base/tgt" -Watchlist $wl

        $result.Action | Should -Be 'Created'
        $script:sentBody.properties.ContainsKey('sourceType') | Should -BeFalse
        $script:sentBody.properties.ContainsKey('rawContent') | Should -BeFalse
        $script:sentBody.properties['itemsSearchKey'] | Should -Be 'User Principal Name'
    }

    It 'Still sends sourceType Local and rawContent when items exist' {
        $script:sentBody = $null
        Mock Invoke-SentinelApi -ModuleName Sentinel.Watchlists {
            if ($Method -eq 'GET') {
                $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not Found', $resp)
            }
            $script:sentBody = $Body
            return [PSCustomObject]@{ name = 'wl'; properties = @{} }
        }
        Mock Invoke-SentinelApiList -ModuleName Sentinel.Watchlists {
            return @([PSCustomObject]@{ properties = [PSCustomObject]@{ itemsKeyValue = [PSCustomObject]@{ IP = '10.0.0.1' } } })
        }

        $wl = [PSCustomObject]@{
            name = 'wl'
            properties = [PSCustomObject]@{ displayName='WL'; watchlistAlias='wl'; itemsSearchKey='IP'; provider='Microsoft' }
        }
        $base = 'https://management.azure.com/subscriptions/sub/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces'
        $null = Import-Watchlist -SourceWorkspaceUri "$base/src" -TargetWorkspaceUri "$base/tgt" -Watchlist $wl

        $script:sentBody.properties['sourceType'] | Should -Be 'Local'
        $script:sentBody.properties['rawContent'] | Should -Match 'IP'
    }
}
