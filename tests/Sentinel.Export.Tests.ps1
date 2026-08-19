#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for Sentinel.Export module.
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'Sentinel.Export.psm1'
    Import-Module $modulePath -Force

    function New-TestRule {
        param($Name, $Severity = 'Medium', $Enabled = $true, $Template = $null, $Tactics = @())
        [PSCustomObject]@{
            name       = [guid]::NewGuid().ToString()
            kind       = 'Scheduled'
            properties = [PSCustomObject]@{
                displayName           = $Name
                severity              = $Severity
                enabled               = $Enabled
                alertRuleTemplateName = $Template
                tactics               = $Tactics
                techniques            = @('T1078')
            }
        }
    }

    $script:SourceRules = @(
        New-TestRule -Name 'Impossible travel' -Severity 'High' -Template 'tmpl-1' -Tactics @('InitialAccess', 'Persistence')
        New-TestRule -Name 'Mass download'     -Severity 'Medium' -Tactics @('Exfiltration')
        New-TestRule -Name 'Legacy auth'       -Severity 'Low' -Enabled $false -Template 'tmpl-2'
    )

    $script:Results = @{
        Config             = [PSCustomObject]@{
            Source  = [PSCustomObject]@{ SubscriptionId = 'sub-src'; ResourceGroupName = 'rg-dev'; WorkspaceName = 'ws-dev' }
            Target  = [PSCustomObject]@{ SubscriptionId = 'sub-tgt'; ResourceGroupName = 'rg-prod'; WorkspaceName = 'ws-prod' }
            Options = [PSCustomObject]@{ Cloud = 'Commercial'; DryRun = $true }
        }
        RuleClassification = @{
            All                   = $script:SourceRules
            TemplateRulesEnabled  = @($script:SourceRules[0])
            TemplateRulesDisabled = @($script:SourceRules[2])
            CustomRulesEnabled    = @($script:SourceRules[1])
            CustomRulesDisabled   = @()
        }
        RuleResults        = @(
            [PSCustomObject]@{ Action = 'Created'; RuleId = 'r1'; DisplayName = 'Impossible travel'; Reason = $null }
            [PSCustomObject]@{ Action = 'Skipped'; RuleId = 'r3'; DisplayName = 'Legacy auth'; Reason = 'Disabled' }
            [PSCustomObject]@{ Action = 'Failed'; RuleId = 'r2'; DisplayName = 'Mass download'; Reason = 'Table missing' }
        )
        WorkbookResults    = @(
            [PSCustomObject]@{ Action = 'Created'; WorkbookId = 'w1'; DisplayName = 'SOC Overview'; Reason = $null }
        )
        WatchlistResults   = @(
            [PSCustomObject]@{ Action = 'Created'; WatchlistAlias = 'VIPUsers'; DisplayName = 'VIP Users'; ItemCount = 42; Reason = $null }
        )
        ContentHubResults  = @{
            InstalledPackages = @([PSCustomObject]@{ Action = 'Installed'; PackageId = 'azuresentinel'; DisplayName = 'Azure Sentinel'; Reason = $null })
            FailedPackages    = @([PSCustomObject]@{ Action = 'Failed'; PackageId = 'okta'; DisplayName = 'Okta'; Reason = 'Not found' })
            AlreadyInstalled  = @()
            ManualChecklist   = @([PSCustomObject]@{
                    AlertRuleTemplateName = 'tmpl-2'; RuleDisplayName = 'Legacy auth'; SolutionName = 'Azure AD'
                    Severity = 'Low'; Tactics = 'InitialAccess'; IsEnabled = $false
                    ManualSteps = @('1. Open Content Hub', '2. Install')
                })
        }
        Errors             = @([PSCustomObject]@{ Component = 'Workbooks'; Message = 'Forbidden'; Remediation = 'Grant role' })
        StartTime          = (Get-Date).AddMinutes(-5)
        EndTime            = Get-Date
        DryRun             = $true
    }
}

