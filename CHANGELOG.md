# Sentinel Migration Assistant — Change Log

## Unreleased

### Two rules built from one template no longer overwrite each other

A workspace held two distinct rules both named "Cross-tenant Access Settings Organization
Deleted" — the built-in one and a retuned copy, a normal result of duplicating a template
rule and adjusting it. Only one reached the target. The run reported `[44/44] … -> Skipped`,
which reads as an ordinary "already there" and gave no sign anything was lost.

The target rule name came from `Get-RuleMigrationId`, which returns the template id for any
template-based rule. That is the Sentinel convention and it keeps re-runs idempotent, but it
assumes one rule per template. With two, both resolved to the same target name: the first was
created, the second found it already present and skipped itself. The rule was silently
dropped and nothing in the output said so.

`Resolve-RuleMigrationIdMap` now assigns target ids for the whole rule set at once instead of
one rule at a time, so collisions are visible before any call is made. The first rule of each
template keeps the template id — single-rule workspaces behave exactly as before — and any
further rule gets an id derived from the template plus the source rule name. Assignment is
ordered by source rule name, an immutable GUID, so it is stable no matter what order the API
returns rules in and re-runs land on the same ids rather than creating fresh duplicates.

### Rules whose kind allows only one instance per template are no longer reported as failures

Fusion rules failed with *"Analytics rule template … is already installed for workspace … and
cannot be installed more than once."* Sentinel creates its own Fusion rule under the resource
name `BuiltInFusion`, not under the template id, so the pre-flight GET for the template id
returned 404, the tool concluded nothing was there, and the create was rejected.

The recovery matches on the error rather than on a list of rule kinds, because the constraint
belongs to the template, not the kind — `MicrosoftSecurityIncidentCreation`, for one, is not
limited to a single instance. On that error the target rule list is fetched and searched by
`alertRuleTemplateName`. If the template is already installed the rule is reported as
`Skipped` naming the existing resource, or updated in place when `-OverwriteExisting` is set.
If no match is found the original failure stands. The extra list call happens only on that
error path, so a normal run is unaffected.

### Rules carrying duplicate entity mappings no longer exceed the API limit

A rule with six `entityMappings` was rejected: *"Invalid length of '6' for 'EntityMappings',
should be between '1' and '5'."* Two of the six were byte-identical (`Process`/`ProcessId`
twice). Sentinel counts duplicates against the cap even though they add nothing.

`Export-RuleDefinition` now drops exact duplicates on every rule. Mappings match when they
share an entity type and the same set of identifier/column pairs, compared order-insensitively
so that two mappings listing the same fields in a different order still collapse. For the rule
above this yields exactly five and nothing is lost.

Genuinely distinct overflow is still possible, so the length error is also caught: the rule is
retried trimmed to the maximum the error reports, and the result carries a note naming the
entity types that were dropped. Trimming is a fallback, never silent — dedupe is what handles
the common case.

### Watchlists with no items now migrate instead of failing

A watchlist with zero items failed with *"Local File option requires value for rawContent."*
The body always set `sourceType = 'Local'`, which makes `rawContent` mandatory, but
`rawContent` was only attached when there were items to put in it.

Sending a header-only CSV does not work either — the API rejects it with *"no watchlist items
found in the provided rawContent"*. A watchlist with no rows is not expressible as a local
file upload at all. So when the source has no items, `sourceType`, `contentType` and
`rawContent` are all omitted and the watchlist is created from its properties alone. It
arrives empty, matching the source, and items can be added later. Watchlists that do have
items are unchanged.

### The manual checklist stopped listing rules that need nothing

A run that migrated 44 template-based rules produced a 44-item "install these solutions by
hand" checklist — every rule, including ones whose solution was already installed in the
target. The count matching the rule count exactly was the tell: a filter that never matched.

`Get-TemplatePackageRef` worked out which solution ships a rule by reading `packageId`,
`packageName`, `packageDisplayName` and a `source` block off the template objects returned
by `alertRuleTemplates`. That endpoint has never returned any of them. Every entry in the
template→solution map came back `Source = 'Unknown'` with a null `PackageId`, so nothing
could ever be filtered out and every rule fell through to the checklist. This was not a
regression from the solution-install work; it had never worked for any workspace. It stayed
hidden because the checklist *was* the expected output — only once solutions began
installing did a 44-item list of things already installed become visibly wrong.

The test suite did not catch it because the fixtures fed legacy template objects carrying
`packageId`, a shape the real API never produces. The tests were green against fiction.
They now use the real shape.

Solution identity now comes from `contentTemplates`, which does carry `packageId`,
`contentId` and `contentProductId`. It is read from the **source** workspace: the endpoint
only returns templates for solutions installed in the workspace you ask, and the migrating
rules live in source. `rule.alertRuleTemplateName` joins to `contentTemplate.contentId`,
which carries `packageId`, which joins to the content package. The old field probes remain
as a fallback. If the fetch fails the map degrades to "could not determine" instead of
throwing, which is the pre-existing behaviour.

