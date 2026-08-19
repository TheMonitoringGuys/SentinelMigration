<#
.SYNOPSIS
    Content Hub solution discovery and installation for Microsoft Sentinel.
.DESCRIPTION
    Maps template-based analytics rules to Content Hub solutions, installs solutions
    when supported, and generates manual install checklists as a fallback.
#>

Import-Module (Join-Path $PSScriptRoot 'Sentinel.Common.psm1') -Force -DisableNameChecking

# ── Discovery ─────────────────────────────────────────────────────────────────
function Get-InstalledContentPackages {
    <#
    .SYNOPSIS
        Lists Content Hub solutions already installed in a workspace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri,
        [int]$ThrottleDelayMs = 100
    )

    $uri = Get-ContentPackagesUri -WorkspaceUri $WorkspaceUri
    Write-Host "  Fetching installed content packages..." -ForegroundColor Cyan
    try {
        $packages = @(Invoke-SentinelApiList -Uri $uri -ThrottleDelayMs $ThrottleDelayMs)
        Write-Host "  Found $($packages.Count) installed package(s)" -ForegroundColor Cyan
        return @($packages)
    }
    catch {
        Write-Warning "  Could not list installed content packages: $($_.Exception.Message)"
        return @()
    }
}

function Get-AvailableContentPackages {
    <#
    .SYNOPSIS
        Lists Content Hub solutions available in the catalog for a workspace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri,
        [int]$ThrottleDelayMs = 100
    )

    $uri = Get-ContentProductPackagesUri -WorkspaceUri $WorkspaceUri
    Write-Host "  Fetching available content catalog..." -ForegroundColor Cyan
    try {
        $packages = @(Invoke-SentinelApiList -Uri $uri -ThrottleDelayMs $ThrottleDelayMs)
        Write-Host "  Found $($packages.Count) available package(s) in catalog" -ForegroundColor Cyan
        return @($packages)
    }
    catch {
        Write-Warning "  Could not list content catalog: $($_.Exception.Message)"
        return @()
    }
}

# ── Template → Solution Mapping ──────────────────────────────────────────────
function Get-ContentTemplateIndex {
    <#
    .SYNOPSIS
        Indexes a workspace's Content Hub analytics-rule templates by template id.
    .DESCRIPTION
        The legacy alertRuleTemplates endpoint — the one the rest of the tool reads
        templates from — returns no package identity whatsoever: no packageId, no
        packageName, no source block. Every lookup against it comes back "Unknown", so
        the template → solution mapping it feeds could never resolve anything.

        contentTemplates is the endpoint that carries that identity. Its contentId is
        the same template id a rule stores in alertRuleTemplateName, and its packageId
        matches the contentId of the corresponding contentPackages entry, which is what
        makes the join to installed and catalog packages possible.

        Templates only exist here for solutions installed in the workspace, so this is
        read from the source: that is where the rules being migrated came from.
    .OUTPUTS
        Hashtable keyed by template id (contentId), valued with the template object.
        Empty on failure — the mapping degrades to "could not determine" rather than
        taking the migration down with it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceUri,
        [int]$ThrottleDelayMs = 100
    )

    $index = @{}
    $uri = Get-ContentTemplateUri -WorkspaceUri $WorkspaceUri -ContentKind 'AnalyticsRule'
    Write-Host "  Fetching Content Hub rule templates from source..." -ForegroundColor Cyan
    try {
        $templates = @(Invoke-SentinelApiList -Uri $uri -ThrottleDelayMs $ThrottleDelayMs)
    }
    catch {
        Write-Warning "  Could not list Content Hub templates: $($_.Exception.Message)"
        Write-Warning "  Rules cannot be mapped to their solutions; the manual checklist will say so."
        return $index
    }

    foreach ($t in $templates) {
        if (-not $t) { continue }
        $cid = $t.properties.contentId
        if ([string]::IsNullOrWhiteSpace($cid)) { continue }
        $index[[string]$cid] = $t
    }

    Write-Host "  Found $($index.Count) Content Hub rule template(s)" -ForegroundColor Cyan
    return $index
}

