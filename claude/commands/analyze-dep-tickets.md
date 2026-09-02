# /analyze-dep-tickets — Deep-dive review of `dep-major` Jira tickets

`/update-dependencies` files backlog tickets (label `dep-major`) for every
major it refuses to apply. This command picks up those tickets and does the
work a human would have to: research the breaking changes, check whether this
codebase is actually affected, trial the upgrade in an isolated worktree, and
post the full analysis as a comment on the ticket. When — and only when —
the analysis proves the major is a no-op for this repo **and** verification
is fully green, it also opens the PR.

## Usage

```bash
/analyze-dep-tickets                 # interactive: discover, ask before posting/PR
/analyze-dep-tickets PRK-123        # analyze one specific ticket
/analyze-dep-tickets --auto          # unattended (CCVerify): pre-approved
/analyze-dep-tickets --max 1         # cap tickets per run (default 2)
```

**`--auto`:** the caller has pre-approved posting the analysis comment,
adding the `dep-analyzed` label, and — on a SAFE verdict only — pushing a
`deps/*` branch, opening the PR, and moving the ticket to Dev Complete. No
approval gates, every guard applies. Interactive mode: show the finished
analysis and ask once per ticket before posting the comment (and, when SAFE,
creating the PR + the Dev Complete transition — one yes covers both).

## Hard safety rules (both modes)

1. **Never modify the user's working copy.** All trial upgrades happen in a
   throwaway `git worktree` created from `origin/<base>`; remove it at the
   end, always — even on failure.
2. **A SAFE verdict needs both halves.** (a) Every documented breaking change
   is shown — with evidence from this codebase — to not affect this repo, and
   (b) the upgrade passes the repo's full verification (install, format,
   lint, tests, build) in the worktree. Missing either half → the verdict is
   NEEDS MIGRATION or BLOCKED, and **no PR**.
3. **Red base = no SAFE verdict.** If verification fails on clean
   `origin/<base>` *before* the upgrade, the ticket is BLOCKED (by the base,
   not the package): post the analysis with that finding and stop — a green
   run can't be distinguished from a masked regression.
4. **Push only to a fresh `deps/major-*` branch.** Never to existing
   branches, never force, never to `dependabot/*`.
5. **Never merge, approve, or enable auto-merge** on the PR this creates.
6. **One PR per ticket.** If an open PR already references the ticket key or
   covers the same package group, link it in the comment instead of stacking
   a second one.
7. **Comment + label; the only status change is Dev Complete after our own
   PR.** When this command itself opened the PR (SAFE verdict), transition
   the ticket to Dev Complete (step 8) — the development half is done, the
   PR awaits human review. Never transition on NEEDS MIGRATION or BLOCKED,
   never to any other status, and never change the assignee or edit the
   description. Humans own the rest of the workflow state.

## Jira mapping

Known projects (same table as `/update-dependencies`):

| Repo | Jira project | Cloud ID | Epic |
|---|---|---|---|
| `teztechnology/text2park.web` | `PRK` | `108a72cf-a3ed-4303-95da-07d7fa0fa6ee` | `PRK-209` |
| `teztechnology/text2park.backend` | `PRK` | `108a72cf-a3ed-4303-95da-07d7fa0fa6ee` | `PRK-209` |

If the repo isn't in the table (and its `CLAUDE.md` defines no Jira project)
or the Atlassian tools aren't available here, stop immediately and report —
this command has no useful degraded mode without Jira.

## Procedure

### 1. Discover tickets

Given an explicit ticket key, use it (still verify it carries `dep-major`
and belongs to this repo per its summary/description). Otherwise search
(`searchJiraIssuesUsingJql`):

```
project = <KEY> AND labels = dep-major AND labels != dep-analyzed
  AND statusCategory != Done ORDER BY created ASC
```

Keep only tickets whose summary names this repo — step 8 of
`/update-dependencies` ends summaries with `(<owner>/<repo>)` — and take the
oldest `--max` (default 2; deep dives are expensive, breadth comes from the
schedule). Nothing to analyze → report that and stop cleanly.

### 2. Understand the ticket

`getJiraIssue` (with comments): extract the package or package group, the
recorded current → latest versions, and any "version moved on" comments.
Re-check the *actual* latest version with the package manager
(`npm view <pkg> version` / `dotnet package search` / registry via WebFetch) —
analyze against today's latest, not the version the ticket was filed with,
and say so in the comment when they differ.

### 3. Research the breaking changes

