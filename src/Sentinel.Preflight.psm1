<#
.SYNOPSIS
    Fail-fast checks that run before the migration touches anything.
.DESCRIPTION
    Three gates, in the order they matter:

      1. Assert-MigrationPrerequisite - is this machine able to run the tool at
         all? Deliberately free of Az dependencies so it can run BEFORE the other
         modules are imported, turning a cryptic #Requires failure into an
         actionable install command.

      2. Test-WorkspaceAccess - does the target actually exist, is Sentinel
         enabled on it, and can this identity write to it? Previously the first
         target write happened in phase 3, so a permissions problem surfaced only
         after minutes of work and a partially-migrated workspace.

      3. Confirm-MigrationExecution - show what is about to be written to
         production and require explicit consent.
#>

# Sentinel.Common is itself Az-free, so importing it here preserves this
# module's ability to load before the Az-dependent modules.
Import-Module (Join-Path $PSScriptRoot 'Sentinel.Common.psm1') -Force -DisableNameChecking

# ── 1. Machine prerequisites ──────────────────────────────────────────────────

function Test-ModulePresent {
    <#
    .SYNOPSIS
        Returns the highest installed version of a module, or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $found = Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($found) { return $found.Version }
    return $null
}

function Install-MissingModule {
    <#
    .SYNOPSIS
        Attempts a CurrentUser install of a missing module, returning the version on success.
    .DESCRIPTION
        Isolated from Assert-MigrationPrerequisite so the decision to install and the
        mechanics of installing can be tested separately, and so any failure here is
        non-fatal: the caller falls back to the normal blocking message with manual
        install instructions.

        Installation is deliberately scoped to CurrentUser. Machine-wide installs need
        elevation, which a migration run should never silently demand.
    .PARAMETER Name
        Module to install.
    .PARAMETER Quiet
        Suppress console output; the return value still reports the outcome.
    .OUTPUTS
        The installed version string, or $null if the install did not succeed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Quiet
    )

    if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) {
        return $null
    }

    if (-not $Quiet) { Write-Host "  [....] Installing $Name (CurrentUser)..." -ForegroundColor Cyan }

    try {
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    catch {
        if (-not $Quiet) { Write-Host "  [WARN] Could not install ${Name}: $($_.Exception.Message)" -ForegroundColor Yellow }
        return $null
    }

    # Confirm it is actually loadable now rather than trusting the install call.
    return (Test-ModulePresent -Name $Name)
}

