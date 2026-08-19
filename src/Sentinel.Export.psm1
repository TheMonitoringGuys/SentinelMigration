<#
.SYNOPSIS
    Output/export for the Sentinel Migration Assistant.
.DESCRIPTION
    - Flattens source inventory and migration results into tabular rows.
    - Writes a raw JSON snapshot per collection (documentation / version control),
      plus a combined raw/_Full.json envelope for the whole run.
    - Writes a multi-sheet Excel workbook when the ImportExcel module is available,
      otherwise falls back to one CSV file per sheet.

    Mirrors the artifact set produced by the Sentinel Assessment Tool so migration
    runs and assessment runs can be reviewed side by side.
#>

Import-Module (Join-Path $PSScriptRoot 'Sentinel.Common.psm1') -Force -DisableNameChecking

# ── small helpers ─────────────────────────────────────────────────────────────
function Write-ExportLog {
    <#
    .SYNOPSIS
        Logs through Write-MigrationLog when Sentinel.Report is loaded, else Write-Host.
    .DESCRIPTION
        Keeps this module usable standalone (e.g. in Pester) without requiring the
        reporting module to be imported first.
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

function Get-Prop {
    <#
    .SYNOPSIS
        Safely navigates a dotted property path; returns $Default if any hop is null.
    #>
    [CmdletBinding()]
    param(
        [object]$Object,
        [Parameter(Mandatory)][string]$Path,
        [object]$Default = $null
    )
    $cur = $Object
    foreach ($seg in $Path.Split('.')) {
        if ($null -eq $cur) { return $Default }
        if ($cur -is [System.Collections.IDictionary]) {
            if (-not $cur.Contains($seg)) { return $Default }
            $cur = $cur[$seg]
            continue
        }
        $member = $cur.PSObject.Properties[$seg]
        if ($null -eq $member) { return $Default }
        $cur = $member.Value
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

function Join-Values {
    <#
    .SYNOPSIS
        Flattens a scalar or collection into a single delimited string for a cell.
    #>
    param([object]$Value, [string]$Separator = '; ')
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) { return (@($Value) -join $Separator) }
    return [string]$Value
}

function Get-RuleCategory {
    <#
    .SYNOPSIS
        Classifies a source rule as template/custom and enabled/disabled.
    #>
    param([object]$Rule)
    $templateName = Get-Prop $Rule 'properties.alertRuleTemplateName'
    $origin  = if ([string]::IsNullOrWhiteSpace([string]$templateName)) { 'Custom' } else { 'Template' }
    $state   = if ((Get-Prop $Rule 'properties.enabled') -eq $true) { 'Enabled' } else { 'Disabled' }
    return "$origin ($state)"
}

# ── raw JSON snapshot ─────────────────────────────────────────────────────────
function New-FullExportEnvelope {
    <#
    .SYNOPSIS
        Builds the object written to raw/_Full.json: run metadata plus every collection.
    .DESCRIPTION
        A run emits one raw/*.json per collection. This gathers the same data into a
        single object so the whole run can be moved, archived or handed off as one
        file. Nothing is truncated.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Collections,
        [string]$Product = 'Microsoft Sentinel',
        [string]$Tool = 'Sentinel-Migration-Assistant',
        [System.Collections.IDictionary]$Scope
    )
    $counts  = [ordered]@{}
    $bundled = [ordered]@{}
    foreach ($name in @($Collections.Keys)) {
        $data = $Collections[$name]
        if ($null -eq $data) { $data = @() }
        $counts[$name]  = @($data).Count
        $bundled[$name] = @($data)
    }
    $scopeOut = [ordered]@{}
    if ($Scope) { foreach ($key in $Scope.Keys) { $scopeOut[$key] = $Scope[$key] } }

    [ordered]@{
        schemaVersion    = 1
        tool             = $Tool
        product          = $Product
        generatedUtc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        scope            = $scopeOut
        collectionCounts = $counts
        collections      = $bundled
    }
}

function Export-RawJson {
    <#
    .SYNOPSIS
        Writes raw/<Collection>.json for each collection plus a combined raw/_Full.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Collections,
        [Parameter(Mandatory)][string]$OutputDir,
        [System.Collections.IDictionary]$Scope
    )

    $rawDir = Join-Path $OutputDir 'raw'
    if (-not (Test-Path $rawDir)) { New-Item -Path $rawDir -ItemType Directory -Force | Out-Null }

    foreach ($name in @($Collections.Keys)) {
        $data = $Collections[$name]
        if ($null -eq $data) { $data = @() }
        $path = Join-Path $rawDir "$name.json"
        @($data) | ConvertTo-Json -Depth 25 | Set-Content -Path $path -Encoding UTF8
    }

    $envelope = New-FullExportEnvelope -Collections $Collections -Scope $Scope
    $fullPath = Join-Path $rawDir '_Full.json'
    $envelope | ConvertTo-Json -Depth 25 | Set-Content -Path $fullPath -Encoding UTF8

    Write-ExportLog -Level 'Success' -Message "Raw JSON snapshot: $rawDir"
    return $rawDir
}

# ── flatteners: migration results ─────────────────────────────────────────────
function ConvertTo-RuleResultRows {
    <#
    .SYNOPSIS
        Flattens analytics rule migration results, enriched with source rule metadata.
    .PARAMETER SourceRules
        Raw source rule objects, used to attach severity/tactics/origin by display name.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Results,
        [object[]]$SourceRules
    )

    $index = @{}
    foreach ($rule in (ConvertTo-ItemList $SourceRules)) {
        $dn = [string](Get-Prop $rule 'properties.displayName')
        if ($dn -and -not $index.ContainsKey($dn)) { $index[$dn] = $rule }
    }

    foreach ($r in (ConvertTo-ItemList $Results)) {
        $dn  = [string]$r.DisplayName
        $src = if ($dn -and $index.ContainsKey($dn)) { $index[$dn] } else { $null }

        [PSCustomObject][ordered]@{
            Action       = Get-NormalizedAction $r.Action
            PlannedOnly  = [bool]([string]$r.Action -ne (Get-NormalizedAction $r.Action))
            DisplayName  = $dn
            Severity     = Get-Prop $src 'properties.severity' ''
            Origin       = if ($src) { Get-RuleCategory $src } else { '' }
            Kind         = Get-Prop $src 'kind' ''
            Tactics      = Join-Values (Get-Prop $src 'properties.tactics')
            Techniques   = Join-Values (Get-Prop $src 'properties.techniques')
            EnabledInSource = if ($src) { [bool](Get-Prop $src 'properties.enabled') } else { '' }
            TemplateId   = Get-Prop $src 'properties.alertRuleTemplateName' ''
            RuleId       = $r.RuleId
            Reason       = $r.Reason
        }
    }
}

function ConvertTo-WorkbookResultRows {
    <#
    .SYNOPSIS
        Flattens workbook migration results.
    #>
    [CmdletBinding()]
    param([object[]]$Results)

    foreach ($r in (ConvertTo-ItemList $Results)) {
        [PSCustomObject][ordered]@{
            Action      = Get-NormalizedAction $r.Action
            PlannedOnly = [bool]([string]$r.Action -ne (Get-NormalizedAction $r.Action))
            DisplayName = $r.DisplayName
            WorkbookId  = $r.WorkbookId
            Reason      = $r.Reason
        }
    }
}

function ConvertTo-WatchlistResultRows {
    <#
    .SYNOPSIS
        Flattens watchlist migration results.
    #>
    [CmdletBinding()]
    param([object[]]$Results)

    foreach ($r in (ConvertTo-ItemList $Results)) {
        [PSCustomObject][ordered]@{
            Action         = Get-NormalizedAction $r.Action
            PlannedOnly    = [bool]([string]$r.Action -ne (Get-NormalizedAction $r.Action))
            DisplayName    = $r.DisplayName
            WatchlistAlias = $r.WatchlistAlias
            ItemCount      = $r.ItemCount
            Reason         = $r.Reason
        }
    }
}

function ConvertTo-ContentHubRows {
    <#
    .SYNOPSIS
        Flattens Content Hub solution results into one table with a Status column.
    .PARAMETER ContentHubResults
        The object returned by Sync-ContentHubSolutions.
    #>
    [CmdletBinding()]
    param([object]$ContentHubResults)

    if (-not $ContentHubResults) { return }

    $groups = @(
        @{ Status = 'Installed';        Items = $ContentHubResults.InstalledPackages }
        @{ Status = 'Failed';           Items = $ContentHubResults.FailedPackages }
        @{ Status = 'AlreadyInstalled'; Items = $ContentHubResults.AlreadyInstalled }
    )

    foreach ($g in $groups) {
        foreach ($p in (ConvertTo-ItemList $g.Items)) {
            [PSCustomObject][ordered]@{
                Status      = $g.Status
                Action      = Get-NormalizedAction $p.Action
                PlannedOnly = [bool]([string]$p.Action -ne (Get-NormalizedAction $p.Action))
                DisplayName = $p.DisplayName
                PackageId   = $p.PackageId
                Reason      = $p.Reason
            }
        }
    }
}

function ConvertTo-ChecklistRows {
    <#
    .SYNOPSIS
        Flattens the manual Content Hub install checklist.
    #>
    [CmdletBinding()]
    param([object[]]$Checklist)

    foreach ($c in (ConvertTo-ItemList $Checklist)) {
        [PSCustomObject][ordered]@{
            RuleDisplayName       = $c.RuleDisplayName
            SolutionName          = $c.SolutionName
            Severity              = $c.Severity
            Tactics               = Join-Values $c.Tactics
            EnabledInSource       = $c.IsEnabled
            AlertRuleTemplateName = $c.AlertRuleTemplateName
            ManualSteps           = Join-Values $c.ManualSteps ' '
        }
    }
}

function ConvertTo-ErrorRows {
    <#
    .SYNOPSIS
        Flattens run errors and their remediation guidance.
    #>
    [CmdletBinding()]
    param([object[]]$Errors)

    foreach ($e in (ConvertTo-ItemList $Errors)) {
        [PSCustomObject][ordered]@{
            Component   = $e.Component
            Message     = $e.Message
            Remediation = $e.Remediation
        }
    }
}

# ── flatteners: discovered source inventory ───────────────────────────────────
function ConvertTo-SourceRuleRows {
    <#
    .SYNOPSIS
        Flattens the analytics rules discovered in the source workspace.
    #>
    [CmdletBinding()]
    param([object[]]$Rules)

    foreach ($rule in (ConvertTo-ItemList $Rules)) {
        [PSCustomObject][ordered]@{
            DisplayName = Get-Prop $rule 'properties.displayName' ''
            Enabled     = [bool](Get-Prop $rule 'properties.enabled')
            Severity    = Get-Prop $rule 'properties.severity' ''
            Origin      = Get-RuleCategory $rule
            Kind        = Get-Prop $rule 'kind' ''
            Tactics     = Join-Values (Get-Prop $rule 'properties.tactics')
            Techniques  = Join-Values (Get-Prop $rule 'properties.techniques')
            TemplateId  = Get-Prop $rule 'properties.alertRuleTemplateName' ''
            Name        = Get-Prop $rule 'name' ''
        }
    }
}

function ConvertTo-SourceWorkbookRows {
    <#
    .SYNOPSIS
        Flattens the workbooks discovered in the source resource group.
    #>
    [CmdletBinding()]
    param([object[]]$Workbooks)

    foreach ($wb in (ConvertTo-ItemList $Workbooks)) {
        [PSCustomObject][ordered]@{
            DisplayName = Get-Prop $wb 'properties.displayName' ''
            Category    = Get-Prop $wb 'properties.category' ''
            Kind        = Get-Prop $wb 'kind' ''
            Location    = Get-Prop $wb 'location' ''
            Name        = Get-Prop $wb 'name' ''
        }
    }
}

function ConvertTo-SourceWatchlistRows {
    <#
    .SYNOPSIS
        Flattens the watchlists discovered in the source workspace.
    #>
    [CmdletBinding()]
    param([object[]]$Watchlists)

    foreach ($wl in (ConvertTo-ItemList $Watchlists)) {
        [PSCustomObject][ordered]@{
            DisplayName    = Get-Prop $wl 'properties.displayName' ''
            Alias          = Get-Prop $wl 'properties.watchlistAlias' ''
            Provider       = Get-Prop $wl 'properties.provider' ''
            ItemsSearchKey = Get-Prop $wl 'properties.itemsSearchKey' ''
            Description    = Get-Prop $wl 'properties.description' ''
        }
    }
}

function ConvertTo-SummaryRows {
    <#
    .SYNOPSIS
        Builds the run summary sheet: mode, scope, timings and headline counts.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$MigrationResults)

    $cfg   = $MigrationResults.Config
    $rules = $MigrationResults.RuleClassification
    $start = $MigrationResults.StartTime
    $end   = $MigrationResults.EndTime

    $duration = if ($start -and $end) { Format-MigrationDuration -Span ([datetime]$end - [datetime]$start) } else { 'N/A' }
    $mode     = if ($MigrationResults.DryRun) { 'DRY RUN (no changes made)' } else { 'EXECUTE' }

    $pairs = [ordered]@{
        'Mode'                    = $mode
        'Started'                 = if ($start) { ([datetime]$start).ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        'Completed'               = if ($end) { ([datetime]$end).ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        'Duration'                = $duration
        'Source Subscription'     = Get-Prop $cfg 'Source.SubscriptionId' ''
        'Source Resource Group'   = Get-Prop $cfg 'Source.ResourceGroupName' ''
        'Source Workspace'        = Get-Prop $cfg 'Source.WorkspaceName' ''
        'Target Subscription'     = Get-Prop $cfg 'Target.SubscriptionId' ''
        'Target Resource Group'   = Get-Prop $cfg 'Target.ResourceGroupName' ''
        'Target Workspace'        = Get-Prop $cfg 'Target.WorkspaceName' ''
        'Cloud'                   = Get-Prop $cfg 'Options.Cloud' ''
        'Source Rules Discovered' = if ($rules) { @(ConvertTo-ItemList $rules.All).Count } else { 0 }
        'Workbooks Discovered'    = $MigrationResults.WorkbooksDiscovered
        'Watchlists Discovered'   = $MigrationResults.WatchlistsDiscovered
        'Rule Results'            = @(ConvertTo-ItemList $MigrationResults.RuleResults).Count
        'Workbook Results'        = @(ConvertTo-ItemList $MigrationResults.WorkbookResults).Count
        'Watchlist Results'       = @(ConvertTo-ItemList $MigrationResults.WatchlistResults).Count
        'Errors'                  = @(ConvertTo-ItemList $MigrationResults.Errors).Count
    }

    foreach ($k in $pairs.Keys) {
        [PSCustomObject][ordered]@{ Property = $k; Value = $pairs[$k] }
    }
}

# ── workbook writer ───────────────────────────────────────────────────────────
function Get-SafeSheetName {
    <#
    .SYNOPSIS
        Excel worksheet names are capped at 31 characters and reject : \ / ? * [ ].
    .PARAMETER Suffix
        Disambiguator appended within the 31-character budget, so uniquifying a
        long name always produces a different string.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Suffix = ''
    )
    $clean = ($Name -replace '[:\\/?*\[\]]', '-').Trim()
    # Excel rejects an empty worksheet name, so a blank input must still yield something.
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = 'Sheet' }
    $budget = 31 - $Suffix.Length
    if ($budget -lt 1) { $budget = 1 }
    if ($clean.Length -gt $budget) { $clean = $clean.Substring(0, $budget) }
    return ($clean.Trim() + $Suffix)
}

function Get-SafeTableName {
    <#
    .SYNOPSIS
        Excel table names must be non-empty, must not start with a digit, and must
        be unique within the workbook.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [System.Collections.IDictionary]$Used
    )
    $clean = $Name -replace '[^A-Za-z0-9]', ''
    if (-not $clean)            { $clean = 'Table' }
    if ($clean -match '^[0-9]') { $clean = "T$clean" }

    $candidate = $clean
    $n = 2
    while ($Used -and $Used.Contains($candidate)) { $candidate = "$clean$n"; $n++ }
    if ($Used) { $Used[$candidate] = $true }
    return $candidate
}

function Test-ExportModuleAvailable {
    <#
    .SYNOPSIS
        Reports whether an optional export dependency is installed.
    .DESCRIPTION
        A seam so tests can simulate a missing ImportExcel without mocking
        Get-Module. Mocking Get-Module is not viable here: Pester itself calls it
        to resolve module scope, so stubbing it breaks every later mock in the
        same test with a misleading "Could not find Command" error.
    #>
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Module -ListAvailable -Name $Name)
}

function Export-MigrationWorkbook {
    <#
    .SYNOPSIS
        Writes sheets to an .xlsx (ImportExcel) or a folder of CSVs (fallback).
    .PARAMETER Sheets
        Ordered dictionary of SheetName -> row objects[].
    .PARAMETER NoAutoInstall
        Suppresses the automatic ImportExcel install and falls straight back to CSV.
        Without this the switch of the same name on the orchestrator was honoured
        for powershell-yaml but silently ignored here, so an operator who asked for
        no installs still got one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Sheets,
        [Parameter(Mandatory)][string]$OutputDir,
        [string]$FileName = 'Migration-Results.xlsx',
        [switch]$NoAutoInstall
    )

    if (-not (Test-Path $OutputDir)) { New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null }

    $hasImportExcel = Test-ExportModuleAvailable -Name 'ImportExcel'
    if (-not $hasImportExcel -and $NoAutoInstall) {
        Write-ExportLog -Level 'Warning' -Message 'ImportExcel not installed and -NoAutoInstall was specified; writing CSV instead.'
    }
    elseif (-not $hasImportExcel) {
        try {
            Write-ExportLog -Message 'Installing ImportExcel module...'
            Install-Module -Name ImportExcel -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            $hasImportExcel = $true
        }
        catch {
            Write-ExportLog -Level 'Warning' -Message "ImportExcel unavailable; falling back to CSV. ($($_.Exception.Message))"
        }
    }

    if ($hasImportExcel) {
        Import-Module ImportExcel -ErrorAction Stop
        $xlsxPath = Join-Path $OutputDir $FileName
        if (Test-Path $xlsxPath) { Remove-Item $xlsxPath -Force }
        $usedSheets = @{}
        $usedTables = @{}
        foreach ($sheet in @($Sheets.Keys)) {
            $name = Get-SafeSheetName -Name $sheet
            $n = 2
            while ($usedSheets.ContainsKey($name)) { $name = (Get-SafeSheetName -Name $sheet -Suffix " $n"); $n++ }
            $usedSheets[$name] = $true

            $rows = @($Sheets[$sheet])
            if ($rows.Count -eq 0) { $rows = @([PSCustomObject]@{ Note = 'No items found' }) }
            $rows | Export-Excel -Path $xlsxPath -WorksheetName $name -AutoSize -FreezeTopRow -BoldTopRow -TableName (Get-SafeTableName -Name $name -Used $usedTables)
        }
        Write-ExportLog -Level 'Success' -Message "Results workbook: $xlsxPath"
        return $xlsxPath
    }
    else {
        $csvDir = Join-Path $OutputDir 'csv'
        if (-not (Test-Path $csvDir)) { New-Item -Path $csvDir -ItemType Directory -Force | Out-Null }
        $usedFiles = @{}
        foreach ($sheet in @($Sheets.Keys)) {
            $rows = @($Sheets[$sheet])
            $file = Get-SafeSheetName -Name $sheet
            $n = 2
            while ($usedFiles.ContainsKey($file)) { $file = (Get-SafeSheetName -Name $sheet -Suffix " $n"); $n++ }
            $usedFiles[$file] = $true
            $path = Join-Path $csvDir "$file.csv"
            if ($rows.Count -eq 0) {
                'Note' | Set-Content -Path $path -Encoding UTF8
                'No items found' | Add-Content -Path $path -Encoding UTF8
            }
            else {
                $rows | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
            }
        }
        Write-ExportLog -Level 'Success' -Message "Results CSVs: $csvDir"
        return $csvDir
    }
}

function New-MigrationSheets {
    <#
    .SYNOPSIS
        Builds the ordered sheet set shared by the workbook and the HTML drill-down.
    .DESCRIPTION
        The workbook and the HTML detail tables render the same rows, so the two
        artifacts cannot disagree about what a run did.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$MigrationResults,
        [object[]]$SourceRules,
        [object[]]$SourceWorkbooks,
        [object[]]$SourceWatchlists
    )

    $ch = $MigrationResults.ContentHubResults

    return [ordered]@{
        'Summary'           = @(ConvertTo-SummaryRows -MigrationResults $MigrationResults)
        'Analytics Rules'   = @(ConvertTo-RuleResultRows -Results $MigrationResults.RuleResults -SourceRules $SourceRules)
        'Workbooks'         = @(ConvertTo-WorkbookResultRows -Results $MigrationResults.WorkbookResults)
        'Watchlists'        = @(ConvertTo-WatchlistResultRows -Results $MigrationResults.WatchlistResults)
        'Content Hub'       = @(ConvertTo-ContentHubRows -ContentHubResults $ch)
        'Manual Checklist'  = @(if ($ch) { ConvertTo-ChecklistRows -Checklist $ch.ManualChecklist })
        'Source Rules'      = @(ConvertTo-SourceRuleRows -Rules $SourceRules)
        'Source Workbooks'  = @(ConvertTo-SourceWorkbookRows -Workbooks $SourceWorkbooks)
        'Source Watchlists' = @(ConvertTo-SourceWatchlistRows -Watchlists $SourceWatchlists)
        'Errors'            = @(ConvertTo-ErrorRows -Errors $MigrationResults.Errors)
    }
}

function Export-AgentInput {
    <#
    .SYNOPSIS
        Writes agent-input.json: a projected evidence file an AI agent can consume.
    .DESCRIPTION
        Serialises the same $Sheets dictionary that builds the results workbook and
        the HTML drill-down, so an agent's numbers and the workbook's numbers agree
        by construction. Anyone verifying a generated report against the workbook
        would otherwise be comparing two independently derived answers.

        This is a projection, not an archive. The flatteners have already dropped
        the ARM envelope - resource IDs, etags, systemData, createdBy/updatedBy
        identities and raw watchlist rows - which is what takes a run from tens of
        megabytes down to something an agent can actually read, and stops customer
        identities being sent to a model. raw/_Full.json remains the complete record.

        Shape is deliberately flat: collections is a map of SheetName -> row[], and
        every row is a flat scalar object, so each collection loads into a DataFrame
        with no unnesting.
    .PARAMETER Sheets
        Ordered dictionary of SheetName -> row objects[]. The same one passed to
        Export-MigrationWorkbook.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Sheets,
        [Parameter(Mandatory)][string]$OutputDir,
        [System.Collections.IDictionary]$Scope,
        [System.Collections.IDictionary]$Kpis,
        [object[]]$NextSteps,
        [string]$Product = 'Microsoft Sentinel',
        [string]$Tool = 'Sentinel-Migration-Assistant',
        [string]$FileName = 'agent-input.json'
    )

    if (-not (Test-Path $OutputDir)) { New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null }

    $counts      = [ordered]@{}
    $collections = [ordered]@{}
    foreach ($name in @($Sheets.Keys)) {
        $rows = $Sheets[$name]
        if ($null -eq $rows) { $rows = @() }
        $counts[$name]      = @($rows).Count
        $collections[$name] = @($rows)
    }

    $scopeOut = [ordered]@{}
    if ($Scope) { foreach ($key in $Scope.Keys) { $scopeOut[$key] = $Scope[$key] } }

    $kpiOut = [ordered]@{}
    if ($Kpis) { foreach ($key in $Kpis.Keys) { $kpiOut[$key] = $Kpis[$key] } }

    $envelope = [ordered]@{
        schemaVersion    = 1
        tool             = $Tool
        product          = $Product
        generatedUtc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        scope            = $scopeOut
        kpis             = $kpiOut
        nextSteps        = @($NextSteps)
        collectionCounts = $counts
        collections      = $collections
    }

    # Compressed: the consumer is a parser, and it roughly halves the character
    # count, and so the size that has to be uploaded.
    $json = ConvertTo-Json -InputObject $envelope -Depth 20 -Compress
    $path = Join-Path $OutputDir $FileName
    Set-Content -Path $path -Value $json -Encoding UTF8

    $chars  = $json.Length
    $sizeKb = [math]::Round($chars / 1KB, 1)
    Write-ExportLog -Level 'Success' -Message "Agent input: $path ($sizeKb KB, $chars chars)"

    return $path
}

Export-ModuleMember -Function @(
    'Get-Prop'
    'Join-Values'
    'ConvertTo-ItemList'
    'Get-RuleCategory'
    'New-FullExportEnvelope'
    'Export-RawJson'
    'ConvertTo-RuleResultRows'
    'ConvertTo-WorkbookResultRows'
    'ConvertTo-WatchlistResultRows'
    'ConvertTo-ContentHubRows'
    'ConvertTo-ChecklistRows'
    'ConvertTo-ErrorRows'
    'ConvertTo-SourceRuleRows'
    'ConvertTo-SourceWorkbookRows'
    'ConvertTo-SourceWatchlistRows'
    'ConvertTo-SummaryRows'
    'Get-SafeSheetName'
    'Get-SafeTableName'
    'Test-ExportModuleAvailable'
    'Export-MigrationWorkbook'
    'New-MigrationSheets'
    'Export-AgentInput'
)
