BeforeAll {
    $script:SrcDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
    Import-Module (Join-Path $script:SrcDir 'Sentinel.Report.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:SrcDir 'Sentinel.Html.psm1')   -Force -DisableNameChecking

    # Minimal but realistic result set. Dry-run verbs are used deliberately: dry run
    # is the default mode, and every section below has to cope with the 'WouldBe'
    # prefix rather than the executed verb.
    function New-TestResults {
        param(
            [switch]$Execute,
            [object]$RuleClassification = $null
        )
        $p = if ($Execute) { '' } else { 'WouldBe' }
        return @{
            Config = @{
                Source = @{ SubscriptionId = 'sub-src'; ResourceGroupName = 'rg-dev';  WorkspaceName = 'ws-dev' }
                Target = @{ SubscriptionId = 'sub-tgt'; ResourceGroupName = 'rg-prod'; WorkspaceName = 'ws-prod' }
            }
            RuleClassification = $RuleClassification
            RuleResults = @(
                [PSCustomObject]@{ DisplayName = 'Rule Created';  RuleId = 'r1'; Action = "${p}Created";         Reason = '' }
                [PSCustomObject]@{ DisplayName = 'Rule Disabled'; RuleId = 'r2'; Action = "${p}CreatedDisabled"; Reason = 'Table AWSCloudTrail missing' }
                [PSCustomObject]@{ DisplayName = 'Rule Failed';   RuleId = 'r3'; Action = 'Failed';              Reason = 'Boom' }
            )
            WorkbookResults  = @([PSCustomObject]@{ DisplayName = 'WB'; WorkbookId = 'w1'; Action = "${p}Created"; Reason = '' })
            WatchlistResults = @([PSCustomObject]@{ DisplayName = 'WL'; WatchlistAlias = 'wl1'; Action = "${p}Created"; ItemCount = 5; Reason = '' })
            ContentHubResults = @{ InstalledPackages = @(); FailedPackages = @(); ManualChecklist = @() }
            Errors = @()
            WorkbooksDiscovered  = 4
            WatchlistsDiscovered = 2
            StartTime = (Get-Date).AddMinutes(-5)
            EndTime   = (Get-Date)
            DryRun    = (-not $Execute)
        }
    }

    # Every '|'-delimited line must belong to a table that has a separator row.
    function Test-MarkdownTablesWellFormed {
        param([string]$Markdown)
        $lines = $Markdown -split "\r?\n"
        $inTable = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $isRow = $line.TrimStart().StartsWith('|')
            if ($isRow -and -not $inTable) {
                # Start of a table: the very next line must be the separator.
                $next = if ($i + 1 -lt $lines.Count) { $lines[$i + 1] } else { '' }
                if ($next -notmatch '^\s*\|[\s\-:|]+\|\s*$') {
                    return "Table starting at line $($i + 1) has no separator row: '$line'"
                }
                $inTable = $true
            }
            elseif (-not $isRow) {
                $inTable = $false
            }
        }
        return $null
    }
}

Describe 'Format-ReportDuration' {
    It 'keeps days visible instead of wrapping at 24 hours' {
        # 'hh\:mm\:ss' renders 26 hours as 02:00:00, understating a long migration.
        Format-ReportDuration ([TimeSpan]::FromHours(26)) | Should -Match '^1d 02:00:00$'
    }

    It 'omits the day component for short runs' {
        Format-ReportDuration ([TimeSpan]::FromMinutes(90)) | Should -Be '01:30:00'
    }

    It 'does not throw on a non-TimeSpan value' {
        Format-ReportDuration 'not a timespan' | Should -Be 'N/A'
    }
}

Describe 'Format-ReportCell' {
    It 'escapes a pipe so it cannot create a phantom column' {
        Format-ReportCell 'Rule|Name' | Should -Be 'Rule\|Name'
    }

    It 'flattens newlines so they cannot terminate the row' {
        (Format-ReportCell "line one`nline two") | Should -Be 'line one line two'
    }

    It 'renders null as an empty cell' {
        Format-ReportCell $null | Should -Be ''
    }
}

Describe 'New-ReportTable' {
    It 'returns nothing when there are no rows so a header is never orphaned' {
        $empty = [System.Collections.Generic.List[object[]]]::new()
        New-ReportTable -Header @('A', 'B') -Row $empty | Should -BeNullOrEmpty
    }

    It 'emits a separator row immediately after the header' {
        $rows = [System.Collections.Generic.List[object[]]]::new()
        $rows.Add(@('x', 'y'))
        $table = New-ReportTable -Header @('A', 'B') -Row $rows
        $table | Should -Match '(?m)^\| A \| B \|\r?\n\|---\|---\|'
    }
}