The map is also built from the **union** of both endpoints rather than the legacy list
alone. They do not cover the same set: `alertRuleTemplates` returns the built-in catalogue,
while `contentTemplates` returns what the installed solutions ship. On the workspace this
was diagnosed against, only 12 of 45 migrating rules had a template in the legacy list at
all — the other 33 came from solutions, so no amount of identity resolution could have
reached them. They had no map entry to resolve. The map now spans 675 templates where it
previously held 477.

Built-in rule kinds — Fusion, ML Behavior Analytics, Threat Intelligence, and Microsoft
Security incident-creation — are no longer listed when no solution was resolved. They ship
with Sentinel and no Content Hub solution provides them, so the entry only ever sent
operators looking for something that does not exist. They are still listed if a solution
*was* identified and is genuinely missing, because then there is a real action to take.

A checklist entry now means one thing: the tool could not determine which solution ships
this rule, usually because it is not installed in the source either. It is no longer a
report of failed installs, which have their own section. The console line, the HTML Next
Steps entry and the Markdown section were reworded to match, and the HTML entry dropped
from red to amber — it is a gap in knowledge, not a failure.

### Content Hub solutions now actually migrate

The tool advertised Content Hub solution installation and had real code for it — a
dedicated phase, KPI cards, a fallback checklist. Solutions did not migrate. Two
independent causes, either fatal on its own.

