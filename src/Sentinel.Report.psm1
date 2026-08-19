<#
.SYNOPSIS
    Report generation for Sentinel Migration Assistant.
.DESCRIPTION
    Produces structured JSON log lines and a final Markdown migration report.

    The Markdown report is the text-first companion to Migration-Summary.html and
    carries the same facts, so a run can be reviewed, diffed or pasted into a change
    record without opening a browser. Headline counts, next steps and table coverage
    are passed in by the orchestrator rather than recomputed here, so the two
    artifacts cannot disagree about what a run did.
#>

# Get-NormalizedAction and ConvertTo-SafeArray come from Common. Dry-run results
# carry 'WouldBe' verbs, and comparing against the executed verb silently empties
# whole sections of the report.
Import-Module (Join-Path $PSScriptRoot 'Sentinel.Common.psm1') -Force -DisableNameChecking

$script:LogEntries = [System.Collections.Generic.List[object]]::new()

# ── Structured Logging ────────────────────────────────────────────────────────
function Write-MigrationLog {
    <#
    .SYNOPSIS
        Writes a structured log entry (JSON line) and optional console output.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info','Warning','Error','Success','Debug')]
        [string]$Level = 'Info',
        [string]$Component,
        [hashtable]$Data
    )

    $entry = [ordered]@{
        timestamp = (Get-Date -Format 'o')
        level     = $Level
        message   = $Message
    }
    if ($Component) { $entry['component'] = $Component }
    if ($Data)      { $entry['data'] = $Data }

    $script:LogEntries.Add([PSCustomObject]$entry)

    # Console output
    $color = switch ($Level) {
        'Info'    { 'White' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
        'Debug'   { 'DarkGray' }
    }
    $prefix = "[$Level".ToUpper().PadRight(8) + "]"
    if ($Component) { $prefix += " [$Component]" }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Export-MigrationLog {
    <#
    .SYNOPSIS
        Writes all accumulated log entries to a JSON lines file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

    $lines = $script:LogEntries | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 }
    $lines | Set-Content -Path $Path -Encoding UTF8
    Write-Host "Log written to: $Path" -ForegroundColor Cyan
}

function Clear-MigrationLog {
    $script:LogEntries.Clear()
}

# ── Report Generation ─────────────────────────────────────────────────────────

function Format-ReportDuration {
    <#
    .SYNOPSIS
        Renders a TimeSpan without silently discarding days.
    .DESCRIPTION
        Thin wrapper over Format-MigrationDuration in Sentinel.Common, kept because
        the report tests and callers refer to it by this name. The implementation
        moved to Common so the console, dashboard and Excel export render the same
        duration; while it lived only here, those three still wrapped at 24 hours.
    #>
    param([object]$Span)
    return (Format-MigrationDuration -Span $Span)
}

function Format-ReportCell {
    <#
    .SYNOPSIS
        Makes an arbitrary value safe to place inside a Markdown table cell.
    .DESCRIPTION
        Two characters break a Markdown table: a newline ends the row, and a pipe
        starts a new column. API error text routinely contains both, which turned
        the Errors table into unreadable fragments.
    #>
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    $text = ([string]$Value) -replace '\r?\n', ' '
    $text = $text -replace '\|', '\|'
    return $text.Trim()
}

function Format-ReportInline {
    <#
    .SYNOPSIS
        Collapses a value onto a single line for use in a bullet or paragraph.
    .DESCRIPTION
        A raw newline inside a list item ends the item: the remainder lands at
        column 0 and renders as a separate paragraph, visually detached from the
        bullet it belongs to. ARM error messages are frequently multi-line, so the
        Errors list would break apart exactly when it mattered most.

        Unlike Format-ReportCell this does not escape pipes, because outside a table
        a pipe is an ordinary character.
    #>
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    return (([string]$Value) -replace '\r?\n', ' ').Trim()
}

