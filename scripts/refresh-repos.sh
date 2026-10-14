#!/usr/bin/env bash
# refresh-repos.sh — deterministic per-repo refresh, run at the start of every
# feature-review / bug-fix run.
#
# This replaces the old "one analyst dispatch per repo" refresh step. For every
# entry in repos.yml it: clones the repo if .repo/<name> is absent, verifies the
# SSH remote, fetches origin, and fast-forwards a clean clone that is on its
# registered default branch. Anything else — a dirty tree, a non-default branch,
# diverged history, a fetch failure, a remote that does not match the registry —
# is REPORTED and left exactly as found. Beyond the initial clone the hard rules
# match the analyst's: no pull, no reset, no force, no rebase, no checkout. It
# clones what is missing; it fixes nothing else.
#
# stdout: one JSON document (the report the orchestrator hands to the planner)
# stderr: human-readable progress
#
# It also mints the run id. `--run <slug>` generates <slug>-<6 random chars>,
# reserves .repo/worktrees/<run-id>/ with mkdir (so a second run cannot claim
# the same namespace), writes the .factory-run.json marker, and reports the id
# as "run_id" in the JSON. Minting it here, rather than having an agent invent
# "random" characters, is what makes the namespace actually collision-free.
#
# Usage:
#   scripts/refresh-repos.sh [--run <slug>] [--no-clone-missing] [--no-pretty]
#
#   --run <slug>        mint and reserve a run id for this run (kebab-case
#                       feature or bug slug). Omit it for a read-only refresh,
#                       and "run_id" comes back null.
#   --no-clone-missing  do not clone absent repos; report state "missing" and
#                       leave them (default: clone, so a run never stalls on a
#                       repo that simply was not cloned yet)
#   --no-pretty         emit minified JSON
#
# Exit: 0 on a completed report (even when repos are dirty/diverged/missing),
#       1 if repos.yml cannot be read or parsed, or if a run id could not be
#       reserved after several attempts.

set -uo pipefail

CLONE_MISSING=1
PRETTY=1
RUN_SLUG=""
RUN_ID=""
RUN_DIR=""
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --clone-missing)    CLONE_MISSING=1 ;;
    --no-clone-missing) CLONE_MISSING=0 ;;
    --no-pretty)        PRETTY=0 ;;
    --run)              shift; RUN_SLUG="${1:-}"
                        [ -n "$RUN_SLUG" ] || { echo "refresh-repos: --run needs a slug" >&2; exit 1; } ;;
    --run=*)            RUN_SLUG="${1#--run=}" ;;
    -h|--help)          sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "refresh-repos: unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

REGISTRY="$ROOT/repos.yml"
[ -f "$REGISTRY" ] || { echo "refresh-repos: repos.yml not found at $REGISTRY" >&2; exit 1; }

# --- Run id ------------------------------------------------------------------
# Mint <slug>-<6 random lowercase alphanumerics> and reserve its worktree
# namespace. `mkdir` without -p is the lock: it fails if the directory exists,
# so two runs can never share a run-id.

mint_run_id() {
  local slug suffix attempt=0
  slug="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')"
  [ -n "$slug" ] || { echo "refresh-repos: --run slug is empty after normalization" >&2; exit 1; }

  while [ "$attempt" -lt 10 ]; do
    attempt=$((attempt + 1))
    suffix="$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 6)"
    [ "${#suffix}" -eq 6 ] || suffix="$(printf '%06x' $(( (RANDOM << 15 | RANDOM) % 16777216 )))"
    RUN_ID="$slug-$suffix"
    RUN_DIR="$ROOT/.repo/worktrees/$RUN_ID"
    mkdir -p "$ROOT/.repo/worktrees" 2>/dev/null
    if mkdir "$RUN_DIR" 2>/dev/null; then
      printf '{\n  "run_id": "%s",\n  "feature": "%s",\n  "created": "%s"\n}\n' \
        "$RUN_ID" "$slug" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RUN_DIR/.factory-run.json"
      printf 'refresh-repos: run id %s (reserved %s)\n' "$RUN_ID" ".repo/worktrees/$RUN_ID" >&2
      return 0
    fi
    printf 'refresh-repos: run id %s already taken, retrying\n' "$RUN_ID" >&2
  done

  echo "refresh-repos: could not reserve a run id for '$slug' after 10 attempts" >&2
  exit 1
}

[ -n "$RUN_SLUG" ] && mint_run_id "$RUN_SLUG"

# --- JSON helpers ------------------------------------------------------------

