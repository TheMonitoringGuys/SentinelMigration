<#
.SYNOPSIS
    Migration summary HTML dashboard for the Sentinel Migration Assistant.
.DESCRIPTION
    Produces a single self-contained HTML file (no external/CDN dependencies) with
    KPI cards, lightweight inline CSS bar charts, and searchable/sortable drill-down
    tables. Safe to open offline in a SOC.
#>

# Get-NormalizedAction lives in Common so the Markdown report and this dashboard
# classify outcomes identically. Keeping a private copy here is what let the two
# drift apart in the first place.
Import-Module (Join-Path $PSScriptRoot 'Sentinel.Common.psm1') -Force -DisableNameChecking

function Write-HtmlLog {
    <#
    .SYNOPSIS
        Logs through Write-MigrationLog when Sentinel.Report is loaded, else Write-Host.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Debug')]
        [string]$Level = 'Info',
        [string]$Component = 'Export'
    )
    if (Get-Command -Name 'Write-MigrationLog' -ErrorAction SilentlyContinue) {
        Write-MigrationLog -Message $Message -Level $Level -Component $Component
    }
    else {
        Write-Host "[$Level] [$Component] $Message"
    }
}

function ConvertTo-HtmlEncoded {
    param([object]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function ConvertTo-Slug {
    param([string]$Text)
    $s = ([string]$Text).ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    return "sec-$($s.Trim('-'))"
}

function New-KpiCard {
    <#
    .SYNOPSIS
        Renders one KPI card, optionally deep-linking into a detail section.
    .PARAMETER Tone
        Visual emphasis: 'default', 'good', 'warn' or 'bad'.
    #>
    param(
        [string]$Label,
        [object]$Value,
        [string]$Sub = '',
        [string]$Anchor = '',
        [ValidateSet('default', 'good', 'warn', 'bad')]
        [string]$Tone = 'default'
    )
    $subHtml = if ($Sub) { "<div class='kpi-sub'>$(ConvertTo-HtmlEncoded $Sub)</div>" } else { '' }
    $toneCls = if ($Tone -ne 'default') { " tone-$Tone" } else { '' }
    $inner = @"
  <div class="kpi-value">$(ConvertTo-HtmlEncoded $Value)</div>
  <div class="kpi-label">$(ConvertTo-HtmlEncoded $Label)</div>
  $subHtml
"@
    if ($Anchor) {
        return "<a class=""kpi kpi-link$toneCls"" href=""#$Anchor"">$inner</a>"
    }
    return "<div class=""kpi$toneCls"">$inner</div>"
}

function ConvertTo-ChartValue {
    <#
    .SYNOPSIS
        Coerces a chart value to a number so a non-numeric cell cannot abort the report.
    #>
    param([object]$Value)
    if ($null -eq $Value) { return 0.0 }
    $result = 0.0
    if ([double]::TryParse([string]$Value, [ref]$result)) { return $result }
    return 0.0
}

function New-BarChart {
    <#
    .SYNOPSIS
        Renders a horizontal bar chart from label/value pairs using inline CSS.
    .PARAMETER Pairs
        Array of [PSCustomObject]@{ Label=..; Value=.. }.
    #>
    param(
        [string]$Title,
        [object[]]$Pairs,
        [string]$Color = '#2563eb'
    )
    $pairs = @($Pairs)
    if ($pairs.Count -eq 0) {
        return "<div class='chart'><h3>$(ConvertTo-HtmlEncoded $Title)</h3><p class='muted'>No data available.</p></div>"
    }
    $max = 0.0
    foreach ($p in $pairs) {
        $n = ConvertTo-ChartValue $p.Value
        if ($n -gt $max) { $max = $n }
    }
    if ($max -le 0) { $max = 1 }

    $rows = foreach ($p in $pairs) {
        $pct = [math]::Round(((ConvertTo-ChartValue $p.Value) / $max) * 100, 1)
        @"
<div class="bar-row">
  <div class="bar-label" title="$(ConvertTo-HtmlEncoded $p.Label)">$(ConvertTo-HtmlEncoded $p.Label)</div>
  <div class="bar-track"><div class="bar-fill" style="width:$pct%;background:$Color"></div></div>
  <div class="bar-value">$(ConvertTo-HtmlEncoded $p.Value)</div>
</div>
"@
    }
    return "<div class='chart'><h3>$(ConvertTo-HtmlEncoded $Title)</h3>$($rows -join "`n")</div>"
}

function New-DetailTable {
    <#
    .SYNOPSIS
        Renders a collapsible, searchable, sortable HTML table for one result set.
    .PARAMETER Rows
        Array of flat PSCustomObjects (the same shapes written to the Excel workbook).
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [object[]]$Rows
    )
    $rows = @($Rows)
    $id   = ConvertTo-Slug $Title
    $tid  = "$id-tbl"
    $count = $rows.Count

    if ($count -eq 0) {
        return @"
<details id="$id" class="detail">
  <summary>$(ConvertTo-HtmlEncoded $Title) <span class="count">0</span></summary>
  <p class="muted">No items collected.</p>
</details>
"@
    }

    $columns = @($rows[0].PSObject.Properties.Name)
    $headCells = for ($i = 0; $i -lt $columns.Count; $i++) {
        "<th onclick=""sortTable('$tid',$i,this)"">$(ConvertTo-HtmlEncoded $columns[$i])<span class=""sort-ind""></span></th>"
    }
    $bodyRows = foreach ($r in $rows) {
        $cls = switch ([string]$r.Action) {
            'Failed'  { ' class="row-bad"' }
            'Skipped' { ' class="row-warn"' }
            default   { '' }
        }
        $cells = foreach ($c in $columns) {
            "<td>$(ConvertTo-HtmlEncoded $r.$c)</td>"
        }
        "<tr$cls>$($cells -join '')</tr>"
    }

    return @"
<details id="$id" class="detail">
  <summary>$(ConvertTo-HtmlEncoded $Title) <span class="count">$count</span></summary>
  <input class="tbl-search" type="search" placeholder="Filter $(ConvertTo-HtmlEncoded $Title)…" oninput="filterTable('$tid',this.value)">
  <div class="tbl-wrap">
  <table id="$tid" class="detail-table">
    <thead><tr>$($headCells -join '')</tr></thead>
    <tbody>
$($bodyRows -join "`n")
    </tbody>
  </table>
  </div>
</details>
"@
}

function Get-ActionBreakdown {
    <#
    .SYNOPSIS
        Groups result rows by their Action value into chart-ready label/value pairs.
    .DESCRIPTION
        Actions are normalised first. In dry run the migration modules emit
        'WouldBeCreated' / 'WouldBeCreatedDisabled', so grouping on the raw value
        made the Breakdowns chart read 'WouldBeCreatedDisabled' while the KPI cards
        directly above it read 'Rules Disabled' - two labels for one number, in one
        document. Normalising here keeps every part of the dashboard on the same
        vocabulary and merges verbs that differ only by the dry-run prefix.
    #>
    param([object[]]$Results)
    $rows = @(ConvertTo-ItemList $Results)
    if ($rows.Count -eq 0) { return @() }
    return $rows |
        Group-Object -Property { Get-NormalizedAction $_.Action } |
        Sort-Object Count -Descending |
        ForEach-Object {
            [PSCustomObject]@{ Label = $_.Name; Value = $_.Count }
        }
}

function Get-MigrationKpis {
    <#
    .SYNOPSIS
        Derives the headline KPI set from a migration results hashtable.
    .DESCRIPTION
        Actions are normalized first so dry-run runs report the same numbers an
        execute run would, and 'CreatedDisabled' is counted separately rather than
        folded into 'Created' because those rules still need a manual follow-up.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$MigrationResults)

    $ruleRes = @(ConvertTo-ItemList $MigrationResults.RuleResults)
    $wbRes   = @(ConvertTo-ItemList $MigrationResults.WorkbookResults)
    $wlRes   = @(ConvertTo-ItemList $MigrationResults.WatchlistResults)
    $ch      = $MigrationResults.ContentHubResults

    $countBy = {
        param($set, $pattern)
        @($set | Where-Object { (Get-NormalizedAction $_.Action) -match $pattern }).Count
    }

    # 'Created' must not swallow 'CreatedDisabled' - the two need different follow-up.
    return [ordered]@{
        'Rules Created'      = & $countBy $ruleRes '^Created$'
        'Rules Updated'      = & $countBy $ruleRes '^Updated$'
        'Rules Disabled'     = & $countBy $ruleRes '^CreatedDisabled$'
        'Rules Skipped'      = & $countBy $ruleRes '^Skipped'
        'Rules Failed'       = & $countBy $ruleRes '^Failed'
        'Workbooks Migrated' = & $countBy $wbRes   '^(Created|Updated)'
        'Workbooks Failed'   = & $countBy $wbRes   '^Failed'
        'Watchlists Migrated'= & $countBy $wlRes   '^(Created|Updated)'
        'Watchlists Failed'  = & $countBy $wlRes   '^Failed'
        'Solutions Installed'= @(ConvertTo-ItemList $ch.InstalledPackages).Count
        'Solutions Upgraded' = @(ConvertTo-ItemList $ch.UpgradedPackages).Count
        'Manual Checklist'   = @(ConvertTo-ItemList $ch.ManualChecklist).Count
        'Errors'             = @(ConvertTo-ItemList $MigrationResults.Errors).Count
    }
}

function Get-MigrationNextSteps {
    <#
    .SYNOPSIS
        Derives a prioritised, results-driven action list for completing the migration.
    .DESCRIPTION
        Everything returned here is inferred from what actually happened in the run,
        so a clean migration produces a short list and a messy one produces a long
        one. Boilerplate advice that applies regardless of outcome is deliberately
        kept to the final verification block.

        Returns step objects with Order, Tone, Title, Detail, Count and Anchor.
        Presentation-neutral by design, so the renderer decides how to show them.
    .PARAMETER MigrationResults
        The migration results hashtable built by the orchestrator.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$MigrationResults)

    $ruleRes = @(ConvertTo-ItemList $MigrationResults.RuleResults)
    $wbRes   = @(ConvertTo-ItemList $MigrationResults.WorkbookResults)
    $wlRes   = @(ConvertTo-ItemList $MigrationResults.WatchlistResults)
    $ch      = $MigrationResults.ContentHubResults
    $errors  = @(ConvertTo-ItemList $MigrationResults.Errors)
    $isDry   = [bool]$MigrationResults.DryRun

    $match = {
        param($set, $pattern)
        @($set | Where-Object { (Get-NormalizedAction $_.Action) -match $pattern })
    }

    $steps = [System.Collections.Generic.List[object]]::new()
    # Order comes from the list itself: $steps is shared by reference, whereas a
    # counter variable would be copied into the scriptblock's child scope and the
    # increment would never reach this scope.
    $add = {
        param($Tone, $Title, $Detail, $Count, $Anchor)
        $steps.Add([PSCustomObject]@{
            Order  = $steps.Count + 1
            Tone   = $Tone
            Title  = $Title
            Detail = $Detail
            Count  = $Count
            Anchor = $Anchor
        })
    }

    # ── Dry run: nothing was applied, so this dominates everything else ──
    if ($isDry) {
        & $add 'warn' 'Re-run with -Execute to apply these changes' @'
This was a dry run: nothing in the target workspace was created, updated or
installed. The counts above are what would happen. Review them, work through any
manual items below, then re-run the same command with -Execute instead of -DryRun.
'@ 0 ''
    }

    # ── Rules whose solution could not be identified ──
    $manual = @(ConvertTo-ItemList $ch.ManualChecklist)
    if ($manual.Count -gt 0) {
        & $add 'warn' 'Identify Content Hub solutions for these rules' @'
The tool could not work out which Content Hub solution ships these rules, so it could
not install anything on their behalf. That usually means the solution was not installed
in the source workspace either. Find each one in the target workspace's Content Hub,
install it, then re-run the migration to pick up the dependent rules. Full per-rule
steps are listed below.
'@ $manual.Count 'sec-manual-steps'
    }

    # ── Failed Content Hub installs ──
    $chFailed = @(ConvertTo-ItemList $ch.FailedPackages)
    if ($chFailed.Count -gt 0) {
        & $add 'bad' 'Retry failed Content Hub installations' @'
One or more solution installs returned an error. Check the Content Hub section for
the failure reason - the most common causes are insufficient permissions on the
target resource group and a solution that is unavailable in the target cloud.
'@ $chFailed.Count 'sec-content-hub'
    }

    # ── Solutions the target's catalog does not offer ──
    # This is the one Content Hub state a re-run will never resolve, so it needs to
    # say plainly that the operator has to find another route.
    $notInCatalog = @(ConvertTo-ItemList $ch.NotInCatalog)
    if ($notInCatalog.Count -gt 0) {
        & $add 'bad' 'Source solutions unavailable in the target catalog' @'
These solutions are installed in the source workspace but are not offered by the
target workspace's Content Hub. Re-running will not change this. The usual causes
are a Commercial-only solution in a Gov target and a solution that has since been
withdrawn. Find the current equivalent in the target's Content Hub, or recreate the
content the solution provided by hand.
'@ $notInCatalog.Count 'sec-content-hub'
    }

    # ── Solutions still deploying when the run ended ──
    $pending = @(ConvertTo-ItemList $ch.PendingPackages)
    if ($pending.Count -gt 0) {
        & $add 'warn' 'Re-run to pick up rules from solutions that were still deploying' @'
These solutions were accepted by Content Hub but had not finished deploying their
content when the migration moved on. Any template-based rule depending on them was
skipped. Nothing is wrong - simply re-run the same command once deployment finishes
and the dependent rules will be created.
'@ $pending.Count 'sec-content-hub'
    }

    # ── Out-of-date solutions left alone ──
    $chSkipped = @(ConvertTo-ItemList $ch.SkippedPackages)
    if ($chSkipped.Count -gt 0) {
        & $add 'warn' 'Upgrade out-of-date solutions with -OverwriteExisting' @'
The target already has these solutions but at an older version than the source. They
were left untouched, because upgrading an existing solution is a change to content
the target workspace already relies on. Re-run with -OverwriteExisting to bring them
up to the source's version.
'@ $chSkipped.Count 'sec-content-hub'
    }

    # ── Rules created disabled (missing tables) ──
    $disabled = & $match $ruleRes '^CreatedDisabled$'
    if ($disabled.Count -gt 0) {
        & $add 'warn' 'Connect data sources, then enable the disabled rules' @'
These rules query tables that do not yet exist in the target workspace, so they were
created in a disabled state - Sentinel rejects an enabled rule whose query cannot be
validated. Connect the underlying data sources first, then enable each rule in
Analytics. Enabling before the table exists will fail again.
'@ $disabled.Count 'sec-analytics-rules'
    }

    # ── Failures by component ──
    $ruleFailed = & $match $ruleRes '^Failed'
    if ($ruleFailed.Count -gt 0) {
        & $add 'bad' 'Resolve failed analytics rules' @'
Each failure carries its ARM error message in the Analytics Rules table and the
Errors section. Known causes that need a manual decision: Fusion rules are singleton
per workspace and cannot be duplicated, and a rule with more than five entity
mappings exceeds the API limit and must be reduced in the source first.
'@ $ruleFailed.Count 'sec-analytics-rules'
    }

    $wbFailed = & $match $wbRes '^Failed'
    if ($wbFailed.Count -gt 0) {
        & $add 'bad' 'Resolve failed workbooks' @'
Workbook failures are usually a permissions problem on the target resource group, or
a workbook whose serialised content references a resource that does not exist in the
target subscription.
'@ $wbFailed.Count 'sec-workbooks'
    }

    $wlFailed = & $match $wlRes '^Failed'
    if ($wlFailed.Count -gt 0) {
        & $add 'bad' 'Resolve failed watchlists' @'
Check the watchlist alias and the items search key in the Watchlists table. A
watchlist whose items failed to upload will exist but be empty, which silently
weakens any rule that joins against it.
'@ $wlFailed.Count 'sec-watchlists'
    }

    # ── Skipped items ──
    $skipped = @(& $match $ruleRes '^Skipped') + @(& $match $wbRes '^Skipped') + @(& $match $wlRes '^Skipped')
    if ($skipped.Count -gt 0) {
        & $add 'warn' 'Review skipped items' @'
These already existed in the target and were left untouched. That is the safe
default, but it also means the target copy may be older than the source. Re-run with
overwrite enabled if the source version should win.
'@ $skipped.Count ''
    }

    # ── Watchlists carrying items ──
    $withItems = @($wlRes | Where-Object {
        (Get-NormalizedAction $_.Action) -match '^(Created|Updated)' -and [int]$_.ItemCount -gt 0
    })
    if ($withItems.Count -gt 0) {
        & $add 'info' 'Verify watchlist item counts in the target' @'
Watchlist items are uploaded separately from the watchlist itself. Confirm the item
counts in the target match the source before relying on any rule that joins against
them - a partial upload produces no error but changes rule behaviour.
'@ $withItems.Count 'sec-watchlists'
    }

    # ── Errors bucket ──
    if ($errors.Count -gt 0) {
        & $add 'bad' 'Work through the error log' @'
Each entry records the component, the message and, where the tool could determine
one, a suggested remediation. The same entries are in migration-log.jsonl for
scripted triage.
'@ $errors.Count 'sec-errors'
    }

    # ── Scope the tool does not cover ──
    & $add 'info' 'Migrate the content this tool does not cover' @'
Analytics rules, workbooks, watchlists and Content Hub solutions are in scope. Data
connectors, automation rules, playbooks (Logic Apps), hunting queries, saved searches
/ parsers, incidents and UEBA settings are not - they must be re-created in the target
by hand or by a separate deployment. Rules that depend on a connector will not
produce alerts until that connector is configured.
'@ 0 ''

    # ── Always-applicable verification ──
    if (-not $isDry) {
        & $add 'good' 'Verify the target workspace' @'
Confirm each migrated rule shows the expected enabled/disabled state in Analytics;
confirm workbooks render against target data rather than erroring on a missing table;
confirm data connectors in the target are actually ingesting; then let the target run
alongside the source long enough to compare alert volumes before decommissioning.
'@ 0 ''
    }

    return $steps.ToArray()
}

