#!/usr/bin/env bash
# shell/azure.sh — workbench-cloud
# Azure tool configuration. Registered at tier: tools (.dotfiles-sync.yml),
# sourced unconditionally; self-guards on `command -v az`.
# Ported from workbench-precursor's tools/azure.sh, unchanged.
command -v az &>/dev/null || return 0

# These aliases and az-update are only ever defined once the `command -v az`
# guard above has passed, but get-cloud-functions' static-grep listing can't
# see that runtime guard, so without this it would list them even on hosts
# without az. Declare their availability predicates so the listing matches
# reality.
_wb_declare_availability az azl azlo azs azsl azss az-update

# ── aliases ───────────────────────────────────────────────────────────────────
alias azl="az login"
alias azlo="az logout"
alias azs="az account show"
alias azsl="az account list --output table"
alias azss="az account set --subscription"

# ── functions ─────────────────────────────────────────────────────────────────
# Thin wrapper — install-azure (shell/installers.sh) already handles both
# the fresh-install and update-in-place cases across every distro and macOS.
# Kept here as a short, memorable name for anyone reaching for "az-update" out
# of habit.
az-update() {
    install-azure
}