**The install request was malformed.** Microsoft's
[Content Package - Install](https://learn.microsoft.com/en-us/rest/api/securityinsights/content-package/install)
body requires `contentProductId` alongside `contentId`. `Install-ContentPackage` sent
`contentId`, `displayName`, `version` and `contentKind`, and dropped the one field it
could not do without — even though the catalog objects it already had in hand carried it
as `properties.contentProductId`. Every install was rejected, caught, and converted into
an "install this by hand" checklist row. That fallback is why nobody noticed: a run in
which nothing installed was indistinguishable from a run in which nothing needed to.

**Solutions were only discovered through analytics rules.** The work list was built from
the template-based rules being migrated, and `Get-InstalledContentPackages` was called
against the target only — never the source. The tool had no concept of "the set of
solutions installed in the source workspace". A solution was invisible unless a migrating
template rule happened to name it, so solutions shipping workbooks, hunting queries,
parsers, playbooks or data connectors were silently skipped, as were solutions whose rules
the operator had never enabled. Phase 2 was also gated on `MigrateTemplateRules`, so
`-SkipTemplateRules` disabled solution migration as a side effect nobody asked for.

The source workspace's installed solution set is now the unit of migration, unioned with
the solutions the migrating template rules require — additive, so the existing
rule-dependency behaviour keeps working. Each solution is classified against the target:
install, upgrade, already current, or not present in the target's catalog. Installs are
topologically sorted by `properties.dependencies.criteria`, counting only criteria that
name another solution in the same set, since most point at content *inside* the solution.
A dependency cycle falls back to the original order and says so, because a wrong order
costs a retry while throwing costs the whole run.

Install is asynchronous — the API returns before the solution's rule templates exist, and
phase 3 would otherwise race phase 2. Each install is now polled until `installedVersion`
appears. A large solution can outlast any sensible poll budget, so anything still
deploying is reported as **Pending** rather than as a failure: it means re-run, not
investigate.

Behaviour worth stating plainly:

- **The target receives the current catalog version, not the source's.** Pinning to the
  source version is not possible: `contentProductId` encodes the version, it is opaque and
  cannot be derived, and only the current one is published. A target can end up a version
  ahead of its source.
- **An already-installed solution is left alone**, even at an older version, unless
  `-OverwriteExisting` is passed — matching how existing rules and workbooks are treated.
  Out-of-date solutions are reported either way.
- **Installing a solution deploys a data connector's *definition*, not a configured
  connection.** That boundary has not moved.

New `migrateSolutions` config option and `-SkipSolutions` switch, both defaulting to on.
Phase 2 is now gated on that option alone. `Microsoft.SecurityInsights/contentPackages/write`
was added to preflight, so a missing role is reported once up front rather than as a wall
of per-solution failures. The HTML dashboard gains a *Solutions Upgraded* KPI and Next
Steps entries for the two states a re-run will not resolve on its own; the Markdown report
gains matching sections.

`docs/troubleshooting.md` blamed the original symptom on the `contentPackages` API "not
supporting all solution types". It was our request that was wrong, and that entry has been
corrected — a plausible false explanation is worse than none, because it stops anyone
looking further.

Found while writing the tests for this, and fixed: `New-ContentHubChecklist` returns an
empty array, PowerShell unrolls it to nothing on assignment, and `@($null)` then wraps that
single null into a one-element array. Every clean run would have rendered a phantom
checklist row telling the operator to install a solution that does not exist.

29 new tests in `Sentinel.ContentHub.Tests.ps1` covering the request body, the four-way
classification, the upgrade gate, dependency ordering and its cycle fallback; 5 in
`Sentinel.Config.Tests.ps1` for the new option. They can prove the shape of the request and
the classification logic. They cannot prove the service accepts the body — that needs a
live run against two real workspaces, and that run is the acceptance test.

### Content Hub no longer names the wrong solution

`Build-TemplateSolutionMap` matched rule templates to Content Hub solutions with a loop
that had no matching logic in it. For any template that did not carry explicit package
metadata, it walked the whole catalog and assigned the solution name on every iteration,
so the template ended up attributed to **whichever package happened to be last in the
catalog**. Two rules with nothing in common both came back as "Zscaler".

That name is not an internal detail. It flows straight into the operator's manual
install checklist in the Markdown report, the HTML dashboard and the Excel workbook, as
`Solution: <name>`. The instruction to go install an unrelated solution was indistinguishable
from a correct one, and the honest fallback text — `(Could not determine — search Content
Hub by rule name)` — was almost unreachable in practice, because the loop always assigned
something first.

Templates are now resolved against the catalog by actual identity: `contentId` first,
then exact display name, checking installed packages before available ones so the name
shown is the one the operator will see in the portal. A template that declares no package
keeps a null solution name and gets the fallback text. Where the solution *is* known, the
checklist step now names it directly rather than saying "search by rule name".

The guiding rule: naming the wrong solution is worse than admitting the mapping is
unknown, because in a checklist a wrong name reads exactly like a right one.

`Sentinel.ContentHub.psm1` had no test file — the last module without one, and the module
that generates the operator's manual steps. It now has 38 tests. Reverting the fix fails
six of them.

Also in this module: `Sync-ContentHubSolutions` and `New-ContentHubChecklist` accept an
empty rule set instead of failing parameter binding. A workspace whose analytics rules
are all hand-written has no template rules, and the right answer for that is an empty
checklist. The orchestrator already guarded this case, so it was latent rather than live,
but the guard was a hidden requirement on every future caller.

### Dry-run verbs no longer leak past the report into the console and the workbook

The previous release fixed raw verbs such as `WouldBeCreatedDisabled` in the Markdown
report. The same pattern survived in three other places, found by running the exporters
and reading the output rather than by grepping:

- **Every Excel worksheet showed raw verbs.** All four result flatteners wrote
  `$r.Action` through unchanged, so the workbook disagreed with both the dashboard and
  the report. The dry-run distinction they carried is preserved as a separate
  `PlannedOnly` column rather than smuggled back into the verb, so the exports stay
  lossless while agreeing with everything else.
- **The console coloured dry runs differently from real runs.** The colour was chosen by
  a `switch` on the raw verb, so the same outcome was green in one mode and uncoloured
  in the other.
- **Rules that will land disabled were coloured as ordinary successes in dry run** —
  green, not yellow. Yellow is what tells the operator a rule needs enabling by hand.

Underneath the colour bug was one worth naming: PowerShell's `switch` has no implicit
`break`, so `CreatedDisabled` matched both its own arm and a later `-match 'Created'`
arm and returned **two** colours. `Write-Host -ForegroundColor` accepts an array without
complaint and uses the first, which is why this never surfaced as an error.

Four helpers now live in `Sentinel.Common.psm1` — `Get-ActionColor`, `Format-ActionLabel`,
`Format-MigrationDuration` and `ConvertTo-ItemList` — and every artifact calls them.
`Get-ActionColor` normalises before matching and returns from each arm explicitly, so it
cannot return an array; a test asserts exactly one colour for every known verb.
`Sentinel.Export.psm1` and `Sentinel.ContentHub.psm1` turned out to have no
`Import-Module Sentinel.Common` at all, which is the mechanical reason they had drifted.

`Format-MigrationDuration` replaces a second, wrong duration implementation in the export
path that still used `hh\:mm\:ss` — a 26-hour run appeared in the workbook summary as
`02:00:00`. There is now one duration function, and it keeps the day component.

`Export-MigrationWorkbook` honours `-NoAutoInstall`, which previously governed only the
YAML module and was silently ignored for ImportExcel.

### A CI workflow, which this repository cannot yet run — and a local gate that does

There is now a GitHub Actions workflow that runs the Pester suite on Windows and Linux
for every push and pull request, plus an advisory PSScriptAnalyzer pass that reports
findings to the job summary without failing the build.

**It does not execute in this repository today.** This repo is a private repo owned by an
Enterprise Managed User account, and GitHub Actions is disabled there by enterprise
policy: the Actions API reports zero registered workflows and zero runs, and pull request
#7 received no check runs at all. The workflow file itself is valid — the YAML parses and
the steps are standard — so it will begin working unchanged if the repository moves to an
organisation with Actions enabled, or if that policy changes.

Until then the gate is local, and it is now enforced rather than remembered. `git push`
runs the full suite via a `pre-push` hook and refuses the push if anything fails:

```powershell
./tools/Install-GitHooks.ps1
```

The installer points `core.hooksPath` at the version-controlled `tools/hooks` directory,
so the hook travels with the repository instead of living in one developer's `.git`. The
path is deliberately relative: git resolves it against the top of each working tree, so a
single setting is correct in the main clone and in every worktree simultaneously. Pushes
that only delete a branch skip the run. `git push --no-verify` bypasses it for a
docs-only fixup, and `-Uninstall` removes it.

Verified by reintroducing a real regression — the `CreatedDisabled` colour arm — and
confirming the push was refused, naming the failing test and the assertion. Restoring the
fix let it through. A gate that has not been watched to fail is not known to be a gate.

The suite is 358 tests, up from 290, and takes about 25 seconds.

### The Markdown report now matches the dashboard

The `.md` report and the HTML dashboard are generated from the same run, but were
built by unrelated code that recomputed everything independently. They had drifted,
and the Markdown side had drifted furthest. Six defects, all confirmed by generating
real reports rather than by reading code:

- **Rules created as disabled were missing from every dry-run report.** The section
  tested for the action `CreatedDisabled`, but in dry run the migration modules emit
  `WouldBeCreatedDisabled`. Since dry run is the default, this section was absent from
  the report almost everyone reads first — the one listing exactly which rules need
  enabling by hand.
- **A null rule classification produced a broken table** — data rows with no header
  and no separator, which renders as a paragraph of pipe characters.
- **Raw internal verbs leaked into the text.** The report said `WouldBeCreated` where
  the dashboard said `Rules Created`.
- **Discovered workbook and watchlist counts read zero unless something was migrated.**
  The counts were gated on the migration result arrays instead of the discovery
  counts, so "found 12 workbooks, migrated 0" reported 0 found.
- **Runs over 24 hours reported the wrong duration.** The format string `hh\:mm\:ss`
  silently drops whole days: a 25-hour run displayed as `01:00:00`.
- **A pipe character in a rule name broke the surrounding table**, as did a newline in
  an API error message.
- **An empty "Content Hub Solutions" heading** appeared whenever Content Hub ran with
  nothing to install — a heading promising content and delivering none, which reads
  like the report was truncated.
- **A multi-line error message broke out of its bullet.** The continuation landed at
  column 0 and rendered as a separate paragraph, detached from the error it belonged
  to. ARM messages are routinely multi-line.

The last two were found only by generating a report with realistic data and reading
it. Every one of the tests passed while both defects were present, because a test that
asserts a section exists cannot notice that the section is empty.

The generator was rewritten around four helpers — duration formatting, cell escaping,
inline (bullet) formatting and table construction — so a malformed table is no longer
expressible. It also now receives the KPIs, next steps and table coverage the
orchestrator already computed for the dashboard, rather than recomputing them. The two
artifacts can no longer disagree about a number, because there is only one number.

New sections in the Markdown report, all previously HTML-only: **Migration Outcome**
(the KPI table), **Next Steps**, and **Target Table Coverage** (rules whose target
tables hold no data, which usually means a connector has not been enabled yet).

`Get-NormalizedAction` — the function that maps `WouldBeCreatedDisabled` to
`CreatedDisabled` — moved to `Sentinel.Common.psm1`. It previously lived in the HTML
module only, which is precisely why the Markdown generator did not use it.

`Sentinel.Report.psm1` had no test file at all; it was the only module without one.
It now has 35 tests, including one that parses the generated Markdown and asserts every
table is well-formed, and one that asserts no heading is ever followed immediately by
another heading. Writing them turned up a rounding bug in the new duration helper
— `[int]1.5` is `2`, so 90 minutes rendered as `02:30:00`.

### Dashboard: a Source Discovery section, and honest chart labels

Discovery counts (rules found, workbooks found, watchlists found) lived only inside the
collapsible Summary detail table, so `-NoDetailTables` produced a dashboard that never
said how much content the source workspace held. They are now their own section of KPI
cards, visible regardless of detail-table settings, mirroring the Markdown report.

The Breakdowns charts grouped on the raw action verb, so a dry run showed a bar
labelled `WouldBeCreatedDisabled` directly below a KPI card reading `Rules Disabled` —
one number, two names, same page. Charts now normalise first.

### powershell-yaml installs itself

If your config is a `.yaml` file and `powershell-yaml` is missing, the tool now
installs it to `-Scope CurrentUser` and continues, instead of stopping to tell you to
run one command. It never elevates and never installs machine-wide.

The scope is deliberately narrow. `Az.Accounts` is **not** auto-installed: it is large,
and organisations frequently pin a version on purpose. And YAML is only required when
you actually use a YAML config — a JSON config still needs nothing beyond
`Az.Accounts`.

Pass `-NoAutoInstall` to disable this. If the install fails for any reason, the run
stops with the same manual instructions as before, so a locked-down agent is no worse
off than it was.

### One config sample, not two

`samples/config.json` has been removed. There were two samples of the same six
settings, which made "which one do I use?" the first question a new user had to
answer — for no benefit, since the schemas are identical.

`samples/config.yaml` is now the single sample. YAML was chosen because it supports
comments, so the sample doubles as the reference for every option. **JSON support is
unchanged** — existing `.json` configs keep working, the parser is still selected by
file extension, and `docs/troubleshooting.md` carries a copy-ready JSON example for
anyone who would rather not depend on `powershell-yaml`.

Two related fixes found while doing this:

- `docs/troubleshooting.md` advised renaming `config.yaml` to `config.json` when the
  YAML module would not install. That does not work and never did — the formats
  differ, and the rename makes the JSON parser choke on the first comment. Someone
  already blocked would have hit a second, more confusing error. It now shows the
  actual JSON equivalent.
- The CI/CD example in `docs/runbook.md` used a YAML config without noting that
  hosted build agents rarely have `powershell-yaml` installed, so it would have
  failed with exit code 2. It now uses JSON and explains the choice.

### Scope stated explicitly: in-tenant migrations

The tool migrates between workspaces in a **single Azure AD tenant** — the DEV → PROD
promotion it is built for. Source and target may sit in different subscriptions and
resource groups, provided both are in the tenant you sign in to.

This was always true, because the access token is acquired once from the current
context and Azure AD tokens are tenant-scoped. It was never written down, and the
failure mode was confusing: a subscription in another tenant does not fail at
sign-in, it fails later with a 401 from ARM, which preflight reported as a generic
"could not read workspace" — indistinguishable from a missing RBAC role.

Preflight now recognises the 401 and says so, naming the subscription. The scope is
stated in the README and the customer guide.

### Usability and reliability overhaul

A full sweep of the tool, prompted by the observation that it predates the Sentinel
Assessment Tool and had not absorbed what that tool learned. Twenty findings — eight
bugs and twelve enhancements — addressed together. The goal throughout was to make
the tool safe to run without reading the source first.

#### Breaking changes

Two changes alter existing behaviour. Both are deliberate.

**`-Execute` now asks before writing.** The tool prints the target workspace and the
planned change counts, then waits for confirmation. Pass `-Force` to skip the
prompt. In a non-interactive session `-Execute` without `-Force` now **fails** rather
than proceeding silently — **existing pipelines must add `-Force`**. The old
behaviour meant a mistyped target workspace was discovered after the writes, not
before.

**`-Migrate*` parameters are deprecated in favour of `-Skip*`.** `-MigrateWorkbooks`,
`-MigrateWatchlists`, `-MigrateCustomRules` and `-MigrateTemplateRules` still work
and still warn; they will be removed in a future version. They defaulted to `$true`,
so `-MigrateWorkbooks` read like it enabled something it had not disabled. The
replacements — `-SkipWorkbooks`, `-SkipWatchlists`, `-SkipCustomRules`,
`-SkipTemplateRules` — say what they do. If both are supplied, `-Skip*` wins.

#### Safety

- **Preflight workspace check.** Before any work, the tool confirms both workspaces
  exist, have Sentinel enabled, and that the signed-in identity can write to the
  target. A wrong subscription or a missing role assignment now fails in seconds
  with a specific message instead of midway through a migration. Bypass with
  `-SkipPreflight` for identities that cannot read their own role assignments.
- **Prerequisite check.** PowerShell and Az module versions are verified at startup,
  with `ImportExcel` reported as optional rather than missing.
- **Source and target may no longer be the same workspace.** Previously accepted,
  and it produced a confusing self-migration.
- **A failure in one content type no longer aborts the run.** Discovery and
  migration of rules, workbooks and watchlists are independent; one failing leaves
  the others to finish and records the failure with a suggested remediation.

#### Clarity

- **Next Steps on the console**, not only in the HTML report — the same prioritised
  list, so a run that is never opened in a browser still says what remains.
- **Readable API errors.** Azure's nested error payloads are unwrapped to the
  message and remediation that matter, rather than a wall of JSON.
- **Progress reporting** during rule, workbook and watchlist migration, so a long
  run is visibly working rather than apparently hung.
- **Exit codes** are now contractual: `0` clean, `1` completed with failures,
  `2` could not start.

#### New capabilities

- **JSON configuration.** `-ConfigFile` accepts `.json`, and detects JSON content in
  a `.yaml` file. YAML previously required `powershell-yaml`, which the tool tried
  to install silently — it no longer does. JSON needs no third-party module, so it
  is the fallback when installing modules is not possible; `docs/troubleshooting.md`
  has a copy-ready example.
  *(Superseded: auto-install returned in Unreleased, but announced rather than silent,
  scoped to `powershell-yaml` only, and disableable with `-NoAutoInstall`.)*
- **`-IncludeTableStats`** reports which migrated rules reference tables that hold no
  data in the target, distinguishing "migrated" from "will actually fire". Opt-in,
  because it needs Log Analytics data-plane access. Tune the window with
  `-TableStatsLookbackDays` (default 7).
- **`agent-input.json`**, a machine-readable summary of the run for downstream
  automation.

#### Fixes

- Empty collections counted as one item, inflating every "0 items" case to 1.
- A single-element collection returned from a helper could arrive at the caller as a
  nested array, silently collapsing to one item.
- `Sentinel.Preflight.psm1` called a helper it never imported, so the 404 and 403
  paths — exactly the cases preflight exists to explain — threw
  `CommandNotFoundException` instead of a useful message.
- `options.concurrency` is no longer accepted. It was never implemented. The
  migration runs sequentially on purpose: ARM throttles per subscription, so
  parallel writes finish no faster and fail in harder-to-resume ways. Use
  `options.throttleMs` to pace a run.

#### Testing

The suite grew from 157 to 244 tests, adding coverage for the shared helpers,
configuration parsing, preflight permission logic, table statistics, and an
end-to-end smoke test that runs the real entry point and asserts on its exit codes.
Two of the bugs above were found only because those tests assert on caller-visible
shapes and exercise error paths; neither was visible from reading the code.

---

### Feature: Next steps and manual completion guidance in the HTML dashboard

**Files:** `src/Sentinel.Html.psm1`, `tests/Sentinel.Html.Tests.ps1`

**Problem:** The dashboard reported what a run *did*, then stopped. It went
straight from the charts to the raw drill-down tables, leaving the reader to work
out what still had to happen by hand. The manual Content Hub checklist — the one
thing that genuinely blocks a migration from finishing — appeared only as a KPI
count and a table row whose four numbered steps were joined into a single cell.

**Change:** Two new sections between the breakdowns and the detail tables.

`Get-MigrationNextSteps` derives a prioritised action list from the results
rather than printing boilerplate, so a clean run yields two steps and a messy dry
run yields eight. Steps are ordered by how much each one blocks a working target:

1. Dry-run notice — nothing was applied, so this outranks everything else
2. Manual Content Hub installs, then failed installs
3. Rules created disabled — connect the data source *before* enabling
4. Failed rules / workbooks / watchlists, each with its known causes
5. Skipped items, and watchlists whose item counts should be spot-checked
6. The error log
7. What this tool does **not** migrate — data connectors, automation rules,
   playbooks, hunting queries, saved searches and parsers, incidents, UEBA
8. Post-migration verification (execute runs only)

`New-NextStepsHtml` renders those steps, then the per-solution Content Hub
checklist as readable cards with the numbered steps intact. The workbook still
flattens them into one cell, which is right for filtering but unreadable as
instructions.

Steps carry an anchor to the matching detail section, but only sections that were
actually rendered are linked — with `-NoDetailTables` the anchors would otherwise
be dead links.

### Fix: KPI cards read zero for every dry run

**File:** `src/Sentinel.Html.psm1` — `Get-MigrationKpis`, `Get-NormalizedAction`

`Get-MigrationKpis` matched `^Created` and `^Updated`, but in dry-run mode the
migration modules emit `WouldBeCreated` and `WouldBeUpdated`. Since
`'WouldBeCreated' -match '^Created'` is false, **every KPI card read 0 in a dry
run** — which the runbook prescribes as step 1 and is by far the most common way
the tool is used.

The failure was easy to miss because `Get-ActionBreakdown` groups on the raw
`Action` string, so the charts rendered correctly while the cards above them
showed zero. `Skipped` and `Failed` are early-return paths that are never
prefixed, so those two cards happened to work, which made the rest look like a
genuinely empty run rather than a bug.

`Get-NormalizedAction` now strips the `WouldBe` prefix, so one set of matchers
serves both modes.

### Fix: rules created as disabled were counted as ordinary creations

**File:** `src/Sentinel.Html.psm1` — `Get-MigrationKpis`

`'CreatedDisabled' -match '^Created'` is true, so rules the tool had to create in
a disabled state were folded into **Rules Created**. Those are rules whose KQL
references tables absent from the target; the tool retries them disabled so
Sentinel skips query validation, and they need a real follow-up — connect the
data source, *then* enable — before the target is protected.

Matchers are now anchored (`^Created$`, `^Updated$`) and a distinct **Rules
Disabled** KPI sits between Rules Updated and Rules Skipped. The Markdown report
has had a dedicated "Rules Created as Disabled" section since an earlier release,
so the two artifacts now agree.

### Fix: absent collections reported one phantom item

**Files:** `src/Sentinel.Html.psm1`, `src/Sentinel.Export.psm1`

`@($null).Count` is 1, not 0. The HTML module counted collections directly, so
when Content Hub sync was skipped the dashboard showed **Manual Checklist: 1**
and rendered a checklist card with every field blank. The Export module already
had `ConvertTo-ItemList` for exactly this; the HTML module never got it. It now
does, and all twelve counting sites use it.

Both copies of the helper gained a note about the related trap that surfaced
while fixing this: PowerShell unrolls a single-element array on return, so
`.Count` on an unwrapped result reads the *element's* own `Count` property. A
lone next-step object has `Count = 0`, which silently suppressed the whole
section. Call sites wrap in `@()`.

### Hardening: unbounded pagination in `Invoke-SentinelApiList`

**File:** `src/Sentinel.Api.psm1`

The list helper followed `nextLink` in a `while ($currentUri)` loop with no
ceiling, so a service returning a self-referential link would spin forever. Ported
the assessment tool's guards: `MaxRecords` (default 50000), `MaxPages` (default
1000), and a `HashSet` of links already fetched.

