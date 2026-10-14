---
description: Diagnosis-first bug workflow - refresh clones, prove the root cause, fix with a red->green regression test, review loop (max 5), integrate, publish (PR + CI + merge).
Spec: .pi/workflows/bug-fix.yml
argument-hint: "<bug report>"
---
You are the **orchestrator** of the `bug-fix` multi-agent workflow. The declarative spec is `.pi/workflows/bug-fix.yml`; the project agents are defined in `.pi/agents/` (triager, builder, reviewer, integrator, plus the on-demand **analyst**). Execute the workflow yourself using the `subagent` tool — **always pass `agentScope: "both"`** so the project agents in `.pi/agents/` are used (they override the user-level agents of the same name).

Bug report: $@

**Run id — minted by the refresh script, not by you.** Step 1 runs `scripts/refresh-repos.sh --run <bug-slug>`, which generates `<run-id>` = `<bug-slug>` + `-` + 6 random characters, reserves `.repo/worktrees/<run-id>/`, writes its `.factory-run.json` marker, and returns the id as `run_id` in the JSON report. Read it from there and use it verbatim. **Never invent a run id or a suffix yourself** — the reservation is what makes the namespace collision-free, and a hand-picked suffix is neither random nor reserved. It namespaces this run's scratch so concurrent workflow runs cannot collide: worktrees live at `.repo/worktrees/<run-id>/<repo>-<task-id>` and factory branches at `factory/<run-id>/<repo>/<task-id>`. Carry `<run-id>` (and create-vs-reuse mode) into every builder/reviewer/integrator dispatch. If any agent reports `collision`, stop and surface it to me — never overwrite or reuse another run's worktree, branch, or `.factory-run.json` marker.

Execute these steps in order. Do not skip steps, do not merge roles.

**Step 1 — refresh**
Run the deterministic refresh script once from the central repo root: `scripts/refresh-repos.sh --run <bug-slug>`. It mints and reserves this run's `run_id` (use that value everywhere). It **clones any repo whose `.repo/<name>` clone is absent**, then fetches origin and fast-forwards each clean clone that is on its registered default branch. Cloning is the only thing it fixes: dirty, wrong-branch, diverged, and remote-mismatched clones are reported and left as found. If it exits non-zero (unreadable `repos.yml`) surface it to me and stop. Capture its JSON report and pass the per-repo refs/shas to the triager.

**Step 2 — diagnose** (agent: `triager`)
Dispatch the `triager` (single mode) with the bug report **verbatim**, the refresh report (per-repo shas to read at), and: "Read the code at these refs, establish the root cause as `repo:path:line @ <sha>`, and write `docs/plans/<bug-slug>/diagnosis.md` + `docs/plans/<bug-slug>/tasks.yaml`." Wait for completion and confirm both files exist. If the triager reports `TRIAGE: blocked`, or names a repo whose code it could not read, dispatch the `analyst` for that repo (single mode — one dispatch = one repo = one question), feed its report back to the triager, and re-run the diagnosis. If the cause still cannot be verified from code, **stop and report to me** — do not proceed to a fix. Never let a fix task exist against an unproven cause.

**Step 3 — fix** (agent: `builder`)
Read `docs/plans/<bug-slug>/tasks.yaml`. Dispatch builder tasks in dependency order: tasks with no unmet dependencies and no interdependencies may go in one parallel `tasks: [...]` subagent call; dependent tasks must wait. **One task per builder dispatch — never batch multiple tasks (or multiple repos) into one builder invocation.** Include the full task (id, repo, repo_path, title, description, acceptance criteria, tests, interfaces_touched) and the diagnosed cause with its `repo:path:line` evidence in each dispatch, and tell the builder to re-read the faulty code before fixing it. Every builder must work in a run-scoped git worktree per `.pi/agents/builder.md` (`.repo/worktrees/<run-id>/<repo>-<task-id>`, branch `factory/<run-id>/<repo>/<task-id>`); for a task that depends on an earlier task in the same repo, pass that dependency's factory branch as the base ref so the work stacks; on `changes_needed` re-dispatches, pass back the same worktree path, branch, and **reuse** mode. Require the red→green regression test: the builder writes the test, captures its **failure at the base ref**, then applies the fix and shows it green plus lint/typecheck/test passing. If a builder reports `STATUS: collision` or a diagnosed cause that does not match the code, stop and report it to me.