function Assert-MigrationPrerequisite {
    <#
    .SYNOPSIS
        Verifies PowerShell version and required/optional modules before any work starts.
    .DESCRIPTION
        Required modules are blocking and report the exact Install-Module command
        plus why the module is needed. Optional modules warn and explain what
        degrades without them, so a missing nice-to-have never stops a migration.

        A missing powershell-yaml is installed automatically, because it is needed
        only to read the config file the operator already wrote - failing the run and
        asking them to type one command adds friction without adding a decision. The
        install is CurrentUser-scoped, never elevates, and falls back to the normal
        blocking message if it does not succeed. Use -NoAutoInstall in locked-down or
        CI environments where package installs are governed elsewhere.
    .PARAMETER RequireYaml
        Set when a YAML config file was supplied, making powershell-yaml blocking
        rather than optional. A JSON config needs no third-party parser at all.
    .PARAMETER NoAutoInstall
        Never attempt to install a missing module; report it as blocking instead.
    .PARAMETER Quiet
        Suppress the per-check console output; findings are still returned.
    .OUTPUTS
        PSCustomObject with Ok, Blocking and Warnings.
    #>
    [CmdletBinding()]
    param(
        [switch]$RequireYaml,
        [switch]$NoAutoInstall,
        [switch]$Quiet
    )

    $blocking = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if (-not $Quiet) { Write-Host "[PREFLIGHT] Checking prerequisites..." -ForegroundColor Cyan }

    # ── PowerShell version ──
    $psv = $PSVersionTable.PSVersion
    if ($psv.Major -lt 7) {
        $blocking.Add("PowerShell 7.0 or later is required (found $psv). Install from https://aka.ms/powershell-release")
    }
    elseif (-not $Quiet) {
        Write-Host "  [OK]   PowerShell $psv" -ForegroundColor Green
    }

    # ── Required modules ──
    # AutoInstall is opt-in per module. Az.Accounts is a large dependency that many
    # organisations pre-stage and pin, so installing it unasked would be presumptuous.
    $required = @(
        @{ Name = 'Az.Accounts'; Why = 'Azure authentication and ARM token acquisition.'; AutoInstall = $false }
    )
    if ($RequireYaml) {
        $required += @{
            Name        = 'powershell-yaml'
            Why         = 'Parsing the YAML config file. Convert the config to JSON to remove this dependency.'
            AutoInstall = $true
        }
    }

    foreach ($m in $required) {
        $ver = Test-ModulePresent -Name $m.Name

        if (-not $ver -and $m.AutoInstall -and -not $NoAutoInstall) {
            $ver = Install-MissingModule -Name $m.Name -Quiet:$Quiet
        }

        if ($ver) {
            if (-not $Quiet) { Write-Host "  [OK]   $($m.Name) $ver" -ForegroundColor Green }
        }
        else {
            $blocking.Add("Missing required module '$($m.Name)' - $($m.Why)`n         Install with: Install-Module -Name $($m.Name) -Scope CurrentUser")
        }
    }

    # ── Optional modules ──
    $optional = @(
        @{ Name = 'ImportExcel'; Degrades = 'Results export falls back to CSV files instead of a single .xlsx workbook.' }
    )

    foreach ($m in $optional) {
        $ver = Test-ModulePresent -Name $m.Name
        if ($ver) {
            if (-not $Quiet) { Write-Host "  [OK]   $($m.Name) $ver (optional)" -ForegroundColor Green }
        }
        else {
            $warnings.Add("Optional module '$($m.Name)' not installed - $($m.Degrades)`n         Install with: Install-Module -Name $($m.Name) -Scope CurrentUser")
        }
    }

    # ── Conflicting in-process modules ──
    # Uses Get-Module (not -ListAvailable) on purpose: only a module already
    # loaded into THIS session can cause the assembly clash, so merely having it
    # installed is not a problem worth warning about.
    $conflicts = @('ExchangeOnlineManagement', 'MicrosoftTeams')
    foreach ($c in $conflicts) {
        if (Get-Module -Name $c -ErrorAction SilentlyContinue) {
            $warnings.Add("Module '$c' is loaded in this session and shares authentication libraries with Az. If you hit token errors, run the migration in a fresh PowerShell session.")
        }
    }

    if (-not $Quiet) {
        foreach ($w in $warnings) { Write-Host "  [WARN] $w" -ForegroundColor Yellow }
        foreach ($b in $blocking) { Write-Host "  [FAIL] $b" -ForegroundColor Red }
        Write-Host ""
    }

    return [PSCustomObject]@{
        Ok       = ($blocking.Count -eq 0)
        Blocking = $blocking.ToArray()
        Warnings = $warnings.ToArray()
    }
}

# ── 2. Target reachability and permissions ────────────────────────────────────

function Test-ArmActionAllowed {
    <#
    .SYNOPSIS
        Evaluates an ARM action string against a permission set's actions/notActions.
    .DESCRIPTION
        ARM wildcards are glob-style, so each entry becomes an anchored regex.
        notActions subtract from actions, matching ARM's own evaluation order.
    .PARAMETER Permissions
        The value[] array from the Microsoft.Authorization/permissions response.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [object[]]$Permissions
    )

    $toRegex = {
        param([string]$Pattern)
        '^' + ([regex]::Escape($Pattern) -replace '\\\*', '.*') + '$'
    }

    foreach ($p in @($Permissions)) {
        if (-not $p) { continue }
        $granted = $false
        foreach ($a in @($p.actions)) {
            if ($a -and $Action -match (& $toRegex $a)) { $granted = $true; break }
        }
        if (-not $granted) { continue }

        $denied = $false
        foreach ($na in @($p.notActions)) {
            if ($na -and $Action -match (& $toRegex $na)) { $denied = $true; break }
        }
        if (-not $denied) { return $true }
    }
    return $false
}

