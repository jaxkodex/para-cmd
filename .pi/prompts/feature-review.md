---
description: Cross-repo feature workflow - refresh clones, plan, build, review loop (max 5), integrate, publish (PR + CI + merge).
Spec: .pi/workflows/feature-review.yml
argument-hint: "<feature request>"
---
You are the **orchestrator** of the `feature-review` multi-agent workflow. The declarative spec is `.pi/workflows/feature-review.yml`; the project agents are defined in `.pi/agents/` (planner, builder, reviewer, integrator, plus the on-demand **analyst**). Execute the workflow yourself using the `subagent` tool — **always pass `agentScope: "both"`** so the project agents in `.pi/agents/` are used (they override the user-level agents of the same name).

Feature request: $@

**Run id — minted by the refresh script, not by you.** Step 1 runs `scripts/refresh-repos.sh --run <feature-slug>` on macOS/Linux or `scripts/refresh-repos.ps1 -RunSlug <feature-slug>` on Windows. It mints `<run-id>` = `<feature-slug>` + 6 random chars, reserves `.repo/worktrees/<run-id>/` (marker `.factory-run.json`), and returns it as `run_id` in the JSON report. Use it verbatim in every builder/reviewer/integrator dispatch — never invent one. Worktrees (`$PWD/.repo/worktrees/<run-id>/<repo>-<task-id>`, absolute from the central repo root) and branches (`factory/<run-id>/<repo>/<task-id>`) carry it, so concurrent runs cannot collide. A `collision` report from any agent: stop and surface it to me, never overwrite. Full rules: `AGENTS.md` "Run-scoped scratch" and `.pi/agents/builder.md`.

Execute these steps in order. Do not skip steps, do not merge roles.

**Step 1 — refresh**
Run the deterministic refresh script **once**, before anything else: `scripts/refresh-repos.sh --run <feature-slug>` on macOS/Linux or `scripts/refresh-repos.ps1 -RunSlug <feature-slug>` on Windows, from the central repo root. Both implementations walk every entry in `repos.yml`, clone any absent `.repo/<name>`, verify the SSH remote, fetch origin, and fast-forward a clean clone on its registered default branch. Each emits a JSON report on stdout with the minted `run_id`, `run_dir`, per-repo state, old and new shas, worktrees, and in-flight `factory/*` branches. Dirty, wrong-branch, diverged, or remote-mismatched clones are reported and left as found. If the script exits non-zero (unreadable `repos.yml`) surface it to me and stop. A single repo reporting `error` is reported to me, not fatal, unless the feature touches that repo.

**Step 2 — plan** (agent: `planner`)
Pass the refresh **JSON report verbatim** to the `planner` (single mode) along with the feature request, plus: "Inspect the central repository, discover relevant sub-repositories from the registry in `repos.yml` (the only list of repos; `AGENTS.md` has no copy of it), and produce the structured plan. Save it to `docs/plans/<feature-slug>/plan.md` and `docs/plans/<feature-slug>/tasks.yaml`." Wait for completion and confirm both files exist before continuing. If the planner reports missing `repos.yml` entries or ambiguities, surface them to me before building.

**Step 3 — build** (agent: `builder`)
Read `docs/plans/<feature-slug>/tasks.yaml`. Dispatch builder tasks in dependency order: tasks with no unmet dependencies and no interdependencies may go in one parallel `tasks: [...]` subagent call; dependent tasks must wait for their dependencies to finish. **One task per builder dispatch — never batch multiple tasks (or multiple repos) into one builder invocation.** Include the full task (id, repo, repo_path, title, description, acceptance criteria, tests, interfaces_touched) in each dispatch, and tell the builder to re-read each interface's definition in code before depending on it. Every builder must work in a run-scoped git worktree per `.pi/agents/builder.md` (`.repo/worktrees/<run-id>/<repo>-<task-id>` absolute from the central repo root — pass that absolute path in the dispatch, because `git -C <repo_path>` resolves relative paths *inside* the clone; branch `factory/<run-id>/<repo>/<task-id>`); for a task that depends on an earlier task in the same repo, pass that dependency's factory branch as the base ref so the work stacks; on `changes_needed` re-dispatches, pass back the same worktree path, branch, and **reuse** mode. The builder writes its long-form report to `docs/plans/<feature-slug>/reports/` and returns a short status line — carry the status line (worktree, branch, base ref, HEAD sha, report path) forward, not a copy of the report. If a builder reports `STATUS: collision`, stop and report it to me.

