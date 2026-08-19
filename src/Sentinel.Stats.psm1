<#
.SYNOPSIS
    Table statistics helpers for Sentinel analytics rule coverage reporting.
.DESCRIPTION
    Adds optional Log Analytics data-plane checks and pure KQL/rule coverage helpers so
    migrated rules can be reported as referencing populated, empty, or unknown tables.
#>

Import-Module (Join-Path $PSScriptRoot 'Sentinel.Common.psm1') -Force -DisableNameChecking

$script:KqlKeywordSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@(
    'where', 'project', 'project-away', 'project-keep', 'project-rename', 'summarize', 'extend',
    'join', 'union', 'let', 'datatable', 'print', 'range', 'materialize', 'take', 'limit', 'sort',
    'order', 'top', 'distinct', 'count', 'mv-expand', 'mv', 'parse', 'evaluate', 'invoke', 'on',
    'kind', 'hint', 'by', 'asc', 'desc', 'as', 'and', 'or', 'not', 'in', 'contains', 'has',
    'startswith', 'endswith', 'between', 'ago', 'datetime', 'bin', 'iff', 'case', 'true', 'false',
    'withsource', 'isfuzzy', 'inner', 'leftouter', 'rightouter', 'fullouter', 'innerunique',
    'lookup', 'search', 'find', 'facet', 'make-series', 'partition', 'serialize', 'getschema',
    'render', 'scan', 'reduce', 'sample', 'sample-distinct', 'fork'
) | ForEach-Object { [void]$script:KqlKeywordSet.Add($_) }

function Remove-KqlLineComment {
    param([string]$Query)

    if ([string]::IsNullOrWhiteSpace($Query)) { return '' }
    $lines = $Query -split "`r?`n"
    $clean = foreach ($line in $lines) {
        $line -replace '//.*$', ''
    }
    return ($clean -join "`n")
}

function Test-KqlTableCandidate {
    param(
        [string]$Name,
        [System.Collections.Generic.HashSet[string]]$LetNames
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { return $false }
    if ($script:KqlKeywordSet.Contains($Name)) { return $false }
    if ($LetNames -and $LetNames.Contains($Name)) { return $false }
    return $true
}

function Add-KqlTableCandidate {
    param(
        [string]$Name,
        [System.Collections.Generic.List[string]]$Tables,
        [System.Collections.Generic.HashSet[string]]$Seen,
        [System.Collections.Generic.HashSet[string]]$LetNames
    )

    if ((Test-KqlTableCandidate -Name $Name -LetNames $LetNames) -and $Seen.Add($Name)) {
        $Tables.Add($Name)
    }
}

function Get-ObjectPathValue {
    param(
        [object]$Object,
        [Parameter(Mandatory)][string]$Path,
        [object]$Default = $null
    )

    $current = $Object
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $Default }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $Default }
            $current = $current[$segment]
            continue
        }
        $member = $current.PSObject.Properties[$segment]
        if ($null -eq $member) { return $Default }
        $current = $member.Value
    }

    if ($null -eq $current) { return $Default }
    return $current
}

function Resolve-LogAnalyticsDataEndpoint {
    param(
        [ValidateSet('Commercial', 'Gov')]
        [string]$Cloud = 'Commercial'
    )

    if ($Cloud -eq 'Gov') { return 'https://api.loganalytics.us' }
    return 'https://api.loganalytics.io'
}

function Invoke-LogAnalyticsQuery {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$ResourceUrl,
        [int]$ThrottleDelayMs = 100
    )

    if ($ThrottleDelayMs -gt 0) {
        Start-Sleep -Milliseconds $ThrottleDelayMs
    }

    $tokenObject = Get-AzAccessToken -ResourceUrl $ResourceUrl -ErrorAction Stop
    $token = if ($tokenObject.Token -is [securestring]) {
        $tokenObject.Token | ConvertFrom-SecureString -AsPlainText
    }
    else {
        $tokenObject.Token
    }

    $body = @{ query = $Query } | ConvertTo-Json -Depth 10 -Compress
    Invoke-RestMethod -Uri $Uri -Method POST -Headers @{
        Authorization = "Bearer $token"
        'Content-Type' = 'application/json'
    } -Body $body -ErrorAction Stop
}