Describe 'Get-Prop' {
    It 'Reads a nested property from PSCustomObject' {
        $o = [PSCustomObject]@{ properties = [PSCustomObject]@{ displayName = 'Rule A' } }
        Get-Prop -Object $o -Path 'properties.displayName' | Should -Be 'Rule A'
    }

    It 'Reads a nested value from a hashtable' {
        $o = @{ Options = @{ Cloud = 'Gov' } }
        Get-Prop -Object $o -Path 'Options.Cloud' | Should -Be 'Gov'
    }

    It 'Returns the default when the path is missing' {
        $o = [PSCustomObject]@{ properties = [PSCustomObject]@{} }
        Get-Prop -Object $o -Path 'properties.nope' -Default 'fallback' | Should -Be 'fallback'
    }

    It 'Returns the default for a null input' {
        Get-Prop -Object $null -Path 'a.b' -Default 'x' | Should -Be 'x'
    }
}

Describe 'Join-Values' {
    It 'Joins an array with the separator' {
        Join-Values -Value @('a', 'b', 'c') | Should -Be 'a; b; c'
    }

    It 'Returns an empty string for null' {
        Join-Values -Value $null | Should -Be ''
    }

    It 'Passes a scalar through' {
        Join-Values -Value 'solo' | Should -Be 'solo'
    }
}

Describe 'Get-RuleCategory' {
    It 'Reports origin and state for an enabled template rule' {
        Get-RuleCategory -Rule $script:SourceRules[0] | Should -Be 'Template (Enabled)'
    }

    It 'Reports Custom for a rule with no template id' {
        Get-RuleCategory -Rule $script:SourceRules[1] | Should -Be 'Custom (Enabled)'
    }

    It 'Reports Disabled state for a disabled rule' {
        Get-RuleCategory -Rule $script:SourceRules[2] | Should -Be 'Template (Disabled)'
    }
}

Describe 'ConvertTo-RuleResultRows' {
    It 'Produces one row per result' {
        $rows = ConvertTo-RuleResultRows -Results $script:Results.RuleResults -SourceRules $script:SourceRules
        @($rows).Count | Should -Be 3
    }

    It 'Enriches rows from the matching source rule by display name' {
        $rows = ConvertTo-RuleResultRows -Results $script:Results.RuleResults -SourceRules $script:SourceRules
        $row = $rows | Where-Object { $_.DisplayName -eq 'Impossible travel' }
        $row.Severity | Should -Be 'High'
        $row.Origin   | Should -Be 'Template (Enabled)'
        $row.Tactics  | Should -Be 'InitialAccess; Persistence'
    }

    It 'Still emits a row when no source rule matches' {
        $orphan = @([PSCustomObject]@{ Action = 'Failed'; RuleId = 'x'; DisplayName = 'Unknown rule'; Reason = 'boom' })
        $rows = ConvertTo-RuleResultRows -Results $orphan -SourceRules $script:SourceRules
        @($rows).Count | Should -Be 1
        $rows[0].DisplayName | Should -Be 'Unknown rule'
    }

    It 'Returns nothing for an empty result set' {
        @(ConvertTo-RuleResultRows -Results @() -SourceRules $script:SourceRules).Count | Should -Be 0
    }
}

Describe 'ConvertTo-WatchlistResultRows' {
    It 'Carries the alias and item count through' {
        $rows = @(ConvertTo-WatchlistResultRows -Results $script:Results.WatchlistResults)
        $rows.Count | Should -Be 1
        $rows[0].WatchlistAlias | Should -Be 'VIPUsers'
        $rows[0].ItemCount      | Should -Be 42
    }
}

Describe 'ConvertTo-ContentHubRows' {
    It 'Flattens installed and failed packages into one set' {
        $rows = @(ConvertTo-ContentHubRows -ContentHubResults $script:Results.ContentHubResults)
        $rows.Count | Should -Be 2
        ($rows | Where-Object { $_.Action -eq 'Failed' }).PackageId | Should -Be 'okta'
    }

    It 'Handles a null Content Hub result' {
        @(ConvertTo-ContentHubRows -ContentHubResults $null).Count | Should -Be 0
    }
}

