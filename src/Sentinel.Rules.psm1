<#
.SYNOPSIS
    Analytics rule discovery and migration for Microsoft Sentinel.
.DESCRIPTION
    Enumerates source rules, classifies them (template-based vs custom, enabled vs disabled),
    and replicates them into the target workspace via the alertRules REST API.
#>

Import-Module (Join-Path $PSScriptRoot 'Sentinel.Common.psm1') -Force -DisableNameChecking

# ── Discovery ─────────────────────────────────────────────────────────────────
function Get-SourceAnalyticsRules {
    <#
    .SYNOPSIS
        Enumerates all analytics rules from the source workspace and classifies them.
    .OUTPUTS
        PSCustomObject with TemplateRulesEnabled, TemplateRulesDisabled,
        CustomRulesEnabled, CustomRulesDisabled, All.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri,
        [int]$ThrottleDelayMs = 100
    )

    $uri = Get-AlertRulesUri -WorkspaceUri $WorkspaceUri
    Write-Host "  Fetching analytics rules from source..." -ForegroundColor Cyan
    $rules = Invoke-SentinelApiList -Uri $uri -ThrottleDelayMs $ThrottleDelayMs

    Write-Host "  Found $($rules.Count) analytics rule(s)" -ForegroundColor Cyan

    $classified = @{
        TemplateRulesEnabled  = [System.Collections.Generic.List[object]]::new()
        TemplateRulesDisabled = [System.Collections.Generic.List[object]]::new()
        CustomRulesEnabled    = [System.Collections.Generic.List[object]]::new()
        CustomRulesDisabled   = [System.Collections.Generic.List[object]]::new()
        All                   = $rules
    }

    foreach ($rule in $rules) {
        $props = $rule.properties
        $templateName = $props.alertRuleTemplateName
        $isTemplateBased = -not [string]::IsNullOrWhiteSpace($templateName)
        $isEnabled = ($props.enabled -eq $true)

        if ($isTemplateBased) {
            if ($isEnabled) { $classified.TemplateRulesEnabled.Add($rule) }
            else            { $classified.TemplateRulesDisabled.Add($rule) }
        }
        else {
            if ($isEnabled) { $classified.CustomRulesEnabled.Add($rule) }
            else            { $classified.CustomRulesDisabled.Add($rule) }
        }
    }

    Write-Host "  Classification:" -ForegroundColor Cyan
    Write-Host "    Template-based enabled:  $($classified.TemplateRulesEnabled.Count)" -ForegroundColor Green
    Write-Host "    Template-based disabled: $($classified.TemplateRulesDisabled.Count)" -ForegroundColor DarkGray
    Write-Host "    Custom enabled:          $($classified.CustomRulesEnabled.Count)" -ForegroundColor Green
    Write-Host "    Custom disabled:         $($classified.CustomRulesDisabled.Count)" -ForegroundColor DarkGray

    return [PSCustomObject]$classified
}

function Get-SourceAlertRuleTemplates {
    <#
    .SYNOPSIS
        Lists all alert rule templates from the source workspace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri,
        [int]$ThrottleDelayMs = 100
    )

    $uri = Get-AlertRuleTemplatesUri -WorkspaceUri $WorkspaceUri
    Write-Host "  Fetching alert rule templates from source..." -ForegroundColor Cyan
    $templates = Invoke-SentinelApiList -Uri $uri -ThrottleDelayMs $ThrottleDelayMs
    Write-Host "  Found $($templates.Count) alert rule template(s)" -ForegroundColor Cyan
    return $templates
}