function Get-KqlReferencedTable {
    <#
    .SYNOPSIS
        Returns distinct Log Analytics table names referenced by a KQL query.
    .DESCRIPTION
        Performs lightweight string parsing for common analytics-rule KQL shapes,
        including leading sources, union inputs, join subqueries, and let right-hand
        sides. It does not call Azure and is intended for unit-testable reporting logic.
    #>
    [CmdletBinding()]
    param([string]$Query)

    if ([string]::IsNullOrWhiteSpace($Query)) { return @() }

    $text = Remove-KqlLineComment -Query $Query
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }

    $tables = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $letNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    <#
    Let names are local aliases, not workspace tables; their right-hand sides are
    still parsed because those expressions often contain the actual source table.
    #>
    foreach ($match in [regex]::Matches($text, '(?im)\blet\s+([A-Za-z][A-Za-z0-9_]*)\s=')) {
        [void]$letNames.Add($match.Groups[1].Value)
    }

    foreach ($match in [regex]::Matches($text, '(?ims)\blet\s+[A-Za-z][A-Za-z0-9_]*\s*=\s*([A-Za-z][A-Za-z0-9_]*)\b')) {
        Add-KqlTableCandidate -Name $match.Groups[1].Value -Tables $tables -Seen $seen -LetNames $letNames
    }

    foreach ($match in [regex]::Matches($text, '(?im)(?:^|;)\s*([A-Za-z][A-Za-z0-9_]*)\b')) {
        Add-KqlTableCandidate -Name $match.Groups[1].Value -Tables $tables -Seen $seen -LetNames $letNames
    }

    foreach ($match in [regex]::Matches($text, '(?im)\(\s*([A-Za-z][A-Za-z0-9_]*)\b')) {
        Add-KqlTableCandidate -Name $match.Groups[1].Value -Tables $tables -Seen $seen -LetNames $letNames
    }

    foreach ($match in [regex]::Matches($text, '(?ims)\bunion\b(?<tail>[\s\S]*?)(?=\||;|\)|$)')) {
        $tail = $match.Groups['tail'].Value
        $tail = $tail -replace '(?i)\b(?:withsource|isfuzzy|kind|hint\.[A-Za-z0-9_]+)\s*=\s*[A-Za-z0-9_]+', ' '
        foreach ($token in [regex]::Matches($tail, '\b[A-Za-z][A-Za-z0-9_]*\b')) {
            Add-KqlTableCandidate -Name $token.Value -Tables $tables -Seen $seen -LetNames $letNames
        }
    }

    return @($tables.ToArray())
}

function Get-WorkspaceTableStat {
    <#
    .SYNOPSIS
        Gets row-count statistics for target workspace tables over a lookback window.
    .DESCRIPTION
        Queries the Log Analytics data-plane API with one batched union query and
        returns advisory table data status objects. Failures are converted into
        per-table unknown results so missing data-plane permissions cannot fail a migration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string[]]$TableName,
        [int]$LookbackDays = 7,
        [int]$ThrottleDelayMs = 100,
        [ValidateSet('Commercial', 'Gov')]
        [string]$Cloud = 'Commercial'
    )

    $tables = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($table in (ConvertTo-SafeArray $TableName)) {
        $name = [string]$table
        if ($name -match '^[A-Za-z][A-Za-z0-9_]*$' -and $seen.Add($name)) {
            $tables.Add($name)
        }
    }

    if ($tables.Count -eq 0) { return @() }

    $endpoint = Resolve-LogAnalyticsDataEndpoint -Cloud $Cloud
    $workspacePart = [Uri]::EscapeDataString($WorkspaceId)
    $uri = "$endpoint/v1/workspaces/$workspacePart/query"

    <#
    isfuzzy=true keeps one absent table from failing the entire advisory batch.
    The migration result must remain authoritative even when these stats cannot be gathered.
    #>
    $query = "union withsource=_TableName_ isfuzzy=true $($tables.ToArray() -join ', ') | where TimeGenerated > ago($($LookbackDays)d) | summarize Rows=count() by _TableName_"

    try {
        $response = Invoke-LogAnalyticsQuery -Uri $uri -Query $query -ResourceUrl $endpoint -ThrottleDelayMs $ThrottleDelayMs
        $rowCounts = @{}
        $firstTable = $null
        if ($response -and $response.tables) { $firstTable = @($response.tables)[0] }

        if ($firstTable -and $firstTable.columns -and $firstTable.rows) {
            $nameIndex = -1
            $rowsIndex = -1
            for ($i = 0; $i -lt @($firstTable.columns).Count; $i++) {
                $columnName = [string]$firstTable.columns[$i].name
                if ($columnName -eq '_TableName_') { $nameIndex = $i }
                if ($columnName -eq 'Rows') { $rowsIndex = $i }
            }

            if ($nameIndex -ge 0 -and $rowsIndex -ge 0) {
                foreach ($row in @($firstTable.rows)) {
                    $sourceName = [string]$row[$nameIndex]
                    if (-not [string]::IsNullOrWhiteSpace($sourceName)) {
                        $rowCounts[$sourceName] = [long]$row[$rowsIndex]
                    }
                }
            }
        }

        $result = foreach ($table in $tables) {
            $count = if ($rowCounts.ContainsKey($table)) { [long]$rowCounts[$table] } else { [long]0 }
            [PSCustomObject][ordered]@{
                TableName    = $table
                RowCount     = $count
                HasData      = ($count -gt 0)
                LookbackDays = $LookbackDays
            }
        }
        return @($result)
    }
    catch {
        $detail = Format-ApiErrorDetail -ErrorRecord $_
        $result = foreach ($table in $tables) {
            [PSCustomObject][ordered]@{
                TableName    = $table
                RowCount     = [long]-1
                HasData      = $false
                LookbackDays = $LookbackDays
                Note         = "Log Analytics query failed: $detail"
            }
        }
        return @($result)
    }
}

