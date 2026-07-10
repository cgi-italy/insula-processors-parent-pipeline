#!/usr/bin/env sh
# ------------------------------------------------------------------------------
# parent-pipeline repo bootstrap / inspection tool
#
#   new-repo.sh inspect [REPO]   Read-only. Dump the config (vars, secret NAMES,
#                                environments) of REPO (default: the template) so
#                                you can note which settings a new repo needs.
#
#   new-repo.sh create           Create a new repo from the processor template,
#                                copy the settings GitHub does NOT clone from a
#                                template (Actions allow-list, workflow perms,
#                                repo merge/feature options), then optionally seed
#                                repo-level secrets/vars and collaborators.
#
#   new-repo.sh sync REPO        Re-apply those same settings to an existing repo.
#
# NOTE ON CONFIG: the pipeline reads secrets from the CALLER repo and the
# cgi-italy org, never from parent-pipeline. The 4 required secrets (see
# parent-pipeline README.md) are set once at the cgi-italy org level, so a new
# repo needs no secret setup.
#
# NOTE ON gh: on this machine gh lives in WSL, not Git Bash. Run this script from
# WSL (or any shell where `gh` is on PATH and authenticated).
#
# NOTE ON HARDCODED SETTINGS: the values below are a snapshot of
# cgi-italy/processor_template. GitHub's template feature does NOT copy Actions
# permissions, the selected-actions allow-list, workflow default permissions, or
# repo merge/feature toggles, so we re-apply them explicitly. If the template
# changes, run `inspect` and update the constants here.
# ------------------------------------------------------------------------------
set -eu

ORG="cgi-italy"
TEMPLATE="$ORG/processor_template"
VISIBILITY="private"
DEFAULT_PERM="push"

# --- snapshot of processor_template settings (see NOTE ON HARDCODED SETTINGS) --
ALLOWED_ACTIONS_JSON='{"github_owned_allowed":false,"verified_allowed":false,"patterns_allowed":["actions/cache/restore@*","actions/cache@*","actions/checkout@*","anchore/scan-action@*","aquasecurity/setup-trivy@*","aquasecurity/trivy-action@*","docker/build-push-action@*","docker/login-action@*","docker/setup-buildx-action@*"]}'
WORKFLOW_PERMS_JSON='{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'
RETENTION_JSON='{"days":7}'
FORK_PR_JSON='{"run_workflows_from_fork_pull_requests":false,"send_write_tokens_to_workflows":false,"send_secrets_and_variables":false,"require_approval_for_fork_pr_workflows":false}'
REPO_SETTINGS_JSON='{"has_issues":false,"has_projects":false,"has_wiki":false,"allow_squash_merge":true,"allow_merge_commit":true,"allow_rebase_merge":true,"allow_auto_merge":false,"delete_branch_on_merge":false,"allow_update_branch":false}'

log() { printf '%-8s %s\n' "$1" "$2"; }

require_gh() {
  command -v gh >/dev/null 2>&1 || { log ERROR "gh not found (run from WSL)"; exit 1; }
  gh auth status >/dev/null 2>&1 || { log ERROR "gh not authenticated"; exit 1; }
}

# ---- copy settings the template feature drops --------------------------------
apply_settings() {
  TGT="$1"

  gh api -X PATCH "repos/$TGT" --input - <<EOF >/dev/null 2>&1 \
    && log SETTINGS "merge/feature options applied" \
    || log WARN "repo settings not applied"
$REPO_SETTINGS_JSON
EOF

  # allow_actions must be flipped to "selected" before the allow-list is set.
  if gh api -X PUT "repos/$TGT/actions/permissions" \
       -F enabled=true -f allowed_actions=selected >/dev/null 2>&1; then
    gh api -X PUT "repos/$TGT/actions/permissions/selected-actions" --input - <<EOF >/dev/null 2>&1 \
      && log ACTIONS "allowed-actions list applied" \
      || log WARN "allowed-actions list not applied"
$ALLOWED_ACTIONS_JSON
EOF
  else
    log WARN "actions permissions not applied"
  fi

  gh api -X PUT "repos/$TGT/actions/permissions/workflow" --input - <<EOF >/dev/null 2>&1 \
    && log ACTIONS "workflow permissions applied" \
    || log WARN "workflow permissions not applied"
$WORKFLOW_PERMS_JSON
EOF

  gh api -X PUT "repos/$TGT/actions/permissions/artifact-and-log-retention" --input - <<EOF >/dev/null 2>&1 \
    && log ACTIONS "artifact/log retention set (7d)" \
    || log WARN "retention not applied"
$RETENTION_JSON
EOF

  gh api -X PUT "repos/$TGT/actions/permissions/fork-pr-workflows-private-repos" --input - <<EOF >/dev/null 2>&1 \
    && log ACTIONS "fork-PR workflows disabled" \
    || log WARN "fork-PR settings not applied"
$FORK_PR_JSON
EOF
}

