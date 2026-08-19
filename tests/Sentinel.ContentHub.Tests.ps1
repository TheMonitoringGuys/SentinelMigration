#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for Sentinel.ContentHub module.
.DESCRIPTION
    This module generates the ManualChecklist — the list of steps the operator has to
    perform by hand after the tool finishes — so a defect here lands directly in the
    deliverable rather than in an internal data structure. It went untested until a
    reproduction showed Build-TemplateSolutionMap attributing every unmapped template
    to whichever package happened to be last in the catalog. Most of what follows
    exists to keep that from coming back.
#>

BeforeAll {
    $apiModule = Join-Path $PSScriptRoot '..' 'src' 'Sentinel.Api.psm1'
    $commonModule = Join-Path $PSScriptRoot '..' 'src' 'Sentinel.Common.psm1'
    $rulesModule = Join-Path $PSScriptRoot '..' 'src' 'Sentinel.Rules.psm1'
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'Sentinel.ContentHub.psm1'
    Import-Module $apiModule -Force
    Import-Module $rulesModule -Force -DisableNameChecking
    Import-Module $modulePath -Force -DisableNameChecking
    # Last on purpose: Rules and ContentHub each Import-Module Common -Force, which
    # re-imports it as a nested module and strips it from this session. Importing it
    # after them is what makes Get-NormalizedAction callable from the tests.
    Import-Module $commonModule -Force -DisableNameChecking

    function New-TestTemplate {
        param(
            [string]$Name,
            [string]$DisplayName,
            [hashtable]$Extra = @{}
        )
        $props = @{ displayName = $DisplayName }
        foreach ($k in $Extra.Keys) { $props[$k] = $Extra[$k] }
        [PSCustomObject]@{ name = $Name; properties = [PSCustomObject]$props }
    }

    function New-TestPackage {
        param(
            [string]$ContentId,
            [string]$DisplayName,
            [string]$Version = '1.0.0',
            # Defaults to a derived value so most tests get a well-formed catalog
            # entry; pass '' to model a catalog that omits it.
            # Untyped on purpose: [string]$x = $null coerces to '', which would make the
            # "omit it" sentinel and the "derive a default" sentinel the same value.
            $ContentProductId = $null,
            [object]$Dependencies,
            [string]$InstalledVersion
        )
        $props = @{
            contentId = $ContentId; displayName = $DisplayName; version = $Version
        }
        if ($null -eq $ContentProductId) { $props['contentProductId'] = "$ContentId-sl-$Version" }
        elseif ($ContentProductId -ne '') { $props['contentProductId'] = $ContentProductId }
        if ($Dependencies) { $props['dependencies'] = $Dependencies }
        if ($InstalledVersion) { $props['installedVersion'] = $InstalledVersion }
        [PSCustomObject]@{ properties = [PSCustomObject]$props }
    }

    function New-TestRule {
        param(
            [string]$TemplateName,
            [string]$DisplayName,
            [string]$Severity = 'High',
            [string[]]$Tactics = @('InitialAccess'),
            [bool]$Enabled = $true,
            [string]$Kind = 'Scheduled'
        )
        [PSCustomObject]@{
            kind       = $Kind
            properties = [PSCustomObject]@{
                alertRuleTemplateName = $TemplateName
                displayName           = $DisplayName
                severity              = $Severity
                tactics               = $Tactics
                enabled               = $Enabled
            }
        }
    }
}

Describe 'Get-TemplatePackageRef' {
    It 'reads an explicit packageId as the strongest signal' {
        $t = New-TestTemplate -Name 't1' -DisplayName 'Rule' -Extra @{ packageId = 'pkg-a' }
        $ref = Get-TemplatePackageRef -Template $t
        $ref.PackageId | Should -BeExactly 'pkg-a'
        $ref.Source | Should -BeExactly 'TemplateMetadata'
    }

    It 'reads packageName when there is no packageId' {
        $t = New-TestTemplate -Name 't1' -DisplayName 'Rule' -Extra @{ packageName = 'Azure Active Directory' }
        $ref = Get-TemplatePackageRef -Template $t
        $ref.PackageId | Should -BeNullOrEmpty
        $ref.PackageName | Should -BeExactly 'Azure Active Directory'
        $ref.Source | Should -BeExactly 'TemplateMetadata'
    }

    It 'falls back to packageDisplayName' {
        $t = New-TestTemplate -Name 't1' -DisplayName 'Rule' -Extra @{ packageDisplayName = 'Zscaler' }
        (Get-TemplatePackageRef -Template $t).PackageName | Should -BeExactly 'Zscaler'
    }

    It 'falls back to the source block when nothing else is present' {
        $t = New-TestTemplate -Name 't1' -DisplayName 'Rule' -Extra @{
            source = [PSCustomObject]@{ sourceId = 'src-1'; name = 'Amazon Web Services' }
        }
        $ref = Get-TemplatePackageRef -Template $t
        $ref.PackageId | Should -BeExactly 'src-1'
        $ref.PackageName | Should -BeExactly 'Amazon Web Services'
        $ref.Source | Should -BeExactly 'TemplateSource'
    }

    It 'prefers packageId over the source block' {
        $t = New-TestTemplate -Name 't1' -DisplayName 'Rule' -Extra @{
            packageId = 'pkg-a'
            source    = [PSCustomObject]@{ sourceId = 'src-1'; name = 'Other' }
        }
        (Get-TemplatePackageRef -Template $t).PackageId | Should -BeExactly 'pkg-a'
    }

    It 'reports Unknown for a template that declares nothing' {
        $t = New-TestTemplate -Name 't1' -DisplayName 'Rule'
        $ref = Get-TemplatePackageRef -Template $t
        $ref.PackageId | Should -BeNullOrEmpty
        $ref.PackageName | Should -BeNullOrEmpty
        $ref.Source | Should -BeExactly 'Unknown'
    }

    It 'treats whitespace-only metadata as absent' {
        $t = New-TestTemplate -Name 't1' -DisplayName 'Rule' -Extra @{ packageId = '   '; packageName = '' }
        $ref = Get-TemplatePackageRef -Template $t
        $ref.PackageId | Should -BeNullOrEmpty
        $ref.Source | Should -BeExactly 'Unknown'
    }

    It 'survives a null template and a template with no properties' {
        (Get-TemplatePackageRef -Template $null).Source | Should -BeExactly 'Unknown'
        (Get-TemplatePackageRef -Template ([PSCustomObject]@{ name = 't' })).Source | Should -BeExactly 'Unknown'
    }

    Context 'with a Content Hub template record' {
        It 'reads the packageId the real API actually returns' {
            # A realistic pair: the legacy template has no package fields whatsoever,
            # and the contentTemplates record is the only thing that identifies the solution.
            $t = New-TestTemplate -Name 't1' -DisplayName 'Rule'
            $ct = [PSCustomObject]@{
                properties = [PSCustomObject]@{ contentId = 't1'; packageId = 'azuresentinel.azure-sentinel-solution-gcpdns' }
            }
            $ref = Get-TemplatePackageRef -Template $t -ContentTemplate $ct
            $ref.PackageId | Should -BeExactly 'azuresentinel.azure-sentinel-solution-gcpdns'
            $ref.Source | Should -BeExactly 'ContentHubTemplate'
        }

        It 'prefers Content Hub over anything the legacy template claims' {
            $t = New-TestTemplate -Name 't1' -DisplayName 'Rule' -Extra @{ packageId = 'stale-pkg' }
            $ct = [PSCustomObject]@{ properties = [PSCustomObject]@{ packageId = 'real-pkg' } }
            (Get-TemplatePackageRef -Template $t -ContentTemplate $ct).PackageId | Should -BeExactly 'real-pkg'
        }

        It 'ignores the blank packageName the API sends and keeps looking' {
            $t = New-TestTemplate -Name 't1' -DisplayName 'Rule' -Extra @{ packageName = 'From legacy' }
            $ct = [PSCustomObject]@{ properties = [PSCustomObject]@{ packageId = 'real-pkg'; packageName = '' } }
            $ref = Get-TemplatePackageRef -Template $t -ContentTemplate $ct
            $ref.PackageId | Should -BeExactly 'real-pkg'
            $ref.PackageName | Should -BeExactly 'From legacy'
        }

        It 'falls back to the legacy template when Content Hub has no record' {
            $t = New-TestTemplate -Name 't1' -DisplayName 'Rule' -Extra @{ packageId = 'pkg-a' }
            (Get-TemplatePackageRef -Template $t -ContentTemplate $null).PackageId | Should -BeExactly 'pkg-a'
        }
    }
}

