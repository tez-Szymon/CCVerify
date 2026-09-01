# /review-dependabot-pr — Dependabot PR Review (multi-stack)

End-to-end review of a Dependabot PR in the current repo: analyze the bump,
verify it against this codebase (running the project's own checks when the
manifest changed), assess risk, and post one review comment to the GitHub PR
and one to its Jira ticket. When everything looks OK — risk **LOW** and
verification green — it also approves the PR (`gh pr review --approve`).
It still never merges, labels, or closes a PR, never transitions a Jira
ticket, and never pushes to a `dependabot/*` branch.

## Usage

```bash
/review-dependabot-pr 1738               # interactive: draft → ask → post
/review-dependabot-pr 1738 --auto        # unattended: verify → post directly
/review-dependabot-pr 1738 --coderabbit  # additionally trigger @coderabbitai review
```

Arguments: first positional token = PR number (required, numeric — if missing
or non-numeric, stop and ask). Flags may appear anywhere.

**`--auto` (unattended mode, used by CCVerify):** the caller has pre-approved
posting. Skip every approval gate: post the drafted comment directly to the
GitHub PR and the discovered Jira ticket. Additionally:

- Append the hidden marker `<!-- auto-dependabot-review -->` at the end of the
  GitHub comment body.
- Before doing anything else, check the PR's existing comments for that marker
  (`gh pr view <n> --json comments`). If present, the PR is already reviewed —
  report that and stop. No duplicate reviews.
- Never rebase and never commit fixes. If the branch is behind the base or
  formatting is off, say so in the review comment instead.
- **Never check out branches in this working copy** — the user may have
  uncommitted work here. All verification happens in a throwaway
  `git worktree` (see FULL_CHECKS).

Without `--auto`, follow the interactive gates in step 7.

## Procedure

### 1. Fetch PR + diff

```bash
gh pr view <n> --json title,body,state,baseRefName,headRefName,author,url,additions,deletions,changedFiles,comments,mergeable
gh pr diff <n>
```

If `state` is not `OPEN`, stop and report — only open PRs are reviewed.
If the author is not Dependabot, say so and ask before continuing (in `--auto`,
stop with a report instead).

### 2. Detect the project's toolchain

| Signal (repo root) | Package manager | Verification commands |
|---|---|---|
| `yarn.lock` | yarn (1.x unless `packageManager` says otherwise) | `yarn install --frozen-lockfile`, then the repo's own scripts: format check, lint, tests, build (read `package.json` scripts — don't guess names) |
| `pnpm-lock.yaml` | pnpm | `pnpm install --frozen-lockfile`, then scripts as above |
| `package-lock.json` | npm | `npm ci`, then scripts as above |
| `*.sln` / `*.csproj` | dotnet | `dotnet restore`, `dotnet build`, `dotnet test` |

Never mix package managers (a `yarn.lock` repo must never see npm). Read the
repo's `CLAUDE.md` for required env overrides (e.g. `SKIP_ENV_VALIDATION=true`
for a Next.js build outside a real env) and honor them.

Base branch: `develop` if it exists on the remote, else the default branch
(`gh repo view --json defaultBranchRef`).

### 3. Detect mode from the changed file paths (first match wins)

| Mode | Trigger | Verification |
|---|---|---|
| `FULL_CHECKS` | Manifest and/or lockfile in the diff (`package.json`, `yarn.lock`, `pnpm-lock.yaml`, `package-lock.json`, `*.csproj`, `packages.lock.json`, `Directory.Packages.props`) | Full local verification in a worktree (below) |
| `DOCKERFILE` | `Dockerfile` in the diff | Read the whole Dockerfile, the manifest (engines, native deps like `sharp`), and CI pipeline files; analyze runtime implications (EOL/LTS status, native-module compatibility). Install-only check optional. |
| `ANALYZE_ONLY` | Only `.github/workflows/**`, or anything else | Read the changed files end-to-end plus upstream release notes (WebFetch when the PR body truncates the changelog); check each documented breaking change against our actual usage. No checkout. |

Mixed PRs take the deepest applicable mode (`FULL_CHECKS` > `DOCKERFILE` > `ANALYZE_ONLY`).

**FULL_CHECKS runs in an isolated worktree, never in the main checkout:**

```bash
git fetch origin <headRefName> <base>
git worktree add /tmp/depreview-<n> origin/<headRefName>
cd /tmp/depreview-<n>   # run all verification here
```

Also record drift: `git rev-list --count origin/<headRefName>..origin/<base>`.
If > 0, note "branch is N commits behind <base>" in the review (interactive
mode may offer a rebase; `--auto` never rebases — recommend commenting
`@dependabot rebase` instead).

When done, always clean up: `git worktree remove /tmp/depreview-<n> --force`.

