#!/usr/bin/env sh
# ------------------------------------------------------------------------------
# parent-pipeline repo bootstrap / inspection tool
#
#   new-repo.sh inspect [REPO]   Read-only. Dump the config (vars, secret NAMES,
#                                environments) of REPO (default: the template) so
#                                you can note which settings a new repo needs.
#
#   new-repo.sh create           Create a new repo from the processor template,
#                                then optionally seed repo-level secrets/vars and
#                                collaborators.
#
# NOTE ON CONFIG: the pipeline reads secrets from the CALLER repo and the
# cgi-italy org, never from parent-pipeline. The 4 required secrets (see
# parent-pipeline README.md) are set once at the cgi-italy org level, so a new
# repo needs no secret setup.
# ------------------------------------------------------------------------------
set -eu

ORG="cgi-italy"
TEMPLATE="$ORG/processor-template"
VISIBILITY="private"
DEFAULT_PERM="push"

log() { printf '%-8s %s\n' "$1" "$2"; }

require_gh() {
  command -v gh >/dev/null 2>&1 || { log ERROR "gh not found"; exit 1; }
  gh auth status >/dev/null 2>&1 || { log ERROR "gh not authenticated"; exit 1; }
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
  *)
    printf 'usage: %s {inspect [REPO] | create}\n' "$0"
    exit 1
    ;;
esac
