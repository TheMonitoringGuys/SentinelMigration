<#
.SYNOPSIS
    Watchlist discovery and migration for Microsoft Sentinel.
.DESCRIPTION
    Enumerates watchlists and their items from the source workspace,
    exports their definitions, and recreates them in the target workspace
    using bulk CSV upload via rawContent.
#>

Import-Module (Join-Path $PSScriptRoot 'Sentinel.Common.psm1') -Force -DisableNameChecking

# ── Discovery ─────────────────────────────────────────────────────────────────
function Get-SourceWatchlists {
    <#
    .SYNOPSIS
        Lists all Sentinel watchlists in the source workspace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceWorkspaceUri,
        [int]$ThrottleDelayMs = 100
    )

    $uri = Get-WatchlistsUri -WorkspaceUri $SourceWorkspaceUri
    Write-Host "  Fetching watchlists from source..." -ForegroundColor Cyan
    $watchlists = Invoke-SentinelApiList -Uri $uri -ThrottleDelayMs $ThrottleDelayMs
    Write-Host "  Found $($watchlists.Count) watchlist(s)" -ForegroundColor Cyan
    return $watchlists
}

function Get-WatchlistItems {
    <#
    .SYNOPSIS
        Fetches all items for a given watchlist via paginated GET.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri,
        [Parameter(Mandatory)][string]$WatchlistAlias,
        [int]$ThrottleDelayMs = 100
    )

    $uri = Get-WatchlistItemsUri -WorkspaceUri $WorkspaceUri -WatchlistAlias $WatchlistAlias
    return Invoke-SentinelApiList -Uri $uri -ThrottleDelayMs $ThrottleDelayMs
}

# ── Export ────────────────────────────────────────────────────────────────────
function Export-WatchlistDefinition {
    <#
    .SYNOPSIS
        Extracts a portable watchlist definition for recreation in another workspace.
    .DESCRIPTION
        Strips read-only / audit properties and preserves the metadata needed
        for a PUT to the target workspace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Watchlist
    )

    $props = $Watchlist.properties | ConvertTo-Json -Depth 100 | ConvertFrom-Json

    # Remove read-only / audit properties that the target API will set
    $readOnlyProps = @(
        'watchlistId', 'tenantId', 'created', 'updated',
        'createdBy', 'updatedBy', 'uploadStatus', 'provisioningState',
        'isDeleted'
    )
    foreach ($p in $readOnlyProps) {
        if ($props.PSObject.Properties[$p]) {
            $props.PSObject.Properties.Remove($p)
        }
    }

    return $props
}

function ConvertTo-WatchlistCsv {
    <#
    .SYNOPSIS
        Converts watchlist items (from API) into a CSV string for rawContent bulk upload.
    .DESCRIPTION
        Reads the itemsKeyValue dictionary from each item and produces a standard CSV
        with a header row derived from the first item's keys.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items
    )

    if ($Items.Count -eq 0) { return '' }

    # Get column headers from the first item
    $firstItem = $Items[0].properties.itemsKeyValue
    $headers = @()
    if ($firstItem -is [hashtable]) {
        $headers = @($firstItem.Keys)
    }
    else {
        $headers = @($firstItem.PSObject.Properties.Name)
    }

    $sb = [System.Text.StringBuilder]::new()

    # Header row
    [void]$sb.AppendLine(($headers | ForEach-Object { ConvertTo-CsvField $_ }) -join ',')

    # Data rows
    foreach ($item in $Items) {
        $kv = $item.properties.itemsKeyValue
        $values = foreach ($h in $headers) {
            $val = if ($kv -is [hashtable]) { $kv[$h] } else { $kv.$h }
            ConvertTo-CsvField $val
        }
        [void]$sb.AppendLine($values -join ',')
    }

    return $sb.ToString().TrimEnd("`r", "`n")
}

function ConvertTo-CsvField {
    <#
    .SYNOPSIS
        Escapes a single CSV field value (quotes if it contains comma, quote, or newline).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()]
        [Parameter(Position = 0)][string]$Value
    )

    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    if ($s -match '[,"\r\n]') {
        return '"' + ($s -replace '"', '""') + '"'
    }
    return $s
}

