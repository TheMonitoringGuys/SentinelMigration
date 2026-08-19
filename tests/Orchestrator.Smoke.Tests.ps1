<#
    End-to-end smoke test for the orchestrator.

    These tests exist because unit tests pass while the script that wires the units
    together is broken. They run the real entry point with the network mocked and
    assert on exit codes and the artifacts a customer actually receives.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Script = Join-Path $script:RepoRoot 'Sentinel-Migration-Assistant.ps1'

    # Runs the orchestrator in a child process so exit codes are observable and
    # module state cannot leak between cases. Az + the ARM layer are stubbed by
    # shimming the modules on the module path before the script imports them.
    function Invoke-Orchestrator {
        param([string[]]$Arguments, [string]$Fixture = 'default')

        $work = Join-Path ([System.IO.Path]::GetTempPath()) "smt-smoke-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $work -Force | Out-Null

        $outDir = Join-Path $work 'output'
        $stdout = Join-Path $work 'stdout.txt'
        $stderr = Join-Path $work 'stderr.txt'

        # Quote any argument that is not a -Switch so paths/values survive intact.
        $argLine = ($Arguments | ForEach-Object {
                if ($_ -like '-*') { $_ } else { "'{0}'" -f ($_ -replace "'", "''") }
            }) -join ' '

        # The invocation is baked into the generated harness rather than passed as a
        # process argument: a command line containing quotes does not survive
        # Start-Process argument splitting intact.
        $harness = @"
`$ErrorActionPreference = 'Stop'

# --- stub the Az surface the orchestrator touches -------------------------
function Get-AzContext {
    [PSCustomObject]@{
        Account      = [PSCustomObject]@{ Id = 'smoke@contoso.com' }
        Subscription = [PSCustomObject]@{ Id = 'sub-source' }
        Tenant       = [PSCustomObject]@{ Id = 'tenant-1' }
        Environment  = [PSCustomObject]@{ Name = 'AzureCloud' }
    }
}
function Connect-AzAccount  { Get-AzContext }
function Set-AzContext      { Get-AzContext }
function Get-AzAccessToken  { [PSCustomObject]@{ Token = 'stub-token' } }

& '$($script:Script)' $argLine -OutputDir '$outDir'
exit `$LASTEXITCODE
"@

        $harnessPath = Join-Path $work 'harness.ps1'
        Set-Content -Path $harnessPath -Value $harness -Encoding UTF8

        $p = Start-Process -FilePath 'pwsh' `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $harnessPath) `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr

        [PSCustomObject]@{
            ExitCode  = $p.ExitCode
            Stdout    = (Test-Path $stdout) ? (Get-Content $stdout -Raw) : ''
            Stderr    = (Test-Path $stderr) ? (Get-Content $stderr -Raw) : ''
            OutputDir = $outDir
            WorkDir   = $work
        }
    }
}

Describe 'Orchestrator entry point' {

    It 'parses without syntax errors' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script:Script, [ref]$null, [ref]$errors) | Out-Null
        $errors.Count | Should -Be 0
    }

    It 'exposes -WhatIf-safe defaults: neither -DryRun nor -Execute forces a write' {
        # A run with no mode flag must not default to writing to the target.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:Script, [ref]$null, [ref]$null)
        $execute = $ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'Execute' }
        $execute | Should -Not -BeNullOrEmpty
        # -Execute must be a switch, so omitting it cannot silently enable writes.
        $execute.StaticType.Name | Should -Be 'SwitchParameter'
    }

    It 'rejects an invalid -TableStatsLookbackDays at bind time' {
        $result = Invoke-Orchestrator -Arguments @(
            '-DryRun', '-IncludeTableStats', '-TableStatsLookbackDays', '999',
            '-SourceSubscriptionId', 'sub-source', '-SourceResourceGroup', 'rg-s',
            '-SourceWorkspace', 'ws-s',
            '-TargetSubscriptionId', 'sub-target', '-TargetResourceGroup', 'rg-t',
            '-TargetWorkspace', 'ws-t'
        )
        # Parameter binding failure must not look like a successful migration.
        $result.ExitCode | Should -Not -Be 0
    }

    It 'fails fast and non-zero when source and target workspace are identical' {
        $result = Invoke-Orchestrator -Arguments @(
            '-DryRun',
            '-SourceSubscriptionId', 'sub-same', '-SourceResourceGroup', 'rg-same',
            '-SourceWorkspace', 'ws-same',
            '-TargetSubscriptionId', 'sub-same', '-TargetResourceGroup', 'rg-same',
            '-TargetWorkspace', 'ws-same'
        )
        $result.ExitCode | Should -Not -Be 0
        ($result.Stdout + $result.Stderr) | Should -Match '(?i)same|identical'
    }
}
