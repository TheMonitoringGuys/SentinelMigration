<#
.SYNOPSIS
    Workbook discovery and migration for Microsoft Sentinel.
.DESCRIPTION
    Enumerates workbooks from the source resource group (Sentinel category),
    exports their definitions, and recreates them in the target resource group.
#>

Import-Module (Join-Path $PSScriptRoot 'Sentinel.Common.psm1') -Force -DisableNameChecking

# ── Discovery ─────────────────────────────────────────────────────────────────
function Get-SourceWorkbooks {
    <#
    .SYNOPSIS
        Lists Sentinel workbooks in the source resource group scoped to a specific workspace.
    .DESCRIPTION
        Uses the sourceId query parameter to return only workbooks associated with the
        given workspace. This prevents picking up migration-created workbooks when source
        and target share the same resource group. Also filters out any workbook tagged
        with MigratedFromWorkbookId as a defensive measure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArmEndpoint,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$WorkspaceResourceId,
        [int]$ThrottleDelayMs = 100
    )

    $uri = Get-WorkbooksUri -ArmEndpoint $ArmEndpoint -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName -SourceId $WorkspaceResourceId
    Write-Host "  Fetching workbooks from source..." -ForegroundColor Cyan
    $workbooks = Invoke-SentinelApiList -Uri $uri -ThrottleDelayMs $ThrottleDelayMs

    # Defensive: exclude any workbooks created by a previous migration
    $workbooks = @($workbooks | Where-Object {
        -not ($_.tags -and $_.tags.MigratedFromWorkbookId)
    })

    Write-Host "  Found $($workbooks.Count) workbook(s)" -ForegroundColor Cyan
    return $workbooks
}

# ── Export ────────────────────────────────────────────────────────────────────
function Export-WorkbookDefinition {
    <#
    .SYNOPSIS
        Extracts a portable workbook definition for recreation in another resource group.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Workbook
    )

    $props = $Workbook.properties | ConvertTo-Json -Depth 100 | ConvertFrom-Json

    # Remove read-only properties
    $readOnlyProps = @('timeModified', 'userId', 'sourceId')
    foreach ($p in $readOnlyProps) {
        if ($props.PSObject.Properties[$p]) {
            $props.PSObject.Properties.Remove($p)
        }
    }

    return @{
        location   = $Workbook.location
        tags       = $Workbook.tags
        kind       = $Workbook.kind
        properties = $props
    }
}

function Get-WorkbookMigrationId {
    <#
    .SYNOPSIS
        Generates a deterministic workbook resource name for idempotent migration.
    .DESCRIPTION
        Uses a hash of the source workbook displayName to produce a stable GUID,
        ensuring re-runs target the same resource instead of creating duplicates.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Workbook
    )

    $displayName = $Workbook.properties.displayName
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        return [guid]::NewGuid().ToString()
    }

    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("sentinel-migration:$displayName")
    $hash = $md5.ComputeHash($bytes)
    return [guid]::new($hash).ToString()
}

