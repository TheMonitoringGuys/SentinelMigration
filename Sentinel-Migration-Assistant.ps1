#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Sentinel Migration Assistant — DEV → PROD analytics rule, workbook, and watchlist migration.

.DESCRIPTION
    Scans a SOURCE Microsoft Sentinel workspace and replicates analytics rules,
    workbooks, watchlists, and Content Hub solutions into a TARGET workspace.

    Supports dry-run and execute modes, YAML config files, and produces
    structured logs and Markdown reports.

.PARAMETER ConfigFile
    Path to a YAML or JSON configuration file. See samples/config.yaml for the
    schema and the full set of options. JSON uses the same key names and needs no
    third-party module; the parser is chosen from the file extension.

.PARAMETER SourceSubscriptionId
    Azure subscription ID for the source workspace.

.PARAMETER SourceResourceGroup
    Resource group containing the source Log Analytics workspace.

.PARAMETER SourceWorkspace
    Name of the source Log Analytics workspace.

.PARAMETER TargetSubscriptionId
    Azure subscription ID for the target workspace.

.PARAMETER TargetResourceGroup
    Resource group containing the target Log Analytics workspace.

.PARAMETER TargetWorkspace
    Name of the target Log Analytics workspace.

.PARAMETER DryRun
    When set, performs no changes — outputs a migration plan/report only.

.PARAMETER Execute
    When set, performs the actual migration. Mutually exclusive with -DryRun.

.PARAMETER Cloud
    Azure cloud environment: Commercial or Gov.

.PARAMETER OverwriteExisting
    Overwrite rules/workbooks/watchlists that already exist in the target.

.PARAMETER CreateDisabledRules
    Migrate rules that are disabled in the source (preserving disabled state).

.PARAMETER SkipWorkbooks
    Skip workbook migration.

.PARAMETER SkipWatchlists
    Skip watchlist migration.

.PARAMETER SkipCustomRules
    Skip custom analytics rule migration.

.PARAMETER SkipTemplateRules
    Skip template-based analytics rule migration.

.PARAMETER SkipSolutions
    Skip Content Hub solution migration. By default every solution installed in the
    source workspace is installed in the target.

.PARAMETER SkipChecklist
    Skip generating the manual Content Hub install checklist.

.PARAMETER MigrateWorkbooks
    Deprecated. Use -SkipWorkbooks. Accepts $true/$false for backward compatibility.

.PARAMETER MigrateWatchlists
    Deprecated. Use -SkipWatchlists.

.PARAMETER MigrateCustomRules
    Deprecated. Use -SkipCustomRules.

.PARAMETER MigrateTemplateRules
    Deprecated. Use -SkipTemplateRules.

.PARAMETER MigrateSolutions
    Deprecated. Use -SkipSolutions.

.PARAMETER GenerateChecklist
    Deprecated. Use -SkipChecklist.

.PARAMETER Force
    Skip the interactive confirmation prompt in -Execute mode. Required for
    non-interactive/automated runs.

.PARAMETER RetryCount
    Maximum retries on throttled or transient API errors (0-10, default 3).

.PARAMETER ThrottleMs
    Delay in milliseconds between API calls (default 100). Raise this if the
    target subscription throttles aggressively.

.PARAMETER SkipPreflight
    Bypass the target workspace reachability and permission checks. Not
    recommended; intended for constrained identities that cannot read their own
    role assignments.

.PARAMETER IncludeTableStats
    Query the target workspace for per-table row counts and report which migrated
    rules reference tables that hold no data. A rule can migrate successfully and
    still never fire when its data connector was never configured on the target.
    Opt-in because it requires Log Analytics data-plane read access, which is a
    separate grant from the ARM permissions the migration itself needs.

.PARAMETER TableStatsLookbackDays
    Lookback window in days for -IncludeTableStats (default 7).

.PARAMETER OutputDir
    Directory for report and log output. Defaults to ./output. Each run writes to a
    timestamped subfolder beneath it.

.PARAMETER NoDetailTables
    Build a slim KPI/chart-only HTML summary without the embedded drill-down tables.

.PARAMETER NoAutoInstall
    Do not attempt to install missing PowerShell modules. By default a missing
    powershell-yaml module is installed automatically (CurrentUser scope) when a
    YAML config file is supplied. Use this in CI or locked-down environments where
    package installation is managed separately.

.EXAMPLE
    # Dry-run with config file
    ./Sentinel-Migration-Assistant.ps1 -ConfigFile ./samples/config.yaml -DryRun