json_str() {
  # Minimal, correct-enough string escaper for the constrained values we emit
  # (names, paths, shas, remotes, short git error text).
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

# --- Parse the registry ------------------------------------------------------

CLONE_ROOT=".repo"
entries="$(awk '
  function flush() {
    if (name != "") print name "\t" url "\t" path "\t" def
    name = ""; url = ""; path = ""; def = "main"
  }
  /^clone_root:/ {
    v = $0; sub(/^clone_root:[ ]*/, "", v); sub(/[ ]*#.*$/, "", v); print "@clone_root\t" v "\t\t"
    next
  }
  /^  - name:/ {
    flush()
    name = $0; sub(/^  - name:[ ]*/, "", name); sub(/[ ]*#.*$/, "", name)
    next
  }
  /^    url:/            { url  = $0; sub(/^    url:[ ]*/, "", url);           sub(/[ ]*#.*$/, "", url);  next }
  /^    path:/           { path = $0; sub(/^    path:[ ]*/, "", path);         sub(/[ ]*#.*$/, "", path); next }
  /^    default_branch:/ { def  = $0; sub(/^    default_branch:[ ]*/, "", def); sub(/[ ]*#.*$/, "", def);  next }
  END { flush() }
' "$REGISTRY")"

if [ -z "$entries" ]; then
  echo "refresh-repos: could not parse any repos from $REGISTRY" >&2
  exit 1
fi

REPO_OBJS=()
# Plain counters, not an associative array: macOS ships bash 3.2, which has no
# `declare -A`, and this script must run under /bin/bash there.
S_total=0; S_cloned=0; S_refreshed=0; S_clean=0; S_dirty=0
S_wrong_branch=0; S_diverged=0; S_remote_mismatch=0; S_missing=0; S_error=0

tally() {
  case "$1" in
    cloned)          S_cloned=$((S_cloned + 1)) ;;
    refreshed)       S_refreshed=$((S_refreshed + 1)) ;;
    clean)           S_clean=$((S_clean + 1)) ;;
    dirty)           S_dirty=$((S_dirty + 1)) ;;
    wrong_branch)    S_wrong_branch=$((S_wrong_branch + 1)) ;;
    diverged)        S_diverged=$((S_diverged + 1)) ;;
    remote_mismatch) S_remote_mismatch=$((S_remote_mismatch + 1)) ;;
    missing)         S_missing=$((S_missing + 1)) ;;
    error)           S_error=$((S_error + 1)) ;;
  esac
}

# --- Per-repo refresh --------------------------------------------------------