function New-NextStepsHtml {
    <#
    .SYNOPSIS
        Renders the next-steps action list plus the manual Content Hub checklist.
    .DESCRIPTION
        The checklist is rendered as per-item cards with their numbered steps intact.
        The workbook flattens those steps into a single joined cell, which is fine for
        filtering but close to unreadable as instructions.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Steps,
        [object[]]$Checklist,
        [string[]]$ValidAnchors
    )

    $stepList = @(ConvertTo-ItemList $Steps)
    $checkList = @(ConvertTo-ItemList $Checklist)
    if ($stepList.Count -eq 0 -and $checkList.Count -eq 0) { return '' }

    # 'sec-manual-steps' is rendered right here, so it is always linkable.
    $anchorSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($a in @($ValidAnchors)) { if ($a) { [void]$anchorSet.Add($a) } }
    if ($checkList.Count -gt 0) { [void]$anchorSet.Add('sec-manual-steps') }

    $items = foreach ($s in $stepList) {
        $badge = if ([int]$s.Count -gt 0) { "<span class=""count"">$([int]$s.Count)</span>" } else { '' }
        $title = ConvertTo-HtmlEncoded $s.Title
        # Never emit a link to a section that was not rendered (e.g. -NoDetailTables).
        $titleHtml = if ($s.Anchor -and $anchorSet.Contains($s.Anchor)) {
            "<a href=""#$($s.Anchor)"">$title</a>"
        } else { $title }
        # Detail is authored as a wrapped here-string; collapse to one paragraph.
        $detail = ConvertTo-HtmlEncoded (([string]$s.Detail) -replace '\s*\r?\n\s*', ' ').Trim()
        @"
    <li class="step tone-$($s.Tone)">
      <div class="step-title">$titleHtml $badge</div>
      <div class="step-detail">$detail</div>
    </li>
"@
    }

    $stepsHtml = if ($stepList.Count -gt 0) {
        @"
  <h2 id="sec-next-steps">Next Steps</h2>
  <p class="muted">Derived from this run. Items are ordered by how much they block a working target workspace.</p>
  <ol class="steps">
$($items -join "`n")
  </ol>
"@
    } else { '' }

    $checklistHtml = ''
    if ($checkList.Count -gt 0) {
        $cards = foreach ($c in $checkList) {
            $stepsInner = foreach ($ms in @($c.ManualSteps)) {
                # Strip any leading "1. " so the ordered list numbers it instead.
                "<li>$(ConvertTo-HtmlEncoded (([string]$ms) -replace '^\s*\d+\.\s*', ''))</li>"
            }
            $tactics = if ($c.Tactics) { "<dt>Tactics</dt><dd>$(ConvertTo-HtmlEncoded (@($c.Tactics) -join ', '))</dd>" } else { '' }
            @"
    <div class="check-card">
      <div class="check-head">$(ConvertTo-HtmlEncoded $c.RuleDisplayName)</div>
      <dl class="check-meta">
        <dt>Solution</dt><dd>$(ConvertTo-HtmlEncoded $c.SolutionName)</dd>
        <dt>Severity</dt><dd>$(ConvertTo-HtmlEncoded $c.Severity)</dd>
        $tactics
        <dt>Enabled in source</dt><dd>$(ConvertTo-HtmlEncoded $c.IsEnabled)</dd>
        <dt>Template ID</dt><dd><code>$(ConvertTo-HtmlEncoded $c.AlertRuleTemplateName)</code></dd>
      </dl>
      <ol class="check-steps">
$($stepsInner -join "`n")
      </ol>
    </div>
"@
        }
        $checklistHtml = @"
  <h2 id="sec-manual-steps">Manual Content Hub Install Steps</h2>
  <p class="muted">$($checkList.Count) solution(s) need installing by hand in the <strong>target</strong> workspace. Install these, then re-run the migration so the dependent rules can be created.</p>
$($cards -join "`n")
"@
    }

    return "$stepsHtml`n$checklistHtml"
}

