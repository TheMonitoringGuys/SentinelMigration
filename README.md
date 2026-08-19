# Sentinel Migration Assistant

Copies Microsoft Sentinel content — Content Hub solutions, analytics rules, workbooks,
and watchlists — from one Log Analytics workspace to another. Its purpose is to make the
DEV → PROD promotion inside a single Azure tenant straightforward and repeatable.

Source and target can be in different subscriptions, as long as both are in the
tenant you sign in to. Migrating between tenants is out of scope and not supported.

It is built to be run more than once. A migration normally takes a few passes: dry
run, install what the report asks for, execute, fix what failed, execute again.
Re-running never duplicates anything.

## Requirements

- PowerShell 7+
- The `Az.Accounts` module
- `powershell-yaml` (for YAML config files — installed automatically if missing)
- `ImportExcel` (optional — installed automatically when writing the workbook; without
  it, results are written as CSV instead of XLSX)
- **Microsoft Sentinel Reader** on the source workspace
- **Microsoft Sentinel Contributor** on the target workspace

The tool checks all of this at startup and tells you what is missing. Two modules are
installed on your behalf when they are needed and absent: `powershell-yaml` (only for a
YAML config) and `ImportExcel` (only when writing the workbook). Both go into your own
user scope — no elevation, nothing machine-wide. `Az.Accounts` is never installed for
you, because organisations usually pin a specific version. Pass `-NoAutoInstall` to turn
both automatic installs off; the YAML case then stops with instructions, and the workbook
falls back to CSV.

## Quick start

```powershell
Connect-AzAccount

# 1. Describe the move
Copy-Item ./samples/config.yaml ./config.yaml    # then edit it

# 2. See what would happen - changes nothing
./Sentinel-Migration-Assistant.ps1 -ConfigFile ./config.yaml -DryRun

# 3. Do it - asks for confirmation before writing
./Sentinel-Migration-Assistant.ps1 -ConfigFile ./config.yaml -Execute
```

The sample config is commented, so it doubles as the reference for every option.
JSON is accepted too, using the same key names, and needs no extra module at all.
See [troubleshooting](docs/troubleshooting.md) for a JSON example.

Each run writes a timestamped folder under `./output/`. Open
`Migration-Summary.html` from it — the **Next Steps** section lists what still needs
doing, derived from that run rather than from a generic checklist.

No config file? Pass the six workspace values directly instead:

```powershell
./Sentinel-Migration-Assistant.ps1 -DryRun `
    -SourceSubscriptionId <id> -SourceResourceGroup <rg> -SourceWorkspace <ws> `
    -TargetSubscriptionId <id> -TargetResourceGroup <rg> -TargetWorkspace <ws>
```

## Content Hub solutions

Every solution installed in the source workspace is installed in the target, before any
rules are created — so a rule that depends on a solution has something to bind to. This
happens by default; `-SkipSolutions` turns it off.

Three things are worth knowing before the first run:

- **The target gets the current catalog version, not the source's version.** The install
  API identifies a solution by an opaque `contentProductId` that encodes its version, and
  only the *current* one is published in the catalog. So a target can end up a version
  ahead of the source. Where that matters, check the report's solution table.
- **A solution already in the target is left alone**, even at an older version, unless you
  pass `-OverwriteExisting` — the same rule the tool applies to existing rules and
  workbooks. Out-of-date solutions are listed in the report either way.
- **Installing a solution brings the data connector's *definition*, not a working
  connection.** The connector still has to be configured by hand, and until it is, the
  tables its rules query stay empty.

Installation is asynchronous: the API accepts the request before the solution's rule
templates exist. The tool waits for each one, but a large solution can outlast that wait
and is reported as **Pending** rather than failed. Re-run to pick up the rules that
depend on it.

A solution installed in source that the target's catalog does not offer cannot be
installed — Commercial and Government catalogs differ, and solutions are occasionally
withdrawn. Those are listed separately as needing a decision rather than a re-run.

## What it will not do for you

It migrates Content Hub solutions, rules, workbooks, and watchlists. It does **not**
migrate data connector *configuration*, automation rules, playbooks, hunting queries,
saved searches and parsers, incidents and bookmarks, or UEBA settings. Plan those
separately.

Two things routinely stop a migration from being finished when the script exits:

- **Content Hub solutions still deploying, or absent from the target catalog.** Rules
  that depend on them cannot be created until they exist. Re-run for the first; the
  second needs a decision.
- **Rules created disabled.** Their queries reference tables the target does not
  have yet. Connect the data source first, then enable the rule.

Both appear in the report with the specific steps to take.

A rule can also migrate cleanly and still never fire, because nothing is writing to
the table it queries. `-IncludeTableStats` reports which rules are in that state.

## Safety

- Dry run is the default posture; nothing is written without `-Execute`.
- `-Execute` shows the target workspace and the planned changes, then waits for
  confirmation. `-Force` skips the prompt for unattended runs.
- Source content is never modified or deleted.
- Existing target items are left alone unless you pass `-OverwriteExisting`. That
  includes Content Hub solutions already installed at an older version.
- Both workspaces are checked for existence, Sentinel, and write access before any
  work begins.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Completed with no failures |
| `1` | Completed, but some items failed — check the report |
| `2` | Could not start: bad config, unreachable workspace, or missing permission |

## Documentation

| Document | Use it for |
|---|---|
| [Customer Guide](docs/customer-guide.md) | Setup, every parameter, expected behaviour |
| [Runbook](docs/runbook.md) | The step-by-step procedure, re-runs, rollback, CI/CD |
| [Troubleshooting](docs/troubleshooting.md) | When something fails |
| [Changelog](CHANGELOG.md) | What changed, including breaking changes |

Full parameter help is in the script itself:

```powershell
Get-Help ./Sentinel-Migration-Assistant.ps1 -Full
```

## Development

Run the test suite:

```powershell
Invoke-Pester -Path ./tests
```

### Test gate

GitHub Actions **does not run in this repository.** It is a private repo owned by an
Enterprise Managed User account, where Actions is disabled by enterprise policy — the
Actions API reports zero registered workflows and zero runs. `.github/workflows/tests.yml`
is present and valid, and will start working unchanged if the repo moves to an
organisation with Actions enabled, but today it produces no check runs at all.

Because nothing server-side is checking the tests, the gate is local. Install it once
per clone:

```powershell
./tools/Install-GitHooks.ps1
```

That points `core.hooksPath` at `tools/hooks`, enabling a `pre-push` hook that runs the
full suite (about 25 seconds) and refuses the push if anything fails. The path is
relative, so a single setting works correctly in the main clone and in every worktree.

To bypass for one push — a docs-only fixup, or a deliberate work-in-progress:

```powershell
git push --no-verify
```

To remove the gate entirely:

```powershell
./tools/Install-GitHooks.ps1 -Uninstall
```
