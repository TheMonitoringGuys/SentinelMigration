#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for Sentinel.Html module.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Sentinel.Export.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Sentinel.Html.psm1') -Force

    $script:Results = @{
        Config            = [PSCustomObject]@{
            Source  = [PSCustomObject]@{ SubscriptionId = 'sub-src'; ResourceGroupName = 'rg-dev'; WorkspaceName = 'ws-dev' }
            Target  = [PSCustomObject]@{ SubscriptionId = 'sub-tgt'; ResourceGroupName = 'rg-prod'; WorkspaceName = 'ws-prod' }
            Options = [PSCustomObject]@{ Cloud = 'Commercial'; DryRun = $true }
        }
        RuleResults       = @(
            [PSCustomObject]@{ Action = 'Created'; RuleId = 'r1'; DisplayName = 'Impossible travel'; Reason = $null }
            [PSCustomObject]@{ Action = 'Created'; RuleId = 'r2'; DisplayName = 'Mass download'; Reason = $null }
            [PSCustomObject]@{ Action = 'Updated'; RuleId = 'r3'; DisplayName = 'Brute force'; Reason = $null }
            [PSCustomObject]@{ Action = 'Skipped'; RuleId = 'r4'; DisplayName = 'Legacy auth'; Reason = 'Disabled' }
            [PSCustomObject]@{ Action = 'Failed'; RuleId = 'r5'; DisplayName = 'Suspicious PS'; Reason = 'Table missing' }
        )
        WorkbookResults   = @(
            [PSCustomObject]@{ Action = 'Created'; WorkbookId = 'w1'; DisplayName = 'SOC Overview'; Reason = $null }
            [PSCustomObject]@{ Action = 'Failed'; WorkbookId = 'w2'; DisplayName = 'Threat Hunting'; Reason = 'Forbidden' }
        )
        WatchlistResults  = @(
            [PSCustomObject]@{ Action = 'Created'; WatchlistAlias = 'VIPUsers'; DisplayName = 'VIP Users'; ItemCount = 42; Reason = $null }
        )
        ContentHubResults = @{
            InstalledPackages = @([PSCustomObject]@{ Action = 'Installed'; PackageId = 'azuresentinel'; DisplayName = 'Azure Sentinel'; Reason = $null })
            FailedPackages    = @()
            AlreadyInstalled  = @()
            ManualChecklist   = @([PSCustomObject]@{
                    AlertRuleTemplateName = 'tmpl-2'; RuleDisplayName = 'Legacy auth'; SolutionName = 'Azure AD'
                    Severity = 'Low'; Tactics = 'InitialAccess'; IsEnabled = $false; ManualSteps = @('1. Install')
                })
        }
        Errors            = @([PSCustomObject]@{ Component = 'Workbooks'; Message = 'Forbidden'; Remediation = 'Grant role' })
        StartTime         = (Get-Date).AddMinutes(-5)
        EndTime           = Get-Date
        DryRun            = $true
    }

    $script:Meta = @{
        Mode = 'DRY RUN'; Cloud = 'Commercial'; Duration = '00:05:00'
        GeneratedAt          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        SourceWorkspace      = 'ws-dev'; SourceResourceGroup = 'rg-dev'; SourceSubscriptionId = 'sub-src'
        TargetWorkspace      = 'ws-prod'; TargetResourceGroup = 'rg-prod'; TargetSubscriptionId = 'sub-tgt'
    }
}

Describe 'ConvertTo-HtmlEncoded' {
    It 'Escapes angle brackets and ampersands' {
        ConvertTo-HtmlEncoded -Text '<script>a & b</script>' | Should -Not -Match '<script>'
        ConvertTo-HtmlEncoded -Text 'a & b' | Should -Match '&amp;'
    }

    It 'Returns an empty string for null' {
        ConvertTo-HtmlEncoded -Text $null | Should -Be ''
    }
}

Describe 'ConvertTo-Slug' {
    It 'Lowercases and hyphenates behind the section prefix' {
        ConvertTo-Slug -Text 'Analytics Rules' | Should -Be 'sec-analytics-rules'
    }

    It 'Strips punctuation' {
        ConvertTo-Slug -Text 'Content Hub (beta)!' | Should -Not -Match '[()!]'
    }

    It 'Produces a value usable as an HTML id' {
        ConvertTo-Slug -Text 'Manual Checklist' | Should -Match '^[a-z][a-z0-9-]*$'
    }
}