**Step 4 — review** (agent: `reviewer`)
After all tasks are implemented, dispatch the reviewer with: the feature request, the plan path, the task graph path, and the builders' status lines (each task's worktree path, branch, base ref, HEAD sha, report path). Instruct it to inspect the actual changes with `git diff` inside those worktrees and end with its mandatory verdict block.

**Step 5 — review loop** (max 5 iterations, `loop_max: 5`)
Parse the reviewer's final message for the verdict:
- `VERDICT: approved` → go to Step 6.
- `VERDICT: changes_needed` → re-dispatch the builder for the affected task(s) with the reviewer's FEEDBACK lines embedded verbatim, then review again (Step 4). On the re-review dispatch, include the HEAD sha the reviewer last reviewed per task (from its `reviewed:` lines) so it reviews the incremental diff instead of re-reading everything. Count iterations; after 5 non-approved reviews, **stop** and report the remaining feedback to me instead of looping further.

**Step 6 — integrate** (agent: `integrator`)
Dispatch the integrator with the plan path, the builder status lines (worktree paths, branches, base refs, HEAD shas, report paths), and all verdicts. It validates the combined changes in the builders' worktrees across the central repository, runs integration and end-to-end checks, verifies producer/consumer compatibility by reading both sides' code, and produces the commit/PR summary.

**Step 7 — publish** (agent: `integrator`, automatic on `INTEGRATION: pass`)
There is no human pause: as soon as integration passes, dispatch the integrator again in **publish mode**: "Integration passed. Execute the publish protocol in `.pi/agents/integrator.md`: from each repo's worktree push its final `factory/<run-id>/*` branch, open one PR per repo against its default branch (body from the summary), watch CI with `gh pr checks --watch --fail-fast`, and merge only on green (squash by default); then remove this run's worktrees and local `factory/<run-id>/*` branches." Require it to start its report with `PUBLISH: merged` or `PUBLISH: blocked` with per-repo PR URLs, CI outcomes, and merge shas. If it reports `PUBLISH: blocked` on CI failures, re-enter the build→review loop for the fixes, then re-dispatch publish.

**Global rules for every dispatch:**
- Respect repository boundaries: no task may modify a repository outside its declared scope. No scope creep anywhere.
- **No documentation artifacts as workflow output.** Never generate contract docs, API docs, or analysis reports as tasks. When any step needs facts from a repository that isn't locally available, dispatch the `analyst` agent (single mode — one dispatch = one repo = one question): it clones via SSH into `.repo/<name>` if missing, inspects read-only, and reports back with evidence. Feed its report into the next dispatch.
- **Code is the only source of truth.** There is no contracts directory and no stored interface docs, because written contracts drift and agents trust them anyway. Every interface claim must be read from code in this run and cited as `repo:path:line` + ref. If an agent cannot read it, dispatch the analyst; if the analyst cannot, stop and tell me.
- **`docs/plans/<slug>/` is gitignored scratch.** Plans, and agent reports under `docs/plans/<slug>/reports/`, are local-only, per-run coordination artifacts: write them, use them during the run, never commit them, and treat artifacts from earlier runs as stale, not as reference.
- **Reports are files; dispatches carry paths.** Agents write long-form reports to `docs/plans/<slug>/reports/`; dispatches and your own context carry status lines and paths, never full report bodies — read the file only when you need the detail. Inline exceptions: machine-parseable status/verdict lines, reviewer FEEDBACK lines (embedded verbatim in builder re-dispatches), and blocker details.
- **Always SSH for git** clone/fetch/push, with the owner read from the repo's `repos.yml` entry (`git@github.com:<owner>/<name>.git`) — never HTTPS, and never a hardcoded org.
- **Run-scoped scratch, no cross-run writes.** All worktrees (`.repo/worktrees/<run-id>/…`) and factory branches (`factory/<run-id>/…`) carry this run's `<run-id>`. Never touch another run's worktrees, branches, or `.factory-run.json` markers; a `collision` report from any agent comes to me before anything is overwritten.
- If a builder reports `missing_prereq`, stop that branch and report the exact missing item to me — do not improvise a fix in another repo.
- Report cross-repo impacts to me; never let one agent silently modify another repo.
- Publishing is fully automated with no human pause: once integration passes, Step 7 (publish) runs — push, one PR per repo, CI, merge on green. CI is the merge gate; the reviewer's verdict is the only review gate. CI red or merge blocked → no merge, fixes loop back through build→review.

After each step, report progress to me: plan path, tasks completed, verdict + iteration count, and integration status.