.EXAMPLE
    # Execute migration with CLI parameters
    ./Sentinel-Migration-Assistant.ps1 `
        -SourceSubscriptionId "aaaa-bbbb" -SourceResourceGroup "rg-dev" -SourceWorkspace "ws-dev" `
        -TargetSubscriptionId "cccc-dddd" -TargetResourceGroup "rg-prod" -TargetWorkspace "ws-prod" `
        -Execute -Cloud Commercial

.EXAMPLE
    # Execute with service principal (non-interactive)
    Connect-AzAccount -ServicePrincipal -TenantId $tenantId -Credential $cred
    ./Sentinel-Migration-Assistant.ps1 -ConfigFile ./config.yaml -Execute
#>
[CmdletBinding(DefaultParameterSetName = 'DryRun')]
param(
    [string]$ConfigFile,

    [string]$SourceSubscriptionId,
    [string]$SourceResourceGroup,
    [string]$SourceWorkspace,

    [string]$TargetSubscriptionId,
    [string]$TargetResourceGroup,
    [string]$TargetWorkspace,

    [Parameter(ParameterSetName = 'DryRun')]
    [switch]$DryRun,

    [Parameter(ParameterSetName = 'Execute')]
    [switch]$Execute,

    [ValidateSet('Commercial', 'Gov')]
    [string]$Cloud,

    [switch]$OverwriteExisting,
    [switch]$CreateDisabledRules,

    [switch]$SkipWorkbooks,
    [switch]$SkipWatchlists,
    [switch]$SkipCustomRules,
    [switch]$SkipTemplateRules,
    [switch]$SkipSolutions,
    [switch]$SkipChecklist,

    # Deprecated -Migrate* forms, retained so existing automation keeps working.
    [Nullable[bool]]$MigrateWorkbooks,
    [Nullable[bool]]$MigrateWatchlists,
    [Nullable[bool]]$MigrateCustomRules,
    [Nullable[bool]]$MigrateTemplateRules,
    [Nullable[bool]]$MigrateSolutions,
    [Nullable[bool]]$GenerateChecklist,

    [Parameter(ParameterSetName = 'Execute')]
    [switch]$Force,

    [ValidateRange(0, 10)]
    [int]$RetryCount = -1,

    [ValidateRange(0, 60000)]
    [int]$ThrottleMs = -1,

    [switch]$SkipPreflight,

    [switch]$IncludeTableStats,

    [ValidateRange(1, 365)]
    [int]$TableStatsLookbackDays = 7,

    [switch]$NoDetailTables,

    [switch]$NoAutoInstall,

    [string]$OutputDir = './output'
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date

# Exit codes: 0 = success, 1 = completed with failures, 2 = fatal error.
$script:ExitCode = 0

# ── Banner ────────────────────────────────────────────────────────────────────
$toolVersion = 'v1.1.0'
$bannerLines = @(
    "Sentinel Migration Assistant  $toolVersion"
    'DEV -> PROD Workspace Migration'
)
$bannerWidth = 62
Write-Host ""
Write-Host ("╔" + ("═" * $bannerWidth) + "╗") -ForegroundColor Cyan
foreach ($line in $bannerLines) {
    $pad = $bannerWidth - $line.Length
    $left = [Math]::Max(0, [int][Math]::Floor($pad / 2))
    $right = [Math]::Max(0, $pad - $left)
    Write-Host ("║" + (" " * $left) + $line + (" " * $right) + "║") -ForegroundColor Cyan
}
Write-Host ("╚" + ("═" * $bannerWidth) + "╝") -ForegroundColor Cyan
Write-Host ""

# ── Load Modules ──────────────────────────────────────────────────────────────
$scriptRoot = $PSScriptRoot
$srcDir = Join-Path $scriptRoot 'src'

# Preflight and Common are deliberately Az-free so they load even when the
# environment is incomplete, turning a cryptic #Requires failure into advice.
Import-Module (Join-Path $srcDir 'Sentinel.Common.psm1')     -Force -DisableNameChecking
Import-Module (Join-Path $srcDir 'Sentinel.Preflight.psm1')  -Force -DisableNameChecking

$needsYaml = $false
if ($ConfigFile) {
    # Config module isn't loaded yet, so sniff the extension here. YAML is only
    # a prerequisite when the config file actually needs a YAML parser.
    $needsYaml = ([System.IO.Path]::GetExtension($ConfigFile)) -notin @('.json', '.jsonc')
}
$prereq = Assert-MigrationPrerequisite -RequireYaml:$needsYaml -NoAutoInstall:$NoAutoInstall
foreach ($w in $prereq.Warnings) { Write-Host "[PREREQ] $w" -ForegroundColor Yellow }
if (-not $prereq.Ok) {
    Write-Host ""
    Write-Host "[PREREQ] Cannot continue:" -ForegroundColor Red
    foreach ($b in $prereq.Blocking) { Write-Host "  - $b" -ForegroundColor Red }
    Write-Host ""
    exit 2
}

Import-Module (Join-Path $srcDir 'Sentinel.Api.psm1')        -Force
Import-Module (Join-Path $srcDir 'Sentinel.Config.psm1')     -Force
Import-Module (Join-Path $srcDir 'Sentinel.Rules.psm1')      -Force
Import-Module (Join-Path $srcDir 'Sentinel.Workbooks.psm1')  -Force
Import-Module (Join-Path $srcDir 'Sentinel.Watchlists.psm1') -Force
Import-Module (Join-Path $srcDir 'Sentinel.ContentHub.psm1') -Force
Import-Module (Join-Path $srcDir 'Sentinel.Report.psm1')     -Force
Import-Module (Join-Path $srcDir 'Sentinel.Export.psm1')     -Force
Import-Module (Join-Path $srcDir 'Sentinel.Stats.psm1')      -Force
Import-Module (Join-Path $srcDir 'Sentinel.Html.psm1')       -Force

# Every module above re-imports Sentinel.Common with -Force. Import-Module -Force
# removes the module first, which unloads the copy imported at the top of this
# script and rebinds those functions to the importing module's own scope. The
# orchestrator is left unable to see Invoke-SafeCollection, Format-ApiErrorDetail
# and the rest, and dies at the first call. Re-import last to restore them.
Import-Module (Join-Path $srcDir 'Sentinel.Common.psm1')     -Force -DisableNameChecking

# ── Configuration ─────────────────────────────────────────────────────────────
Write-Host "[CONFIG] Loading configuration..." -ForegroundColor Cyan

if ($ConfigFile) {
    $config = Read-MigrationConfig -Path $ConfigFile
}
else {
    # Build config from defaults
    $config = ConvertTo-NormalizedConfig -RawConfig @{ source = @{}; target = @{}; options = @{} }
}

# Apply CLI parameter overrides
$overrides = @{}
if ($SourceSubscriptionId) { $overrides['SourceSubscriptionId'] = $SourceSubscriptionId }
if ($SourceResourceGroup)  { $overrides['SourceResourceGroup']  = $SourceResourceGroup }
if ($SourceWorkspace)      { $overrides['SourceWorkspace']      = $SourceWorkspace }
if ($TargetSubscriptionId) { $overrides['TargetSubscriptionId'] = $TargetSubscriptionId }
if ($TargetResourceGroup)  { $overrides['TargetResourceGroup']  = $TargetResourceGroup }
if ($TargetWorkspace)      { $overrides['TargetWorkspace']      = $TargetWorkspace }
if ($Cloud)                { $overrides['Cloud']                = $Cloud }
if ($Execute)              { $overrides['DryRun']               = $false }
if ($DryRun)               { $overrides['DryRun']               = $true }
if ($OverwriteExisting)    { $overrides['OverwriteExisting']    = $true }
if ($CreateDisabledRules)  { $overrides['CreateDisabledRules']  = $true }
if ($RetryCount -ge 0)     { $overrides['RetryCount']           = $RetryCount }
if ($ThrottleMs -ge 0)     { $overrides['ThrottleMs']           = $ThrottleMs }

# Deprecated -Migrate*/-GenerateChecklist forms apply first so the newer
# -Skip* switches win when both are supplied.
$deprecated = @()
if ($null -ne $MigrateWorkbooks)     { $overrides['MigrateWorkbooks']     = $MigrateWorkbooks;     $deprecated += '-MigrateWorkbooks (use -SkipWorkbooks)' }
if ($null -ne $MigrateWatchlists)    { $overrides['MigrateWatchlists']    = $MigrateWatchlists;    $deprecated += '-MigrateWatchlists (use -SkipWatchlists)' }
if ($null -ne $MigrateCustomRules)   { $overrides['MigrateCustomRules']   = $MigrateCustomRules;   $deprecated += '-MigrateCustomRules (use -SkipCustomRules)' }
if ($null -ne $MigrateTemplateRules) { $overrides['MigrateTemplateRules'] = $MigrateTemplateRules; $deprecated += '-MigrateTemplateRules (use -SkipTemplateRules)' }
if ($null -ne $MigrateSolutions) { $overrides['MigrateSolutions'] = $MigrateSolutions; $deprecated += '-MigrateSolutions (use -SkipSolutions)' }
if ($null -ne $GenerateChecklist)    { $overrides['GenerateChecklist']    = $GenerateChecklist;    $deprecated += '-GenerateChecklist (use -SkipChecklist)' }

if ($SkipWorkbooks)     { $overrides['MigrateWorkbooks']     = $false }
if ($SkipWatchlists)    { $overrides['MigrateWatchlists']    = $false }
if ($SkipCustomRules)   { $overrides['MigrateCustomRules']   = $false }
if ($SkipTemplateRules) { $overrides['MigrateTemplateRules'] = $false }
if ($SkipSolutions) { $overrides['MigrateSolutions'] = $false }
if ($SkipChecklist)     { $overrides['GenerateChecklist']    = $false }

foreach ($d in $deprecated) {
    Write-Host "[CONFIG] Deprecated parameter $d" -ForegroundColor Yellow
}

$config = Merge-ParameterOverrides -Config $config -Overrides $overrides

# If neither -DryRun nor -Execute specified, default to dry-run
if (-not $Execute -and -not $DryRun) {
    $config.Options.DryRun = $true
}

Assert-ConfigValid -Config $config

# Make the configured retry budget actually reach the API layer.
Set-SentinelApiDefault -RetryCount $config.Options.RetryCount

$isDryRun = $config.Options.DryRun
$modeLabel = if ($isDryRun) { "DRY RUN" } else { "EXECUTE" }
Write-Host "[CONFIG] Mode: $modeLabel" -ForegroundColor $(if ($isDryRun) { 'Yellow' } else { 'Red' })
Write-Host "[CONFIG] Source: $($config.Source.WorkspaceName) ($($config.Source.ResourceGroupName))" -ForegroundColor White
Write-Host "[CONFIG] Target: $($config.Target.WorkspaceName) ($($config.Target.ResourceGroupName))" -ForegroundColor White
Write-Host ""

# ── Authentication ────────────────────────────────────────────────────────────
Write-Host "[AUTH] Verifying Azure authentication..." -ForegroundColor Cyan
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    Write-Host "[AUTH] No active Azure session. Running Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount -ErrorAction Stop
    $ctx = Get-AzContext
}
Write-Host "[AUTH] Authenticated as: $($ctx.Account.Id) (Tenant: $($ctx.Tenant.Id))" -ForegroundColor Green
Write-Host ""

$armEndpoint = Resolve-ArmEndpoint -Cloud $config.Options.Cloud

# ── Build workspace URIs ──────────────────────────────────────────────────────
$sourceWsUri = Get-SentinelWorkspaceUri `
    -ArmEndpoint $armEndpoint `
    -SubscriptionId $config.Source.SubscriptionId `
    -ResourceGroupName $config.Source.ResourceGroupName `
    -WorkspaceName $config.Source.WorkspaceName

$targetWsUri = Get-SentinelWorkspaceUri `
    -ArmEndpoint $armEndpoint `
    -SubscriptionId $config.Target.SubscriptionId `
    -ResourceGroupName $config.Target.ResourceGroupName `
    -WorkspaceName $config.Target.WorkspaceName

$targetWorkspaceResourceId = "/subscriptions/$($config.Target.SubscriptionId)/resourceGroups/$($config.Target.ResourceGroupName)/providers/Microsoft.OperationalInsights/workspaces/$($config.Target.WorkspaceName)"
$sourceWorkspaceResourceId = "/subscriptions/$($config.Source.SubscriptionId)/resourceGroups/$($config.Source.ResourceGroupName)/providers/Microsoft.OperationalInsights/workspaces/$($config.Source.WorkspaceName)"

# ── Preflight: fail fast on an unreachable or unwritable target ───────────────
# Historically the tool discovered every source artifact, attempted every write,
# and only then reported that the target workspace did not exist.
$targetLocation = $null
if (-not $SkipPreflight) {
    Write-Host "[PREFLIGHT] Validating workspace access..." -ForegroundColor Cyan

    $srcCheck = Test-WorkspaceAccess -WorkspaceUri $sourceWsUri -ArmEndpoint $armEndpoint `
        -SubscriptionId $config.Source.SubscriptionId `
        -ResourceGroupName $config.Source.ResourceGroupName `
        -Label 'Source' -ThrottleDelayMs $config.Options.ThrottleMs

    $tgtCheck = Test-WorkspaceAccess -WorkspaceUri $targetWsUri -ArmEndpoint $armEndpoint `
        -SubscriptionId $config.Target.SubscriptionId `
        -ResourceGroupName $config.Target.ResourceGroupName `
        -Label 'Target' -RequireWrite:(-not $isDryRun) -ThrottleDelayMs $config.Options.ThrottleMs

    $targetLocation = $tgtCheck.Location

    $blocking = @()
    foreach ($check in @($srcCheck, $tgtCheck)) { $blocking += @($check.Problems) }

    if ($blocking.Count -gt 0) {
        Write-Host ""
        Write-Host "[PREFLIGHT] Cannot continue:" -ForegroundColor Red
        foreach ($b in $blocking) { Write-Host "  - $b" -ForegroundColor Red }
        Write-Host ""
        Write-Host "  Re-run with -SkipPreflight to bypass these checks." -ForegroundColor DarkGray
        Write-Host ""
        exit 2
    }

    if ($tgtCheck.CanWrite -eq 'Unknown' -and -not $isDryRun) {
        Write-Host "[PREFLIGHT] Could not verify write permission on the target (the identity cannot read its own role assignments). Continuing." -ForegroundColor Yellow
    }
    Write-Host "[PREFLIGHT] Source and target reachable." -ForegroundColor Green
    Write-Host ""
}

# ── Initialize result tracking ────────────────────────────────────────────────
Clear-MigrationLog
$migrationErrors = [System.Collections.Generic.List[object]]::new()
$allRuleResults = [System.Collections.Generic.List[object]]::new()
$allWorkbookResults = [System.Collections.Generic.List[object]]::new()
$allWatchlistResults = [System.Collections.Generic.List[object]]::new()
$contentHubResults = $null
$ruleClassification = $null
$workbooksDiscovered = 0
$watchlistsDiscovered = 0

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1: DISCOVER SOURCE STATE
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " PHASE 1: Discovering Source State" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

try {
    $ruleClassification = Get-SourceAnalyticsRules `
        -WorkspaceUri $sourceWsUri `
        -ThrottleDelayMs $config.Options.ThrottleMs
    Write-MigrationLog -Message "Discovered $(@($ruleClassification.All).Count) analytics rules" -Level 'Success' -Component 'Discovery'
}
catch {
    $detail = Format-ApiErrorDetail -ErrorRecord $_
    Write-MigrationLog -Message "Failed to enumerate source rules: $detail" -Level 'Error' -Component 'Discovery'
    $migrationErrors.Add([PSCustomObject]@{
        Component   = 'Rule Discovery'
        Message     = $detail
        Remediation = 'Verify source workspace exists, Sentinel is enabled, and you have Reader access.'
    })
}

# Rule discovery is the input to phases 2 and 3. If it produced nothing usable,
# say so once here rather than letting both phases silently no-op and still
# report success.
$ruleDiscoveryOk = ($null -ne $ruleClassification)
if (-not $ruleDiscoveryOk) {
    Write-Host "[DISCOVERY] Analytics rule discovery failed - rule migration phases will be skipped." -ForegroundColor Red
}

# Discover workbooks
$sourceWorkbooks = @()
if ($config.Options.MigrateWorkbooks) {
    $sourceWorkbooks = @(Invoke-SafeCollection -Name 'Workbook Discovery' -ErrorSink $migrationErrors `
        -Remediation 'Verify Reader access on source resource group.' -Action {
            Get-SourceWorkbooks `
                -ArmEndpoint $armEndpoint `
                -SubscriptionId $config.Source.SubscriptionId `
                -ResourceGroupName $config.Source.ResourceGroupName `
                -WorkspaceResourceId $sourceWorkspaceResourceId `
                -ThrottleDelayMs $config.Options.ThrottleMs
        })
    $workbooksDiscovered = $sourceWorkbooks.Count
    Write-MigrationLog -Message "Discovered $workbooksDiscovered workbook(s)" -Level 'Success' -Component 'Discovery'
}

# Discover watchlists
$sourceWatchlists = @()
if ($config.Options.MigrateWatchlists) {
    $sourceWatchlists = @(Invoke-SafeCollection -Name 'Watchlist Discovery' -ErrorSink $migrationErrors `
        -Remediation 'Verify Reader access on source workspace.' -Action {
            Get-SourceWatchlists `
                -SourceWorkspaceUri $sourceWsUri `
                -ThrottleDelayMs $config.Options.ThrottleMs
        })
    $watchlistsDiscovered = $sourceWatchlists.Count
    Write-MigrationLog -Message "Discovered $watchlistsDiscovered watchlist(s)" -Level 'Success' -Component 'Discovery'
}

