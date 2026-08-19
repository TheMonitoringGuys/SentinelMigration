#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Core REST API wrapper for Microsoft Sentinel ARM calls.
.DESCRIPTION
    Provides authenticated, retry-aware, paginated REST calls against Azure Resource Manager
    for Microsoft Sentinel resources. Resolves ARM endpoints per cloud environment.
#>

Import-Module (Join-Path $PSScriptRoot 'Sentinel.Common.psm1') -Force -DisableNameChecking

# ── Runtime defaults ──────────────────────────────────────────────────────────
# Retry behaviour is configured once by the orchestrator rather than threaded
# through every call site in four modules. Callers may still override per-call.
$script:DefaultRetryCount = 3

function Set-SentinelApiDefault {
    <#
    .SYNOPSIS
        Sets module-wide API defaults from configuration.
    .DESCRIPTION
        Applies options.retryCount so the configured value actually reaches
        Invoke-SentinelApi. Previously the setting was parsed and stored but
        never passed anywhere, so raising it had no effect.
    #>
    [CmdletBinding()]
    param([int]$RetryCount = -1)

    if ($RetryCount -ge 0) { $script:DefaultRetryCount = $RetryCount }
}

function Get-SentinelApiDefault {
    <#
    .SYNOPSIS
        Returns the current module-wide API defaults. Primarily for tests.
    #>
    [CmdletBinding()]
    param()
    return [PSCustomObject]@{ RetryCount = $script:DefaultRetryCount }
}

# ── API Versions (documented/stable) ──────────────────────────────────────────
$script:ApiVersions = @{
    alertRules             = '2024-09-01'
    alertRuleTemplates     = '2024-09-01'
    workbooks              = '2022-04-01'
    watchlists             = '2024-09-01'
    watchlistItems         = '2024-09-01'
    contentPackages        = '2024-09-01'
    contentProductPackages = '2024-09-01'
    contentTemplates       = '2024-09-01'
}

function Get-SentinelApiVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Resource)
    if ($script:ApiVersions.ContainsKey($Resource)) {
        return $script:ApiVersions[$Resource]
    }
    throw "Unknown API resource '$Resource'. Known: $($script:ApiVersions.Keys -join ', ')"
}

# ── ARM Endpoint Resolution ───────────────────────────────────────────────────
function Resolve-ArmEndpoint {
    <#
    .SYNOPSIS
        Returns the ARM endpoint for the current Az context or specified cloud.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Commercial', 'Gov')]
        [string]$Cloud = 'Commercial'
    )

    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { throw "No Az context. Run Connect-AzAccount first." }

    $envName = $ctx.Environment.Name
    $env = Get-AzEnvironment -Name $envName -ErrorAction Stop
    if (-not $env) { throw "Cannot resolve Az environment '$envName'." }

    $endpoint = $env.ResourceManagerUrl.TrimEnd('/')
    Write-Verbose "ARM endpoint resolved: $endpoint (environment: $envName)"
    return $endpoint
}

# ── Token Acquisition ─────────────────────────────────────────────────────────
function Get-SentinelAccessToken {
    <#
    .SYNOPSIS
        Acquires a Bearer token for the ARM audience using the current Az context.
    #>
    [CmdletBinding()]
    param()

    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { throw "No Az context. Run Connect-AzAccount first." }

    $env = Get-AzEnvironment -Name $ctx.Environment.Name -ErrorAction Stop
    $resourceUrl = $env.ResourceManagerUrl.TrimEnd('/')

    $tokenObj = Get-AzAccessToken -ResourceUrl $resourceUrl -ErrorAction Stop
    if ($tokenObj.Token -is [securestring]) {
        return $tokenObj.Token | ConvertFrom-SecureString -AsPlainText
    }
    return $tokenObj.Token
}

