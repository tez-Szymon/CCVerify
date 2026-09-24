# /review-pr — Pull Request Review (global dispatcher)

Universal entry point for PR reviews, installed at user level. Detects the current project's technology stack and dispatches the review to the dedicated reviewer agent for that stack. The reviewer returns a merge verdict — **only Critical findings block** — plus a full report grouped by severity (Critical / High / Major / Minor).

## Usage

```bash
/review-pr 351                 # review GitHub PR #351
/review-pr <PR URL>            # review a PR by URL
/review-pr                     # review the current branch against the base branch
/review-pr 351 focus on auth   # extra context is passed through to the reviewer
/review-pr 351 --publish       # additionally publish the review to GitHub
```

`--publish` posts the outcome to the GitHub PR: an approve / request-changes review with Critical findings as inline code comments, plus one grouped comment per remaining severity level. Without the flag, nothing is ever posted.

## Instructions

### 1. Resolve the review target
- **A number or GitHub PR URL** → the target is that PR (`gh pr view` / `gh pr diff`).
- **No argument** → the target is the current branch diffed against the base branch.
- Base branch: prefer `develop` if it exists on the remote, otherwise the repo's default branch (`gh repo view --json defaultBranchRef` or `git symbolic-ref refs/remotes/origin/HEAD`).
- If the current branch **is** the base branch and no PR was given, ask the user what to review instead of guessing.
- Any extra words in the argument are reviewer context (e.g. "focus on the payment flow") — pass them through.

### 2. Prefer a project-specific reviewer
If the project defines its own reviewer agent (check `.claude/agents/` in the repo for a `pr-reviewer*.md`), dispatch to **that** agent — a repo-tailored reviewer always beats a stack-generic one. Otherwise continue with stack detection.

### 3. Detect the stack and pick the dedicated agent
Decide by the **changed files in the diff**, not just by what exists in the repo (monorepos may contain several stacks):

| Signal | Agent (`subagent_type`) |
|---|---|
| Diff touches `*.cs` / `*.csproj` / `*.sln`, or the project root has a `.sln`/`.csproj` | `pr-reviewer-dotnet` |
| `next` in `package.json` dependencies or a `next.config.*` exists, and the diff touches JS/TS/JSX/TSX | `pr-reviewer-nextjs` |
| Anything else (Python, Go, Rust, plain Node, mixed, unknown) | `pr-reviewer-generic` |

If the diff genuinely spans **multiple stacks** (e.g. a monorepo PR touching both a .NET API and a Next.js app), launch the matching dedicated agents **in parallel**, each scoped to its portion of the diff, then combine: the overall verdict is ⛔ MERGE BLOCKED if **any** reviewer blocks; present the reports one after another.

### 4. Launch and relay
Launch the chosen agent via the Agent tool, **synchronously** (`run_in_background: false`) — the verdict is the answer to this command. Give it everything it needs in the prompt: the resolved target (PR number/URL or branch + base branch), the repo root, and any user-provided focus context.

When the agent returns, relay its report **verbatim in structure**: verdict first, then findings by severity, then analysis notes. Do not summarize away findings and do not soften the verdict. The review is read-only — apply no fixes unless the user asks afterwards.

### 5. `--publish` — post the review to GitHub (only when the flag was given)

Strip `--publish` from the arguments before target resolution. Publishing runs **after** the review completes and **in addition to** relaying the full report in chat. The flag is the user's explicit consent to post; never publish without it.

**Preconditions**
- A PR must exist: the given PR number/URL, or the PR associated with the current branch (`gh pr view --json number`). No PR → relay the report and state that publishing was skipped.
- `gh` must be authenticated with write access to the repo. Resolve `OWNER/REPO` via `gh repo view --json nameWithOwner`.

**A. Verdict review (approve / request changes)**