function Get-TemplatePackageRef {
    <#
    .SYNOPSIS
        Reads the Content Hub package identity that a rule template declares, if any.
    .DESCRIPTION
        The authoritative answer is the matching contentTemplates record, so that is
        checked first when one is supplied. Failing that, the legacy alert rule template
        is inspected for package identity under the property names it has used across
        API versions — in practice it carries none, but reading it costs nothing and
        keeps the function useful for callers that have no Content Hub index.

        It returns nulls when nothing says, and never guesses. Naming the wrong solution
        is worse for the operator than admitting the mapping is unknown, because in the
        checklist a wrong name reads exactly like a right one.
    .PARAMETER ContentTemplate
        The contentTemplates record for this template, when one was found.
    .OUTPUTS
        Object with PackageId, PackageName and Source.
    #>
    [CmdletBinding()]
    param(
        [object]$Template,
        [object]$ContentTemplate
    )

    $ref = [PSCustomObject]@{ PackageId = $null; PackageName = $null; Source = 'Unknown' }

    # Content Hub's own record wins: it is the only source that reliably has this.
    $chProps = if ($ContentTemplate) { $ContentTemplate.properties } else { $null }
    if ($chProps) {
        if (-not [string]::IsNullOrWhiteSpace($chProps.packageId)) {
            $ref.PackageId = [string]$chProps.packageId
            $ref.Source = 'ContentHubTemplate'
        }
        if (-not [string]::IsNullOrWhiteSpace($chProps.packageName)) {
            $ref.PackageName = [string]$chProps.packageName
            if ($ref.Source -eq 'Unknown') { $ref.Source = 'ContentHubTemplate' }
        }
        if ($ref.PackageId -and $ref.PackageName) { return $ref }
    }

    if (-not $Template) { return $ref }

    $props = $Template.properties
    if (-not $props) { return $ref }

    if (-not $ref.PackageId -and -not [string]::IsNullOrWhiteSpace($props.packageId)) {
        $ref.PackageId = [string]$props.packageId
        if ($ref.Source -eq 'Unknown') { $ref.Source = 'TemplateMetadata' }
    }

    if (-not $ref.PackageName) {
        if (-not [string]::IsNullOrWhiteSpace($props.packageName)) {
            $ref.PackageName = [string]$props.packageName
            if ($ref.Source -eq 'Unknown') { $ref.Source = 'TemplateMetadata' }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($props.packageDisplayName)) {
            $ref.PackageName = [string]$props.packageDisplayName
            if ($ref.Source -eq 'Unknown') { $ref.Source = 'TemplateMetadata' }
        }
    }

    $src = $props.source
    if ($src) {
        if (-not $ref.PackageId -and -not [string]::IsNullOrWhiteSpace($src.sourceId)) {
            $ref.PackageId = [string]$src.sourceId
            if ($ref.Source -eq 'Unknown') { $ref.Source = 'TemplateSource' }
        }
        if (-not $ref.PackageName -and -not [string]::IsNullOrWhiteSpace($src.name)) {
            $ref.PackageName = [string]$src.name
            if ($ref.Source -eq 'Unknown') { $ref.Source = 'TemplateSource' }
        }
    }

    return $ref
}