**Tests:** 45 new Pester tests covering action normalisation, dry-run and
`CreatedDisabled` KPI counts, next-step derivation and ordering, anchor validity,
null-collection handling, and the pagination guards. Full suite: 157 passing.

---

### Feature: Rich output artifacts matching the Sentinel Assessment Tool

**Files:** `src/Sentinel.Export.psm1` (new), `src/Sentinel.Html.psm1` (new),
`Sentinel-Migration-Assistant.ps1`, `tests/Sentinel.Export.Tests.ps1` (new),
`tests/Sentinel.Html.Tests.ps1` (new)

**Problem:** The tool emitted only a flat Markdown report and a JSONL log into
`output/`, with successive runs piling up in the same directory. Reviewing a
migration meant reading a wall of Markdown, and there was no machine-readable
inventory or raw snapshot to diff against.

**Change:** Each run now writes a self-contained, timestamped run folder:

```
output/migration-<source-ws>-to-<target-ws>-<yyyyMMdd-HHmmss>/
├── Migration-Summary.html   ← KPI cards, action charts, searchable drill-down tables
├── Migration-Results.xlsx   ← 10-sheet inventory workbook (CSV fallback)
├── migration-report.md      ← unchanged Markdown report
├── migration-log.jsonl      ← unchanged structured log
└── raw/*.json + raw/_Full.json
```