# ── Rule Export ───────────────────────────────────────────────────────────────
function ConvertTo-UniqueEntityMapping {
    <#
    .SYNOPSIS
        Removes exact duplicate entity mappings, preserving original order.
    .DESCRIPTION
        Sentinel caps entityMappings (5 at time of writing) and counts duplicates
        towards that cap, so a source rule carrying the same mapping twice can be
        rejected outright. Two mappings are considered identical when they share an
        entity type and the same set of identifier/column pairs; field order within
        a mapping is not significant, so the key is built from a sorted pair list.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EntityMappings
    )

    $seen = @{}
    $unique = [System.Collections.Generic.List[object]]::new()

    foreach ($mapping in $EntityMappings) {
        if ($null -eq $mapping) { continue }

        $pairs = @()
        if ($mapping.fieldMappings) {
            $pairs = @($mapping.fieldMappings | ForEach-Object {
                '{0}={1}' -f $_.identifier, $_.columnName
            } | Sort-Object)
        }
        $key = '{0}|{1}' -f $mapping.entityType, ($pairs -join ';')

        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique.Add($mapping)
        }
    }

    return $unique.ToArray()
}

function Export-RuleDefinition {
    <#
    .SYNOPSIS
        Extracts a portable rule definition from a source rule, suitable for CreateOrUpdate on target.
    .DESCRIPTION
        Strips source-specific resource IDs and retains the rule kind and properties needed
        to recreate the rule in another workspace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Rule
    )

    $kind = $rule.kind
    $props = $rule.properties | ConvertTo-Json -Depth 100 | ConvertFrom-Json

    # An exact duplicate entity mapping is meaningless to Sentinel but still counts
    # against the API's cap, so drop duplicates before they can push a rule over it.
    if ($props.PSObject.Properties['entityMappings'] -and $props.entityMappings) {
        $props.entityMappings = @(ConvertTo-UniqueEntityMapping -EntityMappings @($props.entityMappings))
    }

    # Remove read-only / source-specific properties
    $readOnlyProps = @('lastModifiedUtc', 'createdDateUtc', 'lastExecutionUtc',
                       'nextExecutionUtc', 'incidentConfiguration')

    # Fusion rules have additional read-only properties
    if ($kind -eq 'Fusion') {
        $readOnlyProps += @('displayName', 'description', 'severity', 'tactics', 'techniques')
    }

    foreach ($p in $readOnlyProps) {
        if ($props.PSObject.Properties[$p]) {
            $props.PSObject.Properties.Remove($p)
        }
    }

    return @{
        kind       = $kind
        properties = $props
    }
}

function Get-RuleMigrationId {
    <#
    .SYNOPSIS
        Generates a deterministic rule name/ID for the target workspace to ensure idempotency.
    .DESCRIPTION
        For template-based rules, uses the alertRuleTemplateName as a stable identifier.
        For custom rules, generates a GUID based on the displayName to avoid duplicates.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Rule
    )

    $props = $Rule.properties
    $templateName = $props.alertRuleTemplateName

    if (-not [string]::IsNullOrWhiteSpace($templateName)) {
        # Template-based: use template name as the rule ID (standard Sentinel convention)
        return $templateName
    }

    # Custom rule: generate deterministic GUID from displayName
    $displayName = $props.displayName
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        return [guid]::NewGuid().ToString()
    }

    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($displayName)
    $hash = $md5.ComputeHash($bytes)
    return [guid]::new($hash).ToString()
}

function New-DeterministicRuleId {
    <#
    .SYNOPSIS
        Derives a stable GUID-shaped rule id from an arbitrary seed string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Seed
    )

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Seed))
        return [guid]::new($hash).ToString()
    }
    finally {
        $md5.Dispose()
    }
}