function Build-TemplateSolutionMap {
    <#
    .SYNOPSIS
        Maps alert rule template IDs to Content Hub solution/package names.
    .DESCRIPTION
        Resolves each template's declared package identity against the installed and
        available package lists. A template is only associated with a solution when an
        identity actually matches — by contentId, or failing that by exact display name.
        Templates that declare nothing keep a null SolutionName so callers can say so
        plainly rather than presenting a guess as fact.

        Returns a hashtable keyed by template ID.
    .PARAMETER ContentTemplateIndex
        Content Hub templates keyed by template id, from Get-ContentTemplateIndex. This
        is what supplies package identity in practice: alert rule templates themselves
        carry none, so without this index every template resolves to Unknown. It also
        widens coverage — templates shipped by installed solutions appear only here, not
        in the legacy alertRuleTemplates list, and the map spans both.
    #>
    [CmdletBinding()]
    param(
        [object[]]$AlertRuleTemplates,
        [object[]]$AvailablePackages,
        [object[]]$InstalledPackages,
        [hashtable]$ContentTemplateIndex
    )

    $map = @{}

    # Index both package lists by id and by display name, so a template that names its
    # solution without giving an id can still be resolved.
    $installedById = @{}; $installedByName = @{}
    foreach ($pkg in $InstalledPackages) {
        if (-not $pkg) { continue }
        $id = $pkg.properties.contentId
        if (-not [string]::IsNullOrWhiteSpace($id)) { $installedById[[string]$id] = $pkg }
        $nm = $pkg.properties.displayName
        if (-not [string]::IsNullOrWhiteSpace($nm)) { $installedByName[[string]$nm] = $pkg }
    }

    $availableById = @{}; $availableByName = @{}
    foreach ($pkg in $AvailablePackages) {
        if (-not $pkg) { continue }
        $id = $pkg.properties.contentId
        if (-not [string]::IsNullOrWhiteSpace($id)) { $availableById[[string]$id] = $pkg }
        $nm = $pkg.properties.displayName
        if (-not [string]::IsNullOrWhiteSpace($nm)) { $availableByName[[string]$nm] = $pkg }
    }

    # The two endpoints do not cover the same set. Legacy alertRuleTemplates returns the
    # built-in catalogue; contentTemplates returns whatever the installed solutions ship,
    # and that is where most rules' templates actually live — a workspace can easily have
    # hundreds of solution templates that appear nowhere in the legacy list. Mapping only
    # the legacy list leaves every solution-supplied rule unresolved, so walk the union.
    $pairs = [System.Collections.Generic.List[object]]::new()
    $seen = @{}

    foreach ($template in $AlertRuleTemplates) {
        if (-not $template) { continue }
        $templateId = $template.name
        if ([string]::IsNullOrWhiteSpace($templateId)) { continue }
        $key = [string]$templateId
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $ct = $null
        if ($ContentTemplateIndex) { $ct = $ContentTemplateIndex[$key] }
        $pairs.Add([PSCustomObject]@{ Id = $key; Legacy = $template; Content = $ct })
    }

    if ($ContentTemplateIndex) {
        foreach ($ctKey in $ContentTemplateIndex.Keys) {
            $key = [string]$ctKey
            if ([string]::IsNullOrWhiteSpace($key) -or $seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $pairs.Add([PSCustomObject]@{ Id = $key; Legacy = $null; Content = $ContentTemplateIndex[$ctKey] })
        }
    }

    foreach ($pair in $pairs) {
        $templateId = $pair.Id
        $template = $pair.Legacy
        $contentTemplate = $pair.Content

        $ref = Get-TemplatePackageRef -Template $template -ContentTemplate $contentTemplate

        $displayName = $null
        if ($template) { $displayName = $template.properties.displayName }
        if ([string]::IsNullOrWhiteSpace($displayName) -and $contentTemplate) {
            $displayName = $contentTemplate.properties.displayName
        }

        $entry = @{
            TemplateId   = [string]$templateId
            DisplayName  = $displayName
            SolutionName = $null
            PackageId    = $ref.PackageId
            IsInstalled  = $false
            Source       = $ref.Source
        }

        # Prefer the installed copy: that is the name the operator sees in the portal,
        # and finding it there is also what tells us the solution is already present.
        $match = $null
        if ($ref.PackageId) {
            if ($installedById.ContainsKey($ref.PackageId)) {
                $match = $installedById[$ref.PackageId]; $entry.IsInstalled = $true
            }
            elseif ($availableById.ContainsKey($ref.PackageId)) {
                $match = $availableById[$ref.PackageId]
            }
        }
        if (-not $match -and $ref.PackageName) {
            if ($installedByName.ContainsKey($ref.PackageName)) {
                $match = $installedByName[$ref.PackageName]; $entry.IsInstalled = $true
            }
            elseif ($availableByName.ContainsKey($ref.PackageName)) {
                $match = $availableByName[$ref.PackageName]
            }
        }

        if ($match) {
            $entry.SolutionName = $match.properties.displayName
            if (-not $entry.PackageId) {
                $cid = $match.properties.contentId
                if (-not [string]::IsNullOrWhiteSpace($cid)) { $entry.PackageId = [string]$cid }
            }
            if ($entry.Source -eq 'Unknown') { $entry.Source = 'Catalog' }
        }
        elseif ($ref.PackageName) {
            # The template named a solution the catalog does not list — still worth
            # showing the operator, since it came from the template rather than a guess.
            $entry.SolutionName = $ref.PackageName
        }

        $map[[string]$templateId] = [PSCustomObject]$entry
    }

    return $map
}

# ── Source → Target Solution Diff ────────────────────────────────────────────
function Compare-ContentPackageVersion {
    <#
    .SYNOPSIS
        Compares two Content Hub version strings. Returns -1, 0 or 1 (Left vs Right).
    .DESCRIPTION
        Most versions parse as [version] ('2.0.0', '1.4'). Some carry a suffix such as
        '2.0.0-preview', which [version] rejects. Falling back to an ordinal string
        compare keeps an unparseable version from throwing mid-migration; being wrong
        about the ordering of a preview build costs one needless skip, whereas throwing
        costs the run.
    #>
    [CmdletBinding()]
    param([string]$Left, [string]$Right)

    $leftEmpty = [string]::IsNullOrWhiteSpace($Left)
    $rightEmpty = [string]::IsNullOrWhiteSpace($Right)
    if ($leftEmpty -and $rightEmpty) { return 0 }
    if ($leftEmpty) { return -1 }
    if ($rightEmpty) { return 1 }

    $lv = $null; $rv = $null
    if ([version]::TryParse($Left, [ref]$lv) -and [version]::TryParse($Right, [ref]$rv)) {
        return $lv.CompareTo($rv)
    }

    return [string]::Compare($Left, $Right, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-PackageInstalledVersion {
    <#
    .SYNOPSIS
        Reads the version actually installed in a workspace, not the catalog latest.
    #>
    [CmdletBinding()]
    param([object]$Package)

    if (-not $Package -or -not $Package.properties) { return $null }
    $installed = $Package.properties.installedVersion
    if (-not [string]::IsNullOrWhiteSpace([string]$installed)) { return [string]$installed }
    # contentPackages entries represent installed solutions, so a missing
    # installedVersion still means "this version is present".
    if (-not [string]::IsNullOrWhiteSpace([string]$Package.properties.version)) {
        return [string]$Package.properties.version
    }
    return $null
}

function Get-SolutionMigrationPlan {
    <#
    .SYNOPSIS
        Classifies every solution installed in source against the target's state.
    .DESCRIPTION
        This is the piece that makes the tool migrate solutions rather than merely
        react to analytics rules. Previously the installed-package list was only ever
        read from the target, so the source workspace's solution set was invisible and
        anything not named by a migrating rule template was silently skipped.

        Each source solution lands in exactly one class:

          ToInstall      absent from target
          ToUpgrade      present but older than source
          AlreadyCurrent present at the same version or newer
          NotInCatalog   installed in source but absent from the target's catalog

        NotInCatalog is a real state, not defensive padding: catalogs differ between
        Commercial and Gov, and solutions are withdrawn. It has to reach the operator
        as an explicit "this cannot be automated" rather than a silent omission.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$SourceInstalled = @(),
        [AllowEmptyCollection()][object[]]$TargetInstalled = @(),
        [AllowEmptyCollection()][object[]]$TargetCatalog = @()
    )

    $plan = [PSCustomObject]@{
        ToInstall      = [System.Collections.Generic.List[object]]::new()
        ToUpgrade      = [System.Collections.Generic.List[object]]::new()
        AlreadyCurrent = [System.Collections.Generic.List[object]]::new()
        NotInCatalog   = [System.Collections.Generic.List[object]]::new()
    }

    $targetById = @{}
    foreach ($pkg in $TargetInstalled) {
        if (-not $pkg) { continue }
        $id = [string]$pkg.properties.contentId
        if (-not [string]::IsNullOrWhiteSpace($id)) { $targetById[$id] = $pkg }
    }

    $catalogById = @{}
    foreach ($pkg in $TargetCatalog) {
        if (-not $pkg) { continue }
        $id = [string]$pkg.properties.contentId
        if (-not [string]::IsNullOrWhiteSpace($id)) { $catalogById[$id] = $pkg }
    }

    foreach ($src in $SourceInstalled) {
        if (-not $src) { continue }
        $id = [string]$src.properties.contentId
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $sourceVersion = Get-PackageInstalledVersion -Package $src
        $displayName = [string]$src.properties.displayName

        if (-not $catalogById.ContainsKey($id)) {
            $plan.NotInCatalog.Add([PSCustomObject]@{
                PackageId     = $id
                DisplayName   = $displayName
                SourceVersion = $sourceVersion
                Reason        = "Installed in source but not offered by the target workspace's Content Hub catalog"
            })
            continue
        }

        $catalogPkg = $catalogById[$id]

        if (-not $targetById.ContainsKey($id)) {
            $plan.ToInstall.Add([PSCustomObject]@{
                PackageId     = $id
                DisplayName   = $displayName
                SourceVersion = $sourceVersion
                TargetVersion = $null
                Package       = $catalogPkg
            })
            continue
        }

        $targetVersion = Get-PackageInstalledVersion -Package $targetById[$id]
        $entry = [PSCustomObject]@{
            PackageId     = $id
            DisplayName   = $displayName
            SourceVersion = $sourceVersion
            TargetVersion = $targetVersion
            Package       = $catalogPkg
        }

        if ((Compare-ContentPackageVersion -Left $targetVersion -Right $sourceVersion) -lt 0) {
            $plan.ToUpgrade.Add($entry)
        }
        else {
            $plan.AlreadyCurrent.Add($entry)
        }
    }

    return $plan
}

function Get-SolutionInstallOrder {
    <#
    .SYNOPSIS
        Orders solutions so that dependencies install before their dependants.
    .DESCRIPTION
        Packages declare properties.dependencies as a recursive criteria tree. Most
        criteria point at content *inside* the solution — a parser, a data connector —
        which says nothing about install order. Only a criterion naming another
        solution in the same batch is an actual ordering constraint, so everything else
        is ignored.

        A dependency cycle returns the original order with HasCycle set rather than
        throwing. A wrong order costs one retry; refusing to proceed costs the run.
    .OUTPUTS
        Object with Ordered (the sorted entries) and HasCycle.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Entries = @())

    $entries = @($Entries | Where-Object { $_ -and $_.PackageId })
    if ($entries.Count -le 1) {
        return [PSCustomObject]@{ Ordered = $entries; HasCycle = $false }
    }

    $byId = @{}
    foreach ($e in $entries) { $byId[[string]$e.PackageId] = $e }

    # Flatten the recursive criteria tree down to the content ids it mentions.
    $collectIds = {
        param($node, $acc)
        if (-not $node) { return }
        $cid = $node.contentId
        if (-not [string]::IsNullOrWhiteSpace([string]$cid)) { $acc.Add([string]$cid) | Out-Null }
        foreach ($child in @($node.criteria)) { & $collectIds $child $acc }
    }

    $dependsOn = @{}
    foreach ($e in $entries) {
        $id = [string]$e.PackageId
        $acc = [System.Collections.Generic.HashSet[string]]::new()
        & $collectIds $e.Package.properties.dependencies $acc
        # Keep only edges pointing at another solution in this same batch.
        $dependsOn[$id] = @($acc | Where-Object { $_ -ne $id -and $byId.ContainsKey($_) })
    }

    $ordered = [System.Collections.Generic.List[object]]::new()
    $placed = [System.Collections.Generic.HashSet[string]]::new()

    # Kahn's algorithm, preserving input order among ready nodes so the result stays
    # stable and diffable between runs.
    $remaining = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $entries) { $remaining.Add([string]$e.PackageId) | Out-Null }

    while ($remaining.Count -gt 0) {
        $ready = @($remaining | Where-Object {
            @($dependsOn[$_] | Where-Object { -not $placed.Contains($_) }).Count -eq 0
        })

        if ($ready.Count -eq 0) {
            # Cycle, or a dependency we cannot satisfy. Emit the rest as they came.
            foreach ($id in $remaining) { $ordered.Add($byId[$id]) | Out-Null }
            return [PSCustomObject]@{ Ordered = $ordered.ToArray(); HasCycle = $true }
        }

        foreach ($id in $ready) {
            $ordered.Add($byId[$id]) | Out-Null
            $placed.Add($id) | Out-Null
            $remaining.Remove($id) | Out-Null
        }
    }

    return [PSCustomObject]@{ Ordered = $ordered.ToArray(); HasCycle = $false }
}

