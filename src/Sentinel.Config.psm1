<#
.SYNOPSIS
    Configuration loading and merging for Sentinel Migration Assistant.
.DESCRIPTION
    Loads JSON or YAML config files and merges them with command-line parameter
    overrides. JSON needs no third-party module; YAML requires powershell-yaml.
#>

function Test-ConfigIsJson {
    <#
    .SYNOPSIS
        Decides whether a config file should be parsed as JSON.
    .DESCRIPTION
        Extension first, then content sniffing, so a JSON document saved with a
        .yml extension still parses. (JSON is a subset of YAML, but the reverse
        is not true, so guessing wrong towards JSON is the safe direction.)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Content = ''
    )

    if ([System.IO.Path]::GetExtension($Path) -ieq '.json') { return $true }
    return ($Content.TrimStart() -match '^\{')
}

function Import-YamlModule {
    <#
    .SYNOPSIS
        Imports powershell-yaml, with an actionable message when it is absent.
    .DESCRIPTION
        Deliberately does NOT install anything. Reaching out to PSGallery in the
        middle of a migration fails or hangs in locked-down tenants, and silently
        installing modules on an operator's machine is not this tool's business.
        Assert-MigrationPrerequisite reports this upfront instead.
    #>
    if (-not (Get-Module -Name 'powershell-yaml' -ErrorAction SilentlyContinue)) {
        if (-not (Get-Module -ListAvailable -Name 'powershell-yaml' -ErrorAction SilentlyContinue)) {
            throw "The 'powershell-yaml' module is required to read a YAML config file.`n" +
                  "  Install it:      Install-Module -Name powershell-yaml -Scope CurrentUser`n" +
                  "  Or avoid it:     supply the same settings in a .json config file, which needs no extra module."
        }
        Import-Module powershell-yaml -ErrorAction Stop
    }
}

function Read-MigrationConfig {
    <#
    .SYNOPSIS
        Loads a JSON or YAML config file and returns a normalized configuration object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Configuration file not found: $Path"
    }

    $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Configuration file is empty: $Path"
    }

    if (Test-ConfigIsJson -Path $Path -Content $raw) {
        try {
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "Failed to parse JSON config '$Path': $($_.Exception.Message)"
        }
    }
    else {
        Import-YamlModule
        try {
            $parsed = ConvertFrom-Yaml -Yaml $raw -ErrorAction Stop
        }
        catch {
            throw "Failed to parse YAML config '$Path': $($_.Exception.Message)"
        }
    }

    return ConvertTo-NormalizedConfig -RawConfig $parsed
}

function ConvertTo-NormalizedConfig {
    <#
    .SYNOPSIS
        Validates and normalizes raw config (from YAML or parameters) into a typed config object.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$RawConfig)

    $cfg = [PSCustomObject]@{
        Source  = [PSCustomObject]@{
            SubscriptionId    = $null
            ResourceGroupName = $null
            WorkspaceName     = $null
        }
        Target  = [PSCustomObject]@{
            SubscriptionId    = $null
            ResourceGroupName = $null
            WorkspaceName     = $null
        }
        Options = [PSCustomObject]@{
            DryRun               = $true
            Cloud                = 'Commercial'
            OverwriteExisting    = $false
            CreateDisabledRules  = $false
            MigrateWorkbooks     = $true
            MigrateWatchlists    = $true
            MigrateCustomRules   = $true
            MigrateTemplateRules = $true
            MigrateSolutions     = $true
            GenerateChecklist    = $true
            RetryCount           = 3
            ThrottleMs           = 100
        }
    }

    # Map source
    if ($RawConfig.source) {
        $s = $RawConfig.source
        if ($s.subscriptionId)    { $cfg.Source.SubscriptionId    = $s.subscriptionId }
        if ($s.resourceGroupName) { $cfg.Source.ResourceGroupName = $s.resourceGroupName }
        if ($s.workspaceName)     { $cfg.Source.WorkspaceName     = $s.workspaceName }
    }

    # Map target
    if ($RawConfig.target) {
        $t = $RawConfig.target
        if ($t.subscriptionId)    { $cfg.Target.SubscriptionId    = $t.subscriptionId }
        if ($t.resourceGroupName) { $cfg.Target.ResourceGroupName = $t.resourceGroupName }
        if ($t.workspaceName)     { $cfg.Target.WorkspaceName     = $t.workspaceName }
    }

    # Map options
    if ($RawConfig.options) {
        $o = $RawConfig.options
        if ($null -ne $o.dryRun)               { $cfg.Options.DryRun               = [bool]$o.dryRun }
        if ($null -ne $o.cloud)                 { $cfg.Options.Cloud                = $o.cloud }
        if ($null -ne $o.overwriteExisting)     { $cfg.Options.OverwriteExisting    = [bool]$o.overwriteExisting }
        if ($null -ne $o.createDisabledRules)   { $cfg.Options.CreateDisabledRules  = [bool]$o.createDisabledRules }
        if ($null -ne $o.migrateWorkbooks)      { $cfg.Options.MigrateWorkbooks     = [bool]$o.migrateWorkbooks }
        if ($null -ne $o.migrateWatchlists)     { $cfg.Options.MigrateWatchlists    = [bool]$o.migrateWatchlists }
        if ($null -ne $o.migrateCustomRules)    { $cfg.Options.MigrateCustomRules   = [bool]$o.migrateCustomRules }
        if ($null -ne $o.migrateTemplateRules)  { $cfg.Options.MigrateTemplateRules = [bool]$o.migrateTemplateRules }
        if ($null -ne $o.migrateSolutions)      { $cfg.Options.MigrateSolutions     = [bool]$o.migrateSolutions }
        if ($null -ne $o.generateChecklist)     { $cfg.Options.GenerateChecklist    = [bool]$o.generateChecklist }
        if ($null -ne $o.retryCount)            { $cfg.Options.RetryCount           = [int]$o.retryCount }
        if ($null -ne $o.throttleMs)            { $cfg.Options.ThrottleMs           = [int]$o.throttleMs }
        # 'concurrency' was accepted here but never read by any caller. Migration
        # is intentionally sequential: ARM throttles per-subscription, and parallel
        # writes made 429s more likely without finishing measurably sooner.
        if ($null -ne $o.concurrency) {
            Write-Warning "options.concurrency is not supported and will be ignored. Migration runs sequentially to stay within ARM throttling limits; use options.throttleMs to tune pacing."
        }
    }

    return $cfg
}

