# Sentinel Migration Assistant — Customer Guide

## Overview

The Sentinel Migration Assistant automates the migration of Microsoft Sentinel content from a **source** (DEV) workspace to a **target** (PROD) workspace within the same Azure AD tenant. It handles:

- **Analytics rules** — both custom and template-based
- **Workbooks** — saved Sentinel workbook instances
- **Watchlists** — including their items
- **Content Hub solutions** — every solution installed in the source is installed in the target

**Scope:** source and target may be in different subscriptions and resource groups, provided both are in the tenant you authenticate to. Cross-tenant migration is out of scope: the access token is tenant-scoped, so a subscription in another tenant is rejected during preflight.

## Prerequisites

### Software

| Requirement | Minimum Version |
|---|---|
| PowerShell | 7.0+ |
| Az.Accounts module | Latest |
| powershell-yaml module | Only for YAML config files. Installed automatically if missing. |
| ImportExcel module | Optional. Installed automatically when writing the workbook; results fall back to CSV without it. |

The tool verifies these at startup and reports what is missing.

Two modules are installed for you, each only when it is actually needed:
`powershell-yaml` when your config is a `.yaml` file, and `ImportExcel` when the results
workbook is written. Both installs go to `-Scope CurrentUser`, so they never need
elevation and never change the machine.

The two differ in what happens when the install fails. A failed `powershell-yaml`
install stops the run with the exact command to run by hand, because without it the
config cannot be read at all. A failed `ImportExcel` install is not fatal — the workbook
degrades to one CSV per sheet and the migration continues.

`Az.Accounts` is never installed on your behalf, because organisations often pin a
specific version deliberately.

Use `-NoAutoInstall` to disable both automatic installs. The YAML case then reports the
missing module and stops, as it does for everything else; the workbook writes CSV.

### Azure Access

You need an identity (user or service principal) with the following roles:

| Scope | Role | Purpose |
|---|---|---|
| Source resource group | **Reader** | Enumerate rules, workbooks, and templates |
| Target resource group | **Microsoft Sentinel Contributor** | Create/update analytics rules and Content Hub solutions |
| Target resource group | **Workbook Contributor** | Create/update workbooks |