- **⛔ MERGE BLOCKED** → submit a single `REQUEST_CHANGES` review with every Critical finding as an **inline comment anchored to the offending code**. `gh pr review` cannot do inline comments, so use the API:
  ```bash
  gh api repos/OWNER/REPO/pulls/N/reviews --method POST --input review.json
  ```
  `review.json` (write it to the scratchpad, not the repo):
  ```json
  {
    "event": "REQUEST_CHANGES",
    "body": "## ⛔ MERGE BLOCKED\n\n<verdict summary: blocked-by list, 2–4 sentence summary, quality-gate results>",
    "comments": [
      { "path": "src/Payments/CaptureService.cs", "line": 123, "side": "RIGHT",
        "body": "🔴 **Critical — <title>**\n\n**Problem:** …\n**Failure scenario:** …\n**Fix:** …" }
    ]
  }
  ```
  Inline comments only attach to lines **present in the diff** — verify each Critical finding's `path:line` against `gh pr diff` first. For a finding on the deleted side use `"side": "LEFT"`; for one that cannot be anchored to any diff line, move its full text into the review `body` instead. Multi-line findings may use `start_line` + `line`.

- **✅ MERGE ALLOWED** → `gh pr review N --approve --body "<verdict summary>"`.

- **Fallback**: GitHub forbids reviewing your own PR with approve/request-changes. If the API returns that error, resubmit the same content as an `event: "COMMENT"` review and say so in chat.

**B. Grouped comments for the remaining severities**

For each **non-empty** severity below Critical, post **one** separate comment — one for High, one for Major, one for Minor:
```bash
gh pr comment N --body-file high.md      # 🟠 High — N findings
gh pr comment N --body-file major.md     # 🟡 Major — N findings
gh pr comment N --body-file minor.md     # ⚪ Minor — N findings
```
Each comment must scan in seconds: a summary table first, the detail collapsed below it. Layout:

```markdown
## 🟠 High — 2 findings

| # | Where | Issue |
|---|-------|-------|
| 1 | [`CaptureService.cs:42`](https://github.com/OWNER/REPO/blob/HEAD_SHA/src/Payments/CaptureService.cs#L42) | Missing null check on refund result |
| 2 | [`CacheRefresher.cs:17`](https://github.com/OWNER/REPO/blob/HEAD_SHA/src/Cache/CacheRefresher.cs#L17) | Race between refresh and read |

<details>
<summary><b>1. Missing null check on refund result</b> — <code>CaptureService.cs:42</code></summary>

**Problem:** …

**Failure scenario:** …

**Fix:** …

</details>

<details>
<summary><b>2. Race between refresh and read</b> — <code>CacheRefresher.cs:17</code></summary>

…

</details>
```

Rules:
- The table's **Issue** cell is the finding title only: one line, under ~70 characters, and no `|` characters (they break the table).
- Link `Where` to the file at the PR head SHA (`gh pr view N --json headRefOid`); show just the file name and line, not the full path.
- Every `<details>` block needs a blank line after `<summary>…</summary>` and another before `</details>`, or GitHub won't render the markdown inside.
- Put one fenced code block inside a finding's details only when the fix needs code; keep problem, scenario and fix to a sentence or two each.
- Minor findings: the table alone is enough when the title says it all; add a `<details>` block only for findings that need an explanation.
- Empty severities get no comment.

**C. Confirm in chat** — after publishing, list exactly what was posted: review type (approve / request changes / comment fallback), number of inline comments, and which grouped comments were created, with the PR URL.

## Verdict Rules (shared by all reviewer agents)

- **✅ MERGE ALLOWED** / **⛔ MERGE BLOCKED** — the verdict leads the report
- **Only Critical findings block** — High / Major / Minor are reported with recommendations but do not change the verdict
- Every finding includes severity, `file:line`, the concrete failure scenario, and a suggested fix

## Extending to a new stack

Add `~/.claude/agents/pr-reviewer-<stack>.md` (copy an existing one, keep the Core Method / Severity Taxonomy / Report Format sections identical, swap the stack-specific checklists in Phases 1–3) and add a detection row to the table in step 3 above.

## Prerequisites

- For PR review: `gh` CLI authenticated against the repo (write access required for `--publish`)
- For branch review: the feature branch checked out with the base branch fetched
- Optional: issue tracker MCP (intent check against the ticket)