refresh_repo() {
  local name="$1" expected="$2" rel="$3" def="$4"
  local path="$ROOT/$rel"
  local state="" old_sha="" new_sha="" branch="" actual_remote="" dirty=0 err="" tmp just_cloned=0
  local -a worktrees=() factories=()
  tmp="$(mktemp)"

  S_total=$((S_total + 1))

  # Missing clone ------------------------------------------------------------
  if [ ! -d "$path/.git" ]; then
    if [ "$CLONE_MISSING" = "1" ]; then
      printf 'refresh-repos: cloning %s -> %s\n' "$name" "$rel" >&2
      if git clone "$expected" "$path" >"$tmp" 2>&1; then
        just_cloned=1
      else
        state="error"; err="clone failed: $(tr '\n' ' ' < "$tmp")"
      fi
    fi
    if [ -z "$state" ] && [ "$just_cloned" != "1" ]; then
      state="missing"
      printf 'refresh-repos: %s: missing clone (%s), not cloned: --no-clone-missing\n' "$name" "$rel" >&2
    fi
  fi

  if [ -d "$path/.git" ] && [ -z "$state" ]; then
    actual_remote="$(git -C "$path" remote get-url origin 2>/dev/null || echo '')"
    old_sha="$(git -C "$path" rev-parse HEAD 2>/dev/null || echo '')"
    new_sha="$old_sha"
    branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
    [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ] && dirty=1

    if [ -n "$expected" ] && [ "$actual_remote" != "$expected" ]; then
      state="remote_mismatch"
      err="origin is $actual_remote, registry says $expected"
    elif ! git -C "$path" fetch origin --quiet >"$tmp" 2>&1; then
      state="error"; err="git fetch origin failed: $(tr '\n' ' ' < "$tmp")"
    elif [ "$dirty" = "1" ]; then
      state="dirty"
    elif [ "$branch" != "$def" ]; then
      state="wrong_branch"
    elif git -C "$path" merge --ff-only "origin/$def" >"$tmp" 2>&1; then
      new_sha="$(git -C "$path" rev-parse HEAD 2>/dev/null || echo "$old_sha")"
      if [ "$just_cloned" = "1" ]; then state="cloned"
      elif [ "$new_sha" = "$old_sha" ]; then state="clean"
      else state="refreshed"; fi
    else
      state="diverged"; err="$(tr '\n' ' ' < "$tmp")"
    fi

    # Worktrees --------------------------------------------------------------
    local wt_path="" wt_sha="" wt_branch=""
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) wt_path="${line#worktree }" ;;
        "HEAD "*)     wt_sha="${line#HEAD }" ;;
        "branch "*)   wt_branch="${line#branch refs/heads/}"
                      worktrees+=("{\"path\":$(json_str "$wt_path"),\"branch\":$(json_str "$wt_branch"),\"sha\":$(json_str "$wt_sha")}")
                      wt_path=""; wt_sha=""; wt_branch="" ;;
        "detached")   worktrees+=("{\"path\":$(json_str "$wt_path"),\"branch\":\"(detached)\",\"sha\":$(json_str "$wt_sha")}")
                      wt_path=""; wt_sha=""; wt_branch="" ;;
      esac
    done < <(git -C "$path" worktree list --porcelain 2>/dev/null)

    # In-flight factory branches --------------------------------------------
    local ref run marker feature sha
    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      sha="$(git -C "$path" rev-parse --short "$ref" 2>/dev/null || echo '')"
      run=""; marker=""; feature=""
      case "$ref" in
        factory/*) run="${ref#factory/}"; run="${run%%/*}"
                   marker="$ROOT/.repo/worktrees/$run/.factory-run.json"
                   if [ -f "$marker" ]; then
                     feature="$(grep -o '"feature"[[:space:]]*:[[:space:]]*"[^"]*"' "$marker" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')"
                   fi ;;
      esac
      factories+=("{\"name\":$(json_str "$ref"),\"commit\":$(json_str "$sha"),\"run_id\":$(json_str "$run"),\"marker\":$(json_str "$marker"),\"feature\":$(json_str "$feature")}")
    done < <(git -C "$path" for-each-ref --format='%(refname:short)' refs/heads/factory/ 2>/dev/null)
  fi

  rm -f "$tmp"

  # Summary tally -------------------------------------------------------------
  tally "$state"
  printf 'refresh-repos: %-20s %-14s %s -> %s\n' "$name" "$state" "${old_sha:0:7}" "${new_sha:0:7}" >&2

  local dirty_json=false; [ "$dirty" = "1" ] && dirty_json=true
  local err_json=null; [ -n "$err" ] && err_json="$(json_str "$err")"
  local wt_json="[]"; [ "${#worktrees[@]}" -gt 0 ] && wt_json="[$(IFS=,; echo "${worktrees[*]}")]"
  local fc_json="[]"; [ "${#factories[@]}" -gt 0 ] && fc_json="[$(IFS=,; echo "${factories[*]}")]"

  REPO_OBJS+=("$(printf '    {\n      "name": %s,\n      "path": %s,\n      "expected_remote": %s,\n      "actual_remote": %s,\n      "default_branch": %s,\n      "state": %s,\n      "old_sha": %s,\n      "new_sha": %s,\n      "branch": %s,\n      "dirty": %s,\n      "worktrees": %s,\n      "factory_branches": %s,\n      "error": %s\n    }' \
    "$(json_str "$name")" "$(json_str "$rel")" "$(json_str "$expected")" "$(json_str "$actual_remote")" \
    "$(json_str "$def")" "$(json_str "$state")" "$(json_str "$old_sha")" "$(json_str "$new_sha")" \
    "$(json_str "$branch")" "$dirty_json" "$wt_json" "$fc_json" "$err_json")")
}

while IFS=$'\t' read -r name url path def; do
  [ -z "$name" ] && continue
  if [ "$name" = "@clone_root" ]; then CLONE_ROOT="$url"; continue; fi
  [ -z "$path" ] && path="$CLONE_ROOT/$name"
  refresh_repo "$name" "$url" "$path" "${def:-main}"
done <<< "$entries"

# --- Emit --------------------------------------------------------------------

repos_json=""
sep=$'\n'
for obj in ${REPO_OBJS[@]+"${REPO_OBJS[@]}"}; do
  repos_json+="$sep$obj"
  sep=","$'\n'
done

report="$(cat <<EOF
{
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "registry": "repos.yml",
  "clone_root": "$CLONE_ROOT",
  "run_id": $( [ -n "$RUN_ID" ] && json_str "$RUN_ID" || echo null ),
  "run_dir": $( [ -n "$RUN_ID" ] && json_str ".repo/worktrees/$RUN_ID" || echo null ),
  "summary": {
    "total": $S_total,
    "cloned": $S_cloned,
    "refreshed": $S_refreshed,
    "clean": $S_clean,
    "dirty": $S_dirty,
    "wrong_branch": $S_wrong_branch,
    "diverged": $S_diverged,
    "remote_mismatch": $S_remote_mismatch,
    "missing": $S_missing,
    "error": $S_error
  },
  "repos": [$repos_json
  ]
}
EOF
)"

if [ "$PRETTY" = "1" ]; then
  printf '%s\n' "$report"
else
  printf '%s\n' "$report" | tr -d '\n' | tr -s ' '
fi

exit 0