function Resolve-RuleMigrationIdMap {
    <#
    .SYNOPSIS
        Assigns a unique target rule id to every source rule, keyed by source rule name.
    .DESCRIPTION
        Template-based rules normally take their template id as the target rule name,
        which is the Sentinel convention and keeps re-runs idempotent. That breaks when
        a workspace holds two rules derived from the same template - a common result of
        duplicating a built-in rule and retuning the copy. Both would resolve to one
        target id, so the second is reported as already existing and silently dropped.

        Here the first rule of each template keeps the template id and any further rules
        get a derived id instead. Ordering is by the source rule name, which is an
        immutable GUID, so the assignment is stable no matter what order the API returns.
    .OUTPUTS
        Hashtable mapping source rule name -> target rule id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rules
    )

    $byTemplate = @{}
    foreach ($rule in $Rules) {
        $templateName = $rule.properties.alertRuleTemplateName
        if ([string]::IsNullOrWhiteSpace($templateName)) { continue }
        if (-not $byTemplate.ContainsKey($templateName)) {
            $byTemplate[$templateName] = [System.Collections.Generic.List[object]]::new()
        }
        $byTemplate[$templateName].Add($rule)
    }

    $map = @{}
    foreach ($rule in $Rules) {
        $sourceName = $rule.name
        if ([string]::IsNullOrWhiteSpace($sourceName)) { continue }

        $templateName = $rule.properties.alertRuleTemplateName
        if ([string]::IsNullOrWhiteSpace($templateName)) {
            $map[$sourceName] = Get-RuleMigrationId -Rule $rule
            continue
        }

        $group = @($byTemplate[$templateName] | Sort-Object { $_.name })
        if ($group.Count -le 1 -or $group[0].name -eq $sourceName) {
            $map[$sourceName] = $templateName
        }
        else {
            $map[$sourceName] = New-DeterministicRuleId -Seed "$templateName|$sourceName"
        }
    }

    return $map
}