Describe 'Build-TemplateSolutionMap' {
    BeforeEach {
        $script:catalog = @(
            New-TestPackage -ContentId 'pkg-aad' -DisplayName 'Azure Active Directory'
            New-TestPackage -ContentId 'pkg-aws' -DisplayName 'Amazon Web Services'
            New-TestPackage -ContentId 'pkg-zzz' -DisplayName 'Zscaler'
        )
    }

    It 'never attributes a template to an unrelated package just because the catalog is non-empty' {
        # The original defect: the catalog loop assigned SolutionName on every
        # iteration with no comparison, so every template ended up claiming the last
        # package in the list. Both of these declare no package at all.
        $templates = @(
            New-TestTemplate -Name 'tmpl-aad' -DisplayName 'Suspicious AAD sign-in'
            New-TestTemplate -Name 'tmpl-aws' -DisplayName 'AWS root login'
        )
        $map = Build-TemplateSolutionMap -AlertRuleTemplates $templates -AvailablePackages $script:catalog -InstalledPackages @()

        $map['tmpl-aad'].SolutionName | Should -BeNullOrEmpty
        $map['tmpl-aws'].SolutionName | Should -BeNullOrEmpty
        $map['tmpl-aad'].SolutionName | Should -Not -Be 'Zscaler'
    }

    It 'does not let one template inherit another template''s solution' {
        $templates = @(
            New-TestTemplate -Name 'tmpl-aad' -DisplayName 'AAD rule' -Extra @{ packageId = 'pkg-aad' }
            New-TestTemplate -Name 'tmpl-none' -DisplayName 'Unmapped rule'
        )
        $map = Build-TemplateSolutionMap -AlertRuleTemplates $templates -AvailablePackages $script:catalog -InstalledPackages @()

        $map['tmpl-aad'].SolutionName | Should -BeExactly 'Azure Active Directory'
        $map['tmpl-none'].SolutionName | Should -BeNullOrEmpty
    }

    It 'resolves a real packageId against the available catalog' {
        $templates = @(New-TestTemplate -Name 'tmpl-aws' -DisplayName 'AWS root login' -Extra @{ packageId = 'pkg-aws' })
        $map = Build-TemplateSolutionMap -AlertRuleTemplates $templates -AvailablePackages $script:catalog -InstalledPackages @()

        $entry = $map['tmpl-aws']
        $entry.SolutionName | Should -BeExactly 'Amazon Web Services'
        $entry.PackageId | Should -BeExactly 'pkg-aws'
        $entry.IsInstalled | Should -BeFalse
    }

    It 'marks a solution installed when the package is in the installed list' {
        $templates = @(New-TestTemplate -Name 'tmpl-aad' -DisplayName 'AAD rule' -Extra @{ packageId = 'pkg-aad' })
        $installed = @(New-TestPackage -ContentId 'pkg-aad' -DisplayName 'Azure Active Directory')
        $map = Build-TemplateSolutionMap -AlertRuleTemplates $templates -AvailablePackages $script:catalog -InstalledPackages $installed

        $map['tmpl-aad'].IsInstalled | Should -BeTrue
        $map['tmpl-aad'].SolutionName | Should -BeExactly 'Azure Active Directory'
    }

    It 'resolves by exact display name when the template only names its solution' {
        $templates = @(New-TestTemplate -Name 'tmpl-z' -DisplayName 'Zscaler rule' -Extra @{ packageName = 'Zscaler' })
        $map = Build-TemplateSolutionMap -AlertRuleTemplates $templates -AvailablePackages $script:catalog -InstalledPackages @()

        $entry = $map['tmpl-z']
        $entry.SolutionName | Should -BeExactly 'Zscaler'
        $entry.PackageId | Should -BeExactly 'pkg-zzz'
    }

    It 'keeps a template-declared solution name the catalog does not list' {
        # Worth surfacing: it came from the template, not from a guess.
        $templates = @(New-TestTemplate -Name 'tmpl-x' -DisplayName 'Rule' -Extra @{ packageName = 'Some Private Solution' })
        $map = Build-TemplateSolutionMap -AlertRuleTemplates $templates -AvailablePackages $script:catalog -InstalledPackages @()

        $map['tmpl-x'].SolutionName | Should -BeExactly 'Some Private Solution'
        $map['tmpl-x'].IsInstalled | Should -BeFalse
    }

    It 'does not resolve a packageId that matches nothing' {
        $templates = @(New-TestTemplate -Name 'tmpl-q' -DisplayName 'Rule' -Extra @{ packageId = 'pkg-does-not-exist' })
        $map = Build-TemplateSolutionMap -AlertRuleTemplates $templates -AvailablePackages $script:catalog -InstalledPackages @()

        $map['tmpl-q'].SolutionName | Should -BeNullOrEmpty
        $map['tmpl-q'].PackageId | Should -BeExactly 'pkg-does-not-exist'
    }

    It 'skips templates with no name rather than keying the map on empty string' {
        $templates = @(
            New-TestTemplate -Name '' -DisplayName 'Nameless'
            New-TestTemplate -Name 'tmpl-ok' -DisplayName 'Fine'
        )
        $map = Build-TemplateSolutionMap -AlertRuleTemplates $templates -AvailablePackages @() -InstalledPackages @()

        $map.Keys.Count | Should -Be 1
        $map.ContainsKey('tmpl-ok') | Should -BeTrue
    }

    It 'returns an empty map for no templates, without throwing' {
        $map = Build-TemplateSolutionMap -AlertRuleTemplates @() -AvailablePackages $script:catalog -InstalledPackages @()
        $map | Should -BeOfType [hashtable]
        $map.Keys.Count | Should -Be 0
    }

    It 'tolerates packages with missing contentId or displayName' {
        $ragged = @(
            [PSCustomObject]@{ properties = [PSCustomObject]@{ displayName = 'No id' } }
            [PSCustomObject]@{ properties = [PSCustomObject]@{ contentId = 'pkg-noname' } }
            New-TestPackage -ContentId 'pkg-ok' -DisplayName 'Good'
        )
        $templates = @(New-TestTemplate -Name 't' -DisplayName 'R' -Extra @{ packageId = 'pkg-ok' })
        { Build-TemplateSolutionMap -AlertRuleTemplates $templates -AvailablePackages $ragged -InstalledPackages @() } |
            Should -Not -Throw
        $map = Build-TemplateSolutionMap -AlertRuleTemplates $templates -AvailablePackages $ragged -InstalledPackages @()
        $map['t'].SolutionName | Should -BeExactly 'Good'
    }

    Context 'with a Content Hub template index' {
        It 'resolves templates that carry no package metadata of their own' {
            # This is the shape the live API returns: alertRuleTemplates with nothing but
            # rule content. Before the index was wired in, every entry here came back
            # Unknown, which is what produced a checklist row for every migrated rule.
            $templates = @(
                New-TestTemplate -Name 'tmpl-aws' -DisplayName 'AWS root login'
                New-TestTemplate -Name 'tmpl-aad' -DisplayName 'Suspicious AAD sign-in'
            )
            $index = @{
                'tmpl-aws' = [PSCustomObject]@{ properties = [PSCustomObject]@{ contentId = 'tmpl-aws'; packageId = 'pkg-aws' } }
                'tmpl-aad' = [PSCustomObject]@{ properties = [PSCustomObject]@{ contentId = 'tmpl-aad'; packageId = 'pkg-aad' } }
            }

            $map = Build-TemplateSolutionMap -AlertRuleTemplates $templates -AvailablePackages $script:catalog `
                -InstalledPackages @() -ContentTemplateIndex $index

            $map['tmpl-aws'].SolutionName | Should -BeExactly 'Amazon Web Services'
            $map['tmpl-aws'].Source | Should -BeExactly 'ContentHubTemplate'
            $map['tmpl-aad'].SolutionName | Should -BeExactly 'Azure Active Directory'
        }

        It 'marks a solution installed when the resolved package is present in target' {
            $templates = @(New-TestTemplate -Name 'tmpl-aws' -DisplayName 'AWS root login')
            $index = @{ 'tmpl-aws' = [PSCustomObject]@{ properties = [PSCustomObject]@{ packageId = 'pkg-aws' } } }
            $installed = @(New-TestPackage -ContentId 'pkg-aws' -DisplayName 'Amazon Web Services')

            $map = Build-TemplateSolutionMap -AlertRuleTemplates $templates -AvailablePackages $script:catalog `
                -InstalledPackages $installed -ContentTemplateIndex $index

            $map['tmpl-aws'].IsInstalled | Should -BeTrue
        }

        It 'leaves a template unresolved when the index has no record for it' {
            $templates = @(New-TestTemplate -Name 'tmpl-orphan' -DisplayName 'Orphan rule')
            $index = @{ 'tmpl-other' = [PSCustomObject]@{ properties = [PSCustomObject]@{ packageId = 'pkg-aws' } } }

            $map = Build-TemplateSolutionMap -AlertRuleTemplates $templates -AvailablePackages $script:catalog `
                -InstalledPackages @() -ContentTemplateIndex $index

            $map['tmpl-orphan'].SolutionName | Should -BeNullOrEmpty
            $map['tmpl-orphan'].Source | Should -BeExactly 'Unknown'
        }

        It 'behaves as before when no index is supplied' {
            $templates = @(New-TestTemplate -Name 'tmpl-aws' -DisplayName 'AWS root login' -Extra @{ packageId = 'pkg-aws' })
            $map = Build-TemplateSolutionMap -AlertRuleTemplates $templates -AvailablePackages $script:catalog -InstalledPackages @()
            $map['tmpl-aws'].SolutionName | Should -BeExactly 'Amazon Web Services'
        }

        It 'maps Content Hub templates that the legacy list does not return' {
            # The two endpoints cover different sets. Templates shipped by an installed
            # solution appear only in contentTemplates, and in a real workspace they are
            # the majority: mapping the legacy list alone left most migrating rules with
            # no map entry at all, so they fell through to the checklist as "unknown".
            $templates = @(New-TestTemplate -Name 'tmpl-legacy' -DisplayName 'Built-in rule')
            $index = @{
                'tmpl-legacy'   = [PSCustomObject]@{ properties = [PSCustomObject]@{ contentId = 'tmpl-legacy'; packageId = 'pkg-aws' } }
                'tmpl-solution' = [PSCustomObject]@{ properties = [PSCustomObject]@{ contentId = 'tmpl-solution'; packageId = 'pkg-aad'; displayName = 'Solution-shipped rule' } }
            }

            $map = Build-TemplateSolutionMap -AlertRuleTemplates $templates -AvailablePackages $script:catalog `
                -InstalledPackages @() -ContentTemplateIndex $index

            $map.Keys | Should -Contain 'tmpl-solution'
            $map['tmpl-solution'].SolutionName | Should -BeExactly 'Azure Active Directory'
            $map['tmpl-solution'].Source | Should -BeExactly 'ContentHubTemplate'
            $map['tmpl-solution'].DisplayName | Should -BeExactly 'Solution-shipped rule'
        }

        It 'does not duplicate a template present in both lists' {
            $templates = @(New-TestTemplate -Name 'tmpl-aws' -DisplayName 'AWS root login')
            $index = @{ 'tmpl-aws' = [PSCustomObject]@{ properties = [PSCustomObject]@{ contentId = 'tmpl-aws'; packageId = 'pkg-aws' } } }

            $map = Build-TemplateSolutionMap -AlertRuleTemplates $templates -AvailablePackages $script:catalog `
                -InstalledPackages @() -ContentTemplateIndex $index

            $map.Keys.Count | Should -Be 1
            $map['tmpl-aws'].DisplayName | Should -BeExactly 'AWS root login'
        }
    }
}

Describe 'New-ContentHubChecklist' {
    It 'says plainly when the solution could not be determined' {
        $rules = @(New-TestRule -TemplateName 'tmpl-1' -DisplayName 'Suspicious sign-in')
        $list = @(New-ContentHubChecklist -TemplateRules $rules -TemplateSolutionMap @{})

        $list.Count | Should -Be 1
        $list[0].SolutionName | Should -Match 'Could not determine'
    }

    It 'points the operator at the rule name when the solution is unknown' {
        $rules = @(New-TestRule -TemplateName 'tmpl-1' -DisplayName 'Suspicious sign-in')
        $list = @(New-ContentHubChecklist -TemplateRules $rules -TemplateSolutionMap @{})
        $steps = @($list[0].ManualSteps) -join ' '

        $steps | Should -Match 'Suspicious sign-in'
        $steps | Should -Match 'Content Hub'
    }

    It 'names the solution in the steps when it is known' {
        $rules = @(New-TestRule -TemplateName 'tmpl-1' -DisplayName 'AAD rule')
        $map = @{ 'tmpl-1' = [PSCustomObject]@{ SolutionName = 'Azure Active Directory'; IsInstalled = $false } }
        $list = @(New-ContentHubChecklist -TemplateRules $rules -TemplateSolutionMap $map)

        $list[0].SolutionName | Should -BeExactly 'Azure Active Directory'
        (@($list[0].ManualSteps) -join ' ') | Should -Match 'Azure Active Directory'
    }

    It 'always produces numbered steps ending at enabling the rule' {
        $rules = @(New-TestRule -TemplateName 'tmpl-1' -DisplayName 'R')
        $steps = @((New-ContentHubChecklist -TemplateRules $rules -TemplateSolutionMap @{})[0].ManualSteps)

        $steps.Count | Should -Be 4
        $steps[0] | Should -Match '^1\.'
        $steps[1] | Should -Match '^2\.'
        $steps[2] | Should -Match '^3\.'
        $steps[3] | Should -Match '^4\.'
        $steps[3] | Should -Match 'enable'
    }

    It 'omits solutions that are already installed' {
        $rules = @(
            New-TestRule -TemplateName 'tmpl-have' -DisplayName 'Already there'
            New-TestRule -TemplateName 'tmpl-need' -DisplayName 'Still needed'
        )
        $map = @{
            'tmpl-have' = [PSCustomObject]@{ SolutionName = 'Installed Sol'; IsInstalled = $true }
            'tmpl-need' = [PSCustomObject]@{ SolutionName = 'Missing Sol'; IsInstalled = $false }
        }
        $list = @(New-ContentHubChecklist -TemplateRules $rules -TemplateSolutionMap $map)

        $list.Count | Should -Be 1
        $list[0].RuleDisplayName | Should -BeExactly 'Still needed'
    }

    It 'lists each template once even when many rules share it' {
        $rules = @(
            New-TestRule -TemplateName 'tmpl-1' -DisplayName 'Copy A'
            New-TestRule -TemplateName 'tmpl-1' -DisplayName 'Copy B'
            New-TestRule -TemplateName 'tmpl-1' -DisplayName 'Copy C'
        )
        $list = @(New-ContentHubChecklist -TemplateRules $rules -TemplateSolutionMap @{})

        $list.Count | Should -Be 1
        $list[0].RuleDisplayName | Should -BeExactly 'Copy A'
    }

    It 'skips custom rules that have no template name' {
        $rules = @(
            New-TestRule -TemplateName '' -DisplayName 'Custom rule'
            New-TestRule -TemplateName '   ' -DisplayName 'Whitespace rule'
            New-TestRule -TemplateName 'tmpl-1' -DisplayName 'Template rule'
        )
        $list = @(New-ContentHubChecklist -TemplateRules $rules -TemplateSolutionMap @{})

        $list.Count | Should -Be 1
        $list[0].RuleDisplayName | Should -BeExactly 'Template rule'
    }

    It 'flattens tactics into a readable string' {
        $rules = @(New-TestRule -TemplateName 'tmpl-1' -DisplayName 'R' -Tactics @('InitialAccess', 'Persistence'))
        $list = @(New-ContentHubChecklist -TemplateRules $rules -TemplateSolutionMap @{})

        $list[0].Tactics | Should -BeExactly 'InitialAccess, Persistence'
    }

    It 'carries severity and enabled state through for the report' {
        $rules = @(New-TestRule -TemplateName 'tmpl-1' -DisplayName 'R' -Severity 'Medium' -Enabled $false)
        $list = @(New-ContentHubChecklist -TemplateRules $rules -TemplateSolutionMap @{})

        $list[0].Severity | Should -BeExactly 'Medium'
        $list[0].IsEnabled | Should -BeFalse
    }

    It 'returns an empty array, not null, when there is nothing to do' {
        $list = @(New-ContentHubChecklist -TemplateRules @() -TemplateSolutionMap @{})
        $list.Count | Should -Be 0
    }

    Context 'built-in rule kinds' {
        It 'leaves Fusion off the checklist, since no solution ships it' {
            # Sending an operator to search Content Hub for 'Advanced Multistage Attack
            # Detection' is a wild goose chase: it is part of Sentinel itself.
            $rules = @(New-TestRule -TemplateName 'f71aba3d' -DisplayName 'Advanced Multistage Attack Detection' -Kind 'Fusion')
            $list = @(New-ContentHubChecklist -TemplateRules $rules -TemplateSolutionMap @{})
            $list.Count | Should -Be 0
        }

        It 'leaves the other built-in kinds off too' {
            $rules = @(
                New-TestRule -TemplateName 't-ml' -DisplayName 'Anomalous SSH login' -Kind 'MLBehaviorAnalytics'
                New-TestRule -TemplateName 't-ti' -DisplayName 'TI map' -Kind 'ThreatIntelligence'
                New-TestRule -TemplateName 't-ms' -DisplayName 'MDE incidents' -Kind 'MicrosoftSecurityIncidentCreation'
            )
            @(New-ContentHubChecklist -TemplateRules $rules -TemplateSolutionMap @{}).Count | Should -Be 0
        }

        It 'still lists a built-in kind whose solution we did identify' {
            # If a package was resolved and is genuinely absent, there is a real action
            # to take, so the kind alone must not silence it.
            $map = @{ 't-ms' = @{ TemplateId = 't-ms'; SolutionName = 'Microsoft Defender XDR'; PackageId = 'pkg-xdr'; IsInstalled = $false } }
            $rules = @(New-TestRule -TemplateName 't-ms' -DisplayName 'MDE incidents' -Kind 'MicrosoftSecurityIncidentCreation')
            $list = @(New-ContentHubChecklist -TemplateRules $rules -TemplateSolutionMap $map)
            $list.Count | Should -Be 1
            $list[0].SolutionName | Should -BeExactly 'Microsoft Defender XDR'
        }

        It 'still lists a scheduled rule whose solution is unknown' {
            $rules = @(New-TestRule -TemplateName 't-sched' -DisplayName 'Custom detection' -Kind 'Scheduled')
            @(New-ContentHubChecklist -TemplateRules $rules -TemplateSolutionMap @{}).Count | Should -Be 1
        }
    }
}

Describe 'Install-ContentPackage' {
    It 'fails cleanly for a package with no contentId' {
        $pkg = [PSCustomObject]@{ properties = [PSCustomObject]@{ displayName = 'Broken'; version = '1.0' } }
        $result = Install-ContentPackage -TargetWorkspaceUri 'https://example/ws' -Package $pkg -DryRun

        $result.Action | Should -BeExactly 'Failed'
        $result.PackageId | Should -BeExactly 'unknown'
        $result.Reason | Should -Match 'contentId'
    }

    It 'reports the dry-run verb so callers can normalise it' {
        Mock Invoke-SentinelApi -ModuleName Sentinel.ContentHub { $null }
        $pkg = New-TestPackage -ContentId 'pkg-a' -DisplayName 'Solution A'
        $result = Install-ContentPackage -TargetWorkspaceUri 'https://example/ws' -Package $pkg -DryRun

        $result.Action | Should -BeExactly 'WouldBeInstalled'
        Get-NormalizedAction $result.Action | Should -BeExactly 'Installed'
    }

    It 'reports the executed verb when not a dry run' {
        Mock Invoke-SentinelApi -ModuleName Sentinel.ContentHub { $null }
        $pkg = New-TestPackage -ContentId 'pkg-a' -DisplayName 'Solution A'
        $result = Install-ContentPackage -TargetWorkspaceUri 'https://example/ws' -Package $pkg

        $result.Action | Should -BeExactly 'Installed'
        $result.PackageId | Should -BeExactly 'pkg-a'
        $result.DisplayName | Should -BeExactly 'Solution A'
    }

    It 'turns an API failure into a Failed result rather than throwing' {
        # Assigning inside a Should -Not -Throw scriptblock would put $result in a
        # child scope; letting the call run directly tests the same thing, since an
        # escaping exception fails the test anyway.
        Mock Invoke-SentinelApi -ModuleName Sentinel.ContentHub { throw 'Forbidden' }
        $pkg = New-TestPackage -ContentId 'pkg-a' -DisplayName 'Solution A'

        $result = Install-ContentPackage -TargetWorkspaceUri 'https://example/ws' -Package $pkg
        $result.Action | Should -BeExactly 'Failed'
        $result.Reason | Should -Match 'Forbidden'
    }

    # ── Root cause 1: the request body was missing contentProductId ──
    It 'sends contentProductId in the request body' {
        $script:sentBody = $null
        Mock Invoke-SentinelApi -ModuleName Sentinel.ContentHub {
            $script:sentBody = $Body
            $null
        }
        $pkg = New-TestPackage -ContentId 'pkg-a' -DisplayName 'Solution A' -ContentProductId 'azure-sentinel-solution-a-sl-xyz'

        Install-ContentPackage -TargetWorkspaceUri 'https://example/ws' -Package $pkg | Out-Null

        $script:sentBody.properties.contentProductId | Should -BeExactly 'azure-sentinel-solution-a-sl-xyz'
    }

    It 'sends the five properties the Install API documents' {
        $script:sentBody = $null
        Mock Invoke-SentinelApi -ModuleName Sentinel.ContentHub {
            $script:sentBody = $Body
            $null
        }
        $pkg = New-TestPackage -ContentId 'pkg-a' -DisplayName 'Solution A' -Version '2.1.0'

        Install-ContentPackage -TargetWorkspaceUri 'https://example/ws' -Package $pkg | Out-Null

        $script:sentBody.properties.contentId | Should -BeExactly 'pkg-a'
        $script:sentBody.properties.displayName | Should -BeExactly 'Solution A'
        $script:sentBody.properties.version | Should -BeExactly '2.1.0'
        $script:sentBody.properties.contentKind | Should -BeExactly 'Solution'
        $script:sentBody.properties.contentProductId | Should -Not -BeNullOrEmpty
    }

    It 'passes catalog metadata through so the portal shows a real solution' {
        $script:sentBody = $null
        Mock Invoke-SentinelApi -ModuleName Sentinel.ContentHub {
            $script:sentBody = $Body
            $null
        }
        $pkg = New-TestPackage -ContentId 'pkg-a' -DisplayName 'Solution A'
        $pkg.properties | Add-Member -NotePropertyName 'author' -NotePropertyValue ([PSCustomObject]@{ name = 'Microsoft' })
        $pkg.properties | Add-Member -NotePropertyName 'categories' -NotePropertyValue ([PSCustomObject]@{ domains = @('Identity') })

        Install-ContentPackage -TargetWorkspaceUri 'https://example/ws' -Package $pkg | Out-Null

        $script:sentBody.properties.author.name | Should -BeExactly 'Microsoft'
        $script:sentBody.properties.categories.domains | Should -Contain 'Identity'
    }

    It 'names the missing contentProductId when the install is rejected' {
        # The API reference does not mark the field required, so the install is still
        # attempted - but a 400 with no explanation is worse than a stated cause.
        Mock Invoke-SentinelApi -ModuleName Sentinel.ContentHub { throw 'BadRequest' }
        $pkg = New-TestPackage -ContentId 'pkg-a' -DisplayName 'Solution A' -ContentProductId ''

        $result = Install-ContentPackage -TargetWorkspaceUri 'https://example/ws' -Package $pkg
        $result.Action | Should -BeExactly 'Failed'
        $result.Reason | Should -Match 'contentProductId'
    }

    It 'marks the write as a dry run so the API layer suppresses it' {
        # The dry-run guard lives in Invoke-SentinelApi, which drops PUT/POST/DELETE/PATCH
        # centrally. So the invariant worth pinning here is not "no call happened" but
        # "the call carried -DryRun" — dropping that switch from this call site is the
        # regression that would let a dry run write to a live workspace.
        Mock Invoke-SentinelApi -ModuleName Sentinel.ContentHub { $null }
        $pkg = New-TestPackage -ContentId 'pkg-a' -DisplayName 'Solution A'

        Install-ContentPackage -TargetWorkspaceUri 'https://example/ws' -Package $pkg -DryRun | Out-Null

        Should -Invoke Invoke-SentinelApi -ModuleName Sentinel.ContentHub -Times 1 `
            -ParameterFilter { $Method -eq 'PUT' -and $DryRun }
    }
}

Describe 'Compare-ContentPackageVersion' {
    It 'orders numeric versions' {
        Compare-ContentPackageVersion -Left '1.0.0' -Right '2.0.0' | Should -BeLessThan 0
        Compare-ContentPackageVersion -Left '2.0.0' -Right '1.0.0' | Should -BeGreaterThan 0
        Compare-ContentPackageVersion -Left '2.0.0' -Right '2.0.0' | Should -Be 0
    }

    It 'compares versions of differing depth' {
        Compare-ContentPackageVersion -Left '1.4' -Right '1.4.1' | Should -BeLessThan 0
    }

    It 'treats an absent version as older than a present one' {
        Compare-ContentPackageVersion -Left '' -Right '1.0.0' | Should -BeLessThan 0
        Compare-ContentPackageVersion -Left '1.0.0' -Right $null | Should -BeGreaterThan 0
        Compare-ContentPackageVersion -Left $null -Right '' | Should -Be 0
    }

    It 'does not throw on a version [version] cannot parse' {
        # A preview suffix must not take down the run mid-migration.
        { Compare-ContentPackageVersion -Left '2.0.0-preview' -Right '2.0.0' } | Should -Not -Throw
    }
}

Describe 'Get-SolutionMigrationPlan' {
    It 'classifies a solution absent from the target as ToInstall' {
        $plan = Get-SolutionMigrationPlan `
            -SourceInstalled @(New-TestPackage -ContentId 'pkg-a' -DisplayName 'A' -Version '1.0.0') `
            -TargetInstalled @() `
            -TargetCatalog @(New-TestPackage -ContentId 'pkg-a' -DisplayName 'A' -Version '2.0.0')

        @($plan.ToInstall).Count | Should -Be 1
        $plan.ToInstall[0].PackageId | Should -BeExactly 'pkg-a'
        # The install must use the target's catalog entry, because contentProductId
        # and version are a matched pair and the source's pair is not available here.
        $plan.ToInstall[0].Package.properties.version | Should -BeExactly '2.0.0'
    }

    It 'classifies an older target as ToUpgrade' {
        $plan = Get-SolutionMigrationPlan `
            -SourceInstalled @(New-TestPackage -ContentId 'pkg-a' -DisplayName 'A' -Version '2.0.0') `
            -TargetInstalled @(New-TestPackage -ContentId 'pkg-a' -DisplayName 'A' -Version '1.0.0') `
            -TargetCatalog @(New-TestPackage -ContentId 'pkg-a' -DisplayName 'A' -Version '2.0.0')

        @($plan.ToUpgrade).Count | Should -Be 1
        $plan.ToUpgrade[0].TargetVersion | Should -BeExactly '1.0.0'
        $plan.ToUpgrade[0].SourceVersion | Should -BeExactly '2.0.0'
    }

    It 'classifies a same-or-newer target as AlreadyCurrent' {
        $plan = Get-SolutionMigrationPlan `
            -SourceInstalled @(New-TestPackage -ContentId 'pkg-a' -DisplayName 'A' -Version '1.0.0') `
            -TargetInstalled @(New-TestPackage -ContentId 'pkg-a' -DisplayName 'A' -Version '3.0.0') `
            -TargetCatalog @(New-TestPackage -ContentId 'pkg-a' -DisplayName 'A' -Version '3.0.0')

        @($plan.AlreadyCurrent).Count | Should -Be 1
        @($plan.ToUpgrade).Count | Should -Be 0
    }

    It 'classifies a solution the target catalog does not offer as NotInCatalog' {
        # Real case: Commercial-only solutions in a Gov target, and withdrawn solutions.
        $plan = Get-SolutionMigrationPlan `
            -SourceInstalled @(New-TestPackage -ContentId 'pkg-gov-missing' -DisplayName 'Missing') `
            -TargetInstalled @() `
            -TargetCatalog @(New-TestPackage -ContentId 'pkg-other' -DisplayName 'Other')

        @($plan.NotInCatalog).Count | Should -Be 1
        $plan.NotInCatalog[0].PackageId | Should -BeExactly 'pkg-gov-missing'
        $plan.NotInCatalog[0].Reason | Should -Match 'catalog'
    }

    It 'prefers installedVersion over the catalog version when judging the target' {
        $target = New-TestPackage -ContentId 'pkg-a' -DisplayName 'A' -Version '9.9.9' -InstalledVersion '1.0.0'
        $plan = Get-SolutionMigrationPlan `
            -SourceInstalled @(New-TestPackage -ContentId 'pkg-a' -DisplayName 'A' -Version '2.0.0') `
            -TargetInstalled @($target) `
            -TargetCatalog @(New-TestPackage -ContentId 'pkg-a' -DisplayName 'A' -Version '2.0.0')

        @($plan.ToUpgrade).Count | Should -Be 1
    }

    It 'returns four empty classes for an empty source, without throwing' {
        $plan = Get-SolutionMigrationPlan -SourceInstalled @() -TargetInstalled @() -TargetCatalog @()

        @($plan.ToInstall).Count | Should -Be 0
        @($plan.ToUpgrade).Count | Should -Be 0
        @($plan.AlreadyCurrent).Count | Should -Be 0
        @($plan.NotInCatalog).Count | Should -Be 0
    }

    It 'skips source entries with no contentId rather than keying on empty string' {
        $plan = Get-SolutionMigrationPlan `
            -SourceInstalled @([PSCustomObject]@{ properties = [PSCustomObject]@{ displayName = 'Nameless' } }) `
            -TargetInstalled @() -TargetCatalog @()

        @($plan.NotInCatalog).Count | Should -Be 0
    }
}

Describe 'Get-SolutionInstallOrder' {
    BeforeAll {
        function New-OrderEntry {
            param([string]$Id, [string[]]$DependsOn = @())
            $deps = if ($DependsOn.Count -gt 0) {
                [PSCustomObject]@{
                    operator = 'AND'
                    criteria = @($DependsOn | ForEach-Object { [PSCustomObject]@{ contentId = $_; kind = 'Solution' } })
                }
            } else { $null }
            [PSCustomObject]@{
                PackageId = $Id
                Package   = New-TestPackage -ContentId $Id -DisplayName $Id -Dependencies $deps
            }
        }
    }

    It 'puts a dependency before the solution that needs it' {
        $order = Get-SolutionInstallOrder -Entries @(
            (New-OrderEntry -Id 'b' -DependsOn @('a')),
            (New-OrderEntry -Id 'a')
        )

        @($order.Ordered)[0].PackageId | Should -BeExactly 'a'
        @($order.Ordered)[1].PackageId | Should -BeExactly 'b'
        $order.HasCycle | Should -BeFalse
    }

    It 'ignores criteria pointing at content outside the install set' {
        # Most criteria name a parser or connector inside the solution, which says
        # nothing about ordering. Treating those as edges would deadlock every batch.
        $order = Get-SolutionInstallOrder -Entries @(
            (New-OrderEntry -Id 'a' -DependsOn @('some-parser-inside-a'))
        )

        $order.HasCycle | Should -BeFalse
        @($order.Ordered).Count | Should -Be 1
    }

    It 'falls back to the original order on a cycle instead of throwing' {
        $order = Get-SolutionInstallOrder -Entries @(
            (New-OrderEntry -Id 'a' -DependsOn @('b')),
            (New-OrderEntry -Id 'b' -DependsOn @('a'))
        )

        $order.HasCycle | Should -BeTrue
        @($order.Ordered).Count | Should -Be 2
    }

    It 'resolves a three-deep chain' {
        $order = Get-SolutionInstallOrder -Entries @(
            (New-OrderEntry -Id 'c' -DependsOn @('b')),
            (New-OrderEntry -Id 'b' -DependsOn @('a')),
            (New-OrderEntry -Id 'a')
        )

        @($order.Ordered | ForEach-Object { $_.PackageId }) | Should -Be @('a', 'b', 'c')
    }

    It 'returns an empty result for no entries' {
        $order = Get-SolutionInstallOrder -Entries @()
        @($order.Ordered).Count | Should -Be 0
        $order.HasCycle | Should -BeFalse
    }
}

Describe 'Sync-ContentHubSolutions' {
    BeforeEach {
        # Shaped like the real alertRuleTemplates payload: no package identity at all.
        Mock Get-SourceAlertRuleTemplates -ModuleName Sentinel.ContentHub {
            @([PSCustomObject]@{
                    name       = 'tmpl-aad'
                    properties = [PSCustomObject]@{ displayName = 'AAD rule' }
                })
        }
        # ...which is why the package identity has to come from Content Hub's own record.
        Mock Get-ContentTemplateIndex -ModuleName Sentinel.ContentHub {
            @{ 'tmpl-aad' = [PSCustomObject]@{
                    properties = [PSCustomObject]@{ contentId = 'tmpl-aad'; packageId = 'pkg-aad'; contentKind = 'AnalyticsRule' }
                }
            }
        }
        Mock Get-AvailableContentPackages -ModuleName Sentinel.ContentHub {
            @([PSCustomObject]@{
                    properties = [PSCustomObject]@{ contentId = 'pkg-aad'; displayName = 'Azure Active Directory'; version = '1.0' }
                })
        }
        Mock Get-InstalledContentPackages -ModuleName Sentinel.ContentHub { @() }
        Mock Invoke-SentinelApi -ModuleName Sentinel.ContentHub { $null }

        $script:rules = @([PSCustomObject]@{
                properties = [PSCustomObject]@{
                    alertRuleTemplateName = 'tmpl-aad'; displayName = 'AAD rule'
                    severity = 'High'; tactics = @('InitialAccess'); enabled = $true
                }
            })
    }

    It 'counts a dry-run install as installed rather than failed' {
        # WouldBeInstalled has to normalise before the success test, or every dry run
        # reports its installs as failures.
        $result = Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
            -TemplateRules $script:rules -DryRun

        @($result.InstalledPackages).Count | Should -Be 1
        @($result.FailedPackages).Count | Should -Be 0
    }

    It 'records a failure when the package is not in the catalog' {
        Mock Get-AvailableContentPackages -ModuleName Sentinel.ContentHub { @() }
        Mock Get-InstalledContentPackages -ModuleName Sentinel.ContentHub { @() }
        Mock Get-SourceAlertRuleTemplates -ModuleName Sentinel.ContentHub {
            @([PSCustomObject]@{
                    name       = 'tmpl-aad'
                    properties = [PSCustomObject]@{ displayName = 'AAD rule' }
                })
        }

        $result = Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
            -TemplateRules $script:rules -DryRun

        @($result.FailedPackages).Count | Should -Be 1
        $result.FailedPackages[0].Reason | Should -Match 'not found in available catalog'
    }

    It 'does not try to install a solution that is already present' {
        Mock Get-InstalledContentPackages -ModuleName Sentinel.ContentHub {
            @([PSCustomObject]@{
                    properties = [PSCustomObject]@{ contentId = 'pkg-aad'; displayName = 'Azure Active Directory' }
                })
        }

        $result = Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
            -TemplateRules $script:rules -DryRun

        @($result.InstalledPackages).Count | Should -Be 0
        @($result.FailedPackages).Count | Should -Be 0
    }

    It 'omits the checklist unless it is asked for' {
        $result = Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
            -TemplateRules $script:rules -DryRun
        @($result.ManualChecklist).Count | Should -Be 0
    }

    It 'builds the checklist when asked' {
        Mock Get-AvailableContentPackages -ModuleName Sentinel.ContentHub { @() }
        Mock Get-SourceAlertRuleTemplates -ModuleName Sentinel.ContentHub { @() }

        $result = Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
            -TemplateRules $script:rules -DryRun -GenerateChecklist

        @($result.ManualChecklist).Count | Should -Be 1
        $result.ManualChecklist[0].AlertRuleTemplateName | Should -BeExactly 'tmpl-aad'
    }

    It 'returns every expected property even when nothing is found' {
        Mock Get-SourceAlertRuleTemplates -ModuleName Sentinel.ContentHub { @() }
        Mock Get-AvailableContentPackages -ModuleName Sentinel.ContentHub { @() }

        $result = Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
            -TemplateRules @() -DryRun

        foreach ($p in 'InstalledPackages', 'FailedPackages', 'AlreadyInstalled', 'ManualChecklist', 'TemplateSolutionMap',
            'UpgradedPackages', 'SkippedPackages', 'NotInCatalog', 'PendingPackages', 'SourceSolutionCount', 'DependencyCycle') {
            $result.PSObject.Properties.Name | Should -Contain $p
        }
    }

    # ── Root cause 2: the source's installed solutions were never read ──
    Context 'mirroring the source workspace' {
        BeforeEach {
            # No template rules at all, so anything installed here proves the source
            # solution set drove it rather than a rule dependency.
            Mock Get-SourceAlertRuleTemplates -ModuleName Sentinel.ContentHub { @() }
            Mock Get-AvailableContentPackages -ModuleName Sentinel.ContentHub {
                @(
                    (New-TestPackage -ContentId 'pkg-aad' -DisplayName 'Azure Active Directory' -Version '3.0.0'),
                    (New-TestPackage -ContentId 'pkg-o365' -DisplayName 'Office 365' -Version '2.0.0')
                )
            }
            Mock Get-InstalledContentPackages -ModuleName Sentinel.ContentHub {
                param($WorkspaceUri)
                if ($WorkspaceUri -eq 'https://s') {
                    @(
                        (New-TestPackage -ContentId 'pkg-aad' -DisplayName 'Azure Active Directory' -Version '3.0.0'),
                        (New-TestPackage -ContentId 'pkg-o365' -DisplayName 'Office 365' -Version '2.0.0')
                    )
                }
                else { @() }
            }
        }

        It 'installs solutions from source even when no rule asks for them' {
            $result = Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
                -TemplateRules @() -DryRun

            @($result.InstalledPackages).Count | Should -Be 2
            $result.SourceSolutionCount | Should -Be 2
        }

        It 'reads the installed package list from the source, not just the target' {
            Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
                -TemplateRules @() -DryRun | Out-Null

            Should -Invoke Get-InstalledContentPackages -ModuleName Sentinel.ContentHub `
                -ParameterFilter { $WorkspaceUri -eq 'https://s' } -Times 1
        }

        It 'leaves an out-of-date target solution alone without -OverwriteExisting' {
            Mock Get-InstalledContentPackages -ModuleName Sentinel.ContentHub {
                param($WorkspaceUri)
                if ($WorkspaceUri -eq 'https://s') {
                    @(New-TestPackage -ContentId 'pkg-aad' -DisplayName 'Azure Active Directory' -Version '3.0.0')
                }
                else {
                    @(New-TestPackage -ContentId 'pkg-aad' -DisplayName 'Azure Active Directory' -Version '1.0.0')
                }
            }

            $result = Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
                -TemplateRules @() -DryRun

            @($result.SkippedPackages).Count | Should -Be 1
            @($result.UpgradedPackages).Count | Should -Be 0
            $result.SkippedPackages[0].Reason | Should -Match 'OverwriteExisting'
        }

        It 'upgrades an out-of-date target solution with -OverwriteExisting' {
            Mock Get-InstalledContentPackages -ModuleName Sentinel.ContentHub {
                param($WorkspaceUri)
                if ($WorkspaceUri -eq 'https://s') {
                    @(New-TestPackage -ContentId 'pkg-aad' -DisplayName 'Azure Active Directory' -Version '3.0.0')
                }
                else {
                    @(New-TestPackage -ContentId 'pkg-aad' -DisplayName 'Azure Active Directory' -Version '1.0.0')
                }
            }

            $result = Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
                -TemplateRules @() -DryRun -OverwriteExisting

            @($result.UpgradedPackages).Count | Should -Be 1
            @($result.SkippedPackages).Count | Should -Be 0
            # Upgrades are counted separately so the report can distinguish "new in
            # target" from "changed what was already there".
            @($result.InstalledPackages).Count | Should -Be 0
        }

        It 'reports a source solution the target catalog does not offer' {
            Mock Get-AvailableContentPackages -ModuleName Sentinel.ContentHub { @() }

            $result = Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
                -TemplateRules @() -DryRun

            @($result.NotInCatalog).Count | Should -Be 2
            @($result.InstalledPackages).Count | Should -Be 0
        }

        It 'marks every target write as a dry run' {
            Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
                -TemplateRules @() -DryRun | Out-Null

            # Every write the sync issues has to carry the switch through; a call without
            # it would reach the service for real.
            Should -Invoke Invoke-SentinelApi -ModuleName Sentinel.ContentHub -Times 0 `
                -ParameterFilter { $Method -in @('PUT', 'POST', 'DELETE', 'PATCH') -and -not $DryRun }
        }

        It 'does not double-install a solution both source and a rule ask for' {
            Mock Get-SourceAlertRuleTemplates -ModuleName Sentinel.ContentHub {
                @([PSCustomObject]@{
                        name       = 'tmpl-aad'
                        properties = [PSCustomObject]@{ displayName = 'AAD rule' }
                    })
            }

            $result = Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
                -TemplateRules $script:rules -DryRun

            @($result.InstalledPackages | Where-Object { $_.PackageId -eq 'pkg-aad' }).Count | Should -Be 1
        }

        It 'keeps the checklist quiet about solutions it just installed' {
            Mock Get-SourceAlertRuleTemplates -ModuleName Sentinel.ContentHub {
                @([PSCustomObject]@{
                        name       = 'tmpl-aad'
                        properties = [PSCustomObject]@{ displayName = 'AAD rule' }
                    })
            }

            $result = Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
                -TemplateRules $script:rules -DryRun -GenerateChecklist

            @($result.ManualChecklist).Count | Should -Be 0
        }
    }

    Context 'mapping rules to the solutions that ship them' {
        It 'resolves a rule to its solution using Content Hub, not the legacy template' {
            # The regression that produced a checklist row for every migrated rule: the
            # legacy template carries no package identity, so without the Content Hub
            # index nothing resolves and the map is uniformly Unknown.
            Mock Get-InstalledContentPackages -ModuleName Sentinel.ContentHub {
                @([PSCustomObject]@{
                        properties = [PSCustomObject]@{ contentId = 'pkg-aad'; displayName = 'Azure Active Directory' }
                    })
            }

            $result = Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
                -TemplateRules $script:rules -DryRun -GenerateChecklist

            $entry = $result.TemplateSolutionMap['tmpl-aad']
            $entry.PackageId | Should -Be 'pkg-aad'
            $entry.SolutionName | Should -Be 'Azure Active Directory'
            $entry.Source | Should -Be 'ContentHubTemplate'
            $entry.IsInstalled | Should -BeTrue
            @($result.ManualChecklist).Count | Should -Be 0
        }

        It 'reads Content Hub templates from the source workspace' {
            # Templates only exist for solutions installed in that workspace, so asking
            # the target would return nothing for anything not already migrated.
            $null = Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
                -TemplateRules $script:rules -DryRun

            Should -Invoke Get-ContentTemplateIndex -ModuleName Sentinel.ContentHub -Times 1 `
                -ParameterFilter { $WorkspaceUri -eq 'https://s' }
        }

        It 'still completes when Content Hub templates cannot be listed' {
            Mock Get-ContentTemplateIndex -ModuleName Sentinel.ContentHub { @{} }

            $result = Sync-ContentHubSolutions -SourceWorkspaceUri 'https://s' -TargetWorkspaceUri 'https://t' `
                -TemplateRules $script:rules -DryRun -GenerateChecklist

            # Degrades to "could not determine" rather than taking the migration down.
            $result.TemplateSolutionMap['tmpl-aad'].Source | Should -Be 'Unknown'
        }
    }
}