WebFetch the changelog / release notes / migration guide for every major
step between current and target (e.g. 10 → 12 means reading 11.0 and 12.0
notes both). Build the concrete list of breaking changes: removed/renamed
APIs, changed defaults, dropped runtimes/TFMs/Node engines, peer-dependency
shifts, license changes. A runtime/engine requirement this repo can't meet
→ verdict BLOCKED, skip the trial upgrade.

### 4. Check this codebase against each breaking change

This is the deep dive — generic changelog summaries are worthless here. For
every breaking change, Grep/Read the repo for actual usage and record a
finding with evidence:

- **Not used** — the removed/changed API never appears (`grep` came back
  empty; name the patterns you searched).
- **Used, unaffected** — appears, but usage is compatible (cite file:line).
- **Affected** — appears and must change (cite file:line, describe the
  required edit and estimate the effort).

Transitive exposure counts: config files, build scripts, CI workflows, and
generated code are part of the codebase.

### 5. Trial upgrade in an isolated worktree

```bash
git fetch origin <base>          # base: develop if it exists, else default
git worktree add /tmp/depticket-<repo>-<date> origin/<base>
```

Baseline first: run the repo's verification suite (install, format check,
lint, tests, build — its own scripts, honoring `CLAUDE.md` env overrides)
on the clean worktree. Red baseline → rule 3, skip the upgrade. Then apply
the major with the package manager's own upgrade command (never hand-edit
lockfiles; move a package family together when the ticket groups them) and
run the full suite again. Record every command and result.

### 6. Verdict

- ✅ **SAFE TO UPDATE** — every breaking change is Not used / Used-unaffected
  *and* verification is fully green. Only this verdict creates a PR.
- ⚠️ **NEEDS MIGRATION** — code changes required (or verification failed in
  a way the analysis explains). The comment's findings table doubles as the
  migration checklist.
- ⛔ **BLOCKED** — can't be applied regardless of code changes right now:
  unmet runtime requirement, peer-dependency conflict, or a red baseline
  (rule 3 — name the pre-existing failures).

### 7. Open the PR (SAFE only)

From the worktree, after the duplicate guard of rule 6:

```bash
git checkout -b deps/major-<package-slug>-<YYYY-MM-DD>
git add <manifest + lockfile>
git commit -m "chore(deps): <package> <current> -> <target> (<TICKET-KEY>)"
git push origin deps/major-<package-slug>-<YYYY-MM-DD>
gh pr create --base <base> --title "chore(deps): <package> <current> → <target> (<TICKET-KEY>)" --body-file <body>
```

PR body: the analysis summary (breaking-changes table with per-change
findings), the verification table, and the Jira key.

### 8. Post the analysis comment and label the ticket

Post one comment (`addCommentToJiraIssue`) — after the PR exists, so a SAFE
comment can link it:

```md
## Deep-dive analysis — <package or group> <current> → <target>

**Verdict: <✅ SAFE TO UPDATE | ⚠️ NEEDS MIGRATION | ⛔ BLOCKED>**
<PR: <url> — verified green, review & merge manually.   (SAFE only)>

### Breaking changes vs this codebase
| Change (version) | Impact here | Evidence |
|---|---|---|

### Verification (isolated worktree from origin/<base>)
| Check | Baseline | After upgrade |
|---|---|---|

### Notes
<version drift since ticket creation, migration effort estimate for
NEEDS MIGRATION, what unblocks a BLOCKED ticket, links used>

*Automated deep-dive by CCVerify (/analyze-dep-tickets).*
```

Then add the `dep-analyzed` label via `editJiraIssue` — **add** to the
existing labels, never replace them (`dep-major` must survive). The label is
the dedupe marker: `/update-dependencies` removes it again when the
available version moves on, which re-queues the ticket here.

**SAFE verdict only — move the ticket to Dev Complete.** The PR exists and
is linked from the comment, so the ticket's development half is done. Look
up the workflow's transitions (`getTransitionsForJiraIssue`) and pick the
one whose target status matches "Dev Complete" (case-insensitive, ignoring
`-`/`_`/spaces); apply it with `transitionJiraIssue`. If the workflow has no
such transition from the current status, leave the status alone and note
that in the run report — never guess a different status. NEEDS MIGRATION
and BLOCKED tickets are never transitioned (rule 7).

### 9. Cleanup and report

`git worktree remove … --force` (always), delete the local `deps/major-*`
ref if the worktree held it, and finish with the run report:

```md
## Dep-ticket deep-dive — <repo> <date>

| Ticket | Package | Verdict | Comment | PR | Status |
|---|---|---|---|---|---|
| PRK-N | pkg 10 → 12 | ✅/⚠️/⛔ | posted/skipped | url or — | dev complete / unchanged |

<per-ticket one-paragraph summaries; anything skipped and why;
tickets remaining in the queue>
```