# ── Rule Migration ────────────────────────────────────────────────────────────
function Import-AnalyticsRule {
    <#
    .SYNOPSIS
        Creates or updates a single analytics rule in the target workspace.
    .OUTPUTS
        PSCustomObject with Action (Created/Updated/Skipped/Failed), RuleName, Details.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetWorkspaceUri,
        [Parameter(Mandatory)][object]$Rule,
        [string]$RuleIdOverride,
        [switch]$DryRun,
        [switch]$OverwriteExisting,
        [switch]$CreateDisabledRules,
        [int]$ThrottleDelayMs = 100
    )

    $displayName = $Rule.properties.displayName
    $isEnabled = ($Rule.properties.enabled -eq $true)
    $ruleId = if (-not [string]::IsNullOrWhiteSpace($RuleIdOverride)) {
        $RuleIdOverride
    } else {
        Get-RuleMigrationId -Rule $Rule
    }

    # Skip disabled rules unless CreateDisabledRules is set
    if (-not $isEnabled -and -not $CreateDisabledRules) {
        return [PSCustomObject]@{
            Action      = 'Skipped'
            RuleId      = $ruleId
            DisplayName = $displayName
            Reason      = 'Rule is disabled and -CreateDisabledRules not set'
        }
    }

    $ruleUri = Get-AlertRuleUri -WorkspaceUri $TargetWorkspaceUri -RuleId $ruleId

    # Check if rule already exists in target
    $existing = $null
    try {
        $existing = Invoke-SentinelApi -Uri $ruleUri -Method GET -ThrottleDelayMs $ThrottleDelayMs
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($statusCode -ne 404) { throw }
    }

    if ($existing -and -not $OverwriteExisting) {
        return [PSCustomObject]@{
            Action      = 'Skipped'
            RuleId      = $ruleId
            DisplayName = $displayName
            Reason      = 'Rule already exists in target and -OverwriteExisting not set'
        }
    }

    $action = if ($existing) { 'Updated' } else { 'Created' }

    # Build the PUT body
    $definition = Export-RuleDefinition -Rule $Rule
    $body = @{
        kind       = $definition.kind
        properties = $definition.properties
    }

    try {
        # Nothing in the response body is acted on; not throwing is the success signal.
        $null = Invoke-SentinelApi -Uri $ruleUri -Method PUT -Body $body `
            -DryRun:$DryRun -ThrottleDelayMs $ThrottleDelayMs

        if ($DryRun) { $action = "WouldBe$action" }

        return [PSCustomObject]@{
            Action      = $action
            RuleId      = $ruleId
            DisplayName = $displayName
            Reason      = $null
        }
    }
    catch {
        $errMsg = $_.Exception.Message

        # A rule kind that allows only one instance per template (Fusion is the usual
        # case) is rejected when the target already holds it under a different resource
        # name - Sentinel creates its own as 'BuiltInFusion', not as the template id.
        # That rule is already present, so report it as such rather than as a failure.
        if ($errMsg -match 'cannot be installed more than once') {
            $templateName = $Rule.properties.alertRuleTemplateName
            $installed = $null

            if (-not [string]::IsNullOrWhiteSpace($templateName)) {
                try {
                    $targetRules = Invoke-SentinelApiList `
                        -Uri (Get-AlertRulesUri -WorkspaceUri $TargetWorkspaceUri) `
                        -ThrottleDelayMs $ThrottleDelayMs
                    $installed = $targetRules |
                        Where-Object { $_.properties.alertRuleTemplateName -eq $templateName } |
                        Select-Object -First 1
                }
                catch {
                    # Fall through to the original failure below.
                }
            }

            if ($installed) {
                if (-not $OverwriteExisting) {
                    return [PSCustomObject]@{
                        Action      = 'Skipped'
                        RuleId      = $installed.name
                        DisplayName = $displayName
                        Reason      = "Already present in the target as '$($installed.name)'. This rule kind allows only one instance per template."
                    }
                }

                Write-Host ""
                Write-Host "      Updating the existing instance '$($installed.name)'..." -ForegroundColor Yellow
                try {
                    $installedUri = Get-AlertRuleUri -WorkspaceUri $TargetWorkspaceUri -RuleId $installed.name
                    $null = Invoke-SentinelApi -Uri $installedUri -Method PUT -Body $body `
                        -DryRun:$DryRun -ThrottleDelayMs $ThrottleDelayMs

                    return [PSCustomObject]@{
                        Action      = if ($DryRun) { 'WouldBeUpdated' } else { 'Updated' }
                        RuleId      = $installed.name
                        DisplayName = $displayName
                        Reason      = "Updated the single permitted instance of this template, already present as '$($installed.name)'."
                    }
                }
                catch {
                    return [PSCustomObject]@{
                        Action      = 'Failed'
                        RuleId      = $installed.name
                        DisplayName = $displayName
                        Reason      = $_.Exception.Message
                    }
                }
            }
        }

        # More entity mappings than the API accepts. Exact duplicates are already gone
        # by this point, so the remainder are distinct and something has to give: keep
        # the rule and drop the overflow, naming what went so the loss is not silent.
        if ($errMsg -match "Invalid length of '\d+' for 'EntityMappings'") {
            $maxMappings = 5
            if ($errMsg -match "should be between '\d+' and '(\d+)'") {
                $maxMappings = [int]$Matches[1]
            }

            $current = @($body.properties.entityMappings)
            if ($current.Count -gt $maxMappings) {
                $dropped = @($current | Select-Object -Skip $maxMappings |
                    ForEach-Object { $_.entityType }) -join ', '

                Write-Host ""
                Write-Host "      Retrying with $maxMappings entity mappings (dropping: $dropped)..." -ForegroundColor Yellow
                try {
                    $body.properties.entityMappings = @($current | Select-Object -First $maxMappings)
                    $null = Invoke-SentinelApi -Uri $ruleUri -Method PUT -Body $body `
                        -DryRun:$DryRun -ThrottleDelayMs $ThrottleDelayMs

                    if ($DryRun) { $action = "WouldBe$action" }

                    return [PSCustomObject]@{
                        Action      = $action
                        RuleId      = $ruleId
                        DisplayName = $displayName
                        Reason      = "Entity mappings trimmed to the API maximum of $maxMappings; dropped: $dropped. Re-add them in the source rule if they matter, then re-run."
                    }
                }
                catch {
                    return [PSCustomObject]@{
                        Action      = 'Failed'
                        RuleId      = $ruleId
                        DisplayName = $displayName
                        Reason      = $_.Exception.Message
                    }
                }
            }
        }

        # If the failure is due to missing tables, retry with the rule disabled
        # so Sentinel skips KQL query validation
        if ($errMsg -match 'One of the tables does not exist') {
            Write-Host "" # newline after the inline status
            Write-Host "      Retrying as disabled (missing tables in target)..." -ForegroundColor Yellow
            try {
                $body.properties.enabled = $false
                $null = Invoke-SentinelApi -Uri $ruleUri -Method PUT -Body $body `
                    -DryRun:$DryRun -ThrottleDelayMs $ThrottleDelayMs

                $retryAction = if ($DryRun) { 'WouldBeCreatedDisabled' } else { 'CreatedDisabled' }

                return [PSCustomObject]@{
                    Action      = $retryAction
                    RuleId      = $ruleId
                    DisplayName = $displayName
                    Reason      = 'Created disabled — missing table(s) in target workspace. Enable after connecting the required data source.'
                }
            }
            catch {
                return [PSCustomObject]@{
                    Action      = 'Failed'
                    RuleId      = $ruleId
                    DisplayName = $displayName
                    Reason      = $_.Exception.Message
                }
            }
        }

        return [PSCustomObject]@{
            Action      = 'Failed'
            RuleId      = $ruleId
            DisplayName = $displayName
            Reason      = $_.Exception.Message
        }
    }
}

