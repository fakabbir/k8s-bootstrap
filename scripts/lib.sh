#!/usr/bin/env bash
# Shared helpers for build.sh. Sourced, never executed directly.

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_BLUE='' C_GREEN='' C_YELLOW='' C_RED=''
fi

step() { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
info() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
ok()   { printf '    %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '\n%s✗ %s%s\n' "$C_RED$C_BOLD" "$*" "$C_RESET" >&2; exit 1; }

require_bins() {
  local b missing=()
  for b in "$@"; do
    command -v "$b" >/dev/null 2>&1 || missing+=("$b")
  done
  if (( ${#missing[@]} > 0 )); then
    die "Required command(s) not found: ${missing[*]}"
  fi
}

require_context() {
  local ctx=$1
  kubectl config get-contexts -o name 2>/dev/null | grep -qx "$ctx" ||
    die "kubectl context '$ctx' is not in ~/.kube/config. Available: $(kubectl config get-contexts -o name | tr '\n' ' ')"
  kubectl --context "$ctx" cluster-info >/dev/null 2>&1 ||
    die "kubectl context '$ctx' is configured but the API server did not answer."
}

# poll <description> <timeout-seconds> <interval-seconds> <cmd...>
# Runs cmd until it exits 0; dies on timeout with the description attached.
poll() {
  local what=$1 timeout=$2 interval=$3; shift 3
  local waited=0
  while true; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    waited=$((waited + interval))
    if (( waited >= timeout )); then
      return 1
    fi
    info "waiting for ${what} (${waited}s elapsed)"
    sleep "$interval"
  done
}