# ── Core REST Invocation ──────────────────────────────────────────────────────
function Invoke-SentinelApi {
    <#
    .SYNOPSIS
        Authenticated ARM REST call with retry, backoff, pagination, and dry-run support.
    .PARAMETER Uri
        Full ARM URI including api-version query parameter.
    .PARAMETER Method
        HTTP method (GET, PUT, DELETE, PATCH).
    .PARAMETER Body
        Request body (will be serialized to JSON if a hashtable/PSObject).
    .PARAMETER DryRun
        If $true, write-changing methods (PUT/POST/DELETE/PATCH) are skipped and a simulated result is returned.
    .PARAMETER RetryCount
        Maximum number of retries on transient / throttle errors. Defaults to the
        module-wide value set by Set-SentinelApiDefault (from options.retryCount).
    .PARAMETER ThrottleDelayMs
        Base delay between requests in milliseconds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET','PUT','POST','DELETE','PATCH')]
        [string]$Method = 'GET',
        [object]$Body,
        [switch]$DryRun,
        [int]$RetryCount = -1,
        [int]$ThrottleDelayMs = 100
    )

    # -1 means "not specified by the caller", so the configured default applies.
    if ($RetryCount -lt 0) { $RetryCount = $script:DefaultRetryCount }

    $token = Get-SentinelAccessToken
    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
    }

    $writeMethods = @('PUT','POST','DELETE','PATCH')
    if ($DryRun -and $Method -in $writeMethods) {
        Write-Verbose "[DRY-RUN] Skipping $Method $Uri"
        return [PSCustomObject]@{
            DryRun     = $true
            Method     = $Method
            Uri        = $Uri
            Body       = $Body
            Simulated  = $true
        }
    }

    if ($ThrottleDelayMs -gt 0) {
        Start-Sleep -Milliseconds $ThrottleDelayMs
    }

    $bodyJson = $null
    if ($Body) {
        if ($Body -is [string]) { $bodyJson = $Body }
        else { $bodyJson = $Body | ConvertTo-Json -Depth 100 -Compress }
    }

    $attempt = 0
    $maxAttempts = $RetryCount + 1

    while ($attempt -lt $maxAttempts) {
        $attempt++
        try {
            $params = @{
                Uri     = $Uri
                Method  = $Method
                Headers = $headers
            }
            if ($bodyJson) { $params['Body'] = $bodyJson }

            $response = Invoke-RestMethod @params -ErrorAction Stop
            return $response
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            $retryable = $statusCode -in @(429, 500, 502, 503, 504)

            if ($retryable -and $attempt -lt $maxAttempts) {
                $backoff = [math]::Pow(2, $attempt) * 1000
                if ($statusCode -eq 429 -and $_.Exception.Response.Headers) {
                    $retryAfter = $_.Exception.Response.Headers | Where-Object { $_.Key -eq 'Retry-After' } | Select-Object -ExpandProperty Value -First 1
                    if ($retryAfter) { $backoff = [math]::Max($backoff, [int]$retryAfter * 1000) }
                }
                Write-Warning "Request failed (HTTP $statusCode), retrying in $($backoff/1000)s (attempt $attempt/$maxAttempts)..."
                Start-Sleep -Milliseconds $backoff
                # Refresh token in case it expired during backoff
                $token = Get-SentinelAccessToken
                $headers['Authorization'] = "Bearer $token"
            }
            else {
                # Enhance error with a readable ARM detail, but preserve 404s as-is
                # since callers catch those for existence checks.
                if ($statusCode -and $statusCode -ne 404) {
                    $detail = Format-ApiErrorDetail -ErrorRecord $_
                    if ($detail) {
                        throw "HTTP $statusCode on $Method $Uri - $detail"
                    }
                }
                throw
            }
        }
    }
}

# ── Paginated List ────────────────────────────────────────────────────────────
function Invoke-SentinelApiList {
    <#
    .SYNOPSIS
        GET with automatic nextLink pagination. Returns all items across pages.
    .DESCRIPTION
        Bounded by MaxRecords and MaxPages, and guarded against a self-referential
        nextLink, so a large or misbehaving collection cannot hang the migration.
    .PARAMETER MaxRecords
        Hard ceiling on returned items. 0 disables the ceiling.
    .PARAMETER MaxPages
        Hard ceiling on pages fetched.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$ThrottleDelayMs = 100,
        [int]$MaxRecords = 50000,
        [int]$MaxPages = 1000
    )

    $allItems = [System.Collections.Generic.List[object]]::new()
    $currentUri = $Uri
    $pages = 0
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    while ($currentUri) {
        # A nextLink that points back at a page already fetched would loop forever.
        if (-not $seen.Add([string]$currentUri)) {
            Write-Warning "Repeated nextLink detected; stopping pagination for: $Uri"
            break
        }

        $response = Invoke-SentinelApi -Uri $currentUri -Method GET -ThrottleDelayMs $ThrottleDelayMs
        $pages++
        if ($response.value) {
            $allItems.AddRange(@($response.value))
        }

        if ($MaxRecords -gt 0 -and $allItems.Count -ge $MaxRecords) {
            while ($allItems.Count -gt $MaxRecords) { $allItems.RemoveAt($allItems.Count - 1) }
            Write-Warning "Reached MaxRecords ($MaxRecords); results truncated for: $Uri"
            break
        }
        if ($pages -ge $MaxPages) {
            Write-Warning "Reached MaxPages ($MaxPages); results truncated for: $Uri"
            break
        }

        $currentUri = $response.nextLink
    }

    return $allItems.ToArray()
}

# ── URI Builders ──────────────────────────────────────────────────────────────
function Get-SentinelWorkspaceUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArmEndpoint,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$WorkspaceName
    )
    return "$ArmEndpoint/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName"
}

function Get-AlertRulesUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri
    )
    $v = Get-SentinelApiVersion -Resource 'alertRules'
    return "$WorkspaceUri/providers/Microsoft.SecurityInsights/alertRules?api-version=$v"
}