Describe 'ConvertTo-ChecklistRows' {
    It 'Joins manual steps into a single field' {
        $rows = @(ConvertTo-ChecklistRows -Checklist $script:Results.ContentHubResults.ManualChecklist)
        $rows.Count | Should -Be 1
        $rows[0].ManualSteps | Should -Match 'Open Content Hub'
        $rows[0].ManualSteps | Should -Match 'Install'
    }

    It 'Returns nothing for an empty checklist' {
        @(ConvertTo-ChecklistRows -Checklist @()).Count | Should -Be 0
    }
}

Describe 'ConvertTo-SourceRuleRows' {
    It 'Emits a row per source rule with an origin' {
        $rows = @(ConvertTo-SourceRuleRows -Rules $script:SourceRules)
        $rows.Count | Should -Be 3
        ($rows | Where-Object { $_.DisplayName -eq 'Legacy auth' }).Origin | Should -Be 'Template (Disabled)'
    }
}

Describe 'ConvertTo-SourceWatchlistRows' {
    It 'Reads the standard ARM watchlist property path' {
        $wl = @([PSCustomObject]@{
                properties = [PSCustomObject]@{
                    displayName = 'VIP Users'; watchlistAlias = 'VIPUsers'
                    provider = 'Custom'; itemsSearchKey = 'UPN'
                }
            })
        $rows = @(ConvertTo-SourceWatchlistRows -Watchlists $wl)
        $rows[0].DisplayName    | Should -Be 'VIP Users'
        $rows[0].Alias          | Should -Be 'VIPUsers'
        $rows[0].ItemsSearchKey | Should -Be 'UPN'
    }
}

Describe 'Get-SafeSheetName' {
    It 'Removes characters Excel rejects' {
        Get-SafeSheetName -Name 'a:b\c/d?e*f[g]' | Should -Not -Match '[:\\/?*\[\]]'
    }

    It 'Caps the length at 31 characters' {
        (Get-SafeSheetName -Name ('x' * 60)).Length | Should -BeLessOrEqual 31
    }

    It 'Keeps the suffix within budget' {
        $n = Get-SafeSheetName -Name ('y' * 60) -Suffix '_2'
        $n.Length | Should -BeLessOrEqual 31
        $n | Should -Match '_2$'
    }

    It 'Falls back to Sheet for an empty name' {
        Get-SafeSheetName -Name '   ' | Should -Be 'Sheet'
    }
}

Describe 'Get-SafeTableName' {
    It 'Removes spaces and punctuation' {
        Get-SafeTableName -Name 'Analytics Rules' | Should -Be 'AnalyticsRules'
    }

    It 'Prefixes names that start with a digit' {
        Get-SafeTableName -Name '2023 Results' | Should -Match '^[A-Za-z_]'
    }

    It 'Falls back for an empty name' {
        Get-SafeTableName -Name '!!!' | Should -Not -BeNullOrEmpty
    }
}

Describe 'New-MigrationSheets' {
    BeforeAll {
        $script:Sheets = New-MigrationSheets -MigrationResults $script:Results -SourceRules $script:SourceRules
    }

    It 'Returns an ordered dictionary' {
        $script:Sheets | Should -BeOfType ([System.Collections.Specialized.OrderedDictionary])
    }

    It 'Leads with the Summary sheet' {
        @($script:Sheets.Keys)[0] | Should -Be 'Summary'
    }

    It 'Includes every expected sheet' {
        foreach ($n in 'Summary', 'Analytics Rules', 'Workbooks', 'Watchlists', 'Content Hub', 'Manual Checklist', 'Source Rules', 'Errors') {
            $script:Sheets.Keys | Should -Contain $n
        }
    }

    It 'Records the source and target workspaces in the Summary sheet' {
        $summary = @($script:Sheets['Summary'])
        ($summary | Where-Object { $_.Property -eq 'Source Workspace' }).Value | Should -Be 'ws-dev'
        ($summary | Where-Object { $_.Property -eq 'Target Workspace' }).Value | Should -Be 'ws-prod'
    }

    It 'Records the run mode in the Summary sheet' {
        $mode = (@($script:Sheets['Summary']) | Where-Object { $_.Property -eq 'Mode' }).Value
        $mode | Should -Match 'DRY RUN'
    }
}

