# Agent notes

This private repo is the central controller of a multi-agent software factory.
The code it changes lives elsewhere: sub-repos are cloned into `.repo/`
(gitignored) and worked on in place. Nothing here is deployed, but the
workflows below push branches, open PRs, and merge them in the real
sub-repos, so treat their rules as binding.

- `projects/` and ad-hoc scripts are the playground: quick experiments
  against real data belong there.
- The factory itself (`.pi/`, `repos.yml`, `scripts/`) is not a playground.

## Workspace Structure (PARA Method)

This repo is organized using the PARA method:

- `projects/` — Active investigations and initiatives with a defined outcome. Each project gets its own folder with a `SUMMARY.md`.
- `areas/` — Ongoing areas of responsibility (no end date).
- `resources/` — Secrets and build/deploy config, git-crypt encrypted (see "Local resources" below).
- `archive/` — Completed or inactive items moved here when done.

When asked to "create a project", create a new folder under `projects/` with a `SUMMARY.md` capturing the context.

# Multi-agent workflows

This repository hosts reusable Pi multi-agent workflows. Specs live in
`.pi/workflows/`, agents in `.pi/agents/`, and each workflow is executed by
the matching prompt template in `.pi/prompts/`.

| Workflow | Command | Purpose |
|----------|---------|---------|
| `feature-review` | `/feature-review "<feature request>"` | Plan, build, review (loop, max 5), integrate, publish (PR + CI + merge) a feature across repos |
| `bug-fix` | `/bug-fix "<bug report>"` | Prove the root cause, fix with a red→green regression test, review (loop, max 5), integrate, publish (PR + CI + merge) a bug |
| `onboard-repo` | `/onboard-repo "<owner/name>"` | Clone a repo, verify its commands, register it in `repos.yml` |

Agents: `.pi/agents/{triager,planner,builder,reviewer,integrator,analyst,registrar}.md`.
The orchestrator is the prompt template itself, not an agent file.
The builder, reviewer, integrator, and analyst are shared by more than one
workflow; the planner belongs to `feature-review`, the triager to `bug-fix`,
and the registrar to `onboard-repo`.
A repo must be onboarded before any feature or bug work can target it.

Both `feature-review` and `bug-fix` run the same seven steps: refresh, plan
or diagnose, build, review, review loop, integrate, publish.

### Run-scoped scratch

Every run gets a `<run-id>` (`<slug>-<6 random chars>`). It is minted by
`scripts/refresh-repos.sh --run <slug>` in Step 1, never invented by an agent:
the script draws the suffix from `/dev/urandom` and reserves
`.repo/worktrees/<run-id>/` with a bare `mkdir`, which fails if the namespace
is already taken, then writes the `.factory-run.json` marker. It comes back as
`run_id` in the refresh report, and the orchestrator carries it into every
builder, reviewer, and integrator dispatch. Worktrees live at `.repo/worktrees/<run-id>/<repo>-<task-id>` and
branches at `factory/<run-id>/<repo>/<task-id>`, so concurrent runs cannot
collide. The run-agnostic layout (`factory/<repo>/<task-id>`) is forbidden.
Any agent that finds a foreign run's worktree, branch, or `.factory-run.json`
marker in its own namespace stops with `STATUS: collision` and reports it;
nothing is overwritten, reset, or deleted.

## Repositories & cloning

Sub-repository clones live under `.repo/` (gitignored) and are created on
demand in two places: `scripts/refresh-repos.sh` clones every registered repo
whose clone is absent, and the **analyst** clones a repo it is dispatched to
inspect if the refresh has not already done so (one dispatch = one repo = one
question; it inspects read-only and reports back).

Every `feature-review` and `bug-fix` run starts with the orchestrator running
the deterministic `scripts/refresh-repos.sh`. It clones what is missing, then
fetches and `--ff-only` fast-forwards each clean clone that is on its
registered default branch. A missing clone is no longer a reason to stall the
run; dirty, wrong-branch, diverged, and remote-mismatched clones are still
reported and left exactly as found. `--no-clone-missing` restores the old
report-only behavior for a dry run.

Always clone/fetch/push via SSH, using the `url` from the repo's `repos.yml`
entry — `git@github.com:<owner>/<name>.git`, owner read from the entry, never
assumed — and never HTTPS. Do not generate
documentation artifacts (contract docs, API docs, analysis reports); when
repo knowledge is needed, analyze the repo directly via the analyst.

## Code is the only source of truth

There is no contracts directory and no stored interface documentation.
Written contracts and plans go stale faster than anyone updates them, and a
stale contract is worse than no contract because agents trust it. So:

- Every claim about another repo's API, payload, shared type, event name, or
  schema must come from reading that repo's code at a known ref, cited as
  `repo:path:line` plus the commit inspected.
- When a repo isn't locally available, dispatch the **analyst** to read it.
  Its report is the answer; it is not written to a file.
- Treat any interface fact older than the current run as unverified. Re-read
  the code instead of reusing a previous run's conclusion.
- Plans under `docs/plans/<slug>/` are per-run coordination scratch, not
  reference material. Old plans are stale by default.
- If an interface cannot be verified from code, stop and report that. Never
  infer it from naming, docs, comments, or a prior run.

"Verified" means read in this run, at a ref you can name.

## Repository registry

**`repos.yml` at the repo root is the registry.** It is the only list of
repositories the factory works on. Agents read it directly; there is no
markdown copy to drift out of sync.

Each entry carries the repo's name, owner, SSH URL, clone path under
`.repo/`, role, default branch, language, package manager, and its actual
`install` / `lint` / `typecheck` / `test` / `test_integration` / `build`
commands, plus `depends_on` / `consumed_by` edges.

Rules:

- If a repo is not in `repos.yml`, it is out of scope. Stop and report the
  missing entry instead of guessing a path or a URL.
- A command set to `null` means that repo has no such command. Report
  "not configured" rather than inventing one.
- `repos.yml` records **where code lives and how to run it**, never what an
  interface looks like. Shapes, payloads, and schemas are read from code on
  every run.
- Registering a new repo: run `/onboard-repo`. It clones the repo, runs its
  commands, and writes a verified entry. Do not hand-write entries; a
  command recorded without being run is the main way this file starts lying.
- The **registrar** is the only agent that writes `repos.yml`, and it writes
  nothing else.

## Agent rules

- Agents must not modify files outside the repository assigned by the
  planner. One task = one repository = one builder.
- Cross-repo impacts must be reported, not silently implemented. A builder
  that spots an impact outside its scope reports it and stops.
- Every implementation task must include tests (added or updated).
- Agents must run the repository's configured lint, typecheck, and test
  commands before reporting success, and include the results in their report.
- If a required API, shared type, event payload, migration, or dependency
  cannot be found in the code, stop and report the exact missing item —
  never guess or stub it in another repo.
- Interface claims carry evidence (`repo:path:line` + ref) or they are
  treated as assumptions and reported as such.
- Read-only roles never rewrite what they inspect: the planner never
  modifies repos; the reviewer never rewrites the implementation and runs
  only non-mutating validation. The analyst is the deliberate exception: it
  owns clone lifecycle under `.repo/` (the initial `git clone`), and the
  deterministic `scripts/refresh-repos.sh` is the sanctioned mutator of
  existing clones, limited to `git fetch` + `merge --ff-only` of a clean
  default branch (everything else is reported, never fixed). Plain
  `git pull` stays forbidden everywhere.
- The reviewer's verdict (`approved` / `changes_needed` + feedback) is the
  only gate between build and integrate; the review loop runs at most 5
  iterations (`loop_max: 5`).
- In `bug-fix` the triager's `TRIAGE: verified` is the gate before any fix
  exists. On `TRIAGE: blocked` the run stops: no fix task may be created
  against an unproven cause, and the fix must remove the diagnosed cause
  rather than guard the symptom. Its regression test is red at the base ref
  and green after the fix, and the builder, reviewer, and integrator each
  check that.
- Publishing is automated, not user-gated: once the reviewer approves and
  integration validation passes, the integrator pushes each repo's
  `factory/*` branch, opens one PR per repo, waits for CI, and merges on
  green (squash by default). The gates are the reviewer's verdict,
  integration validation, and CI — never a human pause.
- Feature plans live in `docs/plans/<feature-slug>/` and bug diagnoses in
  `docs/plans/<bug-slug>/`. Both carry two required files: `plan.md` or
  `diagnosis.md`, and `tasks.yaml` (the orchestrator reads the task graph
  from it and confirms both exist before building). All of `docs/` is
  gitignored, so these are per-run scratch and stale once the run ends.
## Local resources (`resources/`, git-crypt)

`resources/` holds the secrets and config needed to build, run and deploy apps. Use these directly — don't ask the user for them.

| File | Feeds |
|---|---|

The build scripts read `resources/` themselves.

- If files read as binary starting with `GITCRYPT`, the repo is locked: ask
  the user to run `git-crypt unlock <key-file>` (key is kept outside the repo,
  often as base64 — decode with `base64 --decode`).