function Get-RuleTableCoverage {
    <#
    .SYNOPSIS
        Builds flat per-rule table coverage rows from rule definitions and table stats.
    .DESCRIPTION
        Extracts each rule query, resolves referenced tables, and joins those tables
        to advisory workspace statistics. The output uses scalar fields suitable for
        CSV or spreadsheet export.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Rules,
        [object[]]$TableStats
    )

    $statsByName = @{}
    foreach ($stat in (ConvertTo-SafeArray $TableStats)) {
        $name = [string](Get-ObjectPathValue -Object $stat -Path 'TableName')
        if (-not [string]::IsNullOrWhiteSpace($name) -and -not $statsByName.ContainsKey($name)) {
            $statsByName[$name] = $stat
        }
    }

    $rows = foreach ($rule in (ConvertTo-SafeArray $Rules)) {
        $ruleName = [string](Get-ObjectPathValue -Object $rule -Path 'properties.displayName')
        $ruleId = [string](Get-ObjectPathValue -Object $rule -Path 'name')
        if ([string]::IsNullOrWhiteSpace($ruleName)) { $ruleName = $ruleId }
        $query = [string](Get-ObjectPathValue -Object $rule -Path 'properties.query')

        if ([string]::IsNullOrWhiteSpace($query)) {
            [PSCustomObject][ordered]@{
                RuleName        = $ruleName
                RuleId          = $ruleId
                Tables          = ''
                TablesWithData  = 0
                TablesEmpty     = 0
                TablesUnknown   = 0
                EmptyTableNames = ''
                Status          = 'NoQuery'
            }
            continue
        }

        $tables = Get-KqlReferencedTable -Query $query
        $withData = 0
        $empty = 0
        $unknown = 0
        $emptyNames = [System.Collections.Generic.List[string]]::new()

        foreach ($table in $tables) {
            if (-not $statsByName.ContainsKey($table)) {
                $unknown++
                continue
            }

            $stat = $statsByName[$table]
            $rowCount = Get-ObjectPathValue -Object $stat -Path 'RowCount' -Default $null
            if ($null -eq $rowCount -or [long]$rowCount -lt 0) {
                $unknown++
            }
            elseif ([long]$rowCount -gt 0 -or [bool](Get-ObjectPathValue -Object $stat -Path 'HasData' -Default $false)) {
                $withData++
            }
            else {
                $empty++
                $emptyNames.Add($table)
            }
        }

        $status = if ($tables.Count -eq 0 -or $unknown -gt 0) {
            'Unknown'
        }
        elseif ($withData -eq $tables.Count) {
            'Ready'
        }
        elseif ($withData -eq 0) {
            'NoData'
        }
        else {
            'PartialData'
        }

        [PSCustomObject][ordered]@{
            RuleName        = $ruleName
            RuleId          = $ruleId
            Tables          = ($tables -join '; ')
            TablesWithData  = $withData
            TablesEmpty     = $empty
            TablesUnknown   = $unknown
            EmptyTableNames = ($emptyNames.ToArray() -join '; ')
            Status          = $status
        }
    }

    return @($rows)
}

Export-ModuleMember -Function @(
    'Get-KqlReferencedTable',
    'Get-WorkspaceTableStat',
    'Get-RuleTableCoverage'
)
