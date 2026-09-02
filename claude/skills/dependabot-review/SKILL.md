---
name: dependabot-review
description: End-to-end review of a Dependabot PR in the text2park.web project. Analyzes the PR, auto-detects mode (workflow-only/Dockerfile/package update), runs the appropriate verification (jest/lint/build for package updates, deep analysis for Dockerfile/runtime), rebases against develop if the branch is behind (with approval), drafts a risk-assessed summary, posts comments to the GitHub PR and the auto-discovered Jira ticket — always after the user approves — and approves the PR when risk is LOW and verification is fully green. Use when the user invokes `/review-dependabot-pr` or asks to "review dependabot PR <number>".
---

# Dependabot PR Review (text2park.web)

End-to-end review workflow for Dependabot PRs in `teztechnology/text2park.web`. Project-specific constants are baked in.

## Constants (text2park.web)

- **Repository:** `teztechnology/text2park.web`
- **Base branch:** `develop`
- **Jira cloud ID:** `108a72cf-a3ed-4303-95da-07d7fa0fa6ee` (tezdev.atlassian.net)
- **Jira project key:** `PRK`
- **Jira-link bot username:** `tez-depbot` (posts `📋 Jira Issue Created: [PRK-xxx]` comment on every Dependabot PR)
- **Package manager:** `yarn` (1.22.x — never npm)
- **Build env override:** `SKIP_ENV_VALIDATION=true` (required for build outside a real env)

## Inputs

The slash command supplies one positional PR ID plus optional flags:

- `<pr-id>` (required) — numeric, e.g. `1738`
- `--coderabbit` (optional) — also post `@coderabbitai review` on the PR after the analysis comment lands

## Hard Rules

1. **Never post a comment without explicit user approval first.** Always draft the summary, present it, ask the user to confirm, then post.
2. **Approve the PR only when everything looks OK** — risk assessment **LOW** and verification fully green — and only as part of the step 7 approval gate. MEDIUM/HIGH risk never approves. Never merge, never add labels or other status changes.
3. **Never change the Jira ticket's status.** Comment only.
4. **Never force-push a rebase unless the user explicitly approves.** Ask each time.
5. **Never run npm.** This project uses yarn 1.x. Pre-commit hooks expect yarn-resolved state.
6. **If you make code fixes (e.g. prettier reformat), ask for approval before committing and again before pushing.**
7. **Never check out branches in the main working copy.** Other agents (or the user) may be working in this checkout concurrently. All checkout, rebase, and verification happens in a throwaway `git worktree` under `/tmp` (see Step 4); remove it at the end, always.

## Procedure

### Step 1 — Fetch PR + diff

```bash
gh pr view <pr-id> --json title,body,state,baseRefName,headRefName,author,url,additions,deletions,changedFiles,comments,commits,mergeable
gh pr diff <pr-id>
```

Record: `state` (open/merged/closed), `headRefName`, `mergeable`, the file paths in the diff.

If `state` is not `OPEN`, stop and tell the user — this skill only reviews open PRs.

### Step 2 — Detect mode from changed file paths

Apply these rules in order (first match wins):

| Mode | Trigger | Verification |
|---|---|---|
| `ANALYZE_ONLY` | All changes under `.github/workflows/**` | Read the changed workflow files, read release notes (WebFetch when useful), identify breaking changes vs. our usage. No local checkout. |
| `DOCKERFILE` | `Dockerfile` is in the diff | Read entire Dockerfile, read `package.json` (especially `engines`, native deps like `sharp`, `@react-pdf/renderer`), read `azure-pipelines.yml`. Identify Node/runtime version implications. Try `yarn install --frozen-lockfile` locally if it gives signal. A full Docker build is optional — only do it if you have docker available and the user is OK to wait. |
| `FULL_CHECKS` | `package.json` and/or `yarn.lock` in the diff | Check the branch out into an isolated worktree (Step 4), run install/format-check/lint/jest/build there. Apply auto-fixes (prettier) if the diff is purely cosmetic. |
| `ANALYZE_ONLY` (fallback) | Anything else | Read the diff and reason about it; no checkout. |

If the PR mixes categories (e.g. workflow + Dockerfile), pick the deepest applicable mode (`FULL_CHECKS` > `DOCKERFILE` > `ANALYZE_ONLY`).

### Step 3 — Auto-discover the Jira ticket

Scan the PR comments for a post from `tez-depbot`. It looks like:

> 📋 **Jira Issue Created:** [PRK-NNN](https://tezdev.atlassian.net/browse/PRK-NNN)

Extract the `PRK-NNN` key. If no such comment exists, ask the user for the ticket key (don't guess).

### Step 4 — Create the isolated worktree; detect drift; offer rebase if behind develop

Only relevant for `FULL_CHECKS` and `DOCKERFILE` modes (skip for `ANALYZE_ONLY` — no local checkout).

**Never `git checkout` / `gh pr checkout` in the main working copy** — check the PR branch out into a throwaway worktree instead and run everything there:

```bash
gh pr view <pr-id> --json headRefOid -q .headRefOid
git fetch origin develop <headRefName> --quiet
git worktree add /tmp/depreview-<repo-name>-<pr-id> -B <headRefName> origin/<headRefName>
cd /tmp/depreview-<repo-name>-<pr-id>   # all later git/yarn commands run here
# Count commits develop is ahead of the PR branch:
git rev-list --count HEAD..origin/develop
```

(`-B` needs the branch to not be checked out anywhere else; if that fails, say so and stop rather than touching the main checkout.)

If the count is `0`, branch is up to date — skip rebase.

If the count is `> 0`, **ask the user**:
> "PR branch is behind `develop` by N commits. Want me to rebase locally before running checks?"

If yes (inside the worktree):
```bash
git rebase origin/develop
```

Handle outcomes:
- **Rebase succeeds, working tree changed from the original commit** → continue with verification; later, ask the user whether to force-push the rebased branch.
- **Rebase succeeds, working tree identical to the original commit** (no meaningful change — verify with `git diff <pr-headRefOid>`) → discard the rebase, do **not** force-push. The drift was no-op for this branch.
- **Rebase has conflicts** → abort (`git rebase --abort`), tell the user, ask whether to continue with the un-rebased branch or stop.

**Never force-push without explicit approval. Never push to a dependabot/* branch silently** — the user is aware that pushing detaches the branch from Dependabot's auto-management.

### Step 5 — Run mode-specific verification

#### Mode: `FULL_CHECKS`

Run inside the worktree from Step 4, in this order. Capture pass/fail for each.

```bash
yarn install --frozen-lockfile
yarn format:check          # prettier --check src/
yarn lint                  # next lint
yarn jest --colors=false
SKIP_ENV_VALIDATION=true yarn build
```

- **`format:check` fails** → preview the diff, classify (cosmetic-only vs. functional). If cosmetic-only (whitespace/line breaks/class sort), it's safe to auto-fix:
  1. Ask the user: "Apply `yarn format` and commit the reformat?"
  2. On yes: `yarn format` → `git add` the changed files → commit with message `style: reformat with prettier <version>` → ask before pushing.
- **`lint` warnings only (no errors)** → note them as pre-existing if they don't reference newly-changed files; don't block.
- **`lint` errors / `jest` failures / build failures** → STOP. Surface to the user with the failing output. Don't post any comments.

#### Mode: `DOCKERFILE`

- Read `Dockerfile` end-to-end.
- Read `package.json` for `engines.node`, native deps (`sharp`, `@react-pdf/renderer`, `@azure/cosmos`, etc.), and `packageManager`.
- Read `azure-pipelines.yml` for additional Node pins.
- For Node version bumps specifically, identify:
  - Whether the old version is EOL.
  - Whether the new version is LTS, Current, or pre-release.
  - Compatibility with native modules (sharp's N-API bindings, etc.).
  - Whether `Next.js` major has documented support for the new Node major.
- Optionally run `yarn install --frozen-lockfile` (in the Step 4 worktree, never the main checkout) to confirm dep resolution doesn't change.

#### Mode: `ANALYZE_ONLY`

- Read the changed workflow file(s) end-to-end (not just the diff).
- Read release notes from the PR body. Use `WebFetch` against the upstream release page if the body doesn't enumerate breaking changes.
- For each breaking change documented in the upstream changelog, check whether our usage of the action triggers it (e.g. does any of our scripts use `require('@actions/github')`? does anything depend on git credentials being in `.git/config`?).

### Step 6 — Draft the review summary

Use the template in **Templates → Review Comment** below. Tailor the sections to the mode:

- For all modes: package(s) bumped, breaking changes from changelog, impact-on-our-codebase analysis, risk assessment (`LOW` / `MEDIUM` / `HIGH`), recommendation.
- For `FULL_CHECKS`: include a results table of install/format/lint/jest/build outcomes. If you applied fixes, list them with the commit SHA.
- For `DOCKERFILE`: include the runtime-stack table (Node version, native deps, Next.js version, LTS status).

### Step 7 — Approval gate

Present the drafted summary to the user **in the chat, not in a comment yet**. Ask:

> "Post this to GitHub PR #<id> and Jira <PRK-key>?"

When the approval criteria hold (risk **LOW**, all verification checks green), extend the question:

> "…and approve the PR?"

Wait for explicit yes. On no, ask what to revise.

### Step 8 — Post comments

Only after approval. Use these tool calls:

**GitHub PR:**
```bash
gh pr comment <pr-id> --body "$(cat <<'EOF'
<the summary, omitting any "PR: <url>" line — it's on the PR itself>
EOF
)"
```

**Jira:** `mcp__atlassian__addCommentToJiraIssue` with:
- `cloudId`: `108a72cf-a3ed-4303-95da-07d7fa0fa6ee`
- `issueIdOrKey`: the discovered `PRK-NNN`
- `contentFormat`: `markdown`
- `commentBody`: include a `**PR:** <github url>` line at top, otherwise same content

Capture both response URLs/IDs and report them back to the user.

**Approval (when criteria met and the user said yes in step 7):** risk **LOW**, all verification green, and no existing `APPROVED` review by the current `gh` user (`gh pr view <pr-id> --json reviews`):

```bash
gh pr review <pr-id> --approve --body "Automated dependency review: LOW risk, verification green. See the analysis comment for details."
```

MEDIUM/HIGH risk never approves — the analysis comment is the only output.

### Step 9 — Optional: trigger CodeRabbit review

If the user passed `--coderabbit`, after the analysis comments land, post one more comment to the GitHub PR:

```bash
gh pr comment <pr-id> --body "@coderabbitai review"
```

Confirm the trigger comment URL back to the user.

### Step 10 — Cleanup

If a worktree was created in Step 4, remove it now (always — even after a failed run):

```bash
git -C <main-checkout> worktree remove /tmp/depreview-<repo-name>-<pr-id> --force
git -C <main-checkout> branch -D <headRefName>   # drop the local ref the worktree held
```

The main working copy was never touched, so there is nothing to switch back.

## Risk Rubric

| Level | Use when |
|---|---|
| **LOW** | Dev-only deps, patch/minor versions of well-known packages, workflow actions where our usage doesn't trigger any breaking changes, no test/build regressions. |
| **MEDIUM** | Major version of a runtime/build dep, Node version bump, action bump where we use features that change behavior, any test or build instability we couldn't fully resolve. |
| **HIGH** | Major version of a production runtime dep with known breaking API surface our code touches, Node version that's pre-release or EOL, anything that produces failing tests we couldn't fix. |

Recommendation pairs with the level: LOW → "Safe to merge." MEDIUM → "Safe to merge after QA smoke test in dev/qa." HIGH → "Do not merge until <specific blockers> are resolved."

## Templates

### Review Comment (GitHub + Jira shared body)

```md
## PR Analysis — <one-line summary>

### Scope
<files changed, +X/-Y, brief description>

### Breaking changes between <old> and <new>
<bullets from upstream changelog>

### Impact on this codebase
<concrete analysis: do we use the affected APIs? does our config trip the breaking change?>

### Verification results (FULL_CHECKS only)
| Check | Result |
|---|---|
| `yarn install --frozen-lockfile` | ✅/❌ |
| `yarn format:check` | ✅/⚠️ + fix |
| `yarn lint` | ✅ (only pre-existing warnings) |
| `yarn jest` | ✅ N/N tests pass |
| `yarn build` | ✅ |

### Fixes applied (if any)
<files modified, why, commit SHA>

### Risk assessment: <LOW/MEDIUM/HIGH>
<bullets justifying the level>

### Recommendation
<one of: Safe to merge / Safe to merge after QA / Do not merge until ...>
```

For the Jira body specifically, prepend a `**PR:** https://github.com/teztechnology/text2park.web/pull/<id>` line so the ticket has a back-link.

### Merge-confirmation comment (not invoked by this skill, but documented for reference)

Not handled here — out of scope per user decision.

## Gotchas

- **`git diff develop` vs `git diff origin/develop`** — local `develop` is often behind origin. Always `git fetch origin develop` before comparing.
- **PR branches behave like normal branches in this repo** — `git fetch origin <headRefName>` brings them in without special flags; check them out only via the Step 4 worktree.
- **Pre-commit hook (Husky)** runs `yarn lint` + format check on commit. If you've already run `yarn format`, the hook should pass; if not, the commit will be blocked.
- **`SKIP_ENV_VALIDATION=true`** is needed for `yarn build` outside an actual deploy env because `env.ts` is strict.
- **`tez-depbot`'s Jira comment can take a few seconds to land** after the PR opens. For very fresh PRs, retry the comments fetch once after ~10s if no `tez-depbot` post is found.
- **The PR body's changelog is often truncated.** For thorough breaking-change analysis, fetch the upstream release page directly with `WebFetch`.
- **Don't trust a Dependabot PR's "compatibility score" badge as the only signal** — it reflects whether other repos' tests passed, not ours.
