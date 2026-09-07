#!/usr/bin/env bash
# shell/azure.sh — workbench-cloud
# Azure tool configuration. Registered at tier: tools (.dotfiles-sync.yml),
# sourced unconditionally; self-guards on `command -v az`.
# Ported from workbench-precursor's tools/azure.sh, unchanged.
command -v az &>/dev/null || return 0

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