Describe 'New-MigrationReport dry-run fidelity' {
    BeforeAll { $script:Md = New-MigrationReport -MigrationResults (New-TestResults) }

    It 'lists rules that would be created disabled' {
        # These rules need manual follow-up (connect the data source, then enable),
        # so dropping them from the default-mode report hides the real work.
        $script:Md | Should -Match 'Rules That Would Be Created as Disabled'
        $script:Md | Should -Match 'Rule Disabled'
    }

    It 'normalises action verbs so the report never shows raw WouldBe labels' {
        $script:Md | Should -Not -Match 'WouldBe'
    }

    It 'labels the outcome column as planned rather than completed' {
        $script:Md | Should -Match '\| Planned action \| Count \|'
    }

    It 'states plainly that nothing was changed' {
        $script:Md | Should -Match 'This was a preview'
    }

    It 'still finds failed rules, whose verb is never prefixed' {
        $script:Md | Should -Match '### Failed Rules'
    }

    It 'reports watchlist item counts' {
        $script:Md | Should -Match '### Watchlists with Items'
    }
}

Describe 'New-MigrationReport execute mode' {
    BeforeAll { $script:Md = New-MigrationReport -MigrationResults (New-TestResults -Execute) }

    It 'uses completed-tense headings' {
        $script:Md | Should -Match '### Rules Created as Disabled'
        $script:Md | Should -Match '\| Action \| Count \|'
    }

    It 'states that changes were applied' {
        $script:Md | Should -Match 'Changes were applied'
    }
}

Describe 'New-MigrationReport table integrity' {
    It 'produces well-formed tables when rule classification is absent' {
        # The discovery table used to emit workbook/watchlist rows with no header,
        # which renders as literal pipe characters.
        $md = New-MigrationReport -MigrationResults (New-TestResults)
        Test-MarkdownTablesWellFormed -Markdown $md | Should -BeNullOrEmpty
    }

    It 'produces well-formed tables when rule classification is present' {
        $rc = @{
            All                   = @(1, 2, 3)
            TemplateRulesEnabled  = @(1)
            TemplateRulesDisabled = @(2)
            CustomRulesEnabled    = @(3)
            CustomRulesDisabled   = @()
        }
        $md = New-MigrationReport -MigrationResults (New-TestResults -RuleClassification $rc)
        Test-MarkdownTablesWellFormed -Markdown $md | Should -BeNullOrEmpty
        $md | Should -Match '\| \*\*Total rules\*\* \| 3 \|'
    }

    It 'survives a rule name containing a pipe character' {
        $r = New-TestResults
        $r.RuleResults = @([PSCustomObject]@{ DisplayName = 'A|B'; RuleId = 'r1'; Action = 'Failed'; Reason = "multi`nline | text" })
        $md = New-MigrationReport -MigrationResults $r
        Test-MarkdownTablesWellFormed -Markdown $md | Should -BeNullOrEmpty
        $md | Should -Match 'A\\\|B'
    }
}

Describe 'New-MigrationReport discovery counts' {
    It 'reports discovered workbooks and watchlists even when nothing was migrated' {
        # Previously gated on the migration result arrays, so a discovery-only run
        # reported nothing about what it had found.
        $r = New-TestResults
        $r.WorkbookResults  = @()
        $r.WatchlistResults = @()
        $md = New-MigrationReport -MigrationResults $r
        $md | Should -Match '\| Workbooks discovered \| 4 \|'
        $md | Should -Match '\| Watchlists discovered \| 2 \|'
    }
}

Describe 'New-MigrationReport shared data sections' {
    It 'renders the KPI table supplied by the orchestrator' {
        $kpis = Get-MigrationKpis -MigrationResults (New-TestResults)
        $md = New-MigrationReport -MigrationResults (New-TestResults) -Kpis $kpis
        $md | Should -Match '## Migration Outcome'
        $md | Should -Match '\| Rules Disabled \| 1 \|'
    }

    It 'renders next steps supplied by the orchestrator' {
        $steps = @(Get-MigrationNextSteps -MigrationResults (New-TestResults))
        $md = New-MigrationReport -MigrationResults (New-TestResults) -NextSteps $steps
        $md | Should -Match '## Next Steps'
    }

    It 'lists rules whose target tables hold no data' {
        $coverage = @(
            [PSCustomObject]@{ RuleName = 'Gap Rule'; Status = 'NoData';      EmptyTableNames = 'AWSCloudTrail' }
            [PSCustomObject]@{ RuleName = 'Fine Rule'; Status = 'Ready';      EmptyTableNames = '' }
        )
        $md = New-MigrationReport -MigrationResults (New-TestResults) -TableCoverage $coverage
        $md | Should -Match '## Target Table Coverage'
        $md | Should -Match 'Gap Rule'
        $md | Should -Not -Match 'Fine Rule'
    }

    It 'omits the coverage section entirely when every table has data' {
        $coverage = @([PSCustomObject]@{ RuleName = 'Fine Rule'; Status = 'Ready'; EmptyTableNames = '' })
        $md = New-MigrationReport -MigrationResults (New-TestResults) -TableCoverage $coverage
        $md | Should -Not -Match '## Target Table Coverage'
    }
}

