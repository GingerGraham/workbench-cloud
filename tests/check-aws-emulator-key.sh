#!/usr/bin/env bash
# tests/check-aws-emulator-key.sh — workbench-cloud
# Guards the embedded AWS Emulator signing key in
# shell/installers-aws-emulator.sh (_awsemu_public_key) against a mangled
# paste: the block must parse as a PGP public key with exactly one primary
# key, and its fingerprint must match the one recorded in the comment above
# it (security review M3). Also checks that _awsemu_verify accepts a file
# signed by the embedded key's stand-in and rejects one signed by any other
# key.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLERS="${REPO_ROOT}/shell/installers-aws-emulator.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

command -v gpg &>/dev/null || { echo "SKIP: gpg not available — cannot check the embedded AWS Emulator key"; exit 0; }
command -v gpgv &>/dev/null || { echo "SKIP: gpgv not available — cannot check the embedded AWS Emulator key"; exit 0; }

# shellcheck disable=SC2317 # called by the sourced installer file
log_info()  { :; }
# shellcheck disable=SC2317
log_warn()  { :; }
# shellcheck disable=SC2317
log_error() { :; }

# shellcheck source=/dev/null
source "${INSTALLERS}"

EXPECTED_FPR="$(grep -m1 '^# Fingerprint:' "${INSTALLERS}" | sed -E 's/^# Fingerprint: ([0-9A-F]+)\..*$/\1/')"
if [[ -n "${EXPECTED_FPR}" ]]; then
    ok "fingerprint comment found above _awsemu_public_key (${EXPECTED_FPR})"
else
    fail "could not find a '# Fingerprint: <hex>.' comment above _awsemu_public_key"
fi

WORK="$(mktemp -d)" || { echo "FAIL: mktemp -d failed — cannot create an isolated GNUPGHOME for this check"; exit 1; }
trap 'rm -rf "${WORK}"' EXIT
GNUPG_HOME="${WORK}/gnupg"
mkdir -m 700 "${GNUPG_HOME}"

KEY_INFO="$(_awsemu_public_key | gpg --homedir "${GNUPG_HOME}" --with-colons --import-options show-only --import 2>/dev/null)"
if [[ -n "${KEY_INFO}" ]]; then
    ok "_awsemu_public_key output parses as a PGP public key"
else
    fail "_awsemu_public_key output did not parse as a PGP public key"
fi

PRIMARY_COUNT="$(printf '%s\n' "${KEY_INFO}" | grep -c '^pub:')"
if [[ "${PRIMARY_COUNT}" -eq 1 ]]; then
    ok "the embedded block holds exactly one primary key"
else
    fail "the embedded block holds ${PRIMARY_COUNT} primary keys, want 1"
fi

ACTUAL_FPR="$(printf '%s\n' "${KEY_INFO}" | awk -F: '/^fpr:/ { print $10; exit }')"
if [[ -n "${ACTUAL_FPR}" && "${ACTUAL_FPR}" == "${EXPECTED_FPR}" ]]; then
    ok "embedded key's fingerprint matches the comment (${ACTUAL_FPR})"
else
    fail "embedded key's fingerprint (${ACTUAL_FPR:-none}) does not match the comment (${EXPECTED_FPR:-none})"
fi

# ── _awsemu_verify ────────────────────────────────────────────────────────────
# A throwaway key, generated here, signs a file. With the embedded key the
# check must fail; with the throwaway key's public half standing in for the
# embedded key it must pass. Together they show that a file signed by any
# other key is refused and that the mechanism accepts a good signature.
SIGN_HOME="${WORK}/sign"
mkdir -m 700 "${SIGN_HOME}"
printf 'package contents\n' > "${WORK}/pkg.rpm"
if gpg --homedir "${SIGN_HOME}" --batch --quiet --pinentry-mode loopback --passphrase '' \
        --quick-generate-key "Throwaway Test <throwaway@example.invalid>" rsa2048 sign never 2>/dev/null \
    && gpg --homedir "${SIGN_HOME}" --batch --quiet --detach-sign --output "${WORK}/pkg.rpm.sig" "${WORK}/pkg.rpm" 2>/dev/null \
    && gpg --homedir "${SIGN_HOME}" --armor --export > "${WORK}/throwaway.asc" 2>/dev/null; then
    if _awsemu_verify "${WORK}/pkg.rpm" "${WORK}/pkg.rpm.sig"; then
        fail "_awsemu_verify accepted a file signed by a key other than AWS's"
    else
        ok "_awsemu_verify rejects a file signed by a key other than AWS's"
    fi

    # shellcheck disable=SC2317 # called by _awsemu_verify
    _awsemu_public_key() { command cat "${WORK}/throwaway.asc"; }
    if _awsemu_verify "${WORK}/pkg.rpm" "${WORK}/pkg.rpm.sig"; then
        ok "_awsemu_verify accepts a file whose signature matches the embedded key"
    else
        fail "_awsemu_verify rejected a good signature"
    fi

    printf 'tampered\n' >> "${WORK}/pkg.rpm"
    if _awsemu_verify "${WORK}/pkg.rpm" "${WORK}/pkg.rpm.sig"; then
        fail "_awsemu_verify accepted a file changed after signing"
    else
        ok "_awsemu_verify rejects a file changed after signing"
    fi
else
    echo "SKIP: could not generate a throwaway key here — _awsemu_verify not exercised"
fi

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All checks passed."
    exit 0
else
    echo "${FAILED} check(s) failed."
    exit 1
fi