Describe 'Get-MigrationKpis' {
    BeforeAll { $script:Kpis = Get-MigrationKpis -MigrationResults $script:Results }

    It 'Counts created rules' { $script:Kpis['Rules Created'] | Should -Be 2 }
    It 'Counts updated rules' { $script:Kpis['Rules Updated'] | Should -Be 1 }
    It 'Counts skipped rules' { $script:Kpis['Rules Skipped'] | Should -Be 1 }
    It 'Counts failed rules' { $script:Kpis['Rules Failed'] | Should -Be 1 }
    It 'Counts migrated workbooks' { $script:Kpis['Workbooks Migrated'] | Should -Be 1 }
    It 'Counts failed workbooks' { $script:Kpis['Workbooks Failed'] | Should -Be 1 }
    It 'Counts migrated watchlists' { $script:Kpis['Watchlists Migrated'] | Should -Be 1 }
    It 'Counts installed solutions' { $script:Kpis['Solutions Installed'] | Should -Be 1 }
    It 'Counts manual checklist items' { $script:Kpis['Manual Checklist'] | Should -Be 1 }
    It 'Counts errors' { $script:Kpis['Errors'] | Should -Be 1 }

    It 'Returns zeroes rather than throwing on an empty run' {
        $empty = Get-MigrationKpis -MigrationResults @{ RuleResults = @(); WorkbookResults = @(); WatchlistResults = @(); Errors = @() }
        $empty['Rules Created'] | Should -Be 0
        $empty['Errors']        | Should -Be 0
    }
}

Describe 'Get-ActionBreakdown' {
    It 'Groups results by action into label/value pairs' {
        $b = @(Get-ActionBreakdown -Results $script:Results.RuleResults)
        ($b | Where-Object { $_.Label -eq 'Created' }).Value | Should -Be 2
        ($b | Where-Object { $_.Label -eq 'Failed' }).Value  | Should -Be 1
    }

    It 'Orders the breakdown by descending count' {
        $b = @(Get-ActionBreakdown -Results $script:Results.RuleResults)
        $b[0].Label | Should -Be 'Created'
    }

    It 'Returns an empty breakdown for no results' {
        @(Get-ActionBreakdown -Results @()).Count | Should -Be 0
    }

    It 'Normalises dry-run verbs so charts match the KPI cards' {
        # Dry run emits WouldBeCreated / WouldBeCreatedDisabled. Grouping on the raw
        # value put 'WouldBeCreatedDisabled' in the chart directly beneath a KPI card
        # reading 'Rules Disabled' - one number, two names, same page.
        $dryRun = @(
            [pscustomobject]@{ RuleName = 'A'; Action = 'WouldBeCreated' }
            [pscustomobject]@{ RuleName = 'B'; Action = 'WouldBeCreatedDisabled' }
        )
        $b = @(Get-ActionBreakdown -Results $dryRun)
        @($b | Where-Object { $_.Label -match 'WouldBe' }).Count | Should -Be 0
        ($b | Where-Object { $_.Label -eq 'Created' }).Value         | Should -Be 1
        ($b | Where-Object { $_.Label -eq 'CreatedDisabled' }).Value | Should -Be 1
    }

    It 'Merges verbs that differ only by the dry-run prefix' {
        $mixed = @(
            [pscustomobject]@{ RuleName = 'A'; Action = 'Created' }
            [pscustomobject]@{ RuleName = 'B'; Action = 'WouldBeCreated' }
        )
        $b = @(Get-ActionBreakdown -Results $mixed)
        @($b).Count | Should -Be 1
        $b[0].Label | Should -Be 'Created'
        $b[0].Value | Should -Be 2
    }
}