The Markdown report and JSONL log are unchanged in content; they simply moved
inside the run folder and dropped their now-redundant timestamp suffixes.

Notable implementation details:
- `New-MigrationSheets` builds one ordered sheet set that feeds **both** the Excel
  workbook and the HTML drill-down, so the two artifacts cannot drift apart.
- The HTML is fully self-contained — no CDN or external stylesheet references — so
  it opens correctly in air-gapped and restricted environments.
- `ConvertTo-RuleResultRows` joins results to source rules by **DisplayName**, not
  by id, because `RuleId` in a result is a derived migration GUID from
  `Get-RuleMigrationId` rather than the source rule's `name`.
- `ImportExcel` is auto-installed to the current user's scope; if that fails the
  workbook degrades to one CSV per sheet under `csv/` instead of failing the run.
- `ConvertTo-HtmlEncoded` uses `[System.Net.WebUtility]::HtmlEncode` rather than
  `System.Web.HttpUtility`, avoiding an assembly load that is unreliable on PS 7.

**New parameter:** `-NoDetailTables` produces a slim KPI/chart-only HTML summary
without the embedded tables, for very large workspaces.

**Fix (found by the new tests):** `Get-SafeSheetName` returned an empty string for
a whitespace-only name, which Excel rejects as a worksheet name. It now trims first
and falls back to `Sheet`.

