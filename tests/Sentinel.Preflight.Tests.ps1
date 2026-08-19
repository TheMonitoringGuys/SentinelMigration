#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for Sentinel.Preflight module.
#>

BeforeAll {
    $apiModule = Join-Path $PSScriptRoot '..' 'src' 'Sentinel.Api.psm1'
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'Sentinel.Preflight.psm1'
    Import-Module $apiModule -Force
    Import-Module $modulePath -Force
}

Describe 'Test-ModulePresent' {
    It 'Returns a version string for a module that is definitely installed' {
        Test-ModulePresent -Name 'Pester' | Should -Not -BeNullOrEmpty
    }

    It 'Returns nothing for a module that does not exist' {
        Test-ModulePresent -Name 'Definitely.Not.A.Real.Module.XYZ' | Should -BeNullOrEmpty
    }
}

Describe 'Assert-MigrationPrerequisite YAML auto-install' {
    # These tests never touch the PowerShell Gallery: Test-ModulePresent and
    # Install-Module are both mocked inside the module scope, so the decision logic
    # is exercised without installing anything.

    It 'installs a missing powershell-yaml instead of blocking the run' {
        Mock Test-ModulePresent -ModuleName Sentinel.Preflight {
            param($Name)
            if ($Name -eq 'powershell-yaml') { if ($script:YamlInstalled) { '0.4.7' } else { $null } }
            else { '9.9.9' }
        }
        Mock Install-Module -ModuleName Sentinel.Preflight { $script:YamlInstalled = $true }

        $script:YamlInstalled = $false
        $result = Assert-MigrationPrerequisite -RequireYaml -Quiet

        Should -Invoke Install-Module -ModuleName Sentinel.Preflight -Times 1 -Exactly
        $result.Ok | Should -BeTrue
        $result.Blocking | Should -BeNullOrEmpty
    }

    It 'installs to CurrentUser scope so it never requires elevation' {
        Mock Test-ModulePresent -ModuleName Sentinel.Preflight {
            param($Name)
            if ($Name -eq 'powershell-yaml') { if ($script:YamlInstalled) { '0.4.7' } else { $null } }
            else { '9.9.9' }
        }
        Mock Install-Module -ModuleName Sentinel.Preflight { $script:YamlInstalled = $true }

        $script:YamlInstalled = $false
        Assert-MigrationPrerequisite -RequireYaml -Quiet | Out-Null

        Should -Invoke Install-Module -ModuleName Sentinel.Preflight -Times 1 -Exactly `
            -ParameterFilter { $Scope -eq 'CurrentUser' }
    }

    It 'blocks with manual instructions when the install fails' {
        Mock Test-ModulePresent -ModuleName Sentinel.Preflight {
            param($Name)
            if ($Name -eq 'powershell-yaml') { $null } else { '9.9.9' }
        }
        Mock Install-Module -ModuleName Sentinel.Preflight { throw 'No network' }

        $result = Assert-MigrationPrerequisite -RequireYaml -Quiet

        $result.Ok | Should -BeFalse
        ($result.Blocking -join ' ') | Should -Match 'powershell-yaml'
        ($result.Blocking -join ' ') | Should -Match 'Install-Module'
    }

    It 'does not attempt an install when -NoAutoInstall is set' {
        Mock Test-ModulePresent -ModuleName Sentinel.Preflight {
            param($Name)
            if ($Name -eq 'powershell-yaml') { $null } else { '9.9.9' }
        }
        Mock Install-Module -ModuleName Sentinel.Preflight { }

        $result = Assert-MigrationPrerequisite -RequireYaml -NoAutoInstall -Quiet

        Should -Invoke Install-Module -ModuleName Sentinel.Preflight -Times 0 -Exactly
        $result.Ok | Should -BeFalse
    }

    It 'never auto-installs Az.Accounts, which organisations pin deliberately' {
        Mock Test-ModulePresent -ModuleName Sentinel.Preflight {
            param($Name)
            if ($Name -eq 'Az.Accounts') { $null } else { '9.9.9' }
        }
        Mock Install-Module -ModuleName Sentinel.Preflight { }

        $result = Assert-MigrationPrerequisite -Quiet

        Should -Invoke Install-Module -ModuleName Sentinel.Preflight -Times 0 -Exactly
        $result.Ok | Should -BeFalse
        ($result.Blocking -join ' ') | Should -Match 'Az.Accounts'
    }

    It 'does not require YAML at all when the config is JSON' {
        Mock Test-ModulePresent -ModuleName Sentinel.Preflight {
            param($Name)
            if ($Name -eq 'powershell-yaml') { $null } else { '9.9.9' }
        }
        Mock Install-Module -ModuleName Sentinel.Preflight { }

        $result = Assert-MigrationPrerequisite -Quiet

        Should -Invoke Install-Module -ModuleName Sentinel.Preflight -Times 0 -Exactly
        $result.Ok | Should -BeTrue
    }
}

Describe 'Test-ArmActionAllowed' {
    It 'Grants an exact action match' {
        $perms = @(@{ actions = @('Microsoft.SecurityInsights/alertRules/write'); notActions = @() })
        Test-ArmActionAllowed -Action 'Microsoft.SecurityInsights/alertRules/write' -Permissions $perms |
            Should -BeTrue
    }

    It 'Grants via a trailing wildcard' {
        $perms = @(@{ actions = @('Microsoft.SecurityInsights/*'); notActions = @() })
        Test-ArmActionAllowed -Action 'Microsoft.SecurityInsights/alertRules/write' -Permissions $perms |
            Should -BeTrue
    }

    It 'Grants via the Owner-style global wildcard' {
        $perms = @(@{ actions = @('*'); notActions = @() })
        Test-ArmActionAllowed -Action 'Microsoft.Insights/workbooks/write' -Permissions $perms |
            Should -BeTrue
    }

    It 'Denies when the action is not covered' {
        $perms = @(@{ actions = @('Microsoft.OperationalInsights/*'); notActions = @() })
        Test-ArmActionAllowed -Action 'Microsoft.SecurityInsights/alertRules/write' -Permissions $perms |
            Should -BeFalse
    }

    It 'Subtracts an exact notAction from a wildcard grant' {
        $perms = @(@{
                actions    = @('*')
                notActions = @('Microsoft.SecurityInsights/alertRules/write')
            })
        Test-ArmActionAllowed -Action 'Microsoft.SecurityInsights/alertRules/write' -Permissions $perms |
            Should -BeFalse
    }

    It 'Subtracts a wildcard notAction' {
        $perms = @(@{ actions = @('*'); notActions = @('Microsoft.SecurityInsights/*') })
        Test-ArmActionAllowed -Action 'Microsoft.SecurityInsights/watchlists/write' -Permissions $perms |
            Should -BeFalse
    }

    It 'Leaves unrelated actions granted when a notAction excludes something else' {
        $perms = @(@{ actions = @('*'); notActions = @('Microsoft.Authorization/*/Delete') })
        Test-ArmActionAllowed -Action 'Microsoft.SecurityInsights/alertRules/write' -Permissions $perms |
            Should -BeTrue
    }

    It 'Grants when any one permission entry allows the action' {
        # ARM unions role assignments; a deny in one role does not veto another.
        $perms = @(
            @{ actions = @('Microsoft.OperationalInsights/*'); notActions = @() },
            @{ actions = @('Microsoft.SecurityInsights/*'); notActions = @() }
        )
        Test-ArmActionAllowed -Action 'Microsoft.SecurityInsights/alertRules/write' -Permissions $perms |
            Should -BeTrue
    }

    It 'Does not let a notAction in one entry veto a grant in another' {
        $perms = @(
            @{ actions = @('*'); notActions = @('Microsoft.SecurityInsights/*') },
            @{ actions = @('Microsoft.SecurityInsights/alertRules/write'); notActions = @() }
        )
        Test-ArmActionAllowed -Action 'Microsoft.SecurityInsights/alertRules/write' -Permissions $perms |
            Should -BeTrue
    }

    It 'Denies when the permission set is empty' {
        Test-ArmActionAllowed -Action 'Microsoft.SecurityInsights/alertRules/write' -Permissions @() |
            Should -BeFalse
    }

    It 'Denies when the permission set is null' {
        Test-ArmActionAllowed -Action 'Microsoft.SecurityInsights/alertRules/write' -Permissions $null |
            Should -BeFalse
    }

    It 'Treats the wildcard as a literal glob, not a regex' {
        # '.' must not match any character, or unrelated providers would appear granted.
        $perms = @(@{ actions = @('Microsoft.SecurityInsights/alertRules/write'); notActions = @() })
        Test-ArmActionAllowed -Action 'MicrosoftXSecurityInsights/alertRules/write' -Permissions $perms |
            Should -BeFalse
    }
}

Describe 'Test-WorkspaceAccess' {
    It 'Reports a missing workspace as a problem rather than throwing' {
        Mock Invoke-SentinelApi -ModuleName Sentinel.Preflight {
            $ex = [System.Exception]::new('Not Found')
            throw $ex
        }

        $r = Test-WorkspaceAccess -WorkspaceUri 'https://management.azure.com/subscriptions/s/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws' `
            -ArmEndpoint 'https://management.azure.com' -SubscriptionId 's' -ResourceGroupName 'rg' -Label 'Target'

        $r.Ok | Should -BeFalse
        $r.WorkspaceExists | Should -BeFalse
        @($r.Problems).Count | Should -BeGreaterThan 0
    }

    It 'Names the tenant as the likely cause when the subscription returns 401' {
        # A subscription in another tenant fails here, not at sign-in, because the
        # token is tenant-scoped. Without this hint it reads as a missing role.
        Mock Invoke-SentinelApi -ModuleName Sentinel.Preflight {
            $resp = [PSCustomObject]@{ StatusCode = 401 }
            $ex = [System.Exception]::new('Unauthorized')
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue $resp -Force
            throw $ex
        }

        $r = Test-WorkspaceAccess -WorkspaceUri 'https://management.azure.com/subscriptions/sub-other/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws' `
            -ArmEndpoint 'https://management.azure.com' -SubscriptionId 'sub-other' -ResourceGroupName 'rg' -Label 'Target'

        $r.Ok | Should -BeFalse
        $joined = @($r.Problems) -join ' '
        $joined | Should -Match '(?i)tenant'
        $joined | Should -Match 'sub-other'
    }

    It 'Reports Ok and captures the location for a healthy workspace' {        Mock Invoke-SentinelApi -ModuleName Sentinel.Preflight {
            return [PSCustomObject]@{ location = 'westeurope'; value = @() }
        }

        $r = Test-WorkspaceAccess -WorkspaceUri 'https://management.azure.com/subscriptions/s/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws' `
            -ArmEndpoint 'https://management.azure.com' -SubscriptionId 's' -ResourceGroupName 'rg' -Label 'Source'

        $r.WorkspaceExists | Should -BeTrue
        $r.SentinelEnabled | Should -BeTrue
        $r.Location | Should -Be 'westeurope'
        $r.Ok | Should -BeTrue
        @($r.Problems).Count | Should -Be 0
    }

    It 'Leaves CanWrite Unknown when the permission probe cannot run' {
        # Identities that cannot read their own role assignments must not be blocked.
        $script:callCount = 0
        Mock Invoke-SentinelApi -ModuleName Sentinel.Preflight {
            $script:callCount++
            if ($script:callCount -ge 3) { throw 'permissions unreadable' }
            return [PSCustomObject]@{ location = 'eastus'; value = @() }
        }

        $r = Test-WorkspaceAccess -WorkspaceUri 'https://management.azure.com/subscriptions/s/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws' `
            -ArmEndpoint 'https://management.azure.com' -SubscriptionId 's' -ResourceGroupName 'rg' `
            -Label 'Target' -RequireWrite

        $r.CanWrite | Should -Be 'Unknown'
        $r.Ok | Should -BeTrue
    }

    It 'Reports CanWrite No and a problem when required actions are missing' {
        Mock Invoke-SentinelApi -ModuleName Sentinel.Preflight {
            param($Uri)
            if ($Uri -match 'Microsoft\.Authorization/permissions') {
                return [PSCustomObject]@{
                    value = @([PSCustomObject]@{
                            actions    = @('Microsoft.OperationalInsights/*/read')
                            notActions = @()
                        })
                }
            }
            return [PSCustomObject]@{ location = 'eastus'; value = @() }
        }

        $r = Test-WorkspaceAccess -WorkspaceUri 'https://management.azure.com/subscriptions/s/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws' `
            -ArmEndpoint 'https://management.azure.com' -SubscriptionId 's' -ResourceGroupName 'rg' `
            -Label 'Target' -RequireWrite

        $r.CanWrite | Should -Be 'No'
        $r.Ok | Should -BeFalse
        ($r.Problems -join ' ') | Should -Match 'write permission'
    }

    It 'Reports CanWrite Yes when all required actions are granted' {
        Mock Invoke-SentinelApi -ModuleName Sentinel.Preflight {
            param($Uri)
            if ($Uri -match 'Microsoft\.Authorization/permissions') {
                return [PSCustomObject]@{
                    value = @([PSCustomObject]@{ actions = @('*'); notActions = @() })
                }
            }
            return [PSCustomObject]@{ location = 'eastus'; value = @() }
        }

        $r = Test-WorkspaceAccess -WorkspaceUri 'https://management.azure.com/subscriptions/s/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws' `
            -ArmEndpoint 'https://management.azure.com' -SubscriptionId 's' -ResourceGroupName 'rg' `
            -Label 'Target' -RequireWrite

        $r.CanWrite | Should -Be 'Yes'
        $r.Ok | Should -BeTrue
    }
}

Describe 'Show-MigrationPlan' {
    It 'Renders a plan without throwing' {
        {
            Show-MigrationPlan -Plan @{
                TargetWorkspace     = 'ws-target'
                TargetResourceGroup = 'rg-target'
                TargetSubscriptionId = 'sub-b'
                RuleCount           = 12
                WorkbookCount       = 3
                WatchlistCount      = 2
                OverwriteExisting   = $true
            }
        } | Should -Not -Throw
    }
}

Describe 'Confirm-MigrationExecution' {
    It 'Returns true without prompting when -Force is supplied' {
        Confirm-MigrationExecution -TargetWorkspace 'ws-target' -Force | Should -BeTrue
    }

    It 'Throws in a non-interactive session when -Force is absent' {
        # Pester runs non-interactively, so this exercises the automation guard:
        # an unattended run must never silently write to production.
        { Confirm-MigrationExecution -TargetWorkspace 'ws-target' } | Should -Throw
    }
}