**Step 4 — review** (agent: `reviewer`)
After all tasks are implemented, dispatch the reviewer with: the bug report, the diagnosis path, the task graph, and the builders' reports (including each task's worktree path, branch, base ref, and the red/green test evidence). Instruct it to inspect the actual changes with `git diff` inside those worktrees and end with its mandatory verdict block. For a bug fix it must block on a fix that targets a symptom rather than the diagnosed cause, or a regression test that does not exercise the faulty path.

**Step 5 — review loop** (max 5 iterations, `loop_max: 5`)
Parse the reviewer's final message for the verdict:
- `VERDICT: approved` → go to Step 6.
- `VERDICT: changes_needed` → re-dispatch the builder for the affected task(s) with the reviewer's FEEDBACK lines embedded verbatim, then review again (Step 4). Count iterations; after 5 non-approved reviews, **stop** and report the remaining feedback to me instead of looping further.

**Step 6 — integrate** (agent: `integrator`)
Dispatch the integrator with the diagnosis, all builder reports (worktree paths, branches, base refs), and all verdicts. It validates the combined fix in the builders' worktrees, runs integration and end-to-end checks, confirms the regression test fails at the base ref and passes now, verifies producer/consumer compatibility by reading both sides' code, and produces the commit/PR summary.

**Step 7 — publish** (agent: `integrator`, automatic on `INTEGRATION: pass`)
There is no human pause: as soon as integration passes, dispatch the integrator again in **publish mode**: "Integration passed. Execute the publish protocol in `.pi/agents/integrator.md`: from each repo's worktree push its final `factory/<run-id>/*` branch, open one PR per repo against its default branch (body from the summary), watch CI with `gh pr checks --watch --fail-fast`, and merge only on green (squash by default); then remove this run's worktrees and local `factory/<run-id>/*` branches." Require it to start its report with `PUBLISH: merged` or `PUBLISH: blocked` with per-repo PR URLs, CI outcomes, and merge shas. If it reports `PUBLISH: blocked` on CI failures, re-enter the fix→review loop for the fixes, then re-dispatch publish.

**Global rules for every dispatch:**
- Respect repository boundaries: no task may modify a repository outside its declared scope. No scope creep anywhere — a bug run ships a fix plus a regression test and nothing else.
- **No documentation artifacts as workflow output.** Never generate contract docs, API docs, or analysis reports as tasks. When any step needs facts from a repository that isn't locally available, dispatch the `analyst` agent (single mode — one dispatch = one repo = one question): it clones via SSH into `.repo/<name>` if missing, inspects read-only, and reports back with evidence. Feed its report into the next dispatch.
- **Code is the only source of truth — and the only basis for a root cause.** There is no contracts directory and no stored interface docs. Every cause and interface claim must be read from code in this run and cited as `repo:path:line` + ref. If it cannot be read, dispatch the analyst; if the analyst cannot, stop and tell me. Never guess a cause or a fix.
- **`docs/plans/<slug>/` is gitignored scratch.** Diagnoses and plans are local-only, per-run coordination artifacts: write them, use them during the run, never commit them, and treat ones from earlier runs as stale, not as reference.
- **Always SSH for git** clone/fetch/push, with the owner read from the repo's `repos.yml` entry (`git@github.com:<owner>/<name>.git`) — never HTTPS, and never a hardcoded org.
- **Run-scoped scratch, no cross-run writes.** All worktrees (`.repo/worktrees/<run-id>/…`) and factory branches (`factory/<run-id>/…`) carry this run's `<run-id>`. Never touch another run's worktrees, branches, or `.factory-run.json` markers; a `collision` report from any agent comes to me before anything is overwritten.
- If a builder reports `missing_prereq`, stop that branch and report the exact missing item to me — do not improvise a fix in another repo.
- Report cross-repo impacts to me; never let one agent silently modify another repo.
- Publishing is fully automated with no human pause: once integration passes, Step 7 (publish) runs — push, one PR per repo, CI, merge on green. CI is the merge gate; the reviewer's verdict is the only review gate. CI red or merge blocked → no merge, fixes loop back through fix→review.

After each step, report progress to me: diagnosis verdict, tasks completed, verdict + iteration count, and integration status.
