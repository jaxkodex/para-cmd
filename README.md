# para-cmd

Central repository for a multi-agent software factory. It holds the workflow
that plans, implements, reviews, and integrates features across a set of
sub-repositories, plus the PARA structure that keeps track of what was worked
on and why.

The code being changed does not live here. Sub-repos are cloned on demand
into `.repo/` (gitignored) and worked on in place.

## Layout

```
repos.yml              registry: every repo the factory can touch
projects/              active investigations, one folder + SUMMARY.md each
areas/                 ongoing responsibilities, no end date
resources/             reference material
archive/               finished or abandoned, moved here
.pi/
  workflows/           declarative workflow spec (feature-review.yml)
  prompts/             slash commands that execute the workflows
  agents/              agent definitions (planner, builder, reviewer,
                       integrator, analyst, registrar)
.repo/                 sub-repo clones (gitignored)
docs/plans/            per-run plans (gitignored, stale after the run)
```

## Workflows

| Command | What it does |
|---------|--------------|
| `/feature-review "<feature request>"` | Plan, build, review, integrate a feature across repos |
| `/onboard-repo "<owner/name>"` | Clone a repo, verify its commands, register it |

## Running a feature

```
/feature-review "<feature request>"
```

The orchestrator drives five steps: plan, build, review, review loop
(max 5 iterations), integrate. One task equals one repository equals one
builder. The reviewer's `VERDICT: approved` / `VERDICT: changes_needed` is
the only gate between build and integrate. The integrator stops before any
commit, push, or PR and waits for you.

Spec: `.pi/workflows/feature-review.yml`. Agents: `.pi/agents/`.

## Two rules that shape everything else

**Code is the only source of truth.** There is no contracts directory and no
stored interface docs. Every claim about an API, payload, shared type, event,
or schema is read from the code in the current run and cited as
`repo:path:line` plus the ref. Written contracts drift, and a stale contract
is worse than none because agents trust it. If an interface cannot be read,
the agent stops and reports it.

**`repos.yml` is the registry.** A repo not listed there is out of scope.
The entry carries the SSH URL, clone path, and the repo's real lint,
typecheck, and test commands, so agents stop rediscovering them. It records
where code lives and how to run it, never what the code's interfaces look
like.

## Adding a repository

```
/onboard-repo "jaxkodex/example-api"
```

The analyst clones it over SSH into `.repo/`, finds the install, lint,
typecheck, test, and build commands, and **runs them**. The registrar then
writes one verified entry into `repos.yml`, recording `null` for commands the
repo does not have and flagging anything it could not confirm. Then the run
pauses for you.

Don't hand-write entries. A command recorded without being run is how the
registry starts lying, and every later build inherits the lie.

Spec: `.pi/workflows/onboard-repo.yml`.

## Starting a project

Copy `projects/_TEMPLATE/SUMMARY.md` into `projects/<slug>/SUMMARY.md` and
fill in the outcome and context. Log each workflow run in its Runs table:
plans under `docs/plans/` are gitignored scratch, so the SUMMARY is the only
record that survives.

Conventions and agent rules: `AGENTS.md`.
