<#
    Regression test for the module load-order defect.

    Import-Module -Force removes a module before re-importing it. Every module in
    src/ internally does `Import-Module Sentinel.Common -Force`, so each one of
    those imports unloads whatever copy of Common the caller already had and
    rebinds Common's functions to the importing module's own scope.

    The orchestrator imported Common first, so by the time the module block
    finished, Common's functions were invisible to the orchestrator itself and the
    script died at the first call to Invoke-SafeCollection. The fix is a trailing
    re-import of Common after the module block.

    The 358 mocked unit tests could not catch this: they import modules in their
    own (correct) order, so the orchestrator's ordering is never exercised. This
    test replays the orchestrator's *actual* import sequence -- parsed out of the
    script rather than hardcoded, so a module added later is covered automatically
    -- and asserts every function Common exports is still resolvable at the end.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Script = Join-Path $script:RepoRoot 'Sentinel-Migration-Assistant.ps1'
    $script:SrcDir = Join-Path $script:RepoRoot 'src'

    # The module names the orchestrator imports, in the order it imports them.
    $script:ImportOrder = Select-String -Path $script:Script -Pattern "Import-Module \(Join-Path \`$srcDir '([^']+)'\)" |
        ForEach-Object { $_.Matches[0].Groups[1].Value }

    # What Sentinel.Common advertises to its consumers.
    $commonPath = Join-Path $script:SrcDir 'Sentinel.Common.psm1'
    $script:CommonExports = (Get-Module -Name Sentinel.Common -All | Remove-Module -Force -ErrorAction SilentlyContinue)
    $m = Import-Module $commonPath -Force -DisableNameChecking -PassThru
    $script:CommonExports = @($m.ExportedFunctions.Keys)
    Remove-Module $m -Force -ErrorAction SilentlyContinue
}

Describe 'Orchestrator module load order' {

    It 'parses a non-trivial import sequence out of the script' {
        # Guards the test itself: if the regex stops matching, the assertions below
        # would vacuously pass.
        $script:ImportOrder.Count | Should -BeGreaterThan 5
        $script:ImportOrder | Should -Contain 'Sentinel.Common.psm1'
    }

    It 'leaves every Sentinel.Common function callable after the full import sequence' {
        $script:CommonExports.Count | Should -BeGreaterThan 0

        # Run in a child process: Import-Module -Force mutates session state, and
        # this test is specifically about that mutation. It must not leak into the
        # rest of the suite.
        $srcDir = $script:SrcDir
        $order = $script:ImportOrder
        $expected = $script:CommonExports

        $result = pwsh -NoProfile -NonInteractive -Command @"
`$ErrorActionPreference = 'Stop'
`$srcDir = '$($srcDir -replace "'","''")'
foreach (`$m in @($(($order | ForEach-Object { "'$($_ -replace "'","''")'" }) -join ','))) {
    Import-Module (Join-Path `$srcDir `$m) -Force -DisableNameChecking
}
`$missing = @()
foreach (`$fn in @($(($expected | ForEach-Object { "'$_'" }) -join ','))) {
    if (-not (Get-Command `$fn -ErrorAction SilentlyContinue)) { `$missing += `$fn }
}
`$missing -join ','
"@ 2>&1

        $missing = ($result | Out-String).Trim()
        $missing | Should -BeNullOrEmpty -Because "these Sentinel.Common functions were unloaded by a later Import-Module -Force and the orchestrator cannot call them: $missing"
    }

    It 're-imports Sentinel.Common after the last module import' {
        # The structural guarantee behind the assertion above. Stated separately so
        # a failure points straight at the cause rather than the symptom.
        $lastCommon = [array]::LastIndexOf($script:ImportOrder, 'Sentinel.Common.psm1')
        $lastCommon | Should -Be ($script:ImportOrder.Count - 1) -Because 'any module imported after Common with -Force unloads it again'
    }
}