function Import-AnalyticsRules {
    <#
    .SYNOPSIS
        Migrates a collection of analytics rules to the target workspace.
    .OUTPUTS
        Array of result objects from Import-AnalyticsRule.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetWorkspaceUri,
        [Parameter(Mandatory)][object[]]$Rules,
        [string]$Label = 'Rules',
        [switch]$DryRun,
        [switch]$OverwriteExisting,
        [switch]$CreateDisabledRules,
        [int]$ThrottleDelayMs = 100
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $total = $Rules.Count
    $current = 0

    # Assigned up front so that two rules sharing a template do not collide on one id.
    $idMap = Resolve-RuleMigrationIdMap -Rules $Rules

    Write-Host "  Migrating $total $Label..." -ForegroundColor Cyan

    foreach ($rule in $Rules) {
        $current++
        $displayName = $rule.properties.displayName
        Write-MigrationProgress -Activity "Migrating $Label" -Status $displayName -Current $current -Total $total
        Write-Host "    [$current/$total] $displayName" -ForegroundColor White -NoNewline

        $overrideId = $null
        if ($rule.name -and $idMap.ContainsKey($rule.name)) { $overrideId = $idMap[$rule.name] }

        $result = Import-AnalyticsRule `
            -TargetWorkspaceUri $TargetWorkspaceUri `
            -Rule $rule `
            -RuleIdOverride $overrideId `
            -DryRun:$DryRun `
            -OverwriteExisting:$OverwriteExisting `
            -CreateDisabledRules:$CreateDisabledRules `
            -ThrottleDelayMs $ThrottleDelayMs

        $color = Get-ActionColor $result.Action
        Write-Host " -> $(Format-ActionLabel $result.Action)" -ForegroundColor $color
        $normalized = Get-NormalizedAction $result.Action
        if ($result.Reason -and $normalized -eq 'Failed') {
            Write-Host "      Error: $($result.Reason)" -ForegroundColor Red
        }
        elseif ($result.Reason -and $normalized -notin @('Skipped')) {
            Write-Host "      Note: $($result.Reason)" -ForegroundColor Yellow
        }

        $results.Add($result)
    }

    Write-MigrationProgress -Activity "Migrating $Label" -Completed

    return $results.ToArray()
}

# ── Target Rule Discovery (for idempotency checks) ───────────────────────────
function Get-TargetAnalyticsRules {
    <#
    .SYNOPSIS
        Enumerates existing rules in the target workspace for idempotency comparison.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri,
        [int]$ThrottleDelayMs = 100
    )

    $uri = Get-AlertRulesUri -WorkspaceUri $WorkspaceUri
    Write-Host "  Fetching existing rules from target..." -ForegroundColor Cyan
    $rules = Invoke-SentinelApiList -Uri $uri -ThrottleDelayMs $ThrottleDelayMs
    Write-Host "  Found $($rules.Count) existing rule(s) in target" -ForegroundColor Cyan
    return $rules
}

Export-ModuleMember -Function @(
    'Get-SourceAnalyticsRules'
    'Get-SourceAlertRuleTemplates'
    'ConvertTo-UniqueEntityMapping'
    'Export-RuleDefinition'
    'Get-RuleMigrationId'
    'New-DeterministicRuleId'
    'Resolve-RuleMigrationIdMap'
    'Import-AnalyticsRule'
    'Import-AnalyticsRules'
    'Get-TargetAnalyticsRules'
)
