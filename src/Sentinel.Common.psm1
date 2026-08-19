<#
.SYNOPSIS
    Shared helpers used across the migration modules.
.DESCRIPTION
    Cross-cutting utilities that do not belong to any single migration phase:
    array normalisation, readable ARM error extraction, per-item failure
    isolation, and progress reporting.
#>

function ConvertTo-SafeArray {
    <#
    .SYNOPSIS
        Normalises a possibly-null / possibly-scalar value into a clean array.
    .DESCRIPTION
        @($null).Count is 1, not 0, so counting an absent collection directly
        reports one phantom item. Dropping null entries makes an absent
        collection count as zero.

        Returns a plain array rather than using the comma operator: `return ,@()`
        hands the caller a nested array once they wrap the call in @(), which
        silently turns every collection into a single element. Call sites must
        wrap in @() to defeat single-element unrolling.
    #>
    param([object]$Value)
    if ($null -eq $Value) { return @() }
    return @($Value | Where-Object { $null -ne $_ })
}

function Get-NormalizedAction {
    <#
    .SYNOPSIS
        Strips the dry-run 'WouldBe' prefix so one set of matchers serves both modes.
    .DESCRIPTION
        In dry-run mode the migration modules emit 'WouldBeCreated', 'WouldBeUpdated',
        'WouldBeCreatedDisabled' and 'WouldBeInstalled' instead of the executed verbs.
        Any caller that classifies outcomes must compare against the normalized verb,
        or every dry-run count silently reads zero.

        This lives in Common because both report renderers need it. It previously
        existed only in Sentinel.Html, so the Markdown report compared raw verbs and
        dropped its 'Rules Created as Disabled' section from every dry-run report -
        and dry run is the default mode.
    #>
    param([object]$Action)
    if ($null -eq $Action) { return '' }
    return ([string]$Action) -replace '^WouldBe', ''
}

function Format-ApiErrorDetail {
    <#
    .SYNOPSIS
        Extracts a readable message from an ARM error payload or exception.
    .DESCRIPTION
        ARM returns errors as {"error":{"code":"...","message":"..."}}, sometimes
        nested one level deeper. The raw exception text wraps that JSON in
        transport noise, which is what operators end up pasting into support
        tickets. This pulls out the code and message when present and falls back
        to the exception message otherwise.
    .PARAMETER ErrorRecord
        The caught ErrorRecord. Its ErrorDetails.Message is preferred because it
        carries the response body; Exception.Message is the fallback.
    .PARAMETER MaxLength
        Truncation ceiling so a huge payload cannot flood the console or log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ErrorRecord,
        [int]$MaxLength = 800
    )

    $raw = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $raw = [string]$ErrorRecord.ErrorDetails.Message
    }

    $formatted = $null
    if ($raw) {
        try {
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            # ARM nests the useful part one or two levels down depending on the provider.
            $node = $parsed.error
            if ($node -and $node.error) { $node = $node.error }
            if ($node) {
                $code = [string]$node.code
                $msg = [string]$node.message
                if ($code -and $msg) { $formatted = "$code`: $msg" }
                elseif ($msg) { $formatted = $msg }
                elseif ($code) { $formatted = $code }
            }
        }
        catch {
            # Not JSON - fall through and use the raw body below.
            $formatted = $null
        }
        if (-not $formatted) { $formatted = $raw }
    }

    if (-not $formatted) {
        $formatted = if ($ErrorRecord.Exception) { [string]$ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    }

    $formatted = ($formatted -replace '\s+', ' ').Trim()
    if ($MaxLength -gt 0 -and $formatted.Length -gt $MaxLength) {
        $formatted = $formatted.Substring(0, $MaxLength) + '...'
    }
    return $formatted
}

function Get-ApiErrorStatusCode {
    <#
    .SYNOPSIS
        Returns the HTTP status code from an ErrorRecord, or $null when absent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$ErrorRecord)

    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Response) {
        try { return [int]$ErrorRecord.Exception.Response.StatusCode } catch { return $null }
    }
    return $null
}