Describe 'Markdown and HTML agreement' {
    It 'reports the same disabled-rule count in both artifacts' {
        # The two renderers previously classified actions differently, so the same
        # run could produce a dashboard and a report that disagreed.
        $results = New-TestResults
        $kpis = Get-MigrationKpis -MigrationResults $results
        $md   = New-MigrationReport -MigrationResults $results -Kpis $kpis

        $kpis['Rules Disabled'] | Should -Be 1
        $md | Should -Match '\| Rules Disabled \| 1 \|'
        $md | Should -Match 'Rule Disabled'
    }
}

Describe 'New-MigrationReport section hygiene' {
    It 'omits the Content Hub heading when there is nothing to report' {
        # Content Hub runs on almost every migration, so testing "did it run" emitted a
        # heading with no body whenever nothing needed installing.
        $r = New-TestResults
        $md = New-MigrationReport -MigrationResults $r
        $md | Should -Not -Match '## Content Hub Solutions'
    }

    It 'includes the Content Hub heading when a solution was installed' {
        $r = New-TestResults
        $r.ContentHubResults.InstalledPackages = @(
            [PSCustomObject]@{ DisplayName = 'Azure Activity'; PackageId = 'p1'; Action = 'WouldBeInstalled' }
        )
        $md = New-MigrationReport -MigrationResults $r
        $md | Should -Match '## Content Hub Solutions'
        $md | Should -Match 'Azure Activity'
    }

    It 'includes the Content Hub heading when an install failed' {
        $r = New-TestResults
        $r.ContentHubResults.FailedPackages = @(
            [PSCustomObject]@{ DisplayName = 'Broken'; PackageId = 'p2'; Reason = 'nope' }
        )
        $md = New-MigrationReport -MigrationResults $r
        $md | Should -Match '## Content Hub Solutions'
        $md | Should -Match 'Failed Installations'
    }

    It 'never emits a heading with no content beneath it' {
        # Walks the whole document: any '##' heading immediately followed by another
        # heading (ignoring blank lines) is an empty section.
        $r = New-TestResults
        $md = New-MigrationReport -MigrationResults $r
        $lines = @($md -split "\r?\n")
        $empties = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -notmatch '^#{2,3} ') { continue }
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j].Trim() -eq '') { $j++ }
            if ($j -lt $lines.Count -and $lines[$j] -match '^#{2,3} ') {
                $empties += $lines[$i]
            }
        }
        $empties -join '; ' | Should -BeNullOrEmpty
    }
}

Describe 'Format-ReportInline' {
    It 'collapses newlines so a bullet does not break apart' {
        Format-ReportInline "line one`nline two" | Should -Be 'line one line two'
    }

    It 'collapses Windows line endings too' {
        Format-ReportInline "a`r`nb" | Should -Be 'a b'
    }

    It 'leaves pipes alone, since they are literal outside a table' {
        Format-ReportInline 'a | b' | Should -Be 'a | b'
    }

    It 'returns empty for null rather than the string null' {
        Format-ReportInline $null | Should -Be ''
    }
}

Describe 'New-MigrationReport error list' {
    It 'keeps a multi-line error message on one bullet' {
        $r = New-TestResults
        $r.Errors = @([PSCustomObject]@{ Component = 'Rules'; Message = "first`nsecond" })
        $md = New-MigrationReport -MigrationResults $r

        # The continuation must not land at column 0, which would end the list item.
        ($md -split "\r?\n") | Where-Object { $_ -eq 'second' } | Should -BeNullOrEmpty
        $md | Should -Match '\- \*\*Rules\*\*: first second'
    }

    It 'keeps a multi-line remediation on one bullet' {
        $r = New-TestResults
        $r.Errors = @([PSCustomObject]@{ Component = 'Rules'; Message = 'x'; Remediation = "do this`nthen that" })
        $md = New-MigrationReport -MigrationResults $r
        $md | Should -Match 'Remediation:\* do this then that'
    }
}
