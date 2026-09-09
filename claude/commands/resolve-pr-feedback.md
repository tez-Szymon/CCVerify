# /resolve-pr-feedback — Work through the feedback on your own PR

Your PR is open and something wants your attention: it conflicts with the
target branch, CodeRabbit left threads, a reviewer requested changes, or CI
went red. This command does what you would do next — read every item, decide
per item whether it is worth fixing, fix what is, and answer the rest in its
own thread. Nothing is ever silently ignored.

Unattended sibling of the interactive `gaaf:resolve-pr` skill: same triage
(Fix / Answer / Decline / Defer), no approval gates, and every mutating step
happens in a throwaway worktree.

## Usage

```bash
/resolve-pr-feedback 412              # interactive: triage, ask before pushing/replying
/resolve-pr-feedback <pr-url>         # same, by URL
/resolve-pr-feedback --auto           # unattended (CCVerify): pre-approved
/resolve-pr-feedback 412 --auto       # unattended, one PR
```

Without a number, resolve the current branch's PR
(`gh pr view --json number,title,url,baseRefName,headRefName,isCrossRepository`).

**`--auto`:** the caller has pre-approved implementing the fixes, pushing them
to the PR's own head branch, replying in every thread, and resolving the
threads that were actually fixed. No approval gates, every guard below still
applies. Interactive mode: present the classified list once and ask before
touching anything.

## Hard safety rules (both modes)

1. **Only PRs authored by the `gh` user.** Verify `author.login == viewer`
   (`gh api user --jq .login`); anything else → stop and report. This command
   changes someone's branch, so it only ever changes ours.
2. **Never touch the user's working copy.** All work happens in
   `/tmp/prfollowup-<repo>-<number>` created with `git worktree add`; remove it
   at the end, always — even on failure. Never `git checkout`/`gh pr checkout`
   in the main checkout.
3. **Push only to the PR's own head branch, never force.**
   `git push origin HEAD:<headRefName>` and nothing else — no other branch, no
   `--force`, no `--force-with-lease`, no branch deletion. A cross-repository
   PR (fork) we cannot push to → skip every code change, reply in the threads
   only, and say so in the report.
4. **Never push red.** The repo's full verification (install, format, lint,
   tests, build — its own scripts, honoring `CLAUDE.md`) must pass in the
   worktree before any push. If the base was already red before our changes,
   push nothing and say so in the thread replies.
5. **Never merge, approve, close, re-target, or convert the PR**, never
   dismiss or request reviews, never enable auto-merge. Humans own that.
6. **Resolve only threads you actually fixed.** Answered, declined and
   deferred threads stay open — the reviewer closes them.
7. **One run = one round.** Do not wait for the re-review your push triggers;
   the scheduler brings the PR back when new feedback lands.
8. **Surgical changes only.** A review fix is not an invitation to refactor,
   reformat, or upgrade anything the feedback did not name.

## Procedure

### 1. Collect the feedback

```bash
gh pr view <n> --json number,title,url,author,baseRefName,headRefName,mergeable,isCrossRepository,reviewDecision,reviews,comments
gh pr checks <n>
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){
  reviewThreads(first:100){nodes{id isResolved isOutdated path line
    comments(first:20){nodes{id databaseId author{login} body}}}}}}}' \
  -F o=<owner> -F r=<repo> -F n=<n>
```