Describe 'New-MigrationOverviewHtml' {
    BeforeAll {
        $sheets = New-MigrationSheets -MigrationResults $script:Results -SourceRules @()
        $script:Html = New-MigrationOverviewHtml -Meta $script:Meta -Kpis (Get-MigrationKpis -MigrationResults $script:Results) `
            -MigrationResults $script:Results -Details $sheets
    }

    It 'Emits a complete HTML document' {
        $script:Html | Should -Match '(?i)<!DOCTYPE html>'
        $script:Html | Should -Match '(?i)</html>'
    }

    It 'Is self-contained with no external asset references' {
        $script:Html | Should -Not -Match '(?i)<script[^>]+src='
        $script:Html | Should -Not -Match '(?i)<link[^>]+stylesheet'
    }

    It 'Shows both workspaces in the header' {
        $script:Html | Should -Match 'ws-dev'
        $script:Html | Should -Match 'ws-prod'
    }

    It 'Renders the KPI labels' {
        foreach ($label in 'Rules Created', 'Rules Failed', 'Workbooks Migrated', 'Manual Checklist') {
            $script:Html | Should -Match ([regex]::Escape($label))
        }
    }

    It 'Includes the drill-down detail sections' {
        $script:Html | Should -Match 'Analytics Rules'
        $script:Html | Should -Match 'Impossible travel'
    }

    It 'Flags failed rows for styling' {
        $script:Html | Should -Match 'row-bad'
    }

    It 'Omits detail tables when none are supplied' {
        $slim = New-MigrationOverviewHtml -Meta $script:Meta -Kpis (Get-MigrationKpis -MigrationResults $script:Results) `
            -MigrationResults $script:Results
        $slim | Should -Match '(?i)</html>'
        $slim | Should -Not -Match 'Impossible travel'
        $slim.Length | Should -BeLessThan $script:Html.Length
    }
}

