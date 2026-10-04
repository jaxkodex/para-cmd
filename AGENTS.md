# Agent notes

This repo (private) is a playground for prototypes.
It is not the production project.

- Use this repo for quick scripts and experiments against real data.

## Workspace Structure (PARA Method)

This repo is organized using the PARA method:

- `projects/` — Active investigations and initiatives with a defined outcome. Each project gets its own folder with a `SUMMARY.md`.
- `areas/` — Ongoing areas of responsibility (no end date).
- `resources/` — Reference material and knowledge.
- `archive/` — Completed or inactive items moved here when done.

When asked to "create a project", create a new folder under `projects/` with a `SUMMARY.md` capturing the context.

# Multi-agent workflows

This repository hosts reusable Pi multi-agent workflows. Specs live in
`.pi/workflows/`, agents in `.pi/agents/`, and each workflow is executed by
the matching prompt template in `.pi/prompts/`.

| Workflow | Command | Purpose |
|----------|---------|---------|
| `feature-review` | `/feature-review "<feature request>"` | Plan, build, review (loop, max 5), integrate a feature across repos |
| `onboard-repo` | `/onboard-repo "<owner/name>"` | Clone a repo, verify its commands, register it in `repos.yml` |

Agents: `.pi/agents/{planner,builder,reviewer,integrator,analyst,registrar}.md`.
A repo must be onboarded before any feature work can target it.

## Repositories & cloning

Sub-repository clones live under `.repo/` (gitignored) and are created on
demand by the **analyst** agent (one dispatch = one repo = one question; it
clones, inspects read-only, and reports back). Always clone/fetch/push via
SSH — `git@github.com:jaxkodex/<repo>.git` — never HTTPS. Do not generate
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
`.repo/`, role, default branch, and its actual `lint` / `typecheck` /
`test` / `build` commands, plus `depends_on` / `consumed_by` edges.

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
- Read-only roles (planner, reviewer, analyst) run only non-mutating commands; the
  reviewer never rewrites the implementation.
- The reviewer's verdict (`approved` / `changes_needed` + feedback) is the
  only gate between build and integrate; the review loop runs at most 5
  iterations (`loop_max: 5`).
- No commit, push, or PR without explicit user approval — the integrator
  prepares the summary and always pauses first.
- Feature plans live in `docs/plans/<feature-slug>/` (`plan.md`, optional
  `tasks.yaml`, review notes) and are gitignored per-run scratch.