function Test-WorkspaceAccess {
    <#
    .SYNOPSIS
        Verifies a workspace exists, Sentinel is enabled, and the caller has the
        access level this run needs.
    .DESCRIPTION
        Runs before phase 1 so an unreachable target or a missing role is reported
        in seconds, rather than after the source has been enumerated and rules
        have already been written.

        The permission probe is best-effort: some identities cannot read their own
        role assignments, and that is not itself a failure. When the probe cannot
        run, this reports Unknown and lets the migration proceed rather than
        blocking on a check that is only advisory.
    .PARAMETER WorkspaceUri
        Full Sentinel workspace URI (…/providers/Microsoft.OperationalInsights/workspaces/x).
    .PARAMETER ArmEndpoint
        ARM endpoint for the active cloud.
    .PARAMETER RequireWrite
        Probe for write permission as well as read. Skipped for dry runs.
    .PARAMETER Label
        'Source' or 'Target', used in messages.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri,
        [Parameter(Mandatory)][string]$ArmEndpoint,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [switch]$RequireWrite,
        [string]$Label = 'Target',
        [int]$ThrottleDelayMs = 100
    )

    $result = [PSCustomObject]@{
        Label           = $Label
        WorkspaceExists = $false
        SentinelEnabled = $false
        CanWrite        = 'Unknown'
        Location        = $null
        Problems        = @()
        Ok              = $false
    }
    $problems = [System.Collections.Generic.List[string]]::new()

    # ── Workspace exists ──
    try {
        $ws = Invoke-SentinelApi -Uri "$WorkspaceUri`?api-version=2023-09-01" -Method GET -ThrottleDelayMs $ThrottleDelayMs
        $result.WorkspaceExists = $true
        $result.Location = $ws.location
    }
    catch {
        $detail = Format-ApiErrorDetail -ErrorRecord $_
        $status = Get-ApiErrorStatusCode -ErrorRecord $_
        if ($status -eq 404) {
            $problems.Add("$Label workspace not found. Check subscription, resource group and workspace name.")
        }
        elseif ($status -eq 401) {
            # A subscription in a different tenant fails here rather than at sign-in,
            # because the token is tenant-scoped. Say so, or this reads as a role problem.
            $problems.Add("Not authorised for the $Label subscription. This tool migrates between workspaces in a single tenant - confirm subscription $SubscriptionId belongs to the tenant you signed in to. ($detail)")
        }
        elseif ($status -eq 403) {
            $problems.Add("Access denied reading the $Label workspace. You need at least Reader on the workspace. ($detail)")
        }
        else {
            $problems.Add("Could not read the $Label workspace: $detail")
        }
        $result.Problems = $problems.ToArray()
        return $result
    }

    # ── Sentinel enabled ──
    # Listing alert rules is the cheapest positive signal: it succeeds only when
    # the SecurityInsights provider is actually onboarded to this workspace.
    try {
        $apiVersion = Get-SentinelApiVersion -Resource 'alertRules'
        Invoke-SentinelApi -Uri "$WorkspaceUri/providers/Microsoft.SecurityInsights/alertRules?api-version=$apiVersion" `
            -Method GET -ThrottleDelayMs $ThrottleDelayMs | Out-Null
        $result.SentinelEnabled = $true
    }
    catch {
        $detail = Format-ApiErrorDetail -ErrorRecord $_
        $status = Get-ApiErrorStatusCode -ErrorRecord $_
        if ($status -eq 403) {
            $problems.Add("Access denied listing analytics rules on the $Label workspace. You need Microsoft Sentinel Reader or higher. ($detail)")
        }
        else {
            $problems.Add("Microsoft Sentinel does not appear to be enabled on the $Label workspace, or it is unreachable: $detail")
        }
    }

    # ── Write permission ──
    if ($RequireWrite) {
        $needed = @(
            'Microsoft.SecurityInsights/alertRules/write'
            'Microsoft.SecurityInsights/contentPackages/write'
            'Microsoft.SecurityInsights/watchlists/write'
            'Microsoft.Insights/workbooks/write'
        )
        try {
            $scope = "$ArmEndpoint/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
            $perms = Invoke-SentinelApi -Uri "$scope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" `
                -Method GET -ThrottleDelayMs $ThrottleDelayMs
            $permSet = @($perms.value)

            $missing = @($needed | Where-Object { -not (Test-ArmActionAllowed -Action $_ -Permissions $permSet) })
            if ($missing.Count -eq 0) {
                $result.CanWrite = 'Yes'
            }
            else {
                $result.CanWrite = 'No'
                $problems.Add("The signed-in identity is missing write permission on the $Label resource group for: $($missing -join ', '). Assign 'Microsoft Sentinel Contributor' on the workspace and 'Monitoring Contributor' on the resource group.")
            }
        }
        catch {
            # Not being able to read your own permissions is common for some
            # service principals - advisory only, never blocking.
            $result.CanWrite = 'Unknown'
        }
    }

    $result.Problems = $problems.ToArray()
    $result.Ok = ($problems.Count -eq 0)
    return $result
}