function Get-AlertRuleUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri,
        [Parameter(Mandatory)][string]$RuleId
    )
    $v = Get-SentinelApiVersion -Resource 'alertRules'
    return "$WorkspaceUri/providers/Microsoft.SecurityInsights/alertRules/$($RuleId)?api-version=$v"
}

function Get-AlertRuleTemplatesUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri
    )
    $v = Get-SentinelApiVersion -Resource 'alertRuleTemplates'
    return "$WorkspaceUri/providers/Microsoft.SecurityInsights/alertRuleTemplates?api-version=$v"
}

function Get-WorkbooksUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArmEndpoint,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [string]$SourceId
    )
    $v = Get-SentinelApiVersion -Resource 'workbooks'
    $uri = "$ArmEndpoint/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/workbooks?category=sentinel&canFetchContent=true&api-version=$v"
    if ($SourceId) {
        $uri += "&sourceId=$([Uri]::EscapeDataString($SourceId))"
    }
    return $uri
}

function Get-WorkbookUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArmEndpoint,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$WorkbookId
    )
    $v = Get-SentinelApiVersion -Resource 'workbooks'
    return "$ArmEndpoint/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/workbooks/$($WorkbookId)?api-version=$v"
}

function Get-ContentPackagesUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri
    )
    $v = Get-SentinelApiVersion -Resource 'contentPackages'
    return "$WorkspaceUri/providers/Microsoft.SecurityInsights/contentPackages?api-version=$v"
}

function Get-ContentProductPackagesUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri
    )
    $v = Get-SentinelApiVersion -Resource 'contentProductPackages'
    return "$WorkspaceUri/providers/Microsoft.SecurityInsights/contentProductPackages?api-version=$v"
}

function Get-ContentPackageUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri,
        [Parameter(Mandatory)][string]$PackageId
    )
    $v = Get-SentinelApiVersion -Resource 'contentPackages'
    return "$WorkspaceUri/providers/Microsoft.SecurityInsights/contentPackages/$($PackageId)?api-version=$v"
}

function Get-ContentTemplateUri {
    <#
    .SYNOPSIS
        URI for a workspace's Content Hub templates.
    .DESCRIPTION
        This is the only endpoint that ties an analytics rule template to the solution
        that ships it. The legacy alertRuleTemplates endpoint returns the rule's content
        but carries no package identity at all, so it cannot answer "which solution does
        this rule come from?".
    .PARAMETER ContentKind
        Server-side filter, e.g. 'AnalyticsRule'. A workspace's template collection spans
        every content kind, so filtering keeps the response to the part we use.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri,
        [string]$ContentKind
    )
    $v = Get-SentinelApiVersion -Resource 'contentTemplates'
    $uri = "$WorkspaceUri/providers/Microsoft.SecurityInsights/contentTemplates?api-version=$v"
    if (-not [string]::IsNullOrWhiteSpace($ContentKind)) {
        $uri += '&$filter=' + [uri]::EscapeDataString("properties/contentKind eq '$ContentKind'")
    }
    return $uri
}

# ── Watchlist URI Builders ────────────────────────────────────────────────────
function Get-WatchlistsUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri
    )
    $v = Get-SentinelApiVersion -Resource 'watchlists'
    return "$WorkspaceUri/providers/Microsoft.SecurityInsights/watchlists?api-version=$v"
}

function Get-WatchlistUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri,
        [Parameter(Mandatory)][string]$WatchlistAlias
    )
    $v = Get-SentinelApiVersion -Resource 'watchlists'
    return "$WorkspaceUri/providers/Microsoft.SecurityInsights/watchlists/$($WatchlistAlias)?api-version=$v"
}

function Get-WatchlistItemsUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri,
        [Parameter(Mandatory)][string]$WatchlistAlias
    )
    $v = Get-SentinelApiVersion -Resource 'watchlistItems'
    return "$WorkspaceUri/providers/Microsoft.SecurityInsights/watchlists/$($WatchlistAlias)/watchlistItems?api-version=$v"
}

Export-ModuleMember -Function @(
    'Get-SentinelApiVersion'
    'Set-SentinelApiDefault'
    'Get-SentinelApiDefault'
    'Resolve-ArmEndpoint'
    'Get-SentinelAccessToken'
    'Invoke-SentinelApi'
    'Invoke-SentinelApiList'
    'Get-SentinelWorkspaceUri'
    'Get-AlertRulesUri'
    'Get-AlertRuleUri'
    'Get-AlertRuleTemplatesUri'
    'Get-WorkbooksUri'
    'Get-WorkbookUri'
    'Get-ContentPackagesUri'
    'Get-ContentProductPackagesUri'
    'Get-ContentPackageUri'
    'Get-ContentTemplateUri'
    'Get-WatchlistsUri'
    'Get-WatchlistUri'
    'Get-WatchlistItemsUri'
)
