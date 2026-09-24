#!/usr/bin/env bash
# tests/check-aws-key.sh — workbench-cloud
# Guards the embedded AWS CLI signing key in shell/installers.sh
# (_aws_cli_public_key) against a mangled paste: the block must parse as a
# PGP public key, and its fingerprint must match the one recorded in the
# comment above it (security review M3).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLERS="${REPO_ROOT}/shell/installers.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

command -v gpg &>/dev/null || { echo "SKIP: gpg not available — cannot check the embedded AWS CLI key"; exit 0; }

# shellcheck source=/dev/null
source "${INSTALLERS}"

EXPECTED_FPR="$(grep -m1 '^# Fingerprint:' "${INSTALLERS}" | sed -E 's/^# Fingerprint: ([0-9A-F]+)\..*$/\1/')"
if [[ -n "${EXPECTED_FPR}" ]]; then
    ok "fingerprint comment found above _aws_cli_public_key (${EXPECTED_FPR})"
else
    fail "could not find a '# Fingerprint: <hex>.' comment above _aws_cli_public_key"
fi

GNUPG_HOME="$(mktemp -d)"
trap 'rm -rf "${GNUPG_HOME}"' EXIT

KEY_INFO="$(_aws_cli_public_key | gpg --homedir "${GNUPG_HOME}" --with-colons --import-options show-only --import 2>/dev/null)"
if [[ -n "${KEY_INFO}" ]]; then
    ok "_aws_cli_public_key output parses as a PGP public key"
else
    fail "_aws_cli_public_key output did not parse as a PGP public key"
fi

ACTUAL_FPR="$(echo "${KEY_INFO}" | awk -F: '/^fpr:/ { print $10; exit }')"
if [[ -n "${ACTUAL_FPR}" && "${ACTUAL_FPR}" == "${EXPECTED_FPR}" ]]; then
    ok "embedded key's fingerprint matches the comment (${ACTUAL_FPR})"
else
    fail "embedded key's fingerprint (${ACTUAL_FPR:-none}) does not match the comment (${EXPECTED_FPR:-none})"
fi

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All checks passed."
    exit 0
else
    echo "${FAILED} check(s) failed."
    exit 1
fi