> **Note:** These are typical required roles. Your environment may require additional roles depending on custom RBAC policies. See [Microsoft Sentinel RBAC documentation](https://learn.microsoft.com/en-us/azure/sentinel/roles) for details.

### Authentication

**Interactive (user):**
```powershell
Connect-AzAccount
# If targeting Gov cloud:
Connect-AzAccount -Environment AzureUSGovernment
```

**Service Principal:**
```powershell
$securePassword = ConvertTo-SecureString "client-secret" -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential("app-id", $securePassword)
Connect-AzAccount -ServicePrincipal -TenantId "tenant-id" -Credential $credential
```

## Quick Start

### 1. Create a config file

Copy `samples/config.yaml` and fill in your workspace details. The sample is
commented throughout, so it doubles as the reference for every available option:

```yaml
source:
  subscriptionId: "aaaa-bbbb-cccc-dddd"
  resourceGroupName: "rg-sentinel-dev"
  workspaceName: "law-sentinel-dev"

target:
  subscriptionId: "eeee-ffff-0000-1111"
  resourceGroupName: "rg-sentinel-prod"
  workspaceName: "law-sentinel-prod"

options:
  dryRun: true
  cloud: "Commercial"
```

YAML needs the `powershell-yaml` module, which the tool installs for you if it is
missing. If you would rather not have it installed, the same settings work as JSON
with identical key names — see
[troubleshooting](troubleshooting.md#powershell-yaml-module-installation-fails)
for a ready-to-copy example. The tool picks the parser from the file extension, so
a YAML file must end in `.yaml` or `.yml` and a JSON file in `.json`.

### 2. Run a dry-run

```powershell
./Sentinel-Migration-Assistant.ps1 -ConfigFile ./config.yaml -DryRun
```

Review the generated artifacts in `./output/` — each run creates its own timestamped
subfolder. Open `Migration-Summary.html` from that folder for the quickest overview.

### 3. Execute the migration

```powershell
./Sentinel-Migration-Assistant.ps1 -ConfigFile ./config.yaml -Execute
```

The tool shows the target workspace and the planned change counts, then waits for
you to confirm before writing anything. Check the workspace name on that screen.

Add `-Force` to skip the prompt when running unattended. In a pipeline this is
required: without it, an `-Execute` run stops rather than guessing.

### 4. Review the results

Open `Migration-Summary.html` from the run folder. Read it top to bottom: KPI
cards, action charts, then **Next Steps** — a prioritised list of what still has
to happen, derived from this run rather than a generic checklist. Anything the
tool could not finish on its own appears there, including the per-solution
**Manual Content Hub Install Steps** with the portal clicks spelled out.

`migration-report.md` and `Migration-Results.xlsx` in the same folder cover the
same ground in Markdown and spreadsheet form:
- Summary of actions taken
- Any failures with remediation steps
- Manual Content Hub install checklist (if applicable)

### 5. Finish the manual work

A migration is rarely complete when the script exits. Work through the Next Steps
section in order — it is sorted by how much each item blocks a working target.
The recurring ones:

| Situation | What you have to do |
|---|---|
| Solutions still **Pending** | The install was accepted but had not finished deploying. Re-run; the rules that depend on them will be created on that pass |
| Solutions **not in the target catalog** | Cannot be installed here. Find an equivalent solution, or migrate that content by hand — a re-run will not change this |
| Solutions **out of date** in the target | Left alone on purpose. Re-run with `-OverwriteExisting` to upgrade them |
| A solution's **data connector is not collecting** | Installing a solution deploys the connector definition, not a working connection. Configure it in the target portal |
| Rules were created **disabled** | Their KQL references tables that do not exist in the target yet. Connect the data source first, then enable the rule — enabling early fails again |
| Watchlists migrated with items | Spot-check the item counts in the target. A partial upload raises no error but changes how the rules behave |
| Skipped items | The target copy was already current, so it may be older than the source. Compare if you expected an update |

The tool migrates Content Hub solutions, analytics rules, workbooks, and watchlists. It
does **not** migrate data connector *configuration*, automation rules, playbooks (Logic
Apps), hunting queries, saved searches and parsers, incidents and bookmarks, or UEBA
settings — plan those separately.

## CLI Parameters

All config keys can be overridden via CLI parameters, and a CLI value always beats
the config file:

```powershell
./Sentinel-Migration-Assistant.ps1 `
    -SourceSubscriptionId "aaaa" `
    -SourceResourceGroup "rg-dev" `
    -SourceWorkspace "ws-dev" `
    -TargetSubscriptionId "bbbb" `
    -TargetResourceGroup "rg-prod" `
    -TargetWorkspace "ws-prod" `
    -Execute `
    -Cloud Commercial `
    -OverwriteExisting `
    -CreateDisabledRules
```

Choosing what to migrate — everything is migrated unless you skip it:

| Parameter | Description |
|---|---|
| `-SkipWorkbooks` | Leave workbooks out of this run |
| `-SkipWatchlists` | Leave watchlists out of this run |
| `-SkipCustomRules` | Leave custom analytics rules out of this run |
| `-SkipTemplateRules` | Leave template-based analytics rules out of this run |
| `-SkipSolutions` | Leave Content Hub solutions out of this run |
| `-SkipChecklist` | Do not generate the manual Content Hub checklist |

> The older `-MigrateWorkbooks`, `-MigrateWatchlists`, `-MigrateCustomRules`,
> `-MigrateTemplateRules` and `-MigrateSolutions` parameters still work but are
> deprecated and will warn. They defaulted to on, so they never enabled anything.
> Use `-Skip*` instead.

Safety and control:

| Parameter | Description |
|---|---|
| `-Force` | Skip the pre-write confirmation prompt. Required for unattended runs. |
| `-SkipPreflight` | Skip the workspace reachability and permission checks. Only for identities that cannot read their own role assignments. |
| `-RetryCount <n>` | Retries per API call on throttling or transient failure. |
| `-ThrottleMs <n>` | Delay between API calls. Raise it if the subscription throttles. |

Reporting:

| Parameter | Description |
|---|---|
| `-OutputDir <path>` | Parent directory for run folders. Defaults to `./output`. |
| `-NoDetailTables` | Build a slim KPI/chart-only HTML summary without the embedded drill-down tables. Useful for very large workspaces. |
| `-IncludeTableStats` | Add a **Table Coverage** report showing which migrated rules reference tables that hold no data in the target. Needs Log Analytics Reader on the target. |
| `-TableStatsLookbackDays <n>` | Lookback window for `-IncludeTableStats`. Defaults to 7. |

Every parameter is documented in the script's own help:

```powershell
Get-Help ./Sentinel-Migration-Assistant.ps1 -Full
```

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | Completed with no failures |
| `1` | Completed, but one or more items failed — check the report |
| `2` | Could not start: bad configuration, unreachable workspace, or missing permission |

## Key Behaviors

### Idempotency
Re-running the tool is safe, and is the normal way to use it — most migrations take
two or three passes. It uses deterministic resource IDs:
- **Template-based rules**: Uses `alertRuleTemplateName` as the rule ID
- **Custom rules**: Generates a deterministic GUID from `displayName`
- **Workbooks**: Generates a deterministic GUID from `displayName`

Because the IDs are stable, a second run recognises what it already created and
reports it as skipped rather than making a duplicate. Only missing or previously
failed items are created. There is no separate resume mode — to pick up after a
failure, run the same command again.

Existing resources are skipped unless `-OverwriteExisting` is set. With that switch,
the source copy replaces the target copy, so any change made directly in the target
is lost.

### Dry-Run Mode
Default behavior. Performs all discovery steps but skips any PUT/POST/DELETE calls.
Produces a full migration plan report showing what *would* happen.

### Error Handling
The tool continues on partial failures. All errors are captured in the final report
with remediation guidance. ARM throttling is handled with exponential backoff.

### Content Hub
The tool mirrors the source workspace's installed solutions into the target, in dependency
order, before any rules are created — so a rule that depends on a solution has something to
bind to. It runs by default; `-SkipSolutions` turns it off.

Three behaviours are worth knowing:

- **The target receives the current catalog version, not the source's.** The install API
  identifies a solution by an opaque `contentProductId` that encodes its version, and only
  the current one is published, so pinning to the source's exact version is not possible.
  A target can therefore end up a version ahead of the source.
- **An already-installed solution is left alone**, even at an older version, unless
  `-OverwriteExisting` is passed. Out-of-date solutions are reported either way.
- **Install is asynchronous.** The API accepts the request before the solution's rule
  templates exist. The tool waits for each, but a large solution can outlast that wait and
  is reported as **Pending** — re-run to migrate the rules that depend on it.

A solution the target's catalog does not offer cannot be installed; Commercial and
Government catalogs differ, and solutions are occasionally withdrawn. Those are reported
separately, and the manual checklist remains for that case.

**Installing a solution deploys a data connector's *definition*, not a configured
connection.** The connector still has to be wired up by hand.

## Output Files

Each run writes to its own timestamped folder beneath `output/`, so artifacts from
separate runs never overwrite one another:

```
output/migration-<source-ws>-to-<target-ws>-<yyyyMMdd-HHmmss>/
├── Migration-Summary.html      ← start here
├── Migration-Results.xlsx
├── migration-report.md
├── migration-log.jsonl
└── raw/
    ├── _Full.json
    ├── SourceRules.json
    └── ...
```

| File | Description |
|---|---|
| `Migration-Summary.html` | Self-contained dashboard: KPI cards, action breakdown charts, a results-derived **Next Steps** list with the manual Content Hub install steps, and searchable drill-down tables. No internet connection required. |
| `Migration-Results.xlsx` | Inventory workbook, one sheet per area (Summary, Analytics Rules, Workbooks, Watchlists, Content Hub, Manual Checklist, Source Rules/Workbooks/Watchlists, Errors). Falls back to a `csv/` folder if the `ImportExcel` module is unavailable. |
| `migration-report.md` | Markdown report with the full migration summary |
| `migration-log.jsonl` | Structured JSON Lines log for programmatic consumption |
| `raw/*.json` | Raw JSON snapshots of everything discovered and every result, plus a combined `_Full.json` envelope |

Open `Migration-Summary.html` in any browser for the fastest read of a run. Use
`-NoDetailTables` to produce a slim KPI/chart-only summary without the embedded tables.