**Tests:** 66 new Pester tests covering the flatteners, Excel name sanitisation,
the raw JSON envelope, the CSV fallback path, KPI derivation, and HTML structure.
Full suite: 102 passing.

---

## Session: 2026-05-22

All changes made during an iterative debugging session to get the migration tool
running successfully against a real source/target workspace pair.

**Source:** `<source-workspace>` (rg: `<resource-group>`)
**Target:** `<target-workspace>` (rg: `<resource-group>`)
**Subscription:** `<subscription-id>`

---

### 1. Fix: SecureString token — 401 Unauthorized on all API calls

**File:** `src/Sentinel.Api.psm1` — `Get-SentinelAccessToken`
**Problem:** Az.Accounts ≥ 2.13 (installed: 5.3.2) changed `Get-AzAccessToken`
to return `.Token` as a `SecureString` instead of a plain string. The
Authorization header was literally `"Bearer System.Security.SecureString"`,
causing every API call to return 401.
**Fix:** Detect `SecureString` and convert with `ConvertFrom-SecureString -AsPlainText`:

```powershell
$tokenObj = Get-AzAccessToken -ResourceUrl $resourceUrl -ErrorAction Stop
if ($tokenObj.Token -is [securestring]) {
    return $tokenObj.Token | ConvertFrom-SecureString -AsPlainText
}
return $tokenObj.Token
```

