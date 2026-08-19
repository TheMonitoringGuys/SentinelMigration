# Migration Runbook

## Pre-Migration Checklist

1. [ ] Confirm source and target workspaces exist with Sentinel enabled
2. [ ] Verify RBAC roles are assigned (see [Customer Guide](customer-guide.md))
3. [ ] Authenticate to Azure (`Connect-AzAccount`)
4. [ ] Create and populate a config file from `samples/config.yaml`
5. [ ] Run a dry-run and review the report

The tool checks its own prerequisites at startup and stops with a clear message if
something is missing, so you do not need to verify module versions by hand.

## Step-by-Step Procedure

### Step 1: Dry-Run

```powershell
./Sentinel-Migration-Assistant.ps1 -ConfigFile ./config.yaml -DryRun
```

Review the run folder created under `output/` — open `Migration-Summary.html` first:
- Verify rule counts match expectations
- Read the **Next Steps** section: it lists what this run would leave unfinished
- Check the solution counts — every solution installed in the source is installed in
  the target, so this is where you see the true blast radius before committing
- Check for any pre-existing errors

A dry run applies nothing, so every KPI reflects what *would* happen. The Next
Steps list is derived from those projected results, which makes it a useful
preview of the manual work ahead before you commit to executing.

### Step 2: Content Hub Solutions

Solutions install automatically as part of the run, in dependency order, before rules
are created. There is normally nothing to do here. Three cases need attention afterwards:

1. **Pending** — the install was accepted but had not finished deploying when the run
   ended. Re-run; the rules that depend on it will be created on that pass.
2. **Not in the target catalog** — cannot be installed in this cloud. Find an equivalent
   solution or migrate that content by hand. Re-running will not help.
3. **Out of date** — a solution already in the target at an older version is left alone
   by design. Re-run with `-OverwriteExisting` to upgrade it.

Anything still listed in the **Manual Content Hub Install Checklist** falls into case 2.
Install those in the target portal, then re-run so the dependent rules can be created.

### Step 3: Execute Migration

```powershell
./Sentinel-Migration-Assistant.ps1 -ConfigFile ./config.yaml -Execute
```

Before it writes anything, the tool prints exactly what it is about to change and
asks you to confirm. Read the target workspace name on that screen — it is the last
point at which a wrong target costs you nothing.

To skip the prompt in automation, add `-Force`. In a non-interactive session
(a pipeline, or `pwsh -NonInteractive`) `-Execute` without `-Force` stops with an
error rather than hanging or guessing.

### Step 4: Verify Results

1. Review the execution artifacts in the new run folder under `output/`
   (`Migration-Summary.html` for the dashboard, `Migration-Results.xlsx` for the
   full inventory)
2. Work through the **Next Steps** section in order — it is sorted by how much
   each item blocks a working target
3. In Azure Portal, verify:
   - Analytics rules appear in target workspace with correct enabled/disabled state
   - Workbooks are visible under the target resource group
4. Address any failures listed in the report

**Rules created as disabled.** Check the **Rules Disabled** KPI. These reference
tables that do not exist in the target yet, so Sentinel would reject them in an
enabled state. Connect the underlying data source first, then enable each rule in
Analytics — enabling before the table exists fails the same way.

**Watchlists.** Compare item counts against the source. A partial upload produces
no error but changes how the dependent rules behave.

### Step 5: Post-Migration

- Verify data connectors in target workspace are producing data
- Test a sample of migrated rules by triggering test alerts
- Confirm workbooks render correctly with target workspace data

### What this tool does not migrate

Plan these separately — the dashboard's Next Steps section repeats the list so it
is not forgotten at the end of a run:

- Data connectors — the rules will not fire without their source tables
- Automation rules and playbooks (Logic Apps)
- Hunting queries
- Saved searches and parsers (functions)
- Incidents and bookmarks
- UEBA and entity behaviour settings

## Re-running the tool

Re-running is the normal way to use this tool, not a recovery step. A migration
usually takes two or three passes: dry run, install what the checklist asks for,
execute, fix what failed, execute again.

**Re-running is safe.** The tool never deletes source content, and by default it
does not overwrite target items either. On a second pass:

- Items that already exist in the target are reported as **Skipped**, not
  duplicated. Re-running does not create a second copy of anything.
- Only the items that were missing or failed are created.
- Add `-OverwriteExisting` when you *want* the target refreshed from the source.
  This replaces existing target items, so any edit made directly in the target is
  lost. Without it, the target copy wins.

**Picking up where a failed run stopped.** There is no separate resume mode and none
is needed: run the same command again. Whatever succeeded is skipped, whatever
failed is retried. If a run was interrupted midway, the same applies.

**Narrowing a re-run.** Once one content type is settled, skip it to make the next
pass faster and its report easier to read:

```powershell
# Rules failed, workbooks and watchlists are already done
./Sentinel-Migration-Assistant.ps1 -ConfigFile ./config.yaml -Execute `
    -SkipWorkbooks -SkipWatchlists
```

Each run writes to its own timestamped folder under `output/`, so re-running never
overwrites the evidence from a previous attempt.

## Checking that migrated rules will actually fire

A rule can migrate successfully and still never produce an alert, because its query
references a table the target has no data in. That is a data connector gap, not a
migration failure, and the migration report cannot see it by default.

```powershell
./Sentinel-Migration-Assistant.ps1 -ConfigFile ./config.yaml -DryRun -IncludeTableStats
```

This adds a **Table Coverage** sheet listing, per rule, which referenced tables hold
data in the target. Rules marked `NoData` are migrated but dormant — connect the
underlying data source before relying on them.

It is opt-in because it queries the Log Analytics data plane, which needs
**Log Analytics Reader** on the target. That is a separate grant from the
permissions the migration itself uses, so the tool does not assume you have it.

## Rollback

The tool does not delete source content. To rollback target changes:
- **Rules**: Delete migrated rules from the target via Azure Portal or REST API
- **Workbooks**: Delete migrated workbooks from the target resource group
- **Content Hub solutions**: Uninstall solutions from Content Hub if desired

## Scheduling Repeated Migrations

For ongoing DEV → PROD sync, run the tool in a CI/CD pipeline. `-Force` is required:
without it the confirmation prompt cannot be answered and the run fails by design.

With a YAML config the tool installs `powershell-yaml` on the agent itself if it is
missing, so a hosted agent works without an extra step. Two reasons you might still
prefer JSON in a pipeline: it needs no module at all, and it avoids a gallery call on
every run. If your agents block module installation, either pre-install the module or
pass `-NoAutoInstall` and use JSON.

```yaml
# Azure DevOps example
- task: AzurePowerShell@5
  inputs:
    azureSubscription: 'service-connection'
    scriptType: 'FilePath'
    scriptPath: './Sentinel-Migration-Assistant.ps1'
    # A .json config needs no modules beyond Az.Accounts. A .yaml config works too -
    # powershell-yaml is installed to the agent's user scope on demand. Add
    # -NoAutoInstall if your agents must not reach the PowerShell Gallery.
    scriptArguments: '-ConfigFile ./config.json -Execute -Force'
    azurePowerShellVersion: 'LatestVersion'
    pwsh: true
```

The tool sets an exit code the pipeline can act on:

| Exit code | Meaning |
|-----------|---------|
| `0` | Completed with no failures |
| `1` | Completed, but one or more items failed — check the report |
| `2` | Could not start (bad config, unreachable workspace, missing permission) |

A scheduled sync that should track the source exactly needs `-OverwriteExisting`;
without it, items already present in the target are left as they are.