# ── Migration ─────────────────────────────────────────────────────────────────
function Import-Watchlist {
    <#
    .SYNOPSIS
        Creates or updates a single watchlist in the target workspace, including items.
    .DESCRIPTION
        Fetches all items from the source, converts to CSV rawContent, and PUTs the
        watchlist to the target workspace using the same alias for idempotency.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceWorkspaceUri,
        [Parameter(Mandatory)][string]$TargetWorkspaceUri,
        [Parameter(Mandatory)][object]$Watchlist,
        [switch]$DryRun,
        [switch]$OverwriteExisting,
        [int]$ThrottleDelayMs = 100
    )

    $alias = $Watchlist.properties.watchlistAlias
    if (-not $alias) { $alias = $Watchlist.name }
    $displayName = $Watchlist.properties.displayName

    $watchlistUri = Get-WatchlistUri -WorkspaceUri $TargetWorkspaceUri -WatchlistAlias $alias

    # Check for existing
    $existing = $null
    try {
        $existing = Invoke-SentinelApi -Uri $watchlistUri -Method GET -ThrottleDelayMs $ThrottleDelayMs
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($statusCode -ne 404) { throw }
    }

    if ($existing -and -not $OverwriteExisting) {
        return [PSCustomObject]@{
            Action         = 'Skipped'
            WatchlistAlias = $alias
            DisplayName    = $displayName
            ItemCount      = 0
            Reason         = 'Watchlist already exists in target and -OverwriteExisting not set'
        }
    }

    $action = if ($existing) { 'Updated' } else { 'Created' }

    # Fetch items from source
    $items = @()
    try {
        $items = @(Get-WatchlistItems -WorkspaceUri $SourceWorkspaceUri `
            -WatchlistAlias $alias -ThrottleDelayMs $ThrottleDelayMs)
    }
    catch {
        Write-Warning "    Could not fetch items for watchlist '$alias': $($_.Exception.Message)"
    }

    # Build the PUT body
    $definition = Export-WatchlistDefinition -Watchlist $Watchlist

    $body = @{
        properties = @{
            displayName       = $definition.displayName
            provider          = if ($definition.provider) { $definition.provider } else { 'Microsoft' }
            itemsSearchKey    = $definition.itemsSearchKey
            source            = if ($definition.source) { $definition.source } else { 'migration.csv' }
            watchlistAlias    = $alias
        }
    }

    if ($definition.description) { $body.properties['description'] = $definition.description }
    if ($definition.labels) { $body.properties['labels'] = $definition.labels }
    if ($definition.defaultDuration) { $body.properties['defaultDuration'] = $definition.defaultDuration }
    if ($definition.watchlistType) { $body.properties['watchlistType'] = $definition.watchlistType }

    # Include items as rawContent CSV. sourceType 'Local' makes rawContent mandatory and
    # the API rejects a CSV with no data rows, so an empty source watchlist omits
    # sourceType entirely - that creates the watchlist with no items rather than failing.
    if ($items.Count -gt 0) {
        $body.properties['sourceType'] = 'Local'
        $body.properties['contentType'] = 'text/csv'
        $body.properties['rawContent'] = ConvertTo-WatchlistCsv -Items $items
        $body.properties['numberOfLinesToSkip'] = 0
    }

    try {
        $result = Invoke-SentinelApi -Uri $watchlistUri -Method PUT -Body $body `
            -DryRun:$DryRun -ThrottleDelayMs $ThrottleDelayMs

        if ($DryRun) { $action = "WouldBe$action" }

        return [PSCustomObject]@{
            Action         = $action
            WatchlistAlias = $alias
            DisplayName    = $displayName
            ItemCount      = $items.Count
            Reason         = $null
        }
    }
    catch {
        return [PSCustomObject]@{
            Action         = 'Failed'
            WatchlistAlias = $alias
            DisplayName    = $displayName
            ItemCount      = $items.Count
            Reason         = $_.Exception.Message
        }
    }
}

function Import-Watchlists {
    <#
    .SYNOPSIS
        Migrates all watchlists from source to target workspace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceWorkspaceUri,
        [Parameter(Mandatory)][string]$TargetWorkspaceUri,
        [Parameter(Mandatory)][object[]]$Watchlists,
        [switch]$DryRun,
        [switch]$OverwriteExisting,
        [int]$ThrottleDelayMs = 100
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $total = $Watchlists.Count
    $current = 0

    Write-Host "  Migrating $total watchlist(s)..." -ForegroundColor Cyan

    foreach ($wl in $Watchlists) {
        $current++
        $displayName = $wl.properties.displayName
        $alias = if ($wl.properties.watchlistAlias) { $wl.properties.watchlistAlias } else { $wl.name }
        Write-MigrationProgress -Activity 'Migrating Watchlists' -Status $displayName -Current $current -Total $total
        Write-Host "    [$current/$total] $displayName ($alias)" -ForegroundColor White -NoNewline

        $result = Import-Watchlist `
            -SourceWorkspaceUri $SourceWorkspaceUri `
            -TargetWorkspaceUri $TargetWorkspaceUri `
            -Watchlist $wl `
            -DryRun:$DryRun `
            -OverwriteExisting:$OverwriteExisting `
            -ThrottleDelayMs $ThrottleDelayMs

        $color = Get-ActionColor $result.Action
        $itemInfo = if ($result.ItemCount -gt 0) { " ($($result.ItemCount) items)" } else { '' }
        Write-Host " -> $(Format-ActionLabel $result.Action)$itemInfo" -ForegroundColor $color
        if ($result.Reason -and (Get-NormalizedAction $result.Action) -eq 'Failed') {
            Write-Host "      Error: $($result.Reason)" -ForegroundColor Red
        }

        $results.Add($result)
    }

    Write-MigrationProgress -Activity 'Migrating Watchlists' -Completed

    return $results.ToArray()
}

Export-ModuleMember -Function @(
    'Get-SourceWatchlists'
    'Get-WatchlistItems'
    'Export-WatchlistDefinition'
    'ConvertTo-WatchlistCsv'
    'Import-Watchlist'
    'Import-Watchlists'
)
