# Troubleshooting

## Common Issues

### "No Az context. Run Connect-AzAccount first."

**Cause:** No active Azure session.

**Fix:**
```powershell
Connect-AzAccount
# For Gov cloud:
Connect-AzAccount -Environment AzureUSGovernment
```

### HTTP 403 — Forbidden

**Cause:** Insufficient RBAC permissions.

**Fix:** Ensure the authenticated identity has:
- **Reader** on the source resource group
- **Microsoft Sentinel Contributor** on the target resource group
- **Workbook Contributor** on the target resource group

### HTTP 429 — Too Many Requests

**Cause:** ARM API throttling.

**Fix:** The tool retries automatically with exponential backoff. If persistent:
- Increase `throttleMs` in config (e.g., `500`)
- Increase `retryCount` (e.g., `5`)
- Run during off-peak hours

### "Rule already exists in target and -OverwriteExisting not set"

**Cause:** A rule with the same ID exists in the target.

**Fix:** Either:
- Set `overwriteExisting: true` in config to update existing rules
- Or use `-OverwriteExisting` CLI switch

### Content Hub solutions not auto-installing

**Cause:** Until recently the install request omitted `contentProductId`, so every install
was rejected and fell through to the manual checklist. That is fixed. If solutions still
do not install, the remaining causes are:

- **`migrateSolutions` is off**, or `-SkipSolutions` was passed.
- **Missing permission.** The install needs
  `Microsoft.SecurityInsights/contentPackages/write` on the target — Microsoft Sentinel
  Contributor covers it. Preflight now checks this and reports it before phase 2 rather
  than as a wall of per-solution failures.
- **The solution is not in the target's catalog.** Commercial and Government catalogs
  differ, and solutions are occasionally withdrawn. These are reported as
  *Solutions Unavailable in the Target Catalog*; no re-run will resolve it. Find an
  equivalent solution, or migrate that content by hand.
- **The catalog entry carried no `contentProductId`.** Rare, but the failure reason says
  so explicitly rather than leaving a bare 400.

### The report lists rules whose solution is already installed

**Cause:** Fixed. The tool worked out which solution ships a rule by reading package fields
off the `alertRuleTemplates` payload — fields that endpoint has never returned. Every
lookup came back `Unknown`, so *every* migrated template rule landed on the checklist,
including rules whose solution was sitting installed in the target the whole time.

Identity now comes from the `contentTemplates` endpoint, which does carry `packageId`,
read from the **source** workspace (that endpoint only returns templates for solutions
installed in the workspace you ask, and the migrating rules live in source).

**Fix:** Re-run. To confirm on an existing run, open `raw/ContentHub.json` and look at
`TemplateSolutionMap`: entries should show a populated `PackageId` and `Source` of
`ContentHubTemplate`. A map that is entirely `Source = 'Unknown'` is the old behaviour.

An entry on this list now means one thing only: *the tool could not determine which
solution ships this rule.* Usually that is because the solution is not installed in the
source workspace either. It is no longer a report of failed installs — those appear
separately under *Retry failed Content Hub installations*.

### A built-in rule is missing from the checklist

**Cause:** By design. Fusion, ML Behavior Analytics, Threat Intelligence, and Microsoft
Security incident-creation rules are built into Sentinel and ship with no Content Hub
solution, so there is nothing to install. Listing them only ever sent operators looking
for a solution that does not exist.

They are suppressed **only** when no solution was resolved. If a solution *was* identified
and is genuinely absent from the target, the entry still appears, because then there is a
real action to take.

### A solution shows as Pending

**Cause:** Not an error. Content Hub installs asynchronously, and the API returns before
the solution's rule templates exist. The tool waits, but a large solution can outlast the
wait.

**Fix:** Re-run. The solution will be found installed, and the rules that depend on it
will be created on that pass.

### A solution in the target is older than the source's

**Cause:** By design. An already-installed solution is not touched unless you ask, which
matches how existing rules and workbooks are treated.

**Fix:** Re-run with `-OverwriteExisting`. Note the target receives the **current catalog
version**, which may be newer than the source's — the install API identifies a solution by
an opaque `contentProductId` that encodes its version, and only the current one is
published, so pinning to the source's exact version is not possible.

### A solution installed but its data connector is not collecting

**Cause:** Installing a solution deploys the connector's *definition*, not a configured
connection. This is a scope boundary, not a failure.

**Fix:** Configure the connector in the target portal. Until you do, the tables its rules
query stay empty, and those rules are created disabled.

### Rule fails with "cannot be installed more than once"

**Cause:** Fusion and similar rules allow only one instance per template, and Sentinel
creates its own under a fixed resource name (`BuiltInFusion`) rather than under the
template id. The tool's existence check looks for the template id, does not find it, and
the create is then rejected by the API.