# ── Migration ─────────────────────────────────────────────────────────────────
function Import-Workbook {
    <#
    .SYNOPSIS
        Creates or updates a single workbook in the target resource group.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArmEndpoint,
        [Parameter(Mandatory)][string]$TargetSubscriptionId,
        [Parameter(Mandatory)][string]$TargetResourceGroupName,
        [Parameter(Mandatory)][string]$TargetWorkspaceResourceId,
        [Parameter(Mandatory)][string]$TargetLocation,
        [Parameter(Mandatory)][object]$Workbook,
        [switch]$DryRun,
        [switch]$OverwriteExisting,
        [int]$ThrottleDelayMs = 100
    )

    $displayName = $Workbook.properties.displayName
    $workbookId = Get-WorkbookMigrationId -Workbook $Workbook
    $workbookUri = Get-WorkbookUri -ArmEndpoint $ArmEndpoint `
        -SubscriptionId $TargetSubscriptionId `
        -ResourceGroupName $TargetResourceGroupName `
        -WorkbookId $workbookId

    # Check for existing
    $existing = $null
    try {
        $existing = Invoke-SentinelApi -Uri $workbookUri -Method GET -ThrottleDelayMs $ThrottleDelayMs
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($statusCode -ne 404) { throw }
    }

    if ($existing -and -not $OverwriteExisting) {
        return [PSCustomObject]@{
            Action      = 'Skipped'
            WorkbookId  = $workbookId
            DisplayName = $displayName
            Reason      = 'Workbook already exists in target and -OverwriteExisting not set'
        }
    }

    $action = if ($existing) { 'Updated' } else { 'Created' }

    # Build the PUT body
    $definition = Export-WorkbookDefinition -Workbook $Workbook

    # Set sourceId to the target workspace (required by the workbooks API)
    if ($definition.properties.PSObject.Properties['sourceId']) {
        $definition.properties.sourceId = $TargetWorkspaceResourceId
    }
    else {
        $definition.properties | Add-Member -NotePropertyName 'sourceId' -NotePropertyValue $TargetWorkspaceResourceId
    }

    # Override location to match target
    $definition.location = $TargetLocation

    # Add migration tracking tag
    $tags = @{}
    if ($definition.tags) {
        if ($definition.tags -is [hashtable]) { $tags = $definition.tags.Clone() }
        else {
            $definition.tags.PSObject.Properties | ForEach-Object { $tags[$_.Name] = $_.Value }
        }
    }
    $sourceId = $Workbook.name
    $tags['MigratedFromWorkbookId'] = $sourceId
    $tags['hidden-title'] = $displayName

    $body = @{
        location   = $definition.location
        tags       = $tags
        kind       = if ($definition.kind) { $definition.kind } else { 'shared' }
        properties = $definition.properties
    }

    try {
        $result = Invoke-SentinelApi -Uri $workbookUri -Method PUT -Body $body `
            -DryRun:$DryRun -ThrottleDelayMs $ThrottleDelayMs

        if ($DryRun) { $action = "WouldBe$action" }

        return [PSCustomObject]@{
            Action      = $action
            WorkbookId  = $workbookId
            DisplayName = $displayName
            Reason      = $null
        }
    }
    catch {
        return [PSCustomObject]@{
            Action      = 'Failed'
            WorkbookId  = $workbookId
            DisplayName = $displayName
            Reason      = $_.Exception.Message
        }
    }
}

function Import-Workbooks {
    <#
    .SYNOPSIS
        Migrates all workbooks from source to target.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArmEndpoint,
        [Parameter(Mandatory)][string]$TargetSubscriptionId,
        [Parameter(Mandatory)][string]$TargetResourceGroupName,
        [Parameter(Mandatory)][string]$TargetWorkspaceResourceId,
        [Parameter(Mandatory)][string]$TargetLocation,
        [Parameter(Mandatory)][object[]]$Workbooks,
        [switch]$DryRun,
        [switch]$OverwriteExisting,
        [int]$ThrottleDelayMs = 100
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $total = $Workbooks.Count
    $current = 0

    Write-Host "  Migrating $total workbook(s)..." -ForegroundColor Cyan

    foreach ($wb in $Workbooks) {
        $current++
        $displayName = $wb.properties.displayName
        Write-MigrationProgress -Activity 'Migrating Workbooks' -Status $displayName -Current $current -Total $total
        Write-Host "    [$current/$total] $displayName" -ForegroundColor White -NoNewline

        $result = Import-Workbook `
            -ArmEndpoint $ArmEndpoint `
            -TargetSubscriptionId $TargetSubscriptionId `
            -TargetResourceGroupName $TargetResourceGroupName `
            -TargetWorkspaceResourceId $TargetWorkspaceResourceId `
            -TargetLocation $TargetLocation `
            -Workbook $wb `
            -DryRun:$DryRun `
            -OverwriteExisting:$OverwriteExisting `
            -ThrottleDelayMs $ThrottleDelayMs

        $color = Get-ActionColor $result.Action
        Write-Host " -> $(Format-ActionLabel $result.Action)" -ForegroundColor $color
        if ($result.Reason -and (Get-NormalizedAction $result.Action) -eq 'Failed') {
            Write-Host "      Error: $($result.Reason)" -ForegroundColor Red
        }

        $results.Add($result)
    }

    Write-MigrationProgress -Activity 'Migrating Workbooks' -Completed

    return $results.ToArray()
}

# ── Target workspace location resolver ────────────────────────────────────────
function Get-WorkspaceLocation {
    <#
    .SYNOPSIS
        Queries the ARM API for a workspace resource to retrieve its location.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri,
        [int]$ThrottleDelayMs = 100
    )

    $uri = "$WorkspaceUri`?api-version=2023-09-01"
    $ws = Invoke-SentinelApi -Uri $uri -Method GET -ThrottleDelayMs $ThrottleDelayMs
    return $ws.location
}

Export-ModuleMember -Function @(
    'Get-SourceWorkbooks'
    'Export-WorkbookDefinition'
    'Get-WorkbookMigrationId'
    'Import-Workbook'
    'Import-Workbooks'
    'Get-WorkspaceLocation'
)