function Invoke-SafeCollection {
    <#
    .SYNOPSIS
        Runs a collection/migration step so one failure degrades a single
        artifact type instead of aborting the whole phase.
    .DESCRIPTION
        Wraps a scriptblock, and on failure records a structured error against
        the supplied sink and returns an empty array rather than $null. Callers
        downstream then see a zero-count collection, which every flattener and
        KPI already handles, instead of a null that silently disables a phase.
    .PARAMETER Name
        Component name used in the log line and the error record.
    .PARAMETER Action
        The work to perform.
    .PARAMETER ErrorSink
        A list that receives a structured error object on failure.
    .PARAMETER Remediation
        Operator-facing guidance attached to the error record.
    .PARAMETER Critical
        Marks the failure as blocking in the error record, for callers that
        distinguish "this artifact type is missing" from "the run is invalid".
    .OUTPUTS
        The scriptblock's result as an array, or an empty array on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [System.Collections.IList]$ErrorSink,
        [string]$Remediation = '',
        [switch]$Critical
    )

    try {
        $result = & $Action
        return @(ConvertTo-SafeArray $result)
    }
    catch {
        $detail = Format-ApiErrorDetail -ErrorRecord $_
        if (Get-Command -Name 'Write-MigrationLog' -ErrorAction SilentlyContinue) {
            Write-MigrationLog -Message "$Name failed: $detail" -Level 'Error' -Component $Name
        }
        else {
            Write-Warning "$Name failed: $detail"
        }

        if ($null -ne $ErrorSink) {
            $ErrorSink.Add([PSCustomObject]@{
                    Component   = $Name
                    Message     = $detail
                    Remediation = $Remediation
                    Critical    = [bool]$Critical
                }) | Out-Null
        }
        return @()
    }
}

function Write-MigrationProgress {
    <#
    .SYNOPSIS
        Reports [i/N] progress for a long-running loop.
    .DESCRIPTION
        Suppressed when the host has no progress surface (redirected output,
        CI logs), so automated runs do not accumulate control characters.
    .PARAMETER Completed
        Clears the progress bar for this activity.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Activity,
        [string]$Status = '',
        [int]$Current = 0,
        [int]$Total = 0,
        [int]$Id = 1,
        [switch]$Completed
    )

    if ($Completed) {
        Write-Progress -Id $Id -Activity $Activity -Completed
        return
    }

    $pct = if ($Total -gt 0) { [math]::Min(100, [int](($Current / $Total) * 100)) } else { 0 }
    $text = if ($Total -gt 0) { "[$Current/$Total] $Status" } else { $Status }
    Write-Progress -Id $Id -Activity $Activity -Status $text -PercentComplete $pct
}

function ConvertTo-ItemList {
    <#
    .SYNOPSIS
        Normalises a possibly-null / possibly-scalar input into a clean array.
    .DESCRIPTION
        @($null).Count is 1, not 0, so counting an absent collection directly would
        report one phantom item - a KPI card reading 1 for a component that never
        ran, or a bogus all-empty row in an export.

        Callers that need a .Count must wrap the call in @(): PowerShell unrolls a
        single-element result on return, and reading .Count off the bare element
        would pick up that object's own Count property instead of the length.

        Identical copies of this previously lived in Sentinel.Export and
        Sentinel.Html. That duplication is what allowed the two renderers to drift
        apart, so it now has one home.
    #>
    param([object]$Value)
    if ($null -eq $Value) { return @() }
    return @($Value | Where-Object { $null -ne $_ })
}