function New-DiscoverySummaryHtml {
    <#
    .SYNOPSIS
        Renders what was found in the source workspace as its own section.
    .DESCRIPTION
        These counts previously appeared only inside the collapsible Summary detail
        table, so running with -NoDetailTables produced a dashboard that never said
        how much content the source workspace actually held. Rendering them as cards
        keeps the figure visible regardless of detail-table settings, and matches the
        'Source Discovery' section in the Markdown report.
    .PARAMETER MigrationResults
        The full results hashtable; RuleClassification may legitimately be absent.
    #>
    param([Parameter(Mandatory)][hashtable]$MigrationResults)

    $rc = $MigrationResults.RuleClassification
    $cards = [System.Collections.Generic.List[string]]::new()

    if ($rc) {
        $cards.Add((New-KpiCard -Label 'Total Source Rules' -Value @($rc.All).Count))
        $cards.Add((New-KpiCard -Label 'Template (enabled)'  -Value @($rc.TemplateRulesEnabled).Count))
        $cards.Add((New-KpiCard -Label 'Template (disabled)' -Value @($rc.TemplateRulesDisabled).Count))
        $cards.Add((New-KpiCard -Label 'Custom (enabled)'    -Value @($rc.CustomRulesEnabled).Count))
        $cards.Add((New-KpiCard -Label 'Custom (disabled)'   -Value @($rc.CustomRulesDisabled).Count))
    }
    $cards.Add((New-KpiCard -Label 'Workbooks Discovered'  -Value ([int]$MigrationResults.WorkbooksDiscovered)))
    $cards.Add((New-KpiCard -Label 'Watchlists Discovered' -Value ([int]$MigrationResults.WatchlistsDiscovered)))

    return @"
  <h2 id="sec-discovery">Source Discovery</h2>
  <p class="section-note">Content found in the source workspace before migration began.</p>
  <div class="kpis">
    $($cards -join "`n")
  </div>
"@
}