function Merge-ParameterOverrides {
    <#
    .SYNOPSIS
        Merges CLI parameter overrides onto a config object. CLI params take precedence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [hashtable]$Overrides
    )

    foreach ($key in $Overrides.Keys) {
        $val = $Overrides[$key]
        if ($null -eq $val) { continue }

        switch ($key) {
            'SourceSubscriptionId'    { $Config.Source.SubscriptionId    = $val }
            'SourceResourceGroup'     { $Config.Source.ResourceGroupName = $val }
            'SourceWorkspace'         { $Config.Source.WorkspaceName     = $val }
            'TargetSubscriptionId'    { $Config.Target.SubscriptionId    = $val }
            'TargetResourceGroup'     { $Config.Target.ResourceGroupName = $val }
            'TargetWorkspace'         { $Config.Target.WorkspaceName     = $val }
            'DryRun'                  { $Config.Options.DryRun               = $val }
            'Cloud'                   { $Config.Options.Cloud                = $val }
            'OverwriteExisting'       { $Config.Options.OverwriteExisting    = $val }
            'CreateDisabledRules'     { $Config.Options.CreateDisabledRules  = $val }
            'MigrateWorkbooks'        { $Config.Options.MigrateWorkbooks     = $val }
            'MigrateWatchlists'       { $Config.Options.MigrateWatchlists    = $val }
            'MigrateCustomRules'      { $Config.Options.MigrateCustomRules   = $val }
            'MigrateTemplateRules'    { $Config.Options.MigrateTemplateRules = $val }
            'MigrateSolutions'        { $Config.Options.MigrateSolutions     = $val }
            'GenerateChecklist'       { $Config.Options.GenerateChecklist    = $val }
            'RetryCount'              { $Config.Options.RetryCount           = [int]$val }
            'ThrottleMs'              { $Config.Options.ThrottleMs           = [int]$val }
        }
    }

    return $Config
}

function Assert-ConfigValid {
    <#
    .SYNOPSIS
        Validates that required config fields are present.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Config)

    $errors = @()
    if (-not $Config.Source.SubscriptionId)    { $errors += "source.subscriptionId is required" }
    if (-not $Config.Source.ResourceGroupName) { $errors += "source.resourceGroupName is required" }
    if (-not $Config.Source.WorkspaceName)     { $errors += "source.workspaceName is required" }
    if (-not $Config.Target.SubscriptionId)    { $errors += "target.subscriptionId is required" }
    if (-not $Config.Target.ResourceGroupName) { $errors += "target.resourceGroupName is required" }
    if (-not $Config.Target.WorkspaceName)     { $errors += "target.workspaceName is required" }

    if ($Config.Options.Cloud -notin @('Commercial', 'Gov')) {
        $errors += "options.cloud must be 'Commercial' or 'Gov'"
    }

    if ($Config.Options.RetryCount -lt 0 -or $Config.Options.RetryCount -gt 10) {
        $errors += "options.retryCount must be between 0 and 10 (got $($Config.Options.RetryCount))"
    }

    if ($Config.Options.ThrottleMs -lt 0 -or $Config.Options.ThrottleMs -gt 60000) {
        $errors += "options.throttleMs must be between 0 and 60000 (got $($Config.Options.ThrottleMs))"
    }

    # Migrating a workspace onto itself would have every rule collide with its
    # own source, and with overwriteExisting on it would rewrite the source.
    $sameWorkspace = (
        $Config.Source.SubscriptionId    -eq $Config.Target.SubscriptionId -and
        $Config.Source.ResourceGroupName -eq $Config.Target.ResourceGroupName -and
        $Config.Source.WorkspaceName     -eq $Config.Target.WorkspaceName
    )
    if ($sameWorkspace -and $Config.Source.WorkspaceName) {
        $errors += "source and target refer to the same workspace ('$($Config.Source.WorkspaceName)'). Migration requires two different workspaces."
    }

    if ($errors.Count -gt 0) {
        throw "Configuration validation failed:`n  - $($errors -join "`n  - ")"
    }
}

Export-ModuleMember -Function @(
    'Read-MigrationConfig'
    'ConvertTo-NormalizedConfig'
    'Merge-ParameterOverrides'
    'Assert-ConfigValid'
    'Test-ConfigIsJson'
)