Describe 'Null-safety of the flatteners' {
    # $sourceWorkbooks / $sourceWatchlists are never assigned when the matching
    # -Migrate* option is off, so every flattener must treat $null as "no items"
    # rather than emitting one all-empty row.
    It 'ConvertTo-SourceWorkbookRows returns no rows for null' {
        @(ConvertTo-SourceWorkbookRows -Workbooks $null).Count | Should -Be 0
    }

    It 'ConvertTo-SourceWatchlistRows returns no rows for null' {
        @(ConvertTo-SourceWatchlistRows -Watchlists $null).Count | Should -Be 0
    }

    It 'ConvertTo-SourceRuleRows returns no rows for null' {
        @(ConvertTo-SourceRuleRows -Rules $null).Count | Should -Be 0
    }

    It 'ConvertTo-RuleResultRows returns no rows for null' {
        @(ConvertTo-RuleResultRows -Results $null -SourceRules $null).Count | Should -Be 0
    }

    It 'ConvertTo-ErrorRows returns no rows for null' {
        @(ConvertTo-ErrorRows -Errors $null).Count | Should -Be 0
    }

    It 'ConvertTo-ChecklistRows returns no rows for null' {
        @(ConvertTo-ChecklistRows -Checklist $null).Count | Should -Be 0
    }

    It 'Still emits rows when real data is supplied' {
        $r = @([PSCustomObject]@{ Action = 'Created'; RuleId = 'r1'; DisplayName = 'A'; Reason = $null })
        @(ConvertTo-RuleResultRows -Results $r -SourceRules $null).Count | Should -Be 1
    }
}

Describe 'ConvertTo-ItemList' {
    It 'Maps null to an empty array' {
        @(ConvertTo-ItemList -Value $null).Count | Should -Be 0
    }

    It 'Drops null entries from a sparse collection' {
        @(ConvertTo-ItemList -Value @('a', $null, 'b')).Count | Should -Be 2
    }

    It 'Wraps a scalar' {
        @(ConvertTo-ItemList -Value 'solo').Count | Should -Be 1
    }
}