Describe 'Save-MigrationOverviewHtml' {
    BeforeAll {
        $script:OutDir = Join-Path ([System.IO.Path]::GetTempPath()) "smt-html-$([guid]::NewGuid().ToString('N'))"
        New-Item -Path $script:OutDir -ItemType Directory -Force | Out-Null
        $script:Path = Join-Path $script:OutDir 'Migration-Summary.html'
        $html = New-MigrationOverviewHtml -Meta $script:Meta -Kpis (Get-MigrationKpis -MigrationResults $script:Results) -MigrationResults $script:Results
        Save-MigrationOverviewHtml -Html $html -Path $script:Path
    }

    AfterAll {
        if (Test-Path $script:OutDir) { Remove-Item $script:OutDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Writes the file to disk' {
        Test-Path $script:Path | Should -BeTrue
        (Get-Item $script:Path).Length | Should -BeGreaterThan 0
    }

    It 'Creates the parent directory when it is missing' {
        $nested = Join-Path $script:OutDir 'a' 'b' 'Migration-Summary.html'
        Save-MigrationOverviewHtml -Html '<html></html>' -Path $nested
        Test-Path $nested | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Regression: dry-run action names, CreatedDisabled, and next-step derivation
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Get-NormalizedAction' {
    It 'Strips the dry-run WouldBe prefix' {
        Get-NormalizedAction 'WouldBeCreated'         | Should -Be 'Created'
        Get-NormalizedAction 'WouldBeUpdated'         | Should -Be 'Updated'
        Get-NormalizedAction 'WouldBeCreatedDisabled' | Should -Be 'CreatedDisabled'
        Get-NormalizedAction 'WouldBeInstalled'       | Should -Be 'Installed'
    }

    It 'Leaves executed verbs untouched' {
        Get-NormalizedAction 'Created' | Should -Be 'Created'
        Get-NormalizedAction 'Failed'  | Should -Be 'Failed'
    }

    It 'Only strips the prefix at the start' {
        Get-NormalizedAction 'CreatedWouldBe' | Should -Be 'CreatedWouldBe'
    }

    It 'Returns an empty string for null' {
        Get-NormalizedAction $null | Should -Be ''
    }
}

Describe 'Get-MigrationKpis dry-run handling' {
    BeforeAll {
        $script:DryResults = @{
            RuleResults       = @(
                [PSCustomObject]@{ Action = 'WouldBeCreated' }
                [PSCustomObject]@{ Action = 'WouldBeCreated' }
                [PSCustomObject]@{ Action = 'WouldBeUpdated' }
                [PSCustomObject]@{ Action = 'WouldBeCreatedDisabled' }
                [PSCustomObject]@{ Action = 'Skipped' }
            )
            WorkbookResults   = @([PSCustomObject]@{ Action = 'WouldBeCreated' })
            WatchlistResults  = @([PSCustomObject]@{ Action = 'WouldBeUpdated' })
            ContentHubResults = $null
            Errors            = @()
        }
    }

    # A dry run is the documented first step, so all-zero cards would be the
    # first thing most users ever saw.
    It 'Counts WouldBeCreated rules as created' {
        (Get-MigrationKpis -MigrationResults $script:DryResults)['Rules Created'] | Should -Be 2
    }

    It 'Counts WouldBeUpdated rules as updated' {
        (Get-MigrationKpis -MigrationResults $script:DryResults)['Rules Updated'] | Should -Be 1
    }

    It 'Counts WouldBeCreated workbooks and watchlists as migrated' {
        $k = Get-MigrationKpis -MigrationResults $script:DryResults
        $k['Workbooks Migrated']  | Should -Be 1
        $k['Watchlists Migrated'] | Should -Be 1
    }

    It 'Does not report every KPI as zero for a dry run' {
        $k = Get-MigrationKpis -MigrationResults $script:DryResults
        $nonZero = @($k.Keys | Where-Object { [int]$k[$_] -gt 0 })
        $nonZero.Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-MigrationKpis CreatedDisabled handling' {
    BeforeAll {
        $script:DisabledResults = @{
            RuleResults       = @(
                [PSCustomObject]@{ Action = 'Created' }
                [PSCustomObject]@{ Action = 'CreatedDisabled' }
                [PSCustomObject]@{ Action = 'CreatedDisabled' }
            )
            WorkbookResults   = @()
            WatchlistResults  = @()
            ContentHubResults = $null
            Errors            = @()
        }
    }

    # These rules need a manual follow-up, so folding them into Created hides work.
    It 'Does not count CreatedDisabled rules as plain Created' {
        (Get-MigrationKpis -MigrationResults $script:DisabledResults)['Rules Created'] | Should -Be 1
    }

    It 'Reports CreatedDisabled rules under their own KPI' {
        (Get-MigrationKpis -MigrationResults $script:DisabledResults)['Rules Disabled'] | Should -Be 2
    }

    It 'Counts the dry-run form of CreatedDisabled too' {
        $r = @{
            RuleResults = @([PSCustomObject]@{ Action = 'WouldBeCreatedDisabled' })
            WorkbookResults = @(); WatchlistResults = @(); ContentHubResults = $null; Errors = @()
        }
        (Get-MigrationKpis -MigrationResults $r)['Rules Disabled'] | Should -Be 1
        (Get-MigrationKpis -MigrationResults $r)['Rules Created']  | Should -Be 0
    }
}

Describe 'Get-MigrationNextSteps' {
    It 'Tells the user to re-run with -Execute after a dry run' {
        $steps = Get-MigrationNextSteps -MigrationResults $script:Results
        @($steps | Where-Object { $_.Title -match 'Execute' }).Count | Should -BeGreaterThan 0
    }

    It 'Omits the re-run step for an execute run' {
        $r = @{
            DryRun = $false; RuleResults = @([PSCustomObject]@{ Action = 'Created' })
            WorkbookResults = @(); WatchlistResults = @(); ContentHubResults = $null; Errors = @()
        }
        $steps = Get-MigrationNextSteps -MigrationResults $r
        @($steps | Where-Object { $_.Title -match 'Execute' }).Count | Should -Be 0
    }

    It 'Raises a step for rules whose Content Hub solution could not be identified' {
        $steps = Get-MigrationNextSteps -MigrationResults $script:Results
        $s = $steps | Where-Object { $_.Title -match 'Content Hub' } | Select-Object -First 1
        $s        | Should -Not -BeNullOrEmpty
        $s.Count  | Should -Be 1
        $s.Tone   | Should -Be 'warn'
    }

    It 'Raises a step for rules created disabled' {
        $r = @{
            DryRun = $false
            RuleResults = @([PSCustomObject]@{ Action = 'CreatedDisabled' })
            WorkbookResults = @(); WatchlistResults = @(); ContentHubResults = $null; Errors = @()
        }
        $steps = Get-MigrationNextSteps -MigrationResults $r
        @($steps | Where-Object { $_.Title -match 'enable the disabled rules' }).Count | Should -Be 1
    }

    It 'Raises a step for failures in each component' {
        $r = @{
            DryRun = $false
            RuleResults      = @([PSCustomObject]@{ Action = 'Failed' })
            WorkbookResults  = @([PSCustomObject]@{ Action = 'Failed' })
            WatchlistResults = @([PSCustomObject]@{ Action = 'Failed' })
            ContentHubResults = $null; Errors = @()
        }
        $steps = Get-MigrationNextSteps -MigrationResults $r
        @($steps | Where-Object { $_.Title -match 'failed analytics rules' }).Count | Should -Be 1
        @($steps | Where-Object { $_.Title -match 'failed workbooks' }).Count       | Should -Be 1
        @($steps | Where-Object { $_.Title -match 'failed watchlists' }).Count      | Should -Be 1
    }

    It 'Always states what the tool does not migrate' {
        $r = @{
            DryRun = $false; RuleResults = @(); WorkbookResults = @(); WatchlistResults = @()
            ContentHubResults = $null; Errors = @()
        }
        $steps = Get-MigrationNextSteps -MigrationResults $r
        @($steps | Where-Object { $_.Detail -match 'Data\s+connectors' }).Count | Should -BeGreaterThan 0
    }

    It 'Numbers steps consecutively from one' {
        $steps = @(Get-MigrationNextSteps -MigrationResults $script:Results)
        $steps.Count | Should -BeGreaterThan 1
        for ($i = 0; $i -lt $steps.Count; $i++) {
            $steps[$i].Order | Should -Be ($i + 1)
        }
    }

    It 'Stays short when there is nothing to remediate' {
        $r = @{
            DryRun = $false; RuleResults = @([PSCustomObject]@{ Action = 'Created' })
            WorkbookResults = @(); WatchlistResults = @(); ContentHubResults = $null; Errors = @()
        }
        @(Get-MigrationNextSteps -MigrationResults $r).Count | Should -BeLessOrEqual 3
    }

    It 'Handles null result collections without throwing' {
        $r = @{ DryRun = $false }
        { Get-MigrationNextSteps -MigrationResults $r } | Should -Not -Throw
    }
}

Describe 'New-NextStepsHtml' {
    It 'Returns an empty string when there is nothing to render' {
        New-NextStepsHtml -Steps @() -Checklist @() | Should -Be ''
    }

    It 'Renders the manual checklist steps as list items' {
        $cl = @([PSCustomObject]@{
            RuleDisplayName = 'Legacy auth'; SolutionName = 'Azure AD'; Severity = 'Low'
            Tactics = 'InitialAccess'; IsEnabled = $false; AlertRuleTemplateName = 'tmpl-2'
            ManualSteps = @('1. Open Content Hub', '2. Install the solution')
        })
        $html = New-NextStepsHtml -Steps @() -Checklist $cl
        $html | Should -Match 'sec-manual-steps'
        $html | Should -Match '<li>Open Content Hub</li>'
        $html | Should -Match '<li>Install the solution</li>'
    }

    It 'Escapes HTML in step and checklist content' {
        $steps = @([PSCustomObject]@{ Order = 1; Tone = 'bad'; Title = '<script>x</script>'; Detail = 'a & b'; Count = 0; Anchor = '' })
        $html = New-NextStepsHtml -Steps $steps -Checklist @()
        $html | Should -Not -Match '<script>x</script>'
        $html | Should -Match '&amp;'
    }

    It 'Does not link to a section that was not rendered' {
        $steps = @([PSCustomObject]@{ Order = 1; Tone = 'bad'; Title = 'Fix rules'; Detail = 'd'; Count = 1; Anchor = 'sec-analytics-rules' })
        $html = New-NextStepsHtml -Steps $steps -Checklist @() -ValidAnchors @()
        $html | Should -Not -Match 'href="#sec-analytics-rules"'
    }

    It 'Links to a section that was rendered' {
        $steps = @([PSCustomObject]@{ Order = 1; Tone = 'bad'; Title = 'Fix rules'; Detail = 'd'; Count = 1; Anchor = 'sec-analytics-rules' })
        $html = New-NextStepsHtml -Steps $steps -Checklist @() -ValidAnchors @('sec-analytics-rules')
        $html | Should -Match 'href="#sec-analytics-rules"'
    }
}

Describe 'New-MigrationOverviewHtml next-steps integration' {
    It 'Includes the Next Steps section' {
        $html = New-MigrationOverviewHtml -Meta $script:Meta -Kpis (Get-MigrationKpis -MigrationResults $script:Results) -MigrationResults $script:Results
        $html | Should -Match 'id="sec-next-steps"'
    }

    It 'Includes the manual Content Hub steps' {
        $html = New-MigrationOverviewHtml -Meta $script:Meta -Kpis (Get-MigrationKpis -MigrationResults $script:Results) -MigrationResults $script:Results
        $html | Should -Match 'id="sec-manual-steps"'
        $html | Should -Match 'Azure AD'
    }

    It 'Stays self-contained with the new sections present' {
        $html = New-MigrationOverviewHtml -Meta $script:Meta -Kpis (Get-MigrationKpis -MigrationResults $script:Results) -MigrationResults $script:Results
        $html | Should -Not -Match '<script\s+src='
        $html | Should -Not -Match '<link[^>]+stylesheet'
    }
}

Describe 'ConvertTo-ItemList' {
    It 'Treats a null collection as empty rather than one null item' {
        # @($null).Count is 1, which is what made absent collections report a phantom item.
        @(ConvertTo-ItemList $null).Count | Should -Be 0
    }

    It 'Drops null entries from a populated collection' {
        @(ConvertTo-ItemList @('a', $null, 'b')).Count | Should -Be 2
    }

    It 'Wraps a scalar' {
        @(ConvertTo-ItemList 'a').Count | Should -Be 1
    }
}

Describe 'Absent collections do not produce phantom counts' {
    BeforeAll {
        # Content Hub sync is skipped, so its sub-collections were never populated.
        $script:Sparse = @{
            DryRun = $false
            RuleResults = @([PSCustomObject]@{ Action = 'Created' })
            ContentHubResults = [PSCustomObject]@{ InstalledPackages = $null; ManualChecklist = $null; FailedPackages = $null }
        }
    }

    It 'Reports zero for a null manual checklist' {
        (Get-MigrationKpis -MigrationResults $script:Sparse)['Manual Checklist'] | Should -Be 0
    }

    It 'Reports zero for null installed packages' {
        (Get-MigrationKpis -MigrationResults $script:Sparse)['Solutions Installed'] | Should -Be 0
    }

    It 'Reports zero errors when the error list was never populated' {
        (Get-MigrationKpis -MigrationResults $script:Sparse)['Errors'] | Should -Be 0
    }

    It 'Reports zero for null workbook and watchlist results' {
        $k = Get-MigrationKpis -MigrationResults $script:Sparse
        $k['Workbooks Migrated']  | Should -Be 0
        $k['Watchlists Migrated'] | Should -Be 0
    }

    It 'Raises no manual-install step for a null checklist' {
        $steps = Get-MigrationNextSteps -MigrationResults $script:Sparse
        @($steps | Where-Object { $_.Title -match 'Content Hub' }).Count | Should -Be 0
    }

    It 'Charts no action breakdown for a null result set' {
        @(Get-ActionBreakdown -Results $null).Count | Should -Be 0
    }

    It 'Renders nothing when steps and checklist are both null' {
        New-NextStepsHtml -Steps $null -Checklist $null | Should -Be ''
    }

    It 'Renders a dashboard without a phantom manual-steps section' {
        $html = New-MigrationOverviewHtml -Meta $script:Meta -Kpis (Get-MigrationKpis -MigrationResults $script:Sparse) -MigrationResults $script:Sparse
        $html | Should -Not -Match 'id="sec-manual-steps"'
    }
}

Describe 'New-NextStepsHtml with a single step' {
    It 'Renders a lone step even though the step object has its own Count property' {
        # The result unrolls to the bare object on return, so an unwrapped .Count
        # would read the step's Count (0) and the section would silently vanish.
        $steps = @([PSCustomObject]@{ Order = 1; Tone = 'warn'; Title = 'Only step'; Detail = 'd'; Count = 0; Anchor = '' })
        $html = New-NextStepsHtml -Steps $steps -Checklist @()
        $html | Should -Match 'Only step'
    }
}
