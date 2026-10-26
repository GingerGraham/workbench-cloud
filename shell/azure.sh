#!/usr/bin/env bash
# shell/azure.sh — workbench-cloud
# Azure tool configuration. Registered at tier: tools (.dotfiles-sync.yml),
# sourced unconditionally; self-guards on `command -v az`.
# These aliases and az-update are only ever defined once the `command -v az`
# guard below has passed, but the getter's static-grep listing can't see
# that runtime guard, so without this it would list them even on hosts
# without az. Declared *before* that guard, not after: on a host without
# az, the guard below returns out of this file immediately, so anything
# placed after it (including this declaration) would never run — and
# _wb_function_available's documented fallback for "no predicate declared"
# is available, which would silently defeat this on exactly the host where
# it needs to fire.
_wb_declare_availability az azl azlo azs azsl azss az-update

# Ported from workbench-precursor's tools/azure.sh, unchanged.
command -v az &>/dev/null || return 0

# ── aliases ───────────────────────────────────────────────────────────────────
alias azl="az login"
alias azlo="az logout"
alias azs="az account show"
alias azsl="az account list --output table"
alias azss="az account set --subscription"

# ── functions ─────────────────────────────────────────────────────────────────
# Thin wrapper — the azure installer (shell/installers.sh) already handles
# both the fresh-install and update-in-place cases across every distro and
# macOS. Kept here as a short, memorable name for anyone reaching for
# "az-update" out of habit. It goes through 'wb tools': installer files are
# never sourced into the interactive shell, so calling the installer
# function directly failed with "command not found" (workbench-core
# docs/decisions-log.md D94).
az-update() {
    wb tools install azure
}