Keep the threads where `isResolved == false` **and** the last comment is not
ours — a thread we already answered is waiting on the reviewer, not on us.
For red checks, get the actual failure, not just the name:
`gh run view <run-id> --log-failed` (or the check's output via `gh api`).

Nothing actionable → report that and stop cleanly, without creating a worktree.

### 2. Triage every item

One verdict per item, with a one-line rationale:

- **Fix** — valid; implement it.
- **Answer** — a question or a misunderstanding; reply, change nothing.
- **Decline** — wrong or not worth it (a bot's false positive, a suggestion
  that breaks a deliberate design); reply with the reasoning, respectfully.
- **Defer** — valid but out of this PR's scope; reply proposing a follow-up.

Bot comments (CodeRabbit and friends) get the same scrutiny as human ones:
nitpicks that contradict the repo's own conventions are declined with the
convention cited, not applied for the sake of a clean slate. A reviewer who
requested changes usually has one underlying ask spread over several
comments — group those, fix once, and reply in each thread.

In interactive mode, show the classified table and ask once before proceeding.

### 3. Worktree

```bash
git fetch origin <baseRefName> <headRefName>
git worktree add /tmp/prfollowup-<repo>-<n> <headRefName>
```

Work only in there. Install dependencies with the repo's package manager
before running anything.

### 4. Conflicts with the target branch (when `mergeable == CONFLICTING`)

```bash
git merge origin/<baseRefName>
```

Resolve only conflicts whose resolution is unambiguous: disjoint edits in the
same file, both sides' additions where the intent is plainly union
(imports, enum cases, test lists), and lockfiles — which are never hand-merged
but regenerated by the package manager from the merged manifest. Keep both
sides' intent; never drop a change to make the merge pass.

Anything semantic — the two sides changed the same logic, a rename collides
with new usages, a migration ordering conflict — is **not** ours to guess:
`git merge --abort`, then say so in the PR comment of step 9 (which files, why
it needs a human) and carry on with the rest of the feedback.

### 5. Implement the Fix items

Smallest first. If a fix reveals a real bug that no test covered, add the
covering test with it. Follow the repo's conventions (`CLAUDE.md`, the
surrounding code) rather than the reviewer's exact wording when the two differ
— and say which you followed in the reply.

### 6. Verify

Run the repo's full suite in the worktree: install, format check, lint, tests,
build. Red CI was one of the triggers, so this is also where a failing check
gets reproduced and fixed. Record every command and its result — the table
goes into the report.

Still red for a reason our changes don't own (flaky infra, a pre-existing
failure on the base) → rule 4: push nothing, and say exactly that in the
replies.

### 7. Commit and push

One commit per logical group, referencing the review:

```bash
git add <touched files>
git commit -m "fix(review): <topic>"
git push origin HEAD:<headRefName>
```

A merge from step 4 is its own commit
(`Merge branch '<base>' into <head>`), pushed with the rest.

### 8. Reply to every thread

Inline threads (REST reply keeps it in the thread):

```bash
gh api repos/<owner>/<repo>/pulls/<n>/comments/<comment-databaseId>/replies -f body='…'
```

- **Fix** → what changed and where, with the commit SHA. Then resolve it:
  ```bash
  gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -F id=<threadId>
  ```
- **Answer** → the answer, with a file:line pointer when it settles the
  question. Thread stays open.
- **Decline** → why, in one short paragraph, citing the convention, the
  benchmark, or the constraint that makes the suggestion wrong here. Never
  dismissive, never a bare "won't fix". Thread stays open.
- **Defer** → what would be needed and where it belongs. Thread stays open.

Review-level feedback that has no thread (a CHANGES_REQUESTED review body, a
plain PR comment) gets one `gh pr comment` reply covering those points.

### 9. PR comment for what code alone can't say

Post one summary comment (`gh pr comment <n>`) when anything below applies —
otherwise skip it, the thread replies are enough:

```md
## Follow-up round — <date>

<what was fixed, with the commit SHA>
<what was declined and why, one line each>
<unresolvable merge conflict: files + what a human has to decide>
<verification results, when something is still red>

*Automated follow-up by CCVerify (/resolve-pr-feedback).*
```

### 10. Cleanup and report

`git worktree remove /tmp/prfollowup-<repo>-<n> --force` — always, even after
a failure — then finish with the run report:

```md
## PR follow-up — <owner/repo>#<n> <title>

| Item | Source | Verdict | Action |
|---|---|---|---|
| <thread/check/conflict> | coderabbit / <login> / CI | Fix/Answer/Decline/Defer | fixed in <sha> / replied / … |

### Verification
| Check | Result |
|---|---|

<pushed commits (or why nothing was pushed); threads resolved vs left open;
anything a human must pick up>
```