# ── 3. Consent before writing to production ───────────────────────────────────

function Show-MigrationPlan {
    <#
    .SYNOPSIS
        Prints what the run is about to write, before it writes any of it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Plan
    )

    Write-Host ""
    Write-Host "  About to modify the TARGET workspace:" -ForegroundColor Yellow
    Write-Host "    Workspace:      $($Plan.TargetWorkspace)" -ForegroundColor White
    Write-Host "    Resource group: $($Plan.TargetResourceGroup)" -ForegroundColor White
    Write-Host "    Subscription:   $($Plan.TargetSubscriptionId)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Planned changes:" -ForegroundColor Yellow
    Write-Host "    Analytics rules to migrate: $($Plan.RuleCount)" -ForegroundColor White
    Write-Host "    Workbooks to migrate:       $($Plan.WorkbookCount)" -ForegroundColor White
    Write-Host "    Watchlists to migrate:      $($Plan.WatchlistCount)" -ForegroundColor White
    if ($Plan.OverwriteExisting) {
        Write-Host "    Overwrite existing items:   YES - existing target items will be replaced" -ForegroundColor Red
    }
    else {
        Write-Host "    Overwrite existing items:   No - existing target items are skipped" -ForegroundColor White
    }
    Write-Host ""
}

function Confirm-MigrationExecution {
    <#
    .SYNOPSIS
        Requires explicit consent before an execute run writes to the target.
    .DESCRIPTION
        The operator types the target workspace name. That is deliberately harder
        than pressing 'y': the failure this guards against is running a correct
        command against the wrong workspace, which a yes/no prompt does not catch.

        Non-interactive sessions must pass -Force. Prompting into a redirected
        host would either hang a pipeline or silently auto-approve, and both are
        worse than a clear refusal.
    .PARAMETER Force
        Bypass the prompt, for automation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetWorkspace,
        [switch]$Force
    )

    if ($Force) {
        Write-Host "  -Force specified: proceeding without confirmation." -ForegroundColor Yellow
        return $true
    }

    $interactive = $true
    try { $interactive = -not [System.Console]::IsInputRedirected } catch { $interactive = $false }

    if (-not $interactive) {
        throw "Execute mode requires confirmation, but this session is not interactive. Re-run with -Force to proceed without prompting."
    }

    Write-Host "  Type the target workspace name to confirm (or press Enter to cancel):" -ForegroundColor Yellow
    Write-Host "  > " -ForegroundColor Yellow -NoNewline
    $answer = Read-Host

    if ($answer -eq $TargetWorkspace) {
        Write-Host "  Confirmed." -ForegroundColor Green
        Write-Host ""
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($answer)) {
        Write-Host "  Cancelled." -ForegroundColor Yellow
    }
    else {
        Write-Host "  '$answer' does not match '$TargetWorkspace'. Cancelled." -ForegroundColor Red
    }
    return $false
}

Export-ModuleMember -Function @(
    'Test-ModulePresent'
    'Install-MissingModule'
    'Assert-MigrationPrerequisite'
    'Test-ArmActionAllowed'
    'Test-WorkspaceAccess'
    'Show-MigrationPlan'
    'Confirm-MigrationExecution'
)