function New-MigrationOverviewHtml {
    <#
    .SYNOPSIS
        Builds the full migration summary HTML document.
    .PARAMETER Meta
        Hashtable: SourceWorkspace, SourceResourceGroup, SourceSubscriptionId,
        TargetWorkspace, TargetResourceGroup, TargetSubscriptionId, Cloud, Mode,
        GeneratedAt, Duration.
    .PARAMETER Kpis
        Ordered dictionary of KPI label -> value.
    .PARAMETER Details
        Ordered dictionary of section title -> flat rows, rendered as drill-down tables.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Meta,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Kpis,
        [Parameter(Mandatory)][hashtable]$MigrationResults,
        [System.Collections.IDictionary]$Details
    )

    $hasDetails = ($null -ne $Details) -and (@($Details.Keys).Count -gt 0)

    # Map KPI labels to detail-section titles so cards can deep-link into the data.
    $kpiAnchor = @{
        'Rules Created'       = 'Analytics Rules'
        'Rules Updated'       = 'Analytics Rules'
        'Rules Disabled'      = 'Analytics Rules'
        'Rules Skipped'       = 'Analytics Rules'
        'Rules Failed'        = 'Analytics Rules'
        'Workbooks Migrated'  = 'Workbooks'
        'Workbooks Failed'    = 'Workbooks'
        'Watchlists Migrated' = 'Watchlists'
        'Watchlists Failed'   = 'Watchlists'
        'Solutions Installed' = 'Content Hub'
        'Solutions Upgraded'  = 'Content Hub'
        'Manual Checklist'    = 'Manual Checklist'
        'Errors'              = 'Errors'
    }
    $kpiTone = @{
        'Rules Created'       = 'good'
        'Rules Updated'       = 'good'
        'Rules Disabled'      = 'warn'
        'Rules Skipped'       = 'warn'
        'Rules Failed'        = 'bad'
        'Workbooks Migrated'  = 'good'
        'Workbooks Failed'    = 'bad'
        'Watchlists Migrated' = 'good'
        'Watchlists Failed'   = 'bad'
        'Solutions Installed' = 'good'
        'Solutions Upgraded'  = 'good'
        'Manual Checklist'    = 'warn'
        'Errors'              = 'bad'
    }

    $cards = foreach ($k in @($Kpis.Keys)) {
        $anchorTitle = $kpiAnchor[$k]
        $anchor = if ($hasDetails -and $anchorTitle -and $Details.Contains($anchorTitle)) {
            ConvertTo-Slug $anchorTitle
        } else { '' }
        # Zero failures/errors should not read as alarming.
        $tone = $kpiTone[$k]
        if ($tone -in @('bad', 'warn') -and (ConvertTo-ChartValue $Kpis[$k]) -eq 0) { $tone = 'default' }
        if (-not $tone) { $tone = 'default' }
        New-KpiCard -Label $k -Value $Kpis[$k] -Anchor $anchor -Tone $tone
    }

    # ── charts ──
    $charts = [System.Collections.Generic.List[string]]::new()

    $rulePairs = Get-ActionBreakdown -Results $MigrationResults.RuleResults
    $charts.Add((New-BarChart -Title 'Analytics Rules by Outcome' -Pairs $rulePairs -Color '#2563eb'))

    $wbPairs = Get-ActionBreakdown -Results $MigrationResults.WorkbookResults
    $charts.Add((New-BarChart -Title 'Workbooks by Outcome' -Pairs $wbPairs -Color '#7c3aed'))

    $wlPairs = Get-ActionBreakdown -Results $MigrationResults.WatchlistResults
    $charts.Add((New-BarChart -Title 'Watchlists by Outcome' -Pairs $wlPairs -Color '#059669'))

    $rc = $MigrationResults.RuleClassification
    if ($rc) {
        $catPairs = @(
            [PSCustomObject]@{ Label = 'Template (enabled)';  Value = @($rc.TemplateRulesEnabled).Count }
            [PSCustomObject]@{ Label = 'Template (disabled)'; Value = @($rc.TemplateRulesDisabled).Count }
            [PSCustomObject]@{ Label = 'Custom (enabled)';    Value = @($rc.CustomRulesEnabled).Count }
            [PSCustomObject]@{ Label = 'Custom (disabled)';   Value = @($rc.CustomRulesDisabled).Count }
        )
        $charts.Add((New-BarChart -Title 'Source Rules by Category' -Pairs $catPairs -Color '#0891b2'))

        $sevPairs = @($rc.All) |
            Group-Object -Property { $_.properties.severity } |
            Sort-Object Count -Descending |
            ForEach-Object { [PSCustomObject]@{ Label = $(if ($_.Name) { $_.Name } else { 'n/a' }); Value = $_.Count } }
        $charts.Add((New-BarChart -Title 'Source Rules by Severity' -Pairs $sevPairs -Color '#dc2626'))

        $tacticPairs = @($rc.All) |
            ForEach-Object { $_.properties.tactics } |
            Where-Object { $_ } |
            Group-Object |
            Sort-Object Count -Descending |
            Select-Object -First 10 |
            ForEach-Object { [PSCustomObject]@{ Label = $_.Name; Value = $_.Count } }
        $charts.Add((New-BarChart -Title 'Top MITRE Tactics (source rules)' -Pairs $tacticPairs -Color '#ea580c'))
    }

    $errPairs = @(ConvertTo-ItemList $MigrationResults.Errors) |
        Group-Object -Property Component |
        Sort-Object Count -Descending |
        ForEach-Object { [PSCustomObject]@{ Label = $_.Name; Value = $_.Count } }
    if (@($errPairs).Count -gt 0) {
        $charts.Add((New-BarChart -Title 'Errors by Component' -Pairs $errPairs -Color '#b91c1c'))
    }

    # ── next steps + manual checklist ──
    # Only sections that are actually rendered are linkable.
    $validAnchors = if ($hasDetails) {
        @($Details.Keys | ForEach-Object { ConvertTo-Slug ([string]$_) })
    } else { @() }

    $checklist = @(ConvertTo-ItemList $MigrationResults.ContentHubResults.ManualChecklist)
    $discoveryHtml = New-DiscoverySummaryHtml -MigrationResults $MigrationResults
    $nextStepsHtml = New-NextStepsHtml `
        -Steps (Get-MigrationNextSteps -MigrationResults $MigrationResults) `
        -Checklist $checklist `
        -ValidAnchors $validAnchors

    # ── detail drill-down ──
    $detailHtml = ''
    if ($hasDetails) {
        $jumpLinks = [System.Collections.Generic.List[string]]::new()
        $tables    = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $Details.GetEnumerator()) {
            $title = [string]$entry.Key
            $rows  = @($entry.Value)
            $slug  = ConvertTo-Slug $title
            $jumpLinks.Add("<a href=""#$slug"">$(ConvertTo-HtmlEncoded $title) <span class=""count"">$($rows.Count)</span></a>")
            $tables.Add((New-DetailTable -Title $title -Rows $rows))
        }
        $detailHtml = @"
  <h2>Detailed Results</h2>
  <p class="muted">Click a section to expand. Use the filter box to search and click a column header to sort. Same data as the Excel workbook.</p>
  <div class="jump">$($jumpLinks -join '')</div>
  $($tables -join "`n")
