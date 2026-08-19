#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for Sentinel.Common module.
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'Sentinel.Common.psm1'
    Import-Module $modulePath -Force
}

Describe 'ConvertTo-SafeArray' {
    It 'Returns an empty array for null' {
        $result = @(ConvertTo-SafeArray -Value $null)
        $result.Count | Should -Be 0
    }

    It 'Wraps a single object without unrolling it' {
        $result = @(ConvertTo-SafeArray -Value ([PSCustomObject]@{ Name = 'one' }))
        $result.Count | Should -Be 1
        $result[0].Name | Should -Be 'one'
    }

    It 'Drops null entries so an absent collection counts as zero' {
        # @($null).Count is 1, which is the phantom-count bug this guards against.
        $result = @(ConvertTo-SafeArray -Value @($null))
        $result.Count | Should -Be 0
    }

    It 'Preserves multi-item collections' {
        $result = @(ConvertTo-SafeArray -Value @(1, 2, 3))
        $result.Count | Should -Be 3
    }

    It 'Does not report the element Count for a single-item collection' {
        # A hashtable exposes its own Count; unrolling would surface 3 instead of 1.
        $result = @(ConvertTo-SafeArray -Value @{ a = 1; b = 2; c = 3 })
        $result.Count | Should -Be 1
    }
}

Describe 'Get-ApiErrorStatusCode' {
    It 'Extracts the status code from a web exception response' {
        $err = [PSCustomObject]@{
            Exception = [PSCustomObject]@{
                Response = [PSCustomObject]@{ StatusCode = 404 }
            }
        }
        Get-ApiErrorStatusCode -ErrorRecord $err | Should -Be 404
    }

    It 'Returns null when no response is present' {
        $err = [PSCustomObject]@{ Exception = [PSCustomObject]@{ Message = 'boom' } }
        Get-ApiErrorStatusCode -ErrorRecord $err | Should -BeNullOrEmpty
    }
}

Describe 'Format-ApiErrorDetail' {
    It 'Prefers the ARM error message over the raw exception text' {
        $err = [PSCustomObject]@{
            Exception    = [PSCustomObject]@{ Message = 'Response status code 404' }
            ErrorDetails = [PSCustomObject]@{ Message = '{"error":{"code":"NotFound","message":"Workspace not found"}}' }
        }
        $detail = Format-ApiErrorDetail -ErrorRecord $err
        $detail | Should -Match 'Workspace not found'
        $detail | Should -Match 'NotFound'
    }

    It 'Unwraps a doubly-nested ARM error payload' {
        $err = [PSCustomObject]@{
            Exception    = [PSCustomObject]@{ Message = 'noise' }
            ErrorDetails = [PSCustomObject]@{ Message = '{"error":{"error":{"code":"Forbidden","message":"Denied by policy"}}}' }
        }
        Format-ApiErrorDetail -ErrorRecord $err | Should -Match 'Denied by policy'
    }

    It 'Falls back to the raw body when it is not JSON' {
        $err = [PSCustomObject]@{
            Exception    = [PSCustomObject]@{ Message = 'transport noise' }
            ErrorDetails = [PSCustomObject]@{ Message = 'upstream connect error' }
        }
        Format-ApiErrorDetail -ErrorRecord $err | Should -Match 'upstream connect error'
    }

    It 'Falls back to the exception message when no response body exists' {
        $err = [PSCustomObject]@{
            Exception    = [PSCustomObject]@{ Message = 'The remote name could not be resolved' }
            ErrorDetails = $null
        }
        Format-ApiErrorDetail -ErrorRecord $err | Should -Match 'remote name'
    }

    It 'Truncates an oversized payload' {
        $err = [PSCustomObject]@{
            Exception    = [PSCustomObject]@{ Message = ('x' * 5000) }
            ErrorDetails = $null
        }
        $detail = Format-ApiErrorDetail -ErrorRecord $err -MaxLength 100
        $detail.Length | Should -BeLessOrEqual 103
        $detail | Should -Match '\.\.\.$'
    }

    It 'Collapses embedded newlines into a single line' {
        $err = [PSCustomObject]@{
            Exception    = [PSCustomObject]@{ Message = "line one`r`n   line two" }
            ErrorDetails = $null
        }
        Format-ApiErrorDetail -ErrorRecord $err | Should -Be 'line one line two'
    }
}