**Fix:** Handled automatically. The tool re-checks the target by
`alertRuleTemplateName` and reports the rule as `Skipped`, naming the resource already
holding it. Run with `-OverwriteExisting` to push the source version onto that existing
rule instead.

### Rule fails with "Invalid length of 'N' for 'EntityMappings'"

**Cause:** Sentinel accepts at most five entity mappings per rule. Duplicates count
towards that limit, so a rule listing the same mapping twice can breach it while appearing
to have fewer distinct mappings than allowed.

**Fix:** Handled automatically. Exact duplicates are removed from every rule before it is
sent, which resolves the common case without losing anything. If more than five *distinct*
mappings remain, the rule is created with the first five and the report notes which entity
types were dropped — edit the source rule to prioritise the mappings you want, then re-run
with `-OverwriteExisting`.

### Watchlist fails with "Local File option requires value for rawContent"

**Cause:** The source watchlist has no items. `sourceType: Local` requires `rawContent`,
and the API also rejects a CSV containing only a header row.

**Fix:** Handled automatically. A watchlist with no items is created from its properties
alone, without `sourceType`/`rawContent`, and arrives empty like the source. If you expected
items, check the source watchlist in the portal — an empty result here means the source
returned no items.

### Two source rules with the same name, only one in the target

**Cause:** Both rules were created from the same Content Hub template — typically a built-in
rule plus a customised duplicate. Before this was fixed both mapped to the same target rule
id, so the second was reported as `Skipped` and never migrated.

**Fix:** Handled automatically. The first rule of each template keeps the template id and any
further rules get a distinct derived id, stable across runs. If you migrated before this fix,
re-run to pick up the rules that were dropped — existing rules are untouched.

### Workbook migration fails with 409 Conflict

**Cause:** A workbook with the same deterministic ID already exists.

**Fix:** Use `-OverwriteExisting` to update, or delete the conflicting workbook in the target first.

### Custom rule fails with "BadRequest — query validation failed"

**Cause:** The rule's KQL query references tables or functions not available in the target workspace.

**Fix:**
1. Verify the target workspace has the necessary data connectors enabled
2. Check that any custom functions referenced in the query exist in the target
3. Manually adjust the query after migration if needed

### powershell-yaml module installation fails

The tool installs `powershell-yaml` for you when your config is a `.yaml` file and
the module is missing. If that automatic install fails, the run stops and tells you.

**Cause:** PowerShell Gallery access restrictions, a proxy, or an execution policy
that blocks module installation.

**Fix:**
```powershell
# Install manually
Install-Module -Name powershell-yaml -Scope CurrentUser -Force
```

To skip the automatic attempt — on a locked-down build agent, say — run with
`-NoAutoInstall`. The tool then reports the missing module and stops instead.

If you cannot install modules at all, use a JSON config instead — JSON is parsed by
PowerShell itself and needs nothing extra. Note that **renaming `config.yaml` to
`config.json` does not work**: the two are different formats, and the parser is
chosen by file extension. You have to rewrite the settings as JSON:

```json
{
  "source": {
    "subscriptionId": "aaaa-bbbb-cccc-dddd",
    "resourceGroupName": "rg-sentinel-dev",
    "workspaceName": "law-sentinel-dev"
  },
  "target": {
    "subscriptionId": "eeee-ffff-0000-1111",
    "resourceGroupName": "rg-sentinel-prod",
    "workspaceName": "law-sentinel-prod"
  },
  "options": {
    "dryRun": true,
    "cloud": "Commercial"
  }
}
```

The key names are identical to the YAML version, so anything documented for one
applies to the other.

## Diagnostic Steps

### Enable verbose output

```powershell
./Sentinel-Migration-Assistant.ps1 -ConfigFile ./config.yaml -DryRun -Verbose
```

### Check structured logs

```powershell
# Parse JSON lines log from the most recent run folder
$run = Get-ChildItem ./output -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-Content (Join-Path $run.FullName 'migration-log.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object { $_.level -eq 'Error' } | Format-Table
```

### Inspect the raw API snapshots

Every run captures what was discovered and what happened under `raw/`, which is the
fastest way to confirm whether a problem was in discovery or in the write path:

```powershell
$run = Get-ChildItem ./output -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
(Get-Content (Join-Path $run.FullName 'raw' '_Full.json') -Raw | ConvertFrom-Json).collections.RuleResults |
    Where-Object { $_.Action -eq 'Failed' } | Format-Table DisplayName, Reason
```

### Verify ARM endpoint resolution

```powershell
Import-Module ./src/Sentinel.Api.psm1
Resolve-ArmEndpoint -Cloud Commercial -Verbose
```

### Test API connectivity

```powershell
Import-Module ./src/Sentinel.Api.psm1
$token = Get-SentinelAccessToken
# Manually test a GET call:
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
Invoke-RestMethod -Uri "https://management.azure.com/subscriptions?api-version=2022-12-01" -Headers $headers
```