Describe 'Export-RawJson' {
    BeforeAll {
        $script:RawDir = Join-Path ([System.IO.Path]::GetTempPath()) "smt-raw-$([guid]::NewGuid().ToString('N'))"
        New-Item -Path $script:RawDir -ItemType Directory -Force | Out-Null
        Export-RawJson -Collections ([ordered]@{
                SourceRules = $script:SourceRules
                Errors      = $script:Results.Errors
            }) -OutputDir $script:RawDir -Scope ([ordered]@{ targetWorkspaceName = 'ws-prod' }) | Out-Null
    }

    AfterAll {
        if (Test-Path $script:RawDir) { Remove-Item $script:RawDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Writes one file per collection' {
        Test-Path (Join-Path $script:RawDir 'raw' 'SourceRules.json') | Should -BeTrue
        Test-Path (Join-Path $script:RawDir 'raw' 'Errors.json')      | Should -BeTrue
    }

    It 'Writes a combined _Full.json envelope' {
        $full = Get-Content (Join-Path $script:RawDir 'raw' '_Full.json') -Raw | ConvertFrom-Json
        $full.scope.targetWorkspaceName | Should -Be 'ws-prod'
        @($full.collections.SourceRules).Count | Should -Be 3
    }

    It 'Produces parseable JSON per collection' {
        { Get-Content (Join-Path $script:RawDir 'raw' 'SourceRules.json') -Raw | ConvertFrom-Json } | Should -Not -Throw
    }
}

Describe 'Export-MigrationWorkbook' {
    BeforeAll {
        $script:WbDir = Join-Path ([System.IO.Path]::GetTempPath()) "smt-wb-$([guid]::NewGuid().ToString('N'))"
        New-Item -Path $script:WbDir -ItemType Directory -Force | Out-Null
        $sheets = New-MigrationSheets -MigrationResults $script:Results -SourceRules $script:SourceRules
        $script:WbPath = Export-MigrationWorkbook -Sheets $sheets -OutputDir $script:WbDir
    }

    AfterAll {
        if (Test-Path $script:WbDir) { Remove-Item $script:WbDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Writes an artifact to disk' {
        $script:WbPath | Should -Not -BeNullOrEmpty
        Test-Path $script:WbPath | Should -BeTrue
    }

    It 'Produces either an xlsx or a CSV fallback folder' {
        if ($script:WbPath -like '*.xlsx') {
            (Get-Item $script:WbPath).Length | Should -BeGreaterThan 0
        }
        else {
            @(Get-ChildItem $script:WbPath -Filter '*.csv').Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'Export action normalisation (dry-run verb leak)' {
    # The exports wrote $r.Action straight through, so a dry run produced a
    # spreadsheet column reading 'WouldBeCreatedDisabled' next to a dashboard
    # card reading 'Rules Disabled'. agent-input.json carried it downstream.
    BeforeAll {
        $script:dryRules = @(
            [PSCustomObject]@{ Action = 'WouldBeCreated';         RuleId = 'r1'; DisplayName = 'Impossible travel'; Reason = $null }
            [PSCustomObject]@{ Action = 'WouldBeCreatedDisabled'; RuleId = 'r2'; DisplayName = 'Suspicious signin';  Reason = 'Source rule disabled' }
            [PSCustomObject]@{ Action = 'Failed';                 RuleId = 'r3'; DisplayName = 'Broken rule';        Reason = '429 throttled' }
        )
    }

    It 'Normalises rule result actions' {
        $rows = @(ConvertTo-RuleResultRows -Results $script:dryRules -SourceRules @())
        @($rows | Where-Object { $_.Action -match 'WouldBe' }).Count | Should -Be 0
        $rows[0].Action | Should -Be 'Created'
        $rows[1].Action | Should -Be 'CreatedDisabled'
        $rows[2].Action | Should -Be 'Failed'
    }

    It 'Records that a planned action was only planned' {
        # Normalising alone would lose the dry-run distinction, so the fact moves
        # into its own column rather than being smuggled into the verb.
        $rows = @(ConvertTo-RuleResultRows -Results $script:dryRules -SourceRules @())
        $rows[0].PlannedOnly | Should -BeTrue
        $rows[2].PlannedOnly | Should -BeFalse
    }

    It 'Normalises workbook result actions' {
        $rows = @(ConvertTo-WorkbookResultRows -Results @(
            [PSCustomObject]@{ Action = 'WouldBeCreated'; WorkbookId = 'w1'; DisplayName = 'Overview'; Reason = $null }))
        $rows[0].Action | Should -Be 'Created'
        $rows[0].PlannedOnly | Should -BeTrue
    }

    It 'Normalises watchlist result actions' {
        $rows = @(ConvertTo-WatchlistResultRows -Results @(
            [PSCustomObject]@{ Action = 'WouldBeCreated'; WatchlistAlias = 'vip'; DisplayName = 'VIP'; ItemCount = 3; Reason = $null }))
        $rows[0].Action | Should -Be 'Created'
        $rows[0].ItemCount | Should -Be 3
    }

    It 'Normalises content hub actions' {
        $rows = @(ConvertTo-ContentHubRows -ContentHubResults @{
            InstalledPackages = @([PSCustomObject]@{ Action = 'WouldBeInstalled'; PackageId = 'azuread'; DisplayName = 'Azure AD'; Reason = $null })
            FailedPackages    = @()
            AlreadyInstalled  = @()
        })
        $rows[0].Action | Should -Be 'Installed'
        $rows[0].PlannedOnly | Should -BeTrue
    }

    It 'Leaves executed verbs untouched' {
        $rows = @(ConvertTo-RuleResultRows -SourceRules @() -Results @(
            [PSCustomObject]@{ Action = 'Created'; RuleId = 'r1'; DisplayName = 'x'; Reason = $null }))
        $rows[0].Action | Should -Be 'Created'
        $rows[0].PlannedOnly | Should -BeFalse
    }
}

Describe 'ConvertTo-SummaryRows duration' {
    It 'Keeps days on a run longer than 24 hours' {
        # Was 'hh\:mm\:ss', which reported a 26-hour run as 02:00:00 while the
        # Markdown report - already fixed - said 1d 02:00:00.
        $start = Get-Date '2026-01-01 08:00:00'
        $rows = @(ConvertTo-SummaryRows -MigrationResults @{
            StartTime = $start; EndTime = $start.AddHours(26); DryRun = $true
        })
        ($rows | Where-Object { $_.Property -eq 'Duration' }).Value | Should -Be '1d 02:00:00'
    }

    It 'Renders a short run without a day component' {
        $start = Get-Date '2026-01-01 08:00:00'
        $rows = @(ConvertTo-SummaryRows -MigrationResults @{
            StartTime = $start; EndTime = $start.AddMinutes(90); DryRun = $true
        })
        ($rows | Where-Object { $_.Property -eq 'Duration' }).Value | Should -Be '01:30:00'
    }

    It 'Reports N/A when timings are missing' {
        $rows = @(ConvertTo-SummaryRows -MigrationResults @{ DryRun = $true })
        ($rows | Where-Object { $_.Property -eq 'Duration' }).Value | Should -Be 'N/A'
    }
}

Describe 'Export-MigrationWorkbook -NoAutoInstall' {
    # The orchestrator switch was honoured for powershell-yaml but ignored here,
    # so an operator who asked for no installs still got one.
    It 'Accepts the switch' {
        (Get-Command Export-MigrationWorkbook).Parameters.Keys | Should -Contain 'NoAutoInstall'
    }

    It 'Does not call Install-Module when the switch is set' {
        Mock Test-ExportModuleAvailable -ModuleName Sentinel.Export { $false }
        Mock Install-Module -ModuleName Sentinel.Export { }
        Mock Write-ExportLog -ModuleName Sentinel.Export { }

        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("smt-noai-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            $sheets = [ordered]@{ 'Summary' = @([PSCustomObject]@{ Property = 'Mode'; Value = 'DRY RUN' }) }
            Export-MigrationWorkbook -Sheets $sheets -OutputDir $dir -NoAutoInstall | Out-Null
            Should -Invoke Install-Module -ModuleName Sentinel.Export -Times 0 -Exactly
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Falls back to CSV when ImportExcel is absent and installs are blocked' {
        Mock Test-ExportModuleAvailable -ModuleName Sentinel.Export { $false }
        Mock Install-Module -ModuleName Sentinel.Export { }
        Mock Write-ExportLog -ModuleName Sentinel.Export { }

        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("smt-csv-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            $sheets = [ordered]@{ 'Summary' = @([PSCustomObject]@{ Property = 'Mode'; Value = 'DRY RUN' }) }
            Export-MigrationWorkbook -Sheets $sheets -OutputDir $dir -NoAutoInstall | Out-Null
            @(Get-ChildItem -Path $dir -Recurse -Filter *.csv).Count | Should -BeGreaterThan 0
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Still auto-installs when the switch is absent' {
        # Negative control: proves the two tests above are actually driven by the
        # switch rather than by the mocks being unreachable.
        Mock Test-ExportModuleAvailable -ModuleName Sentinel.Export { $false }
        Mock Install-Module -ModuleName Sentinel.Export { }
        Mock Write-ExportLog -ModuleName Sentinel.Export { }

        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("smt-ai-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            $sheets = [ordered]@{ 'Summary' = @([PSCustomObject]@{ Property = 'Mode'; Value = 'DRY RUN' }) }
            Export-MigrationWorkbook -Sheets $sheets -OutputDir $dir | Out-Null
            Should -Invoke Install-Module -ModuleName Sentinel.Export -Times 1 -Exactly
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