function Format-MigrationDuration {
    <#
    .SYNOPSIS
        Renders a TimeSpan without silently discarding days.
    .DESCRIPTION
        'hh\:mm\:ss' wraps at 24 hours, so a 26-hour run reads as 02:00:00. Large
        tenants do exceed a day, and an under-reported duration is worse than a
        long one. Days are only shown when there are days to show.

        Lives in Common because the console, the Markdown report, the HTML
        dashboard and the Excel/CSV export all render the same run duration. When
        this existed only in Sentinel.Report the other three still wrapped at 24
        hours, so the artifacts contradicted each other.
    .PARAMETER Span
        The TimeSpan to render. Anything that is not a TimeSpan yields 'N/A'.
    #>
    param([object]$Span)
    if ($Span -isnot [TimeSpan]) { return 'N/A' }
    # Use the component properties, not [int]$Span.TotalHours - casting a double
    # rounds (1.5 becomes 2), so a 90-minute run would report as 02:30:00.
    if ($Span.Days -ge 1) {
        return ('{0}d {1:00}:{2:00}:{3:00}' -f $Span.Days, $Span.Hours, $Span.Minutes, $Span.Seconds)
    }
    return ('{0:00}:{1:00}:{2:00}' -f $Span.Hours, $Span.Minutes, $Span.Seconds)
}

function Get-ActionColor {
    <#
    .SYNOPSIS
        Console colour for a migration action verb, in either mode.
    .DESCRIPTION
        Normalises first, so a dry run colours outcomes exactly as the real run
        would. Previously each migration module carried its own switch that
        compared raw verbs, with two consequences:

        - 'WouldBeCreatedDisabled' fell through a literal 'CreatedDisabled' arm
          into a '-match Created' arm and printed green, so a rule destined to
          land disabled in production looked like a clean create.
        - The arms had no 'break', so 'CreatedDisabled' matched twice and the
          switch returned an array of two colours. Write-Host tolerated it, but
          only by accident.

        Returns a single ConsoleColor name.
    #>
    param([object]$Action)

    $normalized = Get-NormalizedAction $Action
    switch -Regex ($normalized) {
        '^CreatedDisabled$' { return 'Yellow' }
        '^Created'          { return 'Green' }
        '^Installed'        { return 'Green' }
        '^Updated'          { return 'Yellow' }
        '^AlreadyInstalled' { return 'DarkGray' }
        '^Skipped$'         { return 'DarkGray' }
        '^Failed$'          { return 'Red' }
        default             { return 'White' }
    }
}

function Format-ActionLabel {
    <#
    .SYNOPSIS
        Human-readable form of an action verb for display to an operator.
    .DESCRIPTION
        Turns 'WouldBeCreatedDisabled' into 'Would be created (disabled)' and
        'CreatedDisabled' into 'Created (disabled)'. The console previously echoed
        the raw verb, so a dry run scrolled '-> WouldBeCreated' past the operator
        while the dashboard said 'Rules Created'.
    #>
    param([object]$Action)

    $raw = [string]$Action
    if (-not $raw) { return '' }

    $normalized = Get-NormalizedAction $raw
    $isPlanned  = $raw -ne $normalized

    $text = switch ($normalized) {
        'CreatedDisabled'  { 'created (disabled)' }
        'Created'          { 'created' }
        'Updated'          { 'updated' }
        'Installed'        { 'installed' }
        'AlreadyInstalled' { 'already installed' }
        'Skipped'          { 'skipped' }
        'Failed'           { 'failed' }
        default            { $normalized.ToLowerInvariant() }
    }

    if ($isPlanned) { return "Would be $text" }
    $text = $text.Substring(0, 1).ToUpperInvariant() + $text.Substring(1)
    return $text
}

Export-ModuleMember -Function @(
    'ConvertTo-ItemList'
    'ConvertTo-SafeArray'
    'Format-ActionLabel'
    'Format-ApiErrorDetail'
    'Format-MigrationDuration'
    'Get-ActionColor'
    'Get-ApiErrorStatusCode'
    'Get-NormalizedAction'
    'Invoke-SafeCollection'
    'Write-MigrationProgress'
)