Describe 'Invoke-SafeCollection' {
    It 'Returns collected items on success' {
        $result = @(Invoke-SafeCollection -Name 'Widgets' -Action { @('a', 'b') })
        $result.Count | Should -Be 2
    }

    It 'Returns an empty array when the action throws' {
        $result = @(Invoke-SafeCollection -Name 'Widgets' -Action { throw 'boom' } -WarningAction SilentlyContinue)
        $result.Count | Should -Be 0
    }

    It 'Does not rethrow so one artifact type cannot abort the phase' {
        { Invoke-SafeCollection -Name 'Widgets' -Action { throw 'boom' } -WarningAction SilentlyContinue } |
            Should -Not -Throw
    }

    It 'Records a structured error against the sink on failure' {
        $sink = [System.Collections.Generic.List[object]]::new()
        Invoke-SafeCollection -Name 'Widgets' -Action { throw 'boom' } -ErrorSink $sink `
            -Remediation 'Check permissions' -WarningAction SilentlyContinue | Out-Null

        $sink.Count | Should -Be 1
        $sink[0].Component | Should -Be 'Widgets'
        $sink[0].Message | Should -Match 'boom'
        $sink[0].Remediation | Should -Be 'Check permissions'
        $sink[0].Critical | Should -BeFalse
    }

    It 'Marks the error as critical when requested' {
        $sink = [System.Collections.Generic.List[object]]::new()
        Invoke-SafeCollection -Name 'Widgets' -Action { throw 'boom' } -ErrorSink $sink `
            -Critical -WarningAction SilentlyContinue | Out-Null

        $sink[0].Critical | Should -BeTrue
    }

    It 'Leaves the sink empty on success' {
        $sink = [System.Collections.Generic.List[object]]::new()
        Invoke-SafeCollection -Name 'Widgets' -Action { @('a') } -ErrorSink $sink | Out-Null
        $sink.Count | Should -Be 0
    }

    It 'Returns a single-item result whose Count is 1' {
        $result = @(Invoke-SafeCollection -Name 'Widgets' -Action { @{ a = 1; b = 2; c = 3 } })
        $result.Count | Should -Be 1
    }

    It 'Normalises a null result to an empty array' {
        $result = @(Invoke-SafeCollection -Name 'Widgets' -Action { $null })
        $result.Count | Should -Be 0
    }
}

Describe 'Write-MigrationProgress' {
    It 'Does not throw while reporting progress' {
        { Write-MigrationProgress -Activity 'Test' -Status 'item' -Current 1 -Total 10 } | Should -Not -Throw
    }

    It 'Does not throw when completing' {
        { Write-MigrationProgress -Activity 'Test' -Completed } | Should -Not -Throw
    }

    It 'Tolerates a zero total without dividing by zero' {
        { Write-MigrationProgress -Activity 'Test' -Status 'item' -Current 0 -Total 0 } | Should -Not -Throw
    }
}

Describe 'ConvertTo-ItemList' {
    # Consolidated here from Sentinel.Export and Sentinel.Html, which held
    # byte-identical copies. That duplication is the mechanism that let the
    # Markdown and HTML renderers drift apart.
    It 'Returns an empty array for null' {
        @(ConvertTo-ItemList $null).Count | Should -Be 0
    }

    It 'Drops null entries so an absent collection counts as zero' {
        @(ConvertTo-ItemList @($null)).Count | Should -Be 0
    }

    It 'Wraps a single object without unrolling it' {
        $r = @(ConvertTo-ItemList ([PSCustomObject]@{ Name = 'one' }))
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'one'
    }

    It 'Preserves a populated collection' {
        @(ConvertTo-ItemList @(1, 2, 3)).Count | Should -Be 3
    }
}

