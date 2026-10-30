#!/usr/bin/env bash
# Push the sami-infra Terraform inputs from resources/vault.txt to the
# sami-infra CI secrets (TF_VAR_<var>) plus the customer-agent env variables.
#
# vault.txt is the source of truth; GitHub is a mirror, because the CI runner
# cannot read this repo's git-crypt vault. Re-run this after a value changes.
#
# Dry run by default — it prints secret NAMES and lengths, never values.
#
#   scripts/vault-to-github-secrets.sh                  # show what would change
#   scripts/vault-to-github-secrets.sh --apply          # actually write secrets
#
# Requires: gh, logged in with admin on the target repo. Values are piped on
# stdin, so nothing secret lands in argv, shell history, or the process list.

set -euo pipefail

repo="libre-net-pe/sami-infra"
env_name="production"
apply=false

while (($#)); do
  case "$1" in
    --apply) apply=true ;;
    --repo) repo="$2"; shift ;;
    --env) env_name="$2"; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vault="$root/resources/vault.txt"
[[ -r "$vault" ]] || { echo "missing $vault" >&2; exit 1; }
head -c 9 "$vault" | grep -q GITCRYPT && { echo "vault is locked: run git-crypt unlock" >&2; exit 2; }

# One entry per variable in sami-infra/variables.tf -> secret TF_VAR_<lowercase>.
# Listed explicitly so a renamed or dropped key fails loudly instead of silently
# shrinking the CI secret set (an empty/missing TF_VAR_ blanks the live Railway
# variable rather than failing the apply). Keep in sync with variables.tf.
keys=(
  RAILWAY_WORKSPACE_ID      # railway_workspace_id      (required)
  POSTGRES_PASSWORD         # postgres_password         (required)
  SIDECAR_POSTGRES_PASSWORD # sidecar_postgres_password (required)
  WHATSAPP_VERIFY_TOKEN     # whatsapp_verify_token
  WHATSAPP_APP_SECRET       # whatsapp_app_secret
  WHATSAPP_ACCESS_TOKEN     # whatsapp_access_token
  MEDIA_DOWNLOAD_TOKEN      # media_download_token
  FIREBASE_PROJECT_ID       # firebase_project_id
  JEV_API_KEY               # jev_api_key
  GEMINI_API_KEY            # gemini_api_key
  META_CATALOG_ACCESS_TOKEN # meta_catalog_access_token
  ALLOWED_ORIGINS           # allowed_origins
  SIDECAR_SEND_TOKEN        # sidecar_send_token
)

# Empty is a meaningful value for these: an absent secret leaves the env var
# unset, the HCL default "" applies, and sidecar_phone_number_ids then means
# "let the backend's per-number DB channel decide". They are pushed only when
# the vault actually carries a value.
optional=(
  SIDECAR_PHONE_NUMBER_IDS # sidecar_phone_number_ids (force-override)
)

# The customer-agent provider is consumed by .github/workflows/ci.yml as a
# GitHub Environment *secret* named CUSTOMER_AGENT_API_KEY (not TF_VAR_*) and
# two non-secret Environment *variables*. Empty is the dark-launch disabled
# state: an unset/empty key leaves the agent off, and URL/model are required
# only once a key is configured (variables.tf enforces the same rule).
customer_agent_key=CUSTOMER_AGENT_API_KEY
customer_agent_vars=(
  CUSTOMER_AGENT_BASE_URL
  CUSTOMER_AGENT_MODEL
)

echo "source: $vault"
echo "target: $repo environment=$env_name"
echo

fail=0

# customer agent: a configured key requires the two non-secret companions
customer_agent_key_value="$(sed -n "s/^${customer_agent_key}=//p" "$vault")"
if [[ -n "$customer_agent_key_value" ]]; then
  for key in "${customer_agent_vars[@]}"; do
    value="$(sed -n "s/^${key}=//p" "$vault")"
    if [[ -z "$value" ]]; then
      echo "EMPTY  $key — required when $customer_agent_key is set"
      fail=1
    fi
  done
fi

# required: must be present and non-empty
for key in "${keys[@]}"; do
  name="TF_VAR_$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"

  if ! grep -q "^${key}=" "$vault"; then
    echo "MISSING $name (from $key) — not in resources/vault.txt"
    fail=1
    continue
  fi
  value="$(sed -n "s/^${key}=//p" "$vault")"

  if [[ -z "$value" ]]; then
    # Empty would blank the live Railway variable instead of failing the apply.
    echo "EMPTY  $name (from $key) — refusing to push an empty value"
    fail=1
    continue
  fi

  if $apply; then
    printf '%s' "$value" | gh secret set "$name" --repo "$repo" --env "$env_name" >/dev/null
    echo "set    $name (from $key, ${#value} bytes)"
  else
    echo "would  $name (from $key, ${#value} bytes)"
  fi
done

# optional: empty is meaningful, so an empty value means "leave it unset"
for key in "${optional[@]}"; do
  name="TF_VAR_$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
  value="$(sed -n "s/^${key}=//p" "$vault")"
  if [[ -z "$value" ]]; then
    echo "skip   $name (from $key) — empty is the wanted value; secret left unset"
    continue
  fi
  if $apply; then
    printf '%s' "$value" | gh secret set "$name" --repo "$repo" --env "$env_name" >/dev/null
    echo "set    $name (from $key, ${#value} bytes)"
  else
    echo "would  $name (from $key, ${#value} bytes)"
  fi
done

# customer agent: empty key means disabled, so it is pushed only when set
if [[ -n "$customer_agent_key_value" ]]; then
  if $apply; then
    printf '%s' "$customer_agent_key_value" | \
      gh secret set "$customer_agent_key" --repo "$repo" --env "$env_name" >/dev/null
    echo "set    $customer_agent_key (from $customer_agent_key, ${#customer_agent_key_value} bytes)"
  else
    echo "would  $customer_agent_key (from $customer_agent_key, ${#customer_agent_key_value} bytes)"
  fi
else
  echo "skip   $customer_agent_key — empty keeps the agent disabled; secret left unset"
fi

for key in "${customer_agent_vars[@]}"; do
  value="$(sed -n "s/^${key}=//p" "$vault")"
  if [[ -z "$value" ]]; then
    echo "skip   $key — empty keeps the agent disabled; variable left unset"
    continue
  fi
  if $apply; then
    gh variable set "$key" --repo "$repo" --env "$env_name" --body "$value" >/dev/null
    echo "set    $key (from $key, ${#value} bytes)"
  else
    echo "would  $key (from $key, ${#value} bytes)"
  fi
done

echo
if ((fail)); then
  echo "at least one required key is empty — fix resources/vault.txt first" >&2
  exit 1
fi
$apply || echo "dry run: re-run with --apply to write the secrets"