Verification outcomes:
- All green → proceed to drafting.
- Format-only failures (prettier/whitespace) → classify as cosmetic; in
  interactive mode you may offer to fix (ask before committing and again
  before pushing); in `--auto`, just report it.
- Lint errors / test failures / build failures → still write the review: a
  failing verification **is** a valid review outcome (risk HIGH, "do not
  merge until…"), with the failing output quoted.

### 4. Discover the Jira ticket

Scan the PR comments for a Jira link comment (e.g. from a `*-depbot` bot):
`Jira Issue Created: [KEY-NNN]` — extract `KEY-NNN`. Fallback: any comment or
the PR body containing a `[A-Z][A-Z0-9]+-\d+` key next to an atlassian.net
link. Known projects:

| Repo | Jira project | Cloud ID |
|---|---|---|
| `teztechnology/text2park.web` | `PRK` | `108a72cf-a3ed-4303-95da-07d7fa0fa6ee` |
| `teztechnology/text2park.backend` | `PRK` | `108a72cf-a3ed-4303-95da-07d7fa0fa6ee` |

No ticket found → interactive: ask the user; `--auto`: skip the Jira comment
and note it in the GitHub comment ("no linked Jira ticket found").

### 5. Analyze the bump

- Package(s) and version range (old → new); prod vs dev dependency.
- Breaking changes between the versions from the upstream changelog/release
  notes (WebFetch the release page when the PR body is truncated).
- Impact on **this** codebase: do we call the affected APIs? Does our config
  trip the change? Grep, don't assume.
- Don't trust Dependabot's compatibility score — it reflects other repos'
  tests, not ours.

### 6. Risk assessment

| Level | Use when |
|---|---|
| **LOW** | Dev-only deps, patch/minor of well-known packages, no breaking changes touching our usage, verification green. |
| **MEDIUM** | Major of a runtime/build dep, runtime (Node/.NET) version bump, breaking changes near our usage, or instability not fully resolved. |
| **HIGH** | Major of a production dep with breaking API surface we touch, EOL/pre-release runtime, or failing verification. |

Recommendation pairs with the level: LOW → "Safe to merge." MEDIUM → "Safe to
merge after QA smoke test." HIGH → "Do not merge until <blockers>."

### 7. Draft, gate, post

Draft the review comment from the template below.

- **Interactive:** present the draft in chat and ask "Post this to GitHub PR
  #<n> and Jira <KEY>?" (plus "…and approve the PR?" when the approval
  criteria below are met) — post only after an explicit yes.
- **`--auto`:** post immediately (pre-approved), marker appended.

**GitHub:** `gh pr comment <n> --body-file <draft>`.
**Jira:** `mcp__atlassian__addCommentToJiraIssue` (cloudId from the table,
`contentFormat: markdown`), body prefixed with `**PR:** <github url>`. If the
Atlassian MCP tools aren't available in this repo, skip Jira and say so.

If `--coderabbit` was passed: afterwards `gh pr comment <n> --body "@coderabbitai review"`.

### 8. Approve when everything looks OK

Approve **only** when ALL of these hold:

- Risk assessment is **LOW** (recommendation "Safe to merge").
- FULL_CHECKS ran fully green, or the mode was `ANALYZE_ONLY`/`DOCKERFILE`
  with no concerns found.
- We haven't already approved: check `gh pr view <n> --json reviews` for an
  existing `APPROVED` review by the current `gh` user — if present, skip.

Then:

```bash
gh pr review <n> --approve --body "Automated dependency review: LOW risk, verification green. See the analysis comment for details."
```

In interactive mode the approval is covered by the same yes in step 7's gate;
in `--auto` it happens directly. **MEDIUM or HIGH risk never approves** — the
analysis comment is the only output, and the human decides.

Finish by reporting exactly what was posted (comment URLs) and whether the PR
was approved — or, interactive only, ask whether to switch anything back.
Never leave the worktree behind.

## Review comment template

```md
## PR Analysis — <one-line summary>

### Scope
<files changed, +X/−Y, prod/dev dep, old → new>

### Breaking changes between <old> and <new>
<bullets from the upstream changelog; "none documented" if so>

### Impact on this codebase
<concrete: which of our files/APIs are affected, or why none are>

### Verification results (FULL_CHECKS only)
| Check | Result |
|---|---|
| install (frozen lockfile) | ✅/❌ |
| format check | ✅/⚠️ |
| lint | ✅/❌ |
| tests | ✅ N/N |
| build | ✅/❌ |

### Branch state
<up to date with <base> / N commits behind — recommend `@dependabot rebase`>

### Risk assessment: <LOW/MEDIUM/HIGH>
<bullets justifying the level>

### Recommendation
<Safe to merge / Safe to merge after QA / Do not merge until …>
```