# ── Solution Installation ────────────────────────────────────────────────────

# Properties the Install API accepts beyond the core identity fields. Passing them
# through when the catalog supplies them is what makes the installed solution read
# correctly in the portal instead of as a bare stub with no author or support link.
$script:InstallPassthroughProperties = @(
    'source', 'author', 'support', 'dependencies', 'providers',
    'categories', 'description', 'contentSchemaVersion'
)

function Install-ContentPackage {
    <#
    .SYNOPSIS
        Installs a Content Hub solution in the target workspace.
    .DESCRIPTION
        Calls the documented Content Package - Install API:
        PUT .../contentPackages/{packageId}

        The body must carry 'contentProductId' alongside contentId. That id is opaque
        and cannot be derived — it encodes contentId, contentKind and version together
        (for example 'foo.azure-sentinel-solution-foo-sl-igl6jawr4gwmu'). Omitting it
        was why every install previously failed and fell through to the manual
        checklist, which looks identical to normal operation from the outside.

        Because contentProductId and version are a matched pair, $Package must be the
        entry from the *target* workspace's catalog. A source workspace's copy carries
        the source's product id, which the target will not resolve.
    .PARAMETER Package
        The catalog package object, from Get-AvailableContentPackages on the target.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetWorkspaceUri,
        [Parameter(Mandatory)][object]$Package,
        [switch]$DryRun,
        [int]$ThrottleDelayMs = 100
    )

    $props = $Package.properties
    $packageId = $props.contentId
    $displayName = $props.displayName
    $version = $props.version
    $productId = $props.contentProductId

    if (-not $packageId) {
        return [PSCustomObject]@{
            Action      = 'Failed'
            PackageId   = 'unknown'
            DisplayName = $displayName
            Version     = $version
            Reason      = 'No contentId available for this package'
        }
    }

    $uri = Get-ContentPackageUri -WorkspaceUri $TargetWorkspaceUri -PackageId $packageId

    $bodyProps = [ordered]@{
        contentId   = [string]$packageId
        contentKind = if ($props.contentKind) { [string]$props.contentKind } else { 'Solution' }
        version     = [string]$version
        displayName = [string]$displayName
    }

    # Absent product id is not treated as a hard stop: the reference does not mark any
    # body field required, and refusing here would invent a constraint the service may
    # not enforce. It is recorded instead, so that if the API does reject the call the
    # reason names the likely cause rather than leaving a bare 400.
    $productIdMissing = [string]::IsNullOrWhiteSpace([string]$productId)
    if (-not $productIdMissing) { $bodyProps['contentProductId'] = [string]$productId }

    foreach ($name in $script:InstallPassthroughProperties) {
        $value = $props.$name
        if ($null -ne $value) { $bodyProps[$name] = $value }
    }

    try {
        # The response body carries nothing we act on; the absence of a throw is the
        # signal. Assigning to $null says that deliberately.
        $null = Invoke-SentinelApi -Uri $uri -Method PUT -Body @{ properties = $bodyProps } `
            -DryRun:$DryRun -ThrottleDelayMs $ThrottleDelayMs

        $action = if ($DryRun) { 'WouldBeInstalled' } else { 'Installed' }

        return [PSCustomObject]@{
            Action      = $action
            PackageId   = $packageId
            DisplayName = $displayName
            Version     = $version
            Reason      = $null
        }
    }
    catch {
        $reason = $_.Exception.Message
        if ($productIdMissing) {
            $reason = "$reason (the catalog entry for this solution carried no contentProductId, which the install API needs)"
        }
        return [PSCustomObject]@{
            Action      = 'Failed'
            PackageId   = $packageId
            DisplayName = $displayName
            Version     = $version
            Reason      = $reason
        }
    }
}

function Wait-ContentPackageInstall {
    <#
    .SYNOPSIS
        Waits for an installed solution's content to actually materialise.
    .DESCRIPTION
        Content Hub installation is asynchronous: the PUT returns before the solution's
        rule templates exist. Without this wait, phase 3 races phase 2 and rules that
        depend on a just-installed solution fail on a run that otherwise reports success.

        Polls until properties.installedVersion is populated. A 404 means the package is
        not registered yet, which is a normal intermediate state rather than an error.

        Returns $true when confirmed. A $false is not a failure — it means "still
        settling", which the caller reports as Pending so the operator re-runs instead
        of chasing a phantom error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetWorkspaceUri,
        [Parameter(Mandatory)][string]$PackageId,
        [int]$MaxAttempts = 5,
        [int]$DelaySeconds = 3,
        [switch]$DryRun
    )

    # Nothing was written, so there is nothing to confirm. Polling here would report
    # every dry-run install as pending and bury the real signal.
    if ($DryRun) { return $true }

    $uri = Get-ContentPackageUri -WorkspaceUri $TargetWorkspaceUri -PackageId $PackageId

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $pkg = Invoke-SentinelApi -Uri $uri -Method GET
            if ($pkg -and -not [string]::IsNullOrWhiteSpace([string]$pkg.properties.installedVersion)) {
                return $true
            }
        }
        catch {
            Write-Verbose "Install check for '$PackageId' attempt $attempt : $($_.Exception.Message)"
        }

        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds $DelaySeconds }
    }

    return $false
}

# ── Checklist Generation ─────────────────────────────────────────────────────

# Rule kinds Sentinel provides itself. No Content Hub solution ships them, so they can
# never be resolved to one and must not be put on a manual install checklist.
$script:BuiltInRuleKinds = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('Fusion', 'MLBehaviorAnalytics', 'ThreatIntelligence', 'MicrosoftSecurityIncidentCreation'),
    [System.StringComparer]::OrdinalIgnoreCase)

function New-ContentHubChecklist {
    <#
    .SYNOPSIS
        Generates a manual Content Hub install checklist for template-based rules
        whose solutions could not be auto-installed.
    .DESCRIPTION
        A checklist entry is an admission that the tool could not get a rule's solution
        into the target by itself, so anything the operator has no action for must stay
        out of it. Rules whose solution is already present, or was installed during this
        run, are skipped — as are Sentinel's built-in rule kinds, which ship with the
        product rather than from any solution and so cannot be found in Content Hub.
    .OUTPUTS
        Array of checklist item objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$TemplateRules,
        [hashtable]$TemplateSolutionMap = @{},
        # Solutions installed during this run. Without this the checklist keeps telling
        # the operator to hand-install a solution the tool just installed for them,
        # which reads as the automation having done nothing.
        [AllowEmptyCollection()][string[]]$InstalledPackageIds = @()
    )

    $checklist = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $installedSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($InstalledPackageIds | Where-Object { $_ }),
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($rule in $TemplateRules) {
        $templateName = $rule.properties.alertRuleTemplateName
        if ([string]::IsNullOrWhiteSpace($templateName)) { continue }
        if ($seen.ContainsKey($templateName)) { continue }
        $seen[$templateName] = $true

        $mapEntry = $TemplateSolutionMap[$templateName]
        $solutionName = if ($mapEntry) { $mapEntry.SolutionName } else { $null }
        $isInstalled = if ($mapEntry) { $mapEntry.IsInstalled } else { $false }

        if ($isInstalled) { continue }
        if ($mapEntry -and $mapEntry.PackageId -and $installedSet.Contains([string]$mapEntry.PackageId)) { continue }

        # Built-in rule kinds ship with Sentinel itself, not from a Content Hub solution.
        # When we also could not resolve a package for one, there is nothing to install
        # and sending the operator to search Content Hub is a wild goose chase.
        if (-not $solutionName -and $script:BuiltInRuleKinds.Contains([string]$rule.kind)) { continue }

        $checklist.Add([PSCustomObject]@{
            AlertRuleTemplateName = $templateName
            RuleDisplayName       = $rule.properties.displayName
            SolutionName          = if ($solutionName) { $solutionName } else { '(Could not determine — search Content Hub by rule name)' }
            Severity              = $rule.properties.severity
            Tactics               = ($rule.properties.tactics -join ', ')
            IsEnabled             = $rule.properties.enabled
            ManualSteps           = @(
                "1. Open Azure Portal > Microsoft Sentinel > Content Hub"
                if ($solutionName) {
                    "2. Search for the solution: '$solutionName'"
                }
                else {
                    "2. Search Content Hub by rule name: '$($rule.properties.displayName)'"
                }
                "3. Select the solution and click 'Install' or 'Update'"
                "4. After installation, go to Analytics > Rule templates and enable the rule"
            )
        })
    }

    return $checklist.ToArray()
}

# ── Orchestration ─────────────────────────────────────────────────────────────
function Sync-ContentHubSolutions {
    <#
    .SYNOPSIS
        Mirrors the source workspace's Content Hub solutions into the target.
    .DESCRIPTION
        The work set is the union of two things:

          1. every solution installed in the source workspace, and
          2. every solution a migrating template rule depends on.

        (1) is what makes this a solution migration. (2) is the tool's original
        behaviour, kept because a rule can depend on a solution the source workspace
        does not itself have installed — a template can be referenced from the catalog.
        Taking the union means this change only ever adds coverage.

        Installation runs in dependency order and is confirmed afterwards, because the
        install API returns before the solution's rule templates exist and phase 3
        creates rules against them moments later.
    .PARAMETER OverwriteExisting
        Upgrade solutions already present in target at an older version. Off by default,
        matching how the tool treats existing rules and workbooks: an out-of-date target
        solution is reported rather than silently changed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceWorkspaceUri,
        [Parameter(Mandatory)][string]$TargetWorkspaceUri,
        # A workspace whose rules are all hand-written has no template rules, and the
        # right answer for that is an empty result rather than a binding error.
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$TemplateRules,
        [switch]$DryRun,
        [switch]$GenerateChecklist,
        [switch]$OverwriteExisting,
        [int]$ThrottleDelayMs = 100,
        [int]$VerifyAttempts = 5
    )

    $result = [PSCustomObject]@{
        InstalledPackages    = @()
        UpgradedPackages     = @()
        FailedPackages       = @()
        AlreadyInstalled     = @()
        SkippedPackages      = @()
        NotInCatalog         = @()
        PendingPackages      = @()
        ManualChecklist      = @()
        TemplateSolutionMap  = @{}
        SourceSolutionCount  = 0
        DependencyCycle      = $false
    }

    # Get templates from source for metadata
    $templates = Get-SourceAlertRuleTemplates -WorkspaceUri $SourceWorkspaceUri -ThrottleDelayMs $ThrottleDelayMs

    # Get catalog and installed packages from target
    $availablePackages = Get-AvailableContentPackages -WorkspaceUri $TargetWorkspaceUri -ThrottleDelayMs $ThrottleDelayMs
    $installedPackages = Get-InstalledContentPackages -WorkspaceUri $TargetWorkspaceUri -ThrottleDelayMs $ThrottleDelayMs

    # ...and, the part that was missing entirely, what is installed in the source.
    $sourceInstalled = Get-InstalledContentPackages -WorkspaceUri $SourceWorkspaceUri -ThrottleDelayMs $ThrottleDelayMs
    $result.SourceSolutionCount = @($sourceInstalled).Count

    # Content Hub's template records — the only place package identity actually lives.
    # Read from source, since that is the workspace whose solutions ship these rules.
    $contentTemplateIndex = Get-ContentTemplateIndex -WorkspaceUri $SourceWorkspaceUri -ThrottleDelayMs $ThrottleDelayMs

    # Build mapping
    $map = Build-TemplateSolutionMap `
        -AlertRuleTemplates $templates `
        -AvailablePackages $availablePackages `
        -InstalledPackages $installedPackages `
        -ContentTemplateIndex $contentTemplateIndex

    $result.TemplateSolutionMap = $map

    # ── Work set 1: mirror the source's installed solutions ──
    $plan = Get-SolutionMigrationPlan `
        -SourceInstalled $sourceInstalled `
        -TargetInstalled $installedPackages `
        -TargetCatalog $availablePackages

    $result.NotInCatalog = @($plan.NotInCatalog)
    $result.AlreadyInstalled = @($plan.AlreadyCurrent)

    $toInstall = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $plan.ToInstall) { $toInstall.Add($e) | Out-Null }

    foreach ($e in $plan.ToUpgrade) {
        if ($OverwriteExisting) {
            $toInstall.Add($e) | Out-Null
        }
        else {
            $result.SkippedPackages += [PSCustomObject]@{
                PackageId     = $e.PackageId
                DisplayName   = $e.DisplayName
                SourceVersion = $e.SourceVersion
                TargetVersion = $e.TargetVersion
                Reason        = "Target has $($e.TargetVersion), source has $($e.SourceVersion). Re-run with -OverwriteExisting to upgrade."
            }
        }
    }

    $upgradeIds = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($plan.ToUpgrade | ForEach-Object { [string]$_.PackageId }),
        [System.StringComparer]::OrdinalIgnoreCase)

    # ── Work set 2: solutions the migrating rules depend on ──
    $queued = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($toInstall | ForEach-Object { [string]$_.PackageId }),
        [System.StringComparer]::OrdinalIgnoreCase)

    $neededTemplateIds = $TemplateRules | ForEach-Object { $_.properties.alertRuleTemplateName } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique

    foreach ($tid in $neededTemplateIds) {
        if (-not $map.ContainsKey($tid)) { continue }
        $entry = $map[$tid]
        if ($entry.IsInstalled -or -not $entry.PackageId) { continue }
        $pkgId = [string]$entry.PackageId
        if ($queued.Contains($pkgId)) { continue }

        $fullPkg = $availablePackages | Where-Object { [string]$_.properties.contentId -eq $pkgId } | Select-Object -First 1
        if (-not $fullPkg) {
            $result.FailedPackages += [PSCustomObject]@{
                Action      = 'Failed'
                PackageId   = $pkgId
                DisplayName = $entry.DisplayName
                Version     = $null
                Reason      = 'Package not found in available catalog'
            }
            $queued.Add($pkgId) | Out-Null
            continue
        }

        $toInstall.Add([PSCustomObject]@{
            PackageId     = $pkgId
            DisplayName   = $entry.SolutionName
            SourceVersion = $null
            TargetVersion = $null
            Package       = $fullPkg
        }) | Out-Null
        $queued.Add($pkgId) | Out-Null
    }

    # ── Install, dependencies first ──
    $order = Get-SolutionInstallOrder -Entries $toInstall.ToArray()
    $result.DependencyCycle = $order.HasCycle
    if ($order.HasCycle) {
        Write-Warning "  Content Hub solutions declare a circular dependency; installing in discovery order."
    }

    $installedIds = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $order.Ordered) {
        $installResult = Install-ContentPackage `
            -TargetWorkspaceUri $TargetWorkspaceUri `
            -Package $entry.Package `
            -DryRun:$DryRun `
            -ThrottleDelayMs $ThrottleDelayMs

        if ((Get-NormalizedAction $installResult.Action) -ne 'Installed') {
            $result.FailedPackages += $installResult
            continue
        }

        $confirmed = Wait-ContentPackageInstall `
            -TargetWorkspaceUri $TargetWorkspaceUri `
            -PackageId $entry.PackageId `
            -MaxAttempts $VerifyAttempts `
            -DryRun:$DryRun

        $installedIds.Add([string]$entry.PackageId) | Out-Null

        if (-not $confirmed) {
            $result.PendingPackages += [PSCustomObject]@{
                PackageId   = $entry.PackageId
                DisplayName = $installResult.DisplayName
                Version     = $installResult.Version
                Reason      = 'Install accepted but content had not finished deploying. Re-run to migrate any rules that depend on it.'
            }
        }

        if ($upgradeIds.Contains([string]$entry.PackageId)) {
            $result.UpgradedPackages += $installResult
        }
        else {
            $result.InstalledPackages += $installResult
        }
    }

    # Generate manual checklist for anything not auto-installed
    if ($GenerateChecklist) {
        # @() is load-bearing: an empty return unrolls to nothing on assignment, leaving
        # the property $null, and @($null).Count is 1 — a checklist row that does not exist.
        $result.ManualChecklist = @(New-ContentHubChecklist `
                -TemplateRules $TemplateRules `
                -TemplateSolutionMap $map `
                -InstalledPackageIds $installedIds.ToArray())
    }

    return $result
}

Export-ModuleMember -Function @(
    'Get-InstalledContentPackages'
    'Get-AvailableContentPackages'
    'Get-ContentTemplateIndex'
    'Get-TemplatePackageRef'
    'Build-TemplateSolutionMap'
    'Compare-ContentPackageVersion'
    'Get-PackageInstalledVersion'
    'Get-SolutionMigrationPlan'
    'Get-SolutionInstallOrder'
    'Install-ContentPackage'
    'Wait-ContentPackageInstall'
    'New-ContentHubChecklist'
    'Sync-ContentHubSolutions'
)
