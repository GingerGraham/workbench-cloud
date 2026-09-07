#!/usr/bin/env bash
# shell/aws.sh — workbench-cloud
# AWS tool configuration, plus the get-cloud-functions getter for the whole
# module. Registered at tier: tools (.dotfiles-sync.yml), sourced
# unconditionally. get-cloud-functions must stay ahead of the `command -v
# aws` guard below: .dotfiles-sync.yml registers it as the module's sole
# getter, so on an Azure-only machine (no aws CLI) it must still be defined,
# or azure.sh's aws-independent az* aliases/az-update become unenumerable.
get-cloud-functions() {
    local _dir; _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _get_functions_in "Cloud functions" "" "${_dir}/aws.sh" "${_dir}/azure.sh"
    _get_aliases_in "Cloud aliases" "" "${_dir}/aws.sh" "${_dir}/azure.sh"
}

# Ported from workbench-precursor's tools/aws.sh, unchanged.
command -v aws &>/dev/null || return 0

# ── functions ─────────────────────────────────────────────────────────────────
# Thin wrapper — install-aws (shell/installers.sh) already handles both the
# fresh-install and update-in-place cases across every platform. Kept here as
# a short, memorable name for anyone reaching for "aws-update" out of habit.
aws-update() {
    install-aws
}
