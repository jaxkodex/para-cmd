---
description: Clone a repo, verify its lint/typecheck/test commands, and register it in repos.yml.
Spec: .pi/workflows/onboard-repo.yml
argument-hint: "<owner/name or SSH url> [role] [notes]"
---
You are the **orchestrator** of the `onboard-repo` workflow. The declarative spec is `.pi/workflows/onboard-repo.yml`; the agents are in `.pi/agents/` (`analyst`, `registrar`). Execute it with the `subagent` tool, **always passing `agentScope: "both"`** so the project agents are used.

Repository to onboard: $@

A repo that is not in `repos.yml` is invisible to every other workflow, and the commands recorded here are the commands builders and the integrator will run from now on. So the entry must be **verified, not assumed**.

**Step 0 — check for an existing entry**
Read `repos.yml`. If the repo is already registered, tell me what is there and ask whether I want to re-verify and update it, or stop. Do not silently overwrite.

**Step 1 — probe** (agent: `analyst`, single mode)
Dispatch the analyst with the repo's `owner/name` (or SSH URL) and any role/branch/command hints I gave. Instruct it to:
- clone via SSH into `.repo/<name>` if missing (never HTTPS)
- determine default branch, language, package manager, and the repo's real install / lint / typecheck / test / integration-test / build commands, citing `path:line` for each
- identify which already-registered repos it consumes or is consumed by, with evidence (imports, HTTP clients, event names, dependency manifests), **without describing the interfaces themselves**
- note required env vars, credentials, services, or setup steps
- **actually run** the install, lint, typecheck, and test commands. This workflow is the one case where running the suite is explicitly authorized. Report each verbatim with pass/fail.
- propose a `repos.yml` entry in the shape documented at the bottom of `repos.yml`, with `null` for absent commands, plus the ref (commit sha) inspected

**Step 2 — register** (agent: `registrar`, single mode)
Dispatch the registrar with the analyst's full report. It writes exactly one entry into `repos.yml` and touches nothing else. Confirm afterwards that `repos.yml` is still valid YAML and that existing entries and comments survived.

**Step 3 — confirm and pause**
Report to me: the entry as written, every command with its result, anything unverified and why, required env/setup, and the dependency edges with their evidence. Then **stop**. Do not `git commit`, `git push`, or open a PR; wait for my explicit approval.

**Global rules:**
- **Verified or absent, never assumed.** A command that failed or could not be run is recorded as unverified, never as working. If install itself fails, report that the entry is partial and which workflows will hit the gap.
- **The registry records location and commands only.** No interface shapes, payloads, or schemas in `repos.yml`: those are read from code on every run.
- **No documentation artifacts.** Onboarding produces a registry entry and your report to me. Never a repo overview, API doc, or analysis file.
- **Always SSH** for clone/fetch (`git@github.com:<owner>/<name>.git`).
- If the repo cannot be cloned (SSH access, wrong name, private), report the exact error and stop. Do not fall back to HTTPS and do not create a speculative entry.
- Clones live in `.repo/` (gitignored). Never modify a cloned repo's tracked files; the clone and build/test artifacts are the only writes.