---

### 2. Fix: Workbook `sourceId` — all 16 workbooks failed with 400

**File:** `src/Sentinel.Workbooks.psm1` — `Import-Workbook`
**Problem:** `Export-WorkbookDefinition` strips `sourceId` as a read-only
property. `Import-Workbook` then only set it back *conditionally*
(`if ($definition.properties.PSObject.Properties['sourceId'])`), which was
always false because the property had already been removed. The PUT body had
no `sourceId` — a required field — so all workbook creates returned 400.
**Fix:** Unconditionally add `sourceId` pointing to the target workspace:

```powershell
if ($definition.properties.PSObject.Properties['sourceId']) {
    $definition.properties.sourceId = $TargetWorkspaceResourceId
}
else {
    $definition.properties | Add-Member -NotePropertyName 'sourceId' `
        -NotePropertyValue $TargetWorkspaceResourceId
}
```

---

### 3. Fix: Workbook `serializedData` — 400 "serializedData field is missing"

**File:** `src/Sentinel.Api.psm1` — `Get-WorkbooksUri`
**Problem:** The source workbook GET did not include `canFetchContent=true`.
Without it, the Microsoft.Insights API returns workbook metadata but omits the
`serializedData` property (the actual workbook JSON content). The PUT to the
target then failed because the body had null content.
**Fix:** Added `canFetchContent=true` to the workbooks list URI:

```
.../Microsoft.Insights/workbooks?category=sentinel&canFetchContent=true&api-version=2022-04-01
```

---

### 4. Fix: Fusion rule export — 400 "Read-only property 'displayName'"

**File:** `src/Sentinel.Rules.psm1` — `Export-RuleDefinition`
**Problem:** Fusion rules (`kind: Fusion`) treat `displayName`, `description`,
`severity`, `tactics`, and `techniques` as read-only properties derived from
the template. Including them in the PUT body caused a 400.
**Fix:** Strip additional read-only properties when `$kind -eq 'Fusion'`:

```powershell
if ($kind -eq 'Fusion') {
    $readOnlyProps += @('displayName', 'description', 'severity', 'tactics', 'techniques')
}
```

> **Note:** The Fusion rule "Advanced Multistage Attack Detection" will still
> fail if it's already installed in the target workspace (error: "already
> installed ... cannot be installed more than once"). This is expected — Fusion
> rules are singleton per workspace.

---

### 5. Feature: Auto-retry missing-table rules as disabled

**File:** `src/Sentinel.Rules.psm1` — `Import-AnalyticsRule`
**Problem:** Rules whose KQL queries reference tables not present in the target
workspace (e.g., missing data connectors) fail with 400 "One of the tables does
not exist". Sentinel validates the query on PUT and rejects it.
**Fix:** When the error matches `'One of the tables does not exist'`, the tool
automatically retries the PUT with `enabled = $false`. Disabled rules skip
query validation, so they get created successfully. The result is reported as
`CreatedDisabled` with a note to enable after connecting the data source.

```powershell
if ($errMsg -match 'One of the tables does not exist') {
    $body.properties.enabled = $false
    # retry PUT ...
    # return Action = 'CreatedDisabled'
}
```

---

### 6. Feature: Enhanced error diagnostics

**File:** `src/Sentinel.Api.psm1` — `Invoke-SentinelApi`
**Problem:** 400 errors only showed "Bad Request" with no detail, making
debugging impossible.
**Fix:** For non-404 errors, the ARM response body (`$_.ErrorDetails.Message`)
is appended to the exception message (truncated at 500 chars). 404s are
preserved as-is because callers (`Import-AnalyticsRule`, `Import-Workbook`)
catch them for existence checks by inspecting `$_.Exception.Response.StatusCode`.

> **Iteration note:** The first attempt used `GetResponseStream()` which doesn't
> exist on PowerShell 7's `HttpResponseMessage`. The second attempt enhanced all
> errors including 404s, which broke the existence-check pattern. The final
> version correctly uses `$_.ErrorDetails.Message` and skips 404s.

---

### 7. Feature: Report section for disabled rules

**File:** `src/Sentinel.Report.psm1` — `New-MigrationReport`
**File:** `src/Sentinel.Rules.psm1` — `Import-AnalyticsRules` (console output)
**What:** Added a "Rules Created as Disabled" section to the markdown report
listing rules that were created disabled due to missing tables, with guidance
to enable them after connecting data sources. Console output shows these in
yellow with a note.

---

## Known Remaining Limitations

| Issue | Affected Rules | Root Cause | Workaround |
|---|---|---|---|
| Fusion already installed | Advanced Multistage Attack Detection | Fusion rules are singleton per workspace | Skip or delete existing first |
| EntityMappings > 5 | Execution of software vulnerable to webp buffer overflow | Source rule has 6 mappings, API max is 5 | Manually reduce mappings in source |
| Missing tables | Local Admin Group Changes, Possible Phishing with CSL, Auth Methods Changed | Target lacks data connectors | Now auto-created as disabled; enable after connecting data sources |

---

## Files Modified (Summary)

| File | Changes |
|---|---|
| `src/Sentinel.Api.psm1` | SecureString token fix, error diagnostics, `canFetchContent=true` |
| `src/Sentinel.Rules.psm1` | Fusion read-only props, missing-table retry as disabled, console colors |
| `src/Sentinel.Workbooks.psm1` | Unconditional `sourceId` assignment |
| `src/Sentinel.Report.psm1` | "Rules Created as Disabled" report section |