Describe 'Format-MigrationDuration' {
    It 'Keeps the day component instead of wrapping at 24 hours' {
        # 'hh\:mm\:ss' rendered this as 02:00:00, understating a long migration.
        Format-MigrationDuration -Span ([TimeSpan]::FromHours(26)) | Should -Be '1d 02:00:00'
    }

    It 'Omits days when there are none' {
        Format-MigrationDuration -Span ([TimeSpan]::FromMinutes(45)) | Should -Be '00:45:00'
    }

    It 'Truncates rather than rounds' {
        # [int]1.5 is 2, so a naive cast rendered 90 minutes as 02:30:00.
        Format-MigrationDuration -Span ([TimeSpan]::FromMinutes(90)) | Should -Be '01:30:00'
    }

    It 'Returns N/A for a non-TimeSpan' {
        Format-MigrationDuration -Span $null | Should -Be 'N/A'
        Format-MigrationDuration -Span 'nonsense' | Should -Be 'N/A'
    }
}

Describe 'Get-ActionColor' {
    It 'Colours a rule that will land disabled the same in both modes' {
        # The defect: WouldBeCreatedDisabled missed the literal 'CreatedDisabled'
        # arm, fell through to -match 'Created', and printed green - identical to
        # a clean create, for a rule that will be inactive in production.
        Get-ActionColor 'WouldBeCreatedDisabled' | Should -Be 'Yellow'
        Get-ActionColor 'CreatedDisabled'        | Should -Be 'Yellow'
    }

    It 'Returns exactly one colour, never an array' {
        # The old switch had no break, so 'CreatedDisabled' matched two arms and
        # returned @('Yellow','Green'). Write-Host tolerated it by accident.
        foreach ($a in @('Created', 'CreatedDisabled', 'WouldBeCreated', 'WouldBeCreatedDisabled',
                         'Updated', 'Skipped', 'Failed', 'Installed', 'AlreadyInstalled')) {
            @(Get-ActionColor $a).Count | Should -Be 1 -Because "$a must map to a single colour"
        }
    }

    It 'Agrees between dry-run and executed forms of the same verb' {
        foreach ($verb in @('Created', 'CreatedDisabled', 'Updated', 'Installed')) {
            Get-ActionColor "WouldBe$verb" | Should -Be (Get-ActionColor $verb) -Because "$verb must look the same in both modes"
        }
    }

    It 'Uses red for failures and grey for skips' {
        Get-ActionColor 'Failed'  | Should -Be 'Red'
        Get-ActionColor 'Skipped' | Should -Be 'DarkGray'
    }
}

Describe 'Format-ActionLabel' {
    It 'Never leaks a raw WouldBe verb to the operator' {
        foreach ($a in @('WouldBeCreated', 'WouldBeCreatedDisabled', 'WouldBeUpdated', 'WouldBeInstalled')) {
            Format-ActionLabel $a | Should -Not -Match 'WouldBe'
        }
    }

    It 'Marks planned actions as planned' {
        Format-ActionLabel 'WouldBeCreated' | Should -Be 'Would be created'
        Format-ActionLabel 'WouldBeCreatedDisabled' | Should -Be 'Would be created (disabled)'
    }

    It 'Renders executed actions in the past tense' {
        Format-ActionLabel 'Created'         | Should -Be 'Created'
        Format-ActionLabel 'CreatedDisabled' | Should -Be 'Created (disabled)'
        Format-ActionLabel 'Failed'          | Should -Be 'Failed'
    }

    It 'Distinguishes a disabled create from a plain create' {
        Format-ActionLabel 'WouldBeCreatedDisabled' | Should -Not -Be (Format-ActionLabel 'WouldBeCreated')
    }

    It 'Returns empty for null' {
        Format-ActionLabel $null | Should -Be ''
    }
}
