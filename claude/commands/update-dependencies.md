# /update-dependencies — Safe dependency update scan

Scan the current repo for outdated packages, pick only the bumps that can be
shown to be safe, verify them against the project's own checks, and — only
when everything passes — open a PR and file a Jira ticket. When nothing is
provably safe, produce a findings report and change **nothing** in the repo.
Majors are never applied, but they don't vanish into the report either: every
run files (deduplicated) backlog tickets for them — see step 8.

## Usage

```bash
/update-dependencies                # interactive: ask before push/PR/ticket
/update-dependencies --auto         # unattended (CCVerify): pre-approved
/update-dependencies --max 3        # cap bumps per run (default 5)
```

**`--auto`:** the caller has pre-approved pushing a `deps/*` branch, opening
the PR, and creating the Jira tickets (both the updates ticket and the major
backlog tickets of step 8), provided every safety rule below holds.
No approval gates — but every guard still applies.

## Hard safety rules (both modes)

1. **Never modify the user's working copy.** All work happens in a throwaway
   `git worktree` created from `origin/<base>`; remove it at the end, always.
2. **Patch and minor bumps only.** Majors are never applied — they get a
   backlog ticket (step 8) and a "needs human review" row in the report.
   Runtime bumps (Node engine, TFM, SDK) are never applied either.
3. **No PR without green verification.** Install + the repo's own format/lint/
   test/build scripts must all pass with the bumps applied.
4. **Push only to a fresh `deps/*` branch.** Never to existing branches, never
   force, never to `dependabot/*`.
5. **Never merge, approve, or enable auto-merge** on the PR this creates.
6. **One open updates-PR at a time.** If an open PR from a `deps/*` branch
   already exists, report it and stop — don't stack PRs.

## Procedure

### 1. Preflight

- Resolve `owner/repo` (`gh repo view --json nameWithOwner`) and the base
  branch: `develop` if it exists on the remote, else the default branch.
- Duplicate guard: `gh pr list --state open --json headRefName,title,url` —
  if any head ref starts with `deps/`, stop and report that PR (rule 6).
- Also list open Dependabot PRs (`gh pr list --author app/dependabot`) and
  record which packages they already cover — skip those packages entirely
  (Dependabot owns them; reviewing its PRs is a separate flow).

### 2. Detect the toolchain

Same table as `/review-dependabot-pr`: `yarn.lock` → yarn, `pnpm-lock.yaml` →
pnpm, `package-lock.json` → npm, `*.sln`/`*.csproj` → dotnet. Never mix
package managers. Read the repo's `CLAUDE.md` for required env overrides
(e.g. `SKIP_ENV_VALIDATION=true`) and honor them.

### 3. Create the isolated worktree

```bash
git fetch origin <base>
git worktree add /tmp/depupdate-<repo>-<date> origin/<base>
cd /tmp/depupdate-<repo>-<date>
```

### 4. Enumerate candidates

- Outdated: `yarn outdated` / `npm outdated` / `pnpm outdated` /
  `dotnet list package --outdated`.
- Advisories: `yarn audit` / `npm audit` / `dotnet list package --vulnerable`
  — packages with a fix available get priority.
- Filter to **direct dependencies with a patch or minor bump available**
  (semver; for ranges already satisfying the new version, refresh the
  lockfile entry). Order: security fixes first, then patches, then minors.
- Cap at `--max` (default 5) — small PRs get reviewed; omnibus PRs rot.

For each candidate, do a quick changelog sanity check (release notes between
old and new — WebFetch when needed). Drop any candidate whose changelog shows
behavior changes, deprecations we rely on, or peer-dependency shifts — a
"minor" with breaking notes is not safe. Record why anything was dropped.

If no candidates survive: **no branch, no PR, no updates ticket** — but do
not stop dead: still run step 8 (major backlog tickets) and step 9 (cleanup +
report with the majors/dropped list).

### 5. Apply and verify

- Apply the bumps with the package manager's own upgrade command (so the
  lockfile stays consistent) — never hand-edit lockfiles.
- Run the full verification suite: install (frozen where applicable after the
  upgrade), format check, lint, tests, build — using the repo's own scripts.
- On failure: bisect by removing the most suspicious bump(s) and re-running,
  until green or no candidates remain. Everything dropped goes in the report
  with the failing output. No candidates left → skip the PR and the updates
  ticket (rule 3), but still run steps 8 and 9.

### 6. Open the PR (only with everything green)

```bash
git checkout -b deps/safe-updates-<YYYY-MM-DD>
git add <manifest + lockfile>
git commit -m "chore(deps): safe dependency updates <YYYY-MM-DD>"
git push origin deps/safe-updates-<YYYY-MM-DD>
gh pr create --base <base> --title "chore(deps): safe dependency updates (<YYYY-MM-DD>)" --body-file <body>
```