cmd_sync() {
  TARGET="${1:-}"
  [ -n "$TARGET" ] || { log ERROR "usage: sync REPO"; exit 1; }
  case "$TARGET" in */*) : ;; *) TARGET="$ORG/$TARGET" ;; esac
  gh repo view "$TARGET" >/dev/null 2>&1 || { log ERROR "$TARGET not found"; exit 1; }
  log SYNC "$TARGET"
  apply_settings "$TARGET"
  log DONE "$TARGET synced"
}

# ---- inspect (read-only) -----------------------------------------------------
cmd_inspect() {
  TARGET="${1:-$TEMPLATE}"
  case "$TARGET" in */*) : ;; *) TARGET="$ORG/$TARGET" ;; esac
  log INSPECT "$TARGET"

  printf '\n--- Repository ---\n'
  gh repo view "$TARGET" --json name,visibility,isTemplate,defaultBranchRef \
    --template '{{.name}}  visibility={{.visibility}}  template={{.isTemplate}}  default={{.defaultBranchRef.name}}{{"\n"}}' \
    2>/dev/null || log WARN "cannot read repo"

  printf '\n--- Merge / feature settings ---\n'
  gh api "repos/$TARGET" \
    --jq '{has_issues,has_projects,has_wiki,allow_squash_merge,allow_merge_commit,allow_rebase_merge,allow_auto_merge,delete_branch_on_merge,allow_update_branch}' \
    2>/dev/null || log WARN "cannot read repo settings"

  printf '\n--- Actions permissions ---\n'
  gh api "repos/$TARGET/actions/permissions" 2>/dev/null || log WARN "no access"
  printf '\n--- Allowed actions (selected) ---\n'
  gh api "repos/$TARGET/actions/permissions/selected-actions" 2>/dev/null || log WARN "not on selected mode or no access"
  printf '\n--- Workflow default permissions ---\n'
  gh api "repos/$TARGET/actions/permissions/workflow" 2>/dev/null || log WARN "no access"
  printf '\n--- Artifact/log retention ---\n'
  gh api "repos/$TARGET/actions/permissions/artifact-and-log-retention" 2>/dev/null || log WARN "no access"
  printf '\n--- Fork-PR workflows (private) ---\n'
  gh api "repos/$TARGET/actions/permissions/fork-pr-workflows-private-repos" 2>/dev/null || log WARN "no access"

  printf '\n--- Variables (name = value) ---\n'
  gh variable list --repo "$TARGET" 2>/dev/null || log WARN "no repo variables or no access"

  printf '\n--- Secret names (values are never retrievable) ---\n'
  gh secret list --repo "$TARGET" 2>/dev/null || log WARN "no repo secrets or no access"

  printf '\n--- Environments ---\n'
  gh api "repos/$TARGET/environments" \
    --jq '.environments[]?.name' 2>/dev/null || log WARN "no environments or no access"

  printf '\n--- Org-level variables (%s) ---\n' "$ORG"
  gh variable list --org "$ORG" 2>/dev/null || log WARN "no org variable access"

  printf '\n--- Org-level secret names (%s) ---\n' "$ORG"
  gh secret list --org "$ORG" 2>/dev/null || log WARN "no org secret access"
}

# ---- create ------------------------------------------------------------------
cmd_create() {
  printf 'New repo name: '
  read -r NAME
  [ -n "$NAME" ] || { log ERROR "name required"; exit 1; }
  FULL="$ORG/$NAME"

  if gh repo view "$FULL" >/dev/null 2>&1; then
    log ERROR "$FULL already exists"
    exit 1
  fi

  gh repo create "$FULL" --template "$TEMPLATE" --"$VISIBILITY"
  log CREATE "$FULL"
  sleep 2

  printf '\n--- Copying settings the template feature drops ---\n'
  apply_settings "$FULL"

  printf '\n--- Repo secrets (optional extras only; the 4 required secrets are org-level) ---\n'
  while :; do
    printf 'Secret name: '
    read -r SNAME
    [ -n "$SNAME" ] || break
    printf 'Value for %s: ' "$SNAME"
    stty -echo 2>/dev/null || true
    read -r SVAL
    stty echo 2>/dev/null || true
    printf '\n'
    printf '%s' "$SVAL" | gh secret set "$SNAME" --repo "$FULL" --body -
    log SECRET "$SNAME set"
  done

  printf '\n--- Repo variables (empty name to stop) ---\n'
  while :; do
    printf 'Variable name: '
    read -r VNAME
    [ -n "$VNAME" ] || break
    printf 'Value for %s: ' "$VNAME"
    read -r VVAL
    gh variable set "$VNAME" --repo "$FULL" --body "$VVAL"
    log VAR "$VNAME set"
  done

  printf '\n--- Collaborators (empty username to stop) ---\n'
  while :; do
    printf 'Username: '
    read -r USER
    [ -n "$USER" ] || break
    printf 'Permission [%s] (pull/triage/push/maintain/admin): ' "$DEFAULT_PERM"
    read -r PERM
    PERM=${PERM:-$DEFAULT_PERM}
    gh api -X PUT "repos/$FULL/collaborators/$USER" -f permission="$PERM" >/dev/null
    log COLLAB "$USER -> $PERM"
  done

  log DONE "$FULL ready"
}

# ---- dispatch ----------------------------------------------------------------
require_gh
CMD="${1:-}"
[ "$#" -gt 0 ] && shift || true
case "$CMD" in
  inspect) cmd_inspect "${1:-}" ;;
  create)  cmd_create ;;
  sync)    cmd_sync "${1:-}" ;;
  *)
    printf 'usage: %s {inspect [REPO] | create | sync REPO}\n' "$0"
    exit 1
    ;;
esac