function New-ReportTable {
    <#
    .SYNOPSIS
        Builds a Markdown table, or returns nothing when there are no rows.
    .DESCRIPTION
        Emitting a header with no rows below it, or rows with no header above them,
        both render as literal pipe characters. Routing every table through one
        builder means a table is either complete or absent.
    .PARAMETER Row
        Rows of pre-ordered cell values. A typed list is used deliberately: piping
        arrays-of-arrays through the usual array helpers flattens them into a single
        row of cells.
    #>
    param(
        [string[]]$Header,
        [System.Collections.Generic.List[object[]]]$Row
    )
    if ($null -eq $Row -or $Row.Count -eq 0) { return $null }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('| ' + (($Header | ForEach-Object { Format-ReportCell $_ }) -join ' | ') + ' |')
    [void]$sb.AppendLine('|' + (($Header | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($r in $Row) {
        [void]$sb.AppendLine('| ' + (($r | ForEach-Object { Format-ReportCell $_ }) -join ' | ') + ' |')
    }
    return $sb.ToString()
}

function New-MigrationReport {
    <#
    .SYNOPSIS
        Generates a Markdown migration report from collected results.
    .DESCRIPTION
        Text-first companion to the HTML dashboard, carrying the same facts so a run
        can be reviewed or attached to a change record without a browser.
    .PARAMETER MigrationResults
        Hashtable containing: Config, RuleClassification, RuleResults, WorkbookResults,
        WatchlistResults, ContentHubResults, Errors, StartTime, EndTime, DryRun.
    .PARAMETER Kpis
        Headline counts already computed for the dashboard. Passed in rather than
        recalculated so the two artifacts cannot report different numbers.
    .PARAMETER NextSteps
        Result-derived follow-up actions, shared with the dashboard.
    .PARAMETER TableCoverage
        Target-workspace table availability for the migrated rules.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$MigrationResults,
        [object]$Kpis,
        [object[]]$NextSteps,
        [object]$TableCoverage
    )

    $cfg        = $MigrationResults.Config
    $rules      = $MigrationResults.RuleClassification
    $ruleRes    = $MigrationResults.RuleResults
    $wbRes      = $MigrationResults.WorkbookResults
    $wlRes      = $MigrationResults.WatchlistResults
    $chRes      = $MigrationResults.ContentHubResults
    $errors     = $MigrationResults.Errors
    $startTime  = $MigrationResults.StartTime
    $endTime    = $MigrationResults.EndTime
    $dryRun     = $MigrationResults.DryRun

    $mode = if ($dryRun) { "DRY RUN (no changes made)" } else { "EXECUTE (changes applied)" }
    $duration = if ($startTime -and $endTime) { Format-ReportDuration ($endTime - $startTime) } else { 'N/A' }

    # Dry run reports what *would* happen, so every outcome column needs a verb that
    # says so. Naming the column once here keeps the whole report honest.
    $actionLabel = if ($dryRun) { 'Planned action' } else { 'Action' }

    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine("# Sentinel Migration Report")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("**Mode:** $mode")
    [void]$sb.AppendLine("**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    if ($startTime) { [void]$sb.AppendLine("**Started:** $(([datetime]$startTime).ToString('yyyy-MM-dd HH:mm:ss'))") }
    if ($endTime)   { [void]$sb.AppendLine("**Completed:** $(([datetime]$endTime).ToString('yyyy-MM-dd HH:mm:ss'))") }
    [void]$sb.AppendLine("**Duration:** $duration")
    [void]$sb.AppendLine("")
    if ($dryRun) {
        [void]$sb.AppendLine("> **This was a preview.** Nothing in the target workspace was created, updated or")
        [void]$sb.AppendLine("> deleted. Every outcome below describes what the tool *would* do. Re-run with")
        [void]$sb.AppendLine("> ``-Execute`` to apply these changes.")
    } else {
        [void]$sb.AppendLine("> **Changes were applied** to the target workspace.")
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Workspaces")
    [void]$sb.AppendLine("")
    $wsRows = [System.Collections.Generic.List[object[]]]::new()
    $wsRows.Add(@('**Source**', $cfg.Source.SubscriptionId, $cfg.Source.ResourceGroupName, $cfg.Source.WorkspaceName))
    $wsRows.Add(@('**Target**', $cfg.Target.SubscriptionId, $cfg.Target.ResourceGroupName, $cfg.Target.WorkspaceName))
    [void]$sb.AppendLine((New-ReportTable -Header @('', 'Subscription', 'Resource Group', 'Workspace') -Row $wsRows))

    # ── Source Discovery Summary ──
    # Counts are gated on the counts themselves, not on whether a later migration
    # phase produced results - a phase that discovered items but migrated none still
    # needs to report what it found.
    [void]$sb.AppendLine("## Source Discovery")
    [void]$sb.AppendLine("")
    $discRows = [System.Collections.Generic.List[object[]]]::new()
    if ($rules) {
        $discRows.Add(@('Template-based rules (enabled)',  $rules.TemplateRulesEnabled.Count))
        $discRows.Add(@('Template-based rules (disabled)', $rules.TemplateRulesDisabled.Count))
        $discRows.Add(@('Custom rules (enabled)',          $rules.CustomRulesEnabled.Count))
        $discRows.Add(@('Custom rules (disabled)',         $rules.CustomRulesDisabled.Count))
        $discRows.Add(@('**Total rules**',                 $rules.All.Count))
    }
    $discRows.Add(@('Workbooks discovered',  [int]$MigrationResults.WorkbooksDiscovered))
    $discRows.Add(@('Watchlists discovered', [int]$MigrationResults.WatchlistsDiscovered))
    [void]$sb.AppendLine((New-ReportTable -Header @('Category', 'Count') -Row $discRows))

    # ── Migration Outcome ──
    # Headline counts come from the orchestrator so this report and the dashboard
    # are guaranteed to agree.
    if ($Kpis) {
        [void]$sb.AppendLine("## Migration Outcome")
        [void]$sb.AppendLine("")
        $kpiRows = [System.Collections.Generic.List[object[]]]::new()
        foreach ($k in $Kpis.GetEnumerator()) {
            $kpiRows.Add(@($k.Key, $k.Value))
        }
        [void]$sb.AppendLine((New-ReportTable -Header @('Measure', 'Count') -Row $kpiRows))
    }

    # ── Next Steps ──
    if ($NextSteps -and @($NextSteps).Count -gt 0) {
        [void]$sb.AppendLine("## Next Steps")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Derived from this run's results and listed in the order they should be tackled.")
        [void]$sb.AppendLine("")
        foreach ($s in @(ConvertTo-SafeArray $NextSteps)) {
            $countSuffix = if ($s.Count -and [int]$s.Count -gt 0) { " ($($s.Count))" } else { '' }
            [void]$sb.AppendLine("$($s.Order). **$($s.Title)$countSuffix**")
            $detail = (([string]$s.Detail) -replace '\s*\r?\n\s*', ' ').Trim()
            if ($detail) {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("   $detail")
            }
            [void]$sb.AppendLine("")
        }
    }

    # ── Content Hub ──
    # The heading is written only once we know a subsection will follow it. Testing
    # '$chRes' alone emitted 'Content Hub Solutions' with nothing underneath whenever
    # Content Hub ran but had nothing to install - a heading that promises content and
    # delivers none, which reads like a truncated report.
    $chInstalled = if ($chRes) { @(ConvertTo-SafeArray $chRes.InstalledPackages) } else { @() }
    $chFailed    = if ($chRes) { @(ConvertTo-SafeArray $chRes.FailedPackages) } else { @() }
    if ($chInstalled.Count -gt 0 -or $chFailed.Count -gt 0) {
        [void]$sb.AppendLine("## Content Hub Solutions")
        [void]$sb.AppendLine("")
        if ($chInstalled.Count -gt 0) {
            [void]$sb.AppendLine("### Auto-Installed")
            [void]$sb.AppendLine("")
            $chRows = [System.Collections.Generic.List[object[]]]::new()
            foreach ($pkg in $chInstalled) {
                $chRows.Add(@($pkg.DisplayName, $pkg.PackageId, (Get-NormalizedAction $pkg.Action)))
            }
            [void]$sb.AppendLine((New-ReportTable -Header @('Solution', 'Package ID', 'Status') -Row $chRows))
        }
        if ($chFailed.Count -gt 0) {
            [void]$sb.AppendLine("### Failed Installations")
            [void]$sb.AppendLine("")
            $chFailRows = [System.Collections.Generic.List[object[]]]::new()
            foreach ($pkg in $chFailed) {
                $chFailRows.Add(@($pkg.DisplayName, $pkg.PackageId, $pkg.Reason))
            }
            [void]$sb.AppendLine((New-ReportTable -Header @('Solution', 'Package ID', 'Error') -Row $chFailRows))
        }
    }

    # ── Analytics Rules Migration ──
    if ($ruleRes -and @($ruleRes).Count -gt 0) {
        [void]$sb.AppendLine("## Analytics Rules Migration")
        [void]$sb.AppendLine("")
        # Group on the normalized verb so dry-run and execute runs produce the same
        # vocabulary, and so the sections below actually find their rows.
        $grouped = $ruleRes | Group-Object -Property { Get-NormalizedAction $_.Action }
        $actionRows = [System.Collections.Generic.List[object[]]]::new()
        foreach ($g in $grouped) {
            $actionRows.Add(@($g.Name, $g.Count))
        }
        [void]$sb.AppendLine((New-ReportTable -Header @($actionLabel, 'Count') -Row $actionRows))

        # Detail failed rules
        $failed = @($ruleRes | Where-Object { (Get-NormalizedAction $_.Action) -eq 'Failed' })
        if ($failed.Count -gt 0) {
            [void]$sb.AppendLine("### Failed Rules")
            [void]$sb.AppendLine("")
            $failRows = [System.Collections.Generic.List[object[]]]::new()
            foreach ($f in $failed) {
                $failRows.Add(@($f.DisplayName, $f.RuleId, $f.Reason))
            }
            [void]$sb.AppendLine((New-ReportTable -Header @('Rule', 'ID', 'Error') -Row $failRows))
        }

        # Detail rules created as disabled (missing tables)
        $createdDisabled = @($ruleRes | Where-Object { (Get-NormalizedAction $_.Action) -eq 'CreatedDisabled' })
        if ($createdDisabled.Count -gt 0) {
            $heading = if ($dryRun) { '### Rules That Would Be Created as Disabled' } else { '### Rules Created as Disabled' }
            [void]$sb.AppendLine($heading)
            [void]$sb.AppendLine("")
            $verb = if ($dryRun) { 'would be created disabled' } else { 'were created disabled' }
            [void]$sb.AppendLine("These rules $verb because required tables are missing in the target workspace.")
            [void]$sb.AppendLine("Connect the required data sources, then enable each rule.")
            [void]$sb.AppendLine("")
            $cdRows = [System.Collections.Generic.List[object[]]]::new()
            foreach ($r in $createdDisabled) {
                $cdRows.Add(@($r.DisplayName, $r.RuleId, $r.Reason))
            }
            [void]$sb.AppendLine((New-ReportTable -Header @('Rule', 'ID', 'Reason') -Row $cdRows))
        }
    }

    # ── Workbooks Migration ──
    if ($wbRes -and @($wbRes).Count -gt 0) {
        [void]$sb.AppendLine("## Workbooks Migration")
        [void]$sb.AppendLine("")
        $grouped = $wbRes | Group-Object -Property { Get-NormalizedAction $_.Action }
        $wbActionRows = [System.Collections.Generic.List[object[]]]::new()
        foreach ($g in $grouped) {
            $wbActionRows.Add(@($g.Name, $g.Count))
        }
        [void]$sb.AppendLine((New-ReportTable -Header @($actionLabel, 'Count') -Row $wbActionRows))

        $failed = @($wbRes | Where-Object { (Get-NormalizedAction $_.Action) -eq 'Failed' })
        if ($failed.Count -gt 0) {
            [void]$sb.AppendLine("### Failed Workbooks")
            [void]$sb.AppendLine("")
            $wbFailRows = [System.Collections.Generic.List[object[]]]::new()
            foreach ($f in $failed) {
                $wbFailRows.Add(@($f.DisplayName, $f.WorkbookId, $f.Reason))
            }
            [void]$sb.AppendLine((New-ReportTable -Header @('Workbook', 'ID', 'Error') -Row $wbFailRows))
        }
    }

    # ── Watchlists Migration ──
    if ($wlRes -and @($wlRes).Count -gt 0) {
        [void]$sb.AppendLine("## Watchlists Migration")
        [void]$sb.AppendLine("")
        $grouped = $wlRes | Group-Object -Property { Get-NormalizedAction $_.Action }
        $wlActionRows = [System.Collections.Generic.List[object[]]]::new()
        foreach ($g in $grouped) {
            $wlActionRows.Add(@($g.Name, $g.Count))
        }
        [void]$sb.AppendLine((New-ReportTable -Header @($actionLabel, 'Count') -Row $wlActionRows))

        # Detail successful with item counts
        $created = @($wlRes | Where-Object {
            (Get-NormalizedAction $_.Action) -match '^(Created|Updated)' -and [int]$_.ItemCount -gt 0
        })
        if ($created.Count -gt 0) {
            [void]$sb.AppendLine("### Watchlists with Items")
            [void]$sb.AppendLine("")
            $wlItemRows = [System.Collections.Generic.List[object[]]]::new()
            foreach ($w in $created) {
                $wlItemRows.Add(@($w.DisplayName, $w.WatchlistAlias, $w.ItemCount))
            }
            [void]$sb.AppendLine((New-ReportTable -Header @('Watchlist', 'Alias', 'Items') -Row $wlItemRows))
        }

        $failed = @($wlRes | Where-Object { (Get-NormalizedAction $_.Action) -eq 'Failed' })
        if ($failed.Count -gt 0) {
            [void]$sb.AppendLine("### Failed Watchlists")
            [void]$sb.AppendLine("")
            $wlFailRows = [System.Collections.Generic.List[object[]]]::new()
            foreach ($f in $failed) {
                $wlFailRows.Add(@($f.DisplayName, $f.WatchlistAlias, $f.Reason))
            }
            [void]$sb.AppendLine((New-ReportTable -Header @('Watchlist', 'Alias', 'Error') -Row $wlFailRows))
        }
    }

    # ── Target Table Coverage ──
    # Shared with the dashboard so both artifacts name the same gaps. Only rules with
    # a genuine gap are listed; a fully-ready workspace produces no section at all.
    if ($TableCoverage) {
        $coverage = @(ConvertTo-SafeArray $TableCoverage)
        $gaps = @($coverage | Where-Object { $_.Status -in @('NoData', 'PartialData') })
        if ($gaps.Count -gt 0) {
            [void]$sb.AppendLine("## Target Table Coverage")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("These rules reference tables that hold no data in the target workspace. They")
            [void]$sb.AppendLine("will not produce results until the matching data sources are connected.")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("- **No data at all:** $(@($coverage | Where-Object { $_.Status -eq 'NoData' }).Count) rule(s)")
            [void]$sb.AppendLine("- **Partial data:** $(@($coverage | Where-Object { $_.Status -eq 'PartialData' }).Count) rule(s)")
            [void]$sb.AppendLine("")
            $tcRows = [System.Collections.Generic.List[object[]]]::new()
            foreach ($t in $gaps) {
                $tcRows.Add(@($t.RuleName, $t.Status, $t.EmptyTableNames))
            }
            [void]$sb.AppendLine((New-ReportTable -Header @('Rule', 'Status', 'Tables with no data') -Row $tcRows))
        }
    }

    # ── Solutions that need a decision rather than a re-run ──
    if ($chRes) {
        $notInCat = @(ConvertTo-SafeArray $chRes.NotInCatalog)
        if ($notInCat.Count -gt 0) {
            [void]$sb.AppendLine("## Solutions Unavailable in the Target Catalog")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("These are installed in the source workspace but the target's Content Hub does not offer them.")
            [void]$sb.AppendLine("Re-running will not resolve this - find the equivalent solution in the target, or recreate the content by hand.")
            [void]$sb.AppendLine("")
            $rows = [System.Collections.Generic.List[object[]]]::new()
            foreach ($s in $notInCat) { $rows.Add(@($s.DisplayName, $s.PackageId, $s.SourceVersion)) }
            [void]$sb.AppendLine((New-ReportTable -Header @('Solution', 'Package ID', 'Source version') -Row $rows))
            [void]$sb.AppendLine("")
        }

        $chSkipped = @(ConvertTo-SafeArray $chRes.SkippedPackages)
        if ($chSkipped.Count -gt 0) {
            [void]$sb.AppendLine("## Out-of-Date Solutions Left Unchanged")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("The target has these at an older version than the source. Re-run with ``-OverwriteExisting`` to upgrade them.")
            [void]$sb.AppendLine("")
            $rows = [System.Collections.Generic.List[object[]]]::new()
            foreach ($s in $chSkipped) { $rows.Add(@($s.DisplayName, $s.TargetVersion, $s.SourceVersion)) }
            [void]$sb.AppendLine((New-ReportTable -Header @('Solution', 'Target version', 'Source version') -Row $rows))
            [void]$sb.AppendLine("")
        }

        $chPending = @(ConvertTo-SafeArray $chRes.PendingPackages)
        if ($chPending.Count -gt 0) {
            [void]$sb.AppendLine("## Solutions Still Deploying")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("Content Hub accepted these installs but their content had not finished deploying when the run ended.")
            [void]$sb.AppendLine("Re-run the migration to create any rules that depend on them.")
            [void]$sb.AppendLine("")
            $rows = [System.Collections.Generic.List[object[]]]::new()
            foreach ($s in $chPending) { $rows.Add(@($s.DisplayName, $s.PackageId, $s.Version)) }
            [void]$sb.AppendLine((New-ReportTable -Header @('Solution', 'Package ID', 'Version') -Row $rows))
            [void]$sb.AppendLine("")
        }
    }

    # ── Rules whose Content Hub solution could not be identified ──
    if ($chRes -and @(ConvertTo-SafeArray $chRes.ManualChecklist).Count -gt 0) {
        [void]$sb.AppendLine("## Rules Needing a Content Hub Solution")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("The tool could not determine which Content Hub solution ships these rules,")
        [void]$sb.AppendLine("so it could not install one on their behalf. Find and install each solution")
        [void]$sb.AppendLine("manually before enabling the associated template-based rules.")
        [void]$sb.AppendLine("")

        $i = 0
        foreach ($item in @(ConvertTo-SafeArray $chRes.ManualChecklist)) {
            $i++
            [void]$sb.AppendLine("### $i. $($item.RuleDisplayName)")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("- **Alert Rule Template ID:** ``$($item.AlertRuleTemplateName)``")
            [void]$sb.AppendLine("- **Solution:** $($item.SolutionName)")
            [void]$sb.AppendLine("- **Severity:** $($item.Severity)")
            if ($item.Tactics) { [void]$sb.AppendLine("- **Tactics:** $($item.Tactics)") }
            [void]$sb.AppendLine("- **Enabled in source:** $($item.IsEnabled)")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**Steps:**")
            [void]$sb.AppendLine("")
            foreach ($step in @(ConvertTo-SafeArray $item.ManualSteps)) {
                [void]$sb.AppendLine($step)
            }
            [void]$sb.AppendLine("")
        }
    }

    # ── Errors & Remediation ──
    if ($errors -and @($errors).Count -gt 0) {
        [void]$sb.AppendLine("## Errors & Remediation")
        [void]$sb.AppendLine("")
        foreach ($err in @(ConvertTo-SafeArray $errors)) {
            [void]$sb.AppendLine("- **$(Format-ReportInline $err.Component)**: $(Format-ReportInline $err.Message)")
            if ($err.Remediation) { [void]$sb.AppendLine("  - *Remediation:* $(Format-ReportInline $err.Remediation)") }
        }
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("*Generated by Sentinel Migration Assistant*")

    return $sb.ToString()
}

function Save-MigrationReport {
    <#
    .SYNOPSIS
        Saves the Markdown report to disk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Report,
        [Parameter(Mandatory)][string]$Path
    )

    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

    $Report | Set-Content -Path $Path -Encoding UTF8
    Write-Host "Report saved to: $Path" -ForegroundColor Green
}

Export-ModuleMember -Function @(
    'Write-MigrationLog'
    'Export-MigrationLog'
    'Clear-MigrationLog'
    'Format-ReportCell'
    'Format-ReportDuration'
    'Format-ReportInline'
    'New-MigrationReport'
    'New-ReportTable'
    'Save-MigrationReport'
)