"@
    }

    $mode      = ConvertTo-HtmlEncoded $Meta.Mode
    $modeCls   = if ([string]$Meta.Mode -match 'DRY') { 'mode-dry' } else { 'mode-exec' }
    $genAt     = ConvertTo-HtmlEncoded $Meta.GeneratedAt
    $duration  = ConvertTo-HtmlEncoded $Meta.Duration
    $cloud     = ConvertTo-HtmlEncoded $Meta.Cloud
    $srcWs     = ConvertTo-HtmlEncoded $Meta.SourceWorkspace
    $srcRg     = ConvertTo-HtmlEncoded $Meta.SourceResourceGroup
    $srcSub    = ConvertTo-HtmlEncoded $Meta.SourceSubscriptionId
    $tgtWs     = ConvertTo-HtmlEncoded $Meta.TargetWorkspace
    $tgtRg     = ConvertTo-HtmlEncoded $Meta.TargetResourceGroup
    $tgtSub    = ConvertTo-HtmlEncoded $Meta.TargetSubscriptionId

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sentinel Migration — $srcWs → $tgtWs</title>
<style>
  :root { --bg:#0f172a; --card:#1e293b; --muted:#94a3b8; --text:#e2e8f0; --accent:#38bdf8;
          --good:#34d399; --warn:#fbbf24; --bad:#f87171; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:Segoe UI,Arial,sans-serif; background:var(--bg); color:var(--text); }
  header { padding:28px 32px; background:linear-gradient(90deg,#0ea5e9,#6366f1); color:#fff; }
  header h1 { margin:0 0 6px; font-size:24px; }
  header .meta { font-size:13px; opacity:.9; }
  .badge { display:inline-block; border-radius:6px; padding:2px 10px; font-size:12px; font-weight:700; letter-spacing:.4px; }
  .mode-dry { background:#fef3c7; color:#92400e; }
  .mode-exec { background:#fee2e2; color:#991b1b; }
  main { padding:24px 32px 60px; max-width:1200px; margin:0 auto; }
  h2 { border-bottom:1px solid #334155; padding-bottom:8px; margin-top:36px; }
  .flow { display:flex; flex-wrap:wrap; align-items:center; gap:14px; margin:18px 0 4px; }
  .ws { background:var(--card); border:1px solid #334155; border-radius:12px; padding:14px 18px; flex:1; min-width:260px; }
  .ws .ws-role { font-size:11px; text-transform:uppercase; letter-spacing:.6px; color:var(--muted); }
  .ws .ws-name { font-size:17px; font-weight:600; margin-top:2px; }
  .ws .ws-sub { font-size:12px; color:var(--muted); margin-top:4px; word-break:break-all; }
  .arrow { font-size:26px; color:var(--accent); }
  .kpis { display:grid; grid-template-columns:repeat(auto-fill,minmax(180px,1fr)); gap:16px; }
  .kpi { background:var(--card); border-radius:12px; padding:18px; border:1px solid #334155; }
  .kpi-value { font-size:30px; font-weight:700; color:var(--accent); }
  .kpi-label { font-size:13px; color:var(--muted); margin-top:4px; }
  .kpi-sub { font-size:11px; color:var(--muted); margin-top:2px; }
  .kpi.tone-good .kpi-value { color:var(--good); }
  .kpi.tone-warn .kpi-value { color:var(--warn); }
  .kpi.tone-bad  .kpi-value { color:var(--bad); }
  .charts { display:grid; grid-template-columns:repeat(auto-fill,minmax(480px,1fr)); gap:20px; }
  .chart { background:var(--card); border-radius:12px; padding:18px 20px; border:1px solid #334155; }
  .chart h3 { margin:0 0 14px; font-size:15px; }
  .bar-row { display:grid; grid-template-columns:180px 1fr 60px; align-items:center; gap:10px; margin:6px 0; }
  .bar-label { font-size:12px; color:var(--muted); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .bar-track { background:#0f172a; border-radius:6px; height:16px; overflow:hidden; }
  .bar-fill { height:100%; border-radius:6px; }
  .bar-value { font-size:12px; text-align:right; font-variant-numeric:tabular-nums; }
  .muted { color:var(--muted); font-size:13px; }
  .detail { background:var(--card); border:1px solid #334155; border-radius:10px; margin:10px 0; padding:0 16px; }
  .detail > summary { cursor:pointer; padding:14px 0; font-size:15px; font-weight:600; list-style:none; }
  .detail > summary::-webkit-details-marker { display:none; }
  .detail > summary::before { content:'\25B8'; display:inline-block; margin-right:8px; color:var(--accent); transition:transform .15s; }
  .detail[open] > summary::before { transform:rotate(90deg); }
  .count { display:inline-block; background:#0f172a; color:var(--accent); border-radius:10px; font-size:11px; padding:1px 8px; margin-left:6px; vertical-align:middle; }
  .section-note { color:var(--muted); font-size:13px; margin:-6px 0 12px; }
  .tbl-search { width:100%; max-width:340px; margin:4px 0 12px; padding:7px 10px; border-radius:8px; border:1px solid #334155; background:#0f172a; color:var(--text); font-size:13px; }
  .tbl-wrap { overflow:auto; max-height:460px; border:1px solid #263349; border-radius:8px; margin-bottom:16px; }
  table.detail-table { border-collapse:collapse; width:100%; font-size:12px; }
  table.detail-table th, table.detail-table td { text-align:left; padding:7px 10px; border-bottom:1px solid #263349; white-space:nowrap; }
  table.detail-table thead th { position:sticky; top:0; background:#172033; cursor:pointer; user-select:none; z-index:1; }
  table.detail-table thead th:hover { background:#1f2b44; }
  table.detail-table tbody tr:hover { background:#172033; }
  table.detail-table tbody tr.row-bad td:first-child { border-left:3px solid var(--bad); color:var(--bad); }
  table.detail-table tbody tr.row-warn td:first-child { border-left:3px solid var(--warn); color:var(--warn); }
  .sort-ind { color:var(--accent); font-size:10px; }
  .jump { display:flex; flex-wrap:wrap; gap:8px; margin:12px 0 20px; }
  ol.steps { list-style:none; counter-reset:step; padding:0; margin:14px 0 0; }
  ol.steps > li.step { counter-increment:step; position:relative; background:var(--card);
      border:1px solid #334155; border-left:4px solid var(--muted); border-radius:10px;
      padding:14px 18px 14px 56px; margin:10px 0; }
  ol.steps > li.step::before { content:counter(step); position:absolute; left:16px; top:14px;
      width:26px; height:26px; border-radius:50%; background:#0f172a; color:var(--accent);
      font-size:13px; font-weight:700; display:flex; align-items:center; justify-content:center; }
  li.step.tone-bad  { border-left-color:var(--bad); }
  li.step.tone-warn { border-left-color:var(--warn); }
  li.step.tone-good { border-left-color:var(--good); }
  li.step.tone-info { border-left-color:var(--accent); }
  .step-title { font-size:15px; font-weight:600; margin-bottom:5px; }
  .step-title a { color:var(--accent); text-decoration:none; }
  .step-title a:hover { text-decoration:underline; }
  .step-detail { font-size:13px; color:var(--muted); line-height:1.55; }
  .check-card { background:var(--card); border:1px solid #334155; border-left:4px solid var(--warn);
      border-radius:10px; padding:14px 18px; margin:10px 0; }
  .check-head { font-size:15px; font-weight:600; margin-bottom:8px; }
  dl.check-meta { display:grid; grid-template-columns:150px 1fr; gap:2px 12px; margin:0 0 10px;
      font-size:12px; }
  dl.check-meta dt { color:var(--muted); }
  dl.check-meta dd { margin:0; word-break:break-all; }
  dl.check-meta code { background:#0f172a; padding:1px 6px; border-radius:4px; font-size:11px; }
  ol.check-steps { margin:0; padding-left:20px; font-size:13px; color:var(--muted); line-height:1.6; }
  .jump a { font-size:12px; color:var(--accent); text-decoration:none; background:var(--card); border:1px solid #334155; border-radius:8px; padding:6px 10px; }
  .jump a:hover { border-color:var(--accent); }
  a.kpi-link { text-decoration:none; color:inherit; display:block; transition:border-color .15s, transform .1s; }
  a.kpi-link:hover { border-color:var(--accent); transform:translateY(-2px); }
  footer { text-align:center; color:var(--muted); font-size:12px; padding:20px; }
</style>
</head>
<body>
<header>
  <h1>Microsoft Sentinel — Migration Summary</h1>
  <div class="meta">
    <span class="badge $modeCls">$mode</span> &nbsp;|&nbsp; Cloud: $cloud &nbsp;|&nbsp;
    Duration: $duration &nbsp;|&nbsp; Generated: $genAt
  </div>
</header>
<main>
  <div class="flow">
    <div class="ws">
      <div class="ws-role">Source</div>
      <div class="ws-name">$srcWs</div>
      <div class="ws-sub">RG: $srcRg<br>Sub: $srcSub</div>
    </div>
    <div class="arrow">&#8594;</div>
    <div class="ws">
      <div class="ws-role">Target</div>
      <div class="ws-name">$tgtWs</div>
      <div class="ws-sub">RG: $tgtRg<br>Sub: $tgtSub</div>
    </div>
  </div>

  <h2>Migration Outcome</h2>
  <div class="kpis">
    $($cards -join "`n")
  </div>

$discoveryHtml
  <h2>Breakdowns</h2>
  <div class="charts">
    $($charts -join "`n")
  </div>
$nextStepsHtml
$detailHtml
</main>
<footer>Generated by the Sentinel Migration Assistant. This file may contain workspace configuration detail; handle like the accompanying Excel/CSV workbook.</footer>
<script>
function filterTable(id, q) {
  q = (q || '').toLowerCase();
  var rows = document.querySelectorAll('#' + id + ' tbody tr');
  for (var i = 0; i < rows.length; i++) {
    rows[i].style.display = rows[i].textContent.toLowerCase().indexOf(q) > -1 ? '' : 'none';
  }
}
function sortTable(id, col, th) {
  var tbody = document.getElementById(id).tBodies[0];
  var rows = Array.prototype.slice.call(tbody.rows);
  var asc = th.getAttribute('data-asc') !== 'true';
  var heads = th.parentNode.children;
  for (var h = 0; h < heads.length; h++) {
    heads[h].removeAttribute('data-asc');
    var si = heads[h].querySelector('.sort-ind'); if (si) si.textContent = '';
  }
  th.setAttribute('data-asc', asc);
  rows.sort(function (a, b) {
    var x = a.cells[col].textContent.trim(), y = b.cells[col].textContent.trim();
    var nx = parseFloat(x.replace(/,/g, '')), ny = parseFloat(y.replace(/,/g, ''));
    var bothNum = x !== '' && y !== '' && !isNaN(nx) && !isNaN(ny);
    var cmp = bothNum ? nx - ny : x.toLowerCase().localeCompare(y.toLowerCase());
    return asc ? cmp : -cmp;
  });
  for (var r = 0; r < rows.length; r++) tbody.appendChild(rows[r]);
  var ind = th.querySelector('.sort-ind'); if (ind) ind.textContent = asc ? ' \u25B2' : ' \u25BC';
}
function openFromHash() {
  var h = location.hash.slice(1);
  if (!h) return;
  var el = document.getElementById(h);
  if (el && el.tagName === 'DETAILS') { el.open = true; el.scrollIntoView({ behavior: 'smooth' }); }
}
window.addEventListener('hashchange', openFromHash);
window.addEventListener('load', openFromHash);
</script>
</body>
</html>
"@
}

function Save-MigrationOverviewHtml {
    <#
    .SYNOPSIS
        Saves the migration summary HTML to disk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Html,
        [Parameter(Mandatory)][string]$Path
    )
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $Html | Set-Content -Path $Path -Encoding UTF8
    Write-HtmlLog -Level 'Success' -Message "Migration summary: $Path"
}

Export-ModuleMember -Function @(
    'ConvertTo-HtmlEncoded'
    'ConvertTo-Slug'
    'ConvertTo-ItemList'
    'New-KpiCard'
    'ConvertTo-ChartValue'
    'New-BarChart'
    'New-DiscoverySummaryHtml'
    'New-DetailTable'
    'Get-ActionBreakdown'
    'Get-NormalizedAction'
    'Get-MigrationKpis'
    'Get-MigrationNextSteps'
    'New-NextStepsHtml'
    'New-MigrationOverviewHtml'
    'Save-MigrationOverviewHtml'
)