PR body: the report template below (bumps table with changelog links,
verification results, what was skipped and why, risk note per bump).
Interactive mode: show the plan and ask once before push/PR/tickets — one
approval covering the PR, the updates ticket (including its Dev Complete
transition), and step 8's major tickets.

### 7. Create the updates Jira ticket

Known projects:

| Repo | Jira project | Cloud ID | Epic (parent) |
|---|---|---|---|
| `teztechnology/text2park.web` | `PRK` | `108a72cf-a3ed-4303-95da-07d7fa0fa6ee` | `PRK-209` |
| `teztechnology/text2park.backend` | `PRK` | `108a72cf-a3ed-4303-95da-07d7fa0fa6ee` | `PRK-209` |

Create via `mcp__atlassian__createJiraIssue` (Task type, parented under the
epic from the table when one is set): summary
`Dependency updates <repo> <YYYY-MM-DD>`, description = the bumps table plus
a `**PR:** <url>` link. Then edit the PR body to reference the ticket key.
If the repo isn't in the table or the Atlassian tools aren't available in
this repo, skip the ticket and say so in the final report.

Then move the fresh ticket to **Dev Complete** — the PR carrying the work
already exists, so the ticket is born with its development done. Look up the
workflow's transitions (`getTransitionsForJiraIssue`) and pick the one whose
target status matches "Dev Complete" (case-insensitive, ignoring
`-`/`_`/spaces); apply it with `transitionJiraIssue`. If the workflow has no
such transition, leave the status alone and note that in the report — never
guess a different status. Step 8's backlog tickets are **never**
transitioned (no PR exists for them).

### 8. File backlog tickets for majors (no PR — tickets only)

Majors must not die in a report nobody rereads. For every package skipped as
"major" (including runtime-coupled majors like `Microsoft.Extensions.* 8→10`,
and formally-minor jumps you judged PR-worthy-by-a-human, e.g. a package
family that must move together), file a Jira ticket in the same project as
step 7 — **without any branch or PR**. This step runs on every scan, even
when steps 5–7 produced nothing.

- **Group, don't spam.** Packages that must move together (the
  `Functions.Worker` family, `Microsoft.Extensions.*`, a lib + its
  types/plugin packages) share one ticket. One ticket ≈ one human PR.
- **Dedupe before creating.** Label every ticket `dep-major` and search first
  (`searchJiraIssuesUsingJql`):
  `project = <KEY> AND labels = dep-major AND statusCategory != Done AND summary ~ "<package>"`.
  An open ticket for the package/group → don't create a duplicate; if the
  available version moved on since (e.g. 52.x → 53.x), add a short comment
  with the new version instead — and if the ticket carries the
  `dep-analyzed` label (a `/analyze-dep-tickets` deep dive already ran),
  remove that label via `editJiraIssue` so the ticket gets re-analyzed
  against the new version. Closed-as-done ticket + a new major out →
  a new ticket is correct.
- **Ticket shape** (Task type, parented under the step 7 epic when one is
  set; follow the repo's Jira title conventions from
  its `CLAUDE.md` when defined, else this default): summary
  `Dependency major: <package or group> <current> → <latest> (<repo>)`;
  description = current vs latest versions, links to release notes /
  migration guide (WebFetch to find them), why the automation won't touch it
  (major / runtime-coupled / family jump), known breaking changes spotted in
  the changelog, and a suggested verification approach. No PR link — there is
  no PR.
- If the repo has no Jira mapping (step 7 table) or Atlassian tools are
  unavailable, skip and say so in the report — same rule as step 7.

These tickets don't just sit in the backlog: `/analyze-dep-tickets` (run on
its own schedule by CCVerify) picks up every open `dep-major` ticket without
a `dep-analyzed` label, deep-dives the major against the codebase, posts the
analysis as a ticket comment, and opens a PR when the upgrade proves safe.

### 9. Cleanup and report

Remove the worktree (`git worktree remove … --force`, and delete the local
`deps/*` branch ref if the worktree held it). Finish with the report — it is
the run's primary output even when no PR was created.

## Report template

```md
## Dependency update scan — <repo> <date>

### Applied (PR: <url or "none">, Jira: <key or "skipped">)
| Package | Old | New | Type | Why safe |
|---|---|---|---|---|

### Verification
| Check | Result |
|---|---|

### Skipped — needs human review
| Package | Old | Latest | Reason (major / breaking notes / failed checks / covered by Dependabot PR #N) | Ticket (key, "existing PRK-N", or "—" for cap-dropped) |
|---|---|---|---|---|

### Security advisories
<open advisories and whether this PR resolves them>
```
