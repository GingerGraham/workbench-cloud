#!/usr/bin/env bash
# tests/check-cloud-shell.sh — workbench-cloud
# Plain bash, numbered OK:/FAIL: checks, matching workbench-core's
# tests/check-*.sh convention (no framework). No network, no root: every
# external command an installer would run is a stub.
#
#   - shell/gcloud.sh puts ~/google-cloud-sdk/bin on PATH once, in bash and
#     zsh, and leaves PATH alone when it isn't there.
#   - shell/azure.sh declares its names' availability with a reason and the
#     azure installer, before its `command -v az` guard.
#   - _azure-install-arch uses the AUR only with WORKBENCH_ALLOW_AUR=true
#     (workbench-core D100).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "${WORK}"' EXIT

# ── shell/gcloud.sh ──────────────────────────────────────────────────────────
GCLOUD_SH="${REPO_ROOT}/shell/gcloud.sh"
FAKE_HOME="${WORK}/home"
mkdir -p "${FAKE_HOME}/google-cloud-sdk/bin"

# Sourced twice: the second time must not add the directory again.
gcloud_path_in() {
    local shell="$1" home="$2"
    env -i HOME="${home}" PATH="/usr/bin:/bin" "${shell}" -c \
        ". \"${GCLOUD_SH}\"; . \"${GCLOUD_SH}\"; printf '%s\n' \"\${PATH}\""
}

for shell in bash zsh; do
    if ! command -v "${shell}" &>/dev/null; then
        echo "SKIP: ${shell} not installed — gcloud.sh not checked in ${shell}"
        continue
    fi
    got="$(gcloud_path_in "${shell}" "${FAKE_HOME}")"
    if [[ "${got}" == "${FAKE_HOME}/google-cloud-sdk/bin:/usr/bin:/bin" ]]; then
        ok "${shell}: gcloud.sh adds ~/google-cloud-sdk/bin to PATH once"
    else
        fail "${shell}: gcloud.sh PATH is '${got}'"
    fi
    got="$(gcloud_path_in "${shell}" "${WORK}/no-sdk-home")"
    if [[ "${got}" == "/usr/bin:/bin" ]]; then
        ok "${shell}: gcloud.sh leaves PATH alone without ~/google-cloud-sdk/bin"
    else
        fail "${shell}: gcloud.sh changed PATH without the SDK: '${got}'"
    fi
done

# ── shell/azure.sh availability ──────────────────────────────────────────────
# Stub the Core API call to record its arguments; PATH without az, so the
# file's own guard returns right after the declaration.
# shellcheck disable=SC2016 # expanded by the child bash, not here
got="$(env -i PATH="/usr/bin:/bin" bash -c '
    _wb_alias_availability() { printf "%s|" "$@"; echo; }
    . "$1"
' _ "${REPO_ROOT}/shell/azure.sh" 2>&1)"
want='--needs|az (Azure CLI)|--install|azure|_cloud_az_present|azl|azlo|azs|azsl|azss|az-update|'
if [[ "${got}" == "${want}" ]]; then
    ok "azure.sh declares azl/azlo/azs/azsl/azss/az-update with a reason and --install azure, before its guard"
else
    fail "azure.sh availability declaration: got '${got}', want '${want}'"
fi

# ── _azure-install-arch and WORKBENCH_ALLOW_AUR ──────────────────────────────
STUB_BIN="${WORK}/stub-bin"
mkdir -p "${STUB_BIN}"
for cmd in yay git makepkg; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 0\n' "${cmd}" "${WORK}" > "${STUB_BIN}/${cmd}"
    chmod +x "${STUB_BIN}/${cmd}"
done

run_arch() {
    : > "${WORK}/calls"
    # shellcheck disable=SC2016 # expanded by the child bash, not here
    env -i PATH="${STUB_BIN}:/usr/bin:/bin" WORKBENCH_ALLOW_AUR="$1" bash -c '
        log_info()  { echo "[INFO] $*"; }
        log_warn()  { echo "[WARN] $*"; }
        log_error() { echo "[ERROR] $*"; }
        . "$1"
        _azure-install-arch
    ' _ "${REPO_ROOT}/shell/installers.sh" 2>&1
}

out="$(run_arch "")"; rc=$?
if [[ ${rc} -ne 0 && ! -s "${WORK}/calls" ]] && printf '%s' "${out}" | grep -q 'yay -S azure-cli'; then
    ok "without WORKBENCH_ALLOW_AUR: returns 1, runs nothing, prints 'yay -S azure-cli'"
else
    fail "without WORKBENCH_ALLOW_AUR: rc=${rc}, calls='$(cat "${WORK}/calls")', output: ${out}"
fi

out="$(run_arch true)"; rc=$?
if [[ ${rc} -eq 0 ]] && grep -q '^yay -S --noconfirm azure-cli$' "${WORK}/calls"; then
    ok "WORKBENCH_ALLOW_AUR=true: installs with yay"
else
    fail "WORKBENCH_ALLOW_AUR=true: rc=${rc}, calls='$(cat "${WORK}/calls")', output: ${out}"
fi

echo
echo "==============================="
echo "Total OK/FAIL checks: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