Write-Host ""

# ── Confirmation before writing to the target ────────────────────────────────
# Deliberately placed after discovery so the operator confirms against real
# counts rather than an abstract promise to "migrate everything".
if (-not $isDryRun) {
    $plannedRules = 0
    if ($ruleClassification) {
        if ($config.Options.MigrateTemplateRules) {
            $plannedRules += @($ruleClassification.TemplateRulesEnabled).Count
            if ($config.Options.CreateDisabledRules) { $plannedRules += @($ruleClassification.TemplateRulesDisabled).Count }
        }
        if ($config.Options.MigrateCustomRules) {
            $plannedRules += @($ruleClassification.CustomRulesEnabled).Count
            if ($config.Options.CreateDisabledRules) { $plannedRules += @($ruleClassification.CustomRulesDisabled).Count }
        }
    }

    Show-MigrationPlan -Plan @{
        TargetWorkspace      = $config.Target.WorkspaceName
        TargetResourceGroup  = $config.Target.ResourceGroupName
        TargetSubscriptionId = $config.Target.SubscriptionId
        RuleCount            = $plannedRules
        WorkbookCount        = $workbooksDiscovered
        WatchlistCount       = $watchlistsDiscovered
        OverwriteExisting    = $config.Options.OverwriteExisting
    }

    if (-not (Confirm-MigrationExecution -TargetWorkspace $config.Target.WorkspaceName -Force:$Force)) {
        Write-Host "[ABORT] Migration cancelled. No changes were made to the target workspace." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2: CONTENT HUB SOLUTIONS
# ══════════════════════════════════════════════════════════════════════════════
if ($config.Options.MigrateSolutions) {
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host " PHASE 2: Content Hub Solutions" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

    # Rule-dependency discovery is a bonus on top of mirroring the source's solutions,
    # so an absent classification narrows the work set rather than skipping the phase.
    $allTemplateRules = @()
    if ($ruleClassification -and $config.Options.MigrateTemplateRules) {
        $allTemplateRules += $ruleClassification.TemplateRulesEnabled
        $allTemplateRules += $ruleClassification.TemplateRulesDisabled
    }

    try {
        $contentHubResults = Sync-ContentHubSolutions `
            -SourceWorkspaceUri $sourceWsUri `
            -TargetWorkspaceUri $targetWsUri `
            -TemplateRules $allTemplateRules `
            -DryRun:$isDryRun `
            -GenerateChecklist:($config.Options.GenerateChecklist) `
            -OverwriteExisting:($config.Options.OverwriteExisting) `
            -ThrottleDelayMs $config.Options.ThrottleMs

        $installed = @($contentHubResults.InstalledPackages).Count
        $upgraded  = @($contentHubResults.UpgradedPackages).Count
        $skipped   = @($contentHubResults.SkippedPackages).Count
        $failed    = @($contentHubResults.FailedPackages).Count
        $pending   = @($contentHubResults.PendingPackages).Count
        $missing   = @($contentHubResults.NotInCatalog).Count
        $checklist = @($contentHubResults.ManualChecklist).Count

        Write-Host "  Source workspace has $($contentHubResults.SourceSolutionCount) solution(s) installed." -ForegroundColor Gray
        Write-MigrationLog -Message "Content Hub: $installed installed, $upgraded upgraded, $skipped skipped, $failed failed, $pending pending, $missing not in catalog, $checklist manual checklist items" `
            -Level 'Info' -Component 'ContentHub'

        if ($skipped -gt 0) {
            Write-Host "  $skipped solution(s) are out of date in the target. Re-run with -OverwriteExisting to upgrade them." -ForegroundColor Yellow
        }
        if ($pending -gt 0) {
            Write-Host "  $pending solution(s) were still deploying. Re-run the migration to pick up rules that depend on them." -ForegroundColor Yellow
        }
        if ($missing -gt 0) {
            Write-Host "  $missing solution(s) are installed in the source but not offered by the target's catalog." -ForegroundColor Yellow
        }
    }
    catch {
        Write-MigrationLog -Message "Content Hub sync failed: $($_.Exception.Message)" -Level 'Error' -Component 'ContentHub'
        $migrationErrors.Add([PSCustomObject]@{
            Component   = 'Content Hub'
            Message     = $_.Exception.Message
            Remediation = 'Confirm the identity holds Microsoft Sentinel Contributor on the target workspace, then re-run. Solutions can also be installed manually via the Azure Portal Content Hub.'
        })
    }
    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3: MIGRATE ANALYTICS RULES
# ══════════════════════════════════════════════════════════════════════════════
if ($ruleClassification) {
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host " PHASE 3: Migrating Analytics Rules" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

    # Template-based rules
    if ($config.Options.MigrateTemplateRules) {
        $templateRulesToMigrate = @()
        $templateRulesToMigrate += $ruleClassification.TemplateRulesEnabled
        if ($config.Options.CreateDisabledRules) {
            $templateRulesToMigrate += $ruleClassification.TemplateRulesDisabled
        }

        if ($templateRulesToMigrate.Count -gt 0) {
            try {
                $results = Import-AnalyticsRules `
                    -TargetWorkspaceUri $targetWsUri `
                    -Rules $templateRulesToMigrate `
                    -Label 'template-based rules' `
                    -DryRun:$isDryRun `
                    -OverwriteExisting:($config.Options.OverwriteExisting) `
                    -CreateDisabledRules:($config.Options.CreateDisabledRules) `
                    -ThrottleDelayMs $config.Options.ThrottleMs
                $allRuleResults.AddRange(@($results))
            }
            catch {
                Write-MigrationLog -Message "Template rule migration failed: $($_.Exception.Message)" -Level 'Error' -Component 'Rules'
                $migrationErrors.Add([PSCustomObject]@{
                    Component   = 'Template Rules'
                    Message     = $_.Exception.Message
                    Remediation = 'Check that required Content Hub solutions are installed in target workspace.'
                })
            }
        }
    }

    # Custom rules
    if ($config.Options.MigrateCustomRules) {
        $customRulesToMigrate = @()
        $customRulesToMigrate += $ruleClassification.CustomRulesEnabled
        if ($config.Options.CreateDisabledRules) {
            $customRulesToMigrate += $ruleClassification.CustomRulesDisabled
        }

        if ($customRulesToMigrate.Count -gt 0) {
            try {
                $results = Import-AnalyticsRules `
                    -TargetWorkspaceUri $targetWsUri `
                    -Rules $customRulesToMigrate `
                    -Label 'custom rules' `
                    -DryRun:$isDryRun `
                    -OverwriteExisting:($config.Options.OverwriteExisting) `
                    -CreateDisabledRules:($config.Options.CreateDisabledRules) `
                    -ThrottleDelayMs $config.Options.ThrottleMs
                $allRuleResults.AddRange(@($results))
            }
            catch {
                Write-MigrationLog -Message "Custom rule migration failed: $($_.Exception.Message)" -Level 'Error' -Component 'Rules'
                $migrationErrors.Add([PSCustomObject]@{
                    Component   = 'Custom Rules'
                    Message     = $_.Exception.Message
                    Remediation = 'Review the error details. Custom rules may reference data connectors not present in target.'
                })
            }
        }
    }

    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4: MIGRATE WORKBOOKS
# ══════════════════════════════════════════════════════════════════════════════
if ($config.Options.MigrateWorkbooks -and $sourceWorkbooks.Count -gt 0) {
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host " PHASE 4: Migrating Workbooks" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

    # Resolve target workspace location. Preflight usually has it already.
    if (-not $targetLocation) {
        try {
            $targetLocation = Get-WorkspaceLocation -WorkspaceUri $targetWsUri -ThrottleDelayMs $config.Options.ThrottleMs
        }
        catch {
            $targetLocation = $null
        }
    }

    if (-not $targetLocation) {
        # Guessing a region here created workbooks in the wrong place and made
        # them undeletable from the workspace blade. Skipping is recoverable;
        # a misplaced workbook is not.
        $msg = 'Could not resolve the target workspace location, so workbook migration was skipped. Workbooks must be created in the same region as the workspace.'
        Write-MigrationLog -Message $msg -Level 'Error' -Component 'Workbooks'
        $migrationErrors.Add([PSCustomObject]@{
            Component   = 'Workbooks'
            Message     = $msg
            Remediation = "Grant Reader on the target workspace so its location can be read, then re-run. Workbook migration is otherwise idempotent and safe to repeat."
        })
    }
    else {
        try {
            $wbResults = Import-Workbooks `
                -ArmEndpoint $armEndpoint `
                -TargetSubscriptionId $config.Target.SubscriptionId `
                -TargetResourceGroupName $config.Target.ResourceGroupName `
                -TargetWorkspaceResourceId $targetWorkspaceResourceId `
                -TargetLocation $targetLocation `
                -Workbooks $sourceWorkbooks `
                -DryRun:$isDryRun `
                -OverwriteExisting:($config.Options.OverwriteExisting) `
                -ThrottleDelayMs $config.Options.ThrottleMs
            $allWorkbookResults.AddRange(@($wbResults))
        }
        catch {
            $detail = Format-ApiErrorDetail -ErrorRecord $_
            Write-MigrationLog -Message "Workbook migration failed: $detail" -Level 'Error' -Component 'Workbooks'
            $migrationErrors.Add([PSCustomObject]@{
                Component   = 'Workbooks'
                Message     = $detail
                Remediation = 'Verify Workbook Contributor role on target resource group.'
            })
        }
    }

    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5: MIGRATE WATCHLISTS
# ══════════════════════════════════════════════════════════════════════════════
if ($config.Options.MigrateWatchlists -and $sourceWatchlists.Count -gt 0) {
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host " PHASE 5: Migrating Watchlists" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

    try {
        $wlResults = Import-Watchlists `
            -SourceWorkspaceUri $sourceWsUri `
            -TargetWorkspaceUri $targetWsUri `
            -Watchlists $sourceWatchlists `
            -DryRun:$isDryRun `
            -OverwriteExisting:($config.Options.OverwriteExisting) `
            -ThrottleDelayMs $config.Options.ThrottleMs
        $allWatchlistResults.AddRange(@($wlResults))
    }
    catch {
        Write-MigrationLog -Message "Watchlist migration failed: $($_.Exception.Message)" -Level 'Error' -Component 'Watchlists'
        $migrationErrors.Add([PSCustomObject]@{
            Component   = 'Watchlists'
            Message     = $_.Exception.Message
            Remediation = 'Verify Microsoft Sentinel Contributor role on target workspace.'
        })
    }

    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6: GENERATE REPORT
# ══════════════════════════════════════════════════════════════════════════════
$endTime = Get-Date
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " PHASE 6: Generating Report" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

# Each run gets its own timestamped folder so artifacts from separate runs never mix.
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if (-not [System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir = Join-Path $scriptRoot $OutputDir }
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
$runDir = Join-Path $OutputDir "migration-$($config.Source.WorkspaceName)-to-$($config.Target.WorkspaceName)-$timestamp"
New-Item -Path $runDir -ItemType Directory -Force | Out-Null

$migrationResults = @{
    Config               = $config
    RuleClassification   = $ruleClassification
    RuleResults          = $allRuleResults.ToArray()
    WorkbookResults      = $allWorkbookResults.ToArray()
    WatchlistResults     = $allWatchlistResults.ToArray()
    ContentHubResults    = $contentHubResults
    WorkbooksDiscovered  = $workbooksDiscovered
    WatchlistsDiscovered = $watchlistsDiscovered
    Errors               = $migrationErrors.ToArray()
    StartTime            = $startTime
    EndTime              = $endTime
    DryRun               = $isDryRun
}

$sourceRules = if ($ruleClassification) { @($ruleClassification.All) } else { @() }

# ── Raw JSON snapshot ──
$rawCollections = [ordered]@{
    'SourceRules'      = $sourceRules
    'SourceWorkbooks'  = $sourceWorkbooks
    'SourceWatchlists' = $sourceWatchlists
    'RuleResults'      = $migrationResults.RuleResults
    'WorkbookResults'  = $migrationResults.WorkbookResults
    'WatchlistResults' = $migrationResults.WatchlistResults
    'ContentHub'       = @(if ($contentHubResults) { [PSCustomObject]$contentHubResults })
    'Errors'           = $migrationResults.Errors
}
Export-RawJson -Collections $rawCollections -OutputDir $runDir -Scope ([ordered]@{
    mode                    = if ($isDryRun) { 'DryRun' } else { 'Execute' }
    cloud                   = $config.Options.Cloud
    sourceSubscriptionId    = $config.Source.SubscriptionId
    sourceResourceGroupName = $config.Source.ResourceGroupName
    sourceWorkspaceName     = $config.Source.WorkspaceName
    targetSubscriptionId    = $config.Target.SubscriptionId
    targetResourceGroupName = $config.Target.ResourceGroupName
    targetWorkspaceName     = $config.Target.WorkspaceName
    tenantId                = [string]$ctx.Tenant.Id
}) | Out-Null

# ── Optional: target table coverage (opt-in, advisory) ────────────────────────
# A rule can be created successfully and still never fire, because its KQL
# references a table the target has no data in. This queries the target for
# per-table row counts so the report can distinguish "migrated" from "will work".
# Opt-in because it needs Log Analytics data-plane access, which is a separate
# grant from the ARM permissions the rest of the migration uses.
$tableCoverage = @()
if ($IncludeTableStats) {
    Write-Host ""
    Write-Host "Checking target table coverage..." -ForegroundColor Cyan

    $tableCoverage = @(Invoke-SafeCollection -Name 'Table Coverage' -ErrorSink $migrationErrors `
        -Remediation "Grant the signed-in identity Log Analytics Reader on the target workspace, or omit -IncludeTableStats." `
        -Action {
            $targetWs = Invoke-SentinelApi -Uri "$targetWsUri`?api-version=2023-09-01" -Method GET `
                -ThrottleDelayMs $config.Options.ThrottleMs
            $customerId = $targetWs.properties.customerId
            if (-not $customerId) {
                throw "Could not resolve the target workspace ID (customerId) needed for the Log Analytics query API."
            }

            # $sourceRules is already the flat rule array (see the .All unwrap at
            # discovery time) - do not unwrap it again, or every element becomes $null.
            $rulesForCoverage = @($sourceRules)
            $allTables = @($rulesForCoverage |
                ForEach-Object { Get-KqlReferencedTable -Query $_.properties.query } |
                Sort-Object -Unique)

            if ($allTables.Count -eq 0) { return @() }

            $stats = @(Get-WorkspaceTableStat -WorkspaceId $customerId -TableName $allTables `
                    -LookbackDays $TableStatsLookbackDays -ThrottleDelayMs $config.Options.ThrottleMs `
                    -Cloud $config.Options.Cloud)

            Get-RuleTableCoverage -Rules $rulesForCoverage -TableStats $stats
        })

    $noData = @($tableCoverage | Where-Object { $_.Status -eq 'NoData' })
    $partial = @($tableCoverage | Where-Object { $_.Status -eq 'PartialData' })
    Write-Host "  Rules with no data in any referenced table: $($noData.Count)" -ForegroundColor $(if ($noData.Count) { 'Yellow' } else { 'Green' })
    Write-Host "  Rules with partial table coverage:          $($partial.Count)" -ForegroundColor $(if ($partial.Count) { 'Yellow' } else { 'Green' })
}

# ── Results workbook (xlsx, CSV fallback) ──
# The same $sheets feed the HTML drill-down, so the two artifacts cannot disagree.
$sheets = New-MigrationSheets `
    -MigrationResults $migrationResults `
    -SourceRules $sourceRules `
    -SourceWorkbooks $sourceWorkbooks `
    -SourceWatchlists $sourceWatchlists

if ($IncludeTableStats) {
    $sheets['Table Coverage'] = @($tableCoverage)
}

$workbookPath = Export-MigrationWorkbook -Sheets $sheets -OutputDir $runDir -NoAutoInstall:$NoAutoInstall

# ── Migration summary HTML ──
$duration = Format-MigrationDuration -Span ($endTime - $startTime)
$htmlMeta = @{
    Mode                 = if ($isDryRun) { 'DRY RUN' } else { 'EXECUTE' }
    Cloud                = $config.Options.Cloud
    Duration             = $duration
    GeneratedAt          = $endTime.ToString('yyyy-MM-dd HH:mm:ss')
    SourceWorkspace      = $config.Source.WorkspaceName
    SourceResourceGroup  = $config.Source.ResourceGroupName
    SourceSubscriptionId = $config.Source.SubscriptionId
    TargetWorkspace      = $config.Target.WorkspaceName
    TargetResourceGroup  = $config.Target.ResourceGroupName
    TargetSubscriptionId = $config.Target.SubscriptionId
}

$details = if ($NoDetailTables) { $null } else { $sheets }
$kpis = Get-MigrationKpis -MigrationResults $migrationResults
$nextSteps = @(Get-MigrationNextSteps -MigrationResults $migrationResults)

# ── Markdown report ──
# Generated here, not earlier, so it can be handed the same KPIs, next steps and
# table coverage the dashboard uses. Recomputing them separately is how the two
# artifacts previously drifted apart.
$report = New-MigrationReport -MigrationResults $migrationResults `
    -Kpis $kpis `
    -NextSteps $nextSteps `
    -TableCoverage $tableCoverage
$reportPath = Join-Path $runDir 'migration-report.md'
Save-MigrationReport -Report $report -Path $reportPath

$html = New-MigrationOverviewHtml `
    -Meta $htmlMeta `
    -Kpis $kpis `
    -MigrationResults $migrationResults `
    -Details $details

$htmlPath = Join-Path $runDir 'Migration-Summary.html'
Save-MigrationOverviewHtml -Html $html -Path $htmlPath

# ── Agent input (projected evidence for downstream AI reporting) ──
# Built from the same $sheets as the workbook and HTML, so all three agree.
$agentInputPath = Export-AgentInput -Sheets $sheets -OutputDir $runDir -Kpis $kpis -NextSteps $nextSteps -Scope ([ordered]@{
    mode                    = if ($isDryRun) { 'DryRun' } else { 'Execute' }
    cloud                   = $config.Options.Cloud
    sourceSubscriptionId    = $config.Source.SubscriptionId
    sourceResourceGroupName = $config.Source.ResourceGroupName
    sourceWorkspaceName     = $config.Source.WorkspaceName
    targetSubscriptionId    = $config.Target.SubscriptionId
    targetResourceGroupName = $config.Target.ResourceGroupName
    targetWorkspaceName     = $config.Target.WorkspaceName
    tenantId                = [string]$ctx.Tenant.Id
    toolVersion             = $toolVersion
})

# Export structured log (written last so it captures the export steps above)
$logPath = Join-Path $runDir 'migration-log.jsonl'
Export-MigrationLog -Path $logPath

# ── Summary ───────────────────────────────────────────────────────────────────
# Counts come from Get-MigrationKpis, the same function the HTML dashboard uses,
# so the console and the report cannot disagree. Hand-rolled -match 'Created'
# counting previously folded CreatedDisabled into the created total.
$hasFailures = ($kpis['Rules Failed'] + $kpis['Workbooks Failed'] + $kpis['Watchlists Failed'] + $kpis['Errors']) -gt 0
$headerColor = if ($hasFailures) { 'Yellow' } else { 'Green' }
$headerText  = if ($hasFailures) { "Migration Completed With Failures ($modeLabel)" } else { "Migration Complete ($modeLabel)" }

Write-Host ""
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor $headerColor
Write-Host " $headerText" -ForegroundColor $headerColor
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor $headerColor

Write-Host ("  Rules:      {0} created, {1} created disabled, {2} updated, {3} skipped, {4} failed" -f `
    $kpis['Rules Created'], $kpis['Rules Disabled'], $kpis['Rules Updated'], $kpis['Rules Skipped'], $kpis['Rules Failed']) -ForegroundColor White
Write-Host ("  Workbooks:  {0} migrated, {1} failed" -f `
    $kpis['Workbooks Migrated'], $kpis['Workbooks Failed']) -ForegroundColor White
Write-Host ("  Watchlists: {0} migrated, {1} failed" -f `
    $kpis['Watchlists Migrated'], $kpis['Watchlists Failed']) -ForegroundColor White
Write-Host ("  Solutions:  {0} installed, {1} upgraded, {2} unresolved" -f `
    $kpis['Solutions Installed'], $kpis['Solutions Upgraded'], $kpis['Manual Checklist']) -ForegroundColor White
if ($kpis['Errors'] -gt 0) {
    Write-Host "  Errors:     $($kpis['Errors']) (see report for details)" -ForegroundColor Red
}
Write-Host ""
Write-Host "  Output:   $runDir" -ForegroundColor Cyan
Write-Host "  Summary:  $htmlPath" -ForegroundColor Cyan
Write-Host "  Workbook: $workbookPath" -ForegroundColor Cyan
Write-Host "  Report:   $reportPath" -ForegroundColor Cyan
Write-Host "  Log:      $logPath" -ForegroundColor Cyan
Write-Host "  Agent:    $agentInputPath" -ForegroundColor Cyan
Write-Host ""

# ── Next steps ────────────────────────────────────────────────────────────────
# The same list the HTML dashboard renders. An operator who never opens the
# HTML still learns what is left to do by hand.
if ($nextSteps.Count -gt 0) {
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host " Next Steps" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

    foreach ($step in $nextSteps) {
        $color = switch ($step.Tone) {
            'bad'  { 'Red' }
            'warn' { 'Yellow' }
            'good' { 'Green' }
            default { 'White' }
        }
        $countSuffix = if ($step.Count -gt 0) { " ($($step.Count))" } else { '' }
        Write-Host ("  {0}. {1}{2}" -f $step.Order, $step.Title, $countSuffix) -ForegroundColor $color
        foreach ($line in ($step.Detail -split "`n")) {
            if ($line.Trim()) { Write-Host "     $($line.TrimEnd())" -ForegroundColor DarkGray }
        }
    }
    Write-Host ""
    Write-Host "  Full detail: $htmlPath" -ForegroundColor Cyan
    Write-Host ""
}

# ── Exit code ─────────────────────────────────────────────────────────────────
# 0 = success, 1 = completed with failures, 2 = fatal (set at the failure site).
# Previously the script always exited 0, so a run that migrated nothing looked
# identical to a clean run in CI.
if ($hasFailures) { $script:ExitCode = 1 }
exit $script:ExitCode
